<!-- overnight: running -->
# Overnight 報告

分支 `overnight-20261126-1104`，worktree 在 `E:\花椰菜相機\Broccoli-Cam-overnight`（從 files-export `2e907de` 長出來）。主資料夾 `Broccoli-Cam` 另一個對話在用，沒碰。

## 早上摘要
（全部做完才寫）

## 任務清單
- [x] 1. 合併 perf-mid-low 進來。完成標準：合併沒有衝突、commit 成功
- [x] 2. 編譯 iphonesimulator、iphoneos Release。完成標準：兩種都 0 錯 0 Swift 警告
- [ ] 3. 模擬器實測效能中低項。完成標準：分段錄兩段→接片（直通）→完成頁播得出來、開頭第一格不是黑的、影片檔用 ffprobe 看格式正常；提詞固定速度捲、預覽、優化滑桿、加字幕→校對頁打字→燒錄→存照片都能走完
- [ ] 4. 修兩個小問題：完成頁已是「改字幕」時不寫「聲音會送到 Apple 辨識」；提綱重點段、不看時看不見的「提詞」「回開頭」「腳本」鈕從無障礙樹拿掉。完成標準：編過、截圖確認文案、無障礙樹（limrun 能讀的話）看不到那三顆
- [ ] 5. 模擬器補測：ModePicker 只有一位聆聽者時（670）、改稿子內文後按「換稿」真的刪舊段落。完成標準：兩項各有截圖或檔案清單佐證，結果寫進紀錄
- [ ] 6. README 補一節、寫早上摘要。完成標準：README 有本輪段落、本檔第一行改 done

## 待確認（需要多米決定的事）

## 卡住的項目

## 執行紀錄
- 11:04 開 worktree、新分支，`git merge --no-ff perf-mid-low` 沒衝突
- 11:12 第 2 項：iphonesimulator、iphoneos Release 都過，0 錯 0 Swift 警告（limrun xcode_euna_01m8ax1hf0fmsswh619btpyrdn，自己開的，label broccolicam-overnight）
