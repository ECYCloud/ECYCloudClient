#requires -Version 5.1
<#
.SYNOPSIS
    从主图 assets/icon/app_icon.png 生成应用图标与安装器向导图。

.DESCRIPTION
    换图标时只改主图，跑一遍本脚本重新生成，不要手工塞二进制。
    ICO 各尺寸以 PNG 负载嵌入（Vista 起支持），保留透明通道；
    向导图按 Inno Setup 的缩放档位输出 24 位 BMP，白底以贴合向导页背景。
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Output,
    [string]$WizardDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

if (-not $Source) { $Source = Join-Path $rootDir 'assets\icon\app_icon.png' }
if (-not $Output) { $Output = Join-Path $rootDir 'app\windows\runner\resources\app_icon.ico' }
if (-not $WizardDir) { $WizardDir = Join-Path $scriptDir 'installer\wizard' }

if (-not (Test-Path $Source)) {
    throw "未找到主图：$Source"
}

function New-Square {
    param(
        [System.Drawing.Image]$Image,
        [int]$Size,
        [System.Drawing.Color]$Background,
        [System.Drawing.Imaging.PixelFormat]$Format
    )

    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size, $Format)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.Clear($Background)
        $graphics.DrawImage($Image, (New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)))
    }
    finally {
        $graphics.Dispose()
    }
    return $bitmap
}

$sizes = @(16, 20, 24, 32, 48, 64, 128, 256)
# Inno Setup 按 100/150/200/250/300/350% 挑选向导图
$wizardSizes = @(55, 83, 110, 138, 165, 192)

$master = [System.Drawing.Image]::FromFile($Source)
$payloads = New-Object 'System.Collections.Generic.List[byte[]]'

try {
    foreach ($size in $sizes) {
        $bitmap = New-Square -Image $master -Size $size `
            -Background ([System.Drawing.Color]::Transparent) `
            -Format ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $stream = New-Object System.IO.MemoryStream
        try {
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            $payloads.Add($stream.ToArray())
        }
        finally {
            $stream.Dispose()
            $bitmap.Dispose()
        }
    }

    New-Item -ItemType Directory -Force -Path $WizardDir | Out-Null
    foreach ($size in $wizardSizes) {
        $bitmap = New-Square -Image $master -Size $size `
            -Background ([System.Drawing.Color]::White) `
            -Format ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $bitmap.Save((Join-Path $WizardDir "shield-$size.bmp"), [System.Drawing.Imaging.ImageFormat]::Bmp)
        }
        finally {
            $bitmap.Dispose()
        }
    }
}
finally {
    $master.Dispose()
}

$file = [System.IO.File]::Create($Output)
$writer = New-Object System.IO.BinaryWriter($file)

try {
    $writer.Write([uint16]0)              # 保留
    $writer.Write([uint16]1)              # 类型：图标
    $writer.Write([uint16]$sizes.Count)

    # ICONDIRENTRY 定长 16 字节，图像数据紧随目录
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $size = $sizes[$i]
        # 256 在单字节字段里记作 0
        $writer.Write([byte]($size % 256))
        $writer.Write([byte]($size % 256))
        $writer.Write([byte]0)            # 调色板数：真彩色为 0
        $writer.Write([byte]0)            # 保留
        $writer.Write([uint16]1)          # 色彩平面
        $writer.Write([uint16]32)         # 位深
        $writer.Write([uint32]$payloads[$i].Length)
        $writer.Write([uint32]$offset)
        $offset += $payloads[$i].Length
    }

    foreach ($payload in $payloads) {
        $writer.Write($payload)
    }
}
finally {
    $writer.Dispose()
    $file.Dispose()
}

Write-Host "图标已生成：$Output（$($sizes -join '/') px，$([math]::Round((Get-Item $Output).Length / 1KB, 1)) KB）"
Write-Host "向导图已生成：$WizardDir（$($wizardSizes -join '/') px）"
