# Changelog

## 0.1.0 — 2026-11-11

第一版。

### Skills

- `printer-diagnose`：Mac 連不到網路印表機時逐層查，並把佇列改到連得到的位址。
- `printer-autoswitch`：安裝 launchd agent，依目前連得到哪台印表機設定預設印表機。

### Scripts

- `printer-probe.sh`：唯讀檢查，六個子命令（`queues`、`net`、`bonjour`、`scan`、`identify`、`wifi-direct`）。
- `printer-autoswitch.sh`：讀 `~/.config/mac-printer-setup/printers.conf`，把第一台連得到的印表機設成預設。
- `install-autoswitch.sh`：`init-config`、`install`、`status`、`uninstall`。

### 實測範圍

macOS 27.3、一台 Epson 噴墨複合機（IPP）、家用兩層路由器。

- 已實測：六個 `printer-probe.sh` 子命令；用 `lpadmin -p … -v …` 把 Bonjour 佇列改成位址型佇列；`install`、重複 `install`、`uninstall`、`status`；launchd 載入後執行、`kickstart` 觸發後改回預設；關閉再開啟 Wi-Fi 會觸發 agent；透過本機 marketplace 安裝後 Claude Code 載入兩個 skill。
- 只在測試裡驗過：第一台連不到時切到第二台、設定檔的各種寫法（行內註解、CRLF、最後一行沒有換行）、指令失敗時的回傳值（`tests/test_autoswitch.sh`，44 項）；安裝腳本拒絕沒有可用印表機的設定檔（`tests/test_install.sh`，10 項）。
- 未驗證：不關 Wi-Fi 直接換網路、插拔網路線是否觸發 agent；與 macOS 內建的「上次使用的印表機」模式並用；其他廠牌的印表機；其他 macOS 版本；新增佇列；`cancel -a`。

### 發布前的獨立審查

一位沒有參與撰寫的審查者對照腳本與文件，回報 1 個阻擋級、11 個該修、13 個小問題。除了下面列為「沒有照建議做」的一項，其餘都在這一版改了程式或文件。最重要的三項：

- 掃描第二跳的私有網段原本只要求告知。那個網段可能屬於電信業者或大樓，現在一定要先問，使用者回答是才掃。
- 修改佇列的指令原本帶 `-E`，會順便啟用佇列；等待中的工作也會在佇列修好後直接印出來。現在不帶 `-E`，並在修改前先列出等待中的工作、詢問要不要取消。
- 文件原本寫「macOS 沒有依地點切換預設印表機的設定」，這是錯的。現在照實說明內建的「上次使用的印表機」，並在安裝時回報目前的模式。

沒有照建議做的一項：審查者建議把預設印表機設成「上次使用的印表機」實測一次，再把結果記進表格。這一版沒有做這個實測，改成在文件標為未驗證，並由 `install` 與 `status` 回報目前的模式、提醒不要並用。

修正之後又請第二位審查者只看兩份 skill 與三個腳本，檢查文件與程式不符、封閉列舉被擴大、表格漏列。他回報 0 個阻擋級、8 個該修、6 個小問題，都是文件裡流程接不起來的地方（例如只開 9100 的主機指認之後沒有下一步、沒有佇列時後面的步驟卻要求有佇列），全部改了。這些修正之後沒有再送第三次審查。
