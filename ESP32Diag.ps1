<#
  ESP32 诊断工具 v3
  设计原则：以芯片启动日志为证据，得出可解释的结论；术语全部翻成人话。
  分层：L0 状态 / L1 环境 / L2 进程 / L3 采集与判定 / L4 界面
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ================= L0 状态 =================
$script:AppName = 'ESP32 诊断工具'
$script:AppVer  = '3.0'
$script:Esptool = ''
$script:Port    = ''
$script:Busy    = $false
$script:ArgText = (@($args) | ForEach-Object { [string]$_ }) -join ' '
$script:MonoOn  = $false
$script:MonoStop = $false
$script:Report  = ''

$script:CBg     = [System.Drawing.Color]::FromArgb(237, 242, 247)
$script:CCard   = [System.Drawing.Color]::White
$script:CText   = [System.Drawing.Color]::FromArgb(30, 41, 59)
$script:CMuted  = [System.Drawing.Color]::FromArgb(100, 116, 139)
$script:CAccent = [System.Drawing.Color]::FromArgb(37, 99, 235)
$script:COk     = [System.Drawing.Color]::FromArgb(21, 128, 61)
$script:CBad    = [System.Drawing.Color]::FromArgb(185, 28, 28)
$script:CWarn   = [System.Drawing.Color]::FromArgb(180, 83, 9)
$script:CLine   = [System.Drawing.Color]::FromArgb(226, 232, 240)

# 启动日志解码表
$script:BootMap = @{
    '0x13' = '正常启动（从 Flash 读程序）'
    '0x03' = '刷机模式（芯片在等电脑发程序）'
    '0x0b' = '刷机模式（SDIO 口）'
}
$script:RstMap = @{
    '0x1'  = '上电复位'
    '0x3'  = '软件复位'
    '0x4'  = '看门狗复位（程序卡死）'
    '0x5'  = '深睡眠唤醒'
    '0x6'  = 'SDIO 复位'
    '0x7'  = '任务看门狗复位'
    '0x8'  = '中断看门狗复位'
    '0x9'  = 'RTC 看门狗复位'
    '0x10' = 'RTC 看门狗 CPU 复位'
    '0x12' = '外部 CPU 复位'
    '0x13' = '电压跌落复位（供电不足）'
    '0x14' = 'RTC 复位'
}

if ($script:ArgText -match 'selftest') {
    $L = @()
    $L += 'selftest ' + (Get-Date).ToString('s')
    $L += 'psver=' + $PSVersionTable.PSVersion.ToString()
    try { $L += 'ports=' + (([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object) -join ',') } catch { $L += 'ports=ERR' }
    $L += 'boot0x13=' + $script:BootMap['0x13']
    $L += 'rst0x13=' + $script:RstMap['0x13']
    Set-Content -Path (Join-Path $env:TEMP 'esp32diag_selftest.log') -Value ($L -join "`r`n") -Encoding UTF8
    exit 0
}

# ================= L1 环境 =================
function Find-Esptool {
    $here = ''
    if ($PSScriptRoot) { $here = $PSScriptRoot }
    $cands = @()
    if ($here) { $cands += (Join-Path $here 'esptool.exe') }
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Arduino15\packages\esp32\tools\esptool_py'),
        (Join-Path $env:APPDATA      'Arduino15\packages\esp32\tools\esptool_py')
    )
    foreach ($r in $roots) {
        if (Test-Path $r) {
            $fs = Get-ChildItem -Path $r -Filter 'esptool.exe' -Recurse -ErrorAction SilentlyContinue |
                  Sort-Object FullName -Descending
            foreach ($f in $fs) { $cands += $f.FullName }
        }
    }
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return ''
}

function Get-PortList {
    $l = @()
    try { $l = [System.IO.Ports.SerialPort]::GetPortNames() } catch { }
    return ($l | Sort-Object -Unique)
}

# ================= L2 进程 =================
function Invoke-Esptool {
    param([string[]]$ArgList)
    if (-not $script:Esptool) { return @{ Code = 99; Text = '未找到 esptool' } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Esptool
    $parts = @()
    foreach ($a in $ArgList) {
        if ($a -match '[\s"]') { $parts += ('"' + ($a -replace '"', '\"') + '"') }
        else { $parts += $a }
    }
    $psi.Arguments = ($parts -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $oT = $proc.StandardOutput.ReadToEndAsync()
        $eT = $proc.StandardError.ReadToEndAsync()
        while (-not $proc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 40
        }
        $proc.WaitForExit()
        $txt = ''
        try { $txt = $oT.Result } catch { }
        try { $txt = $txt + $eT.Result } catch { }
        return @{ Code = $proc.ExitCode; Text = $txt }
    } catch {
        return @{ Code = 98; Text = $_.Exception.Message }
    } finally {
        $proc.Dispose()
    }
}

# ================= L3 采集与判定 =================
function Read-Raw {
    param($Sp, [int]$Ms)
    $buf = ''
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        try { $s = $Sp.ReadExisting(); if ($s) { $buf += $s } } catch { }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 15
    }
    return $buf
}

