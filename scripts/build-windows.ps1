#requires -Version 5.1
<#
.SYNOPSIS
    构建 Windows 客户端完整产物：内核 + 特权服务 + Flutter 应用，可选打包安装器。

.EXAMPLE
    pwsh scripts/build-windows.ps1 -Arch x64
    pwsh scripts/build-windows.ps1 -Arch x64 -Installer
    pwsh scripts/build-windows.ps1 -Arch x64 -SubUrl https://订阅域名 -Installer
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = 'x64',

    # 需要本机已安装 Inno Setup 6（iscc.exe 在 PATH 中）
    [switch]$Installer,

    # CI 机器上没有面板仓库，直接用仓库里已有的随包素材
    [switch]$SkipAssetSync,

    [string]$Version = '1.0.1',

    # 发布通道。pre 只给界面版本串加 Pre 前缀，安装包版本与产物名仍是纯号段
    [ValidateSet('last', 'pre')]
    [string]$Channel = 'last',

    # 设置中心「网站地址」。只用于登录/注册/关于文案，不作为通讯主机。不填时读 config/panel.json 的 panelUrl
    [string]$PanelUrl,

    # 设置中心「订阅域名」。通讯主机。不填时读 config/panel.json 的 subUrl
    [string]$SubUrl
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$appDir = Join-Path $rootDir 'app'
$depsDir = Join-Path $rootDir "build\deps\$Arch"
$stageDir = Join-Path $rootDir "build\windows\$Arch"
$panelConfigPath = Join-Path $rootDir 'config\panel.json'

$panelConfig = $null
if (-not $SubUrl -or -not $PanelUrl) {
    if (-not (Test-Path $panelConfigPath)) {
        throw "未指定站点域名或订阅域名，且找不到 $panelConfigPath"
    }
    $panelConfig = Get-Content $panelConfigPath -Raw | ConvertFrom-Json
}

if (-not $SubUrl) {
    $SubUrl = $panelConfig.subUrl
}
if (-not $PanelUrl) {
    $PanelUrl = $panelConfig.panelUrl
}

if ($PanelUrl -notmatch '^https?://') {
    throw "站点域名不是合法的 http(s) 地址：$PanelUrl"
}
if ($SubUrl -notmatch '^https?://') {
    throw "订阅域名不是合法的 http(s) 地址：$SubUrl"
}

# 本机仓库在 D 盘，临时文件不落 C 盘；CI 机器上没有 D 盘，用默认位置
if (Test-Path 'D:\') {
    $env:TEMP = 'D:\tmp'
    $env:TMP = 'D:\tmp'
    New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
}

& (Join-Path $scriptDir 'fetch-kernel.ps1') -Arch $Arch
& (Join-Path $scriptDir 'build-service.ps1') -Arch $Arch
if (-not $SkipAssetSync) {
    & (Join-Path $scriptDir 'sync-assets.ps1')
}

Push-Location $appDir
try {
    # --build-name 喂 VERSIONINFO，只能是纯号段；窗口标题另取环境变量里的展示串
    $env:ECYCLOUD_VERSION = if ($Channel -eq 'pre') { "Pre $Version" } else { $Version }
    # Flutter 目前只为宿主架构产出 Windows 产物，arm64 包需在 arm64 机器上构建
    flutter build windows --release --build-name $Version `
        --dart-define="ECYCLOUD_SITE_URL=$PanelUrl" `
        --dart-define="ECYCLOUD_SUB_URL=$SubUrl" `
        --dart-define="ECYCLOUD_VERSION=$env:ECYCLOUD_VERSION"
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

# 服务按自身目录定位 mihomo.exe。逐个点名：build/deps 是增量的，换内核后旧文件还在
$serviceDir = Join-Path $stageDir 'service'
New-Item -ItemType Directory -Force -Path $serviceDir | Out-Null
# geodata 与内核同目录：缺了内核会按 geox-url 同步下载，面板地址在目标网络不可达
foreach ($name in @('ecycloud-service.exe', 'mihomo.exe', 'LICENSE.mihomo.txt', 'geoip.metadb', 'GeoSite.dat')) {
    $source = Join-Path $depsDir $name
    if (-not (Test-Path $source)) {
        throw "缺少 $source"
    }
    Copy-Item $source $serviceDir -Force
}

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
