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
    @StateObject private var imageStore = ImageStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(imageStore)
        }
        .defaultSize(width: 480, height: 360)
    }
}
