# aiDAPTIVClaw WSL Sandbox — 安全性驗收測試

> 對應實作：`installer/wsl/`、`docs/plans/2026-04-23-wsl-sandbox-design.md` 的
> `🔄 REVISION 2026-04-26`（前景啟動模型）與 `🔄 REVISION 2026-04-27`
> （`windowsbridge` 安裝期勾選框）。
>
> **測試立場**：假設 OpenClaw gateway（或它載入的 LLM tool code）已被攻擊者控制，
> 攻擊者擁有 `openclaw` 帳號的全部權限。本清單驗證在這個前提下，他**做不到**哪些事，
> 以及刻意保留給他**做得到**的範圍是否如設計書所述。
>
> **不是測試**：產品功能（gateway 是否能回 chat、UI 是否能渲染、cloud provider
> 設定是否正確）。那是 product QA，不是 security QA。

---

## 0. 測試環境

### 0.1 兩個 distro：STRICT 與 PERMISSIVE 都要測

唯一可靠的方式是**裝兩次**：第一次安裝把 `windowsbridge` 維持未勾選，跑完整套
A / B / D / E / F；解除安裝後重裝、把 `windowsbridge` 勾起來，再跑一次 A / C / D / E / F。

如果只想跑一輪，**至少要驗 STRICT**——那是預設值、絕大多數使用者會跑到的模式，
也是設計書宣稱的核心 mitigation。PERMISSIVE 的測試重點不是「擋住」而是「確實有開」
（不然使用者勾了卻沒生效就是另一種 bug）。

### 0.2 共用變數（PowerShell，已開好的安裝完成後執行）

```powershell
# Windows host side
$Distro = 'aidaptivclaw'

# Helper: run a command AS THE openclaw USER inside the distro and print
# both stdout and the exit code. Mirror what a compromised gateway can do.
function Test-AsOpenClaw {
    param([string]$Cmd, [string]$Label)
    Write-Host ""
    Write-Host "--- $Label ---" -ForegroundColor Cyan
    & wsl.exe -d $Distro -u openclaw -- bash -c $Cmd
    Write-Host "[exit] $LASTEXITCODE" -ForegroundColor DarkGray
}
```

### 0.3 PASS / FAIL 慣例

每一條測試都註明預期：

- **PASS = exit 0 + 預期輸出** 表示防線有效（或功能確實開啟）。
- **PASS = exit 非 0** 表示「攻擊者試了但失敗」，這是好事。
- **FAIL** 都會註明顯示樣態，遇到請當作真實 incident。

### 0.4 確認當前模式（每輪測試前必跑）

```powershell
# Should show "# MODE: STRICT SANDBOX (...)" or "# MODE: PERMISSIVE (...)"
& wsl.exe -d $Distro -u root -- head -1 /etc/wsl.conf
```

如果這行**不**以 `# MODE:` 開頭，表示安裝來自舊版 installer（沒有寫 marker），
那這份測試清單的「mode-dependent」結果就無法依此判斷，請改用 `[automount]
enabled` 的實際值來推斷：

```powershell
& wsl.exe -d $Distro -u root -- grep -E '^enabled=' /etc/wsl.conf
```

---

## A. 基礎隔離（兩種模式皆應通過）

> 這一組是 OpenClaw 在 WSL 內**不論 windowsbridge 開關**都應該擋住的東西，
> 全部由 provision.sh 與 systemd unit（即使停用）保證。

### A.1 `openclaw` 帳號無 root 權限

```powershell
Test-AsOpenClaw -Label "A.1 sudo with no password" -Cmd 'sudo -n true 2>&1'
```

- **PASS**：輸出 `sudo: a password is required` 或 `openclaw is not in the sudoers file`，exit 非 0。
- **FAIL**：exit 0，表示 openclaw 可以無密碼提權。

```powershell
Test-AsOpenClaw -Label "A.1b try password sudo" -Cmd 'echo "" | sudo -S true 2>&1'
```

- **PASS**：exit 非 0；任何「password incorrect / not in sudoers」訊息。

### A.2 不在任何 privileged group

```powershell
Test-AsOpenClaw -Label "A.2 group membership" -Cmd 'id'
```

