**English** · [简体中文](README.zh-CN.md)

# ouc-autologin

> Campus network auto-login and self-healing for Ocean University of China (OUC) · Windows / PowerShell 5.1 · no resident process

A PowerShell script driven by Windows Task Scheduler. It probes the network on a schedule, re-authenticates when the connection drops, falls back to Wi-Fi when Ethernet is unusable, and re-associates the Wi-Fi adapter when the association is dead but Windows still keeps the old IP address and default route.

> **Before you use it** — intended only for automatically reconnecting **your own** device with **your own** account. Follow your campus network policy: do not use it for account sharing, multi-device sharing, or anything that circumvents billing.

---

## Features

- **Zero dependencies** — Windows PowerShell 5.1 only. No Python, no Node, no third-party modules.
- **No resident process** — the scheduled task launches it every N minutes and it exits within seconds. It is started through wscript + launcher.vbs so no console window ever flashes.
- **Unattended** — the scheduled task uses an S4U logon type: no Windows password is stored and you do not need to be logged in. It runs right after boot, while the machine sits at the lock screen.
- **Probes the network instead of trusting the NIC** — it requests baidu.com and Apple's success.html by default and classifies the result as online / portal / linkdown / unknown from the real HTTP responses.
- **Ethernet first, Wi-Fi fallback** — when Ethernet has no usable default route it connects to the campus SSID (OUC-AUTO by default); when Ethernet comes back, Windows interface metrics switch back automatically. If repeated reconnects on that SSID still fail, it rotates to the fallback SSID from `WifiSsidFallback`.
- **Self-healing** — if the Wi-Fi association is dead but Windows still reports "connected" with a stale IP and default route, the script only forces a disconnect + reconnect after the probe has failed continuously for N seconds, with an increasing cooldown so brief flaps are not punished.
- **Fast retry window** — once the link is considered broken it does not wait for the next scheduler tick: it re-probes every 10 seconds for up to 4 minutes and completes the authentication on the spot as soon as the portal answers again.
- **Backoff without friendly fire** — repeated authentication failures back off exponentially (cap configurable), while a portal that answers nothing at all (HTTP 0, link unreachable) does not count as a failure, so the anti-lockout counter is not wasted on outages.
- **Single instance** — a named mutex guarantees two logins never run at the same time.

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in; the script starts with `#requires -Version 5.1`)
- Administrator rights to install the scheduled task

## Quick start

1. Put the whole folder in a **fixed location**, for example `D:\ouc-autologin` — the scheduled task remembers this path, so do not move it afterwards.
2. Copy the configuration template (the script requires `config.ini` to exist; `setup` will not create it):

   ```powershell
   Copy-Item .\config.ini.example .\config.ini
   ```

3. Open PowerShell **as administrator**, change into that folder and run:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\ouc-autologin.ps1 setup
   ```

4. Enter your student ID and password when prompted. The script writes them into `config.ini`, tightens that file with `icacls` so only your Windows account can read it, and installs the scheduled task `OUC-AutoLogin`.
5. Verify:

   ```powershell
   .\ouc-autologin.ps1 test-login    # force one authentication to validate credentials and portal address
   .\ouc-autologin.ps1 status        # show config, task state, current network verdict and recent log lines
   ```

## Commands

| Command | What it does |
| --- | --- |
| `setup` | Ask for credentials and install the scheduled task, in one go |
| `check` / `once` | Probe once and authenticate if the connection is down (this is what the task runs) |
| `test-login` | Force one authentication to validate credentials and portal address |
| `relogin` | Log out first, then log in again — verifies the password end to end (drops the connection for 5–10 seconds) |
| `status` | Show config, scheduled task state, current network verdict and recent log lines |
| `wifi` / `wifi-status` | Read-only: Ethernet/Wi-Fi links, Wi-Fi profile, current egress |
| `wifi-connect` | Try to connect to Wi-Fi right now (useful to test the Ethernet-down fallback) |
| `logs` | Show the log; accepts `-Tail 50` |
| `install` | Install or update only the scheduled task; accepts `-IntervalMinutes 5` |
| `uninstall` | Remove the scheduled task (script, config and logs are kept) |

## Configuration

`config.ini` sits next to the script, is UTF-8 (with or without BOM), uses `key = value` lines, and treats `#` or `;` as a comment. **Edit and save — no need to restart the task**, because the file is re-read on every run.

For a fresh copy, start from `config.ini.example`. Missing keys fall back to the built-in defaults.

### Account and portal

