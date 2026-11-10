# mac-printer-setup — CLAUDE.md

## Purpose

Mac 的網路印表機連線與預設設定。兩件事：印不出來時找出印表機在網路的哪一層並修好佇列；讓預設印表機跟著地點換。

與 [`mac-network-test`](https://github.com/MacHelpdesk/mac-network-test) 同一個系列：先量測，再判讀，最後才動手。

範圍是**封閉的，只有有固定位址或 Bonjour 的網路印表機（IPP）**。USB 印表機、雲端列印（例如 `epsonremote://`）、驅動、卡紙、耗材都不涵蓋，遇到就說明沒涵蓋，不依性質相似類推。

## Skills

| Skill | 用途 |
|-------|------|
| `/mac-printer-setup:printer-diagnose` | 連不到印表機時逐層查：佇列與可達性 → 本機網路位置與第二跳 → Bonjour → 掃描與辨識 → 修改佇列 |
| `/mac-printer-setup:printer-autoswitch` | 安裝 launchd agent，依目前連得到哪台印表機設定預設印表機；也負責檢查與停用 |

## Repo 結構

```
mac-printer-setup/
├── plugin/                    # 被安裝進 Claude Code 的部分
│   ├── .claude-plugin/plugin.json
│   ├── skills/printer-diagnose/、skills/printer-autoswitch/
│   └── scripts/
├── tests/test_autoswitch.sh
└── README.md、CLAUDE.md、CHANGELOG.md、LICENSE
```

根目錄給人看與開發用；`plugin/` 以外的檔案不會被安裝。marketplace 索引在 [`MacHelpdesk/mac-helpdesk`](https://github.com/MacHelpdesk/mac-helpdesk)，用 `git-subdir` 來源指向這個 repo 的 `plugin/`。

## Scripts

| 腳本 | 用途 | 會不會改設定 |
|---|---|---|
| `plugin/scripts/printer-probe.sh` | `queues`／`net`／`bonjour`／`scan`／`identify`／`wifi-direct` | 不會 |
| `plugin/scripts/printer-autoswitch.sh` | 讀設定檔，把第一台連得到的印表機設成預設 | 只改預設印表機 |
| `plugin/scripts/install-autoswitch.sh` | `init-config`／`install`／`status`／`uninstall` | 寫使用者家目錄下的三個檔案（設定檔範本、腳本副本、launchd agent）；log 由切換腳本在第一次改變或出錯時建立 |

測試用替身指令取代 `nc`／`lpstat`／`lpadmin`／`lpoptions`，不碰 CUPS 與網路：

```bash
bash tests/test_autoswitch.sh
```

## 紀律

- **隱私**：這是公開 repo。印表機位址、Wi-Fi 名稱、印表機 UUID 與序號、本機路徑都不寫進任何檔案。範例位址一律用 RFC 5737 的 `192.0.2.x`、`198.51.100.x`，佇列用 `Home_Printer`、`Office_Printer` 這類佔位名稱。使用者的印表機清單只存在他自己的 `~/.config/mac-printer-setup/printers.conf`。在這個 repo 工作時看到的實際輸出要留存，就寫進 `~/.config/mac-printer-setup/records/`，不寫進這個 repo，也不貼進 issue。
- **只寫實測過的行為**：skill 裡的行為標了「已實測」或「未驗證」，`printer-autoswitch` 有一張完整的表。改腳本之後重新實測，再改狀態；沒測的不要改成已實測。
- **主動連線的界線寫在 `printer-diagnose` 的〈行為界線〉**，是封閉列舉，一共五種。`printer-probe.sh scan` 自己只擋非私有網段；能不能掃某個網路由 skill 判斷，不要把判斷搬進腳本後就當作 skill 不用管。第二跳的私有網段不一定是使用者的（可能是電信業者或大樓的設備），skill 規定要先問，腳本的輸出也不可以寫成「這是你的上層網段」。
- **替 `printer-probe.sh` 加會開連線的子命令時**，同時改三處：腳本開頭的清單、`printer-diagnose` 的五種主動連線、README 的說明。
- **腳本維持 bash 3.2 相容**（macOS 內建的 `/bin/bash`）：不用關聯陣列、不用 `local -n`。
- **不要解析 `lpstat -v`／`-p`／`-d` 的文字取名稱**：它跟著系統語言走，`LC_ALL=C` 改不了。名稱用 `lpstat -e`（再用 `lpstat -p <名稱>` 的結束碼確認是已安裝的佇列），URI 與型號用 `lpoptions -p`。`lpstat -d` 是例外，沒有別的方法讀系統層預設，所以取最後一個冒號之後的字，再用 `lpstat -p <名稱>` 確認它是真的佇列。
- **macOS 內建的「上次使用的印表機」**（`org.cups.PrintingPrefs` 的 `UseLastPrinter`，沒設過視為開啟）會依網路記住印表機。這個 agent 只在它關閉時實測過；`install` 與 `status` 會回報目前的模式，skill 由使用者決定用哪一個。文件不可以寫「macOS 沒有依地點切換的設定」。
- **launchd agent 不能指向 plugin cache**：cache 路徑每個版本都不同。`install` 會把腳本複製到 `~/Library/Application Support/mac-printer-setup/`；改了 `printer-autoswitch.sh`，使用者要重跑一次 `install` 才會用到新版，CHANGELOG 要寫明。

## Git 流程

整個 MacHelpdesk 系列共用，正本在 [`mac-helpdesk` 的 CLAUDE.md](https://github.com/MacHelpdesk/mac-helpdesk/blob/main/CLAUDE.md)。這個 repo 的重點：

- `main` 永遠是可發布狀態。工作在短分支 `idd/<issue>-<slug>`，開 PR，squash merge。
- 發布是一個 PR 裡的三件事：bump `plugin.json` 的 version、更新 `CHANGELOG.md`、合併後在 `main` 打 tag `vX.Y.Z`。
- marketplace 索引追這個 repo 的 `main`，沒有釘版本。所以改了 `plugin/` 就要 bump 版本，CI 會檢查。
- CI（`.github/workflows/ci.yml`）跑五項：`/bin/bash -n`、測試、manifest 是合法 JSON、`scripts/check-privacy.sh`、PR 上的 `scripts/check-version-bump.sh`。

`scripts/`（repo 根目錄的）是開發用的檢查腳本，不會被安裝；`plugin/scripts/` 才是 plugin 的一部分。

## Development

- 每次改動都 bump `plugin/.claude-plugin/plugin.json` 的 version，並更新 `CHANGELOG.md`。不 bump，`claude plugin update` 不會更新 cache
- 版本只寫在這個 repo 的 `plugin.json`；`mac-helpdesk` 的 marketplace 索引不重複寫版本
- 改了 skill 清單或 description，同步 `README.md`，以及 `mac-helpdesk` 索引裡這個 plugin 的描述
- 本機測 plugin：`claude --plugin-dir plugin`；格式檢查：`claude plugin validate plugin`
- skill 內用 `${CLAUDE_PLUGIN_ROOT}/scripts/` 找腳本
