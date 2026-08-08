import Foundation

/// Fixed-width integer arithmetic that preserves the nearest representable bound.
///
/// The group-card summary only accepts non-negative weights and catalog totals, but
/// the signed implementation also handles malformed negative inputs without wrapping.
/// Callers must propagate `overflowed` when a bounded value is not authoritative.
internal struct SaturatingArithmeticResult<Value: FixedWidthInteger> {
    let value: Value
    let overflowed: Bool
}

internal enum SaturatingArithmetic {
    static func add<Value: FixedWidthInteger>(
        _ lhs: Value,
        _ rhs: Value
    ) -> SaturatingArithmeticResult<Value> {
        let (value, overflowed) = lhs.addingReportingOverflow(rhs)
        guard overflowed else {
            return SaturatingArithmeticResult(value: value, overflowed: false)
        }
        let bound = lhs >= 0 && rhs >= 0 ? Value.max : Value.min
        return SaturatingArithmeticResult(value: bound, overflowed: true)
    }

    static func subtract<Value: FixedWidthInteger>(
        _ lhs: Value,
        _ rhs: Value
    ) -> SaturatingArithmeticResult<Value> {
        let (value, overflowed) = lhs.subtractingReportingOverflow(rhs)
        guard overflowed else {
            return SaturatingArithmeticResult(value: value, overflowed: false)
        }
        let bound = lhs >= 0 && rhs < 0 ? Value.max : Value.min
        return SaturatingArithmeticResult(value: bound, overflowed: true)
    }

    static func multiply<Value: FixedWidthInteger>(
        _ lhs: Value,
        _ rhs: Value
    ) -> SaturatingArithmeticResult<Value> {
        let (value, overflowed) = lhs.multipliedReportingOverflow(by: rhs)
        guard overflowed else {
            return SaturatingArithmeticResult(value: value, overflowed: false)
        }
        let bound = (lhs >= 0) == (rhs >= 0) ? Value.max : Value.min
        return SaturatingArithmeticResult(value: bound, overflowed: true)
    }
}
