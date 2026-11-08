#requires -Version 5.1
<#
.SYNOPSIS
    在 Windows 上对 com.dsh.runner 做一次完整的真机验证：
    卸载旧包 -> push + pm install -> 启动 -> 等待服务就绪 -> 从 PC 端验证 HTTP 303。

.DESCRIPTION
    流程与对应的 PHASE：
      install : 卸载旧包（失败忽略）-> adb push 到 /data/local/tmp -> pm install -r -g
      start   : adb logcat -c -> am start -n com.dsh.runner/.MainActivity
      wait    : 每 PollSec 秒检查 files/server.url / logcat(DshRunner) / files/logs/server.log，最多 TimeoutMin 分钟
      ok      : 出现 http URL -> adb forward tcp:16137 tcp:61374 -> GET /?token=... 期望 303
      fail    : 打印 3 条最可能原因 + 可复制的诊断命令，并写 scripts\verify-last.json

    说明：dsh web 服务对 GET /（无 token）返回 401，对 GET /?token=<server.url 里的 token> 返回 303 + Location "./"。
    所以“服务活着”的判定是 303（200 也算活着，401 表示 token 不匹配）。

.PARAMETER TimeoutMin
    等待 server.url 出现的最长分钟数，默认 15。首装（解包 Termux 运行时 + 安装 dsh）可能 5-10 分钟。

.PARAMETER KeepAppData
    跳过卸载，用 -r 覆盖安装并复用已解包的私有目录。反复验证时快很多。

.PARAMETER DryRun
    只做只读检查（adb / 设备 / APK），打印将要执行的命令，不安装不启动。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\verify-apk.ps1

.EXAMPLE
    pwsh -NoProfile -File .\verify-apk.ps1 -TimeoutMin 30 -KeepAppData

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\verify-apk.ps1 -DryRun

.NOTES
    退出码：0 成功 / 1 验证失败 / 2 前置条件不满足（adb、设备、APK）。
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 240)][int]$TimeoutMin = 15,
    [string]$ApkPath = 'E:\dsh-android\app\app\build\outputs\apk\debug\app-debug.apk',
    [string]$Serial = 'b82a026f',
    [string]$Adb = 'C:\Program Files\ASUS\GlideX\adb.exe',
    [string]$Package = 'com.dsh.runner',
    [string]$Activity = 'com.dsh.runner/.MainActivity',
    [int]$DevicePort = 61374,
    [int]$LocalPort = 16137,
    [ValidateRange(5, 300)][int]$PollSec = 20,
    [string]$LogTag = 'DshRunner',
    [switch]$KeepAppData,
    [switch]$DryRun,
    [string]$ResultJson = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- 运行状态
$script:AdbBin = $Adb
$script:SerialNo = $Serial
$script:Pkg = $Package
$script:LogTag = $LogTag
$script:StartedAt = Get-Date
$script:Timeline = New-Object System.Collections.Generic.List[string]
$script:KeyLines = New-Object System.Collections.Generic.List[string]
$script:Reasons = @()
$script:DeviceUrl = ''
$script:AppPid = 0

if (-not $ResultJson) { $ResultJson = Join-Path $PSScriptRoot 'verify-last.json' }

$script:Report = [ordered]@{
    tool = 'verify-apk.ps1'
    startedAt = $script:StartedAt.ToString('o')
    endedAt = ''
    elapsedSec = 0
    phase = 'init'
    ok = $false
    timeoutMin = $TimeoutMin
    apk = [ordered]@{ path = $ApkPath; exists = $false; sizeMB = 0; lastWrite = '' }
    install = [ordered]@{ skipped = $false; pushOk = $false; output = ''; seconds = 0 }
    start = [ordered]@{ command = ''; output = ''; ok = $false }
    wait = [ordered]@{ attempts = 0; urlSeen = $false; appPid = 0 }
    server = [ordered]@{ deviceUrl = ''; tokenLength = 0; port = $DevicePort }
    http = [ordered]@{ status = 0; location = ''; engine = ''; bareStatus = 0 }
    keyLogLines = @()
    reasons = @()
    diagnostics = @()
    timeline = @()
}

# ---------------------------------------------------------------- 输出工具
function Write-Phase {
    param([string]$Phase, [string]$Detail = '')
    $ts = (Get-Date).ToString('HH:mm:ss')
    if ($Detail) { $line = ('[{0}] PHASE={1}  {2}' -f $ts, $Phase, $Detail) }
    else { $line = ('[{0}] PHASE={1}' -f $ts, $Phase) }
    Write-Host $line -ForegroundColor Cyan
    [void]$script:Timeline.Add($line)
    $script:Report.phase = $Phase
}

function Write-Note {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host ('        ' + $Text) -ForegroundColor $Color
}

function Add-KeyLine {
    param([string]$Line)
    if (-not $Line) { return }
    $t = ($Line -replace '\s+', ' ').Trim()
    if ($t.Length -eq 0) { return }
    if ($t.Length -gt 200) { $t = $t.Substring(0, 200) + '...' }
    if (-not $script:KeyLines.Contains($t)) { [void]$script:KeyLines.Add($t) }
}

