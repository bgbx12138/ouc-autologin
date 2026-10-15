**简体中文** · [English](README.md)

# ouc-autologin

> 中国海洋大学校园网自动认证与断线自愈脚本 · Windows / PowerShell 5.1 · 无常驻进程

一个跑在 Windows 计划任务里的校园网自动登录脚本：定时探测网络，掉线就重新认证；有线不通时自动切无线；无线"假死"（关联已断、系统却还留着旧 IP 与默认路由）时自动断开重连。

> **使用须知**：仅供个人设备在**自己的账号**上做自动重连。请遵守中国海洋大学校园网使用规定，不要用于账号共享、多设备共用或任何绕过计费用的用途。

---

## 特性

- **零依赖**：只用 Windows 自带的 PowerShell 5.1，不需要 Python / Node / 任何第三方库。
- **无常驻进程**：由计划任务每 N 分钟拉起一次，单次几秒即退；用 wscript + launcher.vbs 启动，不闪控制台窗口。
- **无人值守**：计划任务用 S4U 登录类型，不保存 Windows 密码，也不用先登录桌面 —— 开机停在登录界面就会跑第一次。
- **以探网为准，而不是"网卡是否 Up"**：默认请求 baidu.com 与 Apple 的 success.html，按真实 HTTP 结果判定 online / portal / linkdown / unknown。
- **有线优先、有线不通自动切无线**：有线没有可用默认路由时自动连校园网 SSID（默认 OUC-AUTO），有线恢复后由 Windows 的接口度量自动切回。
- **断线自愈**：无线关联已死但系统仍保留旧 IP 与默认路由时，连续不通满 N 秒才强制 断开+重连，并带递增冷却，避免网络抖动时反复折腾网卡。
- **快速重试窗口**：链路不通时不等下一个计划任务 tick，脚本内每 10 秒复探一次、最多蹲守 4 分钟；宽限期一到立刻重连，恢复后当场把认证走完。
- **失败退避且不误伤**：连续认证失败按指数退避（上限可配）；门户完全无响应（HTTP 0，链路不可达）不计入失败次数，免得把防锁定计数浪费在断网上。
- **单实例**：命名互斥量保证不会有两个实例同时登录。

## 环境要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带；脚本首行有 `#requires -Version 5.1`）
- 安装计划任务需要管理员权限

## 快速开始

1. 把整个目录放到一个**固定位置**，例如 `D:\ouc-autologin`（计划任务会记住这个路径，之后别随便移动）。
2. 先复制一份配置模板（脚本要求 `config.ini` 必须存在，`setup` 本身不会创建它）：

   ```powershell
   Copy-Item .\config.ini.example .\config.ini
   ```

3. 用**管理员**身份打开 PowerShell，切到该目录：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\ouc-autologin.ps1 setup
   ```

4. 按提示输入学号与密码。脚本会把它们写进 `config.ini`、用 `icacls` 把该文件收紧为仅当前 Windows 账号可读，并安装计划任务 `OUC-AutoLogin`。
5. 验证：

   ```powershell
   .\ouc-autologin.ps1 test-login    # 强制走一次认证，验证账号密码与门户地址
   .\ouc-autologin.ps1 status        # 看配置、任务状态、当前网络判定与最近日志
   ```

## 命令一览

| 命令 | 作用 |
| --- | --- |
| `setup` | 填账号密码 + 安装计划任务，一步到位 |
| `check` / `once` | 检测一次，掉线就认证（计划任务用的就是这个） |
| `test-login` | 强制走一次认证，验证账号密码与门户地址 |
| `relogin` | 先注销再重登，把密码验到底（会断网 5～10 秒） |
| `status` | 看配置、计划任务状态、当前网络判定与最近日志 |
| `wifi` / `wifi-status` | 只读：有线/无线链路、无线配置、当前出口 |
| `wifi-connect` | 立刻尝试连接无线，用来验证"有线不通切无线"这条路 |
| `logs` | 看日志，可加 `-Tail 50` |
| `install` | 只装/改计划任务，可加 `-IntervalMinutes 5` |
| `uninstall` | 删除计划任务（脚本、配置、日志保留） |

## 配置

`config.ini` 与脚本同目录，UTF-8（带不带 BOM 都行），格式 `键 = 值`，`#` 或 `;` 开头是注释。**改完直接保存，不用重启任务**——每次运行都会重新读盘。

首次使用**必须**先 `Copy-Item config.ini.example config.ini`——`setup` 只在既有 config.ini 上改键，文件不存在时会直接报「配置文件 … 不存在」。账号密码可以手填，也可以交给 `setup` 交互输入。缺失的键会回落到脚本内置默认值。

### 账号与门户

