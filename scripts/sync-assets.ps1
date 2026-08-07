#requires -Version 5.1
<#
.SYNOPSIS
    同步客户端随包素材：地区旗帜与地区映射表。

.DESCRIPTION
    两者都是面板仓库里的静态文件，直接拷贝，不连数据库、不联网：
    - Website/public/images/flags -> app/assets/flags
    - Website/config/regions.json -> app/assets/regions.json

    地区取词正则（设置项 flag_regex）与策略组图标地址由面板在
    /config/clash 响应里下发，不属于随包素材。
#>
[CmdletBinding()]
param(
    [string]$PanelRoot = ''
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$assetsDir = Join-Path $rootDir 'app\assets'

if (-not $PanelRoot) {
    $PanelRoot = Join-Path (Split-Path -Parent $rootDir) 'Website'
}

$flagsSource = Join-Path $PanelRoot 'public\images\flags'
$regionsSource = Join-Path $PanelRoot 'config\regions.json'
if (-not (Test-Path $flagsSource) -or -not (Test-Path $regionsSource)) {
    throw "未找到面板资源：$flagsSource / $regionsSource"
}

$flagsTarget = Join-Path $assetsDir 'flags'
New-Item -ItemType Directory -Force -Path $flagsTarget | Out-Null
Get-ChildItem $flagsTarget -File -Filter '*.svg' | Remove-Item -Force
Copy-Item (Join-Path $flagsSource '*.svg') $flagsTarget -Force
$flagCount = (Get-ChildItem $flagsTarget -File -Filter '*.svg').Count

Copy-Item $regionsSource (Join-Path $assetsDir 'regions.json') -Force

Write-Host ""
Write-Host "素材已同步：旗帜 $flagCount 面、地区映射表 1 份 -> $assetsDir"