function Hide-Token {
    param([string]$Url)
    if (-not $Url) { return '' }
    return [regex]::Replace($Url, '(token=)([^&\s]+)', '$1***')
}

# ---------------------------------------------------------------- adb 封装
function Invoke-Adb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$NoSerial,
        [switch]$AllowFailure
    )

    $argv = New-Object System.Collections.Generic.List[string]
    if (-not $NoSerial) {
        [void]$argv.Add('-s')
        [void]$argv.Add($script:SerialNo)
    }
    foreach ($a in $Arguments) { [void]$argv.Add([string]$a) }

    $shown = $argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $cmdText = 'adb ' + ($shown -join ' ')

    $out = @()
    $code = 0
    try {
        $out = & $script:AdbBin @argv 2>&1 | ForEach-Object { [string]$_ }
        if ($null -eq $LASTEXITCODE) { $code = 0 } else { $code = [int]$LASTEXITCODE }
    } catch {
        $out = @([string]$_.Exception.Message)
        $code = -1
    }

    $text = ($out -join [Environment]::NewLine).Trim()
    $ok = ($code -eq 0)
    if (-not $ok -and -not $AllowFailure) {
        Write-Host ('        ! adb 失败: ' + $cmdText) -ForegroundColor Red
        if ($text) {
            $first3 = $text -split '\r?\n' | Select-Object -First 3
            Write-Host ('          ' + ($first3 -join ' | ')) -ForegroundColor DarkRed
        }
    }
    return [pscustomobject]@{ Command = $cmdText; ExitCode = $code; Lines = @($out); Text = $text; Ok = $ok }
}

function Test-AdbAvailable {
    if (-not (Test-Path -LiteralPath $script:AdbBin)) { return $false }
    return $true
}

function Get-DeviceList {
    return Invoke-Adb -Arguments @('devices', '-l') -NoSerial -AllowFailure
}

function Test-DeviceOnline {
    $r = Get-DeviceList
    $pattern = '^\s*' + [regex]::Escape($script:SerialNo) + '\s+device\b'
    foreach ($line in ($r.Text -split '\r?\n')) {
        if ($line -match $pattern) { return $true }
    }
    return $false
}

function Get-DeviceState {
    $r = Get-DeviceList
    foreach ($line in ($r.Text -split '\r?\n')) {
        if ($line -match ('^\s*' + [regex]::Escape($script:SerialNo) + '\s+(\S+)')) { return $Matches[1] }
    }
    return 'absent'
}

function Get-AppLogTail {
    param([int]$Lines = 40)
    $r = Invoke-Adb -Arguments @('shell', 'run-as', $script:Pkg, 'tail', '-n', [string]$Lines, 'files/logs/server.log') -AllowFailure
    if ($r.Text -match 'No such file|Permission denied|run-as:|inaccessible') { return '' }
    if ($r.Text) { return $r.Text }

    $c = Invoke-Adb -Arguments @('shell', 'run-as', $script:Pkg, 'cat', 'files/logs/server.log') -AllowFailure
    if ($c.Text -match 'No such file|Permission denied|run-as:|inaccessible') { return '' }
    if (-not $c.Text) { return '' }
    $all = $c.Text -split '\r?\n'
    return (($all | Select-Object -Last $Lines) -join [Environment]::NewLine)
}

function Get-LogcatTail {
    param([int]$Lines = 60)
    $r = Invoke-Adb -Arguments @('logcat', '-d', '-t', [string]$Lines, '-s', ($script:LogTag + ':V')) -AllowFailure
    return $r.Text
}

function Get-CrashLines {
    $r = Invoke-Adb -Arguments @('logcat', '-d', '-t', '300') -AllowFailure
    if (-not $r.Text) { return '' }
    $pkgPattern = [regex]::Escape($script:Pkg)
    $hits = $r.Text -split '\r?\n' | Where-Object {
        $_ -match ('FATAL EXCEPTION|Process: ' + $pkgPattern + '|ANR in ' + $pkgPattern + '|Force finishing activity')
    }
    return ($hits -join [Environment]::NewLine)
}

function Get-DeviceUrl {
    $r = Invoke-Adb -Arguments @('shell', 'run-as', $script:Pkg, 'cat', 'files/server.url') -AllowFailure
    if (-not $r.Text) { return $null }
    $hit = $r.Text -split '\r?\n' | Where-Object { $_ -match '^\s*http://' } | Select-Object -First 1
    if (-not $hit) { return $null }
    return $hit.Trim()
}

function Get-AppPid {
    $r = Invoke-Adb -Arguments @('shell', 'pidof', $script:Pkg) -AllowFailure
    if ($r.Text -match '^\s*(\d+)') { return [int]$Matches[1] }
    return 0
}

