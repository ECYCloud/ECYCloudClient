#requires -Version 5.1
<#
.SYNOPSIS
    构建 Windows 客户端完整产物：内核 + 特权服务 + Flutter 应用，可选打包安装器。

.EXAMPLE
    pwsh scripts/build-windows.ps1 -Arch x64
    pwsh scripts/build-windows.ps1 -Arch x64 -Installer
    pwsh scripts/build-windows.ps1 -Arch x64 -PanelUrl https://面板域名 -Installer
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = 'x64',

    # 需要本机已安装 Inno Setup 6（iscc.exe 在 PATH 中）
    [switch]$Installer,

    # CI 机器上没有面板仓库，直接用仓库里已有的随包素材
    [switch]$SkipAssetSync,

    [string]$Version = '1.0.0',

    # 客户端内置的面板地址。本机是仓库副本、连不到面板数据库，不填时读取 config/panel.json
    [string]$PanelUrl
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$appDir = Join-Path $rootDir 'app'
$depsDir = Join-Path $rootDir "build\deps\$Arch"
$stageDir = Join-Path $rootDir "build\windows\$Arch"
$panelConfigPath = Join-Path $rootDir 'config\panel.json'

if (-not $PanelUrl) {
    if (-not (Test-Path $panelConfigPath)) {
        throw "未指定 -PanelUrl，且找不到 $panelConfigPath"
    }
    $PanelUrl = (Get-Content $panelConfigPath -Raw | ConvertFrom-Json).panelUrl
}

if ($PanelUrl -notmatch '^https?://') {
    throw "面板地址不是合法的 http(s) 地址：$PanelUrl"
}

# 本机仓库在 D 盘，临时文件不落 C 盘；CI 机器上没有 D 盘，用默认位置
if (Test-Path 'D:\') {
    $env:TEMP = 'D:\tmp'
    $env:TMP = 'D:\tmp'
    New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
}

& (Join-Path $scriptDir 'fetch-kernel.ps1') -Arch $Arch
& (Join-Path $scriptDir 'build-service.ps1') -Arch $Arch
# 面板才是素材的来源，本机出包前重新拷一遍，保证与面板当前内容一致
if (-not $SkipAssetSync) {
    & (Join-Path $scriptDir 'sync-assets.ps1')
}

Push-Location $appDir
try {
    # Flutter 目前只为宿主架构产出 Windows 产物，arm64 包需在 arm64 机器上构建
    flutter build windows --release --build-name $Version `
        --dart-define="ECYCLOUD_PANEL_URL=$PanelUrl" `
        --dart-define="ECYCLOUD_VERSION=$Version"
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows 失败' }
}
finally {
    Pop-Location
}

$flutterArch = if ($Arch -eq 'x64') { 'x64' } else { 'arm64' }
$releaseDir = Join-Path $appDir "build\windows\$flutterArch\runner\Release"
if (-not (Test-Path (Join-Path $releaseDir 'ECYCloud.exe'))) {
    throw "未找到 Flutter 产物：$releaseDir"
}

if (Test-Path $stageDir) {
    Remove-Item $stageDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

Copy-Item (Join-Path $releaseDir '*') $stageDir -Recurse -Force

# 内核、wintun 与特权服务同目录：服务按自身所在目录定位 sing-box.exe 与 wintun.dll
$serviceDir = Join-Path $stageDir 'service'
New-Item -ItemType Directory -Force -Path $serviceDir | Out-Null
Copy-Item (Join-Path $depsDir '*') $serviceDir -Force

Copy-Item (Join-Path $rootDir 'LICENSE') (Join-Path $stageDir 'LICENSE.txt') -Force

Write-Host ""
Write-Host "客户端产物已就绪：$stageDir"

if (-not $Installer) {
    return
}

$iscc = Get-Command 'iscc.exe' -ErrorAction SilentlyContinue
if (-not $iscc) {
    throw '未找到 iscc.exe，请安装 Inno Setup 6 并加入 PATH'
}

& $iscc.Source `
    "/DAppVersion=$Version" `
    "/DAppArch=$Arch" `
    "/DStageDir=$stageDir" `
    "/DOutputDir=$(Join-Path $rootDir 'build\installer')" `
    (Join-Path $scriptDir 'installer\ecycloud.iss')
if ($LASTEXITCODE -ne 0) { throw '安装器打包失败' }

Write-Host "安装器已生成：$(Join-Path $rootDir 'build\installer')"