function Invoke-LineCapture {
    param([bool]$D, [bool]$R)
    $sp = New-Object System.IO.Ports.SerialPort($script:Port, 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
    $sp.ReadTimeout = 100
    $buf = ''
    try {
        $sp.Open()
        $sp.DiscardInBuffer()
        $sp.DtrEnable = $false
        $sp.RtsEnable = $false
        Start-Sleep -Milliseconds 120
        $sp.DiscardInBuffer()
        $sp.DtrEnable = $D
        $sp.RtsEnable = $R
        Start-Sleep -Milliseconds 150
        $sp.DtrEnable = $false
        $sp.RtsEnable = $false
        $buf = Read-Raw $sp 900
    } catch {
        $buf = '__ERR__' + $_.Exception.Message
    } finally {
        if ($sp.IsOpen) { $sp.Close() }
        $sp.Dispose()
    }
    return $buf
}

function Parse-BootLog {
    param([string]$Text)
    $r = New-Object PSObject -Property @{
        Bytes = 0; Rst = ''; RstDesc = ''; Boot = ''; BootDesc = ''
        Normal = $false; Download = $false; Panic = $false; Waiting = $false; Garbled = $false
    }
    if (-not $Text) { return $r }
    $r.Bytes = $Text.Length
    if ($Text -like '__ERR__*') { return $r }

    $m = [regex]::Match($Text, 'rst:0x([0-9a-fA-F]+)')
    if ($m.Success) {
        $r.Rst = '0x' + $m.Groups[1].Value.ToLower()
        if ($script:RstMap.ContainsKey($r.Rst)) { $r.RstDesc = $script:RstMap[$r.Rst] }
        else { $r.RstDesc = '未知复位原因' }
    }
    $m2 = [regex]::Match($Text, 'boot:0x([0-9a-fA-F]+)')
    if ($m2.Success) {
        $r.Boot = '0x' + $m2.Groups[1].Value.ToLower()
        if ($script:BootMap.ContainsKey($r.Boot)) { $r.BootDesc = $script:BootMap[$r.Boot] }
        else { $r.BootDesc = '未知启动方式' }
        if ($r.Boot -eq '0x13') { $r.Normal = $true }
        else { $r.Download = $true }
    }
    if ($Text -match 'waiting for download') { $r.Waiting = $true; $r.Download = $true }
    if ($Text -match 'Guru Meditation|abort\(\)|Backtrace') { $r.Panic = $true }

    $printable = ($Text -replace '[^\x20-\x7E\r\n]', '').Length
    if ($Text.Length -gt 0) {
        if (($printable / $Text.Length) -lt 0.7) { $r.Garbled = $true }
    }
    return $r
}

if ($script:ArgText -match 'parsetest') {
    $samples = @(
        @{ N = '正常启动'; T = 'ets Jun  8 2016 00:22:57' + "`r`n" + 'rst:0x1 (POWERON_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)' + "`r`n" + 'configsip: 0, SPIWP:0xee' },
        @{ N = '刷机模式'; T = 'rst:0x1 (POWERON_RESET),boot:0x03 (DOWNLOAD_BOOT(UART0/UART1/SDIO_REI_REO_V2))' + "`r`n" + 'waiting for download' },
        @{ N = '电压跌落'; T = 'rst:0x13 (RTCWDT_BROWN_OUT_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)' },
        @{ N = '崩溃回溯'; T = 'rst:0x3 (SW_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)' + "`r`n" + 'Guru Meditation Error: Core  0 panic''ed (LoadProhibited).' },
        @{ N = '全无输出'; T = '' }
    )
    $out = @()
    foreach ($s in $samples) {
        $p = Parse-BootLog $s.T
        $out += ('[' + $s.N + '] bytes=' + $p.Bytes + ' rst=' + $p.Rst + '(' + $p.RstDesc + ') boot=' + $p.Boot + ' normal=' + $p.Normal + ' download=' + $p.Download + ' panic=' + $p.Panic + ' waiting=' + $p.Waiting)
    }
    Set-Content -Path (Join-Path $env:TEMP 'esp32diag_parsetest.log') -Value ($out -join "`r`n") -Encoding UTF8
    exit 0
}

# ================= L4 界面 =================
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = $script:AppName
$form.ClientSize = New-Object System.Drawing.Size(940, 640)
$form.MinimumSize = New-Object System.Drawing.Size(880, 620)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $script:CBg
try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9) }
catch { $form.Font = New-Object System.Drawing.Font('Segoe UI', 9) }
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
if ($script:ArgText -match 'bigfont') {
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12)
}

