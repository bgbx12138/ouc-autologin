#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'check',
    [string]$Username = '',
    [string]$Password = '',
    [string]$PortalBase = '',
    [int]$IntervalMinutes = 0,
    [int]$Tail = 20,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$ConfigPath = Join-Path $Root 'config.ini'
$TaskName = 'OUC-AutoLogin'
$UserAgent = 'OUC-AutoLogin/1.0'
$Mutex = $null
$Cfg = $null

# 开机无人登录时是批量登录会话，%LOCALAPPDATA% 有取不到的可能，取不到就退到用户目录、再退到脚本目录，
# 绝不能因为路径拼不出来就抛错，那样认证本身就做不了了。
$DataRoot = ''
foreach ($cand in @($env:LOCALAPPDATA, $(if ($env:USERPROFILE) { (Join-Path $env:USERPROFILE 'AppData\Local') } else { '' }))) {
    if ($cand) { $DataRoot = $cand; break }
}
if (-not $DataRoot) { $DataRoot = $Root }
$LogDir = Join-Path $DataRoot 'OUC-AutoLogin\logs'
$StateFile = Join-Path $DataRoot 'OUC-AutoLogin\state.json'
$RecoveryDir = Split-Path -Parent $StateFile
$OfflineStamp = Join-Path $RecoveryDir 'offline-since.stamp'
$ReassocFile = Join-Path $RecoveryDir 'wifi-reassoc.json'

# 校园网门户用的是自签证书，只对配置里列出的门户主机放宽证书校验，其余站点仍按正常规则判断。
$InsecureHosts = @('10.100.29.2', '192.168.101.201', 'wxrz.ouc.edu.cn')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
[Net.ServicePointManager]::ServerCertificateValidationCallback = {
    param($sender, $certificate, $chain, $errors)
    try {
        if ([int]$errors -eq 0) { return $true }
        return ($InsecureHosts -contains ([Net.HttpWebRequest]$sender).RequestUri.Host)
    } catch { return $false }
}

function Write-Log {
    param([string]$Message)
    $now = Get-Date
    $file = Join-Path $LogDir ('log-' + $now.ToString('yyyy-MM-dd') + '.txt')
    foreach ($old in @(Get-ChildItem -LiteralPath $LogDir -File -Filter 'log-*.txt' -ErrorAction SilentlyContinue)) {
        if ($old.LastWriteTime -lt $now.AddDays(-14)) { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue }
    }
    $line = '[{0}] {1}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $file -Value $line -Encoding UTF8
    if (-not $Quiet) { Write-Host $line }
}

function Read-Config {
    $c = [ordered]@{
        Username         = ''
        Password         = ''
        PortalBase       = 'auto'
        PortalCandidates = 'http://192.168.101.201:801,https://10.100.29.2:802'
        IpProbeUrl       = 'https://wxrz.ouc.edu.cn/'
        CheckUrls        = 'http://baidu.com,https://www.apple.com/library/test/success.html'
        PortalPattern    = 'eportal|dr\.com|10\.100\.29\.2|192\.168\.101\.201|wxrz\.ouc\.edu\.cn'
        TimeoutSeconds   = '10'
        IntervalMinutes  = '2'
        NotifyOnFailure  = '1'
        LogoutUrls       = '/eportal/portal/logout,/eportal/?c=ACSetting&a=Logout&ver=1.0'
        WifiFallback     = '1'
        WifiSsid         = 'OUC-AUTO'
        WifiProfile      = 'OUC-AUTO'
        WifiConnectTimeoutSeconds = '25'
        WifiCooldownSeconds       = '300'
        WifiOfflineGraceSeconds       = '100'
        WifiReassocCooldownSeconds    = '180'
        WifiReassocCooldownMaxSeconds = '900'
        BackoffMaxSeconds             = '120'
        WifiWatchSeconds              = '240'
        WifiWatchIntervalSeconds      = '10'
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        foreach ($raw in @(Get-Content -LiteralPath $ConfigPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $t = $raw.Trim()
            if (-not $t -or $t.StartsWith('#') -or $t.StartsWith(';')) { continue }
            $i = $t.IndexOf('=')
            if ($i -lt 1) { continue }
            $k = $t.Substring(0, $i).Trim()
            if ($c.Contains($k)) { $c[$k] = $t.Substring($i + 1).Trim() }
        }
    }
    $c.CheckUrlList = @($c.CheckUrls -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $c.PortalCandidateList = @($c.PortalCandidates -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $c.LogoutUrlList = @($c.LogoutUrls -split ',' | Where-Object { $_ })
    $intTimeout = 10
    if (-not [int]::TryParse($c.TimeoutSeconds, [ref]$intTimeout) -or $intTimeout -lt 3) { $intTimeout = 10 }
    $c.TimeoutSeconds = $intTimeout
    $intInterval = 2
    if (-not [int]::TryParse($c.IntervalMinutes, [ref]$intInterval) -or $intInterval -lt 1) { $intInterval = 2 }
    $c.IntervalMinutes = $intInterval
    if (-not $c.WifiSsid) { $c.WifiSsid = 'OUC-AUTO' }
    if (-not $c.WifiProfile) { $c.WifiProfile = $c.WifiSsid }
    $intWifiTimeout = 25
    if (-not [int]::TryParse($c.WifiConnectTimeoutSeconds, [ref]$intWifiTimeout) -or $intWifiTimeout -lt 5) { $intWifiTimeout = 25 }
    $c.WifiConnectTimeoutSeconds = $intWifiTimeout
    $intWifiCooldown = 300
    if (-not [int]::TryParse($c.WifiCooldownSeconds, [ref]$intWifiCooldown) -or $intWifiCooldown -lt 0) { $intWifiCooldown = 300 }
    $c.WifiCooldownSeconds = $intWifiCooldown
    $intGrace = 100
    if (-not [int]::TryParse($c.WifiOfflineGraceSeconds, [ref]$intGrace) -or $intGrace -lt 0) { $intGrace = 100 }
    $c.WifiOfflineGraceSeconds = $intGrace
    $intReassoc = 180
    if (-not [int]::TryParse($c.WifiReassocCooldownSeconds, [ref]$intReassoc) -or $intReassoc -lt 30) { $intReassoc = 180 }
    $c.WifiReassocCooldownSeconds = $intReassoc
    $intReassocMax = 900
    if (-not [int]::TryParse($c.WifiReassocCooldownMaxSeconds, [ref]$intReassocMax) -or $intReassocMax -lt $intReassoc) { $intReassocMax = 900 }
    $c.WifiReassocCooldownMaxSeconds = $intReassocMax
    $intBackoffMax = 120
    if (-not [int]::TryParse($c.BackoffMaxSeconds, [ref]$intBackoffMax) -or $intBackoffMax -lt 30) { $intBackoffMax = 120 }
    $c.BackoffMaxSeconds = $intBackoffMax
    $intWatch = 240
    if (-not [int]::TryParse($c.WifiWatchSeconds, [ref]$intWatch) -or $intWatch -lt 0) { $intWatch = 240 }
    $c.WifiWatchSeconds = $intWatch
    $intWatchIv = 10
    if (-not [int]::TryParse($c.WifiWatchIntervalSeconds, [ref]$intWatchIv) -or $intWatchIv -lt 5) { $intWatchIv = 10 }
    $c.WifiWatchIntervalSeconds = $intWatchIv
    return $c
}

function Invoke-Http {
    param([string]$Url, [switch]$AllowRedirect, [int]$TimeoutSec = 0)
    $r = @{ Status = 0; Body = ''; Location = ''; Error = '' }
    $resp = $null
    $limit = if ($TimeoutSec -gt 0) { $TimeoutSec } else { $Cfg.TimeoutSeconds }
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.AllowAutoRedirect = [bool]$AllowRedirect
        $req.Timeout = $limit * 1000
        $req.UserAgent = $UserAgent
        $req.Proxy = $null
        # 不复用连接、带上 no-cache，避免探测拿到旧结果把“已掉线”看成“还在线”。
        $req.KeepAlive = $false
        $req.Headers['Cache-Control'] = 'no-cache'
        $resp = $req.GetResponse()
    } catch [Net.WebException] {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { $r.Error = $_.Exception.Message; return $r }
    } catch {
        $r.Error = $_.Exception.Message
        return $r
    }
    try {
        $r.Status = [int]$resp.StatusCode
        $r.Location = [string]$resp.Headers['Location']
        $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $r.Body = $reader.ReadToEnd()
        $reader.Dispose()
    } catch { $r.Error = $_.Exception.Message }
    finally { if ($resp) { $resp.Close() } }
    return $r
}

function Get-PortalBaseFromUrl {
    param([string]$Url)
    try {
        $u = [uri]$Url
        if ($u.Host) { return ($u.Scheme + '://' + $u.Authority) }
    } catch { }
    return ''
}

function Test-DefaultRouteExists {
    try { return [bool](Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Select-Object -First 1) } catch { return $true }
}

# ---- 有线优先、无线兜底（2026-10-10 新增） ----------------------------------
# 判定“一条链路能不能用”只看三件事：网卡在 Up、IPv4 不是 169.254 的自动私有地址、这张网卡上有默认路由。
# 三点都不依赖界面语言，中文系统上也判得对；虚拟网卡（本地连接* N、各种隧道）用 -Physical 挡掉。

function Invoke-Netsh {
    param([string[]]$Arguments)
    $old = $ErrorActionPreference
    # netsh 会往 stderr 写正常内容，而脚本全局是 ErrorActionPreference = Stop，
    # 配合 2>&1 会把正常输出当成错误抛出去，所以这里临时改成 Continue。
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& netsh @Arguments 2>&1 | Out-String)
        return @{ Ok = ($LASTEXITCODE -eq 0); Text = ([string]$out).Trim(); Code = $LASTEXITCODE }
    } catch {
        return @{ Ok = $false; Text = $_.Exception.Message; Code = -1 }
    } finally {
        $ErrorActionPreference = $old
    }
}

