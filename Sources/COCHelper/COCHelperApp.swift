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
        .defaultSize(width: 1_180, height: 820)
        .windowResizability(.contentSize)
    }
}
