# mac-printer-setup

Mac 的網路印表機連線與預設設定。印不出來時，找出印表機在網路的哪一層並修好佇列；換地點時，讓預設印表機自己跟著換。

與 [`mac-network-test`](https://github.com/MacHelpdesk/mac-network-test) 同一個系列。

> **狀態：v0.1.0。** 行為在 macOS 27.3、一台 Epson 噴墨複合機（IPP）、家用兩層路由器的環境下實測。其他廠牌與 macOS 版本沒有實測；skill 內每個行為都標了「已實測」或「未驗證」。

## 它解決什麼

| 你遇到的 | 原因 | 用 |
|---|---|---|
| 印表機開著，Mac 卻找不到 | 印表機接在另一層路由器（例如數據機下面再接一台路由器），Bonjour 廣播過不來 | `printer-diagnose` |
| 換了網路或重開路由器之後印不了 | 佇列記著舊位址 | `printer-diagnose` |
| 佇列顯示閒置，工作卻送不出去 | 這個佇列屬於別的地點 | `printer-diagnose` |
| 在家和辦公室要一直重選印表機 | 預設印表機固定在某一台，不會跟著地點換 | `printer-autoswitch`（或 macOS 內建的設定，見下方） |

涵蓋範圍是封閉的：有固定位址或 Bonjour 的網路印表機（IPP）。USB 印表機、雲端列印、驅動、卡紙、耗材都不處理。

## Skills

| Skill | 做什麼 |
|---|---|
| `/mac-printer-setup:printer-diagnose` | 逐層查：佇列與可達性 → 本機網路位置與第二跳 → Bonjour → 掃描與辨識 → 把佇列改到連得到的位址 |
| `/mac-printer-setup:printer-autoswitch` | 安裝 launchd agent：照你的清單測每台印表機，把第一台連得到的設成預設；一台都連不到就不更動 |

## 安裝

```bash
/plugin marketplace add MacHelpdesk/mac-helpdesk
/plugin install mac-printer-setup@mac-helpdesk
```

## 使用

```
家裡的印表機開著，但 Mac 找不到它
→ /mac-printer-setup:printer-diagnose

在家預設用家裡那台，到辦公室用辦公室那台
→ /mac-printer-setup:printer-autoswitch
```

腳本不透過 Claude Code 也能用。clone 這個 repo 之後：

```bash
plugin/scripts/printer-probe.sh queues              # 每個佇列的位址與連不連得到
plugin/scripts/printer-probe.sh net                 # 本機位址、閘道、第二跳是不是私有網段
plugin/scripts/printer-probe.sh bonjour             # 這個網段上廣播中的印表機
plugin/scripts/printer-probe.sh scan A.B.C          # A.B.C.0/24 裡哪些主機開著列印埠（只接受私有網段）
plugin/scripts/printer-probe.sh identify <位址>     # 那個位址上的印表機型號與 UUID

plugin/scripts/install-autoswitch.sh init-config    # 寫一份設定檔範本
plugin/scripts/install-autoswitch.sh install        # 安裝並載入 agent
plugin/scripts/install-autoswitch.sh status
plugin/scripts/install-autoswitch.sh uninstall      # 保留設定檔與 log
```

`scan` 會對一個 /24 的每個位址試兩個埠（631、9100），再對檢查用的主機試最多四個埠。只在你自己管的網路上用，旅館、會場、公司的網路不要掃。`net` 顯示的第二跳私有網段也一樣：它可能是你自己的第二台路由器，也可能是電信業者或大樓的設備，確定是你的才掃。

## 自動切換的設定檔

`~/.config/mac-printer-setup/printers.conf`，每行一台，越上面越優先：

```
# QUEUE          HOST            [PORT]
Home_Printer     192.0.2.10
Office_Printer   198.51.100.20   631
```

- QUEUE：`lpstat -e` 列出的佇列名稱。
- HOST：佇列 URI 裡的主機，位址或主機名稱都可以。URI 是 `dnssd://` 開頭的佇列沒有主機，不能列進來。
- PORT：省略時是 631（`ipp`、`ipps`）；`socket` 用 9100，`lpd` 用 515。
- `#` 之後是註解。

## macOS 內建的做法

「系統設定 → 印表機與掃描器 → 預設印表機」選「上次使用的印表機」時，系統會依目前網路的路由器位址，記住你在每個網路上次用的那一台。這個設定沒動過時是開的。（依據是 Apple 公開的 CUPS 原始碼 `cups/dest.c`；macOS 27 內建的版本沒有另外查證。）

它不用裝任何東西，但要先在每個地點印過一次，而且兩個網路的路由器位址相同時會認錯。`printer-autoswitch` 改看印表機實際連不連得到，設定檔寫好就生效。

兩個不要同時用：這個 plugin 的 agent 只在「預設印表機固定為某一台」的模式下實測過，`install` 與 `status` 會告訴你目前是哪個模式。

## 這個 repo 只放方法與工具

這個 repo 是公開的。你的印表機清單、位址、診斷輸出都不在這裡，而在你家目錄的 `~/.config/mac-printer-setup/`：

- `printers.conf`：自動切換的印表機清單。
- `records/`：想留診斷紀錄時放這裡，一次一個檔案。`printer-probe.sh` 的輸出只印在終端機，不會自己寫檔；它含有位址、佇列名稱與裝置序號。
- 想留修改紀錄，就在那個資料夾 `git init`。只留在本機就好：清單只有幾行，壞了重做很便宜，不值得為了備份讓它離開你的電腦。

回報問題時，把位址換成 `192.0.2.x`，佇列換成 `Home_Printer` 這類名稱，拿掉 Wi-Fi 名稱與序號。

這個 repo 的 `.gitignore` 擋掉 `printers.conf`、`records/`、`results/`，CI 也會檢查追蹤的檔案裡有沒有私有網段的位址與家目錄路徑。

## 要知道的六件事

1. **Bonjour 過不了路由器，位址連線過得了。** 印表機接在另一層路由器時，靠 Bonjour 的佇列會失效，改成 `ipp://<位址>/ipp/print` 就能印。
2. **改成固定位址之後，位址換了就要再改一次。** 位址是路由器用 DHCP 分配的。要一勞永逸，在路由器上把位址綁定給印表機，或把印表機改接到 Mac 所在的那台路由器。
3. **預設印表機有兩層。** 系統層（`lpadmin -d`）與使用者層（`~/.cups/lpoptions`）。`lpstat -d` 有使用者層時只回報使用者層，所以只改系統層會看起來像沒改。
4. **看得到印表機的 Wi-Fi Direct（`DIRECT-…`），不代表它沒連上區域網路。** 它可以同時用網路線接著。
5. **自動切換會把你手動改的預設改回來。** 在清單內的印表機連得到的地方，10 分鐘內會改回清單裡那一台。單次列印時在對話框另選印表機不受影響。
6. **自動切換只看位址與埠有沒有回應。** 到了別的網路，那個位址上剛好有別的裝置開著同一個埠，預設就會被設成清單裡那一台。連著 VPN 時，辦公室的印表機在家也可能連得到，所以把在家要用的那台排前面。

## 自動切換驗證到哪裡

| 行為 | 狀態 |
|---|---|
| 安裝、重複安裝、移除；手動觸發後把改錯的預設改回來 | 已實測 |
| 關閉再開啟 Wi-Fi 會觸發 | 已實測 |
| 第一台連不到時切到第二台、設定檔的各種寫法、指令失敗時的回傳值 | 只在測試裡用替身指令驗過（44 項） |
| 不關 Wi-Fi 直接換網路、插拔網路線會觸發 | 未驗證；每 10 分鐘的定時執行是保底 |
| 與「上次使用的印表機」模式並用 | 未驗證 |

## 需求

- macOS（實測 27.3），內建的 CUPS 工具：`lpstat`、`lpadmin`、`lpoptions`、`ipptool`
- 自動切換需要帳號能執行 `lpadmin -d`（實測的帳號屬於 `admin` 與 `_lpadmin` 群組）

## 相關

- [`mac-network-test`](https://github.com/MacHelpdesk/mac-network-test)：Mac 網路瓶頸診斷（Wi-Fi、閘道還是上游）
