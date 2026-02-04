import Foundation
import SwiftSoup

// MARK: - Data Models
// CRITICAL FIX: Added 'Codable' here.
struct SearchResult: Identifiable, Hashable, Codable {
    var id = UUID()
    let title: String
    var displayTitle: String?
    let size: String
    let seeders: Int
    let leechers: Int
    let magnetLink: String
    let pageUrl: URL?
    let source: String
    let pubDate: Date?
}

enum ProviderStatus {
    case idle
    case checking
    case online(Int)
    case error(Int)
    case unreachable
}

// MARK: - Protocol
protocol SearchProvider: AnyObject {
    var name: String { get }
    var baseURL: String { get }
    func search(query: String) async throws -> [SearchResult]
    func checkConnection() async -> ProviderStatus
}

// Default Status Check Logic
extension SearchProvider {
    func checkConnection() async -> ProviderStatus {
        guard let url = URL(string: baseURL) else { return .unreachable }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse {
                return (200...299).contains(httpResp.statusCode) ? .online(httpResp.statusCode) : .error(httpResp.statusCode)
            }
            return .unreachable
        } catch {
            return .unreachable
        }
    }
}

// MARK: - 1. Pirate Bay
class PirateBayProvider: SearchProvider {
    let name = "TPB"
    let baseURL = "https://apibay.org"
    
    func search(query: String) async throws -> [SearchResult] {
        let safeQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://apibay.org/q.php?q=\(safeQuery)&cat=") else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        
        struct PBItem: Decodable {
            let id: String, name: String, size: String, seeders: String, leechers: String, info_hash: String
        }
        let items = try JSONDecoder().decode([PBItem].self, from: data)
        return items.compactMap { item in
            if item.info_hash == "0000000000000000000000000000000000000000" { return nil }
            let sizeInt = Int64(item.size) ?? 0
            return SearchResult(
                title: item.name, size: ByteCountFormatter.string(fromByteCount: sizeInt, countStyle: .file),
                seeders: Int(item.seeders) ?? 0, leechers: Int(item.leechers) ?? 0,
                magnetLink: "magnet:?xt=urn:btih:\(item.info_hash)&dn=\(item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")",
                pageUrl: URL(string: "https://thepiratebay.org/description.php?id=\(item.id)"), source: "TPB", pubDate: nil
            )
        }
    }
}

// MARK: - 2. 1337x (Mirror)
class One337xProvider: SearchProvider {
    let name = "1337x"
    let baseURL = "https://1337xx.to"
    
    func search(query: String) async throws -> [SearchResult] {
        let safeQuery = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        guard let url = URL(string: "\(baseURL)/search/\(safeQuery)/1/") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:146.0) Gecko/20100101 Firefox/146.0", forHTTPHeaderField: "User-Agent")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        let doc = try SwiftSoup.parse(html)
        let rows = try doc.select("table tbody tr")
        
        var results: [SearchResult] = []
        for row in rows {
            let nameEl = try row.select(".name a").last()
            let title = try nameEl?.text() ?? "Unknown"
            let link = try nameEl?.attr("href") ?? ""
            let fullLink = link.starts(with: "/") ? baseURL + link : link
            let seeds = try Int(row.select(".seeds").text()) ?? 0
            let leeches = try Int(row.select(".leeches").text()) ?? 0
            let size = try row.select(".size").text().components(separatedBy: CharacterSet.decimalDigits.inverted).first ?? "?"
            
            results.append(SearchResult(
                title: title, size: size, seeders: seeds, leechers: leeches,
                magnetLink: fullLink, pageUrl: URL(string: fullLink), source: "1337x", pubDate: nil
            ))
        }
        return results
    }
}

// MARK: - 3. RuTor
class RuTorProvider: SearchProvider {
    let name = "RuTor"
    let baseURL = "http://rutor.info"
    
