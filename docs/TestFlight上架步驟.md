# 把花椰菜相機裝到手機：TestFlight 步驟

你之前上過捏捏史萊姆、bigkeyboard，流程一樣，這次只是換一個 Bundle ID。全部做完大概 20 分鐘，其中一半是在等 Apple 處理。

要做的事有五件，照順序來：

1. 註冊 Bundle ID
2. 在 App Store Connect 建 App
3. 準備 API 金鑰的三個值，加上 Team ID
4. 把四個值設成 GitHub secrets
5. 觸發建置，然後在手機上用 TestFlight 安裝

## 一、註冊 Bundle ID

到 <https://developer.apple.com/account/resources/identifiers/list>，登入你的開發者帳號。

1. 按 Identifiers 旁邊的「＋」
2. 選 App IDs，Continue
3. 選 App，Continue
4. Description 填 `Broccoli Cam`（這欄只給你自己看，不接受中文和符號）
5. Bundle ID 選 Explicit，填 `org.domyweb.broccolicam`
6. 下面的 Capabilities 一個都不用勾
7. Continue，再按 Register

這個 ID 要一字不差。專案的 `project.yml` 寫的就是它，打錯的話後面簽章會失敗，而且註冊過的 ID 不能改名只能刪。

## 二、在 App Store Connect 建 App

到 <https://appstoreconnect.apple.com/apps>。

1. 按左上的「＋」，選「新增 App」
2. 平台勾 iOS
3. 名稱填 `花椰菜相機`
4. 主要語言選繁體中文
5. 套件識別碼從下拉選單選剛剛註冊的 `org.domyweb.broccolicam`
6. SKU 填 `broccolicam`
7. 使用者存取權限選「完整存取權限」
8. 按「建立」

名稱是整個 App Store 不能重複的。如果跳出「名稱已被使用」，先隨便加幾個字建起來（例如 `花椰菜相機 口播提詞`），這個名稱之後上架前還能改，手機桌面上顯示的名字是專案裡設的「花椰菜相機」，不受影響。

下拉選單裡找不到剛註冊的 ID 的話，等一兩分鐘重新整理。上次捏捏史萊姆就是在這一步選錯 ID 才把茄記的 ID 用掉，這次選之前多看一眼。

## 三、準備四個值

GitHub 那邊要四個值：

| 名稱 | 是什麼 | 去哪裡看 |
|---|---|---|
| `ASC_KEY_ID` | API 金鑰的 Key ID，10 個字元 | App Store Connect → 使用者與存取權限 → 整合 → App Store Connect API → 團隊金鑰 |
| `ASC_ISSUER_ID` | Issuer ID，一串有連字號的長碼 | 同一頁最上方 |
| `ASC_KEY_P8` | 金鑰檔 `AuthKey_XXXXXXXXXX.p8` 的內容 | 建金鑰當下下載的那個檔案 |
| `APPLE_TEAM_ID` | 開發者團隊 ID，10 個字元 | <https://developer.apple.com/account> → 會員資格詳細資訊 |

金鑰頁面的網址是 <https://appstoreconnect.apple.com/access/integrations/api>。

### 用現成的金鑰

你的下載資料夾裡有五個金鑰檔：

| 檔案 | 日期 |
|---|---|
| `AuthKey_A8MXKF7HA2.p8` | 2026-11-15 |
| `AuthKey_F3286X6SY3.p8` | 2026-11-13 |
| `AuthKey_95S932UJWS.p8` | 2026-11-01 |
| `AuthKey_6K69URC47Y.p8` | 2026-10-31 |
| `AuthKey_SL298DM552.p8` | 2026-10-31 |

檔名 `AuthKey_` 後面那 10 個字元就是 Key ID。到金鑰頁面對一下，挑一個狀態是「有效」、存取權限是「管理」或「App 管理」的就能用。我沒有讀這些檔案的內容，也不知道哪幾把已經被撤銷，這要你在頁面上確認。

權限要「管理」或「App 管理」，因為建置時會自動幫你產生簽章憑證和描述檔，權限只有「開發者」的金鑰做不到。

### 沒有可用的就建一把新的

在金鑰頁面按「＋」，名稱隨意（例如 `broccolicam-ci`），存取權限選「App 管理」，按「產生」。然後按「下載」把 `.p8` 存下來。這個檔案只能下載一次，關掉頁面就拿不回來了，只能撤銷重建。

Issuer ID 和 Team ID 是帳號層級的，跟你其他 App 用的是同一組。

## 四、設成 GitHub secrets

在終端機跑下面四個指令，把引號裡的中文換成你的值。這一步我不能代做，金鑰要你自己貼。

