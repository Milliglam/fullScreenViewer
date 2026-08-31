# FullScreenViewer
状態: dormant
フェーズ: 一時停止中スクリーンショット機能完了・commit/push済み（2026-09-01、main 6e4a0ab）
次のアクション: なし（必要時に機能追加）
メモ: macOS用フルスクリーンメディアビューア。Swift/SwiftUI、ffmpeg動画変換付き。2026-09-01追加=Sキー（一時停止中のみ）で現在フレームを画面表示どおりの画角・ピクセルサイズ（Retinaスケール込み、fit=黒帯なし/fill=中央クロップ）でPNG化し~/Desktopへ保存（ダイアログなし・.withoutOverwritingで連番回避）。**AVAssetImageGeneratorはHLS不可のためAVPlayerItemVideoOutput方式（要点）**。回転メタデータはVideoOutputバッファに乗らないためpreferredTransformを非同期取得し保存時に適用、presentationSize補正で非正方形ピクセル対応。保存結果はトースト1.5秒表示。codex-review 2反復でok:true、全機能ユーザー目視確認済み。ビルド=`swift build --disable-sandbox -c release`→バイナリをFullScreenViewer.app/Contents/MacOS/へコピー
更新日: 2026-09-01
