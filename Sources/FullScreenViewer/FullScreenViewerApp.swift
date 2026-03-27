import SwiftUI

@main
struct FullScreenViewerApp: App {
    @StateObject private var imageStore = ImageStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(imageStore)
        }
        .defaultSize(width: 480, height: 360)
    }
}