function Get-PhysicalAdapter {
    param([ValidateSet('wired', 'wifi')][string]$Kind = 'wired')
    $all = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    if (-not $all) { $all = @(Get-NetAdapter -ErrorAction SilentlyContinue) }
    if ($Kind -eq 'wifi') { return @($all | Where-Object { $_.PhysicalMediaType -eq 'Native 802.11' -or $_.MediaType -eq 'Native 802.11' }) }
    return @($all | Where-Object { $_.PhysicalMediaType -like '802.3*' -or $_.MediaType -eq '802.3' })
}

function Get-InterfaceIPv4 {
    param([int]$IfIndex)
    try {
        $addr = @(Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction Stop |
                  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                  Select-Object -First 1)
        if ($addr) { return [string]$addr[0].IPAddress }
    } catch { }
    return ''
}

# 指定网卡上有没有默认路由。Get-NetRoute 查不到时会直接抛 CIM 异常，必须吞掉。
function Test-RouteOnInterface {
    param([int]$IfIndex)
    try { return [bool](Get-NetRoute -InterfaceIndex $IfIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Select-Object -First 1) } catch { return $false }
}

function Test-LinkUsable {
    param([ValidateSet('wired', 'wifi')][string]$Kind = 'wired')
    $label = if ($Kind -eq 'wifi') { '无线' } else { '有线' }
    $adapters = @(Get-PhysicalAdapter -Kind $Kind)
    if (-not $adapters) { return @{ Ok = $false; Name = ''; Ip = ''; Index = 0; Detail = "本机没有$label 网卡" } }
    $notes = @()
    foreach ($a in $adapters) {
        if ($a.Status -ne 'Up') { $notes += "$($a.Name)：$($a.Status)"; continue }
        $ip = Get-InterfaceIPv4 -IfIndex ([int]$a.ifIndex)
        if (-not $ip) { $notes += "$($a.Name)：插着但没拿到有效 IP（只剩 169.254 的自动私有地址）"; continue }
        if (-not (Test-RouteOnInterface -IfIndex ([int]$a.ifIndex))) { $notes += "$($a.Name)：有地址 $ip 但没有默认路由"; continue }
        return @{ Ok = $true; Name = [string]$a.Name; Ip = $ip; Index = [int]$a.ifIndex; Detail = "$($a.Name) $ip" }
    }
    if (-not $notes) { $notes = @("$label 不可用") }
    return @{ Ok = $false; Name = ''; Ip = ''; Index = 0; Detail = ($notes -join '；') }
}

# 当前实际在走的默认路由：Windows 按“路由度量 + 接口度量”取最小的那条。
function Get-ActiveRoute {
    try {
        $r = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
               Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric } | Select-Object -First 1)
        if ($r) { return $r[0] }
    } catch { }
    return $null
}

function Get-WifiAdapterOrNull {
    $wifi = @(Get-PhysicalAdapter -Kind 'wifi')
    if (-not $wifi) { return $null }
    $up = @($wifi | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1)
    if ($up) { return $up[0] }
    return $wifi[0]
}

