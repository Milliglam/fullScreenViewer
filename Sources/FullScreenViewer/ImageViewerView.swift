import SwiftUI
import UniformTypeIdentifiers

/// フルスクリーンで画像を表示するビューア
struct ImageViewerView: View {
    @EnvironmentObject var imageStore: ImageStore
    @State private var isDropTargeted = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let nsImage = NSImage(contentsOf: imageStore.imageURLs[imageStore.currentIndex]) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // ページインジケータ（下部中央）
            VStack {
                Spacer()
                Text("\(imageStore.currentIndex + 1) / \(imageStore.imageURLs.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 12)
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { imageStore.previous(); return .handled }
        .onKeyPress(.rightArrow) { imageStore.next(); return .handled }
        .onKeyPress(.upArrow) { imageStore.previous(); return .handled }
        .onKeyPress(.downArrow) { imageStore.next(); return .handled }
        .onKeyPress(.escape) {
            exitFullScreen()
            imageStore.isViewerActive = false
            return .handled
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear {
            enterFullScreen()
            isFocused = true
        }
    }

    private func enterFullScreen() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApplication.shared.mainWindow else { return }
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }

    private func exitFullScreen() {
        guard let window = NSApplication.shared.mainWindow else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return }
            DispatchQueue.main.async {
                imageStore.loadFolder(url)
            }
        }
        return true
    }
}
