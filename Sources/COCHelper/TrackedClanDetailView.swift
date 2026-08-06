import SwiftUI
import COCHelperCore
import COCHelperApp

/// 手动跟踪部落的详情页（Issue #41）。
///
/// 数据全部来自按 Tag 共享状态层；与村庄详情页的 4 张卡片共用同一份
/// 缓存，不产生重复存储。刷新全部为显式按需（不自动轮询）。
struct TrackedClanDetailView: View {
    @EnvironmentObject private var model: AppModel
    let clanTag: String
    /// 删除跟踪成功后回调（由 ContentView 传入，用于复位侧边栏选择，
    /// 避免 selection 残留导致幽灵详情页）。
    var onRemove: (() -> Void)? = nil

    private var profile: TrackedClanProfile? {
        model.trackedClans.first { $0.clanTag == clanTag }
    }

    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ClanCardView(clanTag: clanTag)
                ClanWarCardView(clanTag: clanTag)
                WarLogCardView(clanTag: clanTag)
                CapitalRaidCardView(clanTag: clanTag)
            }
            .padding(16)
        }
        .navigationTitle(profile?.displayName ?? clanTag)
        .confirmationDialog(
            "删除部落跟踪？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                model.removeTrackedClan(tag: clanTag)
                onRemove?()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只移除跟踪关系，已获取的部落数据缓存会保留。")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile?.displayName ?? "（未命名部落）")
                    .font(.title2.weight(.semibold))
                Text(clanTag)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isCurrentVillageClan(clanTag) {
                Text("当前村庄所属")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.cocAccent.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.cocAccent)
            }
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("移除跟踪", systemImage: "trash")
            }
        }
    }
}
