import Foundation

public struct RelatedAlbum: Identifiable, Sendable {
    public var id: String { album.id }
    public var album: Album
    public var trackID: String
    public var reason: String
    public var rank: Int
}
public struct IdentityCandidate: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
}
public struct StoryEntity: Hashable, Sendable {
    public var kind: String
    public var id: String
    public var name: String
    public init(kind: String, id: String, name: String) { self.kind = kind; self.id = id; self.name = name }
    public var url: URL? {
        var parts = URLComponents(); parts.scheme = "resonance"; parts.host = kind; parts.path = "/" + id
        return parts.url
    }
}
public enum DiscoveryLink {
    public static func entity(_ url: URL) -> (kind: String, id: String)? {
        guard url.scheme == "resonance", let kind = url.host, ["album", "track", "artist", "work"].contains(kind),
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
              url.pathComponents.count == 2 else { return nil }
        return (kind, url.lastPathComponent)
    }
}
public struct StorySpan: Sendable {
    public var text: String
    public var url: URL?
}
public enum StoryLinker {
    /// Ambiguous labels remain text; longest whole-name matches win over shorter substrings.
    public static func spans(_ text: String, entities: [StoryEntity]) -> [StorySpan] {
        let grouped = Dictionary(grouping: entities, by: { TextKey.normalize($0.name) })
        let unique = grouped.values.compactMap { group -> StoryEntity? in
            Set(group.map { $0.kind + ":" + $0.id }).count == 1 ? group.first : nil
        }.filter { $0.name.count >= ($0.name.unicodeScalars.allSatisfy { $0.isASCII } ? 3 : 2) }.sorted { $0.name.count > $1.name.count }
        var ranges: [(Range<String.Index>, URL)] = []
        for entity in unique {
            guard let url = entity.url else { continue }
            var start = text.startIndex
            while start < text.endIndex, let range = text.range(of: entity.name, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
                start = range.upperBound
                let latin = entity.name.unicodeScalars.allSatisfy { $0.value < 0x0250 }
                let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
                let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
                if latin && (before?.isLetter == true || after?.isLetter == true) { continue }
                if !ranges.contains(where: { $0.0.overlaps(range) }) { ranges.append((range, url)) }
            }
        }
        var result: [StorySpan] = [], start = text.startIndex
        for (range, url) in ranges.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            if start < range.lowerBound { result.append(StorySpan(text: String(text[start..<range.lowerBound]), url: nil)) }
            result.append(StorySpan(text: String(text[range]), url: url)); start = range.upperBound
        }
        if start < text.endIndex { result.append(StorySpan(text: String(text[start...]), url: nil)) }
        return result
    }
}
