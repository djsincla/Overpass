import Foundation
import Testing
@testable import TestFlightKit

@Suite struct WatchTests {
    @Test func reportsOnlyBuildsThatChanged() {
        let old = ["6": "IN_BETA_TESTING", "7": "WAITING_FOR_BETA_REVIEW", "8": "WAITING_FOR_BETA_REVIEW"]
        let new = ["6": "IN_BETA_TESTING", "7": "IN_BETA_TESTING", "8": "BETA_REJECTED"]
        #expect(Watch.changes(from: old, to: new) == [
            "build 7: waiting for beta review → in beta testing",
            "build 8: waiting for beta review → beta rejected",
        ])
        #expect(Watch.changes(from: new, to: new).isEmpty)
    }

    @Test func newBuildIsQuietUntilReviewed() {
        #expect(Watch.changes(from: [:], to: ["9": "WAITING_FOR_BETA_REVIEW"]).isEmpty)
        #expect(Watch.changes(from: [:], to: ["9": "BETA_APPROVED"]) == ["build 9: beta approved"])
    }

    @Test func buildsInNumericOrder() {
        let changes = Watch.changes(from: ["9": "IN_BETA_REVIEW", "10": "IN_BETA_REVIEW"],
                                    to: ["9": "IN_BETA_TESTING", "10": "IN_BETA_TESTING"])
        #expect(changes.map { $0.prefix(8) } == ["build 9:", "build 10"])
    }

    @Test func agentRunsWatchOnASchedule() {
        let agent = Watch.agent(executable: "/bin/testflight", arguments: ["--bundle-id", "x"], interval: 7200)
        #expect(agent["ProgramArguments"] as? [String] == ["/bin/testflight", "watch", "--bundle-id", "x"])
        #expect(agent["StartInterval"] as? Int == 7200)
        #expect(agent["Label"] as? String == Watch.label)
    }
}