- **PASS**：輸出僅 `uid=1000(openclaw) gid=1000(openclaw) groups=1000(openclaw)`。
- **FAIL**：出現 `sudo` / `wheel` / `adm` / `root` / `lxd` / `docker` / `disk` 任一群組。

### A.3 密碼鎖定，無法切換成 openclaw 後 escalate

```powershell
Test-AsOpenClaw -Label "A.3 shadow status" -Cmd 'sudo -n cat /etc/shadow | grep openclaw 2>&1 || cat /etc/passwd | grep openclaw'
```

由 root 端再驗一次：

```powershell
& wsl.exe -d $Distro -u root -- grep '^openclaw:' /etc/shadow
```

- **PASS**：第二行欄位（password hash）應為 `!` 或 `!!` 或 `*`，皆代表密碼鎖死。
- **FAIL**：出現任何看起來像 hash 的字串（`$y$...` / `$6$...`）。

### A.4 `/opt/openclaw` 與 `/opt/node` 唯讀（核心 mitigation：阻止 backdoor 自己）

```powershell
Test-AsOpenClaw -Label "A.4a try modify gateway entrypoint" -Cmd 'echo "pwn" >> /opt/openclaw/openclaw.mjs 2>&1'
```

- **PASS**：`Permission denied`，exit 非 0。
- **FAIL**：寫入成功（exit 0）。

```powershell
Test-AsOpenClaw -Label "A.4b try replace run-gateway.sh" -Cmd 'echo "#!/bin/bash" > /opt/openclaw/run-gateway.sh 2>&1'
```

- **PASS**：`Permission denied`。

```powershell
Test-AsOpenClaw -Label "A.4c try modify node binary" -Cmd 'echo "x" >> /opt/node/bin/node 2>&1'
```

- **PASS**：`Permission denied`。

```powershell
Test-AsOpenClaw -Label "A.4d try chmod self-write" -Cmd 'chmod u+w /opt/openclaw/openclaw.mjs 2>&1'
```

- **PASS**：`Operation not permitted`（owner 是 root，openclaw 不能 chmod）。

```powershell
Test-AsOpenClaw -Label "A.4e try create new file in /opt/openclaw" -Cmd 'touch /opt/openclaw/backdoor.js 2>&1'
```

- **PASS**：`Permission denied`。

### A.5 `/etc` 與其他系統目錄不可寫

```powershell
Test-AsOpenClaw -Label "A.5a /etc unwritable" -Cmd 'echo x > /etc/openclaw-pwn 2>&1'
Test-AsOpenClaw -Label "A.5b /usr unwritable" -Cmd 'echo x > /usr/local/bin/openclaw-pwn 2>&1'
Test-AsOpenClaw -Label "A.5c / unwritable" -Cmd 'echo x > /openclaw-pwn 2>&1'
Test-AsOpenClaw -Label "A.5d /var unwritable" -Cmd 'echo x > /var/openclaw-pwn 2>&1'
```

- **PASS**：四條都是 `Permission denied`，exit 非 0。

### A.6 無法 enable / start systemd 服務

```powershell
Test-AsOpenClaw -Label "A.6a try start gateway service" -Cmd 'systemctl start openclaw-gateway.service 2>&1'
Test-AsOpenClaw -Label "A.6b try enable arbitrary service" -Cmd 'systemctl enable openclaw-gateway.service 2>&1'
Test-AsOpenClaw -Label "A.6c try systemctl --user enable" -Cmd 'systemctl --user enable some-evil.service 2>&1'
```

- **A.6a / A.6b PASS**：`Failed to start ... Access denied` / `Authentication required`。
- **A.6c PASS**：`Failed to connect to user scope bus` 或 `Unit some-evil.service not found`（重點是它沒成功安裝）。

### A.7 cron 持久化（如果有 cron service）

```powershell
Test-AsOpenClaw -Label "A.7a check cron presence" -Cmd 'command -v crond cron systemd-cron 2>&1; systemctl is-active cron 2>&1; systemctl is-active crond 2>&1'
```

- **預期**：base rootfs 沒有啟用 cron service。如果輸出全部 `inactive` / `not-found`，
  攻擊者即使 `crontab -e` 寫進排程，也不會在 distro 啟動時被執行。
