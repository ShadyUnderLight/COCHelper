import SwiftUI
import AppKit
import COCHelperApp

@main
struct COCHelperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("COC 助手") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        // Issue #197：隐藏性能样本加载入口（菜单命令，非 UI 可见元素）。
        // 仅当无村庄数据时生效，不覆盖用户真实数据；用于 Instruments 测量重放。
        // DEBUG 门控：只有 debug 构建编译这段菜单（Package.swift 为 COCHelper
        // target 定义 DEBUG 宏，release 构建不定义）→ 生产 app 菜单栏不出现。
        // 点击后检查返回值：失败时弹出明确反馈（不静默忽略）。
        #if DEBUG
        .commands {
            CommandMenu("性能样本") {
                Button("加载性能样本（隐藏）") {
                    if !model.loadPerformanceSample() {
                        let alert = NSAlert()
                        alert.messageText = "性能样本加载失败"
                        alert.informativeText = model.accountImportError
                            ?? "性能样本 fixtures 不可用或已有村庄数据。"
                        alert.runModal()
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        #endif
        .defaultSize(width: 1_180, height: 820)
        .windowResizability(.contentSize)
    }
}
