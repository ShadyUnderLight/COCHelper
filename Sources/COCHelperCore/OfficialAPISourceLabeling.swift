import Foundation

/// 官方数据来源标签的共享纯函数（ClanAPIState 与 ClanWarAPIState 共用，
/// 避免双份实现漂移）。
///
/// 契约：
/// - `success`（含 stale 时间派生）→ "official-api"
/// - `failed` 且保留 last-good → "cached-official-api"
/// - 其余（failed 无 last-good / never / loading / skipped）→ nil，UI 隐藏
public enum OfficialAPISourceLabeling {
    public static func label(status: OfficialAPIRequestStatus, hasLastGood: Bool) -> String? {
        switch status {
        case .success:
            return "official-api"
        case .failed:
            return hasLastGood ? "cached-official-api" : nil
        case .never, .loading, .skipped:
            return nil
        }
    }
}