# ---------------------------------------------------------------- HTTP 探测
function Invoke-WebProbe {
    # 优先 Invoke-WebRequest；PS 7 对 3xx + -MaximumRedirection 0 会抛 InvalidOperationException，
    # 这种情况下再用 HttpWebRequest（同样不跟随重定向）拿真实状态码，最后兜底 curl。
    param([string]$Url, [int]$TimeoutSec = 10)

    $result = [pscustomobject]@{ Status = 0; Location = ''; Engine = 'none'; Error = '' }

    try {
        $iwr = @{
            Uri = $Url
            TimeoutSec = $TimeoutSec
            MaximumRedirection = 0
            UseBasicParsing = $true
            ErrorAction = 'Stop'
        }
        if ($PSVersionTable.PSVersion.Major -ge 7) { $iwr['SkipHttpErrorCheck'] = $true }
        $resp = Invoke-WebRequest @iwr
        $result.Status = [int]$resp.StatusCode
        $result.Location = [string]$resp.Headers['Location']
        $result.Engine = 'Invoke-WebRequest'
        return $result
    } catch {
        $ex = $_.Exception
        if ($null -ne $ex.Response -and $null -ne $ex.Response.StatusCode) {
            $result.Status = [int]$ex.Response.StatusCode
            try { $result.Location = [string]$ex.Response.Headers['Location'] } catch { }
            $result.Engine = 'Invoke-WebRequest(throw)'
            if ($result.Status -gt 0) { return $result }
        }
        $result.Error = $ex.Message
    }

    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.AllowAutoRedirect = $false
        $req.Timeout = $TimeoutSec * 1000
        $req.Proxy = $null
        $req.KeepAlive = $false
        $resp2 = $req.GetResponse()
        $result.Status = [int]$resp2.StatusCode
        $result.Location = [string]$resp2.Headers['Location']
        $result.Engine = 'HttpWebRequest'
        $resp2.Close()
        return $result
    } catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            $hr = $_.Exception.Response
            $result.Status = [int]$hr.StatusCode
            try { $result.Location = [string]$hr.Headers['Location'] } catch { }
            $result.Engine = 'HttpWebRequest(throw)'
            $hr.Close()
            return $result
        }
        $result.Error = $_.Exception.Message
    } catch {
        $result.Error = $_.Exception.Message
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -ne $curl) {
        try {
            $raw = & $curl.Source '-s' '-o' 'NUL' '-w' '%{http_code}|%{redirect_url}' '--max-time' ([string]$TimeoutSec) '--max-redirs' '0' $Url
            $joined = ($raw -join '').Trim()
            $parts = $joined -split '\|'
            if ($parts.Count -ge 1 -and $parts[0] -match '^\d{3}$') {
                $result.Status = [int]$parts[0]
                if ($parts.Count -ge 2) { $result.Location = $parts[1] }
                $result.Engine = 'curl'
                return $result
            }
        } catch { }
    }

    $result.Engine = 'none'
    return $result
}

# ---------------------------------------------------------------- 安装 / 启动
function Install-Apk {
    param([string]$Path)

    $info = Get-Item -LiteralPath $Path
    $remote = '/data/local/tmp/' + $info.Name
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $sizeMB = [math]::Round($info.Length / 1MB, 1)
    Write-Phase 'install' ('push ' + $remote + ' (' + $sizeMB + ' MB)')
    $push = Invoke-Adb -Arguments @('push', $info.FullName, $remote) -AllowFailure
    $script:Report.install.pushOk = $push.Ok
    if (-not $push.Ok) {
        $sw.Stop()
        return [pscustomobject]@{ Ok = $false; Output = $push.Text; Seconds = [int]$sw.Elapsed.TotalSeconds }
    }

    Write-Note ('pm install -r -g ' + $remote)
    $pm = Invoke-Adb -Arguments @('shell', 'pm', 'install', '-r', '-g', $remote) -AllowFailure
    if ($pm.Text -notmatch 'Success' -and $pm.Text -match 'TEST_ONLY') {
        Write-Note 'APK 带 testOnly 标记，追加 -t 重试'
        $pm = Invoke-Adb -Arguments @('shell', 'pm', 'install', '-r', '-g', '-t', $remote) -AllowFailure
    }

    $sw.Stop()
    return [pscustomobject]@{
        Ok = ($pm.Text -match 'Success')
        Output = $pm.Text
        Seconds = [int]$sw.Elapsed.TotalSeconds
    }
}

function Get-InstallReasons {
    param([string]$Output)
    $r = New-Object System.Collections.Generic.List[string]
    if ($Output -match 'INSUFFICIENT_STORAGE') {
        $r.Add('存储不足：pm install 被拒。先 adb shell df -h /data 看剩余空间，清理后重跑。')
    }
    if ($Output -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match') {
        $r.Add('签名冲突：旧包没卸干净。先 adb uninstall com.dsh.runner 再装，或去掉 -KeepAppData。')
    }
    if ($Output -match 'INSTALL_FAILED_NO_MATCHING_ABIS') {
        $r.Add('ABI 不匹配：APK 里没有 arm64-v8a 的 so。检查 app/build.gradle 的 abiFilters。')
    }
    if ($Output -match 'INSTALL_PARSE_FAILED|INSTALL_FAILED_INVALID_APK') {
        $r.Add('APK 损坏或未签名：重新 assembleDebug，确认是 debug 签名产物。')
    }
    if ($Output -match 'Unable to open|No such file|failed to read') {
        $r.Add('push 未落地或不可读：确认 /data/local/tmp 可写，重新 push 后再 pm install。')
    }
    return @($r)
}

