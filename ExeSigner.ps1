# ExeSigner.ps1 - desktop app: drop an EXE, inspect it, sign it with an auto-created code-signing certificate.
param([string]$InitialFile)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot 'SignerCore.ps1')

$settingsPath = Join-Path $env:APPDATA 'ExeSigner\settings.json'
$settings = @{ Publisher = $env:USERNAME; Timestamp = $true }
try {
    if (Test-Path $settingsPath) {
        $s = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($s.Publisher) { $settings.Publisher = $s.Publisher }
        if ($null -ne $s.Timestamp) { $settings.Timestamp = [bool]$s.Timestamp }
    }
} catch { }
function Save-Settings {
    try {
        $dir = Split-Path $settingsPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
        @{ Publisher = $txtPublisher.Text; Timestamp = $chkTs.Checked } | ConvertTo-Json | Set-Content $settingsPath -Encoding UTF8
    } catch { }
}

$font = New-Object System.Drawing.Font('Segoe UI', 10)
$fontBold = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Exe Signer - בדיקה וחתימה דיגיטלית לקבצי EXE'
$form.Size = New-Object System.Drawing.Size(900, 760)
$form.MinimumSize = New-Object System.Drawing.Size(760, 640)
$form.StartPosition = 'CenterScreen'
$form.RightToLeft = 'Yes'
$form.RightToLeftLayout = $true
$form.Font = $font
$form.AllowDrop = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

# --- drop zone --------------------------------------------------------------
$drop = New-Object System.Windows.Forms.Label
$drop.Text = "גרור לכאן קובץ EXE / DLL / MSI`nאו לחץ כאן כדי לבחור קובץ"
$drop.TextAlign = 'MiddleCenter'
$drop.Font = $fontBold
$drop.BorderStyle = 'FixedSingle'
$drop.BackColor = [System.Drawing.Color]::White
$drop.ForeColor = [System.Drawing.Color]::FromArgb(40, 70, 140)
$drop.Cursor = 'Hand'
$drop.Location = New-Object System.Drawing.Point(12, 12)
$drop.Size = New-Object System.Drawing.Size(860, 80)
$drop.Anchor = 'Top, Left, Right'
$drop.AllowDrop = $true
$form.Controls.Add($drop)

# --- report -----------------------------------------------------------------
$lv = New-Object System.Windows.Forms.ListView
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.GridLines = $true
$lv.HeaderStyle = 'Nonclickable'
$lv.Location = New-Object System.Drawing.Point(12, 102)
$lv.Size = New-Object System.Drawing.Size(860, 300)
$lv.Anchor = 'Top, Left, Right, Bottom'
$lv.RightToLeftLayout = $true
[void]$lv.Columns.Add('בדיקה', 200)
[void]$lv.Columns.Add('תוצאה', 640)
$form.Controls.Add($lv)

# --- certificate box --------------------------------------------------------
$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = 'תעודת חתימה (נוצרת אוטומטית)'
$grp.Location = New-Object System.Drawing.Point(12, 410)
$grp.Size = New-Object System.Drawing.Size(860, 120)
$grp.Anchor = 'Bottom, Left, Right'
$form.Controls.Add($grp)

$lblPub = New-Object System.Windows.Forms.Label
$lblPub.Text = 'שם המפרסם:'
$lblPub.Location = New-Object System.Drawing.Point(10, 28)
$lblPub.AutoSize = $true
$grp.Controls.Add($lblPub)

$txtPublisher = New-Object System.Windows.Forms.TextBox
$txtPublisher.Text = $settings.Publisher
$txtPublisher.Location = New-Object System.Drawing.Point(110, 25)
$txtPublisher.Size = New-Object System.Drawing.Size(260, 25)
$txtPublisher.RightToLeft = 'No'
$grp.Controls.Add($txtPublisher)

$chkTs = New-Object System.Windows.Forms.CheckBox
$chkTs.Text = 'הוסף חותמת זמן (החתימה תישאר תקפה גם אחרי שהתעודה פגה)'
$chkTs.Checked = $settings.Timestamp
$chkTs.Location = New-Object System.Drawing.Point(390, 26)
$chkTs.AutoSize = $true
$grp.Controls.Add($chkTs)

$lblCert = New-Object System.Windows.Forms.Label
$lblCert.Location = New-Object System.Drawing.Point(10, 58)
$lblCert.Size = New-Object System.Drawing.Size(840, 22)
$grp.Controls.Add($lblCert)