- **如果 cron 是 active**：那就是潛在的 persistence 路徑（不是現有設計阻擋的，
  屬於「已知未防」項目，見章末）。

### A.8 PATH hijack（不存在的二進位 fallback）

```powershell
Test-AsOpenClaw -Label "A.8 PATH does not start with writable dir" -Cmd 'echo "$PATH" | tr : "\n"'
```

- **PASS**：第一個項目應該是 `/opt/node/bin` 或 `/usr/local/sbin`、`/usr/local/bin`、
  `/usr/sbin`、`/usr/bin`、`/sbin`、`/bin`——通通是 root-only 寫入路徑。
- **FAIL**：`/home/openclaw/...` 出現在前面。

### A.9 SUID escalation 表面（已知很大；只做 spot check）

```powershell
Test-AsOpenClaw -Label "A.9 list SUID binaries" -Cmd 'find / -xdev -perm -4000 -type f 2>/dev/null | sort'
```

- **預期清單應該只包含**：`mount`, `umount`, `su`, `sudo`, `passwd`, `chsh`, `chfn`,
  `gpasswd`, `newgrp`, `pkexec`（pkexec 在無 polkit rule 下對 openclaw 沒用）。
- **可疑樣態**：任何 `/opt`、`/home/openclaw`、`/tmp` 下的 SUID 檔案——那是強烈
  入侵跡象。

### A.10 Gateway 只 listen 127.0.0.1（不論 mode）

先在 Windows 端把 gateway 點開（桌面 icon）。然後從 Windows 跑：

```powershell
& wsl.exe -d $Distro -u openclaw -- bash -c 'ss -ltn | grep 18789'
```

- **PASS**：只有一行，地址是 `127.0.0.1:18789` 或 `[::1]:18789`。
- **FAIL**：出現 `0.0.0.0:18789` 或 `[::]:18789` 或 `*:18789`。

### A.11 gateway 不在 LAN 上可達

從同一台 Windows host（LAN IP 不是 127.0.0.1）：

```powershell
$LanIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.InterfaceAlias -notmatch 'Loopback|vEthernet' -and $_.IPAddress -notmatch '^169\.254'} | Select-Object -First 1).IPAddress
Write-Host "Trying http://$LanIP:18789/ ..."
try { Invoke-WebRequest -Uri "http://$LanIP:18789/" -TimeoutSec 3 -UseBasicParsing | Out-Null; Write-Host "FAIL: reachable on LAN" -ForegroundColor Red } catch { Write-Host "PASS: $($_.Exception.Message)" -ForegroundColor Green }
```

- **PASS**：丟 connection refused / timeout。
- **FAIL**：HTTP 200 / 401 / 任何 HTTP 回應，都代表 LAN 可達。

> 註：如果 `.wslconfig` 是 `networkingMode=mirrored`，`localhost` 在 Windows 上也是
> 127.0.0.1 才看得到，這條會更乾淨；如果是 NAT 模式，預期相同。

### A.12 namespace / capabilities 表面

```powershell
Test-AsOpenClaw -Label "A.12a effective capabilities" -Cmd 'capsh --print 2>&1 | head -3'
Test-AsOpenClaw -Label "A.12b try unshare user ns" -Cmd 'unshare -U id 2>&1'
```

- **A.12a PASS**：`Current` 為空 / 只有非特權 cap；`Bounding` 不含 `cap_sys_admin`、
  `cap_dac_override`、`cap_dac_read_search`。
- **A.12b**：依 kernel config 可能成功也可能失敗；本身不是漏洞，只是觀察攻擊者
  能不能用 user namespace 規避部分權限檢查。**注意**：在我們的設計裡，
  `/opt/openclaw` 唯讀仍然會擋住 user-ns 內的寫入嘗試（因為檔案系統真實 owner
  仍是 root）。

---

## B. STRICT SANDBOX 專用測試（windowsbridge **未勾選**）

> 這一組是 `Q3=D`（`automount=false` + `interop=false`）的核心保證。
> **預期：全部都是「攻擊者試了但失敗」**。

### B.0 確認模式

