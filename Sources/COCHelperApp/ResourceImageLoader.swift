import Foundation
import AppKit
import CoreGraphics
import ImageIO
import COCHelperCore

/// Issue #198：统一本地资源加载器（滚动路径图片解码边界）。
///
/// 职责：把 View body 里的同步 `NSImage(contentsOf:)` 读图/解码收敛到
/// 受控的后台 actor 边界，并建立 session 级资源缓存。
///
/// 契约：
/// - 输入是 `ResourceImageRequest`（候选 URL 链 + 目标像素尺寸 + backing
///   scale），候选链仍由投影层 `preferredAssetURLs` 提供，本组件不在 UI
///   重新拼接候选（Issue #198 要求 1）。
/// - 同一 URL + 像素尺寸 + scale 只解码一次：成功入 `imageCache`，
///   解码失败的候选入 `failedKeys`（失败候选缓存，避免每次 body 重算
///   重复探测不存在/不可解码的文件）。
/// - 候选顺序回退：按 `request.urls` 顺序逐候选尝试，首选解码失败自动
///   尝试次选；全部失败返回 nil（调用方回退 SF Symbol）。
/// - 取消安全：actor 方法在解码前/候选间检查 `Task.isCancelled`，被取消
///   的请求不启动/不继续解码；缓存按 key 隔离，取消的旧请求不可能把
///   结果串到新 key（视图层再用 `.task(id:)` + `Task.isCancelled` 守卫
///   防旧结果发布到新行）。
/// - 缩略解码：`defaultDecode` 用 ImageIO thumbnail 按目标像素尺寸解码，
///   不加载远大于显示尺寸的原图；缓存存的是缩略图本身（非原图再缩放），
///   内存上限 = `maxTotalCost`，cost = 像素字节估算。
/// - 生命周期：`ResourceImageLoader.shared` 为 app 级 session cache，
///   首次加载、滚动复用、切页、打开详情 Sheet 共用同一实例；LRU 淘汰
///   在插入超 `maxTotalCost` 时触发，同时清除被淘汰 key 的失败标记。
/// - 埋点：实际解码经 `PerformanceSignpost` `.imageDecode` 事件（#197
///   契约，`ok=%d` = 解码成功/失败），缓存命中不重复发事件，便于
///   Instruments 基线前后对比解码次数。
public struct ResourceImageKey: Hashable, Sendable {
    /// canonical 资源 URL（只来自 Bundle 资源，本组件不新增网络下载）。
    public let url: URL
    /// 目标像素宽度（pt × backing scale）。
    public let pixelWidth: Int
    /// 目标像素高度。
    public let pixelHeight: Int
    /// backing scale（如 Retina 2x），参与缓存 key，防止不同 scale 串用。
    public let scale: Double

    public init(url: URL, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        self.url = url
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }
}

/// 一次资源加载请求：候选 URL 链 + 目标像素尺寸 + backing scale。
/// 同时用作 SwiftUI `.task(id:)` 的身份（Hashable），候选链/尺寸/scale
/// 任一变化都会触发重新加载。
public struct ResourceImageRequest: Hashable, Sendable {
    /// 候选链（保持 `preferredAssetURLs` 的显示优先级顺序）。
    public let urls: [URL]
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: Double

    public init(urls: [URL], pixelWidth: Int, pixelHeight: Int, scale: Double) {
        self.urls = urls
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }
}

