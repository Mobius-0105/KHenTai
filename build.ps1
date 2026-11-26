# 构建并按版本号命名产物
#
# 用法（在本目录下）：
#   pwsh -File build.ps1                      # 用环境变量里的 SDK / JDK
#   pwsh -File build.ps1 -Product default     # 真机/上架（runtimeOS=HarmonyOS）
#   pwsh -File build.ps1 -Sign                # 顺带在 DevEco 外部签名（需要 signingConfigs）
#
# 产物：dist/KHenTai-HarmonyOS-v<versionName>-<product>[-unsigned].hap
# 版本号来自 AppScope/app.json5，改版本只改那一处。

param(
    [string]$Product = "api26",
    [string]$Configuration = "debug",
    [switch]$Sign
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $root

# ---- 读版本号 ----
$appJson = Get-Content -Raw -Encoding UTF8 (Join-Path $root "AppScope\app.json5")
$versionName = "0.0.0"
$versionCode = "0"
if ($appJson -match '"versionName"\s*:\s*"([^"]+)"') { $versionName = $Matches[1] }
if ($appJson -match '"versionCode"\s*:\s*(\d+)') { $versionCode = $Matches[1] }

# ---- 定位 hvigorw ----
$hvigorw = $env:HVIGORW
if (-not $hvigorw) {
    $candidate = Join-Path $env:DEVECO_SDK_HOME "..\bin\hvigorw.bat"
    if (Test-Path $candidate) { $hvigorw = $candidate }
}
if (-not $hvigorw -or -not (Test-Path $hvigorw)) {
    throw "找不到 hvigorw：请设置环境变量 HVIGORW，或把 DEVECO_SDK_HOME 指向 <clt>/sdk"
}

Write-Host "== 构建 JHenTai v$versionName ($versionCode) / product=$Product / $Configuration" -ForegroundColor Cyan

$task = if ($Sign) { "assembleHap" } else { "assembleHap" }
& $hvigorw --mode module -p product=$Product -p module=entry@default `
    -p buildMode=$Configuration $task --no-daemon
if ($LASTEXITCODE -ne 0) { throw "hvigor 构建失败（exit $LASTEXITCODE）" }

# ---- 找产物并改名 ----
$outDir = Join-Path $root "entry\build\$Product\outputs\default"
$hap = Get-ChildItem -Path $outDir -Filter "*.hap" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $hap) { throw "没有找到 hap：$outDir" }

$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$suffix = if ($hap.Name -like "*unsigned*") { "-unsigned" } else { "" }
$target = Join-Path $dist ("KHenTai-HarmonyOS-v{0}-{1}{2}.hap" -f $versionName, $Product, $suffix)
Copy-Item -Path $hap.FullName -Destination $target -Force

$size = [math]::Round((Get-Item $target).Length / 1KB)
Write-Host ("== 完成：{0}（{1} KB）" -f $target, $size) -ForegroundColor Green
Write-Host "   版本：$versionName（versionCode $versionCode）"
if ($suffix -eq "-unsigned") {
    Write-Host "   未签名：真机安装请先在 DevEco 里配置签名（Project Structure → Signing Configs），" -ForegroundColor Yellow
    Write-Host "   或用 -Sign 走本工程的 signingConfigs。" -ForegroundColor Yellow
}
