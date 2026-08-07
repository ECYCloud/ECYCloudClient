#requires -Version 5.1
<#
.SYNOPSIS
    按 kernel.lock.json 下载并校验 mihomo 官方发布包。

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

# geodata 上游只有滚动 tag，锁不住 sha256（见 kernel.lock.json 的说明），改为拦 404 页面与
# 截断下载：体积下限 + MMDB 尾部的 MaxMind 元数据魔数。内容合法性由内核运行时自行校验。
function Get-GeoData {
    param([string]$Url, [string]$Target, [int]$MinBytes)

    $path = Join-Path $cacheDir $Target
    if ($Force -and (Test-Path $path)) {
        Remove-Item $path -Force
    }
    if (-not (Test-Path $path)) {
        Write-Host "下载 $Url"
        Invoke-WebRequest -Uri $Url -OutFile $path -UseBasicParsing
    }

    $size = (Get-Item $path).Length
    if ($size -lt $MinBytes) {
        Remove-Item $path -Force
        throw "geodata 体积异常：$Url`n  实际 $size 字节，下限 $MinBytes"
    }
    # MaxMind DB 规范把元数据段放在文件末 128 KiB 内，以 "MaxMind.com" 起头
    if ($Target -like '*.metadb') {
        $tailSize = [Math]::Min(131072, $size)
        $stream = [IO.File]::OpenRead($path)
        try {
            $tail = New-Object byte[] $tailSize
            $stream.Seek(-$tailSize, [IO.SeekOrigin]::End) | Out-Null
            $stream.Read($tail, 0, $tailSize) | Out-Null
        }
        finally {
            $stream.Dispose()
        }
        # ISO-8859-1 逐字节映射，不会像 UTF8 那样把非法序列换成替代字符；
        # 用代码页取而不是 [Text.Encoding]::Latin1，后者要 .NET 5+，PowerShell 5.1 上没有
        if (-not [Text.Encoding]::GetEncoding(28591).GetString($tail).Contains('MaxMind.com')) {
            Remove-Item $path -Force
            throw "不是有效的 MaxMind 数据库：$Url"
        }
    }

    Write-Host "校验通过 $Target（$([math]::Round($size / 1MB, 2)) MB）"
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
    $latest = (Invoke-RestMethod -Uri 'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest' `
            -Headers @{ 'User-Agent' = 'ecycloud-build' } -TimeoutSec 15).tag_name -replace '^v', ''
    if ($latest -and $latest -ne $lock.mihomo.version) {
        Write-Warning "kernel.lock.json 锁定 $($lock.mihomo.version)，官方最新正式版为 $latest：出客户端包前请先抬版本并回归测试，否则用户重装会被降级"
    }
}
catch {
    Write-Host "跳过最新版本比对：$($_.Exception.Message)"
}

$asset = $lock.mihomo.assets."windows-$Arch"
$kernelZip = Get-Verified -Url $asset.url -Sha256 $asset.sha256
$source = Join-Path (Expand-Fresh $kernelZip) $asset.entry
if (-not (Test-Path $source)) {
    throw "发布包中缺少 $($asset.entry)"
}
Copy-Item $source (Join-Path $outDir 'mihomo.exe') -Force

# mihomo 的发布包内不含 LICENSE，其内核许可证与本项目同为逐字 GPL-3.0，直接复用仓库根的副本
Copy-Item (Join-Path $rootDir 'LICENSE') (Join-Path $outDir 'LICENSE.mihomo.txt') -Force

# geodata 与内核同目录，安装后由服务播种进运行目录
foreach ($name in @('mmdb', 'geosite')) {
    $geo = $lock.geodata.assets.$name
    $file = Get-GeoData -Url $geo.url -Target $geo.target -MinBytes $geo.minBytes
    Copy-Item $file (Join-Path $outDir $geo.target) -Force
}

Write-Host ""
Write-Host "mihomo $($lock.mihomo.version) 已就绪：$outDir"
Get-ChildItem $outDir | Select-Object Name, Length | Format-Table -AutoSize
