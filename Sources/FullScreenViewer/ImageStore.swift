import SwiftUI
import Foundation

/// メディア一覧と現在のインデックスを管理する共有ストア
class ImageStore: ObservableObject {
    @Published var mediaURLs: [URL] = []
    @Published var currentIndex: Int = 0
    @Published var isViewerActive: Bool = false

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

    /// -c copy（コンテナ変換のみ）を試してよい形式
    /// aviはコーデック非対応が多いので常に再エンコードする
    private let copyableExtensions: Set<String> = [
        "mkv", "webm"
    ]

    private var supportedExtensions: Set<String> {
        imageExtensions.union(videoExtensions)
    }

    /// 変換済みファイルのキャッシュ（元URL → 変換後URL）
    private var conversionCache: [URL: URL] = [:]

    /// 一時ディレクトリ
    private let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FullScreenViewer")
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
        return conversionCache[url] ?? url
    }

    /// ffmpegで変換
    func convertVideo(at index: Int, completion: @escaping (Result<URL, Error>) -> Void) {
        guard index >= 0 && index < mediaURLs.count else {
            completion(.failure(ConversionError.invalidIndex))
            return
        }

        let sourceURL = mediaURLs[index]
        let ext = sourceURL.pathExtension.lowercased()

        // キャッシュ済みなら即返す
        if let cached = conversionCache[sourceURL],
           FileManager.default.fileExists(atPath: cached.path) {
            completion(.success(cached))
            return
        }

        let outputURL = tempDir.appendingPathComponent(
            sourceURL.deletingPathExtension().lastPathComponent + "_converted.mp4"
        )

        // 既に変換ファイルが存在すれば再利用
        if FileManager.default.fileExists(atPath: outputURL.path) {
            conversionCache[sourceURL] = outputURL
            completion(.success(outputURL))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // mkv/webm は -c copy を先に試す（aviはスキップ）
            if self.copyableExtensions.contains(ext) {
                if self.runFFmpeg(input: sourceURL, output: outputURL, args: ["-c", "copy"]) {
                    self.conversionCache[sourceURL] = outputURL
                    DispatchQueue.main.async { completion(.success(outputURL)) }
                    return
                }
                try? FileManager.default.removeItem(at: outputURL)
            }

            // ハードウェアエンコード（VideoToolbox）
            if self.runFFmpeg(input: sourceURL, output: outputURL, args: [
                "-c:v", "h264_videotoolbox",
                "-b:v", "8000k",
                "-c:a", "aac",
                "-b:a", "192k"
            ]) {
                self.conversionCache[sourceURL] = outputURL
                DispatchQueue.main.async { completion(.success(outputURL)) }
                return
            }

            try? FileManager.default.removeItem(at: outputURL)
            DispatchQueue.main.async {
                completion(.failure(ConversionError.conversionFailed))
            }
        }
    }

    /// ffmpegコマンドを実行
    private func runFFmpeg(input: URL, output: URL, args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-i", input.path, "-y"] + args + [output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 一時ファイルをクリーンアップ
    func cleanupTempFiles() {
        conversionCache.removeAll()
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 複数URLをロードする（フォルダ・ファイル混在可）
    func loadMultiple(_ urls: [URL]) {
        let startIndex = mediaURLs.count
        for url in urls {
            loadSingle(url)
        }
        // 新しいファイルが追加された場合、最初の追加位置から表示
        if mediaURLs.count > startIndex {
            currentIndex = startIndex
            isViewerActive = true
        }
    }

    /// フォルダまたは単品ファイルをロードする（既存リストに追加）
    func load(_ url: URL) {
        let startIndex = mediaURLs.count
        loadSingle(url)
        if mediaURLs.count > startIndex {
            currentIndex = startIndex
            isViewerActive = true
        }
    }

    /// 内部用：1つのURLを処理してリストに追加（isViewerActiveは変更しない）
    private func loadSingle(_ url: URL) {
        // セキュリティスコープ付きアクセス
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }

        if isDir.boolValue {
            let media = scanFolder(url)
            let existing = Set(mediaURLs)
            let newMedia = media.filter { !existing.contains($0) }
            mediaURLs.append(contentsOf: newMedia)
        } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
            if !mediaURLs.contains(url) {
                mediaURLs.append(url)
            }
        }
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
}
