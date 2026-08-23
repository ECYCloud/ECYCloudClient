#requires -Version 5.1
<#
.SYNOPSIS
    从主图 assets/icon/app_icon.png 生成各端应用图标、登录页图标与安装器向导图。

.DESCRIPTION
    换图标时只改主图，跑一遍本脚本重新生成，不要手工塞二进制。
    Windows：ICO 各尺寸以 PNG 负载嵌入（Vista 起支持），保留透明通道；
    向导图按 Inno Setup 的缩放档位输出 24 位 BMP，白底以贴合向导页背景。
    macOS：应用图标 AppIcon.appiconset 与菜单栏 MenuBarIcon.imageset 均按各自档位输出，
    都是透明底纯图形，与 Windows / Linux 托盘同一张；Android：按 mipmap 密度输出，
    并生成 Android TV 主屏 banner（`drawable-*/ic_banner.png`，xhdpi 为 320×180）；
    Linux：按 hicolor 档位输出，随 deb 装进 /usr/share/icons。
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

$flutterIcon = Join-Path $rootDir 'app\assets\app_icon.png'
Copy-Item -LiteralPath $Source -Destination $flutterIcon -Force

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

function Save-Banner {
    param(
        [System.Drawing.Image]$Image,
        [int]$BannerWidth,
        [int]$BannerHeight,
        [string]$Path,
        [string]$Label
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $bitmap = New-Object System.Drawing.Bitmap($BannerWidth, $BannerHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.Clear($bannerColor)
        $iconSize = [int][Math]::Floor($BannerHeight * 0.48)
        $iconTop = [int][Math]::Floor($BannerHeight * 0.14)
        $iconLeft = [int][Math]::Floor(($BannerWidth - $iconSize) / 2)
        $graphics.DrawImage($Image, (New-Object System.Drawing.Rectangle($iconLeft, $iconTop, $iconSize, $iconSize)))
        $fontSize = [Math]::Max(10, [int][Math]::Floor($BannerHeight * 0.13))
        $font = New-Object System.Drawing.Font('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $format = New-Object System.Drawing.StringFormat
        $format.Alignment = [System.Drawing.StringAlignment]::Center
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $textTop = [int]($iconTop + $iconSize)
        $textRect = New-Object System.Drawing.RectangleF(0, $textTop, $BannerWidth, ($BannerHeight - $textTop))
        try {
            $graphics.DrawString($Label, $font, $brush, $textRect, $format)
        }
        finally {
            $format.Dispose()
            $brush.Dispose()
            $font.Dispose()
        }
    }
    finally {
        $graphics.Dispose()
    }
    try {
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}

function Save-Png {
    param(
        [System.Drawing.Image]$Image,
        [int]$Size,
        [string]$Path,
        [System.Drawing.Color]$Background = [System.Drawing.Color]::Transparent
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $bitmap = New-Square -Image $Image -Size $Size `
        -Background $Background `
        -Format ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}

$sizes = @(16, 20, 24, 32, 48, 64, 128, 256)
# Inno Setup 按 100/150/200/250/300/350% 挑选向导图
$wizardSizes = @(55, 83, 110, 138, 165, 192)
# 与 app/macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json 的档位一致
$macSizes = @(16, 32, 64, 128, 256, 512, 1024)
# 菜单栏按 18pt 画，1x / 2x 与 MenuBarIcon.imageset/Contents.json 的 filename 一致
$macMenuBarSizes = @(18, 36)
$linuxSizes = @(16, 32, 48, 64, 128, 256)
$androidSizes = [ordered]@{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
# Android TV banner：官方规格是 xhdpi 320×180，其余密度按 160dpi 基线等比
$androidBanners = @(
    @{ Density = 'mdpi'; Width = 160; Height = 90 }
    @{ Density = 'hdpi'; Width = 240; Height = 135 }
    @{ Density = 'xhdpi'; Width = 320; Height = 180 }
    @{ Density = 'xxhdpi'; Width = 480; Height = 270 }
    @{ Density = 'xxxhdpi'; Width = 640; Height = 360 }
)
$bannerColor = [System.Drawing.Color]::FromArgb(255, 47, 107, 255)
$stringsFile = Join-Path $rootDir 'app\android\app\src\main\res\values\strings.xml'
$bannerLabel = 'ECY Cloud'
if (Test-Path $stringsFile) {
    $match = Select-String -Path $stringsFile -Pattern '<string name="app_name">([^<]+)</string>'
    if ($match) {
        $bannerLabel = $match.Matches[0].Groups[1].Value
    }
}

$macIconDir = Join-Path $rootDir 'app\macos\Runner\Assets.xcassets\AppIcon.appiconset'
$macMenuBarDir = Join-Path $rootDir 'app\macos\Runner\Assets.xcassets\MenuBarIcon.imageset'
$androidResDir = Join-Path $rootDir 'app\android\app\src\main\res'
$linuxIconDir = Join-Path $scriptDir 'installer\linux\icons'

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

    foreach ($size in $macSizes) {
        Save-Png -Image $master -Size $size -Path (Join-Path $macIconDir "app_icon_$size.png")
    }
    foreach ($size in $macMenuBarSizes) {
        Save-Png -Image $master -Size $size -Path (Join-Path $macMenuBarDir "menu_bar_icon_$size.png")
    }
    foreach ($size in $linuxSizes) {
        Save-Png -Image $master -Size $size -Path (Join-Path $linuxIconDir "$size.png")
    }
    foreach ($density in $androidSizes.Keys) {
        Save-Png -Image $master -Size $androidSizes[$density] `
            -Path (Join-Path $androidResDir "mipmap-$density\ic_launcher.png")
    }
    foreach ($banner in $androidBanners) {
        Save-Banner -Image $master -BannerWidth ([int]$banner.Width) -BannerHeight ([int]$banner.Height) `
            -Path (Join-Path $androidResDir "drawable-$($banner.Density)\ic_banner.png") `
            -Label $bannerLabel
    }
}
finally {
    $master.Dispose()
}

$file = [System.IO.File]::Create($Output)
$writer = New-Object System.IO.BinaryWriter($file)

try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$sizes.Count)

    # ICONDIRENTRY 定长 16 字节，图像数据紧随目录
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $size = $sizes[$i]
        # 256 在单字节字段里记作 0
        $writer.Write([byte]($size % 256))
        $writer.Write([byte]($size % 256))
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
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

Write-Host "登录页图标已复制：$flutterIcon"
Write-Host "图标已生成：$Output（$($sizes -join '/') px，$([math]::Round((Get-Item $Output).Length / 1KB, 1)) KB）"
Write-Host "向导图已生成：$WizardDir（$($wizardSizes -join '/') px）"
Write-Host "macOS 图标已生成：$macIconDir（$($macSizes -join '/') px）"
Write-Host "macOS 菜单栏图标已生成：$macMenuBarDir（$($macMenuBarSizes -join '/') px）"
Write-Host "Linux 图标已生成：$linuxIconDir（$($linuxSizes -join '/') px）"
Write-Host "Android 图标已生成：$androidResDir（$($androidSizes.Values -join '/') px）"
Write-Host "Android TV banner 已生成：$androidResDir（xhdpi 320x180）"
