import XCTest
import AppKit
@testable import COCHelperApp

/// Issue #198：统一资源加载器（ResourceImageLoader）的单元测试。
///
/// 只验证加载器契约（解码去重、缓存命中、候选回退、失败缓存、取消安全、
/// fail-closed），不验证 SwiftUI 视图接线（项目无 UI 单测惯例，改 UI 后
/// swift build 验证即可）。解码路径用注入的 TestDecoder 计数/控制，避免
/// 依赖真实 ImageIO 时序。
final class ResourceImageLoaderTests: XCTestCase {

    // MARK: - 测试辅助

    /// 可计数、可按 URL 前缀控制失败、每次返回新 NSImage 的注入解码器。
    /// @unchecked Sendable：计数器用 NSLock 保护，跨 actor 边界安全。
    private final class TestDecoder: @unchecked Sendable {
        private let lock = NSLock()
        private var _decodeCount = 0
        private let failingPrefix: String?

        init(failingPrefix: String? = nil) {
            self.failingPrefix = failingPrefix
        }

        var decodeCount: Int {
            lock.withLock { _decodeCount }
        }

        func handler(url: URL, maxPixel: Int) -> NSImage? {
            lock.lock()
            _decodeCount += 1
            let shouldFail = failingPrefix.map { url.lastPathComponent.hasPrefix($0) } ?? false
            lock.unlock()
            if shouldFail { return nil }
            // 每次调用返回新的 NSImage 实例，便于断言缓存命中（===）与跨 key 隔离（!==）。
            return NSImage(size: NSSize(width: maxPixel, height: maxPixel))
        }
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResourceImageLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 生成一个真实可解码的 PNG（默认 ImageIO 路径用）。
    private func makeTempPNG(size: Int, in dir: URL) throws -> URL {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        XCTAssertNotNil(rep)
        let url = dir.appendingPathComponent("img-\(UUID().uuidString).png")
        guard let data = rep?.representation(using: .png, properties: [:]) else {
            XCTFail("PNG 编码失败")
            return url
        }
        try data.write(to: url)
        return url
    }

    // MARK: - 解码去重与缓存命中

    func testSameRequestDecodesOnceAndCacheHitReturnsSameResource() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("icon-\(UUID().uuidString).png")
        let decoder = TestDecoder()
        let loader = ResourceImageLoader(decodeHandler: decoder.handler)

        let request = ResourceImageRequest(urls: [url], pixelWidth: 64, pixelHeight: 64, scale: 2.0)
        let first = await loader.image(for: request)
        let second = await loader.image(for: request)

        XCTAssertNotNil(first)
        // 缓存命中返回同一资源（同一 NSImage 实例），不重新读取/解码。
        XCTAssertTrue(second === first)
        // 相同 URL + 尺寸 + scale 连续请求只产生一次实际解码。
        XCTAssertEqual(decoder.decodeCount, 1)
    }

    // MARK: - 候选回退

    func testFirstCandidateDecodeFailureContinuesToNextCandidate() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let badURL = dir.appendingPathComponent("bad-\(UUID().uuidString).png")
        let goodURL = dir.appendingPathComponent("good-\(UUID().uuidString).png")
        let decoder = TestDecoder(failingPrefix: "bad")
        let loader = ResourceImageLoader(decodeHandler: decoder.handler)

        let request = ResourceImageRequest(urls: [badURL, goodURL], pixelWidth: 64, pixelHeight: 64, scale: 2.0)
        let image = await loader.image(for: request)