    func search(query: String) async throws -> [SearchResult] {
        let safeQuery = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        guard let url = URL(string: "http://rutor.info/search/0/0/0/0/\(safeQuery)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (X11; Linux i686; rv:38.0) Gecko/20100101 Firefox/38.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let doc = try SwiftSoup.parse(html)
        let rows = try doc.select("#index table tr.gai, #index table tr.tum")
        
        var res: [SearchResult] = []
        for row in rows {
            let tds = try row.select("td")
            if tds.count < 3 { continue }
            let nameEl = try tds[1].select("a[href^='/torrent']")
            let title = try nameEl.text()
            let fullLink = "http://rutor.info" + (try nameEl.attr("href"))
            let magnet = try tds[1].select("a[href^='magnet']").attr("href")
            let size = try tds.get(2).text()
            let seeds = Int(try tds.get(3).select("span").text()) ?? 0
            let leech = Int(try tds.get(4).select("span").text()) ?? 0
            res.append(SearchResult(title: title, size: size, seeders: seeds, leechers: leech, magnetLink: magnet, pageUrl: URL(string: fullLink), source: "RuTor", pubDate: nil))
        }
        return res
    }
}

// MARK: - 4. DivxTotal
class DivxTotalProvider: SearchProvider {
    let name = "DivxTotal"
    let baseURL = "https://divxtotal.wtf"
    
    func search(query: String) async throws -> [SearchResult] {
        let safeQuery = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        guard let url = URL(string: "\(baseURL)/buscar/\(safeQuery)/page/1") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:146.0) Gecko/20100101 Firefox/146.0", forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL, forHTTPHeaderField: "Referer")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""
        let doc = try SwiftSoup.parse(html)
        let rows = try doc.select("table.fichas_tabla tr")
        
        var res: [SearchResult] = []
        for row in rows {
            if try row.select("th").count > 0 { continue }
            let nameEl = try row.select("a").first()
            let title = try nameEl?.text() ?? "Unknown"
            let link = try nameEl?.attr("href") ?? ""
            let tds = try row.select("td")
            var size = "?"
            if tds.count > 2 { size = try tds.get(2).text() }
            
            res.append(SearchResult(title: title, size: size, seeders: 0, leechers: 0, magnetLink: link, pageUrl: URL(string: link), source: "DivxTotal", pubDate: nil))
        }
        return res
    }
}

// MARK: - 5. DODI Repacks
class DodiProvider: SearchProvider {
    let name = "DODI"
    let baseURL = "https://dodi-repacks.site"
    
    private static var cache: [DodiItem]?
    struct DodiResp: Decodable { let downloads: [DodiItem] }
    struct DodiItem: Decodable { let title: String; let fileSize: String; let uris: [String]; let uploadDate: String }
    
    func search(query: String) async throws -> [SearchResult] {
        let items: [DodiItem]
        if let c = DodiProvider.cache { items = c } else {
            guard let url = URL(string: "https://hydralinks.cloud/sources/dodi.json") else { return [] }
            let (data, _) = try await URLSession.shared.data(from: url)
            items = (try JSONDecoder().decode(DodiResp.self, from: data)).downloads
            DodiProvider.cache = items
        }
        
        let lower = query.lowercased()
        let filtered = items.filter { $0.title.lowercased().contains(lower) }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        return filtered.map { item in
            let magnet = item.uris.first(where: { $0.hasPrefix("magnet:") }) ?? ""
            let page = item.uris.first(where: { $0.hasPrefix("http") }) ?? ""
            let date = formatter.date(from: item.uploadDate)
            
            return SearchResult(
                title: item.title, size: item.fileSize, seeders: 0, leechers: 0,
                magnetLink: magnet, pageUrl: URL(string: page), source: "DODI", pubDate: date
            )
        }
    }
}

// MARK: - 6. FitGirl
class FitGirlProvider: SearchProvider {
    let name = "FitGirl"
    let baseURL = "https://fitgirl-repacks.site"
    private static var cache: [FGItem]?
    struct FGResp: Decodable { let downloads: [FGItem] }
    struct FGItem: Decodable { let title: String, fileSize: String, uris: [String] }
    
