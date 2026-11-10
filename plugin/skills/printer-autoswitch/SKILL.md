---
name: printer-autoswitch
description: 讓 Mac 的預設印表機跟著地點換：依目前連得到哪台印表機自動設定預設印表機，由 launchd 在網路變動時與每 10 分鐘執行。使用者說「在家預設用這台、到辦公室用那台」「依網路自動切換印表機」「預設印表機老是不對」「換地方要重選印表機很煩」，或要停用、檢查這個自動切換時使用。只處理 URI 裡有主機的網路印表機；USB、雲端列印與只靠 Bonjour 的佇列不在範圍。
allowed-tools:
  - Read
  - Bash(lpstat *)
---

# printer-autoswitch：預設印表機跟著地點換

這個 skill 安裝一個 launchd agent：它照設定檔的順序測每台印表機連不連得到，把第一台連得到的設成預設；一台都連不到時不更動。

判斷依據是「印表機的那個位址與埠現在有沒有回應」，不是 Wi-Fi 名稱。所以有線、無線都適用，也不需要定位權限。

## 先知道：macOS 自己也有一個依網路記住印表機的設定

「系統設定 → 印表機與掃描器 → 預設印表機」選「上次使用的印表機」時，CUPS 會依目前網路的路由器位址，記住你在每個網路上次用的那一台，回到那個網路就把它當預設。這個設定沒動過時是開的。（依據是 Apple 公開的 CUPS 原始碼 `cups/dest.c` 的 `_cupsAppleCopyDefaultPrinter`；macOS 27 內建的版本沒有另外查證。）

兩者的差別：

| | macOS 內建（上次使用的印表機） | 這個 agent |
|---|---|---|
| 依據 | 路由器位址，加上你上次在那裡印過哪台 | 清單裡哪台印表機現在連得到 |
| 新地點 | 要先在那裡印過一次才會記得 | 設定檔寫好就生效 |
| 會認錯的情況 | 兩個網路的路由器位址相同（很常見的位址會撞） | 另一個網路上剛好有別的裝置在同一個位址、同一個埠回應 |
| 要裝東西 | 不用 | 要裝 launchd agent |

**這個 agent 只在「預設印表機固定為某一台」的模式下實測過。** 兩個機制同時開的行為沒有驗證。所以 Step 1 會先看這台 Mac 是哪個模式。

## Step 0：建立任務清單

用 TaskCreate 建立下面六個 task（subject 直接複製），一次建完。做完一個就標 completed。

要先建清單的原因：安裝指令成功不代表會切換。第 5 步的實測曾經抓到「預設印表機有兩層、只改一層看起來像沒事」的錯，跳過它就會把沒作用的設定交出去。

| # | subject | 類型 |
|---|---|---|
| 1 | 讀現況：預設模式、佇列、agent 狀態 | 機械 |
| 2 | ⚠️ 決定印表機清單與順序 | **判斷** |
| 3 | 寫設定檔 | 機械 |
| 4 | 安裝 agent | 機械 |
| 5 | 實測切換 | 驗證 |
| 6 | 回報：已驗證與未驗證的範圍 | 驗證 |

## 腳本位置

`${CLAUDE_PLUGIN_ROOT}/scripts/` 底下有三個腳本。這個路徑讀不到時，改用載入本 skill 時顯示的 base directory 往上兩層的 `scripts/`。

| 腳本 | 用途 |
|---|---|
| `printer-probe.sh` | 唯讀檢查（佇列、可達性） |
| `install-autoswitch.sh` | `init-config`／`install`／`status`／`uninstall` |
| `printer-autoswitch.sh` | 實際切換的腳本；安裝時會複製到 `~/Library/Application Support/mac-printer-setup/` |

這台 Mac 上相關的檔案：

| 檔案 | 誰寫的 | 內容 |
|---|---|---|
| `~/.config/mac-printer-setup/printers.conf` | `init-config` 寫範本，之後由你編輯 | 印表機清單。plugin 更新與 `uninstall` 都不會動它 |
| `~/Library/Application Support/mac-printer-setup/printer-autoswitch.sh` | `install` | 腳本的副本。plugin 的 cache 路徑每個版本都不同，agent 不能指向 cache |
| `~/Library/LaunchAgents/io.github.machelpdesk.printer-autoswitch.plist` | `install` | launchd agent |
| `~/Library/Logs/mac-printer-setup.log` | 切換腳本 | 第一次改變預設或出錯時才出現，之後每次改變或出錯加一行 |

## 行為界線

