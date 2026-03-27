import SwiftUI

/// 画像一覧と現在のインデックスを管理する共有ストア
class ImageStore: ObservableObject {
    @Published var imageURLs: [URL] = []
    @Published var currentIndex: Int = 0
    @Published var isViewerActive: Bool = false

    private let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic"
    ]

    /// フォルダ内の画像をファイル名の自然順でロードする
    func loadFolder(_ url: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let images = contents
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !images.isEmpty else { return }

        imageURLs = images
        currentIndex = 0
        isViewerActive = true
    }

    func next() {
        if currentIndex < imageURLs.count - 1 {
            currentIndex += 1
        }
    }

    func previous() {
        if currentIndex > 0 {
            currentIndex -= 1
        }
    }
}