    func search(query: String) async throws -> [SearchResult] {
        let items: [FGItem]
        if let c = FitGirlProvider.cache { items = c } else {
            guard let url = URL(string: "https://hydralinks.cloud/sources/fitgirl.json") else { return [] }
            let (data, _) = try await URLSession.shared.data(from: url)
            items = (try JSONDecoder().decode(FGResp.self, from: data)).downloads
            FitGirlProvider.cache = items
        }
        return items.filter { $0.title.lowercased().contains(query.lowercased()) }.map {
            SearchResult(title: $0.title, size: $0.fileSize, seeders: 0, leechers: 0, magnetLink: $0.uris.first(where:{$0.hasPrefix("magnet:")}) ?? "", pageUrl: nil, source: "FitGirl", pubDate: nil)
        }
    }
}

// MARK: - 7. CloudTorrents
class CloudTorrentsProvider: SearchProvider {
    let name = "Cloud"
    let baseURL = "https://cloudtorrents.com"
    
    func search(query: String) async throws -> [SearchResult] {
        let safeQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://api.cloudtorrents.com/search/?limit=50&query=\(safeQuery)") else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        
        struct CTResp: Decodable { let results: [CTRes] }
        struct CTRes: Decodable { let torrent: CTTor }
        struct CTTor: Decodable { let name: String, size: String?, seeders: Int, leechers: Int, torrentMagnet: String }
        
        let response = try JSONDecoder().decode(CTResp.self, from: data)
        return response.results.map {
            SearchResult(title: $0.torrent.name, size: $0.torrent.size ?? "?", seeders: $0.torrent.seeders, leechers: $0.torrent.leechers, magnetLink: $0.torrent.torrentMagnet, pageUrl: nil, source: "Cloud", pubDate: nil)
        }
    }
}

// MARK: - 8. Mikan
class MikanProvider: SearchProvider {
    let name = "Mikan"
    let baseURL = "https://mikanani.me"
    func search(query: String) async throws -> [SearchResult] {
        guard let url = URL(string: "https://mikanani.me/RSS/Search?searchstr=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        let xml = String(data: data, encoding: .utf8) ?? ""
        let doc = try SwiftSoup.parse(xml, "", Parser.xmlParser())
        let items = try doc.select("item")
        
        var res: [SearchResult] = []
        for item in items {
            let title = try item.select("title").text()
            let link = try item.select("link").text()
            let magnet = try item.select("enclosure").attr("url")
            let size = ByteCountFormatter.string(fromByteCount: Int64(try item.select("enclosure").attr("length")) ?? 0, countStyle: .file)
            res.append(SearchResult(title: title, size: size, seeders: 0, leechers: 0, magnetLink: magnet.isEmpty ? link : magnet, pageUrl: URL(string: link), source: "Mikan", pubDate: nil))
        }
        return res
    }
}

// MARK: - 9. DMHY
class DmhyProvider: SearchProvider {
    let name = "DMHY"
    let baseURL = "https://share.dmhy.org"
    func search(query: String) async throws -> [SearchResult] {
        guard let url = URL(string: "https://share.dmhy.org/topics/rss/rss.xml?keyword=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        let xml = String(data: data, encoding: .utf8) ?? ""
        let doc = try SwiftSoup.parse(xml, "", Parser.xmlParser())
        let items = try doc.select("item")
        
        var res: [SearchResult] = []
        for item in items {
            let title = try item.select("title").text()
            let link = try item.select("link").text()
            let magnet = try item.select("enclosure").attr("url")
            res.append(SearchResult(title: title, size: "?", seeders: 0, leechers: 0, magnetLink: magnet, pageUrl: URL(string: link), source: "DMHY", pubDate: nil))
        }
        return res
    }
}