# 系统里没有这个无线配置时（重装系统、换网卡），按开放网络生成一份。
function Ensure-WifiProfile {
    param([string]$InterfaceName)
    $p = Invoke-Netsh -Arguments @('wlan', 'show', 'profiles')
    if ($p.Text -and $p.Text.Contains($Cfg.WifiProfile)) { return $true }
    Write-Log "系统里没有无线配置 [$($Cfg.WifiProfile)]，按开放网络自动生成一份。"
    $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$($Cfg.WifiProfile)</name>
    <SSIDConfig>
        <SSID><name>$($Cfg.WifiSsid)</name></SSID>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>manual</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>open</authentication>
                <encryption>none</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
        </security>
    </MSM>
</WLANProfile>
"@
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ouc-wifi-' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($tmp, $xml, $utf8)
        $na = @('wlan', 'add', 'profile', ('filename=' + $tmp))
        if ($InterfaceName) { $na += ('interface=' + $InterfaceName) }
        $res = Invoke-Netsh -Arguments $na
        Write-Log ('添加无线配置文件：' + (Clear-Brief $res.Text))
        return $res.Ok
    } catch {
        Write-Log "添加无线配置文件失败：$($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# 把无线接上。返回 $true 表示无线已经拿到可用地址（可能本来就连着）。
function Connect-WifiPath {
    param([switch]$Force, [switch]$Reassociate)
    if ($Cfg.WifiFallback -ne '1') { Write-Log '配置里关掉了“有线不通切无线”（WifiFallback = 0），本次不切。'; return $false }
    $adapter = Get-WifiAdapterOrNull
    if (-not $adapter) { Write-Log '本机没有无线网卡，切不了无线。'; return $false }
    $now = Test-LinkUsable -Kind 'wifi'
    if ($now.Ok -and -not $Reassociate) { Write-Log "无线本来就能用（$($now.Detail)），不需要重新连接。"; return $true }
    if ($now.Ok -and $Reassociate) { Write-Log "无线自查是好的（$($now.Detail)），但探网结果说链路不通，按强制重新关联处理。" }
    $stamp = Join-Path (Split-Path -Parent $StateFile) 'wifi-attempt.stamp'
    if (-not $Force -and (Test-Path -LiteralPath $stamp)) {
        try {
            $age = [int](((Get-Date) - (Get-Item -LiteralPath $stamp).LastWriteTime).TotalSeconds)
            if ($age -lt [int]$Cfg.WifiCooldownSeconds) {
                Write-Log ("{0} 秒前刚试过连无线没成，冷却 {1} 秒内不再重复试，免得每 2 分钟白折腾一次。" -f $age, $Cfg.WifiCooldownSeconds)
                return $false
            }
        } catch { }
    }
    if ($adapter.Status -ne 'Up') {
        Write-Log "无线网卡 [$($adapter.Name)] 当前是 $($adapter.Status)，先试着启用它。"
        try { Enable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop; Start-Sleep -Seconds 3 }
        catch { Write-Log "启用无线网卡失败（无人值守任务没有管理员权限）：$($_.Exception.Message)" }
    }
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $stamp) -Force | Out-Null
        Set-Content -LiteralPath $stamp -Value (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') -Encoding UTF8
    } catch { }
    if (-not (Ensure-WifiProfile -InterfaceName $adapter.Name)) { return $false }
    Write-Log "正在连接无线 [$($Cfg.WifiSsid)]（网卡 $($adapter.Name)）…"
    $res = Invoke-Netsh -Arguments @('wlan', 'connect', ('name=' + $Cfg.WifiProfile), ('ssid=' + $Cfg.WifiSsid), ('interface=' + $adapter.Name))
    Write-Log ('连接请求：' + (Clear-Brief $res.Text))
    $deadline = (Get-Date).AddSeconds([int]$Cfg.WifiConnectTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $w = Test-LinkUsable -Kind 'wifi'
        if ($w.Ok) { Write-Log "无线已连上并拿到默认路由（$($w.Detail)），接着走原来的认证流程。"; return $true }
    }
    Write-Log ("等了 {0} 秒，无线还是没拿到可用地址（可能不在 {1} 覆盖范围内）。" -f $Cfg.WifiConnectTimeoutSeconds, $Cfg.WifiSsid)
    return $false
}

function Show-WifiInfo {
    $wired = Test-LinkUsable -Kind 'wired'
    $wifi = Test-LinkUsable -Kind 'wifi'
    if ($wired.Ok) { Write-Host "有线链路    : 可用 — $($wired.Detail)" } else { Write-Host "有线链路    : 不可用 — $($wired.Detail)" }
    if ($wifi.Ok) { Write-Host "无线链路    : 可用 — $($wifi.Detail)" } else { Write-Host "无线链路    : 不可用 — $($wifi.Detail)" }
    $r = Get-ActiveRoute
    if ($r) { Write-Host "当前出口    : $($r.InterfaceAlias)（接口度量 $($r.InterfaceMetric)）" } else { Write-Host '当前出口    : 没有默认路由' }
    $a = Get-WifiAdapterOrNull
    if ($a) { Write-Host "无线网卡    : $($a.Name) — $($a.Status)" } else { Write-Host '无线网卡    : 没有' }
    $p = Invoke-Netsh -Arguments @('wlan', 'show', 'profiles')
    if ($p.Text -and $p.Text.Contains($Cfg.WifiProfile)) { Write-Host "无线配置    : $($Cfg.WifiProfile)（已存在）" } else { Write-Host "无线配置    : $($Cfg.WifiProfile)（缺失，连接时会自动生成）" }
    if ($Cfg.WifiFallback -eq '1') {
        Write-Host "切无线开关  : 开（SSID $($Cfg.WifiSsid)，连接超时 $($Cfg.WifiConnectTimeoutSeconds) 秒，失败冷却 $($Cfg.WifiCooldownSeconds) 秒）"
        Write-Host "断线自愈    : 探网不通满 $($Cfg.WifiOfflineGraceSeconds) 秒后断开重连；重复重连冷却 $($Cfg.WifiReassocCooldownSeconds)xn 秒，上限 $($Cfg.WifiReassocCooldownMaxSeconds) 秒"
        Write-Host "快速重试    : 链路不通时每 $($Cfg.WifiWatchIntervalSeconds) 秒复探一次，最多蹲守 $($Cfg.WifiWatchSeconds) 秒（超时上限 $($Cfg.BackoffMaxSeconds) 秒退避）"
        $o = Get-OfflineSince
        if ($o) { Write-Host "离线起点    : $($o.ToString('yyyy-MM-dd HH:mm:ss'))" } else { Write-Host '离线起点    : 无（链路正常，计数已清零）' }
        $rs = Get-ReassocInfo
        if ($rs.LastAt) { Write-Host "强制重连    : 本段断网已试 $($rs.Attempts) 次，最近一次 $($rs.LastAt)" } else { Write-Host '强制重连    : 本段断网未触发过' }
    } else {
        Write-Host '切无线开关  : 关'
    }
    $stamp = Join-Path (Split-Path -Parent $StateFile) 'wifi-attempt.stamp'
    if (Test-Path -LiteralPath $stamp) { Write-Host "上次试连    : $((Get-Item -LiteralPath $stamp).LastWriteTime)" }
}