function Setup-Forward {
    Invoke-Adb -Arguments @('forward', '--remove', ('tcp:' + $LocalPort)) -AllowFailure | Out-Null
    $f = Invoke-Adb -Arguments @('forward', ('tcp:' + $LocalPort), ('tcp:' + $DevicePort)) -AllowFailure
    if (-not $f.Ok) {
        Write-Note ('adb forward 失败: ' + ($f.Text -replace '\r?\n', ' ')) 'Red'
    }
    return $f.Ok
}

function Build-PcUrl {
    param([string]$DeviceUrl)
    if (-not $DeviceUrl) { return '' }
    $u = $null
    try { $u = [uri]$DeviceUrl } catch { return '' }
    return ('http://127.0.0.1:' + $LocalPort + $u.PathAndQuery)
}

# ---------------------------------------------------------------- 失败归因
function Get-FailureReasons {
    param(
        [string]$AppLog,
        [string]$CatLog,
        [int]$AppPid,
        [bool]$UrlSeen,
        [int]$HttpStatus
    )

    $pool = New-Object System.Collections.Generic.List[string]
    $pkgPattern = [regex]::Escape($script:Pkg)

    if ($CatLog -match ('FATAL EXCEPTION|Process: ' + $pkgPattern + '|ANR in ' + $pkgPattern)) {
        $pool.Add('应用崩溃：Bootstrap 解包 / 符号链接 / native so 架构不匹配。看 logcat -b crash 的第一段 Java 堆栈；出现 UnsatisfiedLinkError 就是 arm64 库混了 x86_64。')
    }
    if ($AppLog -match 'node 退出 code=[1-9]') {
        $pool.Add('node 起来后立刻退出：dsh 入口或参数有问题（usr/lib/node_modules/@deepseek-ai/dsh/lib/bin.js、--profile web、--port）。看 server.log 里 node 退出前最后 30 行。')
    }
    if ($AppLog -match 'ENOTFOUND|EAI_AGAIN|ECONNREFUSED|ETIMEDOUT|npm ERR!|registry|CERT_|self.signed|SELF_SIGNED') {
        $pool.Add('首装网络失败：npm 拉依赖时 DNS / 代理 / 证书不通。确认手机能到 registry，必要时在 files/home/.npmrc 写代理后再启服务。')
    }
    if ($AppLog -match '解包 bootstrap|安装运行时|安装 dsh|unzip|copyAssetTree') {
        $pool.Add('首装还没跑完：解包 Termux 运行时 + 安装 dsh 在真机上要 5-10 分钟。用 -TimeoutMin 30 重跑；反复验证时加 -KeepAppData 复用已解包目录。')
    }
    if (-not $UrlSeen) {
        $pool.Add('服务没写出 server.url：node 可能起来了但没监听 127.0.0.1:61374，或 token 行没被 ServerService 解析到。去 server.log 里找 http 行。')
    }
    if ($HttpStatus -eq 401) {
        $pool.Add('token 校验失败：server.url 里的 token 与进程实际 token 不一致（旧文件没删干净或读到半写内容）。不带 -KeepAppData 重装一次再取。')
    }
    if ($AppPid -le 0) {
        $pool.Add('应用进程不存在：am start 没真正拉起（Activity 名错 / 电池优化杀进程 / 后台限制）。确认 am start 输出里没有 Error type 3。')
    }

    $generic = @(
        '存储或安装问题：adb shell df -h /data 看剩余空间，再重跑 install 阶段。',
        '运行时不完整：adb shell run-as com.dsh.runner ls -l files/usr/bin 里应能看到 bash 与 node。',
        '服务活着但 WebView 白屏属前端问题：forward 后在 PC 打开同一 URL 对照，能出页面就不是后端问题。'
    )
    foreach ($g in $generic) {
        if ($pool.Count -lt 3) { $pool.Add($g) }
    }
    return @($pool | Select-Object -First 3)
}

function Get-DiagnosticCommands {
    $a = $script:AdbBin
    $s = $script:SerialNo
    $p = $script:Pkg
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('& "{0}" -s {1} devices -l' -f $a, $s))
    $lines.Add(('& "{0}" -s {1} logcat -d -s {2}:V' -f $a, $s, $script:LogTag))
    $lines.Add(('& "{0}" -s {1} logcat -d -b crash' -f $a, $s))
    $lines.Add(('& "{0}" -s {1} shell run-as {2} tail -n 80 files/logs/server.log' -f $a, $s, $p))
    $lines.Add(('& "{0}" -s {1} shell run-as {2} cat files/server.url' -f $a, $s, $p))
    $lines.Add(('& "{0}" -s {1} shell run-as {2} ls -l files/usr/bin' -f $a, $s, $p))
    $lines.Add(('& "{0}" -s {1} shell pidof {2}' -f $a, $s, $p))
    $lines.Add(('& "{0}" -s {1} shell dumpsys activity services {2}' -f $a, $s, $p))
    $lines.Add(('& "{0}" -s {1} shell df -h /data' -f $a, $s))
    $lines.Add(('powershell -NoProfile -ExecutionPolicy Bypass -File .\shot.ps1 -Serial ' + $s))
    return $lines.ToArray()
}

