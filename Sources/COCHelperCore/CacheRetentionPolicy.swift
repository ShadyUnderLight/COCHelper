import Foundation

/// Issue #253 Phase A：分页累计缓存（warlog / capitalraidseasons）的保留上限。
///
/// 背景：load-more 把所有页累计进 `lastGood` 并全量写 UserDefaults，此前无
/// 任何上限（长期 retention 风险）。本 policy 用**记录数上限**约束增长：
/// - 记录数是确定、可审计、跨编码器稳定的度量（字节数需编码才能测量，
///   非确定且昂贵）；
/// - 上限取值远高于正常浏览深度（warlog 官方默认页 ~10 条；capitalraid
///   默认页数条/赛季），只拦截无节制翻页的累积。
///
/// 裁剪语义（与既有契约的组合）：
/// - 累计列表顺序恒为最新在前、最旧在后 → 只裁**最旧尾部**，保头部；
/// - 头部不动 → #211 row identity 的 seq 按 head 计数，存留行 ID 不漂移；
/// - 游标（before/after）指向服务端翻页位置，不属于本地数据，原样保留
///   （含"游标停滞清空"的终结语义）;
/// - 与 #231 overlap 合并组合安全：positional 匹配只落在存留后缀上
///   （命中 → 正确 payload 更新）；失配走 append 时追加条目必然全部比
///   存留尾部更旧（游标单调向更旧推进）→ 顺序正确、无重复。被裁掉的
///   旧数据经服务端翻页合法回归不算重复行。
public enum CacheRetentionPolicy {
    /// warlog 每 Tag 累计条目上限（≈20 个官方默认页；单条约含双方成员明细）。
    public static let maxWarLogItemsPerTag = 200

    /// capitalraidseasons 每 Tag 累计赛季上限（远超正常回溯深度；
    /// 单赛季含 members/attackLog/defenseLog 嵌套明细）。
    public static let maxCapitalSeasonsPerTag = 240

    /// 裁剪累计列表：超限时保头删尾（最旧），否则原样返回。
    /// `limit <= 0` 视为配置异常，no-op（不借 retention 清空数据）。
    public static func trimmedTail<T>(items: [T], limit: Int) -> [T] {
        guard limit > 0, items.count > limit else { return items }
        return Array(items.prefix(limit))
    }

    /// 裁剪分页包装：items 按 `trimmedTail` 收敛，游标原样保留。
    public static func trimmedPage<Item>(
        page: OfficialPaginatedPage<Item>,
        limit: Int
    ) -> OfficialPaginatedPage<Item> {
        guard limit > 0, page.items.count > limit else { return page }
        return OfficialPaginatedPage(
            items: Array(page.items.prefix(limit)),
            before: page.before,
            after: page.after
        )
    }
}