function Get-NetworkState {
    $errors = @()
    foreach ($u in $Cfg.CheckUrlList) {
        $r = Invoke-Http $u
        if ($r.Status -eq 0) { $errors += ('{0} 请求失败：{1}' -f $u, $r.Error); continue }
        $loc = [string]$r.Location
        if ($r.Status -ge 300 -and $r.Status -lt 400 -and $loc -and ($loc -match $Cfg.PortalPattern)) {
            return @{ State = 'portal'; Portal = (Get-PortalBaseFromUrl $loc); Detail = "$u 被重定向到认证页 $loc" }
        }
        if ($r.Status -ge 200 -and $r.Status -lt 300) {
            if ($r.Body -match $Cfg.PortalPattern) { return @{ State = 'portal'; Portal = ''; Detail = "$u 返回的内容像认证页" } }
            return @{ State = 'online'; Portal = ''; Detail = "$u 返回 HTTP $($r.Status)" }
        }
        $r2 = Invoke-Http $u -AllowRedirect
        if ($r2.Status -ge 200 -and $r2.Status -lt 300) {
            if ($r2.Body -match $Cfg.PortalPattern) { return @{ State = 'portal'; Portal = ''; Detail = "$u 跳转后是认证页" } }
            return @{ State = 'online'; Portal = ''; Detail = "$u 跳转后返回 HTTP $($r2.Status)" }
        }
        $errors += ('{0} 返回 HTTP {1}' -f $u, $r.Status)
    }
    if (-not (Test-DefaultRouteExists)) { return @{ State = 'linkdown'; Portal = ''; Detail = '网卡未连接或没有默认路由' } }
    return @{ State = 'unknown'; Portal = ''; Detail = ($errors -join '；') }
}

function Get-ClientIp {
    param([switch]$Fast)
    if ($Fast) { return Get-LocalIPv4 }
    $r = Invoke-Http $Cfg.IpProbeUrl -AllowRedirect -TimeoutSec 4
    foreach ($pat in @("v46ip\s*=\s*'([0-9.]+)", "ss5\s*=\s*'([0-9.]+)", "myv4ip\s*=\s*'([0-9.]+)", "v64ip\s*=\s*'([0-9.]+)")) {
        if ($r.Body -match $pat) { return $Matches[1].Trim() }
    }
    # 掉线时认证页可能拿不到 IP，退一步用本机默认路由上的网卡地址，校园网里它就是认证系统看到的那个。
    return Get-LocalIPv4
}

function Get-LocalIPv4 {
    # 有线和无线都连着时必须报“当前真正在走的那张网卡”的地址，
    # 否则门户会拿另一张卡的地址给这台机器认证，怎么登都不通。
    $route = Get-ActiveRoute
    if ($route) {
        $ip = Get-InterfaceIPv4 -IfIndex ([int]$route.InterfaceIndex)
        if ($ip) { return $ip }
    }
    try {
        $conf = Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
        if ($conf -and $conf.IPv4Address) { return [string]($conf.IPv4Address.IPAddress | Select-Object -First 1) }
    } catch { }
    return '0.0.0.0'
}

function Get-PortalBaseList {
    param([string]$Detected)
    $list = @()
    if ($Cfg.PortalBase -and $Cfg.PortalBase -ne 'auto') { $list += $Cfg.PortalBase }
    elseif ($Detected) { $list += $Detected }
    $list += $Cfg.PortalCandidateList
    @($list | Where-Object { $_ } | Select-Object -Unique)
}

function Build-Query {
    param([hashtable]$Pairs)
    $parts = foreach ($k in $Pairs.Keys) { '{0}={1}' -f $k, [uri]::EscapeDataString([string]$Pairs[$k]) }
    return ($parts -join '&')
}

function Clear-Brief {
    param([string]$Text)
    $t = $Text -replace '\s+', ' '
    if ($Cfg.Password) { $t = $t.Replace($Cfg.Password, '******') }
    $t = $t.Trim()
    if ($t.Length -gt 220) { $t = $t.Substring(0, 220) + '…' }
    return $t
}

function Invoke-PortalLogin {
    param([string]$Base, [string]$Ip)
    $query = @{
        callback = 'AutoLogin'; login_method = '1'; lang = 'zh-cn'; jsVersion = '4.1'; terminal_type = '1'
        user_account = $Cfg.Username; user_password = $Cfg.Password
        wlan_user_ip = $Ip; wlan_user_ipv6 = ''; wlan_user_mac = '000000000000'; wlan_ac_ip = ''; wlan_ac_name = ''
        v = (Get-Random -Minimum 10000 -Maximum 99999).ToString()
    }
    # 日志里绝不出现带密码的请求地址，只记门户返回内容。
    $r = Invoke-Http ($Base.TrimEnd('/') + '/eportal/portal/login?' + (Build-Query $query)) -AllowRedirect
    # “result":1 是认证通过；已经在线说明这台机器的会话还有效，都不用再登。
    $ok = ($r.Status -ge 200 -and $r.Status -lt 300) -and
          ($r.Body -match '认证成功|已经在线|"result"\s*:\s*1|\\u8ba4\\u8bc1\\u6210\\u529f|\\u5df2\\u7ecf\\u5728\\u7ebf')
    $brief = if ($r.Body) { Clear-Brief $r.Body } else { Clear-Brief ([string]$r.Error) }
    return @{ Ok = $ok; Status = $r.Status; Brief = $brief }
}