# ---------------------------------------------------------------- 结果输出
function Show-Report {
    param([string]$Phase, [int]$ExitCode)

    $ended = Get-Date
    $script:Report.endedAt = $ended.ToString('o')
    $script:Report.elapsedSec = [int]($ended - $script:StartedAt).TotalSeconds
    $script:Report.phase = $Phase
    $script:Report.ok = ($ExitCode -eq 0)
    $script:Report.reasons = @($script:Reasons)
    $script:Report.keyLogLines = @($script:KeyLines)
    $script:Report.timeline = @($script:Timeline)
    $script:Report.diagnostics = @(Get-DiagnosticCommands)
    if ($script:DeviceUrl) {
        $script:Report.server.deviceUrl = Hide-Token $script:DeviceUrl
        if ($script:DeviceUrl -match 'token=([^&\s]+)') { $script:Report.server.tokenLength = $Matches[1].Length }
    }

    $elapsed = $ended - $script:StartedAt
    Write-Host ''
    Write-Host '========== RESULT ==========' -ForegroundColor White
    if ($ExitCode -eq 0) {
        Write-Host ('PHASE        : ' + $Phase) -ForegroundColor Green
    } else {
        Write-Host ('PHASE        : ' + $Phase) -ForegroundColor Red
    }
    Write-Host ('APK          : ' + $script:Report.apk.path + '  (' + $script:Report.apk.sizeMB + ' MB, ' + $script:Report.apk.lastWrite + ')')
    if ($script:Report.install.output) { Write-Host ('INSTALL      : ' + $script:Report.install.output) -ForegroundColor DarkGray }
    if ($script:Report.start.command) { Write-Host ('START        : ok=' + $script:Report.start.ok + '  ' + $script:Report.start.command) }
    if ($script:Report.wait.attempts -gt 0) {
        Write-Host ('WAIT         : ' + $script:Report.wait.attempts + ' 轮询 / ' + [int]$elapsed.TotalSeconds + 's（上限 ' + $TimeoutMin + ' 分钟）')
    }
    if ($script:Report.wait.appPid -gt 0) { Write-Host ('APP PID      : ' + $script:Report.wait.appPid) }
    if ($script:DeviceUrl) { Write-Host ('SERVER URL   : ' + (Hide-Token $script:DeviceUrl)) }
    if ($script:Report.http.status -gt 0) {
        Write-Host ('HTTP         : ' + $script:Report.http.status + '  GET /?token=...  (engine=' + $script:Report.http.engine + ', location=' + $script:Report.http.location + ')')
        Write-Host ('HTTP(bare)   : ' + $script:Report.http.bareStatus + '  GET /  （401 属正常，表示需要 token）')
    }
    if ($Phase -eq 'ok') {
        Write-Host ('FORWARD      : tcp:' + $LocalPort + ' -> device tcp:' + $DevicePort + '（保持开启，可直接在 PC 浏览器打开）')
    }
    if ($Phase -eq 'dryrun') { Write-Host 'NOTE         : DRY-RUN 未安装、未启动、未请求设备' -ForegroundColor Yellow }
    Write-Host ('ELAPSED      : ' + $elapsed.ToString('hh\:mm\:ss'))

    if ($script:KeyLines.Count -gt 0) {
        Write-Host ''
        Write-Host '--- 关键日志（最近若干条） ---' -ForegroundColor Yellow
        foreach ($l in ($script:KeyLines | Select-Object -Last 12)) { Write-Host ('  ' + $l) -ForegroundColor DarkGray }
    }

    if ($ExitCode -ne 0 -and $script:Reasons.Count -gt 0) {
        Write-Host ''
        Write-Host '--- 最可能的 3 个原因 ---' -ForegroundColor Yellow
        $i = 0
        foreach ($why in $script:Reasons) {
            $i++
            Write-Host ('  ' + $i + ') ' + $why) -ForegroundColor DarkYellow
        }
        Write-Host ''
        Write-Host '--- 可直接复制的诊断命令 ---' -ForegroundColor Yellow
        foreach ($d in (Get-DiagnosticCommands)) { Write-Host ('  ' + $d) -ForegroundColor DarkGray }
    }

    try {
        $json = $script:Report | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($ResultJson, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ''
        Write-Host ('结果 JSON    : ' + $ResultJson)
    } catch {
        Write-Host ('结果 JSON 写入失败: ' + $_.Exception.Message) -ForegroundColor DarkRed
    }

    exit $ExitCode
}

function Fail-Run {
    param(
        [string]$Why,
        [string[]]$Reasons = @(),
        [int]$Code = 1
    )
    Write-Host ''
    Write-Host ('FAIL: ' + $Why) -ForegroundColor Red
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Reasons) { if ($r) { $list.Add($r) } }
    $fill = @(
        '存储或安装问题：adb shell df -h /data 看剩余空间，再重跑 install 阶段。',
        '运行时不完整：adb shell run-as com.dsh.runner ls -l files/usr/bin 里应能看到 bash 与 node。',
        '服务没监听：确认 node 参数 --host 127.0.0.1 --port 61374 没被覆盖。'
    )
    foreach ($f in $fill) { if ($list.Count -lt 3) { $list.Add($f) } }
    $script:Reasons = @($list | Select-Object -First 3)
    Show-Report 'fail' $Code
}

