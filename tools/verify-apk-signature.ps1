# verify-apk-signature.ps1
#
# 用途：装任何 APK 之前，先确认它是「你自己那把钥匙」签的。
# 只认下面这个指纹，别的签名一律判为不一致（官方原版蜜蜂记账也是"不一致"，
# 因为它用作者的钥匙签，装进去会覆盖/替换你的账本）。
#
# 用法（Windows PowerShell）：
#   .\tools\verify-apk-signature.ps1 -Apk "C:\Users\me\Downloads\app-arm64-v8a-prod-release.apk"
#
# 退出码：0 = 指纹一致（可装）；1 = 签名无效/读取失败；2 = 指纹不一致（别装）
#
# 非 Windows 环境可用等价命令：
#   apksigner verify --print-certs app.apk | grep 'SHA-256 digest'

param(
    [Parameter(Mandatory = $true, HelpMessage = "要检查的 APK 路径")]
    [string]$Apk
)

$ErrorActionPreference = 'Stop'

# 本仓库 CI 使用的签名证书指纹（CN=BeeCount AutoBill）
# 换钥匙时必须同步改这里，以及 .github/workflows/sync-upstream-build.yml 里的 EXPECTED_SIGNER_SHA256
$expected = '2e7bce613ecbbc46afc640f8b26755992ce91e52ce2ff1de6dc4cf4527ebdc2c'

if (-not (Test-Path $Apk)) { throw "找不到文件：$Apk" }

$sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $env:ANDROID_HOME }
if (-not $sdk) { throw "没有 ANDROID_HOME / ANDROID_SDK_ROOT，找不到 apksigner" }

$signer = Get-ChildItem (Join-Path $sdk 'build-tools') -Directory |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'apksigner.bat' } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

if (-not $signer) { throw "build-tools 里没有 apksigner，检查 Android SDK" }

Write-Host "-> 检查: $Apk" -ForegroundColor Cyan
$out = & $signer verify --print-certs $Apk 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "x 签名无效（可能被篡改或未签名），不要安装" -ForegroundColor Red
    $out | Select-Object -First 5
    exit 1
}

$line = $out | Select-String 'SHA-256 digest' | Select-Object -First 1
$actual = ($line.Line -replace '.*digest:\s*', '').Trim()

Write-Host ""
Write-Host "期望指纹: $expected"
Write-Host "实际指纹: $actual"
Write-Host ""

if ($actual -eq $expected) {
    Write-Host "OK 指纹一致，是你自己的构建，可以安装" -ForegroundColor Green
    exit 0
}

Write-Host "x 指纹不一致！这个包不是你的钥匙签的，绝对不要装" -ForegroundColor Red
exit 2