function Get-State {
    if (Test-Path -LiteralPath $StateFile) {
        try { return (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{ Fails = 0; LastFail = ''; Reason = '' }
}

function Set-State {
    param([int]$Fails, [string]$Reason)
    try { New-Item -ItemType Directory -Path (Split-Path -Parent $StateFile) -Force | Out-Null } catch { }
    $obj = [pscustomobject]@{
        Fails    = $Fails
        LastFail = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Reason   = $Reason
    }
    ConvertTo-Json -InputObject $obj -Compress | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

# ── 链路自愈的限速状态：连续不通的起点 + 强制重连的递增冷却（都在 state.json 同目录）───────────
function Get-OfflineSince {
    if (-not (Test-Path -LiteralPath $OfflineStamp)) { return $null }
    try {
        $t = [datetime]::MinValue
        if ([datetime]::TryParse((Get-Content -LiteralPath $OfflineStamp -Raw -Encoding UTF8).Trim(), [ref]$t)) { return $t }
    } catch { }
    return $null
}

function Set-OfflineSince {
    param([datetime]$At)
    try {
        New-Item -ItemType Directory -Path $RecoveryDir -Force | Out-Null
        Set-Content -LiteralPath $OfflineStamp -Value $At.ToString('yyyy-MM-dd HH:mm:ss') -Encoding UTF8
    } catch { }
}

function Get-ReassocInfo {
    if (Test-Path -LiteralPath $ReassocFile) {
        try {
            $o = Get-Content -LiteralPath $ReassocFile -Raw -Encoding UTF8 | ConvertFrom-Json
            return [pscustomobject]@{ Attempts = [int]$o.Attempts; LastAt = [string]$o.LastAt }
        } catch { }
    }
    return [pscustomobject]@{ Attempts = 0; LastAt = '' }
}

function Set-ReassocInfo {
    param([int]$Attempts, [string]$LastAt)
    try {
        New-Item -ItemType Directory -Path $RecoveryDir -Force | Out-Null
        $o = [pscustomobject]@{ Attempts = $Attempts; LastAt = $LastAt }
        ConvertTo-Json -InputObject $o -Compress | Set-Content -LiteralPath $ReassocFile -Encoding UTF8
    } catch { }
}

# 一次不通的“这段断网”结束了，把自愈计数清零。
function Reset-RecoveryState {
    try { Remove-Item -LiteralPath $OfflineStamp -Force -ErrorAction SilentlyContinue } catch { }
    $r = Get-ReassocInfo
    if ([int]$r.Attempts -ne 0 -or $r.LastAt) { Set-ReassocInfo -Attempts 0 -LastAt '' }
}

# 链路自愈。只有探网结果（Get-NetworkState）说链路不通（unknown / linkdown）时才会走到这里：
#   场景一：无线自己就没连上（没地址/没路由）——等价于原来的“有线不通切无线”，立刻连，靠 wifi-attempt.stamp 冷却防抖；
#   场景二：无线自查“能用”但探网不通——关联多半已经死了（Windows 仍留着旧 IP 与默认路由），
#           必须断开再重新关联，这条动作重，所以要求连续不通满宽限期、并对重复重连做递增冷却。
# 返回 $true 表示本轮真的动过网卡（调用方据此复查一次探网结果）。
function Invoke-LinkRecovery {
    param([string]$State)
    if ($Cfg.WifiFallback -ne '1') { return $false }
    $adapter = Get-WifiAdapterOrNull
    if (-not $adapter) { Write-Log '本机没有无线网卡，链路自愈帮不上忙。'; return $false }
    $now = Get-Date
    $wifiLink = Test-LinkUsable -Kind 'wifi'

    if (-not $wifiLink.Ok) {
        Write-Log ("探网结果 {0}，无线当前不可用（{1}），走兜底连接，不额外等待。" -f $State, $wifiLink.Detail)
        Reset-RecoveryState
        return (Connect-WifiPath)
    }

    $since = Get-OfflineSince
    if (-not $since) {
        Set-OfflineSince -At $now
        Write-Log ("探网结果 {0}，但无线自查显示「能用」（{1}）：先记下这次不通的起点，连续不通满 {2} 秒才断开重连，免得一次抖动就折腾网卡。" -f $State, $wifiLink.Detail, [int]$Cfg.WifiOfflineGraceSeconds)
        return $false
    }
    $offlineSec = [int]($now - $since).TotalSeconds
    if ($offlineSec -lt [int]$Cfg.WifiOfflineGraceSeconds) {
        Write-Log ("链路已连续不通 {0} 秒（{1}），还没到 {2} 秒的重连门槛，本轮只观测。" -f $offlineSec, $State, [int]$Cfg.WifiOfflineGraceSeconds)
        return $false
    }

    $rs = Get-ReassocInfo
    if ($rs.LastAt) {
        $lastAt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$rs.LastAt, [ref]$lastAt)) {
            $cool = [int][math]::Min([int]$Cfg.WifiReassocCooldownSeconds * [math]::Max(1, [int]$rs.Attempts), [int]$Cfg.WifiReassocCooldownMaxSeconds)
            $until = $lastAt.AddSeconds($cool)
            if ($now -lt $until) {
                Write-Log ("本段断网已强制重连 {0} 次，按递增冷却等到 {1} 再试（距上次 {2} 秒，本次冷却 {3} 秒），期间不重复重连。" -f $rs.Attempts, $until.ToString('HH:mm:ss'), [int]($now - $lastAt).TotalSeconds, $cool)
                return $false
            }
        }
    }

    $attempts = [int]$rs.Attempts + 1
    Write-Log ("探网结果 {0}，无线自查「能用」但链路不通，第 {1} 次强制重新关联无线 [{2}]。" -f $State, $attempts, $Cfg.WifiSsid)
    Set-ReassocInfo -Attempts $attempts -LastAt $now.ToString('yyyy-MM-dd HH:mm:ss')
    $d = Invoke-Netsh -Arguments @('wlan', 'disconnect', ('interface=' + $adapter.Name))
    Write-Log ('断开无线：' + (Clear-Brief $d.Text))
    Start-Sleep -Seconds 2
    Connect-WifiPath -Force -Reassociate | Out-Null
    return $true
}

function Show-Balloon {
    param([string]$Title, [string]$Text)
    # 无人值守（S4U）跑在没有交互桌面的会话里，气泡弹不出来，白等 10 秒，直接只留日志。
    if (-not [Environment]::UserInteractive) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $ni = New-Object Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Exclamation
        $ni.BalloonTipIcon = 'Warning'
        $ni.BalloonTipTitle = $Title
        $ni.BalloonTipText = $Text
        $ni.Visible = $true
        $ni.ShowBalloonTip(10000)
        Start-Sleep -Seconds 10
        $ni.Dispose()
    } catch { }
}

function Test-Backoff {
    $s = Get-State
    $fails = 0
    if ($s.Fails) { $fails = [int]$s.Fails }
    if ($fails -lt 1 -or -not $s.LastFail) { return $false }
    $wait = [math]::Min(120 * [math]::Pow(2, $fails - 1), [int]$Cfg.BackoffMaxSeconds)
    $last = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$s.LastFail, [ref]$last)) { return $false }
    $until = $last.AddSeconds($wait)
    if ((Get-Date) -lt $until) {
        Write-Log ("认证已连续失败 {0} 次，退避到 {1} 再试，避免密码错误次数过多导致账号被锁。" -f $fails, $until.ToString('HH:mm'))
        return $true
    }
    return $false
}

