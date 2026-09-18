//
//  SupportedSites.swift
//  Downloady
//
//  The websites yt-dlp knows by name, from `yt-dlp --list-extractors`, and
//  the search Settings runs over them. Pure, so the tests pin it.
//

import Foundation

/// One website: an extractor and its sub-extractors (`tiktok`,
/// `tiktok:user`, …) folded into one entry.
public struct SupportedSite: Equatable, Hashable, Sendable, Identifiable {
    public let name: String
    /// Every extractor of the site is marked "(CURRENTLY BROKEN)".
    public let isBroken: Bool

    public var id: String { name.lowercased() }
}

public struct SupportedSites: Equatable, Sendable {
    public let sites: [SupportedSite]

    static let brokenSuffix = "(CURRENTLY BROKEN)"
    /// The generic extractor is the fallback that scans any page, not a site.
    static let excluded: Set<String> = ["generic"]

    public init(sites: [SupportedSite]) {
        self.sites = sites
    }

    /// Parses `yt-dlp --list-extractors`: one extractor per line.
    public init(listOutput: String) {
        struct Entry {
            var name: String
            var hasMainExtractor: Bool
            var allBroken: Bool
        }
        var entries: [String: Entry] = [:]
        var order: [String] = []
        for rawLine in listOutput.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            let broken = line.hasSuffix(Self.brokenSuffix)
            if broken {
                line = line.dropLast(Self.brokenSuffix.count).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            let base = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? line
            let key = base.lowercased()
            guard !Self.excluded.contains(key) else { continue }
            let isMain = !line.contains(":")
            if var entry = entries[key] {
                // The extractor without a colon names the site best ("TikTok").
                if isMain, !entry.hasMainExtractor {
                    entry.name = line
                    entry.hasMainExtractor = true
                }
                entry.allBroken = entry.allBroken && broken
                entries[key] = entry
            } else {
                entries[key] = Entry(name: isMain ? line : base, hasMainExtractor: isMain, allBroken: broken)
                order.append(key)
            }
        }
        sites = order.compactMap { entries[$0] }.map { SupportedSite(name: $0.name, isBroken: $0.allBroken) }
    }

    /// The sites whose name contains the query, closest first: a name that
    /// is the query, then one that starts with it, then the rest.
    public func matching(_ query: String) -> [SupportedSite] {
        let terms = Self.searchTerms(for: query)
        guard !terms.isEmpty else { return [] }
        func rank(_ site: SupportedSite) -> Int? {
            let name = site.name.lowercased()
            var best: Int?
            for term in terms {
                let score: Int? = name == term ? 0 : name.hasPrefix(term) ? 1 : name.contains(term) ? 2 : nil
                if let score { best = min(best ?? score, score) }
            }
            return best
        }
        var ranked: [(site: SupportedSite, rank: Int)] = []
        for site in sites {
            if let score = rank(site) { ranked.append((site, score)) }
        }
        ranked.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.site.name.localizedCaseInsensitiveCompare(rhs.site.name) == .orderedAscending
        }
        return ranked.map(\.site)
    }

    /// Second-level labels that are part of a country's suffix (`bbc.co.uk`).
    static let secondLevelSuffixes: Set<String> = ["co", "com", "net", "org", "ac", "gov", "edu", "ne", "or", "go"]

    /// What to look for: the query itself, or for a link or a domain, the
    /// host and its site name (`https://vm.tiktok.com/x` → `vm.tiktok.com`,
    /// `tiktok`).
    static func searchTerms(for query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        var host = trimmed
        if let url = URL(string: trimmed), let urlHost = url.host(), url.scheme != nil {
            host = urlHost.lowercased()
        }
        guard host.contains("."), !host.contains(" ") else { return [trimmed] }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        var labels = host.split(separator: ".").map(String.init)
        if labels.count > 1 { labels.removeLast() }
        if labels.count > 1, let last = labels.last, secondLevelSuffixes.contains(last) { labels.removeLast() }
        guard let site = labels.last, !site.isEmpty else { return [host] }
        return site == host ? [host] : [host, site]
    }
}
