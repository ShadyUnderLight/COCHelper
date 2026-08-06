import SwiftUI
import COCHelperCore
import COCHelperApp

/// 村庄详情的官方玩家数据卡片（独立来源，来源标签 official-api）。
struct OfficialPlayerCardView: View {
    @EnvironmentObject private var model: AppModel
    /// 本卡片数据来源的村庄（显式路由，不得读全局选中村庄）。
    let villageID: UUID

    /// 本卡片村庄的官方状态（nil = 不存在该 ID / 从未刷新）。
    private var villageState: OfficialAPIState? {
        model.officialState(for: villageID)
    }

    /// 本卡片村庄的官方 tag（nil = 无有效 tag，禁用刷新）。
    private var villageTag: String? {
        model.officialTag(for: villageID)
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                header
                statusLine

                if let state = villageState, let snapshot = state.lastGood {
                    snapshotSummary(snapshot: snapshot)
                    if !state.unrecognizedKeys.isEmpty {
                        Text("官方响应包含未识别字段：" + state.unrecognizedKeys.joined(separator: "、"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if villageState?.status == .never
                    || villageState?.status == .skipped
                    || villageState?.status == .failed {
                    Text("刷新失败或尚未获取不会影响本地导入数据与升级追踪。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack(spacing: 12) {
                    Button {
                        model.refreshOfficialPlayer(villageID: villageID)
                    } label: {
                        if model.isRefreshingOfficialPlayer(villageID: villageID) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("刷新官方数据", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cocAccent)
                    // 禁用跟随全局（其他村庄刷新时按钮不可点，避免点击被静默吞掉）；
                    // spinner 仍只跟自身村庄（by-ID），见上方 label 分支。
                    .disabled(
                        model.isRefreshingOfficialData
                            || model.isRefreshingOfficialPlayer(villageID: villageID)
                            || villageTag == nil
                    )

                    Spacer()

                    Button("设置 API Token") {
                        tokenSetupPresented = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
        .sheet(isPresented: $tokenSetupPresented) {
            APITokenSetupView()
        }
    }

    @State private var tokenSetupPresented = false

    /// 卡片头已降级为低视觉权重的来源标签（Issue #49 Task 4）：
    /// 玩家昵称只属于页面头部（Task 3），数据状态由下方 statusLine 负责，
    /// 不再出现与页面平级的 headline 标题。
    private var header: some View {
        Label("官方玩家数据 · official-api", systemImage: "antenna.radiowaves.left.and.right")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch villageState?.displayStatus ?? .never {
        case .never:
            if villageTag == nil {
                // 无有效 tag：刷新按钮同时被禁用，需要明确告诉用户原因与出路。
                VStack(alignment: .leading, spacing: 4) {
                    Label("缺少有效玩家 Tag，无法获取官方数据", systemImage: "tag.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("请先在账号数据页导入该村庄的账号 JSON")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !model.hasAPIToken {
                VStack(alignment: .leading, spacing: 4) {
                    Label("尚未获取官方数据", systemImage: "circle.dashed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("未配置 API Token，刷新将无法请求（点击“设置 API Token”）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("尚未获取官方数据", systemImage: "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .loading:
            Label("正在获取官方数据…", systemImage: "arrow.triangle.2.circlepath")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .success:
            if let fetchedAt = villageState?.fetchedAt {
                Label("已获取 · \(fetchedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Label("已获取官方数据", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        case .stale:
            if let fetchedAt = villageState?.fetchedAt {
                Label("数据已过期（上次获取 \(fetchedAt.formatted(date: .abbreviated, time: .shortened))）", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Label("获取失败", systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                if let reason = villageState?.lastErrorReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let fetchedAt = villageState?.fetchedAt {
                    Text("保留上次成功数据（\(fetchedAt.formatted(date: .abbreviated, time: .shortened))）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .skipped:
            Label(
                villageState?.lastErrorReason ?? "已跳过",
                systemImage: "arrow.uturn.backward.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    /// 快照摘要：分组 + 均分布局（Issue #49 Task 4 + 窗口级验收优化）。
    /// 昵称与 tag 只出现在页面头部（Task 3），此处不再重复。
    /// 布局：每组列数 = 组内项数，`flexible` 均分整行——宽窗口无尾部空白列、
    /// 窄窗口自动收窄（标签允许换行）。替代原 `adaptive`（4~6 项组在宽窗口
    /// 会留下 30%~60% 行尾空白，窗口级验收实测：1180pt 进度组右侧空白 692pt）。
    private func snapshotSummary(snapshot: OfficialPlayerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            summarySection(title: "进度", systemImage: "building.columns.fill", items: [
                ("大本营", snapshot.townHallLevel.map { "\($0) 级" }),
                // 武器未建造时官方返回 nil：显示 "—"（issue：缺失显示未知/未提供，不推断、不隐藏）。
                ("大本营武器", snapshot.townHallWeaponLevel.map { "\($0) 级" }),
                ("建筑大师基地", snapshot.builderHallLevel.map { "\($0) 级" }),
                ("经验等级", snapshot.expLevel.map { "\($0)" }),
            ])

            summarySection(title: "战绩", systemImage: "trophy.fill", items: [
                ("奖杯", snapshot.trophies.map { "\($0)" }),
                ("最佳奖杯", snapshot.bestTrophies.map { "\($0)" }),
                ("建筑大师基地奖杯", snapshot.builderBaseTrophies.map { "\($0)" }),
                ("战争星数", snapshot.warStars.map { "\($0)" }),
                ("进攻胜场", snapshot.attackWins.map { "\($0)" }),
                ("防守胜场", snapshot.defenseWins.map { "\($0)" }),
            ])

            summarySection(title: "部落与联赛", systemImage: "person.3.fill", items: [
                // Issue #49 要求"部落名称和 Tag"（评审 P2）：name/tag 各自可空
                // 独立展示——name 缺失但 tag 存在时仍显示 Tag，不做推断。
                ("部落", snapshot.clan?.name),
                ("部落 Tag", snapshot.clan?.tag),
                ("部落角色", roleLabel(snapshot.role)),
                ("当前联赛", snapshot.league?.name),
                ("建筑大师联赛", snapshot.builderBaseLeague?.name),
                ("战争偏好", warPreferenceLabel(snapshot.warPreference)),
            ])

            // 低频信息默认折叠（与页面「部落信息」分组同模式）。8 项固定 4 列
            // 两行满铺：列数整除项数，任何窗口宽度都无尾部空白。
            DisclosureGroup {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(minimum: 100), spacing: 12), count: 4),
                    alignment: .leading,
                    spacing: 12
                ) {
                    metric("捐兵", snapshot.donations.map { "\($0)" })
                    metric("受捐", snapshot.donationsReceived.map { "\($0)" })
                    metric("部落资本贡献", snapshot.clanCapitalContributions.map { "\($0)" })
                    metric("传奇奖杯", snapshot.legendStatistics?.legendTrophies.map { "\($0)" })
                    metric("当前赛季", seasonLabel(snapshot.legendStatistics?.currentSeason))
                    metric("最佳赛季", seasonLabel(snapshot.legendStatistics?.bestSeason))
                    metric("上赛季", seasonLabel(snapshot.legendStatistics?.previousSeason))
                    metric("最佳对战赛季", seasonLabel(snapshot.legendStatistics?.bestVersusSeason))
                }
                .padding(.top, 6)
            } label: {
                Label("更多玩家信息", systemImage: "ellipsis.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 分组区块：次级标题 + 一行均分网格（列数 = 项数，无尾部空白）。
    private func summarySection(
        title: String,
        systemImage: String,
        items: [(title: String, value: String?)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: items.map { _ in GridItem(.flexible(minimum: 100), spacing: 12) },
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(items, id: \.title) { item in
                    metric(item.title, item.value)
                }
            }
        }
    }

    /// 战争偏好：官方文档化取值映射（out/in/always/any/never），未知值原样透传（不推断）。
    private func warPreferenceLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw {
        case "out": return "未参战"
        case "in": return "可参战"
        case "always": return "随时可战"
        case "any": return "任意"
        case "never": return "从不"
        default: return raw
        }
    }

    /// 部落角色：官方文档化取值映射（leader/coLeader/admin/member），未知值原样透传（不推断）。
    private func roleLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw {
        case "leader": return "首领"
        case "coLeader": return "副首领"
        case "admin": return "长老"
        case "member": return "成员"
        default: return raw
        }
    }

    /// 传奇赛季行：`排名 · 奖杯`；rank 为 0（官方表示未上榜）时省略排名只显示奖杯；
    /// 字段全缺时返回 nil（显示 "—"，不推断）。
    private func seasonLabel(_ season: LegendSeason?) -> String? {
        guard let season else { return nil }
        let parts = [
            season.rank.flatMap { $0 > 0 ? "第 \($0) 名" : nil },
            season.trophies.map { "\($0) 杯" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func metric(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        // 撑满格子宽度：flexible 均分布局下无格内右侧空白（窗口级验收优化）。
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// API token 设置（只写入 Keychain，绝不进入 UserDefaults / 村庄 JSON）。
private struct APITokenSetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clash of Clans API Token")
                .font(.headline)
            Text("粘贴开发者门户（developer.clashofclans.com）生成的 JWT。Token 只写入 macOS Keychain，不会出现在村庄数据或日志中。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("API Token", text: $token)
                .textFieldStyle(.roundedBorder)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.hasPrefix("已") ? .green : .red)
            }

            HStack {
                if model.hasAPIToken {
                    Button("删除已保存 Token", role: .destructive) {
                        do {
                            try model.deleteAPIToken()
                            message = "已删除 Keychain 中的 Token"
                        } catch {
                            message = "删除失败：\(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Button("保存") {
                    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        message = "Token 不能为空"
                        return
                    }
                    do {
                        try model.saveAPIToken(trimmed)
                        message = "已保存到 Keychain"
                    } catch {
                        message = "保存失败：\(error.localizedDescription)"
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.cocAccent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