# 快速重试窗口（2026-10-14 新增）：链路不通时不再干等下一条任务（间隔 1 分钟），
# 就地每 WifiWatchIntervalSeconds 秒复探一次，最多蹲守 WifiWatchSeconds 秒；探到 online / portal 立即返回，
# 探到不通就交给 Invoke-LinkRecovery 做宽限判定与强制重连（它自带递增冷却，不会反复折腾网卡）。
function Invoke-OfflineWatch {
    param([object]$InitialState)
    $interval = [int]$Cfg.WifiWatchIntervalSeconds
    $maxSec = [int]$Cfg.WifiWatchSeconds
    if ($maxSec -le 0) { return $InitialState }
    if ($interval -lt 5) { $interval = 10 }
    $st = $InitialState
    $start = Get-Date
    $n = 0
    Write-Log ("链路不通，进入快速重试窗口：每 {0} 秒复探一次，最多蹲守 {1} 秒。" -f $interval, $maxSec)
    while ($true) {
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        if ($elapsed + $interval -gt $maxSec) { break }
        Start-Sleep -Seconds $interval
        $n++
        $st = Get-NetworkState
        Write-Log ('网络状态：{0}（{1}）[快速重试第 {2} 次]' -f $st.State, $st.Detail, $n)
        if ($st.State -eq 'online') {
            Reset-RecoveryState
            if ((Get-State).Fails -gt 0) { Set-State -Fails 0 -Reason '' }
            Write-Log "快速重试窗口内网络已恢复（$($st.Detail)）。"
            return $st
        }
        if ($st.State -eq 'portal') { Reset-RecoveryState; return $st }
        if (Invoke-LinkRecovery -State $st.State) {
            $st2 = Get-NetworkState
            Write-Log ('重连后网络状态：{0}（{1}）' -f $st2.State, $st2.Detail)
            $st = $st2
            if ($st.State -eq 'online') {
                Reset-RecoveryState
                if ((Get-State).Fails -gt 0) { Set-State -Fails 0 -Reason '' }
                Write-Log "快速重试窗口内网络已恢复（$($st.Detail)）。"
                return $st
            }
            if ($st.State -eq 'portal') { Reset-RecoveryState; return $st }
        }
    }
    Write-Log ("快速重试窗口结束（{0} 秒，共复探 {1} 次），链路仍未恢复。" -f $maxSec, $n)
    return $st
}

function Invoke-Check {
    param([switch]$ForceLogin)
    if (-not $Cfg.Username -or -not $Cfg.Password) {
        Write-Log "未配置账号密码：请先编辑 $ConfigPath 的 Username / Password，或运行 setup。"
        return $false
    }
    if (-not $ForceLogin) {
        # 先看探网结果，再决定要不要动网卡：链路通（online / portal）就完全不碰网络；
        # 只有探网明确说链路不通（unknown / linkdown）才交给 Invoke-LinkRecovery 做自愈，
        # 自愈自带宽限期与递增冷却，避免“反复尝试重连”。
        $st = Get-NetworkState
        Write-Log ('网络状态：{0}（{1}）' -f $st.State, $st.Detail)
        if ($st.State -eq 'online') {
            Reset-RecoveryState
            if ((Get-State).Fails -gt 0) { Set-State -Fails 0 -Reason '' }
            return $true
        }
        if ($st.State -eq 'portal') {
            # 被重定向到认证页说明链路是通的，别动网卡。
            Reset-RecoveryState
        } else {
            if (Invoke-LinkRecovery -State $st.State) {
                $st2 = Get-NetworkState
                Write-Log ('重连后网络状态：{0}（{1}）' -f $st2.State, $st2.Detail)
                if ($st2.State -eq 'online') {
                    Reset-RecoveryState
                    if ((Get-State).Fails -gt 0) { Set-State -Fails 0 -Reason '' }
                    return $true
                }
                if ($st2.State -eq 'portal') { $st = $st2 }
            }
            if ($st.State -eq 'linkdown' -and [int]$Cfg.WifiWatchSeconds -gt 0) {
                # 有线、无线都没有可用链路：门户肯定问不到，别白等两次 10 秒超时，直接进快速重试窗口。
                Write-Log '有线、无线都没有可用的默认路由（网线不通且无线没接上），进入快速重试窗口等链路恢复。'
                $st = Invoke-OfflineWatch -InitialState $st
                if ($st.State -eq 'online') { return $true }
                if ($st.State -ne 'portal') {
                    Write-Log '快速重试窗口内链路仍未恢复，等下一轮任务再试。'
                    return $false
                }
            } elseif ($st.State -eq 'linkdown') {
                Write-Log '有线、无线都没有可用的默认路由（网线不通且无线没接上），校园网认证帮不上忙，等链路恢复后再自动重试。'
                return $false
            }
        }
        if (Test-Backoff) { return $false }
    } else {
        Write-Log '强制执行一次认证（用于验证账号密码和门户地址）。'
    }

    # 认证段最多走两轮：第一轮用当前探网结果；只有门户全无响应（链路确实不可达）时才进快速重试窗口，
    # 窗口内链路一恢复，就地把认证走完，不再等下一个任务 tick。
    for ($round = 0; $round -lt 2; $round++) {
        if ($ForceLogin) {
            $portal = ''
            $offline = $false
            $reason = '手动测试'
        } else {
            $portal = $st.Portal
            $offline = $true
            $reason = if ($st.State -eq 'portal') { '检测到认证页' } else { '联网检测全部失败，按掉线处理' }
        }

        # 已掉线时认证页本身不可达，再去问 wxrz 会白等十几秒断网，直接用本机默认路由的 IP。
        $ip = if ($offline) { Get-ClientIp -Fast } else { Get-ClientIp }
        Write-Log "$reason，本机认证 IP 按 $ip 提交。"
        $bases = Get-PortalBaseList $portal
        $portalAnswered = $false
        foreach ($base in $bases) {
            $res = Invoke-PortalLogin -Base $base -Ip $ip
            $target = Get-PortalBaseFromUrl ($base + '/')
            if ([int]$res.Status -gt 0) { $portalAnswered = $true }
            if ($res.Ok) {
                Write-Log ("门户 {0} 返回 {1}：{2}" -f $target, $res.Status, $res.Brief)
                if (-not $ForceLogin) {
                    Start-Sleep -Seconds 3
                    $after = Get-NetworkState
                    if ($after.State -eq 'online') {
                        Write-Log "认证成功，网络已恢复（$($after.Detail)）。"
                        Set-State -Fails 0 -Reason ''
                        return $true
                    }
                    Write-Log "认证接口说成功，但复查网络仍是 $($after.State)：$($after.Detail)"
                    Set-State -Fails 1 -Reason '认证后仍无法联网'
                    continue
                }
                Set-State -Fails 0 -Reason ''
                return $true
            }
            Write-Log ("门户 {0} 认证未通过（HTTP {1}）：{2}" -f $target, $res.Status, $res.Brief)
        }
        if ($ForceLogin) {
            Write-Log '测试认证失败：请核对 Username / Password / PortalCandidates。'
            return $false
        }
        if ($portalAnswered) {
            $s = Get-State
            $fails = ([int]$s.Fails) + 1
            Set-State -Fails $fails -Reason '所有门户都认证失败'
            Write-Log "本轮认证失败（连续第 $fails 次）。"
            if ($Cfg.NotifyOnFailure -eq '1' -and $fails -ge 2) {
                Show-Balloon '校园网自动登录失败' "已连续 $fails 次认证失败，请检查账号密码或校园网欠费情况。"
            }
            return $false
        }
        # 门户一个都没回话（HTTP 0）= 链路压根不可达，不是账号密码的问题，不能拿它去撞防锁定退避。
        $s = Get-State
        Write-Log ("门户全部无响应（HTTP 0，链路不可达），属于网络不通而不是账号问题，不计入防锁定失败次数（当前仍为 {0} 次）。" -f ([int]$s.Fails))
        # 探网说 unknown 却连门户都没一个回话，说明链路确实不通（不是「校园网通、外网被挡」的认证页场景）：
        # 不再等下一个 tick，就地进入快速重试窗口。
        if ($round -ge 1 -or [int]$Cfg.WifiWatchSeconds -le 0) { break }
        $st = Invoke-OfflineWatch -InitialState $st
        if ($st.State -eq 'online') { return $true }
        if ($st.State -ne 'portal') {
            Write-Log '快速重试窗口内链路仍未恢复，等下一轮任务再试。'
            break
        }
        Write-Log '快速重试窗口内链路已恢复，接着把认证走完。'
        if (Test-Backoff) { break }
    }
    return $false
}