```powershell
& wsl.exe -d $Distro -u root -- head -1 /etc/wsl.conf
```

- **必須**輸出 `# MODE: STRICT SANDBOX (...)`。如果輸出 `PERMISSIVE`，
  跳過 B 改跑 C。

### B.1 `/mnt/c` 不可達

```powershell
Test-AsOpenClaw -Label "B.1a /mnt/c does not exist" -Cmd 'ls /mnt/c 2>&1'
Test-AsOpenClaw -Label "B.1b /mnt is empty or does not exist" -Cmd 'ls /mnt 2>&1; echo "---"; ls -la /mnt 2>&1'
```

- **PASS**：`No such file or directory` 或 `/mnt` 為空目錄。
- **FAIL**：看到 `Users`、`Windows`、`Program Files` 等 Windows 子目錄。

### B.2 cmd.exe / powershell.exe / explorer.exe 不在 PATH

```powershell
Test-AsOpenClaw -Label "B.2a cmd.exe in PATH?" -Cmd 'command -v cmd.exe 2>&1; type cmd.exe 2>&1'
Test-AsOpenClaw -Label "B.2b powershell.exe in PATH?" -Cmd 'command -v powershell.exe 2>&1'
Test-AsOpenClaw -Label "B.2c explorer.exe in PATH?" -Cmd 'command -v explorer.exe 2>&1'
Test-AsOpenClaw -Label "B.2d schtasks.exe in PATH?" -Cmd 'command -v schtasks.exe 2>&1'
Test-AsOpenClaw -Label "B.2e clip.exe in PATH?" -Cmd 'command -v clip.exe 2>&1'
```

- **PASS（5 項都應）**：`command not found`，exit 非 0。

### B.3 直接 exec Windows binary（即使 interop 關閉，binfmt_misc 仍可能存在？驗一下）

```powershell
Test-AsOpenClaw -Label "B.3a direct exec via binfmt" -Cmd '/init -e cmd.exe 2>&1; echo exit=$?'
Test-AsOpenClaw -Label "B.3b /init list interop registrations" -Cmd 'cat /proc/sys/fs/binfmt_misc/WSLInterop 2>&1'
```

- **B.3a PASS**：`No such file or directory` 或 `/init` 拒絕（interop 已關）。
- **B.3b**：應該顯示 `disabled` 或檔案不存在。
- **FAIL**：輸出 `enabled` 且 `interpreter /init`。

### B.4 透過絕對路徑也找不到

```powershell
Test-AsOpenClaw -Label "B.4 absolute path to cmd.exe" -Cmd 'ls /mnt/c/Windows/System32/cmd.exe 2>&1; /mnt/c/Windows/System32/cmd.exe /c echo pwn 2>&1'
```

- **PASS**：`No such file or directory`。

### B.5 `wslpath` 仍存在，但該指什麼地方都失敗

```powershell
Test-AsOpenClaw -Label "B.5 wslpath translate Desktop" -Cmd 'wslpath -u "C:\\Users\\Public\\Desktop" 2>&1; ls "$(wslpath -u C:\\Users\\Public 2>/dev/null)" 2>&1'
```

- **PASS**：`wslpath` 也許輸出一個 `/mnt/c/Users/Public/Desktop` 字串，但
  後續 `ls` 結果是 `No such file or directory`（因為 `/mnt/c` 不存在）。
- **FAIL**：`ls` 看到任何 Windows 端使用者檔案。

### B.6 WSLENV / Windows env vars 沒洩漏

```powershell
Test-AsOpenClaw -Label "B.6 env scan for windows leaks" -Cmd 'env | grep -iE "userprofile|appdata|programfiles|systemroot|path=.*windows" 2>&1'
```

- **PASS**：完全無 match（exit 1）。
- **FAIL**：列出 `USERPROFILE=/mnt/c/Users/...` 或 `APPDATA=...`。

### B.7 `/etc/wsl.conf` 內容驗證

```powershell
& wsl.exe -d $Distro -u root -- grep -E '^(enabled|appendWindowsPath)=' /etc/wsl.conf
```

- **PASS**：所有三行都是 `=false`。
- **FAIL**：任何一行 `=true`。

---