- 寫設定檔、安裝 agent、停用 agent 都是可逆的，照使用者的要求做完再回報，不逐步確認。
- 設定檔已經有印表機時，先讀出來給使用者看，再改。不要整個覆寫。
- 印表機的位址只寫進使用者自己的設定檔，不寫進 plugin 的任何檔案。
- 不替使用者改「預設印表機」的模式。Step 1 發現是「上次使用的印表機」時，由使用者決定，見該步驟。
- Step 5 的實測會暫時把預設印表機改成另一台，約十秒後由 agent 改回來。實測失敗時，照 Step 5 的說明手動改回原本的預設。

## Step 1：讀現況

```bash
install-autoswitch.sh status
printer-probe.sh queues
```

**先看 `status` 最後一行的 `default printer mode`。**

- `fixed`：繼續。
- `Last Printer Used`：停下來，把上面那張比較表的重點告訴使用者，問他要哪一種。這個答案決定後面做不做，所以要問：
  - 用 macOS 內建的：不安裝 agent。已經裝了的話（從 Step 4 回到這裡），先跑 `install-autoswitch.sh uninstall`。告訴他在每個地點各印一次，之後就會記得。到此結束。
  - 用這個 agent：請他自己到「系統設定 → 印表機與掃描器 → 預設印表機」選一台固定的印表機，改好後再跑一次 `status` 確認變成 `fixed`，然後繼續。

`queues` 的 STATUS 欄決定哪些佇列能放進清單：

| STATUS | 能不能放進清單 |
|---|---|
| `reachable`／`unreachable` | 可以。HOST 與 PORT 的取法見 Step 3 |
| `bonjour` | 不行，URI 裡沒有主機。使用者要把它放進清單時，轉到 `printer-diagnose`，那裡有「改成固定位址」的入口；它會先說明代價。這件事要在那台印表機所在的地點做；人不在那裡，這次先不放進清單 |
| `not-probed` | 不行（USB、雲端列印，或 URI 測不了） |

## Step 2：⚠️ 決定印表機清單與順序

這一步決定之後的行為，要想清楚再寫。

- 每個地點放一台。`reachable` 的意思只是「那個位址與埠從這裡現在有回應」；`unreachable` 可能是印表機在別的地點，也可能是它關機，或佇列記著舊位址。哪台在哪個地點，以使用者說的為準，不從 STATUS 推斷。
- **順序只在兩台同時有回應時才有差別**，排前面的那台永遠贏。一個地點有兩台都連得到的印表機時，只放使用者要當預設的那一台。
- 使用者連著 VPN 時，辦公室的印表機可能在家也連得到。他有這種情況的話，把「在家要用的那台」排前面。
- 使用者已經說了哪個地點用哪台，就照做。只有在一個地點有兩台以上的候選、而且使用者沒說要哪台時才問，一次問完。

範例。使用者說「在家用 Home_Printer，到辦公室用 Office_Printer」，`queues` 顯示：

```
Home_Printer     reachable     ipp://192.0.2.10/ipp/print        Example Model A
Office_Printer   unreachable   ipp://198.51.100.20/ipp/print     Example Model B
```

清單就是這兩台，家裡的排前面。

## Step 3：寫設定檔

```bash
install-autoswitch.sh init-config
```

設定檔不存在時，這會寫一份全是註解的範本；已存在就不動。接著用 Read 讀檔，再用 Edit 加上清單。每行一台，欄位用空白分隔，`#` 之後是註解：

```
# QUEUE          HOST            [PORT]
Home_Printer     192.0.2.10
Office_Printer   198.51.100.20   631
```

- QUEUE：`queues` 輸出的名稱，原樣照抄。
- HOST：佇列 URI 裡 `://` 之後、下一個 `/` 之前的主機（位址或主機名稱都可以）。URI 裡有 `:埠` 時，那個埠寫到 PORT。
- PORT：依 URI 的協定。`ipp`、`ipps` 是 631（可以省略）；`socket` 是 9100；`lpd` 是 515；`http` 是 80；`https` 是 443。

## Step 4：安裝 agent

```bash
install-autoswitch.sh install
```

設定檔裡沒有任何印表機時，它會拒絕安裝（exit 2）。已經裝過就重新載入，可以重複執行。輸出最後若有 `note:` 開頭的段落，那是預設模式的提醒，回到 Step 1 處理。

## Step 5：實測切換

三項都要做，每一項都看實際輸出。

1. 手動跑一次：
   ```bash
   bash "$HOME/Library/Application Support/mac-printer-setup/printer-autoswitch.sh" --now
   ```
   正常的輸出是這三種之一：
   - `default is already <佇列>`：已經正確。
   - `default printer: system=… user=… -> <佇列>`：剛切換，log 也會多這一行。
   - `no configured printer is reachable; default left alone`：清單裡的印表機現在都沒有回應。

   出現下面任何一種就停下來，把原文回報給使用者，不要繼續：
   - `config names a queue that does not exist: <名稱> (skipped)`：設定檔的 QUEUE 寫錯，或佇列被刪了。
   - `could not set the system default to …`／`could not set the user default to …`：這個帳號不能改預設印表機。
   - `no config at …`／`config has no printer lines: …`：設定檔不在或沒有內容。

