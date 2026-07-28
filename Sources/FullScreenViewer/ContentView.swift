import SwiftUI

/// メインビュー：ビューア非表示時はドロップゾーン、表示時はフルスクリーンビューア
struct ContentView: View {
    /// ウィンドウごとに独立したストアを持つ（複数ウィンドウ同時再生のため）
    @StateObject private var imageStore = ImageStore()

    var body: some View {
        Group {
            if imageStore.isViewerActive {
                ImageViewerView()
            } else {
                DropZoneView()
            }
        }
        .environmentObject(imageStore)
    }
}
