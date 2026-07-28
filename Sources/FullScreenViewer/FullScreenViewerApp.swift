import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // バンドルなしの実行ファイルをGUIアプリとして前面に表示する
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct FullScreenViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // ストアはContentView側でウィンドウごとに生成する（複数ウィンドウ同時再生のため）
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 480, height: 360)
    }
}
