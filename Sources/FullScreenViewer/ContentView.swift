import SwiftUI

/// メインビュー：ビューア非表示時はドロップゾーン、表示時はフルスクリーンビューア
struct ContentView: View {
    @EnvironmentObject var imageStore: ImageStore

    var body: some View {
        Group {
            if imageStore.isViewerActive {
                ImageViewerView()
            } else {
                DropZoneView()
            }
        }
    }
}