$btnTrust = New-Object System.Windows.Forms.Button
$btnTrust.Text = 'סמוך על התעודה במחשב הזה'
$btnTrust.Location = New-Object System.Drawing.Point(10, 84)
$btnTrust.Size = New-Object System.Drawing.Size(230, 28)
$grp.Controls.Add($btnTrust)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = 'ייצא תעודה (.cer) למחשבים אחרים'
$btnExport.Location = New-Object System.Drawing.Point(250, 84)
$btnExport.Size = New-Object System.Drawing.Size(260, 28)
$grp.Controls.Add($btnExport)

# --- actions ----------------------------------------------------------------
$btnSign = New-Object System.Windows.Forms.Button
$btnSign.Text = 'חתום על הקובץ'
$btnSign.Font = $fontBold
$btnSign.BackColor = [System.Drawing.Color]::FromArgb(40, 110, 220)
$btnSign.ForeColor = [System.Drawing.Color]::White
$btnSign.FlatStyle = 'Flat'
$btnSign.Location = New-Object System.Drawing.Point(12, 538)
$btnSign.Size = New-Object System.Drawing.Size(200, 40)
$btnSign.Anchor = 'Bottom, Left'
$btnSign.Enabled = $false
$form.Controls.Add($btnSign)

$chkOverwrite = New-Object System.Windows.Forms.CheckBox
$chkOverwrite.Text = 'חתום על הקובץ המקורי (במקום ליצור עותק -signed)'
$chkOverwrite.Location = New-Object System.Drawing.Point(222, 548)
$chkOverwrite.AutoSize = $true
$chkOverwrite.Anchor = 'Bottom, Left'
$form.Controls.Add($chkOverwrite)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = 'פתח תיקייה'
$btnOpen.Location = New-Object System.Drawing.Point(752, 538)
$btnOpen.Size = New-Object System.Drawing.Size(120, 40)
$btnOpen.Anchor = 'Bottom, Right'
$btnOpen.Enabled = $false
$form.Controls.Add($btnOpen)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.RightToLeft = 'No'
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.Location = New-Object System.Drawing.Point(12, 586)
$log.Size = New-Object System.Drawing.Size(860, 125)
$log.Anchor = 'Bottom, Left, Right'
$form.Controls.Add($log)

# --- state & helpers --------------------------------------------------------
$script:CurrentFile = $null
$script:LastOutput = $null