$script:Fh = $form.Font.Height
if ($script:Fh -lt 14) { $script:Fh = 14 }
$goH    = [int]($script:Fh * 4.6)
$cardH  = [int]($script:Fh * 6.8)
$opBtnH = $script:Fh + 26
$labelH = $script:Fh + 12
$logH   = [int]($script:Fh * 10.4)

# ---- 顶栏 ----
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = [int]($script:Fh * 5.0)
$header.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($header)

$lineTop = New-Object System.Windows.Forms.Panel
$lineTop.Dock = 'Bottom'
$lineTop.Height = 1
$lineTop.BackColor = $script:CLine
$header.Controls.Add($lineTop)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'ESP32 诊断工具'
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(22, [int]($script:Fh * 0.8))
$lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $script:CText
$header.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = '插上板子，点「开始诊断」，下面会告诉你它到底哪里不对'
$lblSub.AutoSize = $true
$lblSub.Location = New-Object System.Drawing.Point(24, [int]($script:Fh * 2.9))
$lblSub.ForeColor = $script:CMuted
$header.Controls.Add($lblSub)

$portBar = New-Object System.Windows.Forms.FlowLayoutPanel
$portBar.Dock = 'Right'
$portBar.Width = 356
$portBar.FlowDirection = 'RightToLeft'
$portBar.WrapContents = $false
$portBar.Padding = New-Object System.Windows.Forms.Padding(0, [int]($script:Fh * 1.4), 18, 0)
$portBar.BackColor = [System.Drawing.Color]::White
$header.Controls.Add($portBar)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新'
$btnRefresh.Size = New-Object System.Drawing.Size(60, 30)
$btnRefresh.FlatStyle = 'Flat'
$btnRefresh.FlatAppearance.BorderColor = $script:CLine
$btnRefresh.BackColor = [System.Drawing.Color]::White
$btnRefresh.ForeColor = $script:CText
$portBar.Controls.Add($btnRefresh)

$cmbPort = New-Object System.Windows.Forms.ComboBox
$cmbPort.DropDownStyle = 'DropDownList'
$cmbPort.Size = New-Object System.Drawing.Size(140, 28)
$cmbPort.Margin = New-Object System.Windows.Forms.Padding(0, 1, 8, 0)
$portBar.Controls.Add($cmbPort)

$lblPortCap = New-Object System.Windows.Forms.Label
$lblPortCap.Text = '串口'
$lblPortCap.AutoSize = $true
$lblPortCap.ForeColor = $script:CMuted
$lblPortCap.Margin = New-Object System.Windows.Forms.Padding(0, 7, 8, 0)
$portBar.Controls.Add($lblPortCap)

# ---- 状态栏 ----
$status = New-Object System.Windows.Forms.StatusStrip
$status.BackColor = [System.Drawing.Color]::White
$status.SizingGrip = $false
$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatus.Text = '就绪'
$lblStatus.Spring = $true
$lblStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
[void]$status.Items.Add($lblStatus)
$pb = New-Object System.Windows.Forms.ToolStripProgressBar
$pb.Width = 150
$pb.Style = 'Blocks'
[void]$status.Items.Add($pb)
$form.Controls.Add($status)

# ---- 主体 ----
$body = New-Object System.Windows.Forms.TableLayoutPanel
$body.Dock = 'Fill'
$body.ColumnCount = 2
$body.RowCount = 2
$body.Padding = New-Object System.Windows.Forms.Padding(16, 14, 16, 8)
[void]$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 372)))
[void]$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $logH)))
$form.Controls.Add($body)
$body.BringToFront()

# 左列
$left = New-Object System.Windows.Forms.TableLayoutPanel
$left.Dock = 'Fill'
$left.ColumnCount = 1
$left.RowCount = 3
$script:Fh = $form.Font.Height
if ($script:Fh -lt 14) { $script:Fh = 14 }

