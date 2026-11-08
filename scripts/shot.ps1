#requires -Version 5.1
<#
.SYNOPSIS
    真机截屏并保存到 E:\dsh-android\shots\<时间戳>.png，最后一行打印可复制的路径。

.DESCRIPTION
    用 adb shell screencap 落到 /sdcard，再 adb pull 到本地，最后删掉设备上的临时文件。
    不用 exec-out 直出，避免 PowerShell 重定向把 PNG 字节写坏。

.PARAMETER OutDir
    本地输出目录，默认 E:\dsh-android\shots，不存在会自动创建。

.PARAMETER Open
    截完直接用系统看图程序打开。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\shot.ps1

.EXAMPLE
    pwsh -NoProfile -File .\shot.ps1 -Open

.NOTES
    退出码：0 成功 / 1 失败。
#>
[CmdletBinding()]
param(
    [string]$OutDir = 'E:\dsh-android\shots',
    [string]$Serial = 'b82a026f',
    [string]$Adb = 'C:\Program Files\ASUS\GlideX\adb.exe',
    [switch]$Open
)

$ErrorActionPreference = 'Stop'

function Invoke-AdbShot {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$NoSerial
    )
    $argv = New-Object System.Collections.Generic.List[string]
    if (-not $NoSerial) { [void]$argv.Add('-s'); [void]$argv.Add($Serial) }
    foreach ($a in $Arguments) { [void]$argv.Add([string]$a) }
    $out = @()
    $code = 0
    try {
        $out = & $Adb @argv 2>&1 | ForEach-Object { [string]$_ }
        if ($null -eq $LASTEXITCODE) { $code = 0 } else { $code = [int]$LASTEXITCODE }
    } catch {
        $out = @([string]$_.Exception.Message)
        $code = -1
    }
    return [pscustomobject]@{
        Ok = ($code -eq 0)
        Text = (($out -join [Environment]::NewLine).Trim())
    }
}

function Fail-Shot {
    param([string]$Why, [string[]]$Hints = @())
    Write-Host ('SHOT-FAIL: ' + $Why) -ForegroundColor Red
    foreach ($h in $Hints) { Write-Host ('  - ' + $h) -ForegroundColor DarkYellow }
    Write-Host ''
    Write-Host '诊断命令：' -ForegroundColor Yellow
    Write-Host ('  & "' + $Adb + '" -s ' + $Serial + ' devices -l')
    Write-Host ('  & "' + $Adb + '" -s ' + $Serial + ' shell dumpsys window | Select-String mCurrentFocus')
    Write-Host ('  & "' + $Adb + '" -s ' + $Serial + ' shell ls -l /sdcard/DCIM')
    exit 1
}

if (-not (Test-Path -LiteralPath $Adb)) {
    Fail-Shot ('找不到 adb：' + $Adb) @('用 -Adb 指定实际 adb.exe 路径。')
}

$dev = Invoke-AdbShot -Arguments @('devices', '-l') -NoSerial
$pattern = '^\s*' + [regex]::Escape($Serial) + '\s+device\b'
$online = $false
foreach ($line in ($dev.Text -split '\r?\n')) {
    if ($line -match $pattern) { $online = $true }
}
if (-not $online) {
    Fail-Shot ('设备 ' + $Serial + ' 不在线') @(
        'USB 未连接或未授权：手机上点「允许 USB 调试」。',
        'adb server 异常：adb kill-server 后 adb devices -l。',
        '序列号不对：adb devices -l 看真实序列号。'
    )
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$remote = '/sdcard/dsh-shot-' + $stamp + '.png'
$local = Join-Path $OutDir ($stamp + '.png')

$cap = Invoke-AdbShot -Arguments @('shell', 'screencap', '-p', $remote)
if (-not $cap.Ok) {
    Fail-Shot ('screencap 失败：' + $cap.Text) @('设备可能锁屏或屏幕被安全策略挡住，解锁后再试。')
}

$pull = Invoke-AdbShot -Arguments @('pull', $remote, $local)
Invoke-AdbShot -Arguments @('shell', 'rm', '-f', $remote) | Out-Null
if (-not $pull.Ok) {
    Fail-Shot ('pull 失败：' + $pull.Text) @(
        '本地目录不可写：换 -OutDir。',
        '设备 /sdcard 不可写：adb shell df -h /sdcard 看空间。'
    )
}

if (-not (Test-Path -LiteralPath $local)) {
    Fail-Shot 'pull 报告成功但本地文件不存在' @('重跑一次；仍失败就用 -OutDir 换目录。')
}
$file = Get-Item -LiteralPath $local
if ($file.Length -lt 1024) {
    Fail-Shot ('截图为空或过小：' + $file.Length + ' 字节') @(
        '截屏时屏幕可能是纯黑/纯色或 DRM 界面。',
        '先解锁设备再截。'
    )
}

$kb = [math]::Round($file.Length / 1KB, 1)
Write-Host ('SHOT ' + $file.FullName + '  (' + $kb + ' KB, ' + $stamp + ')') -ForegroundColor Green
Write-Host ('可直接打开：Invoke-Item "' + $file.FullName + '"') -ForegroundColor DarkGray

if ($Open) { Invoke-Item -LiteralPath $file.FullName }
exit 0