function Write-Log([string]$m) {
    $log.AppendText(("[{0:HH:mm:ss}] {1}`r`n" -f (Get-Date), $m))
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-Row([string]$k, [string]$v, [string]$level = 'info') {
    $it = New-Object System.Windows.Forms.ListViewItem $k
    [void]$it.SubItems.Add($v)
    switch ($level) {
        'ok'   { $it.ForeColor = [System.Drawing.Color]::FromArgb(20, 130, 50) }
        'warn' { $it.ForeColor = [System.Drawing.Color]::FromArgb(190, 110, 0) }
        'bad'  { $it.ForeColor = [System.Drawing.Color]::FromArgb(190, 30, 30) }
    }
    [void]$lv.Items.Add($it)
}

function Update-CertLabel {
    $c = Get-SignerCert $txtPublisher.Text
    if (-not $c) {
        $lblCert.Text = 'עדיין אין תעודה לשם הזה - היא תיווצר אוטומטית בחתימה הראשונה.'
        $lblCert.ForeColor = [System.Drawing.Color]::DimGray
        $btnExport.Enabled = $false; $btnTrust.Enabled = $false
        return
    }
    $trusted = Test-CertTrustedLocally $c
    $t = if ($trusted) { 'מאושרת במחשב הזה' } else { 'לא מאושרת עדיין במחשב הזה' }
    $lblCert.Text = ('תעודה: {0}  |  בתוקף עד {1:dd/MM/yyyy}  |  {2}  |  {3}' -f $c.Subject, $c.NotAfter, $c.Thumbprint.Substring(0, 12), $t)
    $lblCert.ForeColor = if ($trusted) { [System.Drawing.Color]::FromArgb(20, 130, 50) } else { [System.Drawing.Color]::FromArgb(190, 110, 0) }
    $btnExport.Enabled = $true
    $btnTrust.Enabled = -not $trusted
}

function Show-Report([string]$path) {
    $lv.Items.Clear()
    try { $r = Get-ExeReport $path } catch { Add-Row 'שגיאה' $_.Exception.Message 'bad'; return $null }
    Add-Row 'קובץ' $r.Path
    Add-Row 'גודל' ('{0:N0} בתים ({1:N2} MB)' -f $r.SizeBytes, ($r.SizeBytes / 1MB))
    Add-Row 'SHA-256' $r.Sha256
    if ($r.Pe.IsPe) {
        $kind = if ($r.Pe.IsDll) { 'DLL' } else { 'EXE' }
        $net = if ($r.Pe.IsDotNet) { ' | .NET' } else { '' }
        Add-Row 'מבנה PE' ('{0} תקין | {1} | {2} | {3}{4}' -f $kind, $r.Pe.Format, $r.Pe.Machine, $r.Pe.Subsystem, $net) 'ok'
        Add-Row 'תאריך קומפילציה' ('{0:dd/MM/yyyy HH:mm} UTC' -f $r.Pe.LinkTime)
        if ($r.Pe.HasSignatureBlock -and $r.Pe.SignatureEndsAtEof -eq $false) {
            Add-Row 'אזהרה' 'יש נתונים אחרי בלוק החתימה (overlay). חתימה מחדש עלולה לשבור את הקובץ.' 'warn'
        }
    } elseif ($r.Path -match '\.(msi|ps1|cab|cat|msix|appx)$') {
        Add-Row 'מבנה' 'לא PE - קובץ מסוג שתומך בחתימת Authenticode' 'info'
    } else {
        Add-Row 'מבנה PE' ('לא תקין: ' + $r.Pe.Error) 'bad'
    }
    if ($r.ProductName) { Add-Row 'מוצר' $r.ProductName }
    if ($r.CompanyName) { Add-Row 'חברה' $r.CompanyName }
    if ($r.FileVersion) { Add-Row 'גרסה' $r.FileVersion }
    if ($r.Description) { Add-Row 'תיאור' $r.Description }

    switch ($r.SigStatus) {
        'Valid'        { Add-Row 'חתימה דיגיטלית' 'חתום ותקף' 'ok' }
        'NotSigned'    { Add-Row 'חתימה דיגיטלית' 'לא חתום' 'warn' }
        'UnknownError' {
            if ($r.Signer) { Add-Row 'חתימה דיגיטלית' 'חתום, אבל התעודה לא מאושרת במחשב הזה (תעודה עצמית)' 'warn' }
            else { Add-Row 'חתימה דיגיטלית' $r.SigMessage 'bad' }
        }
        'HashMismatch' { Add-Row 'חתימה דיגיטלית' 'הקובץ שונה אחרי שנחתם - החתימה שבורה!' 'bad' }
        default        { Add-Row 'חתימה דיגיטלית' ($r.SigStatus + ': ' + $r.SigMessage) 'bad' }
    }
    if ($r.Signer) {
        Add-Row 'חותם' $r.Signer
        if ($r.SigType -eq 'Catalog') { Add-Row 'סוג חתימה' 'Catalog - חתימה דרך קטלוג של Windows (לא מוטמעת בקובץ)' }
        elseif ($r.SigType) { Add-Row 'סוג חתימה' 'Authenticode - מוטמעת בקובץ' }
        $tsText = if ($r.Timestamped) { 'יש' } else { 'אין' }
        Add-Row 'חותמת זמן' $tsText
    }
    if ($r.FromInternet) { Add-Row 'מקור' 'הקובץ הורד מהאינטרנט (Mark of the Web)' 'warn' }
    return $r
}

function Open-File([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    $script:CurrentFile = (Resolve-Path -LiteralPath $path).Path
    $script:LastOutput = $null
    $btnOpen.Enabled = $false
    Write-Log ("Loaded " + $script:CurrentFile)
    $r = Show-Report $script:CurrentFile
    $btnSign.Enabled = [bool]$r
    if ($r -and $r.Signer -and $r.SigStatus -eq 'Valid') {
        Write-Log 'Note: this file already has a valid signature. Signing again replaces it.'
    }
}

# --- events -----------------------------------------------------------------
$dragEnter = { param($s, $e) if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = 'Copy' } }
$dragDrop  = { param($s, $e) $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop); if ($files) { Open-File $files[0] } }
$form.Add_DragEnter($dragEnter); $form.Add_DragDrop($dragDrop)
$drop.Add_DragEnter($dragEnter); $drop.Add_DragDrop($dragDrop)
$lv.AllowDrop = $true; $lv.Add_DragEnter($dragEnter); $lv.Add_DragDrop($dragDrop)

