<#
  把 ESP32Diag.ps1 打包成单文件 exe
  依赖：Install-Module ps2exe -Scope CurrentUser
#>
param(
    [string]$Output = 'ESP32诊断工具.exe'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host '未找到 ps2exe，正在安装...' -ForegroundColor Yellow
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe

$src = Join-Path $PSScriptRoot 'ESP32Diag.ps1'
$dst = Join-Path $PSScriptRoot $Output

if (-not (Test-Path $src)) { throw "找不到源文件: $src" }

# ps2exe 在 PowerShell 5.1 下运行最稳，脚本含中文，必须 UTF-8 BOM
$content = Get-Content -Path $src -Raw -Encoding UTF8
Set-Content -Path $src -Value $content -Encoding utf8BOM -NoNewline

Invoke-PS2EXE -inputFile $src -outputFile $dst `
    -noConsole -STA -DPIAware `
    -title 'ESP32 诊断工具' `
    -description 'ESP32 启动日志诊断工具' `
    -version '3.1.0.0'

$f = Get-Item $dst
Write-Host ('已生成 {0}  ({1:N1} KB)' -f $f.Name, ($f.Length / 1KB)) -ForegroundColor Green
