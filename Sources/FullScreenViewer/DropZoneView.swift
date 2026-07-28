import SwiftUI
import UniformTypeIdentifiers

/// フォルダをドラッグ＆ドロップするためのエリア
struct DropZoneView: View {
    @EnvironmentObject var imageStore: ImageStore
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // 中央：ドロップ案内＋ランダム設定
            VStack(spacing: 16) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("フォルダまたはファイルをドロップ")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("フォルダごとにランダム", isOn: $imageStore.shuffleFolders)
                    Toggle("ファイルごとにランダム", isOn: $imageStore.shuffleFiles)
                }
                .toggleStyle(.checkbox)
                .font(.callout)
                .padding(.top, 8)
            }

            Spacer()

            // 下部：ショートカット一覧（小さく・控えめに・中央寄せ）
            shortcutLegend
                .padding(.bottom, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(20)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// ショートカット一覧（2カラム・内容幅で中央寄せ。内容は ImageViewerView.handleKeyEvent と一致）
    private var shortcutLegend: some View {
        Grid(alignment: .leading, horizontalSpacing: 80, verticalSpacing: 7) {
            GridRow { shortcutCell("← →", "ファイル送り");      shortcutCell("Space", "再生 / 一時停止") }
            GridRow { shortcutCell("Shift+← →", "5秒シーク");   shortcutCell("0–9", "10%位置へジャンプ") }
            GridRow { shortcutCell("⌘+← →", "30秒シーク");      shortcutCell("F", "フィット / フィル切替") }
            GridRow { shortcutCell("↑ ↓", "音量");             shortcutCell("Esc", "終了") }
            GridRow { shortcutCell("⌘N", "新規ウィンドウ") }
        }
    }

    /// キーキャップ＋説明の1セル
    private func shortcutCell(_ key: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .frame(minWidth: 68, alignment: .leading)
            Text(action)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            let sorted = urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            imageStore.loadMultiple(sorted)
        }
        return true
    }
}