public actor ResourceImageLoader {
    private struct CacheEntry {
        let image: NSImage
        let cost: Int
    }

    /// 成功缓存（key = URL + 像素尺寸 + scale）。
    private var imageCache: [ResourceImageKey: CacheEntry] = [:]
    /// 失败候选缓存：解码失败的候选不重复探测。
    private var failedKeys = Set<ResourceImageKey>()
    /// LRU 顺序（队首最旧，队尾最新）。
    private var lruOrder: [ResourceImageKey] = []
    /// 当前缓存总字节估算。
    private var totalCost = 0
    /// 内存上限（字节）。默认 64MB，缩略图 48pt@2x ≈ 96×96×4 ≈ 36KB/张，
    /// ~500 行全量约 18MB，余量充足；超限按 LRU 淘汰。
    private let maxTotalCost: Int
    /// 解码实现（默认 ImageIO 缩略解码；测试可注入计数/控制实现）。
    private let decodeHandler: (URL, Int) -> NSImage?

    /// app 级 session cache：首次加载、滚动复用、切页、打开详情 Sheet 共用。
    public static let shared = ResourceImageLoader()

    public init(
        maxTotalCost: Int = 64 * 1024 * 1024,
        decodeHandler: @escaping (URL, Int) -> NSImage? = ResourceImageLoader.defaultDecode
    ) {
        self.maxTotalCost = maxTotalCost
        self.decodeHandler = decodeHandler
    }

    /// 按候选顺序加载首张可解码图片；全部失败返回 nil（SF Symbol 兜底）。
    /// 被取消的请求在解码前/候选间返回 nil，不产生实际解码。
    public func image(for request: ResourceImageRequest) async -> NSImage? {
        if Task.isCancelled { return nil }
        let maxPixel = max(request.pixelWidth, request.pixelHeight)
        for url in request.urls {
            let key = ResourceImageKey(
                url: url,
                pixelWidth: request.pixelWidth,
                pixelHeight: request.pixelHeight,
                scale: request.scale
            )
            if let cached = imageCache[key] {
                touch(key)
                return cached.image
            }
            if failedKeys.contains(key) {
                continue
            }

            // 实际解码：actor 边界（非主线程），带 #197 imageDecode signpost。
            let perfID = PerformanceSignpost.begin(.imageDecode, dataScale: maxPixel, count: 1)
            let image = decodeHandler(url, maxPixel)
            PerformanceSignpost.end(.imageDecode, id: perfID, succeeded: image != nil)
            if let image {
                insert(key, image, cost: imageCost(image))
                return image
            } else {
                failedKeys.insert(key)
            }
            if Task.isCancelled { return nil }
        }
        return nil
    }

    /// 插入成功缓存并按 LRU 淘汰超限。
    private func insert(_ key: ResourceImageKey, _ image: NSImage, cost: Int) {
        if imageCache[key] != nil {
            touch(key)
            return
        }
        imageCache[key] = CacheEntry(image: image, cost: cost)
        totalCost += cost
        lruOrder.append(key)
        evictIfNeeded()
    }

    /// 缓存命中时把 key 移到队尾（最近使用）。
    private func touch(_ key: ResourceImageKey) {
        if let index = lruOrder.firstIndex(of: key) {
            lruOrder.remove(at: index)
            lruOrder.append(key)
        }
    }

    /// 超过内存上限：从队首（最久未用）淘汰，并清除对应失败标记，
    /// 避免被淘汰资源因失败缓存残留而无法重新探测。
    private func evictIfNeeded() {
        while totalCost > maxTotalCost, !lruOrder.isEmpty {
            let key = lruOrder.removeFirst()
            if let entry = imageCache.removeValue(forKey: key) {
                totalCost -= entry.cost
            }
            failedKeys.remove(key)
        }
    }

    /// cost 估算：缓存缩略图的像素字节（宽×高×4）；无尺寸信息时按 1MB 保守值。
    private func imageCost(_ image: NSImage) -> Int {
        let reps = image.representations
        let width = reps.map(\.pixelsWide).max() ?? 0
        let height = reps.map(\.pixelsHigh).max() ?? 0
        if width > 0, height > 0 {
            return width * height * 4
        }
        return 1_048_576
    }

    /// 默认解码：ImageIO 缩略解码（maxPixelSize = 目标像素尺寸），
    /// 文件读取 + 解码在 actor 后台边界完成；缺失/损坏/目录路径 →
    /// nil（fail-closed，不崩溃、不联网）。
    /// 公开为纯函数（默认参数表达式需跨模块可见）；实际使用经 actor。
    public static func defaultDecode(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
