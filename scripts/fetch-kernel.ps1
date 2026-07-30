#requires -Version 5.1
<#
.SYNOPSIS
    按 kernel.lock.json 下载并校验 sing-box 与 wintun 官方发布包。

.DESCRIPTION
    校验不通过立即失败，绝不使用未经校验的二进制。产物落在 build/deps/<arch>/，
    供 build-windows.ps1 组装到安装包的 service 目录。
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = 'x64',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
# Windows PowerShell 5.1 的 Get-Content 默认按 ANSI 读，锁文件含中文注释必须指定 UTF8
$lock = Get-Content (Join-Path $scriptDir 'kernel.lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$cacheDir = Join-Path $rootDir 'build\cache'
$outDir = Join-Path $rootDir "build\deps\$Arch"
New-Item -ItemType Directory -Force -Path $cacheDir, $outDir | Out-Null

function Get-Verified {
    param([string]$Url, [string]$Sha256)

    $path = Join-Path $cacheDir (Split-Path $Url -Leaf)
    if ($Force -and (Test-Path $path)) {
        Remove-Item $path -Force
    }
    if (-not (Test-Path $path)) {
        Write-Host "下载 $Url"
        Invoke-WebRequest -Uri $Url -OutFile $path -UseBasicParsing
    }

    $actual = (Get-FileHash $path -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Sha256.ToLower()) {
        Remove-Item $path -Force
        throw "校验失败：$Url`n  期望 $Sha256`n  实际 $actual"
    }
    Write-Host "校验通过 $(Split-Path $Url -Leaf)"
    return $path
}

function Expand-Fresh {
    param([string]$Archive)

    $target = Join-Path $cacheDir ([IO.Path]::GetFileNameWithoutExtension($Archive))
    if (Test-Path $target) {
        Remove-Item $target -Recurse -Force
    }
    Expand-Archive -Path $Archive -DestinationPath $target -Force
    return $target
}

# 安装器对产物目录是 ignoreversion 无条件覆盖，包内内核比用户机上的旧就会把人降级
# （用户可以在设置里就地升级内核）。因此出包前锁的必须是当时的最新正式版。
# 只提醒不阻断：查不到版本（无网络、API 限流）不该让构建失败。
try {
    $latest = (Invoke-RestMethod -Uri 'https://api.github.com/repos/SagerNet/sing-box/releases/latest' `
            -Headers @{ 'User-Agent' = 'ecycloud-build' } -TimeoutSec 15).tag_name -replace '^v', ''
    if ($latest -and $latest -ne $lock.singBox.version) {
        Write-Warning "kernel.lock.json 锁定 $($lock.singBox.version)，官方最新正式版为 $latest：出客户端包前请先抬版本并回归测试，否则用户重装会被降级"
    }
}
catch {
    Write-Host "跳过最新版本比对：$($_.Exception.Message)"
}

$kernelAsset = $lock.singBox.assets.$Arch
$kernelZip = Get-Verified -Url $kernelAsset.url -Sha256 $kernelAsset.sha256
$kernelRoot = Join-Path (Expand-Fresh $kernelZip) $kernelAsset.root

foreach ($name in $lock.singBox.files) {
    $source = Join-Path $kernelRoot $name
    if (-not (Test-Path $source)) {
        throw "发布包中缺少 $name"
    }
    $destination = if ($name -eq 'LICENSE') { 'LICENSE.sing-box.txt' } else { $name }
    Copy-Item $source (Join-Path $outDir $destination) -Force
}

$wintunZip = Get-Verified -Url $lock.wintun.url -Sha256 $lock.wintun.sha256
$wintunRoot = Expand-Fresh $wintunZip

Copy-Item (Join-Path $wintunRoot $lock.wintun.dll.$Arch) (Join-Path $outDir 'wintun.dll') -Force
Copy-Item (Join-Path $wintunRoot $lock.wintun.license) (Join-Path $outDir 'LICENSE.wintun.txt') -Force

Write-Host ""
Write-Host "sing-box $($lock.singBox.version) + wintun $($lock.wintun.version) 已就绪：$outDir"
Get-ChildItem $outDir | Select-Object Name, Length | Format-Table -AutoSize
