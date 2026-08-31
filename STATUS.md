# FullScreenViewer
状態: active
フェーズ: 一時停止中スクリーンショット機能を実装・ビルド反映済み（ユーザー目視確認待ち、未コミット）
次のアクション: 目視確認（fit/fill・縦向き動画・HLS変換再生・連番回避）→ OKならcommit/push
メモ: macOS用フルスクリーンメディアビューア。Swift/SwiftUI、ffmpeg動画変換付き。2026-09-01追加=Sキー（一時停止中のみ）で現在フレームを画面表示どおりの画角・ピクセルサイズ（Retinaスケール込み、fit=黒帯なし/fill=中央クロップ）でPNG化し~/Desktopへ保存（ダイアログなし・.withoutOverwritingで連番回避）。**AVAssetImageGeneratorはHLS不可のためAVPlayerItemVideoOutput方式（要点）**。回転メタデータはVideoOutputバッファに乗らないためpreferredTransformを非同期取得し保存時に適用、presentationSize補正で非正方形ピクセル対応。保存結果はトースト1.5秒表示。codex-review 2反復でok:true。初回Desktop書き込みでTCC許可ダイアログが出る可能性あり。ビルド=`swift build --disable-sandbox -c release`→バイナリをFullScreenViewer.app/Contents/MacOS/へコピー
更新日: 2026-09-01