$drop.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'קבצי הפעלה (*.exe;*.dll;*.msi;*.sys)|*.exe;*.dll;*.msi;*.sys|כל הקבצים (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') { Open-File $dlg.FileName }
})

$txtPublisher.Add_Leave({ Update-CertLabel; Save-Settings })
$chkTs.Add_CheckedChanged({ Save-Settings })

$btnSign.Add_Click({
    if (-not $script:CurrentFile) { return }
    $btnSign.Enabled = $false
    $form.Cursor = 'WaitCursor'
    try {
        $pub = $txtPublisher.Text.Trim()
        if (-not $pub) { $pub = $env:USERNAME; $txtPublisher.Text = $pub }
        Save-Settings
        $cert = Get-SignerCert $pub
        if (-not $cert) {
            Write-Log "Creating a new code-signing certificate for '$pub' ..."
            $cert = New-SignerCert $pub
            Write-Log ("Certificate created: " + $cert.Thumbprint)
        }
        if ($chkOverwrite.Checked) {
            $out = $script:CurrentFile
        } else {
            $dir = Split-Path $script:CurrentFile
            $base = [System.IO.Path]::GetFileNameWithoutExtension($script:CurrentFile)
            $ext = [System.IO.Path]::GetExtension($script:CurrentFile)
            $out = Join-Path $dir ($base + '-signed' + $ext)
        }
        $res = Invoke-SignExe -InputPath $script:CurrentFile -OutputPath $out -Cert $cert -UseTimestamp $chkTs.Checked -Log { param($m) Write-Log $m }
        Write-Log ("Signed: " + $out)
        $script:LastOutput = $out
        $btnOpen.Enabled = $true
        [void](Show-Report $out)
        Update-CertLabel
        [System.Windows.Forms.MessageBox]::Show("הקובץ נחתם בהצלחה:`n$out", 'Exe Signer', 'OK', 'Information') | Out-Null
    } catch {
        Write-Log ("ERROR: " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show("החתימה נכשלה:`n" + $_.Exception.Message, 'Exe Signer', 'OK', 'Error') | Out-Null
    } finally {
        $form.Cursor = 'Default'
        $btnSign.Enabled = $true
    }
})

$btnTrust.Add_Click({
    $c = Get-SignerCert $txtPublisher.Text
    if (-not $c) { return }
    $msg = "התעודה תתווסף לרשימת התעודות המהימנות של המשתמש שלך במחשב הזה בלבד.`nWindows יציג חלון אישור אבטחה - יש לאשר בו 'Yes'.`n`nלהמשיך?"
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Exe Signer', 'YesNo', 'Question') -ne 'Yes') { return }
    try {
        $ok = Install-SignerTrust $c
        if ($ok) { Write-Log 'Certificate is now trusted for this user on this PC.' } else { Write-Log 'Certificate was not added (confirmation declined?).' }
    } catch { Write-Log ("ERROR: " + $_.Exception.Message) }
    Update-CertLabel
    if ($script:LastOutput) { [void](Show-Report $script:LastOutput) } elseif ($script:CurrentFile) { [void](Show-Report $script:CurrentFile) }
})

$btnExport.Add_Click({
    $c = Get-SignerCert $txtPublisher.Text
    if (-not $c) { return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Certificate (*.cer)|*.cer'
    $dlg.FileName = ($txtPublisher.Text.Trim() -replace '[\\/:*?"<>|]', '_') + '-codesign.cer'
    if ($dlg.ShowDialog() -eq 'OK') {
        Export-SignerCert $c $dlg.FileName
        Write-Log ("Exported public certificate to " + $dlg.FileName)
        Write-Log 'On another PC: double-click the .cer > Install Certificate > Local Machine > "Trusted Root Certification Authorities", and again for "Trusted Publishers".'
    }
})

$btnOpen.Add_Click({ if ($script:LastOutput) { Start-Process explorer.exe "/select,`"$($script:LastOutput)`"" } })

$form.Add_Shown({
    Update-CertLabel
    Write-Log 'Ready. Drop an EXE to inspect it.'
    if ($InitialFile) { Open-File $InitialFile }
})

[void]$form.ShowDialog()
