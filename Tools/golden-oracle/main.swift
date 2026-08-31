import CryptoKit
import Darwin
import Foundation
import COCHelperCore

private let protocolVersion = 1

private struct OracleRequest: Decodable {
    let protocolVersion: Int
    let caseId: String
    let operation: String
    let source: String
}

private struct OracleValue: Encodable {
    let canonicalHex: String
}

private struct OracleError: Encodable {
    let kind: String
    let code: String
}

private struct OracleResponse: Encodable {
    let protocolVersion: Int
    let caseId: String
    let ok: Bool
    let inputFingerprint: String
    let outputFingerprint: String?
    let value: OracleValue?
    let error: OracleError?
}

private enum OracleUsageError: Error {
    case malformedRequest
    case unsupportedProtocol
    case unsupportedOperation
}

@main
struct GoldenOracle {
    static func main() {
        do {
            let requestData = FileHandle.standardInput.readDataToEndOfFile()
            let request = try JSONDecoder().decode(OracleRequest.self, from: requestData)
            try validate(request)
            let response = evaluate(request)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let responseData = try encoder.encode(response)
            FileHandle.standardOutput.write(responseData)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch let error as OracleUsageError {
            writeFailure(error)
            exit(2)
        } catch {
            // 不把请求内容、fixture 或底层错误文本写入 stdout/stderr。
            writeFailure(.malformedRequest)
            exit(2)
        }
    }

    private static func validate(_ request: OracleRequest) throws {
        guard request.protocolVersion == protocolVersion else {
            throw OracleUsageError.unsupportedProtocol
        }
        guard !request.caseId.isEmpty, request.caseId.count <= 200 else {
            throw OracleUsageError.malformedRequest
        }
        guard request.operation == "canonical-json" else {
            throw OracleUsageError.unsupportedOperation
        }
    }

    private static func evaluate(_ request: OracleRequest) -> OracleResponse {
        let inputData = Data(request.source.utf8)
        let inputFingerprint = fingerprint(inputData)

        do {
            let canonical = try CanonicalJSONValue
                .fromJSONData(inputData)
                .canonicalized
            let canonicalData = canonical.canonicalData
            return OracleResponse(
                protocolVersion: protocolVersion,
                caseId: request.caseId,
                ok: true,
                inputFingerprint: inputFingerprint,
                outputFingerprint: fingerprint(canonicalData),
                value: OracleValue(canonicalHex: hex(canonicalData)),
                error: nil
            )
        } catch {
            // 解析拒绝是 parity 的业务结果；具体 Foundation 错误文本不属于协议。
            return OracleResponse(
                protocolVersion: protocolVersion,
                caseId: request.caseId,
                ok: false,
                inputFingerprint: inputFingerprint,
                outputFingerprint: nil,
                value: nil,
                error: OracleError(kind: "rejected", code: "invalidJson")
            )
        }
    }

    private static func fingerprint(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func writeFailure(_ error: OracleUsageError) {
        let message: String
        switch error {
        case .malformedRequest:
            message = "golden-oracle: malformed request"
        case .unsupportedProtocol:
            message = "golden-oracle: unsupported protocol"
        case .unsupportedOperation:
            message = "golden-oracle: unsupported operation"
        }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
