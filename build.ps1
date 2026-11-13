<#
  把 ESP32Diag.ps1 打包成单文件 exe
  需要 ps2exe：Install-Module ps2exe -Scope CurrentUser
#>
param(
    [string]$Output = 'ESP32诊断工具.exe'
)

$ErrorActionPreference = 'Stop'

# ps2exe 常装在 PowerShell 7 下。当前宿主找不到就切到 pwsh 重跑，
# 否则 5.1 会弹 NuGet 安装向导卡住。
if (-not (Get-Module -ListAvailable ps2exe)) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh -and $PSVersionTable.PSEdition -eq 'Desktop') {
        Write-Host '当前是 Windows PowerShell，改用 pwsh 运行...' -ForegroundColor Yellow
        & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Output $Output
        exit $LASTEXITCODE
    }
    throw '未找到 ps2exe。请先运行：Install-Module ps2exe -Scope CurrentUser'
}

Import-Module ps2exe

$src = Join-Path $PSScriptRoot 'ESP32Diag.ps1'
$dst = Join-Path $PSScriptRoot $Output

if (-not (Test-Path $src)) { throw "找不到源文件: $src" }

# 脚本含中文，必须是 UTF-8 BOM，否则 5.1 下乱码
$content = Get-Content -Path $src -Raw -Encoding UTF8
Set-Content -Path $src -Value $content -Encoding utf8BOM -NoNewline

Invoke-PS2EXE -inputFile $src -outputFile $dst `
    -noConsole -STA -DPIAware `
    -title 'ESP32 诊断工具' `
    -description 'ESP32 启动日志诊断工具' `
    -version '3.1.0.0'

$f = Get-Item $dst
Write-Host ('已生成 {0}  ({1:N1} KB)' -f $f.Name, ($f.Length / 1KB)) -ForegroundColor Green
