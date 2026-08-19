import SwiftUI
import AppKit
import COCHelperApp

/// Issue #198：滚动路径图标的统一异步加载视图。
///
/// - body 只消费已加载资源或固定槽位 placeholder，不直接执行同步磁盘读图；
/// - 文件读取 + ImageIO 解码在 `ResourceImageLoader`（后台 actor 边界）完成；
/// - 同一 URL + 像素尺寸 + scale 只解码一次（loader session cache），
///   首次加载、滚动复用、切页、打开详情 Sheet 共用同一缓存；
/// - 候选链顺序回退与 SF Symbol 兜底语义由调用方传入（urls 顺序 +
///   systemImage/tint/symbolFont），本组件不重新拼接候选；
/// - 加载期间固定图标槽位（placeholder 与真实图标同 frame），行高不漂移；
/// - `.task(id:)` 取消旧请求 + `Task.isCancelled` 守卫，防止旧资源发布到
///   新项目/新版本行。
struct ResourceIconView: View {
    /// 候选 URL 链（保持 `preferredAssetURLs` 的显示优先级顺序）。
    let urls: [URL]
    /// 图标槽位边长（pt）；像素尺寸 = slotSize × displayScale。
    let slotSize: CGFloat
    /// SF Symbol 兜底图标。
    let systemImage: String
    /// SF Symbol 兜底着色。
    let tint: Color
    /// SF Symbol 兜底字号。
    let symbolFont: Font
    /// PNG 已渲染时的 hover 提示（缺失原因/来源，见各调用点 pngIconHelp）。
    let pngHelp: String
    /// SF Symbol 分支的 hover 提示（缺失原因/兜底文案）。
    let sfHelp: String

    @Environment(\.displayScale) private var displayScale
    @State private var loadedImage: NSImage?

    /// 加载请求：候选链 + 目标像素尺寸 + backing scale（缓存 key 与 task id）。
    private var request: ResourceImageRequest {
        let pixel = Int(slotSize * displayScale)
        return ResourceImageRequest(urls: urls, pixelWidth: pixel, pixelHeight: pixel, scale: displayScale)
    }

    var body: some View {
        Group {
            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: slotSize, height: slotSize)
            } else {
                Image(systemName: systemImage)
                    .font(symbolFont)
                    .foregroundStyle(tint)
                    .frame(width: slotSize, height: slotSize)
            }
        }
        .help(loadedImage != nil ? pngHelp : sfHelp)
        .task(id: request) {
            // 请求（候选链/尺寸/scale）变化时先清空旧图：稳定行 ID 下资源变化时
            // 不得短暂显示旧资源（Issue #198 review P2）。
            loadedImage = nil
            let image = await ResourceImageLoader.shared.image(for: request)
            // 取消守卫：旧请求的结果不得发布到新行/新版本。
            if !Task.isCancelled {
                loadedImage = image
            }
        }
    }
}
