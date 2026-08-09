# Lightroom MCP＋RAW 挑圖調色 Skill v2

這個 fork 把 Lightroom MCP 與完整的 `raw-photo-lightroom-preset` v2 skill 放在同一個 repository，涵蓋：

- RAW／JPG 配對與挑圖；
- 按光線場景分群；
- 讀取過往 Lightroom preset 的實際設定；
- 小步調整、輸出預覽、比較結果；
- 建立不覆寫舊版本的 preset checkpoint；
- 匯出 Lightroom 產生的 preset 檔案；
- MCP 不可用時的安全 XMP fallback。

上游專案仍保留為 [`Automaat/lightroom-mcp`](https://github.com/Automaat/lightroom-mcp)。使用 fork 而不是另開無關 repository，可以保留原始 commit、MIT 授權與未來同步 upstream 的能力；本機建議維持 `origin` 指向本 fork、`upstream` 指向原作者。

## Repository 內容

```text
plugin/LightroomMCP.lrplugin/       Lightroom Classic Lua 外掛
server/                             MCP server 與工具契約
skills/raw-photo-lightroom-preset/ 完整 v2 Codex skill
tests/e2e/                          Lightroom 實機驗證流程
```

Skill 目錄包含 `SKILL.md`、UI metadata、挑圖／調色／MCP 參考文件、風格資料、XMP 產生器及其測試；不含使用者照片、catalog、token 或本機絕對路徑。

## v2 挑圖流程

### 1. 先建立來源關係

每組 RAW／預覽至少記錄相對路徑、檔名 stem、拍攝時間、相機、尺寸與預覽產生方式。不同資料夾可能有相同檔名，所以不能只靠 basename 配對；缺漏或衝突項目標為 `未分類`，不繼承其他 JPG 的調色結論。

一般相機 JPG 可以先判斷構圖、對焦與表情；最終曝光、白平衡、色彩與 preset 方向必須用 Lightroom／Camera Raw 的 RAW render 判斷。

### 2. 三組狀態分開記錄

| 欄位 | 可用值 | 用途 |
|---|---|---|
| `selection_status` | `交付候選`、`保留`、`淘汰`、`待確認` | 構圖、焦點、表情與交付價值 |
| `edit_status` | `RAW 待檢`、`輕微全域調整`、`需局部調整`、`未知` | 後製工作量 |
| `style_status` | `已分類`、`未分類` | 是否已找到可靠的色調方向 |
| `confidence` | `high`、`medium`、`low` | 判斷可信度 |

不要自行把這些狀態映射成 Lightroom 星等或色標。若要映射，先由使用者明確定義，再把映射當成獨立欄位處理。

### 3. 按光線與用途分群

不要替整場活動硬套一個 preset。常見分群包括戶外陰影、室內暖／混合光、舞台光、逆光與高 ISO。每群先選一張代表 RAW，難處理的 outlier 保持獨立。

推薦的挑圖交付欄位：

```text
relative_raw_path, relative_preview_path, selection_status, edit_status,
style_status, lighting_cluster, confidence, notes
```

## 歷史色調迭代流程

1. 選一張不會破壞 master edit 的代表 RAW 或 virtual copy。
2. 讀取目前 metadata／Develop settings，輸出一張 baseline JPEG。
3. 用 `get_develop_preset` 讀取已認可的歷史 preset；同名時用 UUID 或 folder／scope 消除歧義。
4. 每次只做一小段：技術校正、明暗形狀、色彩校正、創意風格、細節／降噪。
5. 每段都從 Lightroom 輸出新預覽並實際比較，不一次猜大量滑桿。
6. 用 `create_develop_preset` 建立唯一、版本化的 plugin checkpoint。
7. 用 `compare_develop_presets` 比較歷史版本與候選版本，保留設定差異紀錄。
8. 代表照片確認後，才用明確欄位清單把設定複製到同一光線群。
9. 用 `export_develop_preset` 匯出接受的 checkpoint；若目的檔已存在，工具會拒絕覆寫。
10. 在目標 Lightroom 版本匯入並檢查後，才能宣稱 preset 相容且視覺結果正確。

## v0.10.0 新增的 MCP 工具

| 工具 | 功能 |
|---|---|
| `get_develop_preset` | 讀取一個精確 preset 的 UUID、來源檔與完整可序列化設定 |
| `compare_develop_presets` | 產生 base／candidate 的逐設定差異 |
| `create_develop_preset` | 從代表照片選定欄位建立版本化 checkpoint |
| `export_develop_preset` | 複製 Lightroom preset backing file，永不覆寫既有檔案 |

既有的 `list_develop_presets` 與 `apply_develop_preset` 也支援 UUID、folder、scope；`set_develop_settings`、`copy_develop_settings` 與 checkpoint 建立支援主曲線及 RGB point-curve arrays。

Adobe SDK 建立的 plugin-managed checkpoint 不會出現在 Develop 面板。它仍可由 MCP 列出、套用與匯出；若需要面板內可見的正式 preset，請匯出後由 Lightroom UI 匯入，或在 Lightroom 內使用 Create Preset。

## Windows 安裝

### 1. 建置本 fork

```powershell
git clone https://github.com/John-owo/lightroom-mcp.git
Set-Location .\lightroom-mcp
git switch feat/preset-roundtrip
Set-Location .\server
npm ci
npm run build
Set-Location ..
```

### 2. 安裝 Lightroom 外掛

```powershell
node .\server\dist\index.js install-plugin
```

完整關閉並重開 Lightroom Classic，再到「檔案 → 增效模組管理員 → Lightroom MCP」啟動 server。

### 3. 設定 Codex MCP

在 Codex 設定加入本機建置後的 `server/dist/index.js`；以下路徑請換成實際 clone 位置：

```toml
[mcp_servers.lightroom]
command = 'C:\Program Files\nodejs\node.exe'
args = ['D:\path\to\lightroom-mcp\server\dist\index.js']
startup_timeout_sec = 60
```

重新啟動 Codex，新的 task 才會載入 18 個工具。

### 4. 安裝 v2 skill

若已經有同名 skill，請先備份。接著在 repository 根目錄執行：

```powershell
$skillSource = Resolve-Path '.\skills\raw-photo-lightroom-preset'
$skillTarget = Join-Path $env:USERPROFILE '.codex\skills\raw-photo-lightroom-preset'
New-Item -ItemType Directory -Path $skillTarget -Force | Out-Null
Copy-Item -Path "$skillSource\*" -Destination $skillTarget -Recurse -Force
```

重新啟動 Codex 後，可使用：

```text
使用 $raw-photo-lightroom-preset 幫我挑這批 RAW，先分出交付候選與待確認，
再按光線分群。讀取我已認可的歷史 preset，只在代表照片上小步調整，
每輪輸出比較並建立不覆寫的版本化 checkpoint。
```

## 安全邊界

- 不移動、改名、刪除或覆寫原始照片。
- 不在未批准的 master edit 上測試。
- 不只看相機 JPG 就宣稱色彩或 preset 已完成。
- 不把 crop、白平衡、profile、鏡頭狀態或 detail 設定默默複製到整批。
- MCP 沒有 virtual copy、snapshot、undo 或完整局部工具；需要遮罩、修復、AI Denoise、Calibration、Color Grading 或 Point Color 時，交回 Lightroom 手動完成。
- MCP checkpoint 的 backing format 由 Lightroom 決定；內建 preset 若沒有 backing file，不能匯出。

## 已驗證範圍

- TypeScript：13 suites、160 tests 通過。
- Lua `HandlerDevelop`：28 個行為測試通過；Selene 0 errors／0 warnings／0 parse errors。
- Lightroom Classic 實機：建立 checkpoint、精確讀回、匯出 `.lrtemplate`、重複匯出拒絕且原檔 hash 不變，共 5／5 通過。
- XMP fallback generator：14 tests 通過，並具備副檔名、sidecar、覆寫、原子寫入、schema 與範圍保護。

實機測試沒有透過 Lightroom UI 再匯入匯出的 `.lrtemplate`，因此不把「目標 Lightroom 匯入相容」或「視覺風格正確」列為已通過；這兩項必須用實際照片與使用者確認。

## 進一步文件

- [v2 skill 主流程](skills/raw-photo-lightroom-preset/SKILL.md)
- [挑圖、分群與五階段調色](skills/raw-photo-lightroom-preset/references/workflow.md)
- [風格庫](skills/raw-photo-lightroom-preset/references/style-library.md)
- [Lightroom MCP 邊界與 closed loop](skills/raw-photo-lightroom-preset/references/lightroom-mcp.md)
- [上游英文 README](README.md)

授權沿用 repository 的 [MIT License](LICENSE)。
