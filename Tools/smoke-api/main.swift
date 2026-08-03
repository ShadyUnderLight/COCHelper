import Darwin
import Foundation
import COCHelperCore

// COC API 连通性手动验证工具。
// token 只存在于进程内存，绝不打印；所有输出均不含 token / Authorization header / 响应体。

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// 1. 读取 token：COC_TOKEN 环境变量优先，否则 Keychain（nil = 未配置）。
let token: String?
if let envToken = ProcessInfo.processInfo.environment["COC_TOKEN"], !envToken.isEmpty {
    token = envToken
} else {
    do {
        token = try KeychainTokenStore().readToken()
    } catch {
        printError("FAILED: 无法读取 Keychain 凭证: \(error)")
        exit(2)
    }
}

// 2. 执行 smoke 检测（永不 throw）。
let client = CoAPIClient(tokenProvider: { token })
let result = await client.smoke()

// 3. 输出结果并设置退出码。
switch result {
case .success(let locationCount):
    print("SUCCESS: 连通性验证通过，locations=\(locationCount)")
    exit(0)
case .missingCredentials:
    printError("FAILED: 未配置凭证（COC_TOKEN 环境变量或 Keychain）")
    exit(2)
case .authorizationFailed(let reason):
    printError("FAILED: 授权失败（401/403）reason=\(reason)")
    exit(1)
case .rateLimited:
    printError("FAILED: 请求被限流（429）")
    exit(1)
case .notFound:
    printError("FAILED: 端点不存在（404）")
    exit(1)
case .serverError:
    printError("FAILED: 服务器错误（5xx）")
    exit(1)
case .networkFailure(let detail):
    printError("FAILED: 网络失败 detail=\(detail)")
    exit(1)
}
