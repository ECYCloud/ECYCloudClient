#requires -Version 5.1
<#
.SYNOPSIS
    用 SSL.com eSigner（CodeSignTool）就地签名并加时间戳单个文件，供 build-windows.ps1 与 Inno 的 SignTool 调用。
    凭据取自环境变量 ES_USERNAME / ES_PASSWORD / ES_CREDENTIAL_ID / ES_TOTP_SECRET，CodeSignTool 目录取自 CODE_SIGN_TOOL_PATH。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

$jar = Get-ChildItem (Join-Path $env:CODE_SIGN_TOOL_PATH 'jar') -Filter 'code_sign_tool-*.jar' |
    Select-Object -First 1
if (-not $jar) {
    throw "CODE_SIGN_TOOL_PATH 下找不到 CodeSignTool：$env:CODE_SIGN_TOOL_PATH"
}
$java = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { 'java' }

# CodeSignTool 出错时退出码仍可能为 0，只认签名结果；失败后跨过 TOTP 的 30 秒窗口换新码再试
$attempts = 3
for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    & $java -jar $jar.FullName sign `
        "-username=$env:ES_USERNAME" `
        "-password=$env:ES_PASSWORD" `
        "-credential_id=$env:ES_CREDENTIAL_ID" `
        "-totp_secret=$env:ES_TOTP_SECRET" `
        "-input_file_path=$Path" `
        -override | Out-Host
    if ((Get-AuthenticodeSignature -FilePath $Path).Status -eq 'Valid') {
        Write-Host "已签名：$Path"
        return
    }
    if ($attempt -lt $attempts) {
        Start-Sleep -Seconds 31
    }
}
throw "签名失败：$Path"