| Key | Example value | Meaning |
| --- | --- | --- |
| `Username` | *(empty)* | Student / staff ID |
| `Password` | *(empty)* | Campus network password, stored in plain text (see "Security notes") |
| `PortalBase` | `auto` | `auto` derives the portal from the gateway redirect; or hard-code one portal |
| `PortalCandidates` | `http://192.168.101.201:801,https://10.100.29.2:802` | Candidate portals tried in order (West Coast first, Laoshan second) |
| `IpProbeUrl` | `https://wxrz.ouc.edu.cn/` | Asks the portal "which IP do you see for me?"; the reported address takes precedence over the local one |
| `CheckUrls` | `http://baidu.com,https://www.apple.com/library/test/success.html` | Connectivity probes; the first one is usually redirected to the captive portal while offline |
| `PortalPattern` | `eportal\|dr\.com\|10\.100\.29\.2\|...` | Regex that marks a response as "this is the campus portal" |
| `LogoutUrls` | `/eportal/portal/logout,...` | Logout endpoints tried by `relogin`, one by one, re-checking after each |
| `TimeoutSeconds` | `10` | Timeout for a single HTTP request (seconds) |
| `IntervalMinutes` | `1` | Probe interval of the scheduled task (minutes); used by `install` / `setup` |
| `NotifyOnFailure` | `1` | Show a tray balloon after repeated authentication failures (1 = yes, 0 = log only) |

### Wi-Fi fallback

| Key | Example value | Meaning |
| --- | --- | --- |
| `WifiFallback` | `1` | Master switch: connect to Wi-Fi automatically when Ethernet is unusable |
| `WifiSsid` | `OUC-AUTO` | Campus Wi-Fi SSID |
| `WifiProfile` | `OUC-AUTO` | Name of that SSID's profile in Windows (usually the same as the SSID) |
| `WifiSsidFallback` | `OUC-WIFI` | Fallback SSID(s), comma-separated. After `WifiSsidSwitchAfter` consecutive reconnects inside one outage still do not bring the link back, the script moves to the next SSID |
| `WifiSsidSwitchAfter` | `2` | Consecutive failed reconnects before rotating to the next SSID |
| `WifiConnectTimeoutSeconds` | `25` | How long to wait after a connect request before giving up |
| `WifiCooldownSeconds` | `300` | Cooldown after a failed connect (seconds), so no run waits forever |

**"Ethernet is unusable"** means the Ethernet adapter has **no default route** — either no cable, or a cable with no DHCP lease (only a `169.254.x.x` APIPA address). While Ethernet is healthy the script never touches Wi-Fi.

SSID rotation is scoped to one outage: as soon as a probe returns `online` or `portal`, the next outage starts from the primary `WifiSsid` again.

### Self-healing and retry pacing

| Key | Example value | Meaning |
| --- | --- | --- |
| `WifiOfflineGraceSeconds` | `30` | While Wi-Fi "looks usable" but the probe fails, wait this many seconds of continuous failure before one disconnect + reconnect (flap protection) |
| `WifiReassocCooldownSeconds` | `60` | Inside one outage, the nth reconnect cools down for this value × n seconds |
| `WifiReassocCooldownMaxSeconds` | `300` | Upper bound of that cooldown (seconds) |
| `BackoffMaxSeconds` | `120` | Upper bound of the authentication-failure backoff (seconds) |
| `WifiWatchSeconds` | `240` | How long the fast retry window may watch (0 = disabled, fall back to "wait for the next tick") |
| `WifiWatchIntervalSeconds` | `10` | Re-probe interval inside the fast retry window (seconds) |

## How it works

1. **Probe** `Get-NetworkState` — check whether a default route exists; if it does, request every URL in `CheckUrls` and classify:
   - `online` internet reachable | `portal` redirected to the login page | `linkdown` no default route | `unknown` route exists but nothing answers
2. **Decide** `Invoke-Check` — `online` clears the failure counter and returns; `portal` goes straight to authentication without touching the adapters; `unknown` / `linkdown` enter link recovery.
3. **Recover the link** `Invoke-LinkRecovery` —
   - Wi-Fi itself is unusable → connect to Wi-Fi immediately (the original Ethernet-down fallback, with `WifiCooldownSeconds` cooldown);
   - Wi-Fi "looks usable" but the probe fails (dead association) → remember when the outage started, and only after `WifiOfflineGraceSeconds` seconds of continuous failure run `netsh wlan disconnect` + reconnect, with the cooldown growing ×n up to the cap.
4. **Fast retry window** `Invoke-OfflineWatch` — after the link is confirmed broken, do not wait for the next tick: re-probe every `WifiWatchIntervalSeconds` seconds for up to `WifiWatchSeconds` seconds. `online` ends the run; `portal` completes the authentication right there.
5. **Authenticate** `Invoke-PortalLogin` — build `/eportal/portal/login?callback=...&wlan_user_ip=<local IP>` from `PortalBase` / `PortalCandidates`. Success is detected by markers such as "认证成功 / 已经在线 / result:1" in the response. **All candidates are tried in order within one round**, so the log may show two "authentication failed" lines.
6. **Backoff** `Test-Backoff` — `wait = min(120 × 2^(failures-1), BackoffMaxSeconds)`.

