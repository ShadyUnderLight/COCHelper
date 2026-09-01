import Foundation

/// Issue #272：core 存储 baseline 与当前 baseline 是否可对账比较。
public enum ManualBaselineGate {
    public static func isBaselineReconciled(
        core: ManualUpgradeCore,
        currentBaseline: ManualBaselineReference?
    ) -> Bool {
        if core.itemStates.isEmpty && core.records.isEmpty {
            return true
        }
        guard let storedBaseline = core.baselineReference,
              let currentBaseline else {
            return false
        }
        return storedBaseline == currentBaseline
    }
}