## C. PERMISSIVE 專用測試（windowsbridge **勾選**）

> **重要**：這一組的「預期」是「攻擊者**做得到**」，**這是設計**——
> 使用者勾了 checkbox 就是同意這些行為。本組的目的：
> 1. **確認 checkbox 真的有效**（沒生效是另一種 bug）。
> 2. **量化使用者實際失去的隔離**，讓使用者知道勾下去等於放出哪些東西。

### C.0 確認模式

```powershell
& wsl.exe -d $Distro -u root -- head -1 /etc/wsl.conf
```

- **必須**輸出 `# MODE: PERMISSIVE (...)`。如果輸出 `STRICT SANDBOX`，跳到 B。

### C.1 `/mnt/c` 可讀（介面有效）

```powershell
Test-AsOpenClaw -Label "C.1a /mnt/c readable" -Cmd 'ls -la /mnt/c | head -10 2>&1'
```

- **PASS**：列出 Windows 根目錄（`Users`、`Windows`、`Program Files`...）。

### C.2 Windows binary 可執行（介面有效）

```powershell
Test-AsOpenClaw -Label "C.2a cmd.exe runs" -Cmd 'cmd.exe /c "echo PWN_FROM_GATEWAY" 2>&1'
Test-AsOpenClaw -Label "C.2b powershell.exe runs" -Cmd 'powershell.exe -NoProfile -Command "Write-Host CLAW_OK" 2>&1'
Test-AsOpenClaw -Label "C.2c schtasks.exe runs" -Cmd 'schtasks.exe /query /fo LIST 2>&1 | head -5'
```

- **PASS**：cmd.exe / powershell.exe / schtasks.exe 都正常執行並回傳輸出。

### C.3 確認攻擊者**能讀**敏感 Windows 檔案（量化的失去）

> 這一組 **PASS = 讀到敏感檔案**——意思是「設計如預期，使用者勾了確實開出這些路徑」。
> 不是 bug，是 informed consent 的證據。

```powershell
Test-AsOpenClaw -Label "C.3a list user Desktop" -Cmd 'ls "/mnt/c/Users/$USER/Desktop" 2>&1 | head; echo ---; ls /mnt/c/Users 2>&1 | head'
Test-AsOpenClaw -Label "C.3b read first byte of any browser cookie db" -Cmd '
for db in /mnt/c/Users/*/AppData/Local/Google/Chrome/User\ Data/Default/Cookies \
          /mnt/c/Users/*/AppData/Local/Microsoft/Edge/User\ Data/Default/Cookies; do
    [ -r "$db" ] && { echo "READABLE: $db"; head -c 16 "$db" | xxd; }
done 2>&1
'
Test-AsOpenClaw -Label "C.3c read .ssh keys" -Cmd 'ls /mnt/c/Users/*/.ssh 2>&1; cat /mnt/c/Users/*/.ssh/id_rsa 2>&1 | head -2'
```

- **C.3a PASS（informational）**：列出 `Users` 各帳號目錄、Desktop 內容。
- **C.3b PASS（informational）**：印出 `READABLE: ...Cookies` 加 16 byte SQLite 標頭。
- **C.3c PASS（informational）**：可看到 `.ssh` 目錄與 RSA key 前兩行（如有）。

> 把 C.3 的輸出存檔給使用者看：「你勾了 windowsbridge，gateway 能拿到的就是這些。」

### C.4 確認攻擊者**能寫**Windows 檔案（量化的失去）

```powershell
Test-AsOpenClaw -Label "C.4 create canary file on Windows Desktop" -Cmd '
# Create a file on the user's Windows Desktop. If this works, the gateway
# can also wipe / replace anything else under that Desktop.
mkdir -p /tmp/canary
echo "canary written from openclaw at $(date -Is)" > /tmp/canary/x
cp /tmp/canary/x "/mnt/c/Users/$USER/Desktop/openclaw-canary.txt" 2>&1
ls -l "/mnt/c/Users/$USER/Desktop/openclaw-canary.txt" 2>&1
'
```

- **PASS（informational）**：Windows Desktop 多一個 `openclaw-canary.txt`。
  測完手動把它刪掉。

### C.5 確認攻擊者**能排程任務 / 改 Windows 設定**（量化的失去）