```text
check starts
 └─ probe Get-NetworkState
      ├─ online ──────────────→ clear failure counter, exit
      ├─ portal ──────────────→ portal login → re-check → exit
      └─ unknown / linkdown
           └─ Invoke-LinkRecovery
                ├─ Wi-Fi unusable ──→ connect OUC-AUTO (rotates OUC-AUTO ⇄ OUC-WIFI)
                └─ Wi-Fi "looks usable" → grace period → disconnect + reconnect (cooldown ×n)
                     └─ Invoke-OfflineWatch: re-probe every 10s, up to 240s
                          ├─ online → exit
                          └─ portal → finish authentication here
```

## Scheduled task

- Task name `OUC-AutoLogin`, action `wscript.exe "<folder>\launcher.vbs" check`, working directory = the script folder.
- Triggers: at startup (runs even at the lock screen) + at logon + a repeating interval (1 minute by default, set by `IntervalMinutes`).
- S4U logon type with lowest privileges; `MultipleInstances=IgnoreNew`; execution time limit 10 minutes (the fast retry window caps at 4 minutes, so it is never killed).
- `wscript` is used instead of running `powershell.exe` directly because it is a GUI-subsystem host that allocates no console: no black window ever flashes. Even with `-WindowStyle Hidden`, Windows Terminal may still spawn a window for powershell.exe.
- Uninstall with `.\ouc-autologin.ps1 uninstall` or `Unregister-ScheduledTask -TaskName OUC-AutoLogin -Confirm:$false`.

## Logs and state files

| Path | Content |
| --- | --- |
| `%LOCALAPPDATA%\OUC-AutoLogin\logs\log-YYYY-MM-DD.txt` | One log per day; entries older than 14 days are deleted automatically |
| `%LOCALAPPDATA%\OUC-AutoLogin\state.json` | Consecutive failures `Fails` / `LastFail` / `Reason` |
| `...\offline-since.stamp` | When the current outage started (removed once the link is back) |
| `...\wifi-reassoc.json` | Forced reconnects of the current outage |
| `launcher-error.log` | Created in the script folder only if the launcher itself fails |

If `%LOCALAPPDATA%` is unavailable (some non-interactive sessions) the script falls back to the user profile and then to `logs\` next to the script.

## FAQ

**My campus uses different portal addresses. Will it work?** Change `PortalBase` / `PortalCandidates`. The defaults are West Coast `http://192.168.101.201:801` and Laoshan `https://10.100.29.2:802`; `auto` first derives the portal from the gateway redirect. Other campuses are untested — please test and send a PR.

**Why must the script file be UTF-8 *with* BOM?** Windows PowerShell 5.1 parses a BOM-less script using the system ANSI code page (GBK on Simplified Chinese systems), which turns every Chinese string into garbage and aborts with "unexpected token". The repository pins line endings in `.gitattributes`; when you edit the script, keep it UTF-8 **with BOM**.

**Why do I sometimes see two "authentication failed" lines in one round?** See step 5 above: every portal candidate is tried in order.

**Will this look like abnormal traffic to the campus network?** In steady state it is one HTTP probe per minute; only during an outage does it retry quickly. That is comparable to refreshing a web page by hand.

## Known limitations

- **Private IP submission** — behind a router doing NAT the script may pick an address such as `192.168.1.x` that the portal cannot map to the real client, which then answers `AC认证失败`. The script already prefers the address reported by `IpProbeUrl`, but not every network returns one.
- **Limited validation** — only tested against the Laoshan and West Coast portals on the `OUC-AUTO` SSID. The `OUC-WIFI` fallback path is exercised by manual disconnect tests only.
- **Plain-text password** — `config.ini` stores it in plain text (`setup` tries to tighten it with `icacls`). Windows Credential Manager / DPAPI is a possible follow-up.
- **Startup trigger** relies on the NIC obtaining DHCP while the machine is at the lock screen. Verified here, but behaviour may differ across machines and drivers.

## Security notes

- `config.ini` contains a plain-text account and password. **Never commit it, upload it, or send it to anyone** — it is listed in `.gitignore`.
- No file copied out of this repository should ever contain real credentials.

## Repository layout

```text
.
├── ouc-autologin.ps1      # main script
├── launcher.vbs           # console-less launcher used by the scheduled task
├── config.ini.example     # configuration template (copy to config.ini and fill in)
├── .gitignore
├── .gitattributes
├── .editorconfig
├── LICENSE
├── README.md              # this file (English, shown by default on GitHub)
└── README.zh-CN.md        # Simplified Chinese version
```

## Related projects

Other OUC campus network logins worth comparing with: Phuker/OUC-WiFi (Python, unmaintained), jiange6666/OUC_Campus_Network (multi-WAN aggregation), Cuiyingzhe/OUCNetworkAutoConnection, ladeng07/OUC-autoLogin (iOS Shortcuts). For the generic eportal style: Congser/campus-auto-login, likeisall/drcom-autologin.

## License

MIT — see `LICENSE`.