# ---------------------------------------------------------------- 主流程
Write-Host ''
Write-Host '===== DSH Android 真机验证 =====' -ForegroundColor White
Write-Host ('adb      : ' + $script:AdbBin)
Write-Host ('serial   : ' + $script:SerialNo)
Write-Host ('apk      : ' + $ApkPath)
Write-Host ('package  : ' + $Package + '   activity: ' + $Activity)
Write-Host ('wait     : 最多 ' + $TimeoutMin + ' min，每 ' + $PollSec + 's 轮询')
Write-Host ('forward  : tcp:' + $LocalPort + ' -> tcp:' + $DevicePort)
if ($DryRun) { Write-Host 'mode     : DRY-RUN（不安装、不启动）' -ForegroundColor Yellow }

# --- 前置检查
if (-not (Test-AdbAvailable)) {
    Fail-Run ('找不到 adb：' + $script:AdbBin) @(
        'adb 路径不对：用 -Adb 指向实际 adb.exe（本机默认在 C:\Program Files\ASUS\GlideX\adb.exe）。',
        'adb 被安全软件拦截或文件被移走：重新确认路径后重跑。',
        '想用别处的 adb：改成 -Adb "C:\android-sdk\platform-tools\adb.exe"。'
    ) 2
}

$ver = Invoke-Adb -Arguments @('version') -NoSerial -AllowFailure
if ($ver.Lines.Count -gt 0) { Write-Note ('adb: ' + ($ver.Lines[0])) }

$dev = Get-DeviceList
Write-Note ('设备列表: ' + (($dev.Text -split '\r?\n' | Select-Object -Skip 1 | Where-Object { $_.Trim() }) -join ' ; '))

$apkName = Split-Path -Leaf $ApkPath
$apkItem = $null
if (Test-Path -LiteralPath $ApkPath) {
    $apkItem = Get-Item -LiteralPath $ApkPath
    $script:Report.apk.exists = $true
    $script:Report.apk.sizeMB = [math]::Round($apkItem.Length / 1MB, 1)
    $script:Report.apk.lastWrite = $apkItem.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    Write-Note ('APK: ' + $script:Report.apk.sizeMB + ' MB, 构建于 ' + $script:Report.apk.lastWrite)
    $ageMin = [int]((Get-Date) - $apkItem.LastWriteTime).TotalMinutes
    if ($ageMin -gt 30) { Write-Note ('APK 已 ' + $ageMin + ' 分钟未更新，确认不是旧产物') 'Yellow' }
} elseif ($DryRun) {
    Write-Note ('APK 不存在：' + $ApkPath + '，DRY-RUN 只预览命令') 'Yellow'
} else {
    Fail-Run ('APK 不存在：' + $ApkPath) @(
        '还没构建：在 E:\dsh-android\app 下跑 gradlew assembleDebug。',
        '路径不对：确认是 app\app\build\outputs\apk\debug\app-debug.apk。',
        '构建产物被清掉：重新 assemble 再跑本脚本。'
    ) 2
}

if (-not (Test-DeviceOnline)) {
    $state = Get-DeviceState
    if ($DryRun) {
        Write-Note ('设备 ' + $script:SerialNo + ' 不在线（state=' + $state + '），DRY-RUN 继续预览命令') 'Yellow'
    } else {
        Fail-Run ('设备 ' + $script:SerialNo + ' 不在线（state=' + $state + '）') @(
            'USB 没连上或没授权：手机上确认「允许 USB 调试」弹窗，必要时 revoke 后重插。',
            'adb server 状态坏了：adb kill-server 再 adb devices -l。',
            '序列号写错：adb devices -l 看真实序列号，用 -Serial 传。'
        ) 2
    }
}

if ($DryRun) {
    Write-Host ''
    Write-Host '--- DRY-RUN 将执行的命令 ---' -ForegroundColor Yellow
    Write-Host ('  adb -s ' + $Serial + ' uninstall ' + $Package + '    # -KeepAppData 时跳过')
    Write-Host ('  adb -s ' + $Serial + ' push "' + $ApkPath + '" /data/local/tmp/' + $apkName)
    Write-Host ('  adb -s ' + $Serial + ' shell pm install -r -g /data/local/tmp/' + $apkName)
    Write-Host ('  adb -s ' + $Serial + ' logcat -c')
    Write-Host ('  adb -s ' + $Serial + ' shell am start -n ' + $Activity)
    Write-Host ('  [循环 ' + $TimeoutMin + ' 分钟，每 ' + $PollSec + 's] run-as cat files/server.url / logcat -s ' + $LogTag + ':V / tail files/logs/server.log')
    Write-Host ('  adb -s ' + $Serial + ' forward tcp:' + $LocalPort + ' tcp:' + $DevicePort)
    Write-Host ('  Invoke-WebRequest "http://127.0.0.1:' + $LocalPort + '/?token=..."  期望 303')
    Show-Report 'dryrun' 0
}

# --- PHASE install
if ($KeepAppData) {
    Write-Phase 'install' 'KeepAppData：跳过卸载，-r 覆盖安装并复用私有目录'
    $script:Report.install.skipped = $true
} else {
    Write-Phase 'install' ('卸载旧包 ' + $Package + '（失败忽略）')
    $un = Invoke-Adb -Arguments @('uninstall', $Package) -AllowFailure
    if ($un.Text) { Write-Note ('uninstall: ' + ($un.Text -replace '\r?\n', ' ')) }
}

