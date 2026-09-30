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
    @Published var rate: Float = 1.0
    @Published var errorText: String?
    @Published var sleepDeadline: Date?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var sleepTimer: Timer?
    private var sourceForCurrent: BookSource?

    var currentEpisode: Episode? {
        guard index >= 0 && index < episodes.count else { return nil }
        return episodes[index]
    }

    /// 启动时调用：把音频会话设成后台可播放
    func prepareForBackgroundAudio() {
        configureAudioSession()
    }

    // MARK: 播放

    func play(book: Book, episodes: [Episode], startAt: Int = 0, autoPlay: Bool = true) {
        guard !episodes.isEmpty else { return }
        self.book = book
        self.episodes = episodes
        self.index = min(max(0, startAt), episodes.count - 1)
        self.sourceForCurrent = SourceRegistry.source(withId: book.sourceId)
        LibraryStore.shared.markPlayed(book: book, episode: self.index,
                                       title: episodes[min(max(0, startAt), episodes.count - 1)].title)
        Task { await load(autoPlay: autoPlay) }
    }

    private func load(autoPlay: Bool) async {
        guard let book, let ep = currentEpisode, let src = sourceForCurrent else { return }
        isLoading = true
        errorText = nil
        do {
            let url = try await src.audioURL(for: ep)
            configureAudioSession()
            let item = AVPlayerItem(url: url)
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
            if autoPlay { player?.play(); isPlaying = true } else { isPlaying = false }
            updateNowPlaying()
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

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { player?.rate = r }
    }

    func setSleep(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepDeadline = nil
        guard let minutes else { return }
        sleepDeadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.player?.pause()
                self?.isPlaying = false
                self?.sleepDeadline = nil
                self?.updateNowPlaying()
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
            Task { @MainActor in
                guard let self else { return }
                self.position = t.seconds
                if let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                self.updateNowPlaying()
            }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.next() }
        }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let ev = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: ev.positionTime) }
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

// MARK: - 已启用的源

@MainActor
final class SourceSettings: ObservableObject {
    static let shared = SourceSettings()
    @Published var enabled: Set<String> { didSet { UserDefaults.standard.set(Array(enabled), forKey: key) } }
    private let key = "enabled_sources_v1"

    init() {
        if let arr = UserDefaults.standard.array(forKey: key) as? [String] {
            enabled = Set(arr)
        } else {
            enabled = Set(SourceRegistry.all.map(\.id)) // 首次全开
        }
    }

    var enabledSources: [BookSource] { SourceRegistry.all.filter { enabled.contains($0.id) } }
}