        XCTAssertNotNil(image)
        // 首选文件解码失败时继续尝试第二候选。
        XCTAssertEqual(decoder.decodeCount, 2)
    }

    func testAllCandidatesFailReturnsNilAndFailureIsCached() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad1 = dir.appendingPathComponent("bad-\(UUID().uuidString).png")
        let bad2 = dir.appendingPathComponent("bad-\(UUID().uuidString).png")
        let decoder = TestDecoder(failingPrefix: "bad")
        let loader = ResourceImageLoader(decodeHandler: decoder.handler)

        let request = ResourceImageRequest(urls: [bad1, bad2], pixelWidth: 64, pixelHeight: 64, scale: 2.0)
        let first = await loader.image(for: request)
        XCTAssertNil(first)
        let countAfterFirst = decoder.decodeCount
        XCTAssertEqual(countAfterFirst, 2)

        // 失败候选缓存：再次请求不重新探测/解码失败文件。
        let second = await loader.image(for: request)
        XCTAssertNil(second)
        XCTAssertEqual(decoder.decodeCount, countAfterFirst)
    }

    // MARK: - 缓存 key 隔离

    func testDifferentURLSizeOrScaleDoesNotCrossContaminate() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urlA = dir.appendingPathComponent("a-\(UUID().uuidString).png")
        let urlB = dir.appendingPathComponent("b-\(UUID().uuidString).png")
        let decoder = TestDecoder()
        let loader = ResourceImageLoader(decodeHandler: decoder.handler)

        let req1 = ResourceImageRequest(urls: [urlA], pixelWidth: 48, pixelHeight: 48, scale: 1.0)
        let req2 = ResourceImageRequest(urls: [urlA], pixelWidth: 96, pixelHeight: 96, scale: 2.0) // 同 URL 不同尺寸/scale
        let req3 = ResourceImageRequest(urls: [urlB], pixelWidth: 48, pixelHeight: 48, scale: 1.0) // 不同 URL

        let i1 = await loader.image(for: req1)
        let i2 = await loader.image(for: req2)
        let i3 = await loader.image(for: req3)

        XCTAssertNotNil(i1)
        XCTAssertNotNil(i2)
        XCTAssertNotNil(i3)
        // 不同版本(URL)/尺寸/scale 不发生错误串用：各自独立解码。
        XCTAssertEqual(decoder.decodeCount, 3)
        XCTAssertTrue(i2 !== i1)
        XCTAssertTrue(i3 !== i1)
    }

    // MARK: - 取消安全

    func testCancelledRequestDoesNotCorruptCacheNorCrossKeys() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urlA = dir.appendingPathComponent("a-\(UUID().uuidString).png")
        let urlB = dir.appendingPathComponent("b-\(UUID().uuidString).png")
        let decoder = TestDecoder()
        let loader = ResourceImageLoader(decodeHandler: decoder.handler)

        let reqA = ResourceImageRequest(urls: [urlA], pixelWidth: 64, pixelHeight: 64, scale: 2.0)
        let reqB = ResourceImageRequest(urls: [urlB], pixelWidth: 64, pixelHeight: 64, scale: 2.0)

        // 启动 A 后立即取消。
        let taskA = Task { await loader.image(for: reqA) }
        taskA.cancel()
        _ = await taskA.value

        // 取消的旧请求不能污染缓存：重新请求 A 仍返回正确资源。
        let imageA = await loader.image(for: reqA)
        XCTAssertNotNil(imageA)

        // 取消的旧请求不能覆盖新 key 的结果：B 返回自己的资源，与 A 不同。
        let imageB = await loader.image(for: reqB)
        XCTAssertNotNil(imageB)
        XCTAssertTrue(imageB !== imageA)

        // A 与 B 各恰好解码一次（取消不产生额外解码，也不串用）。
        XCTAssertEqual(decoder.decodeCount, 2)
    }

    // MARK: - fail-closed（真实 ImageIO 路径）

    func testMissingPathFailsClosed() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing-\(UUID().uuidString).png")
        let loader = ResourceImageLoader()

        let request = ResourceImageRequest(urls: [missing], pixelWidth: 64, pixelHeight: 64, scale: 2.0)
        let image = await loader.image(for: request)

        XCTAssertNil(image)
    }

    func testCorruptPNGFailsClosed() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let corrupt = dir.appendingPathComponent("corrupt-\(UUID().uuidString).png")
        // 截断/损坏的 PNG：以真实 PNG 签名开头但内容无效。
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: corrupt)
        let loader = ResourceImageLoader()

        let request = ResourceImageRequest(urls: [corrupt], pixelWidth: 64, pixelHeight: 64, scale: 2.0)
        let image = await loader.image(for: request)

        XCTAssertNil(image)
    }

    func testDirectoryPathFailsClosed() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = ResourceImageLoader()

        // 目录路径不是可解码文件：fail-closed，不崩溃。
        let request = ResourceImageRequest(urls: [dir], pixelWidth: 64, pixelHeight: 64, scale: 2.0)
        let image = await loader.image(for: request)

        XCTAssertNil(image)
    }

    func testHugeImageRequestFailsClosedWithoutCrash() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = try makeTempPNG(size: 512, in: dir)
        let loader = ResourceImageLoader()

        // 极大目标尺寸：缩略解码不会超过源图尺寸，不崩溃、不联网。
        let request = ResourceImageRequest(urls: [png], pixelWidth: 4096, pixelHeight: 4096, scale: 1.0)
        let image = await loader.image(for: request)

        XCTAssertNotNil(image)
    }
}