$inst = Install-Apk -Path $ApkPath
$script:Report.install.seconds = $inst.Seconds
$script:Report.install.output = ($inst.Output -replace '\r?\n', ' | ')
Write-Note ('install 用时 ' + $inst.Seconds + 's：' + $script:Report.install.output)
if (-not $inst.Ok) {
    Fail-Run ('安装失败：' + $script:Report.install.output) (Get-InstallReasons $inst.Output) 1
}
Write-Phase 'install' 'ok'

# --- PHASE start
Write-Phase 'start' '清空 logcat'
$cl = Invoke-Adb -Arguments @('logcat', '-c') -AllowFailure
if (-not $cl.Ok) { Write-Note 'logcat -c 被拒（部分机型限制），继续观察' 'Yellow' }

Invoke-Adb -Arguments @('shell', 'am', 'force-stop', $Package) -AllowFailure | Out-Null

$start = Invoke-Adb -Arguments @('shell', 'am', 'start', '-n', $Activity) -AllowFailure
$script:Report.start.command = $start.Command
$script:Report.start.output = ($start.Text -replace '\r?\n', ' | ')
Write-Note ('am start: ' + $script:Report.start.output)

if ($start.Text -match 'Error type 3|does not exist|Error: Activity class|SecurityException') {
    Fail-Run ('am start 失败：' + $script:Report.start.output) @(
        'Activity 组件名不对：adb shell dumpsys package com.dsh.runner 里找 MainActivity 的完整名。',
        'APK 未真正装上：回到 install 阶段看 pm install 输出。',
        'Activity 未 exported 或包名不符：核对 AndroidManifest.xml。'
    ) 1
}
$script:Report.start.ok = $true
Write-Phase 'start' 'ok'

# --- PHASE wait
Write-Phase 'wait' ('每 ' + $PollSec + 's 检查 server.url / logcat / server.log，最多 ' + $TimeoutMin + ' min')
$deadline = (Get-Date).AddMinutes($TimeoutMin)
$attempt = 0
$urlSeen = $false
$crashLine = ''