# 注销接口没在门户前端包里暴露出来，所以逐个试候选地址，每试一个就复查是否真的掉线，
# 只有确认真掉了才走重登——避免“没注销成却把密码验了个寂寞”。
function Invoke-Relogin {
    if (-not $Cfg.Username -or -not $Cfg.Password) {
        Write-Log "未配置账号密码：请先编辑 $ConfigPath。"
        return $false
    }
    $before = Get-NetworkState
    $ip = if ($before.State -eq 'online') { Get-ClientIp } else { Get-ClientIp -Fast }
    Write-Log "注销前：$($before.State)（$($before.Detail)），认证 IP $ip。"
    if ($before.State -notin 'online', 'portal') {
        Write-Log '注销前就判不清网络状态，先不动你的连接，免得把探测失败当成掉线乱试一通。'
        return $false
    }

    $dropped = ($before.State -eq 'portal')
    if (-not $dropped) {
        foreach ($base in (Get-PortalBaseList $before.Portal)) {
            foreach ($path in $Cfg.LogoutUrlList) {
                $q = @{ user_account = $Cfg.Username; user_password = $Cfg.Password; wlan_user_ip = $ip;
                        wlan_user_mac = '000000000000'; lang = 'zh-cn' }
                $sep = if ($path.Contains('?')) { '&' } else { '?' }
                $r = Invoke-Http ($base.TrimEnd('/') + $path + $sep + (Build-Query $q)) -AllowRedirect
                Write-Log ("试注销 {0}{1} → HTTP {2}：{3}" -f $base, $path, $r.Status, (Clear-Brief $(if ($r.Body) { $r.Body } else { $r.Error })))
                Start-Sleep -Seconds 3
                $st = Get-NetworkState
                # 只有真的被重定向到认证页才算掉线；探测本身失败不算。
                if ($st.State -eq 'portal') {
                    Write-Log "确实掉线了（$($st.Detail)），马上重登。"
                    $dropped = $true
                    break
                }
                if ($st.State -ne 'online') { Write-Log "复查状态是 $($st.State)（$($st.Detail)），不算确认掉线，继续试下一个注销地址。" }
            }
            if ($dropped) { break }
        }
    } else {
        Write-Log '本来就在认证页，直接登录即可。'
    }
    if (-not $dropped) {
        Write-Log '所有候选注销地址都没能把你踢下线，密码这条没法当场验证。可能是无感知认证（MAC 绑定）不理会注销请求，也可能是学校没开放注销接口。网络未受影响。'
        return $false
    }
    if (Invoke-Check -ForceLogin) {
        Start-Sleep -Seconds 3
        $after = Get-NetworkState
        if ($after.State -eq 'online') {
            Write-Log "重登成功且网络恢复（$($after.Detail)）—— 账号密码确认无误。"
            Set-State -Fails 0 -Reason ''
            return $true
        }
        Write-Log "门户说登录成功，但复查还是 $($after.State)，再等一轮常驻任务。"
    }
    Write-Log '重登失败：请核对 config.ini 里的 Username / Password。常驻任务会每 2 分钟继续重试，你也可以手动开浏览器登录，别一直等着。'
    return $false
}
function Set-ConfigValue {
    param([string[]]$Lines, [string]$Key, [string]$Value)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            $Lines[$i] = ('{0} = {1}' -f $Key, $Value)
            return $Lines
        }
    }
    return @($Lines + ('{0} = {1}' -f $Key, $Value))
}

function Protect-ConfigFile {
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        & icacls $ConfigPath /inheritance:r /grant "*${sid}:F" | Out-Null
        Write-Host "已把 config.ini 的访问权限收紧为仅当前 Windows 账号可读。"
    } catch { Write-Host "设置 config.ini 权限失败：$($_.Exception.Message)" }
}

function Install-Task {
    param([int]$Interval)
    $span = New-TimeSpan -Minutes $Interval
    # 无人值守：S4U 登录类型不需要存你的 Windows 密码，也不要求有人登录到桌面。
    # 开机只留一个触发器：实测有线网卡在登录界面阶段就拿到了 DHCP，开机 18 秒即可判出网络状态；
    # 原先叠的 30/90 秒延迟触发会在开机瞬间同时挤出一堆进程（表现为弹一堆窗口），且并无收益。
    $bootTrigger = New-ScheduledTaskTrigger -AtStartup
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval $span -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
    # 启动方式：wscript + launcher.vbs（用绝对路径调 powershell，出错才落 launcher-error.log）。
    # wscript 是 GUI 子系统、不分配控制台，所以不会有控制台宿主窗口闪一下；
    # 直接用 powershell.exe 当动作时，即使加 -WindowStyle Hidden，Windows 终端仍会替它开一个约 1 秒的窗口。
    $vbs = Join-Path $Root 'launcher.vbs'
    if (-not (Test-Path -LiteralPath $vbs)) { throw "缺少启动器 $vbs" }
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" `
        -Argument ('"{0}" check' -f $vbs) -WorkingDirectory $Root
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($bootTrigger, $logonTrigger, $repeatTrigger) `
        -Settings $settings -Principal $principal `
        -Description '中国海洋大学校园网自动检测与认证：掉线后自动重新登录（无人值守）' -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "计划任务 [$TaskName] 已安装：开机触发一次（停在登录界面也跑）、登录时接上、平时每 $Interval 分钟检测。"
}

