# 花椰菜相機（Broccoli-Cam）

給知識型、口播型新手創作者的極簡拍攝工具。iOS 原生（SwiftUI + AVFoundation）。

完整規格在 [`docs/spec-v1.1.html`](docs/spec-v1.1.html)。

## 目前進度：第一輪

已實作：

- 前鏡頭直式錄影（依裝置實際支援提供 1080p／4K、30／60 FPS），HEVC，存到照片圖庫
- 提詞：整篇貼上、固定在螢幕頂端緊鄰前鏡頭、自動捲動＋手動滑動、字級／速度／底色可調、與錄影各自獨立啟停
- 固定頭像框，提詞開始後淡出；頭像框與提詞都不會錄進影片
- 臉部定位（`AVCaptureMetadataOutput`）：位置大致正確時頭像框變色
- 收音檢查與說話偵測（讀錄影音訊連線的 `audioChannels`，不另開 `AVAudioEngine`）
- 錄影倒數、錄影完成頁（預覽／儲存／重錄）
- 設定記憶（UserDefaults）
- App 內除錯資訊層

## 第二輪（尚未真機驗證）

- 分段錄影：稿件用空行分段，一段錄一次；錄完選「留用」或「重錄這段」，全部錄完自動接成一支。沒有空行就是一整段，流程和第一輪相同
- 完成頁可以回去只重錄其中一段，再重新接片
- 接片時裁掉每段頭尾沒有聲音的部分（可在設定關閉）
- 錄影中停頓時提詞自動暫停，開口再繼續（可在設定關閉）
- 稿件頁顯示字數、預估時長、段數；錄影計時旁顯示這一段的預估時長
- 音量鍵、藍牙自拍遙控器可以開始／停止錄影，剛錄完一段時等同「留用」（iOS 17.2 以上）

還沒做：語音跟隨提詞、SRT 字幕、陪伴模式、橫式錄影。規劃見 [`docs/需求缺口與功能規劃.md`](docs/需求缺口與功能規劃.md)。

## 專案結構

```
BroccoliCam/
  App/        進入點、權限說明頁
  Camera/     CameraService（session、格式、錄影、中斷）、預覽
  Services/   RecordingViewModel、TeleprompterModel、FaceDetectionService、
              SpeechActivityMonitor、PhotoSaver
  Models/     SettingsStore
  Views/      拍攝主畫面、提詞、頭像框、稿件、設定、完成頁、除錯層
project.yml   XcodeGen 專案定義（.xcodeproj 不進版控，由 CI 產生）
```

## 建置（沒有 Mac）

所有建置都在 GitHub Actions 的 macOS runner 上跑，見 `.github/workflows/ios.yml`。

- **編譯檢查**：每次 push 到 `main` 都會不簽章編譯一次。
- **上傳 TestFlight**：設定好下面四個 repo secrets 後，每次 push 會自動封存並上傳。沒設定時這一步會略過。

| Secret | 內容 |
|---|---|
| `ASC_KEY_ID` | App Store Connect API 金鑰的 Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | `.p8` 檔案的內容（原文或 base64 都可以） |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

API 金鑰需要能管理憑證與描述檔的權限（Admin 或 App Manager），因為簽章用的是自動簽章。
第一次上傳前，要先在 App Store Connect 建立 Bundle ID 為 `org.domyweb.broccolicam` 的 App。

Build 編號用 Actions 的 run number，版本號在 `project.yml` 的 `MARKETING_VERSION`。

## 真機測試時回報問題

模擬器沒有相機，驗收只認真機。

在主畫面**長按麥克風圖示 1 秒**（或到「設定 → 進階」）打開除錯資訊層，按「複製」，把內容貼回來。
裡面有裝置型號、實際錄影格式與 FPS、輸出旋轉與鏡像、音訊路由、音量、臉部偵測、溫度狀態、最近的錯誤與紀錄。

## 已知待真機確認的事項

- 未錄影時，錄影音訊連線是否回報音量。若讀不到（音量條不動、顯示「沒有偵測到聲音」），要改在同一個 session 加 `AVCaptureAudioDataOutput`。
- 影片方向與左右是否正確（預設輸出不鏡像，預覽是鏡像）。
- 4K／60 長時間錄影的發熱與掉幀。
- 接片後的影片方向、左右、聲畫同步是否和單段一致；4K 接片要等多久。
- 裁靜音會不會切到字：用的是錄影當下的音量紀錄（門檻 -45 dB，前留 0.5 秒、後留 0.8 秒），講話小聲的人要特別看。
- 停頓等人的反應時間（目前安靜 0.7 秒後暫停）會不會太敏感或太遲鈍。
- 音量鍵是否能觸發錄影，按下時會不會跳出系統音量條。
- 藍牙耳機麥克風：目前沿用系統自動音訊設定，預設用手機內建麥克風；有線與 USB 麥克風由系統自動切換。
