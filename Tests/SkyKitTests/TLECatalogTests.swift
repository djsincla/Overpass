import Foundation
import Testing
@testable import SkyKit

let issNewer = """
ISS (ZARYA)
1 25544U 98067A   08265.51782528 -.00002182  00000-0 -11606-4 0  2928
2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537
"""

let hubble = """
HST
1 20580U 90037B   08264.51782528  .00000500  00000-0  20000-4 0  9990
2 20580  28.4690 100.0000 0002500 100.0000 260.0000 15.00000000000000
"""

/// Serves canned responses by URL and counts requests.
final class FakeServer: @unchecked Sendable {
    var responses: [URL: String] = [:]
    var requests: [URL] = []
    var fetcher: TLECatalog.Fetcher {
        { url in
            self.requests.append(url)
            guard let body = self.responses[url] else { throw TLECatalogError.http(404) }
            return Data(body.utf8)
        }
    }
}

func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "tlecatalog-\(UUID().uuidString)")
}

@Suite struct TLECatalogTests {
    let a = TLESource(id: "a", name: "A", url: URL(string: "https://example.com/a")!)
    let b = TLESource(id: "b", name: "B", url: URL(string: "https://example.com/b")!)

    @Test func refreshMergesNewestEpochAndPersists() async throws {
        let dir = tempDirectory()
        let server = FakeServer()
        server.responses = [a.url: issTLE + "\n" + hubble, b.url: issNewer]
        let catalog = try TLECatalog(directory: dir, defaultSources: [a, b], fetch: server.fetcher)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        await catalog.refreshDue(now: t0)

        let entries = await catalog.entries
        #expect(entries.count == 2)
        #expect(entries["25544"]?.sourceIDs == ["a", "b"])
        // Day 265 element set beats day 264.
        #expect(entries["25544"]?.satellite.epoch == TLEParser.parse(issNewer)[0].epoch)
        // Its elements come from b, which had the newer set; Hubble only from a.
        #expect(entries["25544"]?.sourceID == "b")
        #expect(entries["20580"]?.sourceID == "a")
        #expect(await catalog.satellites(in: "b").map(\.noradID) == ["25544"])

        // A fresh catalog on the same directory works offline from the cache.
        let offline = try TLECatalog(directory: dir, fetch: { _ in throw URLError(.notConnectedToInternet) })
        #expect(await offline.entries.count == 2)
        #expect(await offline.status["a"]?.satelliteCount == 2)
    }

    @Test func failedRefreshKeepsCache() async throws {
        let server = FakeServer()
        server.responses = [a.url: issTLE]
        let catalog = try TLECatalog(directory: tempDirectory(), defaultSources: [a], fetch: server.fetcher)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try await catalog.refresh("a", now: t0)

        server.responses = [a.url: "No GP data found"]
        await #expect(throws: TLECatalogError.self) { try await catalog.refresh("a", now: t0 + 3 * 3600) }
        #expect(await catalog.entries.count == 1)
        #expect(await catalog.status["a"]?.lastError != nil)
    }

    @Test func respectsMinimumInterval() async throws {
        let server = FakeServer()
        server.responses = [a.url: issTLE]
        let catalog = try TLECatalog(directory: tempDirectory(), defaultSources: [a], fetch: server.fetcher)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try await catalog.refresh("a", now: t0)
        await #expect(throws: TLECatalogError.tooSoon(nextAllowed: t0 + 7200)) {
            try await catalog.refresh("a", now: t0 + 600)
        }
        // refreshDue also waits for both the source's interval and the 2-hour minimum.
        await catalog.refreshDue(now: t0 + 3600)
        #expect(server.requests.count == 1)
        await catalog.refreshDue(now: t0 + 13 * 3600)
        #expect(server.requests.count == 2)
    }

    @Test func disablingAndRemovingSources() async throws {
        let server = FakeServer()
        server.responses = [a.url: hubble, b.url: issTLE]
        let catalog = try TLECatalog(directory: tempDirectory(), defaultSources: [a, b], fetch: server.fetcher)
        await catalog.refreshDue()
        #expect(await catalog.entries.count == 2)
        try await catalog.setEnabled("a", false)
        #expect(await catalog.entries.keys.sorted() == ["25544"])
        try await catalog.remove("b")
        #expect(await catalog.entries.isEmpty)
    }

    @Test func importsLocalFile() async throws {
        let file = tempDirectory().appendingPathExtension("tle")
        try issTLE.write(to: file, atomically: true, encoding: .utf8)
        let catalog = try TLECatalog(directory: tempDirectory(), defaultSources: [],
                                     fetch: { try Data(contentsOf: $0) })
        let source = try await catalog.importFile(file, name: "My TLEs")
        #expect(await catalog.satellites(in: source.id).count == 1)
        #expect(await catalog.sources.map(\.name) == ["My TLEs"])
    }

    @Test func celesTrakURLs() {
        #expect(CelesTrak.groupURL("visual").absoluteString == "https://celestrak.org/NORAD/elements/gp.php?GROUP=visual&FORMAT=tle")
        #expect(TLESource.builtIn.filter { $0.enabled }.map { $0.id } == ["celestrak-visual", "celestrak-stations"])
    }
}