function Invoke-Setup {
    if (-not $Username) {
        if (-not [Environment]::UserInteractive) { throw '请用 -Username / -Password 传入账号密码。' }
        $Username = Read-Host '校园网账号（学号/工号）'
    }
    if (-not $Password) {
        if (-not [Environment]::UserInteractive) { throw '请用 -Password 传入校园网密码。' }
        $sec = Read-Host '校园网密码（输入不显示）' -AsSecureString
        $Password = (New-Object Net.NetworkCredential '', $sec).Password
    }
    if (-not $Username -or -not $Password) { throw '账号和密码不能为空。' }

    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "配置文件 $ConfigPath 不存在，请把脚本目录恢复原样后再运行 setup。" }
    $lines = Set-ConfigValue -Lines @(Get-Content -LiteralPath $ConfigPath -Encoding UTF8) -Key 'Username' -Value $Username
    $lines = Set-ConfigValue -Lines $lines -Key 'Password' -Value $Password
    if ($PortalBase) { $lines = Set-ConfigValue -Lines $lines -Key 'PortalBase' -Value $PortalBase }
    $tmp = "$ConfigPath.tmp"
    Set-Content -LiteralPath $tmp -Value $lines -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
    Protect-ConfigFile

    $iv = $IntervalMinutes
    if ($iv -lt 1) { $c = Read-Config; $iv = [int]$c.IntervalMinutes }
    Install-Task -Interval $iv
    Write-Host ''
    Write-Host '接下来跑一次验证（已联网时它只会回报“已经在线”，不会把你踢下线）：'
    Write-Host ("  powershell -NoProfile -ExecutionPolicy Bypass -File `"{0}`" test-login" -f (Join-Path $Root 'ouc-autologin.ps1'))
}

function Show-Status {
    $c = Read-Config
    Write-Host "账号        : $(if ($c.Username) { $c.Username } else { '(未填写)' })"
    Write-Host "密码        : $(if ($c.Password) { '已填写（长度 ' + $c.Password.Length + '）' } else { '(未填写)' })"
    Write-Host "门户设置    : $($c.PortalBase)  候选: $($c.PortalCandidates)"
    Write-Host "检测间隔    : $($c.IntervalMinutes) 分钟    超时: $($c.TimeoutSeconds) 秒"
    Write-Host "日志目录    : $LogDir"
    $st = Get-State
    if ([int]$st.Fails -gt 0) { Write-Host "连续认证失败 : $($st.Fails) 次，最后一次 $($st.LastFail)（$($st.Reason)）" }
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $i = $t | Get-ScheduledTaskInfo
        Write-Host "计划任务      : $($t.State)  上次运行 $($i.LastRunTime)  结果 $($i.LastTaskResult)  下次运行 $($i.NextRunTime)"
    } catch { Write-Host '计划任务      : 未安装（运行 setup 安装）' }
    Write-Host ''
    Write-Host '当前网络判定：'
    $s = Get-NetworkState
    Write-Host ("  {0} — {1}" -f $s.State, $s.Detail)
    Write-Host ("  认证系统看到的本机 IP：{0}" -f (Get-ClientIp))
    Write-Host ''
    Show-WifiInfo
    if ($Tail -gt 0) {
        Write-Host ''
        Write-Host "最近日志："
        Show-Logs -Count $Tail
    }
}

function Show-Logs {
    param([int]$Count = 20)
    $files = @(Get-ChildItem -LiteralPath $LogDir -File -Filter 'log-*.txt' -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $files) { Write-Host '  (还没有日志)'; return }
    Get-Content -LiteralPath $files[-1].FullName -Encoding UTF8 | Select-Object -Last $Count | ForEach-Object { Write-Host "  $_" }
}

function Enter-Lock {
    try {
        $created = $false
        $m = New-Object Threading.Mutex($false, 'Local\OUC-AutoLogin', [ref]$created)
        if (-not $created) {
            $m.Dispose()
            if (-not $Quiet) { Write-Host '已有另一个检测在跑，本次跳过。' }
            return $false
        }
        $script:Mutex = $m
        return $m.WaitOne([TimeSpan]::FromSeconds(30))
    } catch {
        # 命名互斥量在某些受限会话里建不出来，不该因此就不去登录。
        return $true
    }
}

try {
    try {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    } catch {
        $LogDir = Join-Path $Root 'logs'
        $StateFile = Join-Path $Root 'logs\state.json'
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    $Cfg = Read-Config

    switch ($Command.ToLowerInvariant()) {
        { $_ -in 'check', 'once' } {
            if (-not (Enter-Lock)) { exit 0 }
            if (Invoke-Check) { exit 0 } else { exit 1 }
        }
        'test-login' { if (Invoke-Check -ForceLogin) { exit 0 } else { exit 1 } }
        'relogin' { if (Invoke-Relogin) { exit 0 } else { exit 1 } }
        'setup' { Invoke-Setup; exit 0 }
        'install' {
            $iv = if ($IntervalMinutes -gt 0) { $IntervalMinutes } else { [int]$Cfg.IntervalMinutes }
            Install-Task -Interval $iv
            exit 0
        }
        'uninstall' {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "已删除计划任务 [$TaskName]（脚本、配置和日志保留，需要的话自行删除）。"
            exit 0
        }
        'status' { Show-Status; exit 0 }
        { $_ -in 'wifi', 'wifi-status' } { Show-WifiInfo; exit 0 }
        'wifi-connect' { if (Connect-WifiPath -Force) { exit 0 } else { exit 1 } }
        'logs' { Show-Logs -Count $Tail; exit 0 }
        default {
            Write-Host @"
用法: powershell -NoProfile -ExecutionPolicy Bypass -File .\ouc-autologin.ps1 <命令>

  setup        填账号密码 + 安装常驻计划任务（一步到位）
  check        检测一次，掉线就自动认证（计划任务用的就是这个）
  test-login   强制走一次认证，用来验证账号密码和门户地址是否正确
  relogin      先注销再重登，把密码验到底（会断网 5～10 秒）
  status       看配置、计划任务状态、当前网络判定和最近日志
  wifi         只看有线/无线链路、无线配置和当前出口（不改动任何东西）
  wifi-connect 立刻尝试连接无线 OUC-AUTO，用来验证“有线不通切无线”这条路
  logs         看日志，可加 -Tail 50
  install      只装/改计划任务，可加 -IntervalMinutes 5
  uninstall    删除计划任务
"@
            exit 2
        }
    }
} catch {
    try { Write-Log "出错：$($_.Exception.Message)" } catch { Write-Host "出错：$($_.Exception.Message)" }
    exit 1
} finally {
    if ($script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        $script:Mutex.Dispose()
    }
}
