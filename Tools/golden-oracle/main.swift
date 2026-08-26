import CryptoKit
import Foundation
import COCHelperCore

/// 迁移期 Swift golden oracle。只生成/核对参考结果，不得进入 Electron runtime 或发布包。
@main
enum GoldenOracle {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            fputs("用法: golden-oracle dump-canonical | verify-canonical | fingerprint <Fixtures 相对路径>\n", stderr)
            exit(2)
        }

        switch command {
        case "dump-canonical":
            print(try dumpCanonicalJSON())
        case "verify-canonical":
            try verifyCanonicalJSON()
            print("canonical JSON oracle 与冻结期望值一致")
        case "fingerprint":
            guard args.count == 2 else {
                fputs("用法: golden-oracle fingerprint <Fixtures 相对路径>\n", stderr)
                exit(2)
            }
            print(try fingerprint(relative: args[1]))
        default:
            fputs("未知命令: \(command)\n", stderr)
            exit(2)
        }
    }

    private static func dumpCanonicalJSON() throws -> String {
        let expectations = try canonicalExpectations()
        let payload: [String: Any] = ["expectations": expectations]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func verifyCanonicalJSON() throws {
        let actual = try canonicalExpectations()
        let expectedData = try Data(contentsOf: fixtureURL("canonical-json-expected.json"))
        let expectedRoot = try JSONSerialization.jsonObject(with: expectedData)
        guard
            let expectedMap = expectedRoot as? [String: Any],
            let expected = expectedMap["expectations"] as? [String: String]
        else {
            throw OracleError("canonical-json-expected.json 缺少 expectations。")
        }
        if actual != expected {
            throw OracleError("canonical JSON oracle 与冻结期望值不一致。")
        }
    }

    private static func canonicalExpectations() throws -> [String: String] {
        let samplesData = try Data(contentsOf: fixtureURL("canonical-json-samples.json"))
        let samplesRoot = try JSONSerialization.jsonObject(with: samplesData, options: [.fragmentsAllowed])
        guard
            let rootMap = samplesRoot as? [String: Any],
            let sampleMap = rootMap["samples"] as? [String: Any]
        else {
            throw OracleError("canonical-json-samples.json 缺少 samples。")
        }

        var expectations: [String: String] = [:]
        for (id, raw) in sampleMap.sorted(by: { $0.key < $1.key }) {
            let value = try CanonicalJSONValue.fromJSONObject(raw).canonicalized
            expectations[id] = hex(value.canonicalData)
        }
        return expectations
    }

    private static func fingerprint(relative: String) throws -> String {
        if relative.contains("\0") || relative.hasPrefix("/") || relative.contains("..") {
            throw OracleError("非法 fixture 路径：\(relative)")
        }
        let url = fixtureURL(relative)
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fixtureURL(_ name: String) -> URL {
        repoRoot()
            .appendingPathComponent("Tests")
            .appendingPathComponent("Golden")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

struct OracleError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}
