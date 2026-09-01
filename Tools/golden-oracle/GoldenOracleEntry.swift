import CryptoKit
import Darwin
import Foundation
import COCHelperCore

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
    private static let protocolVersion = 1

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
            writeFailure(.malformedRequest)
            exit(2)
        }
    }

    private static func validate(_ request: OracleRequest) throws {
        guard request.protocolVersion == Self.protocolVersion else {
            throw OracleUsageError.unsupportedProtocol
        }
        guard !request.caseId.isEmpty, request.caseId.count <= 200 else {
            throw OracleUsageError.malformedRequest
        }
        guard ["canonical-json", "manual-queue-capacity", "manual-reconciliation-preview"].contains(
            request.operation
        ) else {
            throw OracleUsageError.unsupportedOperation
        }
    }

    private static func evaluate(_ request: OracleRequest) -> OracleResponse {
        let inputData = Data(request.source.utf8)
        let inputFingerprint = fingerprint(inputData)

        switch request.operation {
        case "canonical-json":
            return evaluateCanonicalJson(
                request: request,
                inputData: inputData,
                inputFingerprint: inputFingerprint
            )
        case "manual-queue-capacity":
            return evaluateManualHex(request: request, inputFingerprint: inputFingerprint) {
                try ManualDomainOracle.evaluate(source: request.source)
            }
        case "manual-reconciliation-preview":
            return evaluateManualHex(request: request, inputFingerprint: inputFingerprint) {
                try ManualReconciliationOracle.evaluate(source: request.source)
            }
        default:
            return OracleResponse(
                protocolVersion: Self.protocolVersion,
                caseId: request.caseId,
                ok: false,
                inputFingerprint: inputFingerprint,
                outputFingerprint: nil,
                value: nil,
                error: OracleError(kind: "rejected", code: "unsupportedOperation")
            )
        }
    }

    private static func evaluateCanonicalJson(
        request: OracleRequest,
        inputData: Data,
        inputFingerprint: String
    ) -> OracleResponse {
        do {
            let canonical = try CanonicalJSONValue.fromJSONData(inputData).canonicalized
            let canonicalData = canonical.canonicalData
            return OracleResponse(
                protocolVersion: Self.protocolVersion,
                caseId: request.caseId,
                ok: true,
                inputFingerprint: inputFingerprint,
                outputFingerprint: fingerprint(canonicalData),
                value: OracleValue(canonicalHex: hex(canonicalData)),
                error: nil
            )
        } catch {
            return OracleResponse(
                protocolVersion: Self.protocolVersion,
                caseId: request.caseId,
                ok: false,
                inputFingerprint: inputFingerprint,
                outputFingerprint: nil,
                value: nil,
                error: OracleError(kind: "rejected", code: "invalidJson")
            )
        }
    }

    private static func evaluateManualHex(
        request: OracleRequest,
        inputFingerprint: String,
        evaluate: () throws -> String
    ) -> OracleResponse {
        do {
            let canonicalHex = try evaluate()
            let outputData = dataFromHex(canonicalHex)
            return OracleResponse(
                protocolVersion: Self.protocolVersion,
                caseId: request.caseId,
                ok: true,
                inputFingerprint: inputFingerprint,
                outputFingerprint: fingerprint(outputData),
                value: OracleValue(canonicalHex: canonicalHex),
                error: nil
            )
        } catch {
            return OracleResponse(
                protocolVersion: Self.protocolVersion,
                caseId: request.caseId,
                ok: false,
                inputFingerprint: inputFingerprint,
                outputFingerprint: nil,
                value: nil,
                error: OracleError(kind: "rejected", code: "invalidManualDomain")
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

    private static func dataFromHex(_ value: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            let byte = UInt8(value[index..<next], radix: 16) ?? 0
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
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