while ((Get-Date) -lt $deadline) {
    $attempt++
    $script:Report.wait.attempts = $attempt

    $url = Get-DeviceUrl
    $appPid = Get-AppPid
    $script:AppPid = $appPid
    $script:Report.wait.appPid = $appPid

    $appLog = Get-AppLogTail -Lines 40
    $catLog = Get-LogcatTail -Lines (40 + 10 * [math]::Min($attempt, 6))
    $crash = Get-CrashLines

    foreach ($ln in ($appLog -split '\r?\n')) { if ($ln.Trim()) { Add-KeyLine $ln } }
    foreach ($ln in ($catLog -split '\r?\n')) { if ($ln.Trim()) { Add-KeyLine $ln } }

    $elapsed = (Get-Date) - $script:StartedAt
    if ($url) { $urlText = 'FOUND' } else { $urlText = 'none' }
    $head = ('[{0}] wait#{1} elapsed={2} pid={3} url={4}' -f (Get-Date).ToString('HH:mm:ss'), $attempt, $elapsed.ToString('hh\:mm\:ss'), $appPid, $urlText)
    Write-Host $head -ForegroundColor DarkCyan

    $lastApp = ($appLog -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 1)
    $lastCat = ($catLog -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if ($lastApp) { Write-Note ('app: ' + $lastApp) }
    if ($lastCat) { Write-Note ('cat: ' + $lastCat) }
    if ($crash) { Write-Note ('crash: ' + (($crash -split '\r?\n' | Select-Object -First 1))) 'Red' }

    if ($url) {
        $script:DeviceUrl = $url
        $urlSeen = $true
        $script:Report.wait.urlSeen = $true
        Write-Note ('server.url = ' + (Hide-Token $url)) 'Green'
        break
    }

    if ($crash -match 'FATAL EXCEPTION') {
        $crashLine = ($crash -split '\r?\n' | Where-Object { $_ -match 'FATAL EXCEPTION' } | Select-Object -First 1)
        Write-Note '检测到 FATAL EXCEPTION，提前结束等待' 'Red'
        break
    }
    if ($appLog -match '启动失败') {
        $crashLine = ($appLog -split '\r?\n' | Where-Object { $_ -match '启动失败' } | Select-Object -Last 1)
        Write-Note '应用日志出现「启动失败」，提前结束等待' 'Red'
        break
    }

    if ($appPid -le 0) { Write-Note '进程当前不存在（可能刚启动/被重启），继续观察' 'Yellow' }

    $remain = [int]($deadline - (Get-Date)).TotalSeconds
    if ($remain -le 0) { break }
    Start-Sleep -Seconds ([math]::Min($PollSec, $remain))
}

if (-not $urlSeen) {
    $appLog = Get-AppLogTail -Lines 80
    $catLog = Get-LogcatTail -Lines 120
    $crash = Get-CrashLines
    $allLog = $appLog + [Environment]::NewLine + $catLog + [Environment]::NewLine + $crash
    foreach ($ln in ($allLog -split '\r?\n')) { if ($ln.Trim()) { Add-KeyLine $ln } }
    $reasons = Get-FailureReasons -AppLog $appLog -CatLog $allLog -AppPid $script:AppPid -UrlSeen $false -HttpStatus 0
    if ($crashLine) {
        Fail-Run ('等待 ' + $TimeoutMin + ' 分钟失败，且已捕获致命错误：' + $crashLine) $reasons 1
    }
    Fail-Run ('等待 ' + $TimeoutMin + ' 分钟仍未出现 server.url（轮询 ' + $attempt + ' 次）') $reasons 1
}

# --- PHASE ok：forward + HTTP 验证
Write-Phase 'ok' 'server.url 已出现，开始 PC 端验证'
$forwardOk = Setup-Forward
if (-not $forwardOk) {
    $reasons = @(
        'adb forward 失败：端口被占用。用 -LocalPort 换一个，或 netstat -ano | findstr 16137 找占用进程。',
        '设备连接抖动：重插 USB 后重跑脚本。',
        '另一个 adb forward 规则冲突：adb forward --list 后清理。'
    )
    Fail-Run 'adb forward 建立失败' $reasons 1
}
Write-Note ('forward 就绪：tcp:' + $LocalPort + ' -> tcp:' + $DevicePort)

$pcUrl = Build-PcUrl $script:DeviceUrl
if (-not $pcUrl) {
    Fail-Run ('server.url 解析失败: ' + (Hide-Token $script:DeviceUrl)) @(
        'server.url 内容不是合法 URL：重新触发一次服务启动（重启 App）。',
        '文件被截断：删除 files/server.url 后重启应用。',
        'run-as 读到的是旧内容：不带 -KeepAppData 重装。'
    ) 1
}
Write-Note ('GET ' + (Hide-Token $pcUrl) + '  期望 303')

$probe = Invoke-WebProbe -Url $pcUrl -TimeoutSec 10
$script:Report.http.status = $probe.Status
$script:Report.http.location = $probe.Location
$script:Report.http.engine = $probe.Engine
Write-Note ('HTTP ' + $probe.Status + ' (engine=' + $probe.Engine + ') location=' + $probe.Location)

$bareProbe = Invoke-WebProbe -Url ('http://127.0.0.1:' + $LocalPort + '/') -TimeoutSec 10
$script:Report.http.bareStatus = $bareProbe.Status
Write-Note ('对照：GET / 无 token -> ' + $bareProbe.Status + '（401 属正常）')

if ($probe.Status -eq 303) {
    Write-Note '303 + Location：token 换 cookie 成功，dsh web 服务确认活着' 'Green'
} elseif ($probe.Status -eq 200) {
    Write-Note '200：服务活着（该版本可能不重定向），继续' 'Green'
} elseif ($probe.Status -eq 401) {
    $reasons = Get-FailureReasons -AppLog (Get-AppLogTail -Lines 60) -CatLog '' -AppPid $script:AppPid -UrlSeen $true -HttpStatus 401
    Fail-Run 'PC 端拿到 401：token 不匹配' $reasons 1
} elseif ($probe.Status -eq 0) {
    $reasons = @(
        'PC 到 adb forward 端口不通：确认 tcp:' + $LocalPort + ' 没被占用（netstat -ano | findstr ' + $LocalPort + '）。',
        '服务只监听 127.0.0.1 且 forward 未生效：adb forward --list 检查映射。',
        '设备侧服务已死：看 logcat -s ' + $LogTag + ':V 最后几行。'
    )
    Fail-Run ('HTTP 探测无响应（engine=' + $probe.Engine + ', err=' + $probe.Error + '）') $reasons 1
} else {
    $reasons = @(
        ('非预期状态码 ' + $probe.Status + '：服务在但路由/鉴权异常，检查 server.log 里的 http 行。'),
        'PC 侧代理干扰：本机代理可能劫持 127.0.0.1，临时关闭后再试。',
        '端口映射错位：确认 forward 的本地端口与请求端口一致。'
    )
    Fail-Run ('HTTP 返回 ' + $probe.Status + '，不符合 303/200') $reasons 1
}

# --- 成功收尾
$openCmd = '$u = (& "' + $script:AdbBin + '" -s ' + $script:SerialNo + ' shell run-as ' + $Package + ' cat files/server.url).Trim(); ($u -replace ":' + $DevicePort + '", ":' + $LocalPort + '") | Set-Clipboard'
Write-Host ''
Write-Host '下一步：' -ForegroundColor Yellow
Write-Host ('  在 PC 浏览器打开带 token 的 URL（Token 未打印，用下面命令复制到剪贴板）：')
Write-Host ('    ' + $openCmd) -ForegroundColor DarkGray
Write-Host ('  截图看界面：powershell -NoProfile -ExecutionPolicy Bypass -File .\shot.ps1')
Write-Host ('  重跑验证：powershell -NoProfile -ExecutionPolicy Bypass -File .\verify-apk.ps1 -KeepAppData -TimeoutMin 5')

Write-Phase 'ok' ('HTTP ' + $probe.Status + '，验证通过')
Show-Report 'ok' 0
