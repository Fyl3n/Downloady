//
//  SupportedSitesTests.swift
//  DownloadyTests
//
//  The list Settings searches: how `--list-extractors` folds into sites, and
//  what a name, a domain or a pasted link finds in it.
//

import Foundation
import Testing

@testable import Downloady

@Suite struct SupportedSitesTests {
    let sites = SupportedSites(listOutput: """
        9now.com.au
        generic
        generic:quoted-html
        TikTok
        tiktok:effect (CURRENTLY BROKEN)
        tiktok:user
        twitter (CURRENTLY BROKEN)
        twitter:spaces (CURRENTLY BROKEN)
        vimeo
        vimeo:album
        youtube
        youtube:tab

        """)

    @Test func foldsSubExtractorsIntoOneSite() {
        #expect(sites.sites.map(\.name) == ["9now.com.au", "TikTok", "twitter", "vimeo", "youtube"])
    }

    /// The generic extractor scans any page; it is not a website.
    @Test func leavesOutTheGenericExtractor() {
        #expect(!sites.sites.contains { $0.name.lowercased().hasPrefix("generic") })
    }

    @Test func aSiteIsBrokenOnlyWhenAllOfItIs() {
        #expect(sites.sites.first { $0.name == "twitter" }?.isBroken == true)
        #expect(sites.sites.first { $0.name == "TikTok" }?.isBroken == false)
    }

    @Test func findsASiteByName() {
        #expect(sites.matching("tik").map(\.name) == ["TikTok"])
        #expect(sites.matching("TIKTOK").map(\.name) == ["TikTok"])
        #expect(sites.matching("tube").map(\.name) == ["youtube"])
        #expect(sites.matching("nothing here").isEmpty)
        #expect(sites.matching("  ").isEmpty)
    }

    @Test func findsASiteByDomainOrLink() {
        #expect(sites.matching("https://www.youtube.com/watch?v=abc").map(\.name) == ["youtube"])
        #expect(sites.matching("vm.tiktok.com").map(\.name) == ["TikTok"])
        #expect(sites.matching("https://9now.com.au/a").map(\.name) == ["9now.com.au"])
        #expect(sites.matching("https://example.com/a").isEmpty)
    }

    @Test func theClosestNameComesFirst() {
        let list = SupportedSites(listOutput: "tube8\nyoutube\ntube\n")
        #expect(list.matching("tube").map(\.name) == ["tube", "tube8", "youtube"])
    }

    @Test func readsDomainsOutOfQueries() {
        #expect(SupportedSites.searchTerms(for: "https://www.bbc.co.uk/news/x") == ["bbc.co.uk", "bbc"])
        #expect(SupportedSites.searchTerms(for: "m.twitch.tv") == ["twitch.tv", "twitch"])
        #expect(SupportedSites.searchTerms(for: "youtu.be") == ["youtu.be", "youtu"])
        #expect(SupportedSites.searchTerms(for: "arte") == ["arte"])
    }
}
