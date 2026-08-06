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
                    snapshotSummary(state: state, snapshot: snapshot)
                    Divider()
                    unitsSummary(snapshot: snapshot)
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

                HStack(spacing: 12) {
                    Button {
                        model.refreshOfficialPlayer(villageID: villageID)
                    } label: {
                        if model.isRefreshingOfficialData {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("刷新官方数据", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cocAccent)
                    .disabled(model.isRefreshingOfficialData || villageTag == nil)

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

    private var header: some View {
        HStack {
            Label("官方玩家数据", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
            Spacer()
            Text("official-api")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.cocAccent.opacity(0.18), in: Capsule())
                .foregroundStyle(Color.cocAccent)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch villageState?.displayStatus ?? .never {
        case .never:
            Label("尚未获取官方数据", systemImage: "circle.dashed")
                .font(.callout)
                .foregroundStyle(.secondary)
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

    private func snapshotSummary(state: OfficialAPIState, snapshot: OfficialPlayerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.name ?? "（无名玩家）")
                    .font(.title3.weight(.semibold))
                if let tag = snapshot.tag {
                    Text(tag)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    metric("大本营", snapshot.townHallLevel.map { "\($0) 级" })
                    metric("建筑大师基地", snapshot.builderHallLevel.map { "\($0) 级" })
                    metric("经验等级", snapshot.expLevel.map { "\($0)" })
                }
                GridRow {
                    metric("奖杯", snapshot.trophies.map { "\($0)" })
                    metric("最佳奖杯", snapshot.bestTrophies.map { "\($0)" })
                    metric("战争星数", snapshot.warStars.map { "\($0)" })
                }
                GridRow {
                    metric("进攻胜场", snapshot.attackWins.map { "\($0)" })
                    metric("防守胜场", snapshot.defenseWins.map { "\($0)" })
                    metric("部落", snapshot.clan?.name)
                }
                if let role = snapshot.role {
                    GridRow {
                        metric("部落角色", role)
                        metric("捐兵", snapshot.donations.map { "\($0)" })
                        metric("受捐", snapshot.donationsReceived.map { "\($0)" })
                    }
                }
                if let league = snapshot.league?.name {
                    GridRow {
                        metric("联赛", league)
                        metric("建筑大师联赛", snapshot.builderBaseLeague?.name)
                        metric("", nil)
                    }
                }
            }
        }
    }

    private func unitsSummary(snapshot: OfficialPlayerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("单位与装备（official-api）")
                .font(.subheadline.weight(.semibold))

            let units = [
                ("兵种", snapshot.troops),
                ("英雄", snapshot.heroes),
                ("法术", snapshot.spells),
                ("装备", snapshot.heroEquipment),
            ]
            ForEach(units, id: \.0) { title, items in
                if let items, !items.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading)
                        Text(items.map { item in
                            var label = item.name ?? "未知"
                            if let level = item.level {
                                label += " Lv.\(level)"
                            }
                            return label
                        }.joined(separator: " · "))
                        .font(.caption)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.callout.weight(.medium))
        }
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
