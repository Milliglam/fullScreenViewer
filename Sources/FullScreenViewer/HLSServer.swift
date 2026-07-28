import Foundation
import Network

/// tempDir配下のHLSファイルをAVPlayerへ配信する最小ループバックHTTPサーバ。
/// AVPlayerはfile://のHLSプレイリストを再生できない（CoreMediaErrorDomain -12865）ため、
/// 127.0.0.1経由で配信する。ATSはループバック接続に適用されないためhttpで問題ない。
final class HLSServer {
    private let root: URL
    private let queue = DispatchQueue(label: "com.milliglam.fullscreenviewer.hlsserver")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    init(root: URL) {
        self.root = root
    }

    /// サーバを起動し、割り当てられたポートを返す（失敗時nil）
    func start() -> UInt16? {
        let params = NWParameters.tcp
        // ループバックのみにバインド（外部からは接続不可）
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else { return nil }
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? 0
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        return port != 0 ? port : nil
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    deinit { stop() }

    // MARK: - リクエスト処理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    /// ヘッダ終端（\r\n\r\n）まで受信してからレスポンスを返す
    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data = data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.respond(connection, requestHead: head)
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, requestHead: String) {
        let lines = requestHead.components(separatedBy: "\r\n")
        let requestParts = lines.first?.components(separatedBy: " ") ?? []
        guard requestParts.count >= 2, requestParts[0] == "GET" else {
            send(connection, status: "405 Method Not Allowed", body: Data())
            return
        }

        // クエリ除去＋パーセントデコード
        let rawPath = String(requestParts[1].prefix(while: { $0 != "?" }))
        guard let decodedPath = rawPath.removingPercentEncoding else {
            send(connection, status: "400 Bad Request", body: Data())
            return
        }

        // ルート配下に正規化されることを確認（パストラバーサル防止）
        let fileURL = root.appendingPathComponent(decodedPath).standardizedFileURL
        guard fileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: fileURL) else {
            send(connection, status: "404 Not Found", body: Data())
            return
        }

        // Rangeリクエスト対応（bytes=a-b / bytes=a-）
        var rangeSpec: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                rangeSpec = line.dropFirst("range:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
            }
        }
        if let spec = rangeSpec, spec.hasPrefix("bytes=") {
            let bounds = spec.dropFirst("bytes=".count).components(separatedBy: "-")
            if bounds.count == 2, let start = Int(bounds[0]), start >= 0, start < data.count {
                let end = Int(bounds[1]).map { min($0, data.count - 1) } ?? (data.count - 1)
                if start <= end {
                    send(connection, status: "206 Partial Content",
                         body: data.subdata(in: start..<(end + 1)),
                         contentType: contentType(for: fileURL),
                         extraHeaders: ["Content-Range: bytes \(start)-\(end)/\(data.count)"])
                    return
                }
            }
            send(connection, status: "416 Range Not Satisfiable", body: Data(),
                 extraHeaders: ["Content-Range: bytes */\(data.count)"])
            return
        }

        send(connection, status: "200 OK", body: data, contentType: contentType(for: fileURL))
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "m4s": return "video/iso.segment"
        case "mp4": return "video/mp4"
        case "ts": return "video/mp2t"
        default: return "application/octet-stream"
        }
    }

    private func send(_ connection: NWConnection, status: String, body: Data,
                      contentType: String = "application/octet-stream",
                      extraHeaders: [String] = []) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        // 変換中はプレイリストが数秒ごとに更新されるためキャッシュさせない
        head += "Cache-Control: no-cache\r\n"
        extraHeaders.forEach { head += $0 + "\r\n" }
        head += "Connection: close\r\n\r\n"

        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
