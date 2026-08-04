import XCTest
@testable import COCHelperCore

final class OfficialAPIStateTests: XCTestCase {
    // MARK: - displayStatus 派生

    func testDisplayStatusMapsStorageStates() {
        func state(_ status: OfficialPlayerRequestStatus) -> OfficialAPIState {
            OfficialAPIState(status: status)
        }
        XCTAssertEqual(state(.never).displayStatus, .never)
        XCTAssertEqual(state(.loading).displayStatus, .loading)
        XCTAssertEqual(state(.failed).displayStatus, .failed)
        XCTAssertEqual(state(.skipped).displayStatus, .skipped)
    }

    func testSuccessIsStaleAfterThreshold() {
        var state = OfficialAPIState(status: .success)
        state.fetchedAt = Date(timeIntervalSinceNow: -OfficialAPIState.staleThreshold - 60)
        XCTAssertEqual(state.displayStatus, .stale)
    }

    func testSuccessIsFreshWithinThreshold() {
        var state = OfficialAPIState(status: .success)
        state.fetchedAt = Date(timeIntervalSinceNow: -60)
        XCTAssertEqual(state.displayStatus, .success)
    }

    func testSuccessWithoutFetchedAtIsNotStale() {
        let state = OfficialAPIState(status: .success)
        XCTAssertFalse(state.isStale)
        XCTAssertEqual(state.displayStatus, .success)
    }

    // MARK: - isStale(at:) 可注入时间

    func testIsStaleUsesInjectedNow() {
        var state = OfficialAPIState(status: .success)
        state.fetchedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(state.isStale(at: Date(timeIntervalSince1970: 1_000 + OfficialAPIState.staleThreshold + 1)))
        XCTAssertFalse(state.isStale(at: Date(timeIntervalSince1970: 1_000 + OfficialAPIState.staleThreshold - 1)))
    }

    // MARK: - property-based：随机 (fetchedAt, now) 与参照一致

    func testPropertyIsStaleMatchesReference() {
        var rng = SeededRandomGenerator(seed: 2024)
        for _ in 0..<2_000 {
            let fetchedAt: Date? = rng.randomInt(in: 0...2) == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(rng.randomInt(in: 0...9_000_000)))
            let now = Date(timeIntervalSince1970: TimeInterval(rng.randomInt(in: 0...9_000_000)))
            var state = OfficialAPIState(status: .success)
            state.fetchedAt = fetchedAt

            let reference: Bool
            if let fetchedAt {
                reference = now.timeIntervalSince(fetchedAt) > OfficialAPIState.staleThreshold
            } else {
                reference = false
            }
            XCTAssertEqual(
                state.isStale(at: now),
                reference,
                "isStale 与参照不一致: fetchedAt=\(String(describing: fetchedAt)) now=\(now)"
            )
        }
    }

    // MARK: - Codable

    func testOfficialAPIStateCodableRoundTrip() throws {
        var state = OfficialAPIState(status: .success)
        state.playerTag = "#ABC"
        state.fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        state.lastErrorReason = nil
        state.parserVersion = OfficialAPIState.currentParserVersion

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(OfficialAPIState.self, from: data)
        XCTAssertEqual(restored, state)
    }
}
