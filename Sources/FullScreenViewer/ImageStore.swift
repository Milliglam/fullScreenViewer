import SwiftUI
import Foundation
import CryptoKit

/// メディア一覧と現在のインデックスを管理する共有ストア
class ImageStore: ObservableObject {
    @Published var mediaURLs: [URL] = []
    @Published var currentIndex: Int = 0
    @Published var isViewerActive: Bool = false

    /// フォルダ自体の順番をランダムにする
    @Published var shuffleFolders: Bool = false
    /// 各フォルダ内のファイル順をランダムにする
    @Published var shuffleFiles: Bool = false

    private let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic"
    ]

    private let videoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "mpg", "mpeg", "avi", "webm", "m4v"
    ]

    /// ffmpegで変換が必要な形式
    private let needsConversionExtensions: Set<String> = [
        "mkv", "avi", "webm"
    ]

    private var supportedExtensions: Set<String> {
        imageExtensions.union(videoExtensions)
    }

    // 変換まわりの共有状態。メインスレッドとバックグラウンド変換の双方から
    // アクセスされるため、すべてstateLockで保護する
    /// 変換済みファイルのキャッシュ（元URL → 変換後URL）
    private var conversionCache: [URL: URL] = [:]
    /// ffprobeで取得したソースの実尺（元URL → 秒）
    private var probedDurations: [URL: Double] = [:]
    /// 実行中のffmpegプロセス（クリーンアップ時にterminateするため追跡）
    private var runningProcesses: [Process] = []
    /// 変換セッションの世代。cleanupTempFilesでインクリメントし、
    /// 古い世代の変換ジョブはtempDir再作成・ffmpeg起動・キャッシュ登録を行えない
    private var conversionGeneration = 0
    private let stateLock = NSLock()

    /// HLS配信用ループバックサーバ（初回ストリーミング時に遅延起動、ストア=ウィンドウ毎に1つ）
    private var hlsServer: HLSServer?

    deinit {
        hlsServer?.stop()
    }

    /// 一時ディレクトリ（インスタンス＝ウィンドウごとに分離。
    /// 共有パスだと片方のウィンドウのEsc時クリーンアップが他方の変換済みファイルを消してしまう）
    private let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullScreenViewer")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 現在のファイルがムービーかどうか
    func isVideo(at index: Int) -> Bool {
        guard index >= 0 && index < mediaURLs.count else { return false }
        return videoExtensions.contains(mediaURLs[index].pathExtension.lowercased())
    }

    /// 変換が必要なファイルかどうか
    func needsConversion(at index: Int) -> Bool {
        guard index >= 0 && index < mediaURLs.count else { return false }
        return needsConversionExtensions.contains(mediaURLs[index].pathExtension.lowercased())
    }

    /// 再生用URLを取得（変換済みキャッシュがあればそちらを返す）
    func playableURL(at index: Int) -> URL? {
        guard index >= 0 && index < mediaURLs.count else { return nil }
        let url = mediaURLs[index]
        stateLock.lock()
        let cached = conversionCache[url]
        stateLock.unlock()

        guard let cached = cached else { return url }
        if FileManager.default.fileExists(atPath: localFilePath(for: cached)) { return cached }

        // 実体が消えたエントリ（変換の途中失敗掃除後など）は除去して元URLへフォールバック。
        // ロック解放中に別ジョブが同じURLへ再公開（実体も再作成）した可能性があるため、
        // 「同一エントリのまま」かつ「実体が依然として存在しない」ことをロック内で再確認する
        stateLock.lock()
        if conversionCache[url] == cached,
           !FileManager.default.fileExists(atPath: localFilePath(for: cached)) {
            conversionCache.removeValue(forKey: url)
        }
        stateLock.unlock()
        return url
    }

    /// キャッシュされた再生URLの実体ファイルパス。
    /// ループバック配信URL（http://127.0.0.1:port/<hash>/index.m3u8）はtempDir配下へマップする
    private func localFilePath(for playbackURL: URL) -> String {
        if playbackURL.isFileURL { return playbackURL.path }
        return tempDir.path + playbackURL.path
    }

    /// mkv等をHLSへストリーミング変換し、再生可能になった時点（プレイリスト出現時）で
    /// completionを呼ぶ。変換自体はバックグラウンドで継続し、AVPlayerは書き込み途中の
    /// プレイリストを追いかけて再生する（VLC風の即時再生）
    func startStreaming(at index: Int, completion: @escaping (Result<URL, Error>) -> Void) {
        guard index >= 0 && index < mediaURLs.count else {
            completion(.failure(ConversionError.invalidIndex))
            return
        }

        let sourceURL = mediaURLs[index]

        stateLock.lock()
        let generation = conversionGeneration
        let cached = conversionCache[sourceURL]
        stateLock.unlock()

        // キャッシュ済み（変換完了 or ストリーミング中）なら即返す
        // （キャッシュはhttp配信URLのため、実体確認はtempDir配下へマップして行う）
        if let cached = cached, FileManager.default.fileExists(atPath: localFilePath(for: cached)) {
            completion(.success(cached))
            return
        }

        // 異なるフォルダの同名ファイルが同じ出力先を共有しないよう、パスの安定ダイジェストで分離
        let digest = SHA256.hash(data: Data(sourceURL.path.utf8))
        let pathHash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let outputDir = tempDir.appendingPathComponent(pathHash, isDirectory: true)
        let playlistURL = outputDir.appendingPathComponent("index.m3u8")
        // 注: プレイリストのファイル存在による再利用判定はしない。再利用可否は
        // conversionCache（publishStream/failStreamJobで順序付けされた正本）のみで判定する。
        // ファイル存在での判定は進行中ジョブの失敗掃除と競合し、削除済みURLを成功として返し得る

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // クリーンアップ済み世代の残ジョブは何もしない（tempDir再作成やffmpeg起動をさせない）
            guard self.isCurrentGeneration(generation) else {
                DispatchQueue.main.async { completion(.failure(ConversionError.conversionFailed)) }
                return
            }

            // Escでのクリーンアップ後もこのストアは生き続けるため、出力先を毎回確保する
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            // コーデック判定と実尺取得（実尺は変換中の再生バー分母に使う）。
            // 保存は世代確認付き：probe中にcleanupが走った場合に旧世代の値を復活させない
            let probe = self.probeSource(sourceURL)
            if let duration = probe.duration {
                self.stateLock.lock()
                if generation == self.conversionGeneration {
                    self.probedDurations[sourceURL] = duration
                }
                self.stateLock.unlock()
            }

            // 映像がH.264/HEVCなら無劣化コピー（ディスク速度）、それ以外は再エンコード
            var videoArgs: [String]
            switch probe.codec {
            case "h264":
                videoArgs = ["-c:v", "copy"]
            case "hevc":
                videoArgs = ["-c:v", "copy", "-tag:v", "hvc1"]   // AVPlayerはhev1タグを再生できない
            default:
                videoArgs = ["-c:v", "h264_videotoolbox", "-b:v", "8000k"]
            }
            // 音声は常にAAC化（DTS/FLAC/Opus等のAVPlayer非対応コーデックを吸収）
            let args = ["-i", sourceURL.path, "-y"] + videoArgs + [
                "-c:a", "aac", "-b:a", "192k",
                "-f", "hls",
                "-hls_time", "4",
                "-hls_playlist_type", "event",
                "-hls_segment_type", "fmp4",
                "-hls_fmp4_init_filename", "init.mp4",
                playlistURL.path
            ]

            let job = StreamJob()
            guard let process = self.launchFFmpeg(arguments: args, generation: generation, onExit: { [weak self] status in
                // 途中失敗した中途半端な出力を残さない（再入時に壊れたプレイリストを掴まないため）。
                // クリーンアップによるterminateは世代確認で弾かれるので実害なし
                guard status != 0, let self = self else { return }
                self.failStreamJob(job, source: sourceURL, generation: generation)
                self.removeOutputIfCurrent(outputDir, generation: generation)
            }) else {
                DispatchQueue.main.async { completion(.failure(ConversionError.conversionFailed)) }
                return
            }

            // プレイリスト出現を待って再生開始を通知（変換自体はバックグラウンドで継続）
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: playlistURL.path) {
                    // AVPlayerはfile://のHLSを再生できないため、ループバックHTTPで配信する
                    guard let port = self.hlsServerPort(),
                          let streamURL = URL(string: "http://127.0.0.1:\(port)/\(pathHash)/index.m3u8") else {
                        break
                    }
                    // 公開は失敗確定と同じロックで順序付けられる。異常終了の掃除が
                    // 先行していた場合は公開を拒否し、削除済み出力のキャッシュ復活を防ぐ
                    guard self.publishStream(job, source: sourceURL, playlist: streamURL, generation: generation) else {
                        DispatchQueue.main.async { completion(.failure(ConversionError.conversionFailed)) }
                        return
                    }
                    DispatchQueue.main.async { completion(.success(streamURL)) }
                    return
                }
                // 起動直後の失敗（コーデック非対応等）。出力削除はonExit側で行われる
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.2)
            }

            // タイムアウトまたはffmpeg異常終了
            if process.isRunning { process.terminate() }
            self.removeOutputIfCurrent(outputDir, generation: generation)
            DispatchQueue.main.async {
                completion(.failure(ConversionError.conversionFailed))
            }
        }
    }

    /// ffprobeで映像コーデック名とコンテナの実尺（秒）を取得（失敗時はそれぞれnil）。
    /// 実尺はストリーミング変換中の再生バー分母に使う（プレイリスト全長は変換に伴い伸びるため）
    private func probeSource(_ url: URL) -> (codec: String?, duration: Double?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        process.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_name:format=duration",
            "-of", "default=noprint_wrappers=1",
            url.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (nil, nil)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return (nil, nil) }

        // 出力形式: "codec_name=h264\nduration=30.023000"
        var codec: String?
        var duration: Double?
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("codec_name=") {
                codec = String(line.dropFirst("codec_name=".count))
            } else if line.hasPrefix("duration=") {
                duration = Double(line.dropFirst("duration=".count))
            }
        }
        return (codec, duration)
    }

    /// ストリーミング変換中の動画の実尺（ffprobe取得値）。未取得ならnil
    func probedDuration(at index: Int) -> Double? {
        guard index >= 0 && index < mediaURLs.count else { return nil }
        let url = mediaURLs[index]
        stateLock.lock()
        defer { stateLock.unlock() }
        return probedDurations[url]
    }

    /// 指定世代が現在も有効か
    private func isCurrentGeneration(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == conversionGeneration
    }

    /// HLS配信サーバを（必要なら起動して）ポートを返す。
    /// start()はセマフォ待ちを含むためロック外で行い、二重起動は登録時に解決する
    private func hlsServerPort() -> UInt16? {
        stateLock.lock()
        if let server = hlsServer, server.port != 0 {
            let port = server.port
            stateLock.unlock()
            return port
        }
        stateLock.unlock()

        let server = HLSServer(root: tempDir)
        guard let port = server.start() else { return nil }

        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = hlsServer, existing.port != 0 {
            // 並行起動の競争に負けた方は破棄
            server.stop()
            return existing.port
        }
        hlsServer = server
        return port
    }

    /// ffmpegを非同期起動する。「世代確認→起動→登録」をstateLock内で一体化し、
    /// cleanupが割り込んで未起動プロセスをterminateしたり、世代更新後に
    /// 旧世代のffmpegが起動したりする隙間をなくす（run自体はposix_spawnで短時間）。
    /// 終了時はterminationHandlerで登録解除し、onExitに終了ステータスを渡す。
    /// 起動失敗・旧世代ならnilを返す
    private func launchFFmpeg(arguments: [String], generation: Int, onExit: ((Int32) -> Void)? = nil) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] proc in
            if let self = self {
                self.stateLock.lock()
                self.runningProcesses.removeAll { $0 === proc }
                self.stateLock.unlock()
            }
            onExit?(proc.terminationStatus)
        }

        stateLock.lock()
        guard generation == conversionGeneration else {
            stateLock.unlock()
            return nil
        }
        do {
            try process.run()
        } catch {
            stateLock.unlock()
            return nil
        }
        runningProcesses.append(process)
        stateLock.unlock()
        return process
    }

    /// ストリーミングジョブの異常終了を確定させ、世代が有効ならキャッシュ登録も取り消す。
    /// 失敗フラグとキャッシュ除去を同一クリティカルセクションで行い、
    /// 以後のpublishStreamが必ず拒否されることを保証する
    private func failStreamJob(_ job: StreamJob, source: URL, generation: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        job.failed = true
        guard generation == conversionGeneration else { return }
        conversionCache.removeValue(forKey: source)
    }

    /// ジョブが失敗しておらず世代も有効な場合のみ、プレイリストをキャッシュへ公開する
    private func publishStream(_ job: StreamJob, source: URL, playlist: URL, generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !job.failed, generation == conversionGeneration else { return false }
        conversionCache[source] = playlist
        return true
    }

    /// 世代が有効な場合のみ出力ファイルを削除する。
    /// terminateされた旧世代ジョブの後始末が、次世代変換の書き込み中出力を消すのを防ぐ。
    /// 確認と削除の間にcleanupTempFiles（世代更新）が割り込めないよう、
    /// 削除までロック内で不可分に行う（対象は一時mp4のみで削除は短時間）
    private func removeOutputIfCurrent(_ url: URL, generation: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == conversionGeneration else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 一時ファイルをクリーンアップ（変換中のffmpegは停止し、終了を待ってから削除する。
    /// 世代を進めるため、以降は残ジョブのffmpeg起動・キャッシュ登録が拒否される。
    /// tempDirは次回変換時に再作成される）
    func cleanupTempFiles() {
        stateLock.lock()
        conversionGeneration += 1
        let procs = runningProcesses
        conversionCache.removeAll()
        probedDurations.removeAll()
        stateLock.unlock()

        // terminateするとwaitUntilExitが非0で返り、呼び出し側は変換失敗として処理される
        procs.forEach { $0.terminate() }
        procs.forEach { $0.waitUntilExit() }

        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 複数URLをロードする（フォルダ・ファイル混在可）。
    /// ランダム設定に応じてフォルダ順・各フォルダ内のファイル順をシャッフルする。
    func loadMultiple(_ urls: [URL]) {
        let startIndex = mediaURLs.count
        var seen = Set(mediaURLs)

        // 各トップレベルをブロックに展開（フォルダ=1ブロック、単品ファイル=1要素ブロック）
        var blocks = urls.map { expand($0) }.filter { !$0.isEmpty }
        if shuffleFiles { blocks = blocks.map { $0.shuffled() } }   // 各フォルダ内をシャッフル
        if shuffleFolders { blocks.shuffle() }                     // フォルダの順番をシャッフル

        // 既存リスト＋バッチ内の重複を順序維持で除外
        let newMedia = blocks.flatMap { $0 }.filter { seen.insert($0).inserted }

        mediaURLs.append(contentsOf: newMedia)
        // 新しいファイルが追加された場合、最初の追加位置から表示
        if mediaURLs.count > startIndex {
            currentIndex = startIndex
            isViewerActive = true
        }
    }

    /// フォルダまたは単品ファイルをロードする（既存リストに追加）
    func load(_ url: URL) {
        loadMultiple([url])
    }

    /// ビューアを閉じて読み込み済みリストをクリアする（Escでの終了時に使用）。
    /// ランダム設定（shuffleFolders/shuffleFiles）は維持する。
    func reset() {
        mediaURLs.removeAll()
        currentIndex = 0
        isViewerActive = false
    }

    /// トップレベルURLをメディア列に展開する
    /// （フォルダ=再帰スキャンしてソート済み、単品ファイル=それ自身）
    private func expand(_ url: URL) -> [URL] {
        // セキュリティスコープ付きアクセス
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }

        if isDir.boolValue {
            return scanFolder(url)
        } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
            return [url]
        }
        return []
    }

    /// フォルダを再帰的にスキャンしてメディアファイルを収集
    private func scanFolder(_ url: URL) -> [URL] {
        let fm = FileManager.default

        // まず再帰スキャン（enumerator）
        if let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            var files: [URL] = []
            for case let fileURL as URL in enumerator {
                if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                    files.append(fileURL)
                }
            }
            if !files.isEmpty {
                return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }
        }

        // enumeratorが失敗した場合、フラットスキャンにフォールバック
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func next() {
        if currentIndex < mediaURLs.count - 1 {
            currentIndex += 1
        }
    }

    func previous() {
        if currentIndex > 0 {
            currentIndex -= 1
        }
    }

    enum ConversionError: Error {
        case invalidIndex
        case conversionFailed
    }

    /// ストリーミング変換ジョブごとの状態。ポーリング側の「プレイリスト公開」と
    /// terminationHandler側の「異常終了の掃除」をstateLock配下で順序付けるために使う
    private final class StreamJob {
        var failed = false
    }
}
