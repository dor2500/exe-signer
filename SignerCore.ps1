# SignerCore.ps1 - analysis and Authenticode signing logic for Exe Signer.
# Works on Windows PowerShell 5.1 (and PowerShell 7 on Windows).

foreach ($m in 'Microsoft.PowerShell.Security', 'PKI') {
    if (-not (Get-Module $m)) { try { Import-Module $m -ErrorAction Stop 2>$null } catch { } }
}

$script:DefaultTimestampServers = @(
    'http://timestamp.digicert.com',
    'http://timestamp.sectigo.com',
    'http://timestamp.globalsign.com/tsa/r6advanced1'
)

function Get-SignerSubject {
    param([string]$PublisherName)
    $name = ($PublisherName -replace '[,=+<>#;"\\]', ' ').Trim()
    if (-not $name) { $name = 'Exe Signer Self-Signed' }
    return "CN=$name, O=$name"
}

function Get-SignerCert {
    param([string]$PublisherName)
    $subject = Get-SignerSubject $PublisherName
    Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(1) -and
            ($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' })
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
}

function New-SignerCert {
    param([string]$PublisherName)
    $subject = Get-SignerSubject $PublisherName
    New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
        -CertStoreLocation Cert:\CurrentUser\My `
        -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
        -KeyExportPolicy Exportable `
        -NotAfter (Get-Date).AddYears(5) `
        -FriendlyName "Exe Signer - $PublisherName"
}

function Get-OrCreateSignerCert {
    param([string]$PublisherName)
    $c = Get-SignerCert $PublisherName
    if ($c) { return $c }
    return New-SignerCert $PublisherName
}

function Test-CertTrustedLocally {
    param($Cert)
    if (-not $Cert) { return $false }
    $inRoot = Test-Path ("Cert:\CurrentUser\Root\" + $Cert.Thumbprint)
    $inPub  = Test-Path ("Cert:\CurrentUser\TrustedPublisher\" + $Cert.Thumbprint)
    return ($inRoot -and $inPub)
}

function Install-SignerTrust {
    # Adds the public part of the cert to the current user's Root and TrustedPublisher stores.
    # Windows shows its own security confirmation dialog for the Root store.
    param($Cert)
    $public = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, $Cert.RawData)
    foreach ($storeName in @('Root', 'TrustedPublisher')) {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store ($storeName, 'CurrentUser')
        $store.Open('ReadWrite')
        try { $store.Add($public) } finally { $store.Close() }
    }
    return (Test-CertTrustedLocally $Cert)
}

function Export-SignerCert {
    param($Cert, [string]$Path)
    [System.IO.File]::WriteAllBytes($Path, $Cert.Export('Cert'))
}

function Read-PeInfo {
    param([string]$Path)
    $r = [ordered]@{ IsPe = $false }
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $br = New-Object System.IO.BinaryReader $fs
        if ($fs.Length -lt 64) { $r.Error = 'File is too small'; return $r }
        if ($br.ReadUInt16() -ne 0x5A4D) { $r.Error = 'No MZ header'; return $r }
        $fs.Position = 0x3C
        $peOff = $br.ReadInt32()
        if ($peOff -le 0 -or $peOff + 24 -gt $fs.Length) { $r.Error = 'Invalid PE offset'; return $r }
        $fs.Position = $peOff
        if ($br.ReadUInt32() -ne 0x00004550) { $r.Error = 'No PE signature'; return $r }
        $machine = $br.ReadUInt16()
        $sections = $br.ReadUInt16()
        $timeStamp = $br.ReadUInt32()
        $null = $br.ReadUInt32(); $null = $br.ReadUInt32()
        $optSize = $br.ReadUInt16()
        $characteristics = $br.ReadUInt16()
        $optStart = $fs.Position
        $magic = $br.ReadUInt16()
        $r.IsPe = $true
        $r.Machine = switch ($machine) {
            0x014c { 'x86 (32-bit)' } 0x8664 { 'x64 (64-bit)' } 0xAA64 { 'ARM64' } 0x01c4 { 'ARM' }
            default { ('0x{0:X4}' -f $machine) }
        }
        $r.Format = switch ($magic) { 0x10b { 'PE32' } 0x20b { 'PE32+' } default { ('0x{0:X}' -f $magic) } }
        $r.Sections = $sections
        $r.LinkTime = ([datetime]'1970-01-01Z').ToUniversalTime().AddSeconds($timeStamp)
        $r.IsDll = (($characteristics -band 0x2000) -ne 0)
        $fs.Position = $optStart + 68
        $subsystem = $br.ReadUInt16()
        $r.Subsystem = switch ($subsystem) { 2 { 'GUI' } 3 { 'Console' } 1 { 'Native' } default { "$subsystem" } }
        $ddStart = if ($magic -eq 0x20b) { $optStart + 112 } else { $optStart + 96 }
        $fs.Position = $ddStart - 4
        $ddCount = $br.ReadUInt32()
        $dd = @{}
        for ($i = 0; $i -lt [Math]::Min($ddCount, 16); $i++) {
            $dd[$i] = @($br.ReadUInt32(), $br.ReadUInt32())
        }
        $r.HasSignatureBlock = ($dd.ContainsKey(4) -and $dd[4][1] -gt 0)
        $r.IsDotNet = ($dd.ContainsKey(14) -and $dd[14][1] -gt 0)
        # Data appended after the signature block (overlay) is a common reason signing breaks installers.
        if ($r.HasSignatureBlock) {
            $r.SignatureEndsAtEof = (($dd[4][0] + $dd[4][1]) -ge $fs.Length)
        }
    } finally { $fs.Dispose() }
    return $r
}

function Get-ExeReport {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path
    $pe = Read-PeInfo $Path
    $ver = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($item.FullName)
    $sig = Get-AuthenticodeSignature -LiteralPath $item.FullName
    $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    $zone = $null
    try { $zone = Get-Content -LiteralPath $item.FullName -Stream Zone.Identifier -ErrorAction Stop } catch { }
    $zoneId = $null
    if ($zone) { $m = ($zone | Select-String 'ZoneId=(\d)'); if ($m) { $zoneId = [int]$m.Matches[0].Groups[1].Value } }

    [pscustomobject]@{
        Path          = $item.FullName
        Name          = $item.Name
        SizeBytes     = $item.Length
        Sha256        = $hash
        Pe            = $pe
        ProductName   = $ver.ProductName
        CompanyName   = $ver.CompanyName
        FileVersion   = $ver.FileVersion
        Description   = $ver.FileDescription
        SigStatus     = [string]$sig.Status
        SigType       = [string]$sig.SignatureType
        SigMessage    = $sig.StatusMessage
        Signer        = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null }
        SignerThumb   = if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { $null }
        Timestamped   = [bool]$sig.TimeStamperCertificate
        FromInternet  = ($zoneId -ge 3)
        ZoneId        = $zoneId
    }
}

function Invoke-SignExe {
    # Signs a copy of $InputPath at $OutputPath. The original file is never modified.
    param(
        [string]$InputPath,
        [string]$OutputPath,
        $Cert,
        [bool]$UseTimestamp = $true,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    if ((Resolve-Path -LiteralPath $InputPath).Path -ne [System.IO.Path]::GetFullPath($OutputPath)) {
        Copy-Item -LiteralPath $InputPath -Destination $OutputPath -Force
    }
    $f = Get-Item -LiteralPath $OutputPath
    if ($f.IsReadOnly) { $f.IsReadOnly = $false }

    # Success = the file now carries an embedded Authenticode signature made by our certificate.
    # (Catalog-signed system files report the catalog signer, so check the embedded one explicitly.)
    $isOurs = {
        $s = Get-AuthenticodeSignature -LiteralPath $OutputPath
        ([string]$s.SignatureType -eq 'Authenticode') -and $s.SignerCertificate -and
            ($s.SignerCertificate.Thumbprint -eq $Cert.Thumbprint) -and ([string]$s.Status -ne 'HashMismatch')
    }

    $servers = if ($UseTimestamp) { $script:DefaultTimestampServers } else { @() }
    foreach ($ts in $servers) {
        & $Log "Signing with timestamp server $ts ..."
        try {
            $null = Set-AuthenticodeSignature -LiteralPath $OutputPath -Certificate $Cert -HashAlgorithm SHA256 -TimestampServer $ts -ErrorAction Stop
            if (& $isOurs) { & $Log '  signed + timestamped'; return (Get-AuthenticodeSignature -LiteralPath $OutputPath) }
            & $Log '  timestamp server did not respond correctly, trying the next one'
        } catch {
            & $Log ("  failed: " + $_.Exception.Message)
        }
    }
    & $Log 'Signing without a timestamp ...'
    $null = Set-AuthenticodeSignature -LiteralPath $OutputPath -Certificate $Cert -HashAlgorithm SHA256 -ErrorAction Stop
    if (-not (& $isOurs)) { throw 'Signing failed: the file does not contain the new signature (unsupported file type?)' }
    return (Get-AuthenticodeSignature -LiteralPath $OutputPath)
}
