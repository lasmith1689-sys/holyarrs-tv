import Foundation
import TVServices

/// Afterglow's Apple TV Top Shelf (Release 4): with Afterglow in the top row of the Home Screen, its Continue
/// Watching row shows there, and a card opens straight into the player (afterglow://play or afterglow://od).
/// The list and its pictures come from the PC (GET /continue), since an extension can't use HolyArrs' sign-in.
///
/// The PC's address: the app's default (RTXServer.defaultAddress). A changed address in Settings isn't seen here:
/// sharing it would need an App Group, which this build's signing doesn't set up.
final class ContentProvider: TVTopShelfContentProvider {
    static let pc = URL(string: "http://192.168.68.100:8787")!

    override func loadTopShelfContent() async -> TVTopShelfContent? {
        var req = URLRequest(url: ContentProvider.pc.appendingPathComponent("continue"))
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["items"] as? [[String: Any]], !list.isEmpty else { return nil }
        let items = list.prefix(12).compactMap(ContentProvider.item)
        guard !items.isEmpty else { return nil }
        let row = TVTopShelfItemCollection(items: items)
        row.title = "Continue Watching"
        return TVTopShelfSectionedContent(sections: [row])
    }

    static func item(_ e: [String: Any]) -> TVTopShelfSectionedItem? {
        guard let id = e["id"] as? String, let title = e["title"] as? String else { return nil }
        let t = (e["t"] as? Double) ?? 0
        let d = (e["duration"] as? Double) ?? 0
        let play = e["play"] as? [String: Any] ?? [:]
        var c = URLComponents()
        c.scheme = "afterglow"
        var q = [URLQueryItem(name: "t", value: String(format: "%.0f", t)), URLQueryItem(name: "d", value: String(format: "%.0f", d)),
                 URLQueryItem(name: "title", value: title)]
        if let od = play["od"] as? [String: Any] {
            c.host = "od"
            q += [URLQueryItem(name: "kind", value: od["kind"] as? String), URLQueryItem(name: "id", value: od["id"] as? String),
                  URLQueryItem(name: "ext", value: od["ext"] as? String)]
        } else if let film = play["film"] as? String {
            c.host = "play"
            let sub = e["subtitle"] as? String ?? ""
            q += [URLQueryItem(name: "id", value: film)]
            if e["kind"] as? String == "episode", !sub.isEmpty { q.append(URLQueryItem(name: "label", value: "\(title) · \(sub.components(separatedBy: " · ").first ?? sub)")) }
        } else {
            return nil
        }
        c.queryItems = q
        guard let link = c.url else { return nil }
        let item = TVTopShelfSectionedItem(identifier: id)
        item.title = title
        item.imageShape = .hdtv
        if let s = e["image"] as? String, let u = URL(string: s) {
            item.setImageURL(u, for: .screenScale1x)
            item.setImageURL(u, for: .screenScale2x)
        }
        if d > 0 { item.playbackProgress = min(1, max(0, t / d)) }
        item.playAction = TVTopShelfAction(url: link)
        item.displayAction = TVTopShelfAction(url: link)
        return item
    }
}
