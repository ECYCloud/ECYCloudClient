#requires -Version 5.1
<#
.SYNOPSIS
    构建 Windows 特权服务 ecycloud-service.exe。
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = 'x64'
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$sourceDir = Join-Path $rootDir 'native\windows\service'
$outDir = Join-Path $rootDir "build\deps\$Arch"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$env:GOOS = 'windows'
$env:GOARCH = if ($Arch -eq 'x64') { 'amd64' } else { 'arm64' }
$env:CGO_ENABLED = '0'
$env:GOCACHE = 'D:\go-build-cache'
$env:GOTMPDIR = 'D:\go-tmp'
$env:GOPATH = 'D:\go'
New-Item -ItemType Directory -Force -Path $env:GOCACHE, $env:GOTMPDIR | Out-Null

$output = Join-Path $outDir 'ecycloud-service.exe'

Push-Location $sourceDir
try {
    go vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'go vet 未通过' }

    # 不加 -H=windowsgui：install / debug 子命令要能在管理员命令行里输出结果
    go build -trimpath -ldflags '-s -w' -o $output .
    if ($LASTEXITCODE -ne 0) { throw 'go build 失败' }
}
finally {
    Pop-Location
}

Write-Host "特权服务已构建：$output"
