import Foundation
import AVFoundation
import MediaPlayer

// MARK: - 播放引擎（后台播放 + 锁屏控制 + 倍速 + 定时关闭）

@MainActor
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    @Published private(set) var book: Book?
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float {
        didSet { UserDefaults.standard.set(rate, forKey: "rate_v1") }
    }
    @Published var errorText: String?
    @Published var sleepDeadline: Date?

    /// 跳过片头 / 片尾（秒），0 = 不跳过
    @Published var skipIntro: Double {
        didSet { UserDefaults.standard.set(skipIntro, forKey: "skip_intro_v1") }
    }
    @Published var skipOutro: Double {
        didSet { UserDefaults.standard.set(skipOutro, forKey: "skip_outro_v1") }
    }

    /// 听完当前这一集就停（不自动续下一集）
    @Published var stopAfterEpisode: Bool {
        didSet { UserDefaults.standard.set(stopAfterEpisode, forKey: "stop_after_episode_v1") }
    }

    /// 本集是否已经跳过片头（避免反复 seek）
    private var appliedIntro = false

    private init() {
        rate = UserDefaults.standard.object(forKey: "rate_v1") as? Float ?? 1.0
        skipIntro = UserDefaults.standard.double(forKey: "skip_intro_v1")
        skipOutro = UserDefaults.standard.double(forKey: "skip_outro_v1")
        stopAfterEpisode = UserDefaults.standard.bool(forKey: "stop_after_episode_v1")
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var sleepTimer: Timer?
    private var sourceForCurrent: (any BookSource)?

    var currentEpisode: Episode? {
        guard index >= 0 && index < episodes.count else { return nil }
        return episodes[index]
    }

    /// 启动时调用：把音频会话设成后台可播放
    func prepareForBackgroundAudio() {
        configureAudioSession()
    }

    // MARK: 播放

    /// 片头片尾按「专辑」记（原版行为）；没设过就用全局默认值
    private var perBookSkip: [String: [Double]] {
        get { UserDefaults.standard.object(forKey: "skip_per_book_v1") as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "skip_per_book_v1") }
    }

    /// 换书时把这本书自己的片头片尾读进来
    func loadSkipForCurrentBook() {
        guard let book else { return }
        if let v = perBookSkip[book.bookURL], v.count >= 2 {
            skipIntro = v[0]
            skipOutro = v[1]
        }
    }

    /// 把当前书调好的片头片尾存下来（只对这本专辑有效）
    func saveSkipForCurrentBook() {
        guard let book else { return }
        var d = perBookSkip
        d[book.bookURL] = [skipIntro, skipOutro]
        perBookSkip = d
    }

    func play(book: Book, episodes: [Episode], startAt: Int = 0, autoPlay: Bool = true) {
        guard !episodes.isEmpty else { return }
        self.book = book
        self.episodes = episodes
        self.index = min(max(0, startAt), episodes.count - 1)
        self.sourceForCurrent = SourceRegistry.source(withId: book.sourceId)
        loadSkipForCurrentBook()
        LibraryStore.shared.markPlayed(book: book, episode: self.index,
                                       title: episodes[min(max(0, startAt), episodes.count - 1)].title)
        Task { await load(autoPlay: autoPlay) }
    }

    private func load(autoPlay: Bool) async {
        guard let book, let ep = currentEpisode, let src = sourceForCurrent else { return }
        isLoading = true
        errorText = nil
        do {
            // 已经缓存过就直接放本地文件（离线也能听、不受直链过期影响）
            let localURL = CacheManager.shared.localURL(for: ep.url)
            let url: URL
            if let localURL {
                url = localURL
            } else {
                url = try await src.audioURL(for: ep)
            }
            configureAudioSession()
            // 有些源站的音频 CDN 有 Referer 防盗链，必须通过 AVURLAssetHTTPHeaderFieldsKey 带上
            let headers = src.audioHeaders(for: ep)
            var item: AVPlayerItem
            if headers.isEmpty {
                item = AVPlayerItem(url: url)
            } else {
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                item = AVPlayerItem(asset: asset)
            }
            if player == nil {
                player = AVPlayer(playerItem: item)
                player?.automaticallyWaitsToMinimizeStalling = true
                addObservers()
            } else {
                player?.replaceCurrentItem(with: item)
            }
            player?.rate = rate
            duration = 0
            position = 0
            appliedIntro = false
            if autoPlay { player?.play(); isPlaying = true } else { isPlaying = false }
            updateNowPlaying()

            // 自动缓存后面几集（book 已在方法开头 guard 出来）
            let prefetchCount = CacheManager.shared.autoCacheNext
            if prefetchCount > 0, localURL == nil {
                let list = episodes
                let from = index
                Task { await CacheManager.shared.prefetch(book: book, episodes: list, from: from, count: prefetchCount) }
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            isPlaying = false
        }
        isLoading = false
    }

    func toggle() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause(); isPlaying = false
        } else {
            if player.currentItem == nil { Task { await load(autoPlay: true) } }
            else { player.play(); isPlaying = true }
        }
        updateNowPlaying()
    }

    func next() {
        guard index + 1 < episodes.count else { return }
        index += 1
        if let book { LibraryStore.shared.markPlayed(book: book, episode: index, title: currentEpisode?.title ?? "") }
        Task { await load(autoPlay: true) }
    }

    func previous() {
        guard index > 0 else { return }
        index -= 1
        if let book { LibraryStore.shared.markPlayed(book: book, episode: index, title: currentEpisode?.title ?? "") }
        Task { await load(autoPlay: true) }
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        position = seconds
    }

    /// 快进/快退（秒），负数=后退
    func skip(_ seconds: Double) {
        let upper = duration > 1 ? duration - 1 : position + abs(seconds)
        let target = max(0, min(position + seconds, upper))
        seek(to: target)
    }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { player?.rate = r }
    }

    /// 跳过片头 / 片尾
    private func applySkipRules(at seconds: Double) {
        // 片头：每集只跳一次
        if !appliedIntro {
            if skipIntro > 1 && seconds < skipIntro {
                appliedIntro = true
                seek(to: skipIntro)
                return
            }
            if seconds >= skipIntro || skipIntro <= 1 { appliedIntro = true }
        }
        // 片尾：剩得比设定值还少就进下一集
        if skipOutro > 1, duration > skipOutro + 10, duration - seconds <= skipOutro, index + 1 < episodes.count {
            next()
        }
    }

    func setSleep(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepDeadline = nil
        guard let minutes else { return }
        sleepDeadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.player?.pause()
                self.isPlaying = false
                self.sleepDeadline = nil
                self.updateNowPlaying()
            }
        }
    }

    // MARK: 内部

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [])
        try? s.setActive(true)
    }

    private func addObservers() {
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            let seconds = t.seconds
            Task { @MainActor in
                self.position = seconds
                if let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                self.applySkipRules(at: seconds)
                self.updateNowPlaying()
            }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.stopAfterEpisode {
                    self.stopAfterEpisode = false
                    self.player?.pause()
                    self.isPlaying = false
                    self.updateNowPlaying()
                    return
                }
                self.next()
            }
        }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.toggle() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let self, let ev = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = ev.positionTime
            Task { @MainActor in self.seek(to: target) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let book, let ep = currentEpisode else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: ep.title.isEmpty ? book.title : ep.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.artist.isEmpty ? book.author : book.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - 收藏 / 历史 / 进度（本地持久化）

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    struct HistoryEntry: Codable, Identifiable {
        var id: String { book.bookURL }
        var book: Book
        var episodeIndex: Int
        var episodeTitle: String
        var updatedAt: Date
    }

    @Published private(set) var favorites: [Book] = []
    @Published private(set) var history: [HistoryEntry] = []

    private let favKey = "fav_books_v1"
    private let hisKey = "history_v1"

    init() { load() }

    func isFavorite(_ book: Book) -> Bool { favorites.contains { $0.bookURL == book.bookURL } }

    func toggleFavorite(_ book: Book) {
        if let i = favorites.firstIndex(where: { $0.bookURL == book.bookURL }) { favorites.remove(at: i) }
        else { favorites.insert(book, at: 0) }
        save()
    }

    func markPlayed(book: Book, episode: Int, title: String) {
        if let i = history.firstIndex(where: { $0.book.bookURL == book.bookURL }) {
            history[i].episodeIndex = episode
            history[i].episodeTitle = title
            history[i].updatedAt = Date()
            let e = history.remove(at: i)
            history.insert(e, at: 0)
        } else {
            history.insert(HistoryEntry(book: book, episodeIndex: episode, episodeTitle: title, updatedAt: Date()), at: 0)
        }
        if history.count > 200 { history = Array(history.prefix(200)) }
        save()
    }

    func clearHistory() { history = []; save() }

    func clearFavorites() { favorites = []; save() }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(favorites) { UserDefaults.standard.set(d, forKey: favKey) }
        if let d = try? enc.encode(history) { UserDefaults.standard.set(d, forKey: hisKey) }
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = UserDefaults.standard.data(forKey: favKey), let v = try? dec.decode([Book].self, from: d) { favorites = v }
        if let d = UserDefaults.standard.data(forKey: hisKey), let v = try? dec.decode([HistoryEntry].self, from: d) { history = v }
    }
}
