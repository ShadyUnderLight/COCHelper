import AppKit
import COCHelperCore

/// Issue #197：滚动路径图片解码的统一 signpost 埋点（app target）。
///
/// 包装 `NSImage(contentsOf:)`：只记录候选数（整数）与成功/失败（布尔 cache 负载），
/// 不记录 URL 敏感参数、完整唯一 ID 或账号原文。解码语义与直接
/// `lazy.compactMap { NSImage(contentsOf: $0) }.first` 完全一致（首个成功候选）。
enum PerformanceImageDecode {
    /// 依次解码候选链，返回首个成功者（与 `.lazy.compactMap(...).first` 同语义）。
    static func firstDecodable(_ urls: [URL]) -> NSImage? {
        let id = PerformanceSignpost.begin(.imageDecode, dataScale: urls.count, count: urls.count)
        let image = urls.lazy.compactMap { NSImage(contentsOf: $0) }.first
        PerformanceSignpost.end(.imageDecode, id: id, cacheHit: image != nil ? true : false)
        return image
    }
}