```powershell
Test-AsOpenClaw -Label "C.5 try schedule a task at 23:59" -Cmd '
schtasks.exe /create /tn "OpenClawCanary" /tr "cmd.exe /c echo pwn > %TEMP%\\openclaw-canary.txt" /sc once /st 23:59 /f 2>&1
schtasks.exe /query /tn "OpenClawCanary" 2>&1
schtasks.exe /delete /tn "OpenClawCanary" /f 2>&1
'
```

- **PASS（informational）**：建立任務成功，能查詢，能刪除——這正是「設個鬧鐘」
  使用案例的反面：能設鬧鐘 ≡ 能植入任意排程任務。

### C.6 但 **PERMISSIVE 並沒有放掉的東西**（再驗一次）

PERMISSIVE 只翻了 wsl.conf 三行。不應影響 A 組。在 PERMISSIVE 下，
**重跑 A.1 ~ A.12，每一條的預期結果都應該與 STRICT 完全一致**。
這是 PERMISSIVE 模式的最後一道防線。

---

## D. 網路隔離（兩種模式都應一致）

### D.1 完整 listener 列表

```powershell
& wsl.exe -d $Distro -u root -- ss -ltnp 2>&1
```

- **PASS**：除了 `127.0.0.1:18789` 之外，沒有 0.0.0.0 / 全綁定的 TCP listener。
  systemd-resolved（如有）可能在 `127.0.0.53:53`，那是 lo only，可接受。

### D.2 從 WSL 端 ping 出去（mode-independent，確認沒有不必要的內網外連）

```powershell
Test-AsOpenClaw -Label "D.2 outbound to public" -Cmd 'curl -sI https://example.com -o /dev/null -w "%{http_code}\n" 2>&1'
```

- **PASS（informational）**：`200`。OpenClaw 需要 outbound 連雲端 LLM provider，
  這條是預期可達。如果你的環境想阻擋 outbound，那是另一層（防火牆 / proxy），
  超出本沙箱職責。

### D.3 LAN 不可達 gateway（重複 A.11，這裡顯式列出）

見 A.11。

### D.4 WSL 內部其他帳號（root）也被綁在 loopback 上

```powershell
& wsl.exe -d $Distro -u root -- bash -c 'curl -sI http://127.0.0.1:18789/ -o /dev/null -w "loopback=%{http_code}\n"; curl -sI http://$(hostname -I | awk "{print \$1}"):18789/ -o /dev/null -m 3 -w "wslip=%{http_code}\n" 2>&1'
```

- **PASS**：`loopback=200`（或 4xx，重點是有回應），`wslip=000`（連不到 / timeout）。
- **FAIL**：`wslip` 也是 200，代表 gateway 也綁了 distro 的 eth0 IP。

---

## E. 可寫範圍（兩模式相同；確認允許的範圍）

### E.1 `/home/openclaw/workspace` 可寫（**預期**：PASS）

```powershell
Test-AsOpenClaw -Label "E.1 workspace writable" -Cmd 'echo ok > /home/openclaw/workspace/test && rm /home/openclaw/workspace/test && echo PASS'
```

- **PASS**：印出 `PASS`，exit 0。

### E.2 `/home/openclaw/.openclaw` 可寫（**預期**：PASS）

```powershell
Test-AsOpenClaw -Label "E.2 .openclaw writable" -Cmd 'echo ok > /home/openclaw/.openclaw/test && rm /home/openclaw/.openclaw/test && echo PASS'
```

### E.3 `/tmp` 可寫（**預期**：PASS）

```powershell
Test-AsOpenClaw -Label "E.3 /tmp writable" -Cmd 'echo ok > /tmp/test && rm /tmp/test && echo PASS'
```

### E.4 `~/.bashrc`、`~/.profile` 可寫（**預期**：PASS — 這是「已知未防」項目）

```powershell
Test-AsOpenClaw -Label "E.4 home dotfiles writable" -Cmd 'touch /home/openclaw/.bashrc.test && rm /home/openclaw/.bashrc.test && echo PASS'
```

> 攻擊者可以改自己 home 內的任何東西。這是 Linux user-account 模型的本質、
> 不是我們的防線，已記入「已知未防」。