| 键 | 示例值 | 说明 |
| --- | --- | --- |
| `Username` | *(留空)* | 学号 / 工号 |
| `Password` | *(留空)* | 校园网密码，明文存放（见"安全提示"） |
| `PortalBase` | `auto` | `auto` = 掉线时按网关重定向自动判定；也可写死某个门户 |
| `PortalCandidates` | `http://192.168.101.201:801,https://10.100.29.2:802` | 候选门户，按顺序试（西海岸在前、崂山在后） |
| `IpProbeUrl` | `https://wxrz.ouc.edu.cn/` | 用来问"认证系统看到你的哪个 IP"，页面上报的地址优先于本机地址 |
| `CheckUrls` | `http://baidu.com,https://www.apple.com/library/test/success.html` | 联网探测地址，掉线时第一个通常会被重定向到认证页 |
| `PortalPattern` | `eportal\|dr\.com\|10\.100\.29\.2\|...` | 判定"这是校园网认证页"的特征（正则） |
| `LogoutUrls` | `/eportal/portal/logout,...` | `relogin` 要试的注销接口，逐个试、每试一个就复查是否真掉线 |
| `TimeoutSeconds` | `10` | 单个 HTTP 请求超时（秒） |
| `IntervalMinutes` | `1` | 计划任务检测间隔（分钟），`install` / `setup` 时生效 |
| `NotifyOnFailure` | `1` | 连续认证失败是否弹右下角气泡（1 弹 / 0 只写日志） |

### 有线不通时自动切无线

| 键 | 示例值 | 说明 |
| --- | --- | --- |
| `WifiFallback` | `1` | 总开关：有线不可用时是否自动连无线 |
| `WifiSsid` | `OUC-AUTO` | 校园网无线 SSID |
| `WifiProfile` | `OUC-AUTO` | 该 SSID 在 Windows 里的无线配置文件名（一般与 SSID 相同） |
| `WifiConnectTimeoutSeconds` | `25` | 发出连接请求后最多等多少秒判定没连上 |
| `WifiCooldownSeconds` | `300` | 连不上后的冷却时间（秒），避免每轮白等 |

**"有线不通"的判定**：有线网卡没有默认路由 —— 没插网线、或插了但没拿到 DHCP 地址（只剩 `169.254.x.x` 自动私有地址）都算。有线正常时脚本完全不动无线。

### 断线自愈与重试节奏

| 键 | 示例值 | 说明 |
| --- | --- | --- |
| `WifiOfflineGraceSeconds` | `30` | 无线自查"能用"但探网不通时，连续不通满这么多秒才断开重连一次（抖动保护） |
| `WifiReassocCooldownSeconds` | `60` | 同一段断网里第 n 次重连的冷却 = 该值 × n |
| `WifiReassocCooldownMaxSeconds` | `300` | 上面的冷却上限（秒） |
| `BackoffMaxSeconds` | `120` | 认证失败退避上限（秒） |
| `WifiWatchSeconds` | `240` | 快速重试窗口最多蹲守多少秒（0 = 关闭，退回"等下一个 tick"） |
| `WifiWatchIntervalSeconds` | `10` | 快速重试窗口内的复探间隔（秒） |

## 工作原理

1. **探测** `Get-NetworkState`：先看有没有默认路由；有就逐条请求 `CheckUrls`，据此判定
   - `online` 外网可达 ｜ `portal` 被重定向到认证页 ｜ `linkdown` 没有默认路由 ｜ `unknown` 有路由但都不通
2. **决策** `Invoke-Check`：`online` 直接清零失败计数返回；`portal` 不动网卡、直接走认证；`unknown` / `linkdown` 进链路恢复流程。
3. **链路恢复** `Invoke-LinkRecovery`：
   - 无线自己都不可用 → 直接连接无线（原"有线不通切无线"，带 `WifiCooldownSeconds` 冷却）；
   - 无线自查"可用"但探网不通（关联已死）→ 记下不通起点，连续不通满 `WifiOfflineGraceSeconds` 秒才 `netsh wlan disconnect` + 重新连接，重复重连的冷却按 ×n 递增、封顶。
4. **快速重试窗口** `Invoke-OfflineWatch`：确认链路不通后不等下一个 tick，每 `WifiWatchIntervalSeconds` 秒复探一次、最多 `WifiWatchSeconds` 秒；探到 `online` 直接结束，探到 `portal` 就地把认证走完。
5. **认证** `Invoke-PortalLogin`：按 `PortalBase` / `PortalCandidates` 拼出 `/eportal/portal/login?callback=...&wlan_user_ip=<本机IP>` 请求，响应里出现"认证成功 / 已经在线 / result:1"之类特征即算成功。一轮里会**按候选顺序逐个门户尝试**，所以日志里可能看到两行"认证未通过"。
6. **失败退避** `Test-Backoff`：`wait = min(120 × 2^(失败次数-1), BackoffMaxSeconds)`。

