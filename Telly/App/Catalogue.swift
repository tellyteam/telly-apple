import Foundation

/** A channel, film or series, as the catalogues hold them. */
protocol CatalogueItem: Identifiable, Hashable, Sendable where ID == String {
    var name: String { get }
    /** When the provider added it (epoch seconds; 0 if unknown). */
    var added: Double { get }
}

extension Channel: CatalogueItem {}
extension Series: CatalogueItem {}

/**
 * One of the provider's lists with what's worked out from it, once per update and off the main
 * thread (telly-sync PLAYBACK.md, Lists): screens never sort, de-duplicate or search the whole
 * catalogue while they draw.
 */
struct Catalogue<Item: CatalogueItem>: Sendable {
    let groups: [ItemGroup<Item>]
    let byId: [String: Item]
    /** Every item once (providers list some in several categories). */
    let all: [Item]
    /** [all]'s names folded for searching and filtering, in the same order. */
    let folded: [String]
    /** Newest first, for Home's "Recently added" rows. */
    let newest: [Item]
    /** Different for every update, so screens can tell one list from the next cheaply. */
    let version = UUID()

    init(_ groups: [ItemGroup<Item>]) {
        self.groups = groups
        var seen = Set<String>(), all: [Item] = [], byId: [String: Item] = [:]
        for g in groups {
            for item in g.items where seen.insert(item.id).inserted {
                all.append(item)
                byId[item.id] = item
            }
        }
        self.all = all
        self.byId = byId
        folded = all.map { Catalogue.fold($0.name) }
        newest = Array(all.filter { $0.added > 0 }.sorted { $0.added > $1.added }.prefix(24))
    }

    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }

    /**
     * Items whose names contain [query]: from [items] (one category), or from everything when nil,
     * where the names are already folded. Meant for a background thread.
     */
    func filter(_ query: String, in items: [Item]?) -> [Item] {
        let q = Catalogue.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return items ?? all }
        guard let items else { return zip(all, folded).filter { $0.1.contains(q) }.map(\.0) }
        return items.filter { Catalogue.fold($0.name).contains(q) }
    }
}
