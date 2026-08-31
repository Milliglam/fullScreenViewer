import SwiftUI
import AVKit
import CoreImage
import UniformTypeIdentifiers

/// フルスクリーンでメディア（画像・ムービー）を表示するビューア
struct ImageViewerView: View {
    @EnvironmentObject var imageStore: ImageStore
    @State private var isDropTargeted = false
    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?
    @State private var playerError = false
    @State private var isConverting = false
    @State private var isFillMode = false
    @State private var showUI = false
    @State private var hideTimer: Timer?
    @State private var mouseMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var navigationGeneration: Int = 0
    /// このビューをホストするウィンドウ（複数ウィンドウでのイベント分離・フルスクリーン制御に使用）
    @State private var hostWindow: NSWindow?
    /// 再生進捗（0.0〜1.0）
    @State private var progress: Double = 0
    @State private var timeObserver: Any?
    /// 一時停止中スクリーンショット用のフレーム取得口（アイテム生成時に添付）
    @State private var videoOutput: AVPlayerItemVideoOutput?
    /// 現在トラックの回転メタデータ（VideoOutputのバッファには適用されないため保存時に自前で適用）
    @State private var videoTransform: CGAffineTransform = .identity
    /// スクリーンショット保存結果の通知トースト
    @State private var captureToast: String?
    @State private var toastTimer: Timer?
    /// UI自動非表示までの秒数
    private let uiHideDelay: TimeInterval = 3.0
    /// スクリーンショット描画用の共有CIContext（生成コストが高いためキャプチャごとに作らない）
    private static let screenshotCIContext = CIContext()

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
                            Text("準備中...")
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
                        Text("\(imageStore.currentIndex + 1) / \(imageStore.mediaURLs.count) · \(currentFileName)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 64)   // 右端のフィルモードボタンと重ならない余白
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
                    .padding(.bottom, 18)   // 再生バー（4px）と重ならない位置
                }
                .transition(.opacity)
            }

            // スクリーンショット保存結果のトースト
            if let toast = captureToast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(.bottom, 48)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { progressBar }
        .background(WindowAccessor(window: $hostWindow))
        .animation(.easeInOut(duration: 0.3), value: showUI)
        .animation(.easeInOut(duration: 0.2), value: captureToast)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear {
            updatePlayer()
            startMouseMonitor()
            startKeyMonitor()
        }
        .onDisappear {
            // Escでもウィンドウクローズでも同じ解放保証を通す
            shutdownViewer()
        }
        .onChange(of: imageStore.currentIndex) {
            updatePlayer()
        }
        .onChange(of: hostWindow) {
            // WindowAccessorがウィンドウを取得した時点で自ウィンドウだけをフルスクリーン化
            enterFullScreenIfNeeded()
        }
    }

    /// ビューア終了時の共通後始末（Esc・ウィンドウクローズのどの経路でも同じ解放を保証。冪等）
    private func shutdownViewer() {
        cleanupPlayer()
        stopMouseMonitor()
        imageStore.cleanupTempFiles()
    }

    /// 現在表示中のファイル名
    private var currentFileName: String {
        guard imageStore.currentIndex >= 0 && imageStore.currentIndex < imageStore.mediaURLs.count else { return "" }
        return imageStore.mediaURLs[imageStore.currentIndex].lastPathComponent
    }

    /// 画面最下部の再生バー（視覚は下端4px・クリック領域は最下部20px。
    /// クリック位置の割合＝動画の該当位置へシークする。ドラッグシークはなし）
    @ViewBuilder
    private var progressBar: some View {
        if player != nil {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    Color.clear
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 4)
                    Rectangle()
                        .fill(.white.opacity(0.4))
                        .frame(width: geo.size.width * progress, height: 4)
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    guard geo.size.width > 0 else { return }
                    seekToPercent(min(max(value.location.x / geo.size.width, 0), 1))
                })
            }
            .frame(height: 20)
            .animation(.linear(duration: 0.1), value: progress)
        }
    }

    // MARK: - マウス監視によるUI表示制御

    private func startMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { event in
            // ローカルモニターはアプリ全体に届くため、自ウィンドウのイベントだけ処理する
            guard event.window === hostWindow else { return event }
            revealUI()
            return event
        }
    }

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // フォーカス中の自ウィンドウ宛のキーだけ処理（他ウィンドウのビューアには反応させない）
            guard event.window === hostWindow else { return event }
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
        toastTimer?.invalidate()
        toastTimer = nil
    }

    /// キーイベント処理。trueを返すとイベントを消費
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        // 左矢印
        case 123:
            if modifiers.contains(.command) { seek(by: -30) }
            else if modifiers.contains(.shift) { seek(by: -5) }
            else { navigate(forward: false) }
            return true
        // 右矢印
        case 124:
            if modifiers.contains(.command) { seek(by: 30) }
            else if modifiers.contains(.shift) { seek(by: 5) }
            else { navigate(forward: true) }
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
            shutdownViewer()
            exitFullScreen()
            imageStore.reset()
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
            case "s", "S":
                // 一時停止中のみ有効（再生中・変換中・画像表示中は素通し）
                guard let player = player, player.timeControlStatus == .paused else { return false }
                captureScreenshot(player: player)
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

    private func navigate(forward: Bool) {
        // 端では何もしない（再生を維持し、末尾右キー・先頭左キーでの黒画面化を防ぐ）
        let canMove = forward
            ? imageStore.currentIndex < imageStore.mediaURLs.count - 1
            : imageStore.currentIndex > 0
        guard canMove else { return }
        cleanupPlayer()
        forward ? imageStore.next() : imageStore.previous()
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
            imageStore.startStreaming(at: targetIndex) { result in
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
        // スクリーンショット用出力は再生開始後の後付けだとバッファが取れないことがあるため生成時に添付
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output
        videoTransform = .identity
        Task {
            // 縦向き動画等の回転はAVPlayerLayerが表示時に適用するが、VideoOutputのバッファは素の向きのまま
            if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
               let transform = try? await track.load(.preferredTransform) {
                await MainActor.run {
                    guard navigationGeneration == generation else { return }
                    videoTransform = transform
                }
            }
        }
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer

        observePlayerStatus(item, generation: generation)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            // 世代チェック：送った直後に積まれた遅延通知での誤った自動送り（＝飛ばし）を防ぐ
            guard navigationGeneration == generation else { return }
            autoAdvance()
        }

        // 再生バー用の進捗監視（0.1秒間隔）
        progress = 0
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak newPlayer] time in
            // playerを強参照すると player→observer→closure→player の保持循環になる
            guard navigationGeneration == generation,
                  let p = newPlayer,
                  let duration = effectiveDuration(of: p) else { return }
            progress = min(max(time.seconds / duration, 0), 1)
        }

        newPlayer.play()
    }

    private func observePlayerStatus(_ item: AVPlayerItem, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard navigationGeneration == generation else { return }
            if item.status == .failed {
                playerError = true
                cleanupPlayer()   // player=nil直接代入だとオブザーバーが残る
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard navigationGeneration == generation else { return }
            if item.status == .failed {
                playerError = true
                cleanupPlayer()
            }
        }
    }

    private func autoAdvance() {
        // 末尾では送らず最後のフレームを維持（最終動画終了後の黒画面を防ぐ）
        guard imageStore.currentIndex < imageStore.mediaURLs.count - 1 else { return }
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

    /// 再生中アイテムの実効的な長さ。イベント型HLSプレイリスト（ストリーミング変換中）は
    /// ENDLIST到達までdurationが不定のため、ffprobeで取得した実尺を優先して使う
    /// （プレイリスト全長を分母にすると変換の進行に伴って再生バーが伸び縮みするため）。
    /// 実尺も取れていない間はシーク可能範囲の末尾へフォールバック
    private func effectiveDuration(of player: AVPlayer) -> Double? {
        guard let item = player.currentItem else { return nil }
        let duration = item.duration.seconds
        if duration.isFinite && duration > 0 { return duration }
        if let probed = imageStore.probedDuration(at: imageStore.currentIndex) {
            return probed
        }
        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let end = CMTimeRangeGetEnd(range).seconds
            if end.isFinite && end > 0 { return end }
        }
        return nil
    }

    /// 指定秒数だけシーク
    private func seek(by seconds: Double) {
        guard let player = player, let duration = effectiveDuration(of: player) else { return }
        let current = player.currentTime().seconds
        let target = min(max(current + seconds, 0), duration)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 動画の指定割合の位置へジャンプ
    private func seekToPercent(_ percent: Double) {
        guard let player = player, let duration = effectiveDuration(of: player) else { return }
        let target = duration * percent
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 音量調整（0.0〜1.0）
    private func adjustVolume(by delta: Float) {
        guard let player = player else { return }
        player.volume = min(max(player.volume + delta, 0.0), 1.0)
    }

    // MARK: - スクリーンショット

    /// 一時停止中の現在フレームを、画面に見えている画角・ピクセルサイズのままPNGでデスクトップへ保存する。
    /// AVAssetImageGeneratorはHLS再生（mkv等の変換ストリーミング）でフレームを取れないため、
    /// 通常ファイル・HLS共通で動くAVPlayerItemVideoOutput経由で取得する
    private func captureScreenshot(player: AVPlayer) {
        guard let output = videoOutput,
              let window = hostWindow,
              let contentView = window.contentView else { return }

        let itemTime = player.currentTime()
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            showToast("フレームを取得できませんでした")
            return
        }

        var image = CIImage(cvPixelBuffer: buffer)
        // 回転メタデータを表示と同じ向きに適用し、原点をゼロへ正規化
        if videoTransform != .identity {
            image = image.transformed(by: videoTransform)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x,
                                                            y: -image.extent.origin.y))
        }
        // 非正方形ピクセル等でバッファ寸法と表示寸法が異なる場合、表示基準（presentationSize）に合わせる
        if let item = player.currentItem {
            let pres = item.presentationSize
            let ext = image.extent.size
            if pres.width > 0, pres.height > 0, ext.width > 0, ext.height > 0,
               abs(pres.width - ext.width) > 1 || abs(pres.height - ext.height) > 1 {
                image = image.transformed(by: CGAffineTransform(scaleX: pres.width / ext.width,
                                                                y: pres.height / ext.height))
            }
        }

        let videoSize = image.extent.size
        let scaleFactor = window.backingScaleFactor
        let screenSize = CGSize(width: contentView.bounds.width * scaleFactor,
                                height: contentView.bounds.height * scaleFactor)
        guard videoSize.width > 0, videoSize.height > 0,
              screenSize.width > 0, screenSize.height > 0 else { return }

        // fit: 全フレームが収まる倍率（黒帯は含めない）／fill: 画面を覆う倍率で中央クロップ
        let scale = isFillMode
            ? max(screenSize.width / videoSize.width, screenSize.height / videoSize.height)
            : min(screenSize.width / videoSize.width, screenSize.height / videoSize.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if isFillMode {
            let cropRect = CGRect(
                x: image.extent.midX - screenSize.width / 2,
                y: image.extent.midY - screenSize.height / 2,
                width: screenSize.width,
                height: screenSize.height
            ).integral.intersection(image.extent)
            image = image.cropped(to: cropRect)
        }

        guard let cgImage = Self.screenshotCIContext.createCGImage(image, from: image.extent) else {
            showToast("画像の生成に失敗しました")
            return
        }
        guard let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            showToast("PNGの生成に失敗しました")
            return
        }

        // <元ファイル名>_<動画位置mm.ss>.png。同名存在時は-2,-3…で重複回避。
        // 存在確認と書き込みの間の競合でも上書きしないよう.withoutOverwritingで排他的に生成する
        let sourceName = imageStore.mediaURLs[imageStore.currentIndex].deletingPathExtension().lastPathComponent
        let seconds = itemTime.seconds.isFinite ? max(itemTime.seconds, 0) : 0
        let base = String(format: "%@_%02d.%02d", sourceName, Int(seconds) / 60, Int(seconds) % 60)
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]

        for attempt in 1...100 {
            let name = attempt == 1 ? "\(base).png" : "\(base)-\(attempt).png"
            let dest = desktop.appendingPathComponent(name)
            do {
                try png.write(to: dest, options: .withoutOverwriting)
                showToast("保存: \(dest.lastPathComponent)")
                return
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                break
            }
        }
        showToast("保存に失敗しました")
    }

    private func showToast(_ message: String) {
        captureToast = message
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            captureToast = nil
        }
    }

    private func cleanupPlayer() {
        player?.pause()
        // ブロック形式で登録した監視はトークンでのみ解除できる（self指定では外れない）
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        // 時間監視は登録先playerの解放前に必ず外す
        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
            timeObserver = nil
        }
        progress = 0
        videoOutput = nil
        player = nil
    }

    // mainWindowへのフォールバックは複数ウィンドウ分離を破る（別ウィンドウを操作し得る）ため、
    // hostWindow確定時のみ操作する
    private func enterFullScreenIfNeeded() {
        guard let window = hostWindow, !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    private func exitFullScreen() {
        guard let window = hostWindow else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
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
            cleanupPlayer()
            let sorted = urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            imageStore.loadMultiple(sorted)
        }
        return true
    }
}

/// ホストするNSWindowをSwiftUI側へ渡すヘルパー
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // windowはビュー階層への追加後でないと取れないため次のランループで取得
        DispatchQueue.main.async {
            window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if window !== nsView.window {
                window = nsView.window
            }
        }
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