[void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $goH)))
[void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $cardH)))
[void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$left.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
$body.Controls.Add($left, 0, 0)

$btnGo = New-Object System.Windows.Forms.Button
$btnGo.Text = '开始诊断'
$btnGo.Dock = 'Fill'
$btnGo.FlatStyle = 'Flat'
$btnGo.FlatAppearance.BorderSize = 0
$btnGo.BackColor = $script:CAccent
$btnGo.ForeColor = [System.Drawing.Color]::White
$btnGo.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
$btnGo.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$btnGo.Cursor = [System.Windows.Forms.Cursors]::Hand
$left.Controls.Add($btnGo, 0, 0)

$card = New-Object System.Windows.Forms.Panel
$card.Dock = 'Fill'
$card.BackColor = $script:CCard
$card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$left.Controls.Add($card, 0, 1)

$cardBar = New-Object System.Windows.Forms.Panel
$cardBar.Dock = 'Left'
$cardBar.Width = 4
$cardBar.BackColor = $script:CLine
$card.Controls.Add($cardBar)

$lblV = New-Object System.Windows.Forms.Label
$lblV.Text = '还没有诊断'
$lblV.Dock = 'Top'
$lblV.Height = [int]($script:Fh * 2.2)
$lblV.Padding = New-Object System.Windows.Forms.Padding(14, 10, 12, 0)
$lblV.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$lblV.ForeColor = $script:CText
$card.Controls.Add($lblV)

$lblVBody = New-Object System.Windows.Forms.Label
$lblVBody.Text = '点上面的按钮，我会先看电脑能不能跟芯片说上话，再看它每次开机说了什么。'
$lblVBody.Dock = 'Fill'
$lblVBody.Padding = New-Object System.Windows.Forms.Padding(14, 2, 12, 10)
$lblVBody.ForeColor = $script:CMuted
$card.Controls.Add($lblVBody)
$lblVBody.BringToFront()

$opsBox = New-Object System.Windows.Forms.Panel
$opsBox.Dock = 'Bottom'
$opsBox.Height = $labelH + 2 * $opBtnH + 14
$opsBox.Margin = New-Object System.Windows.Forms.Padding(0)
$left.Controls.Add($opsBox, 0, 2)

$lblOther = New-Object System.Windows.Forms.Label
$lblOther.Text = '其他操作'
$lblOther.Dock = 'Top'
$lblOther.Height = $labelH
$lblOther.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$lblOther.ForeColor = $script:CMuted
$opsBox.Controls.Add($lblOther)

$ops = New-Object System.Windows.Forms.TableLayoutPanel
$ops.Dock = 'Fill'
$ops.ColumnCount = 2
$ops.RowCount = 2
[void]$ops.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$ops.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$ops.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$ops.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$opsBox.Controls.Add($ops)
$ops.BringToFront()

function New-OpButton {
    param([string]$Text, [int]$Col, [int]$Row)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Dock = 'Fill'
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = $script:CLine
    $b.BackColor = [System.Drawing.Color]::White
    $b.ForeColor = $script:CText
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 6)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $ops.Controls.Add($b, $Col, $Row)
    return $b
}

$btnErase   = New-OpButton '清空芯片' 0 0
$btnFlash   = New-OpButton '刷程序' 1 0
$btnLoop    = New-OpButton '自检串口线' 0 1
$btnCopy    = New-OpButton '复制报告' 1 1

# 右列
$rightCard = New-Object System.Windows.Forms.Panel
$rightCard.Dock = 'Fill'
$rightCard.BackColor = $script:CCard
$rightCard.Padding = New-Object System.Windows.Forms.Padding(18, 12, 18, 12)
$rightCard.Margin = New-Object System.Windows.Forms.Padding(0)
$body.Controls.Add($rightCard, 1, 0)

