import XCTest
@testable import COCHelperCore

final class SaturatingArithmeticTests: XCTestCase {
    func testDeterministicSignedExtremeBoundaries() {
        let round = -1

        assertAdd(Int.max, 1, round: round)
        assertAdd(Int.min, -1, round: round)
        assertSubtract(0, Int.min, round: round)
        assertMultiply(Int.min, -1, round: round)

        assertAdd(Int64.max, 1, round: round)
        assertAdd(Int64.min, -1, round: round)
        assertSubtract(Int64.max, Int64.min, round: round)
        assertMultiply(Int64.min, -1, round: round)
    }

    func testPropertyBasedSignedArithmeticMatchesReportingOverflow() {
        var rng = SeededRNG(seed: 0x78_5A_7E)

        for round in 0..<2_000 {
            let lhs = Int(bitPattern: UInt(rng.next()))
            let rhs = Int(bitPattern: UInt(rng.next()))
            let lhs64 = Int64(bitPattern: rng.next())
            let rhs64 = Int64(bitPattern: rng.next())

            assertAdd(lhs, rhs, round: round)
            assertMultiply(lhs, rhs, round: round)
            assertSubtract(lhs, rhs, round: round)
            assertAdd(lhs64, rhs64, round: round)
            assertSubtract(lhs64, rhs64, round: round)
            assertMultiply(lhs64, rhs64, round: round)
        }
    }

    private func assertAdd(_ lhs: Int, _ rhs: Int, round: Int) {
        let (exact, overflowed) = lhs.addingReportingOverflow(rhs)
        let actual = SaturatingArithmetic.add(lhs, rhs)
        let expectedValue: Int
        if overflowed {
            expectedValue = lhs >= 0 && rhs >= 0 ? Int.max : Int.min
        } else {
            expectedValue = exact
        }
        XCTAssertEqual(actual.value, expectedValue, "Int add round \(round)")
        XCTAssertEqual(actual.overflowed, overflowed, "Int add overflow flag round \(round)")
    }

    private func assertMultiply(_ lhs: Int, _ rhs: Int, round: Int) {
        let (exact, overflowed) = lhs.multipliedReportingOverflow(by: rhs)
        let actual = SaturatingArithmetic.multiply(lhs, rhs)
        let expectedValue: Int
        if overflowed {
            expectedValue = (lhs >= 0) == (rhs >= 0) ? Int.max : Int.min
        } else {
            expectedValue = exact
        }
        XCTAssertEqual(actual.value, expectedValue, "Int multiply round \(round)")
        XCTAssertEqual(actual.overflowed, overflowed, "Int multiply overflow flag round \(round)")
    }

    private func assertSubtract(_ lhs: Int, _ rhs: Int, round: Int) {
        let (exact, overflowed) = lhs.subtractingReportingOverflow(rhs)
        let actual = SaturatingArithmetic.subtract(lhs, rhs)
        let expectedValue: Int
        if overflowed {
            expectedValue = lhs >= 0 && rhs < 0 ? Int.max : Int.min
        } else {
            expectedValue = exact
        }
        XCTAssertEqual(actual.value, expectedValue, "Int subtract round \(round)")
        XCTAssertEqual(actual.overflowed, overflowed, "Int subtract overflow flag round \(round)")
    }

    private func assertAdd(_ lhs: Int64, _ rhs: Int64, round: Int) {
        let (exact, overflowed) = lhs.addingReportingOverflow(rhs)
        let actual = SaturatingArithmetic.add(lhs, rhs)
        let expectedValue: Int64
        if overflowed {
            expectedValue = lhs >= 0 && rhs >= 0 ? Int64.max : Int64.min
        } else {
            expectedValue = exact
        }
        XCTAssertEqual(actual.value, expectedValue, "Int64 add round \(round)")
        XCTAssertEqual(actual.overflowed, overflowed, "Int64 add overflow flag round \(round)")
    }

    private func assertMultiply(_ lhs: Int64, _ rhs: Int64, round: Int) {
        let (exact, overflowed) = lhs.multipliedReportingOverflow(by: rhs)
        let actual = SaturatingArithmetic.multiply(lhs, rhs)
        let expectedValue: Int64
        if overflowed {
            expectedValue = (lhs >= 0) == (rhs >= 0) ? Int64.max : Int64.min
        } else {
            expectedValue = exact
        }
        XCTAssertEqual(actual.value, expectedValue, "Int64 multiply round \(round)")
        XCTAssertEqual(actual.overflowed, overflowed, "Int64 multiply overflow flag round \(round)")
    }

    private func assertSubtract(_ lhs: Int64, _ rhs: Int64, round: Int) {
        let (exact, overflowed) = lhs.subtractingReportingOverflow(rhs)
        let actual = SaturatingArithmetic.subtract(lhs, rhs)
        let expectedValue: Int64
        if overflowed {
            expectedValue = lhs >= 0 && rhs < 0 ? Int64.max : Int64.min
        } else {
            expectedValue = exact
        }
        XCTAssertEqual(actual.value, expectedValue, "Int64 subtract round \(round)")
        XCTAssertEqual(actual.overflowed, overflowed, "Int64 subtract overflow flag round \(round)")
    }
}