```text
check 启动
 └─ 探网 Get-NetworkState
      ├─ online ──────────────→ 清零失败计数，退出
      ├─ portal ──────────────→ 门户认证 → 复检 → 退出
      └─ unknown / linkdown
           └─ Invoke-LinkRecovery
                ├─ 无线不可用 ──→ 连 OUC-AUTO
                └─ 无线"看着可用" → 连续不通满宽限 → 断开 + 重连（递增冷却）
                     └─ Invoke-OfflineWatch：每 10s 复探，最多 240s
                          ├─ online → 退出
                          └─ portal → 就地把认证走完
```

## 计划任务

- 任务名 `OUC-AutoLogin`，动作 `wscript.exe "<目录>\launcher.vbs" check`，工作目录＝脚本目录。
- 触发器：开机（停在登录界面也跑）+ 登录 + 常驻重复（默认每 1 分钟，由 `IntervalMinutes` 决定）。
- 登录类型 S4U、最低权限；`MultipleInstances=IgnoreNew`；单次执行上限 10 分钟（快速重试窗口上限 4 分钟，不会被强杀）。
- 用 `wscript` 而不是直接跑 `powershell.exe`：前者是 GUI 子系统、不分配控制台，不会闪一下黑窗口；后者即使加 `-WindowStyle Hidden`，Windows 终端仍可能替它开窗。
- 卸载：`.\ouc-autologin.ps1 uninstall`，或 `Unregister-ScheduledTask -TaskName OUC-AutoLogin -Confirm:$false`。

## 日志与状态文件

| 路径 | 内容 |
| --- | --- |
| `%LOCALAPPDATA%\OUC-AutoLogin\logs\log-YYYY-MM-DD.txt` | 每天一个日志，自动清理 14 天前的 |
| `%LOCALAPPDATA%\OUC-AutoLogin\state.json` | 连续失败次数 `Fails` / `LastFail` / `Reason` |
| `...\offline-since.stamp` | 连续不通的起点（恢复后自动删除） |
| `...\wifi-reassoc.json` | 本段断网内的强制重连次数与时间 |
| `launcher-error.log` | 只在启动器出错时生成于脚本目录 |

取不到 `%LOCALAPPDATA%` 时（某些无人登录会话）会退到用户目录，再退到脚本目录下的 `logs\`。

## 常见问题

**不是这两个门户地址能用吗？** 改 `PortalBase` / `PortalCandidates` 即可。默认候选是西海岸 `http://192.168.101.201:801` 与崂山 `https://10.100.29.2:802`；`auto` 会先按网关重定向自动判断。其他校区请自行测试，欢迎 PR。

**为什么脚本文件必须是带 BOM 的 UTF-8？** Windows PowerShell 5.1 在没有 BOM 时按系统 ANSI 代码页（简体中文环境即 GBK）解析脚本，中文会乱码并直接抛"表达式或语句中包含意外的标记"整篇语法错误。仓库已用 `.gitattributes` 固定换行，用编辑器改脚本时请保持 UTF-8 **with BOM**。

**为什么日志里偶尔一次掉线出现两行"认证未通过"？** 见"工作原理"第 5 条：一轮里会按候选顺序逐个门户尝试。

**会被判定为异常流量吗？** 常态就是每分钟一次 HTTP 探测，掉线时才会密集重试；频率与手动刷新网页相当。

## 已知限制

- **内网地址问题**：某些网络形态（如路由器 NAT 之后）取到的是 `192.168.1.x` 这类地址，门户用它认不到真实客户端，会返回 `AC认证失败`。脚本已优先采用 `IpProbeUrl` 页面上报的地址，但并非所有网络形态都返回。
- **验证范围有限**：仅在崂山与西海岸两套门户、`OUC-AUTO` 无线下实测过。
- **明文密码**：`config.ini` 里是明文（`setup` 会尝试用 `icacls` 收紧到仅当前账号可读）。后续可改为 Windows 凭据管理器 / DPAPI。
- **开机触发**依赖网卡在登录界面阶段就拿到 DHCP；实测可用，但不同机型与驱动可能有差异。

## 安全提示

- `config.ini` 含明文账号密码，**不要提交到 git、网盘或发给别人**（仓库里已把它写进 `.gitignore`）。
- 从本仓库复制出来的任何文件里都不应出现真实账号密码。

## 目录结构

```text
.
├── ouc-autologin.ps1      # 主脚本
├── launcher.vbs           # 零控制台启动器（计划任务用它拉起 powershell）
├── config.ini.example     # 配置模板（复制成 config.ini 后填账号密码）
├── .gitignore
├── .gitattributes
├── .editorconfig
├── LICENSE
├── README.md            # 英文说明（GitHub 默认展示）
└── README.zh-CN.md      # 本文件（中文说明）
```

## 相关项目

同样做海大校园网自动登录的项目，欢迎对照参考：Phuker/OUC-WiFi（Python，已停止维护）、jiange6666/OUC_Campus_Network（多 WAN 聚合）、Cuiyingzhe/OUCNetworkAutoConnection、ladeng07/OUC-autoLogin（iOS 快捷指令）。

## 许可

MIT，见 `LICENSE`。