---

## F. 持久化嘗試（兩模式相同）

> 攻擊者目標：在 distro 重啟（或 Windows 重開）後仍能恢復控制。

### F.1 無法植入 `run-gateway.sh`

```powershell
Test-AsOpenClaw -Label "F.1 try replace launcher" -Cmd '
cat <<EOF > /tmp/evil
#!/bin/bash
echo PWNED >&2
exec /opt/node/bin/node /opt/openclaw/openclaw.mjs gateway run --bind loopback --port 18789 --force
EOF
cp /tmp/evil /opt/openclaw/run-gateway.sh 2>&1
echo exit=$?
'
```

- **PASS**：`Permission denied`。

### F.2 無法寫入 systemd unit 檔

```powershell
Test-AsOpenClaw -Label "F.2 try write unit" -Cmd 'echo "[Service]" > /etc/systemd/system/evil.service 2>&1'
```

- **PASS**：`Permission denied`。

### F.3 user-level systemd（loginctl linger）

```powershell
Test-AsOpenClaw -Label "F.3 try enable lingering" -Cmd 'loginctl enable-linger openclaw 2>&1'
```

- **PASS**：`Could not enable linger: ... Access denied` / `Authentication required`。
  → 即使攻擊者寫了 `~/.config/systemd/user/evil.service`，沒 linger 也不會在沒人
  登入時跑。

### F.4 修改 launcher 的入口（Windows 端）

> 注意：這條測試的是 Windows side 防線，不是 WSL。

```powershell
Test-AsOpenClaw -Label "F.4 STRICT mode: try mutate Windows-side launcher" -Cmd 'ls "/mnt/c/Program Files/aiDAPTIVClaw/" 2>&1'
```

- **STRICT 模式 PASS**：`No such file or directory`（看不到 `/mnt/c`）。
- **PERMISSIVE 模式**：看得到、但 `/mnt/c/Program Files` 是 Windows ACL，
  openclaw 寫入會被 Windows 端拒絕（因為 wsl 是普通 user token，沒 admin）。
  追加驗證：

```powershell
Test-AsOpenClaw -Label "F.4b PERMISSIVE: write to Program Files" -Cmd 'echo evil > "/mnt/c/Program Files/aiDAPTIVClaw/openclaw-launcher.cmd" 2>&1'
```

- **PASS（兩模式都應）**：STRICT 是 No such file，PERMISSIVE 是 Permission denied
  （Windows ACL 拒絕）。
- **FAIL**：寫入成功——表示使用者是用 admin token 跑 gateway，整個威脅模型
  失效。

---

## G. 安裝旗標 / 升級健全性

### G.1 重裝時 `windowsbridge` 不會偷偷沿用上次選擇

依設計 `Flags: unchecked`、**沒有** `checkedonce`。手動驗：

1. 第一次安裝勾選 PERMISSIVE。
2. 不解除安裝、直接重跑 installer（升級流程）。
3. **看 wizard 的 windowsbridge 是不是「未勾」**。

- **PASS**：未勾。使用者必須再次決定。
- **FAIL**：自動勾起。

### G.2 `install-options.ini` 與 `/etc/wsl.conf` 一致

```powershell
$ini = Join-Path ${env:ProgramFiles} 'aiDAPTIVClaw\install-options.ini'
Get-Content $ini | Select-String '^permissive='

& wsl.exe -d $Distro -u root -- head -1 /etc/wsl.conf
```

- **PASS**：`permissive=1` ↔ `# MODE: PERMISSIVE`；`permissive=0` ↔ `# MODE: STRICT SANDBOX`。
- **FAIL**：兩邊不一致——這代表 `install-options.ini` 寫入後 wsl.conf 沒被 sed-flip，
  屬於 installer bug。

### G.3 `install-options.ini` 不再含 `apiKey`（既有測試，順便驗）

```powershell
Get-Content $ini | Select-String '^apiKey'
```

- **PASS**：無輸出（Phase 2 會 strip `[provider]` section）。

### G.4 install-complete marker 存在

```powershell
Test-Path (Join-Path ${env:ProgramFiles} 'aiDAPTIVClaw\.install-complete')
```

