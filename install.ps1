# Exe Signer installer
#   Install / update:  irm https://raw.githubusercontent.com/dor2500/exe-signer/main/install.ps1 | iex
#   Uninstall:         & ([scriptblock]::Create((irm https://raw.githubusercontent.com/dor2500/exe-signer/main/install.ps1))) -Uninstall
param([switch]$Uninstall, [switch]$NoLaunch)

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $repo = 'dor2500/exe-signer'
    $branch = 'main'
    $dest = Join-Path $env:LOCALAPPDATA 'ExeSigner'
    $startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Exe Signer.lnk'
    $desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Exe Signer.lnk'

    function Say([string]$m, [string]$c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }

    Write-Host ''
    Write-Host '  Exe Signer' -ForegroundColor Cyan

    if ($Uninstall) {
        foreach ($p in $startMenu, $desktop, $dest) { if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
        Say 'Removed the app and its shortcuts.' Green
        Say 'Certificates you created stay in your certificate store (certmgr.msc).'
        return
    }

    $tmp = Join-Path $env:TEMP ('exe-signer-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'app.zip'
        if ($env:EXESIGNER_ZIP) {
            Copy-Item $env:EXESIGNER_ZIP $zip    # local testing
        } else {
            Say 'Downloading...'
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest "https://github.com/$repo/archive/refs/heads/$branch.zip" -OutFile $zip -UseBasicParsing
        }
        Expand-Archive $zip (Join-Path $tmp 'x') -Force
        $src = Get-ChildItem (Join-Path $tmp 'x') -Recurse -Filter 'ExeSigner.ps1' | Select-Object -First 1
        if (-not $src) { throw 'ExeSigner.ps1 was not found in the download.' }

        Say "Installing to $dest ..."
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        New-Item -ItemType Directory $dest | Out-Null
        Copy-Item (Join-Path $src.DirectoryName '*') $dest -Recurse -Force
        Get-ChildItem $dest -Recurse -File | Unblock-File

        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $launchArgs = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $dest 'ExeSigner.ps1') + '"'
        $shell = New-Object -ComObject WScript.Shell
        foreach ($lnkPath in $startMenu, $desktop) {
            $lnk = $shell.CreateShortcut($lnkPath)
            $lnk.TargetPath = $ps
            $lnk.Arguments = $launchArgs
            $lnk.WorkingDirectory = $dest
            $lnk.IconLocation = (Join-Path $env:SystemRoot 'System32\certmgr.dll') + ',0'
            $lnk.Description = 'Inspect and sign EXE files'
            $lnk.Save()
        }
        Say 'Shortcuts added to the Start menu and the desktop.' Green

        if (-not $NoLaunch) {
            Start-Process $ps -ArgumentList $launchArgs -WorkingDirectory $dest
            Say 'Exe Signer is starting.' Green
        }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ''
}