2. 安裝後等 10 秒，再看狀態（agent 載入時會先跑一次，其中 5 秒在等網路穩定）；清單裡現在沒有回應的印表機，每多一台再加 2 秒：
   ```bash
   install-autoswitch.sh status
   ```
   要看到 `agent loaded`，而且 `last exit code = 0`。

3. 由 launchd 實際切一次。先記下現在的預設，把它改成另一個存在的佇列，再觸發 agent：
   ```bash
   lpadmin -d <另一個佇列>
   launchctl kickstart "gui/$(id -u)/io.github.machelpdesk.printer-autoswitch"
   ```
   等 10 秒；清單裡排在「現在連得到的那台」前面的印表機，每多一台再加 2 秒。然後跑 `printer-probe.sh queues`，開頭的系統層要回到清單裡連得到的那一台，log 多一行 `default printer: … -> <佇列>`。

   沒有切回來時，用 `lpadmin -d <原本的預設>` 手動改回，然後讀 log 找原因，不要回報成功。

第 3 項在下面兩種情況跳過，只有這兩種；跳過時在回報中寫明「切換沒有實測」：

- 清單裡的印表機現在都沒有回應。
- 這台 Mac 只有一個佇列，沒有「另一個佇列」可以暫時切過去。

## Step 6：回報

回報要短，但下面五點都要有：

- 清單裡有哪幾台、各自對應哪個地點。
- 哪些情境實測過。照實寫：通常只有使用者目前所在的地點測得到，其他地點要等到了現場才驗得到。
- 三個使用上的後果：
  - 在清單內的印表機連得到的地方，手動把預設改成別台，10 分鐘內會被改回來。單次列印時在列印對話框另選印表機不受影響。
  - 印表機的位址變了（DHCP），佇列與設定檔都要跟著改。`printer-diagnose` 改佇列時會順便檢查設定檔。
  - 判斷只看位址與埠有沒有回應。到了別的網路，那個位址上剛好有別的裝置開著同一個埠，預設就會被設成清單裡那一台，而且不會出聲。
- 怎麼停用：`install-autoswitch.sh uninstall`（保留設定檔與 log）。
- 改了 `printers.conf` 不用重新安裝，下一次執行就會讀到。plugin 更新之後，要重跑一次 `install` 才會用到新版的切換腳本。

## 已驗證與未驗證

macOS 27.3，帳號屬於 `admin` 與 `_lpadmin` 群組，預設印表機模式為固定，2026-11-11。

| 行為 | 狀態 |
|---|---|
| 安裝後 launchd 立刻執行一次；已載入時重複安裝 | 已實測 |
| `launchctl kickstart` 觸發後，把改錯的預設改回來（系統層與使用者層） | 已實測 |
| 關閉再開啟 Wi-Fi 會觸發 agent | 已實測（關閉時 1 次，開啟後 2 次） |
| 從 launchd 執行 `lpadmin -d` 不需要密碼 | 已實測，僅上述群組的帳號 |
| `uninstall` 卸載並移除 agent 與腳本副本 | 已實測 |
| 第一台連不到時切到第二台、設定檔各種寫法、指令失敗時的回傳值 | 只有測試腳本用替身指令驗過（44 項），沒有在實際的第二個地點驗過 |
| 預設印表機模式為「上次使用的印表機」時與這個 agent 並用 | 未驗證 |
| 不關 Wi-Fi、直接連到另一個網路時會觸發 | 未驗證 |
| 插拔網路線會觸發 | 未驗證 |
| 監看 `/private/var/run/resolv.conf` 有作用 | 未驗證（開關 Wi-Fi 的測試裡這個檔案沒有被改寫，那次的觸發來自 `/Library/Preferences/SystemConfiguration`） |
| 不在這兩個群組的帳號 | 未驗證 |

未驗證的觸發情境有保底：agent 每 10 分鐘執行一次，所以最慢 10 分鐘內會切換。回報時不要把未驗證的項目說成會即時切換。

## 為什麼兩層預設都要設

預設印表機有系統層（`lpadmin -d`）與使用者層（`~/.cups/lpoptions`）。`lpstat -d` 在有使用者層時只回報使用者層，系統層錯了也看不出來。腳本分開讀兩層：系統層一定設；使用者層只在已經存在時才跟著設，不會替沒有使用者層的機器新建一個。
