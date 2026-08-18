import SwiftUI
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
        .commands {
            CommandMenu("性能样本") {
                Button("加载性能样本（隐藏）") {
                    model.loadPerformanceSample()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        .defaultSize(width: 1_180, height: 820)
        .windowResizability(.contentSize)
    }
}