- **PASS**：`True`。
- **FAIL**：`False`——launcher 會拒絕啟動。

---

## H. 已知**未防**項目（誠實清單）

下列攻擊路徑**不在**本沙箱的職責範圍。請使用者自己評估風險、或等 broker 階段。

| # | 攻擊 | 適用模式 | 為什麼不防 |
|---|------|----------|------------|
| H.1 | OpenClaw 讀 `/home/openclaw/workspace` 內檔案 | 兩種 | 那是 gateway 的工作目錄，本就要可讀寫 |
| H.2 | OpenClaw 改自己 `~/.bashrc` 加 alias / 啟動鉤子 | 兩種 | Linux user-account 本質；下次 wsl session 才生效，使用者通常會看到 |
| H.3 | OpenClaw 讀 Windows 上的任意使用者檔案 | **PERMISSIVE** | 設計如此，使用者已 informed consent |
| H.4 | OpenClaw 跑 cmd.exe / powershell.exe / schtasks.exe 任意指令 | **PERMISSIVE** | 同上 |
| H.5 | OpenClaw 讀其他 Windows 帳號的檔案 | 兩種 | Windows ACL 阻擋；不是我們的防線，是 Windows 的 |
| H.6 | OpenClaw 寫 `Program Files\aiDAPTIVClaw\*` 來綁住 launcher | 兩種 | Windows ACL 阻擋（installer 自帶 admin，但 runtime 是普通 user token） |
| H.7 | OpenClaw 在 distro 內 DoS 自己 | 兩種 | 影響只限 distro，使用者 `wsl --terminate` 即可恢復 |
| H.8 | OpenClaw 透過 outbound HTTPS exfil 資料 | 兩種 | 沙箱不做 outbound 過濾；要靠企業防火牆 / proxy |
| H.9 | OpenClaw 透過 cloud LLM provider 把 prompt content 傳出去 | 兩種 | 這是 OpenClaw 的核心功能，不是 sandbox 議題 |

---

## I. 一鍵驗收摘要

跑完整套後填寫：

```text
Mode tested:  [ ] STRICT SANDBOX     [ ] PERMISSIVE
Date / build: ____________________

A.1 sudo blocked .................. [P/F]
A.2 group isolation ............... [P/F]
A.3 password locked ............... [P/F]
A.4 /opt readonly (5 sub) ......... [P/F]
A.5 /etc unwritable (4 sub) ....... [P/F]
A.6 systemd locked (3 sub) ........ [P/F]
A.7 cron inactive ................. [P/F]
A.8 PATH safe ..................... [P/F]
A.9 SUID list expected ............ [P/F]
A.10 gateway loopback only ........ [P/F]
A.11 LAN unreachable .............. [P/F]
A.12 caps minimal ................. [P/F]

If STRICT:
B.1 /mnt/c absent ................. [P/F]
B.2 windows binaries absent ....... [P/F]
B.3 binfmt disabled ............... [P/F]
B.4 absolute path fails ........... [P/F]
B.5 wslpath does not help ......... [P/F]
B.6 no env leak ................... [P/F]
B.7 wsl.conf =false ............... [P/F]

If PERMISSIVE:
C.1 /mnt/c readable ............... [P/F]  (P = expected)
C.2 .exe runs ..................... [P/F]  (P = expected)
C.3 sensitive read demonstrated ... [acknowledged]
C.4 desktop write demonstrated .... [acknowledged]
C.5 schtasks demonstrated ......... [acknowledged]
C.6 group A re-verified ........... [P/F]

D.1 listeners only loopback ....... [P/F]
D.2 outbound works ................ [P/F]
D.3 wslip unreachable ............. [P/F]

E.1-E.4 expected writes succeed ... [P/F]

F.1-F.3 persistence blocked ....... [P/F]
F.4 program files protected ....... [P/F]

G.1 reinstall reprompts ........... [P/F]
G.2 ini ↔ wsl.conf consistent ..... [P/F]
G.3 apiKey stripped ............... [P/F]
G.4 marker present ................ [P/F]
```

任何一條 `F` 都應視為 sandbox regression、停止對外 release，並追到 root cause。
