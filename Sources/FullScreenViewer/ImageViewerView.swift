import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// フルスクリーンでメディア（画像・ムービー）を表示するビューア
struct ImageViewerView: View {
    @EnvironmentObject var imageStore: ImageStore
    @State private var isDropTargeted = false
    @State private var player: AVPlayer?
    @State private var playerError = false
    @State private var isConverting = false
    @State private var isFillMode = false
    @State private var showUI = false
    @State private var hideTimer: Timer?
    @State private var mouseMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var navigationGeneration: Int = 0
    /// UI自動非表示までの秒数
    private let uiHideDelay: TimeInterval = 3.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if imageStore.currentIndex >= 0 && imageStore.currentIndex < imageStore.mediaURLs.count {
                let url = imageStore.mediaURLs[imageStore.currentIndex]

                if imageStore.isVideo(at: imageStore.currentIndex) {
                    if isConverting {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.white)
                            Text("変換中...")
                                .foregroundStyle(.white.opacity(0.5))
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    } else if playerError {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 48))
                                .foregroundStyle(.white.opacity(0.5))
                            Text("再生できないファイル形式です")
                                .foregroundStyle(.white.opacity(0.5))
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    } else if player != nil {
                        VideoPlayerView(player: player, fillMode: isFillMode)
                            .id("\(imageStore.currentIndex)-\(isFillMode)")
                    }
                } else if let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: isFillMode ? .fill : .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }

            // UI オーバーレイ（マウス操作時のみ表示）
            if showUI {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("\(imageStore.currentIndex + 1) / \(imageStore.mediaURLs.count)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                    }
                    .overlay(alignment: .trailing) {
                        Button(action: { isFillMode.toggle() }) {
                            Image(systemName: isFillMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(width: 32, height: 32)
                                .background(.white.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16)
                    }
                    .padding(.bottom, 12)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showUI)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear {
            enterFullScreen()
            updatePlayer()
            startMouseMonitor()
            startKeyMonitor()
        }
        .onDisappear {
            stopMouseMonitor()
        }
        .onChange(of: imageStore.currentIndex) {
            updatePlayer()
        }
    }

    // MARK: - マウス監視によるUI表示制御

    private func startMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { event in
            revealUI()
            return event
        }
    }

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return handleKeyEvent(event) ? nil : event
        }
    }

    private func stopMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        hideTimer?.invalidate()
        hideTimer = nil
    }

    /// キーイベント処理。trueを返すとイベントを消費
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        // 左矢印
        case 123:
            if modifiers.contains(.command) { seek(by: -30) }
            else if modifiers.contains(.shift) { seek(by: -5) }
            else { navigate { imageStore.previous() } }
            return true
        // 右矢印
        case 124:
            if modifiers.contains(.command) { seek(by: 30) }
            else if modifiers.contains(.shift) { seek(by: 5) }
            else { navigate { imageStore.next() } }
            return true
        // 上矢印
        case 126:
            adjustVolume(by: 0.1)
            return true
        // 下矢印
        case 125:
            adjustVolume(by: -0.1)
            return true
        // スペース
        case 49:
            togglePlayPause()
            return true
        // Escape
        case 53:
            cleanupPlayer()
            stopMouseMonitor()
            imageStore.cleanupTempFiles()
            exitFullScreen()
            imageStore.isViewerActive = false
            return true
        default:
            break
        }

        // 文字キー
        if let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "f":
                isFillMode.toggle()
                return true
            case "0": seekToPercent(0.0); return true
            case "1": seekToPercent(0.1); return true
            case "2": seekToPercent(0.2); return true
            case "3": seekToPercent(0.3); return true
            case "4": seekToPercent(0.4); return true
            case "5": seekToPercent(0.5); return true
            case "6": seekToPercent(0.6); return true
            case "7": seekToPercent(0.7); return true
            case "8": seekToPercent(0.8); return true
            case "9": seekToPercent(0.9); return true
            default: break
            }
        }

        return false
    }

    private func revealUI() {
        showUI = true
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: uiHideDelay, repeats: false) { _ in
            showUI = false
        }
    }

    // MARK: - プレイヤー制御

    private func navigate(_ action: () -> Void) {
        cleanupPlayer()
        action()
    }

    private func updatePlayer() {
        playerError = false
        isConverting = false
        // 世代をインクリメントして古い非同期処理を無効化
        navigationGeneration += 1
        let currentGen = navigationGeneration

        guard imageStore.isVideo(at: imageStore.currentIndex) else {
            player = nil
            return
        }

        if imageStore.needsConversion(at: imageStore.currentIndex) {
            if let cached = imageStore.playableURL(at: imageStore.currentIndex),
               cached != imageStore.mediaURLs[imageStore.currentIndex] {
                startPlayer(url: cached, generation: currentGen)
                return
            }

            let targetIndex = imageStore.currentIndex
            isConverting = true
            imageStore.convertVideo(at: targetIndex) { result in
                // 世代チェック：連打で先に進んでいたら無視
                guard navigationGeneration == currentGen else { return }
                switch result {
                case .success(let url):
                    isConverting = false
                    startPlayer(url: url, generation: currentGen)
                case .failure:
                    isConverting = false
                    playerError = true
                }
            }
        } else {
            let url = imageStore.mediaURLs[imageStore.currentIndex]
            startPlayer(url: url, generation: currentGen)
        }
    }

    private func startPlayer(url: URL, generation: Int) {
        // 世代チェック：古い呼び出しなら無視
        guard navigationGeneration == generation else { return }

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer

        observePlayerStatus(item, generation: generation)

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            autoAdvance()
        }

        newPlayer.play()
    }

    private func observePlayerStatus(_ item: AVPlayerItem, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard navigationGeneration == generation else { return }
            if item.status == .failed {
                playerError = true
                player = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard navigationGeneration == generation else { return }
            if item.status == .failed {
                playerError = true
                player = nil
            }
        }
    }

    private func autoAdvance() {
        cleanupPlayer()
        imageStore.next()
    }

    private func togglePlayPause() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// 指定秒数だけシーク
    private func seek(by seconds: Double) {
        guard let player = player, let duration = player.currentItem?.duration else { return }
        let current = player.currentTime().seconds
        let target = min(max(current + seconds, 0), duration.seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 動画の指定割合の位置へジャンプ
    private func seekToPercent(_ percent: Double) {
        guard let player = player, let duration = player.currentItem?.duration else { return }
        let target = duration.seconds * percent
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 音量調整（0.0〜1.0）
    private func adjustVolume(by delta: Float) {
        guard let player = player else { return }
        player.volume = min(max(player.volume + delta, 0.0), 1.0)
    }

    private func cleanupPlayer() {
        player?.pause()
        if let item = player?.currentItem {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: item)
        }
        player = nil
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
            DispatchQueue.main.async {
                cleanupPlayer()
                imageStore.load(url)
            }
        }
        return true
    }
}

/// AVPlayerLayerで映像を表示するだけのNSView（フォーカスを一切取らない）
class PlayerLayerView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    var videoFillMode: Bool = false {
        didSet {
            playerLayer.videoGravity = videoFillMode ? .resizeAspectFill : .resizeAspect
        }
    }
}

/// SwiftUIラッパー
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?
    let fillMode: Bool

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        view.videoFillMode = fillMode
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.player = player
        nsView.videoFillMode = fillMode
    }
}
