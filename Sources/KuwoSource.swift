import Foundation

// MARK: - 酷我畅听（search.kuwo.cn + antiserver）
//
// 注意：这个接口的 `rformat=json` 其实是 Python 单引号字面量，不是合法 JSON，
// 所以用正则抽取字段。免费曲目可直接拿到完整 mp3；付费曲目（tpay=2）只会返回约 30 秒试听。

final class KuwoSource: BookSource {
    let id = "502efedf0613460a9967d9e86ce2b24c"
    let name = "酷我畅听"
    let host = "http://kuwo.cn/downtingshu"
    let desc = "酷我音乐/畅听。免费曲目可直接播放；标注「试听」的是付费内容，只能听 30 秒。"

    private let searchAPI = "http://search.kuwo.cn/r.s"
    private let antiAPI = "http://antiserver.kuwo.cn/anti.s"

    private func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .htmlDecoded
    }

    // MARK: 搜索

    func search(keyword: String, page: Int) async throws -> [Book] {
        let pn = max(0, (page - 1) * 20)
        let url = "\(searchAPI)?all=\(keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? keyword)&ft=music&itemset=web_2013&client=kt&pn=\(pn)&rn=20&rformat=json&encoding=utf8"
        let text = try await HTTPClient.text(url, referer: "http://www.kuwo.cn/")

        // 抽取每个条目（单引号字面量）
        let blocks = text.allMatches(#"\{[^{}]*\}"#)
        var books: [Book] = []
        var seenAlbum = Set<String>()
        for b in blocks {
            guard let albumId = b.firstMatch(#"'ALBUMID':\s*'(\d+)'"#), !albumId.isEmpty, albumId != "0" else { continue }
            if seenAlbum.contains(albumId) { continue }
            seenAlbum.insert(albumId)
            let name = unescape(b.firstMatch(#"'NAME':\s*'([^']*)'"#) ?? "")
            let album = unescape(b.firstMatch(#"'ALBUM':\s*'([^']*)'"#) ?? "")
            let artist = unescape(b.firstMatch(#"'ARTIST':\s*'([^']*)'"#) ?? "")
            let pic = b.firstMatch(#"'web_albumpic_short':\s*'([^']*)'"#) ?? b.firstMatch(#"'web_artistpic_short':\s*'([^']*)'"#) ?? ""
            let title = album.isEmpty ? name : album
            if title.isEmpty { continue }
            books.append(Book(sourceId: id,
                              title: title,
                              author: artist,
                              artist: artist,
                              cover: pic.isEmpty ? "" : "https://img4.kuwo.cn/star/albumcover/" + pic,
                              bookURL: "kuwo://album/\(albumId)",
                              intro: name))
        }
        return books
    }

    // MARK: 详情（专辑 → 曲目）

    func detail(for book: Book) async throws -> BookDetail {
        guard let albumId = book.bookURL.split(separator: "/").last.map(String.init) else {
            throw SourceError.parse("专辑 ID 缺失")
        }
        let url = "\(searchAPI)?stype=albuminfo&albumid=\(albumId)&rformat=json&encoding=utf8&rn=200&pn=0"
        let text = try await HTTPClient.text(url, referer: "http://www.kuwo.cn/")

        var out = BookDetail()
        out.author = book.author
        out.artist = book.artist
        let info = unescape(text.firstMatch(#"'info':\s*'([^']*)'"#) ?? "")
        if !info.isEmpty { out.intro = info }
        if let pic = text.firstMatch(#"'img':\s*'([^']*)'"#), !pic.isEmpty {
            out.cover = pic.hasPrefix("http") ? pic : "https://img4.kuwo.cn/star/albumcover/" + pic
        }

        var episodes: [Episode] = []
        for b in text.allMatches(#"\{[^{}]*\}"#) {
            guard let rid = b.firstMatch(#"'musicrid':\s*'MUSIC_(\d+)'"#) ?? b.firstMatch(#"'MUSICRID':\s*'MUSIC_(\d+)'"#) else { continue }
            let name = unescape(b.firstMatch(#"'name':\s*'([^']*)'"#) ?? b.firstMatch(#"'NAME':\s*'([^']*)'"#) ?? "")
            let tpay = b.firstMatch(#"'tpay':\s*'?(\d+)'?"#) ?? "0"
            let mark = (tpay == "0") ? "" : "（试听）"
            episodes.append(Episode(title: "\(name)\(mark)", url: "kuwo://song/\(rid)?tpay=\(tpay)"))
        }
        if episodes.isEmpty { throw SourceError.parse("这张专辑没取到曲目") }
        out.episodes = episodes
        return out
    }

    // MARK: 音频直链

    func audioURL(for episode: Episode) async throws -> URL {
        // kuwo://song/<rid>?tpay=0
        let rid = episode.url.firstMatch(#"song/(\d+)"#) ?? ""
        guard !rid.isEmpty else { throw SourceError.badURL(episode.url) }
        let api = "\(antiAPI)?type=convert_url3&rid=\(rid)&format=mp3&response=url"
        let text = try await HTTPClient.text(api, referer: "http://www.kuwo.cn/")
        guard let urlString = text.firstMatch(#""url"\s*:\s*"([^"]+)""#), !urlString.isEmpty else {
            throw SourceError.parse("酷我没返回播放地址（可能是付费内容）")
        }
        guard let url = URL(string: urlString) else { throw SourceError.badURL(urlString) }
        return url
    }
}
