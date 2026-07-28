# FullScreenViewer
状態: dormant
フェーズ: 機能アップデート完了・commit/push済み（2026-07-28、main 2d6d3a9）
次のアクション: なし（必要時に機能追加）
メモ: macOS用フルスクリーンメディアビューア。Swift/SwiftUI、ffmpeg動画変換付き。2026-07-28アップデート=複数ウィンドウ同時再生（ストア/イベント/tempDir分離、⌘N）・最下部再生バー（視覚4px/クリック領域20pxでクリックシーク）・ファイル名表示・mkv/avi/webmのHLSストリーミング即時再生（ffprobe判定→H.264/HEVC無劣化コピー/他はVideoToolbox、ループバックHTTP配信=HLSServer.swift。**AVPlayerはfile://のHLSを再生不可（-12865）が要点**）・変換中バーはffprobe実尺基準。並行安全=世代管理+StreamJob+stateLock。全機能佐藤さん目視確認済み。codex-review計8反復ok:true。ビルド=`swift build --disable-sandbox -c release`→バイナリをFullScreenViewer.app/Contents/MacOS/へコピー。検証素材・レビューログ=_scratch/（git管理外）
更新日: 2026-07-28