$right = New-Object System.Windows.Forms.TableLayoutPanel
$right.Dock = 'Fill'
$right.BackColor = $script:CCard
$right.ColumnCount = 1
$right.RowCount = 2
[void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
[void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$rightCard.Controls.Add($right)

$lblEv = New-Object System.Windows.Forms.Label
$lblEv.Text = '检查过程'
$lblEv.Dock = 'Fill'
$lblEv.ForeColor = $script:CMuted
$lblEv.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$right.Controls.Add($lblEv, 0, 0)

$rtbEv = New-Object System.Windows.Forms.RichTextBox
$rtbEv.Dock = 'Fill'
$rtbEv.ReadOnly = $true
$rtbEv.BorderStyle = 'None'
$rtbEv.BackColor = $script:CCard
$rtbEv.ForeColor = $script:CText
$rtbEv.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$rtbEv.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$right.Controls.Add($rtbEv, 0, 1)

$logCard = New-Object System.Windows.Forms.Panel
$logCard.Dock = 'Fill'
$logCard.BackColor = $script:CCard
$logCard.Padding = New-Object System.Windows.Forms.Padding(18, 8, 18, 10)
$logCard.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
$body.Controls.Add($logCard, 0, 1)
$body.SetColumnSpan($logCard, 2)

$lblLogCap = New-Object System.Windows.Forms.Label
$lblLogCap.Text = '原始输出（给懂行的人看）'
$lblLogCap.Dock = 'Top'
$lblLogCap.Height = 24
$lblLogCap.ForeColor = $script:CMuted
$lblLogCap.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$logCard.Controls.Add($lblLogCap)

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Dock = 'Fill'
$rtbLog.ReadOnly = $true
$rtbLog.BorderStyle = 'None'
$rtbLog.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$rtbLog.ForeColor = $script:CMuted
$rtbLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$rtbLog.WordWrap = $false
$rtbLog.ScrollBars = 'Both'
$logCard.Controls.Add($rtbLog)
$rtbLog.BringToFront()

# ---- 渲染工具 ----
function Ev-Add {
    param([string]$Icon, [string]$Text, [string]$Detail = '', [string]$Color = 'text')
    $c = $script:CText
    if ($Color -eq 'ok') { $c = $script:COk }
    elseif ($Color -eq 'bad') { $c = $script:CBad }
    elseif ($Color -eq 'warn') { $c = $script:CWarn }
    elseif ($Color -eq 'muted') { $c = $script:CMuted }

    $rtbEv.SelectionStart = $rtbEv.TextLength
    $rtbEv.SelectionLength = 0
    $rtbEv.SelectionColor = $c
    $rtbEv.SelectionFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $rtbEv.AppendText($Icon + '  ' + $Text + "`r`n")

    if ($Detail) {
        $rtbEv.SelectionStart = $rtbEv.TextLength
        $rtbEv.SelectionColor = $script:CMuted
        $rtbEv.SelectionFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
        $rtbEv.AppendText('     ' + $Detail + "`r`n")
    }
    $rtbEv.SelectionFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $rtbEv.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Show-Placeholder {
    param([string]$Text)
    $rtbEv.SelectionStart = $rtbEv.TextLength
    $rtbEv.SelectionLength = 0
    $rtbEv.SelectionColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $rtbEv.SelectionFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    foreach ($ln in ($Text -split "`r?`n")) {
        $rtbEv.AppendText($ln + "`r`n")
    }
    $rtbEv.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Log-Raw {
    param([string]$Text)
    if (-not $Text) { return }
    $rtbLog.SelectionStart = $rtbLog.TextLength
    $rtbLog.SelectionColor = $script:CMuted
    $rtbLog.AppendText($Text + "`r`n")
    $rtbLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Verdict {
    param([string]$Title, [string]$Body, [string]$Level = 'info')
    $c = $script:CLine
    if ($Level -eq 'ok') { $c = $script:COk }
    elseif ($Level -eq 'bad') { $c = $script:CBad }
    elseif ($Level -eq 'warn') { $c = $script:CWarn }
    elseif ($Level -eq 'info') { $c = $script:CAccent }
    $cardBar.BackColor = $c
    $lblV.Text = $Title
    $lblV.ForeColor = $c
    $lblVBody.Text = $Body
    $script:Report = $Title + "`r`n" + $Body
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Busy {
    param([bool]$On, [string]$Msg = '')
    $script:Busy = $On
    $btnGo.Enabled = (-not $On)
    foreach ($b in @($btnErase, $btnFlash, $btnLoop, $btnCopy, $btnRefresh)) { $b.Enabled = (-not $On) }
    $cmbPort.Enabled = (-not $On)
    if ($On) {
        $pb.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $pb.MarqueeAnimationSpeed = 30
    } else {
        $pb.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
        $pb.Value = 0
    }
    if ($Msg) { $lblStatus.Text = $Msg }
    [System.Windows.Forms.Application]::DoEvents()
}

function Refresh-Ports {
    $ports = Get-PortList
    $cmbPort.Items.Clear()
    foreach ($p in $ports) { [void]$cmbPort.Items.Add($p) }
    if ($ports.Count -gt 0) {
        if ($script:Port -and ($ports -contains $script:Port)) { $cmbPort.SelectedItem = $script:Port }
        else { $cmbPort.SelectedIndex = 0; $script:Port = $ports[0] }
    } else {
        [void]$cmbPort.Items.Add('（未检测到）')
        $cmbPort.SelectedIndex = 0
        $script:Port = ''
    }
    return $ports.Count
}

# ================= 诊断主流程 =================
function Invoke-Diagnosis {
    $rtbEv.Clear()
    $rtbLog.Clear()
    $script:Report = ''
    Set-Verdict '正在诊断…' '正在检查串口、尝试与芯片建立连接、并读取它的启动日志。' 'info'

    if (-not $script:Port) {
        Ev-Add '✗' '没有找到任何串口' '电脑现在看不到板子。先插好 USB，再点右上角「刷新」。' 'bad'
        Set-Verdict '找不到板子' '电脑连一个串口都没识别到。先确认 USB 线插好、板子上的灯亮着，然后点右上角「刷新」。如果灯不亮，是供电问题。' 'bad'
        return
    }

    # 步骤 1：端口能否打开
    $sp = $null
    $openOk = $false
    $openErr = ''
    try {
        $sp = New-Object System.IO.Ports.SerialPort($script:Port, 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
        $sp.ReadTimeout = 100
        $sp.Open()
        $openOk = $true
    } catch {
        $openErr = $_.Exception.Message
    } finally {
        if ($sp) { if ($sp.IsOpen) { $sp.Close() }; $sp.Dispose() }
    }

    if ($openOk) {
        Ev-Add '✓' ('串口 ' + $script:Port + ' 能打开') '电脑这侧的串口驱动是好的。但要说明：这只证明 USB 转串口芯片活着，不代表主控芯片活着。' 'ok'
    } else {
        Ev-Add '✗' ('串口 ' + $script:Port + ' 打不开') $openErr 'bad'
        Set-Verdict '串口被占用' '另一个程序（Arduino IDE 的串口监视器、或其他烧录工具）正占着这个串口。把它们关掉再试。' 'bad'
        return
    }

    # 步骤 2：直接让 esptool 喊话
    Set-Busy $true '正在尝试与芯片建立连接…'
    $r1 = Invoke-Esptool -ArgList @('--port', $script:Port, '--before', 'default-reset', '--after', 'no-reset', '--connect-attempts', '2', 'chip-id')
    Log-Raw $r1.Text
    if ($r1.Code -eq 0) {
        Ev-Add '✓' '芯片应答了' '电脑发出的连接请求，芯片收到了并正确回复。' 'ok'
        foreach ($ln in ($r1.Text -split "`r?`n")) {
            if ($ln.Trim()) { Ev-Add '·' $ln.Trim() '' 'muted' }
        }
        Set-Verdict '一切正常' '电脑和芯片能正常对话，可以直接刷程序。如果 IDE 里失败，问题在 IDE 的板型或端口设置，不在硬件。' 'ok'
        Set-Busy $false '诊断完成'
        return
    }
    Ev-Add '✗' '芯片没有应答电脑' '电脑按标准时序喊了两次，芯片一声不吭。这一步失败有两种可能：它没进刷机模式，或者它的话传不回来。' 'bad'

    # 步骤 3：四组控制线组合，抓启动日志
    Set-Busy $true '正在逐组测试复位信号，并读取芯片开机日志…'
    $combos = @(
        @{ N = '都不拉'; D = $false; R = $false },
        @{ N = '只拉第二根'; D = $false; R = $true },
        @{ N = '只拉第一根'; D = $true;  R = $false },
        @{ N = '两根都拉'; D = $true;  R = $true }
    )
    $results = @()
    foreach ($c in $combos) {
        $raw = Invoke-LineCapture -D $c.D -R $c.R
        $p = Parse-BootLog $raw
        $p | Add-Member -NotePropertyName Combo -NotePropertyValue $c.N -Force
        $results += $p
        if ($p.Bytes -gt 0) { Log-Raw ('[' + $c.N + '] ' + ($raw -replace '[^\x20-\x7E\r\n]', '.')) }
    }

    $anyBytes = $results | Where-Object { $_.Bytes -gt 0 }
    $dl      = $results | Where-Object { $_.Download } | Select-Object -First 1
    $normal  = $results | Where-Object { $_.Normal } | Select-Object -First 1
    $brown   = $results | Where-Object { $_.Rst -eq '0x13' } | Select-Object -First 1
    $panic   = $results | Where-Object { $_.Panic } | Select-Object -First 1
    $garble  = $results | Where-Object { $_.Garbled } | Select-Object -First 1

    if ($anyBytes) {
        Ev-Add '✓' ('芯片说话了（收到 ' + $anyBytes[0].Bytes + ' 字节）') '芯片在运行，而且它说的话能传回电脑。这一条一旦成立，就可以排除「线断了」「芯片没电」这类猜测。' 'ok'
        $seen = @()
        foreach ($r0 in $anyBytes) {
            $t = '没有报告启动方式'
            if ($r0.BootDesc) { $t = $r0.BootDesc }
            if ($seen -contains $t) { continue }
            $seen += $t
            $d = ''
            if ($r0.RstDesc) { $d = '它说这次是「' + $r0.RstDesc + '」' }
            Ev-Add '·' $t $d 'muted'
        }
    } else {
        Ev-Add '✗' '芯片一句话都没说' '四组复位信号都试过，一个字节都没收到。芯片要么没在运行，要么它负责发送的那条线断了。' 'bad'
    }

    if ($garble) {
        Ev-Add '!' '收到的数据是乱码' '字节有，但不像正常文字。常见于波特率不对、晶振异常，或线路干扰严重。' 'warn'
    }

    # 结论
    Set-Busy $false '诊断完成'
    if ($dl) {
        Ev-Add '✓' '芯片确实进了刷机模式' '它明确报告自己正停在「等电脑发程序」的状态。' 'ok'
        Set-Verdict '卡在「收」的方向' '芯片已经在等电脑发程序，但电脑发的东西它收不到。问题出在板子上「电脑→芯片」这条接收线，而不是芯片本身。换一块板最省事；要修就得查那颗 USB 转串口芯片到主控之间的接收脚。' 'warn'
        return
    }
    if ($brown) {
        Ev-Add '!' '芯片反复因电压跌落而重启' ('复位原因报告为「' + $brown.RstDesc + '」。') 'warn'
        Set-Verdict '供电不足' '芯片每次刚启动就掉电重启，所以永远进不了刷机模式。换一个供电充足的 USB 口（不要用扩展坞），或换一根短一点的线。' 'warn'
        return
    }
    if ($panic) {
        Ev-Add '!' '芯片启动后崩溃了' '日志里有崩溃回溯。程序在跑，但每次都崩在同一个地方。' 'warn'
    }
    if ($normal) {
        Set-Verdict '进不去刷机模式' '芯片每次都在正常启动（从 Flash 读程序），从来没有进过刷机模式。也就是说，「让它进刷机模式」这根信号没送到——通常是 BOOT 按键、或按键到主控的那根线断了。临时办法：把主控的 IO0 脚直接接到 GND 再上电。' 'warn'
        return
    }
    if (-not $anyBytes) {
        Set-Verdict '芯片没有任何回应' '四组复位信号都试了，芯片一个字节都没发出来。两种可能：它根本没在运行（没供电或已损坏），或者它的发送脚断了。先做「自检串口线」：短接 TX0 和 RX0，如果自检能通过，说明问题在主控一侧，不是 USB 转串口芯片。' 'bad'
        return
    }

    Set-Verdict '情况不典型' '芯片有输出但不在上述任何一种模式里。请点「复制报告」，把内容发出来一起看。' 'warn'
}

# ================= 事件 =================
$btnGo.Add_Click({
    if ($script:Busy) { return }
    try { Invoke-Diagnosis }
    catch {
        Ev-Add '✗' '诊断过程出错' $_.Exception.Message 'bad'
        Set-Verdict '诊断中断' ('程序内部出错：' + $_.Exception.Message) 'bad'
    }
    finally { Set-Busy $false '诊断完成' }
})

$btnRefresh.Add_Click({
    $n = Refresh-Ports
    $lblStatus.Text = '找到 ' + $n + ' 个串口'
})

$cmbPort.Add_SelectedIndexChanged({
    if ($cmbPort.SelectedItem) {
        $v = [string]$cmbPort.SelectedItem
        if ($v.StartsWith('（')) { $script:Port = '' } else { $script:Port = $v }
    }
})

$btnCopy.Add_Click({
    $txt = $script:Report + "`r`n`r`n---- 检查过程 ----`r`n" + $rtbEv.Text + "`r`n---- 原始输出 ----`r`n" + $rtbLog.Text
    if ($txt.Trim()) {
        [System.Windows.Forms.Clipboard]::SetText($txt)
        $lblStatus.Text = '报告已复制到剪贴板'
    }
})

$btnErase.Add_Click({
    if (-not $script:Port) { return }
    $ans = [System.Windows.Forms.MessageBox]::Show(
        '这会清空芯片里的程序和 WiFi 设置，清完必须重新刷程序。' + "`r`n`r`n继续吗？",
        '清空芯片', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    Set-Busy $true '正在清空…'
    Log-Raw '> erase-flash'
    $r = Invoke-Esptool -ArgList @('--port', $script:Port, '--before', 'default-reset', '--after', 'hard-reset', 'erase-flash')
    Log-Raw $r.Text
    if ($r.Code -eq 0) {
        Ev-Add '✓' '清空完成' '回 Arduino IDE 重新上传程序即可。' 'ok'
        Set-Verdict '清空完成' '芯片已经空了，现在回 Arduino IDE 点上传。' 'ok'
    } else {
        Ev-Add '✗' '清空失败' '电脑没能让芯片进入刷机模式，先看上面的诊断结论。' 'bad'
    }
    Set-Busy $false '完成'
})

$btnFlash.Add_Click({
    if (-not $script:Port) { return }
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = '固件文件 (*.bin)|*.bin|所有文件 (*.*)|*.*'
    $dlg.Title = '选择要刷进去的 .bin'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    Set-Busy $true '正在刷写…'
    Log-Raw ('> write-flash 0x10000 ' + $dlg.FileName)
    $r = Invoke-Esptool -ArgList @('--port', $script:Port, '--before', 'default-reset', '--after', 'hard-reset',
                                   '--baud', '460800', 'write-flash', '0x10000', $dlg.FileName)
    Log-Raw $r.Text
    if ($r.Code -eq 0) {
        Ev-Add '✓' '刷写完成' '芯片已自动重启，开始运行新程序。' 'ok'
        Set-Verdict '刷写完成' '新程序已经写进去了，芯片正在运行它。' 'ok'
    } else {
        Ev-Add '✗' '刷写失败' '先看上面的诊断结论，多半是进不了刷机模式。' 'bad'
    }
    Set-Busy $false '完成'
})

$btnLoop.Add_Click({
    if (-not $script:Port) { return }
    $ans = [System.Windows.Forms.MessageBox]::Show(
        '请用一根线把板子上的 TX0 和 RX0 两个针脚连起来，然后点「是」。' + "`r`n`r`n" + '这一步是让电脑自己发、自己收，用来判断串口这条线本身好不好。',
        '自检串口线', 'YesNo', 'Information')
    if ($ans -ne 'Yes') { return }
    Set-Busy $true '正在自检…'
    $sp = $null
    $ok = $false
    $back = ''
    try {
        $sp = New-Object System.IO.Ports.SerialPort($script:Port, 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
        $sp.ReadTimeout = 300
        $sp.Open()
        $sp.DiscardInBuffer()
        $sp.Write('ESP32_LOOPBACK_12345')
        Start-Sleep -Milliseconds 300
        $back = $sp.ReadExisting()
        if ($back -and $back.Contains('ESP32_LOOPBACK')) { $ok = $true }
    } catch {
        $back = $_.Exception.Message
    } finally {
        if ($sp) { if ($sp.IsOpen) { $sp.Close() }; $sp.Dispose() }
    }
    Log-Raw ('> loopback: ' + $back)
    if ($ok) {
        Ev-Add '✓' '串口线自检通过' '电脑发出去的字，绕一圈原样收回来了。说明 USB 转串口芯片和线路都正常，问题在主控那边。' 'ok'
        Set-Verdict '线是好的' '串口线路没问题，所以故障在主控芯片或它旁边的焊点。' 'ok'
    } else {
        Ev-Add '✗' '串口线自检没通过' ('回读到的内容：' + $back) 'bad'
        Set-Verdict '线本身有问题' '短接之后电脑仍收不到自己发的字，说明 USB 转串口芯片坏了，或驱动异常。这与主控芯片无关，换一根 USB 转串口线/换块板即可。' 'bad'
    }
    Set-Busy $false '完成'
})

$form.Add_FormClosing({ $script:MonoStop = $true })

# ================= 启动 =================
$script:Esptool = Find-Esptool
[void](Refresh-Ports)

if (-not $script:Esptool) {
    Set-Verdict '缺少 esptool' '程序需要 esptool 才能跟芯片对话，但没找到它。把 esptool.exe 放到本程序同目录，或安装 ESP32 开发板支持包后重启本工具。' 'bad'
    Show-Placeholder '缺少 esptool.exe，无法开始检查。'
} else {
    $ver = Split-Path -Leaf (Split-Path -Parent $script:Esptool)
    Log-Raw ('esptool: ' + $ver)
    if (-not $script:Port) {
        Set-Verdict '还没看到板子' '电脑现在没有识别到任何串口。插好 USB 后点右上角「刷新」，再点「开始诊断」。' 'info'
        $hint = "插上板子后点「开始诊断」，我会按顺序查三件事：`r`n"
        $hint += '    一、电脑和板子之间的串口通不通'
        $hint += "`r`n    二、芯片会不会回应电脑的呼叫"
        $hint += "`r`n    三、芯片每次开机自己说了什么（最关键的一条）"
        Show-Placeholder $hint
    } else {
        Set-Verdict '准备就绪' ('已经看到 ' + $script:Port + '。点「开始诊断」，我会先看电脑能不能跟芯片说上话，再读它每次开机说的话。') 'info'
        Show-Placeholder '点「开始诊断」，这里会逐条列出检查结果，最后给出一句结论。'
    }
}

if ($script:ArgText -match 'uitest') {
    $form.Show()
    Start-Sleep -Milliseconds 400
    $u = @()
    $u += 'uitest ' + (Get-Date).ToString('s')
    $u += 'client=' + $form.ClientSize.Width + 'x' + $form.ClientSize.Height
    $u += 'port=' + $script:Port
    $u += 'ops=' + $ops.Controls.Count
    $u += 'verdict=' + $lblV.Text
    $u += 'evlen=' + $rtbEv.TextLength
    $u += 'loglen=' + $rtbLog.TextLength
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $img = Join-Path $env:TEMP 'esp32diag_render.png'
    $bmp.Save($img, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $u += 'render=' + $img
    Set-Content -Path (Join-Path $env:TEMP 'esp32diag_uitest.log') -Value ($u -join "`r`n") -Encoding UTF8
    $form.Hide()
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
$form.Dispose()