```bash
gh secret set ASC_KEY_ID --repo domyweb666/Broccoli-Cam --body "你的KeyID"
```

```bash
gh secret set ASC_ISSUER_ID --repo domyweb666/Broccoli-Cam --body "你的IssuerID"
```

```bash
gh secret set APPLE_TEAM_ID --repo domyweb666/Broccoli-Cam --body "你的TeamID"
```

金鑰檔直接從檔案讀進去，不用打開複製。把檔名換成你選的那一把：

```bash
gh secret set ASC_KEY_P8 --repo domyweb666/Broccoli-Cam < "C:/Users/fcharlie/Downloads/AuthKey_XXXXXXXXXX.p8"
```

最後這個指令要在 Git Bash 跑。PowerShell 不吃 `<`，要改成：

```powershell
Get-Content -Raw "C:\Users\fcharlie\Downloads\AuthKey_XXXXXXXXXX.p8" | gh secret set ASC_KEY_P8 --repo domyweb666/Broccoli-Cam
```

設完檢查一下，應該列出四個名字：

```bash
gh secret list --repo domyweb666/Broccoli-Cam
```

不想用指令的話，也可以到 <https://github.com/domyweb666/Broccoli-Cam/settings/secrets/actions> 按「New repository secret」一個一個貼。`ASC_KEY_P8` 用記事本打開 `.p8`，從 `-----BEGIN PRIVATE KEY-----` 到 `-----END PRIVATE KEY-----` 整段貼上，包含這兩行。

## 五、觸發建置

secrets 設好之後不會自己重跑，要手動觸發一次：

```bash
gh workflow run iOS --repo domyweb666/Broccoli-Cam
```

或是跟我說一聲，我來觸發並盯著跑完。

整個流程約 5 到 8 分鐘：先編譯檢查，再封存、簽章、上傳。進度在 <https://github.com/domyweb666/Broccoli-Cam/actions>。

「上傳 TestFlight」那一步如果只跑幾秒就打勾，代表 secrets 沒讀到，被略過了。真的有上傳會跑好幾分鐘。

## 六、在手機上安裝

上傳成功後，Apple 還要處理 5 到 15 分鐘，處理完會寄一封信給你。

1. 到 App Store Connect → 花椰菜相機 → TestFlight 分頁，等版本出現，狀態從「處理中」變成可測試
2. 左邊「內部測試」旁邊按「＋」，建一個群組（名稱隨意），把你自己加進去
3. 在 iPhone 上從 App Store 裝「TestFlight」，用同一個 Apple ID 登入
4. 打開 TestFlight 就會看到花椰菜相機，按「安裝」

內部測試不用送審，處理完馬上可以裝。出口合規那題專案裡已經答好了，不會再問你。

之後每次我 push 到 `main` 都會自動上傳一個新版本，TestFlight 裡按「更新」就好。你之前說過不要每個小功能都發一版，所以我會累積到一批、等你開口才 push。

## 卡住的時候

建置失敗的話，把 Actions 頁面那次的連結丟給我，我去看 log。常見的幾種：

| 錯誤訊息裡有 | 原因 | 怎麼處理 |
|---|---|---|
| `No profiles for 'org.domyweb.broccolicam'` | Bundle ID 沒註冊，或打錯字 | 回第一步檢查 |
| `Authentication credentials are missing or invalid` | Key ID、Issuer ID、`.p8` 三個對不起來，或金鑰已撤銷 | 回第三步，確認三個值來自同一把有效的金鑰 |
| `does not have permission` 或 `forbidden` | 金鑰權限不夠 | 換一把「管理」或「App 管理」權限的 |
| `maximum number of certificates` | 帳號的發佈憑證數量滿了 | 到 <https://developer.apple.com/account/resources/certificates/list> 撤銷舊的 Apple Distribution 憑證 |
| `No suitable application records were found` | App Store Connect 還沒建這個 App | 回第二步 |

最後那個「憑證滿了」你很有機會遇到。你有好幾個 App 都走雲端自動簽章，每次都可能產生新憑證，而一個帳號能有的發佈憑證數量有上限。

## 裝好之後要測什麼

模擬器沒有相機，這是第一次真的在手機上跑。`README.md` 的「已知待真機確認的事項」列了八項，最要緊的三項：

1. 錄一段存進相簿，看影片方向和左右對不對
2. 稿子用空行分成三段，每段錄一次，看接起來的影片有沒有切到字、聲音和嘴型有沒有對上
3. 還沒按錄影時，麥克風旁邊的音量條會不會動

有問題就長按麥克風圖示 1 秒打開除錯層，按「複製」貼給我。
