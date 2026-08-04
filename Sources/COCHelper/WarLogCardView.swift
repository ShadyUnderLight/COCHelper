import SwiftUI
import COCHelperCore
import COCHelperApp

/// 村庄详情页的战争日志卡片（分页，按需刷新）。
///
/// 状态语义（Issue #7 stage 3c）：
/// - 档案已知 `isWarLogPublic=false` → 显式"战争日志不公开"（不发起请求）
/// - 403 兜底：档案过期时请求失败显示失败原因
/// - lastGood = 累计页（items + 游标）；"加载更多"向后翻页，游标不前进即停
struct WarLogCardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                header
                statusContent
            }
        }
    }

    private var header: some View {
        HStack {
            Label("战争日志", systemImage: "list.bullet.clipboard.fill")
                .font(.headline)
            Spacer()
            if let label = model.currentWarLogState?.sourceLabel {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.cocAccent.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.cocAccent)
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if model.currentVillageClanStatusUnknown {
            Label("刷新官方玩家数据后可查看战争日志", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if model.currentVillageClanTag == nil {
            Label("不在部落中，没有战争日志", systemImage: "person.crop.circle.badge.questionmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if model.isCurrentWarLogKnownNotPublic,
                  !(model.currentWarLogState?.status == .success || model.currentWarLogState?.status == .failed) {
            // 显式状态：不伪造"没有历史战争"。
            // 仅当从未请求过时显示预判（force 请求后 success/failed 由
            // 状态分支呈现，避免 force 结果被预判 shadowing）。
            VStack(alignment: .leading, spacing: 8) {
                Label("该部落的战争日志不公开", systemImage: "eye.slash.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                HStack {
                    Button {
                        model.refreshCurrentWarLog(force: true)
                    } label: {
                        Label("仍要检查", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRefreshingWarLogData)
                    Spacer()
                }
            }
        } else if let state = model.currentWarLogState {
            statusLine(state)
            if let page = state.lastGood {
                warLogList(page)
                if model.currentWarLogHasMore {
                    loadMoreButton("加载更多战争")
                }
            }
            // 总是显示刷新按钮：failed（重试）与 stale（重新拉取）都需入口，
            // 避免"有 lastGood 但状态非 success"时卡片死锁（对齐 3b 模式）。
            // 档案已知"不公开"时用户点刷新意图明确 → force 绕过预判
            //（否则被 AppModel 预判静默拦截，按钮无任何效果）。
            refreshButton("刷新战争日志", force: model.isCurrentWarLogKnownNotPublic)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("尚未获取战争日志", systemImage: "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                refreshButton("查看战争日志")
            }
        }
    }

    private func refreshButton(_ title: String, force: Bool = false) -> some View {
        HStack {
            Button {
                if force {
                    model.refreshCurrentWarLog(force: true)
                } else {
                    model.refreshCurrentWarLog()
                }
            } label: {
                if model.isRefreshingWarLogData {
                    ProgressView().controlSize(.small)
                } else {
                    Label(title, systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.cocAccent)
            .disabled(model.isRefreshingWarLogData)
            Spacer()
        }
    }

    private func loadMoreButton(_ title: String) -> some View {
        HStack {
            Button {
                model.loadMoreCurrentWarLog()
            } label: {
                if model.isRefreshingWarLogData {
                    ProgressView().controlSize(.small)
                } else {
                    Label(title, systemImage: "ellipsis.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshingWarLogData)
            Spacer()
        }
    }

    @ViewBuilder
    private func statusLine(_ state: ClanWarLogAPIState) -> some View {
        switch state.displayStatus {
        case .success:
            if let fetchedAt = state.fetchedAt {
                Label("已获取 · \(fetchedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        case .stale:
            if let fetchedAt = state.fetchedAt {
                Label("数据已过期（上次获取 \(fetchedAt.formatted(date: .abbreviated, time: .shortened))）", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Label("获取失败", systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                if let reason = state.lastErrorReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if state.lastHTTPStatus == 403 {
                    // 403 可能是"战争日志不公开"（档案预判过期时兜底），
                    // 也可能是 invalidIp 等凭证问题（reason 原样透传可区分）。
                    Text("战争日志可能不公开（403）")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let fetchedAt = state.fetchedAt {
                    Text("保留上次成功数据（\(fetchedAt.formatted(date: .abbreviated, time: .shortened))）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .never, .loading, .skipped:
            EmptyView()
        }
    }

    private func warLogList(_ page: OfficialWarLogPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if page.items.isEmpty {
                Text("没有历史战争记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(page.items.enumerated()), id: \.offset) { _, entry in
                    warLogRow(entry)
                    if entry.endTime != page.items.last?.endTime {
                        Divider().padding(.leading, 40)
                    }
                }
            }
        }
    }

    private func warLogRow(_ entry: OfficialWarLogEntry) -> some View {
        HStack(spacing: 10) {
            resultBadge(entry.result)
            VStack(alignment: .leading, spacing: 2) {
                Text("对阵 " + (entry.opponent?.name ?? "未知部落"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let endTime = entry.endTime {
                    Text("结束：\(endTime)（官方时间）")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let stars = entry.clan?.stars {
                    Text("⭐ \(stars)")
                        .font(.callout.weight(.semibold))
                }
                if let destruction = entry.clan?.destructionPercentage {
                    Text("摧毁 \(destruction)%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func resultBadge(_ result: String?) -> some View {
        switch result {
        case "win":
            Text("胜").font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.green.opacity(0.18), in: Capsule())
                .foregroundStyle(.green)
        case "lose":
            Text("负").font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.red.opacity(0.18), in: Capsule())
                .foregroundStyle(.red)
        case "tie":
            Text("平").font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.gray.opacity(0.18), in: Capsule())
                .foregroundStyle(.secondary)
        default:
            Text("—").font(.caption).foregroundStyle(.secondary)
        }
    }
}
