import Foundation
import COCHelperApp
import COCHelperCore

/// Seeds an isolated HOME with 1005-wall before/after imports via AppModel
/// (same confirm path as the Account Data UI). Prints no JSON, tags, or tokens.
@main
struct HistoryMemorySeed {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 else {
            fputs("usage: history-memory-seed <before.json> <after.json>\n", stderr)
            exit(2)
        }
        let beforeURL = URL(fileURLWithPath: args[0])
        let afterURL = URL(fileURLWithPath: args[1])
        do {
            let before = try String(contentsOf: beforeURL, encoding: .utf8)
            let after = try String(contentsOf: afterURL, encoding: .utf8)
            try await MainActor.run {
                try importPair(before: before, after: after)
            }
            fputs("seeded 1005-wall history via AppModel import path\n", stderr)
        } catch {
            fputs("seed failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func importPair(before: String, after: String) throws {
        let model = AppModel()
        try importOnce(model, text: before, step: "before")
        try importOnce(model, text: after, step: "after-1")
        try importOnce(model, text: after, step: "after-2")
    }

    @MainActor
    private static func importOnce(_ model: AppModel, text: String, step: String) throws {
        model.importText = text
        model.parseAccountText()
        if let error = model.accountImportError, !error.isEmpty {
            throw SeedError.failed(step: step, message: error)
        }
        guard model.applyPendingAccountSnapshot() else {
            throw SeedError.failed(
                step: step,
                message: model.accountImportError ?? "applyPendingAccountSnapshot returned false"
            )
        }
    }
}

private enum SeedError: Error, LocalizedError {
    case failed(step: String, message: String)

    var errorDescription: String? {
        switch self {
        case .failed(let step, let message):
            "step \(step): \(message)"
        }
    }
}
