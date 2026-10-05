import Foundation

/// Presentation groups retain every physical root and its independent scan/connection state.
public struct LibraryRootGroup: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var roots: [LibraryRoot]
    public var rootIDs: [String] { roots.map(\.id) }
    public var connected: Bool { roots.allSatisfy { $0.status == "연결됨" } }
    public var help: String { roots.map { $0.path + " · " + $0.status }.joined(separator: "\n") }

    public static func grouping(_ roots: [LibraryRoot]) -> [Self] {
        var groups: [Self] = []
        for root in roots {
            let id = "root-group:" + TextKey.id(nameKey(root.name))
            if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].roots.append(root) }
            else { groups.append(Self(id: id, name: root.name, roots: [root])) }
        }
        return groups
    }

    public func collections(from sections: [LibrarySection]) -> [LibraryCollectionGroup] {
        let ids = Set(rootIDs)
        var groups: [LibraryCollectionGroup] = []
        for section in sections where ids.contains(section.rootID) {
            let key = "collection-group:" + TextKey.id(id, Self.nameKey(section.relativePath))
            if let index = groups.firstIndex(where: { $0.id == key }) { groups[index].sections.append(section) }
            else { groups.append(LibraryCollectionGroup(id: key, rootGroupID: id, name: section.name, sections: [section])) }
        }
        return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // Normalize Unicode and case, but preserve accents, punctuation and spaces in folder names.
    private static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

public struct LibraryCollectionGroup: Identifiable, Sendable {
    public var id: String
    public var rootGroupID: String
    public var name: String
    public var sections: [LibrarySection]
    public var sectionIDs: [String] { sections.map(\.id) }
}
