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

$script:CodeSigningOid = '1.3.6.1.5.5.7.3.3'

function Test-CanSignCode {
    # True when the certificate has a private key and allows code signing
    # (explicit Code Signing EKU, or no EKU extension at all = any purpose).
    param($Cert)
    if (-not $Cert -or -not $Cert.HasPrivateKey) { return $false }
    $eku = $Cert.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] }
    if (-not $eku) { return $true }
    return [bool]($eku.EnhancedKeyUsages | Where-Object { $_.Value -eq $script:CodeSigningOid })
}

function Get-StoreSigningCerts {
    # Code-signing certificates with a private key from the user and machine stores
    # (includes certificates on USB tokens / smart cards that Windows exposes there).
    $seen = @{}
    foreach ($loc in 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My') {
        Get-ChildItem $loc -ErrorAction SilentlyContinue | Where-Object {
            $_.NotAfter -gt (Get-Date) -and $_.NotBefore -lt (Get-Date) -and (Test-CanSignCode $_)
        } | ForEach-Object {
            if (-not $seen.ContainsKey($_.Thumbprint)) { $seen[$_.Thumbprint] = $true; $_ }
        }
    }
}

function Import-PfxForSigning {
    # Loads a .pfx/.p12 for this session only (nothing is installed into the certificate store).
    param([string]$Path, [System.Security.SecureString]$Password)
    $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet
    $col = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $col.Import($Path, (New-Object System.Net.NetworkCredential('', $Password)).Password, $flags)
    $cert = $col | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
    if (-not $cert) { throw 'The file does not contain a private key.' }
    if (-not (Test-CanSignCode $cert)) { throw 'This certificate is not allowed to sign code (no Code Signing usage).' }
    if ($cert.NotAfter -lt (Get-Date)) { throw ('This certificate expired on ' + $cert.NotAfter.ToString('dd/MM/yyyy')) }
    return $cert
}

function Find-PrivateKeyFile {
    # Looks for a PEM private key next to a .cer/.crt (same base name, .key / .pem / -key.pem)
    param([string]$CertPath)
    $dir = Split-Path $CertPath
    $base = [IO.Path]::GetFileNameWithoutExtension($CertPath)
    foreach ($n in "$base.key", "$base.pem", "$base-key.pem", "$base.key.pem", "$base.private.key") {
        $p = Join-Path $dir $n
        if ((Test-Path -LiteralPath $p) -and ([IO.Path]::GetFullPath($p) -ne [IO.Path]::GetFullPath($CertPath))) {
            if ((Get-Content -LiteralPath $p -Raw) -match 'PRIVATE KEY-----') { return $p }
        }
    }
    return $null
}

function Merge-CertAndKeyWithPwsh {
    # Windows PowerShell 5.1 (.NET Framework) cannot read PEM private keys; PowerShell 7 can.
    param([string]$CertPath, [string]$KeyPath, [System.Security.SecureString]$Password)
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) {
        throw ('Reading a PEM private key needs PowerShell 7 (winget install Microsoft.PowerShell), ' +
               'or convert it to PFX: openssl pkcs12 -export -in cert.crt -inkey cert.key -out cert.pfx')
    }
    $plain = (New-Object System.Net.NetworkCredential('', $Password)).Password
    $tmpPw = [guid]::NewGuid().ToString('N')
    $script = @'
$ErrorActionPreference = 'Stop'
try {
    $c = $env:ES_CERT; $k = $env:ES_KEY; $p = $env:ES_PASS
    $keyText = [IO.File]::ReadAllText($k)
    if (-not $p -and $keyText -match 'ENCRYPTED PRIVATE KEY|Proc-Type: 4,ENCRYPTED') { [Console]::Out.WriteLine('ERR:KEY_ENCRYPTED'); exit 3 }
    $certText = $null
    try { $certText = [IO.File]::ReadAllText($c) } catch { }
    $X = [Security.Cryptography.X509Certificates.X509Certificate2]
    $cert = if ($certText -match 'BEGIN CERTIFICATE') { $X::CreateFromPem($certText) } else { $X::new([IO.File]::ReadAllBytes($c)) }
    $isEc = $cert.PublicKey.Oid.Value -eq '1.2.840.10045.2.1'
    $key = if ($isEc) { [Security.Cryptography.ECDsa]::Create() } else { [Security.Cryptography.RSA]::Create() }
    if ($p) { $key.ImportFromEncryptedPem($keyText, $p) } else { $key.ImportFromPem($keyText) }
    $withKey = if ($isEc) { [Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::CopyWithPrivateKey($cert, $key) }
               else { [Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($cert, $key) }
    [Console]::Out.WriteLine('OK:' + [Convert]::ToBase64String($withKey.Export('Pfx', $env:ES_TMP)))
} catch {
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    [Console]::Out.WriteLine('ERR:' + $e.Message); exit 2
}
'@
    $env:ES_CERT = $CertPath; $env:ES_KEY = $KeyPath; $env:ES_PASS = $plain; $env:ES_TMP = $tmpPw
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $out = @(& $pwsh -NoProfile -NonInteractive -EncodedCommand $enc 2>$null) | ForEach-Object { [string]$_ }
        $ok = $out | Where-Object { $_ -like 'OK:*' } | Select-Object -Last 1
        if (-not $ok) {
            $msg = (($out | Where-Object { $_ -like 'ERR:*' } | Select-Object -Last 1) -replace '^ERR:', '')
            if (-not $msg) { $msg = ($out -join ' ').Trim() }
            if ($msg -match 'KEY_ENCRYPTED') { throw 'The private key is encrypted: type its password and load the file again.' }
            if ($msg -match 'does not match') { throw 'The private key does not belong to this certificate.' }
            if ($msg -match 'password|decrypt|padding|PKCS') { throw 'Wrong password for the encrypted private key.' }
            throw ('Could not combine the certificate and key: ' + $msg)
        }
        $bytes = [Convert]::FromBase64String($ok.Substring(3).Trim())
    } finally {
        $ErrorActionPreference = $oldEap
        Remove-Item Env:ES_CERT, Env:ES_KEY, Env:ES_PASS, Env:ES_TMP -ErrorAction SilentlyContinue
    }
    $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet
    return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes, $tmpPw, $flags)
}

function Import-CertFileForSigning {
    # Loads a certificate for signing from .pfx/.p12, or from .cer/.crt/.pem.
    # A .cer/.crt holds only the public certificate, so the private key is found by:
    #   1. the same certificate already installed with its key (store, USB token)
    #   2. a pending certificate request created on this PC (certreq -accept binds it)
    #   3. a PEM key file (given, inside the same .pem, or next to the certificate)
    param([string]$Path, [System.Security.SecureString]$Password, [string]$KeyPath, [scriptblock]$Log = { param($m) })
    if (-not $Password) { $Password = New-Object System.Security.SecureString }
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -in '.pfx', '.p12') { return (Import-PfxForSigning -Path $Path -Password $Password) }

    $text = $null
    try { $text = [IO.File]::ReadAllText($Path) } catch { }
    if ($text -and $text -match 'BEGIN CERTIFICATE') {
        $m = [regex]::Match($text, '-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----', 'Singleline')
        $pub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, [Convert]::FromBase64String(($m.Groups[1].Value -replace '\s', '')))
    } else {
        $pub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, [IO.File]::ReadAllBytes($Path))
    }
    & $Log ("Certificate file: " + $pub.Subject + " (" + $pub.Thumbprint + ")")
    if ($pub.NotAfter -lt (Get-Date)) { throw ('This certificate expired on ' + $pub.NotAfter.ToString('dd/MM/yyyy')) }
    if (-not (Test-CanSignCode ([pscustomobject]@{ HasPrivateKey = $true; Extensions = $pub.Extensions }))) {
        throw 'This certificate is not allowed to sign code (no Code Signing usage).'
    }

    # 1. already installed together with its private key?
    foreach ($loc in 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My') {
        $hit = Get-ChildItem $loc -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $pub.Thumbprint -and $_.HasPrivateKey } | Select-Object -First 1
        if ($hit) { & $Log "Found the matching private key in $loc"; return $hit }
    }

    # 2. issued for a request (CSR) that was created on this PC?
    $pubKey = [Convert]::ToBase64String($pub.PublicKey.EncodedKeyValue.RawData)
    foreach ($scope in @(@{ Loc = 'Cert:\CurrentUser\REQUEST'; Arg = '-user' }, @{ Loc = 'Cert:\LocalMachine\REQUEST'; Arg = '-machine' })) {
        $req = Get-ChildItem $scope.Loc -ErrorAction SilentlyContinue |
            Where-Object { [Convert]::ToBase64String($_.PublicKey.EncodedKeyValue.RawData) -eq $pubKey } | Select-Object -First 1
        if ($req) {
            & $Log ("Found the pending request for this certificate; installing it with certreq -accept " + $scope.Arg)
            $null = & certreq.exe -q -accept $scope.Arg $Path 2>&1
            $my = $scope.Loc -replace 'REQUEST$', 'My'
            $hit = Get-ChildItem $my -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $pub.Thumbprint -and $_.HasPrivateKey } | Select-Object -First 1
            if ($hit) { return $hit }
        }
    }

    # 3. PEM private key
    if (-not $KeyPath -and $text -match 'PRIVATE KEY-----') { $KeyPath = $Path }
    if (-not $KeyPath) { $KeyPath = Find-PrivateKeyFile $Path }
    if ($KeyPath) {
        & $Log ("Using private key file " + $KeyPath)
        $cert = Merge-CertAndKeyWithPwsh -CertPath $Path -KeyPath $KeyPath -Password $Password
        if ($cert.Thumbprint -ne $pub.Thumbprint) { throw 'The private key does not belong to this certificate.' }
        return $cert
    }

    $e = New-Object System.InvalidOperationException ('NEEDS_KEY: ' + $pub.Subject)
    $e.Data['NeedsKey'] = $true
    throw $e
}

function Get-CertDisplayName {
    param($Cert)
    $cn = if ($Cert.Subject -match 'CN=("[^"]+"|[^,]+)') { $Matches[1].Trim('"') } else { $Cert.Subject }
    return $cn
}

function Get-CertIssuerName {
    param($Cert)
    if ($Cert.Issuer -eq $Cert.Subject) { return 'self-signed' }
    if ($Cert.Issuer -match 'CN=("[^"]+"|[^,]+)') { return $Matches[1].Trim('"') }
    return $Cert.Issuer
}

function Test-CertChainTrusted {
    param($Cert)
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = 'NoCheck'
    $null = $chain.ChainPolicy.ApplicationPolicy.Add((New-Object System.Security.Cryptography.Oid $script:CodeSigningOid))
    return $chain.Build($Cert)
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
    $ver = try { [System.Diagnostics.FileVersionInfo]::GetVersionInfo($item.FullName) } catch { $null }
    $sig = Get-AuthenticodeSignature -LiteralPath $item.FullName
    $hash = try { (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash } catch { $null }
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
        ProductName   = if ($ver) { $ver.ProductName } else { $null }
        CompanyName   = if ($ver) { $ver.CompanyName } else { $null }
        FileVersion   = if ($ver) { $ver.FileVersion } else { $null }
        Description   = if ($ver) { $ver.FileDescription } else { $null }
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

function Get-PeNormalizedHash {
    # SHA-256 of the PE "content": everything except the three parts signing changes -
    # the optional-header checksum, the certificate-table data-directory entry, and the
    # appended signature block. Two builds of the same program give the same value whether
    # or not they are signed, so it tells code-identity apart from the signature.
    param([string]$Path)
    # shared read so a file another process holds open (a running installer, AV scan) does not abort us
    $fsIn = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $bytes = New-Object byte[] $fsIn.Length
        $off = 0
        while ($off -lt $bytes.Length) { $n = $fsIn.Read($bytes, $off, $bytes.Length - $off); if ($n -le 0) { break }; $off += $n }
    } finally { $fsIn.Dispose() }
    if ($bytes.Length -lt 64) { return $null }
    $ms = New-Object IO.MemoryStream (, $bytes)
    $br = New-Object IO.BinaryReader $ms
    try {
        if ($br.ReadUInt16() -ne 0x5A4D) { return $null }      # MZ
        $ms.Position = 0x3C
        $peOff = $br.ReadInt32()
        if ($peOff -le 0 -or $peOff + 24 -gt $bytes.Length) { return $null }
        $ms.Position = $peOff
        if ($br.ReadUInt32() -ne 0x00004550) { return $null }  # PE\0\0
        $ms.Position += 16                                     # COFF header after Signature
        $optStart = $ms.Position + 4                           # skip OptionalHeaderSize + Characteristics (2+2)
        $ms.Position = $optStart
        $magic = $br.ReadUInt16()
        if ($magic -ne 0x10b -and $magic -ne 0x20b) { return $null }
        $checksumOff = $optStart + 64
        $ddStart = if ($magic -eq 0x20b) { $optStart + 112 } else { $optStart + 96 }
        $certDirOff = $ddStart + 4 * 8                          # data directory index 4 = Certificate Table
        if ($certDirOff + 8 -gt $bytes.Length) { return $null }
        $ms.Position = $certDirOff
        $certRva = $br.ReadUInt32()
        $certSize = $br.ReadUInt32()
    } finally { $ms.Dispose() }

    $copy = New-Object byte[] $bytes.Length
    [Array]::Copy($bytes, $copy, $bytes.Length)
    for ($i = 0; $i -lt 4; $i++) { $copy[$checksumOff + $i] = 0 }   # zero checksum
    for ($i = 0; $i -lt 8; $i++) { $copy[$certDirOff + $i] = 0 }    # zero cert-table dir entry

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        if ($certSize -gt 0 -and $certRva -gt 0 -and ($certRva + $certSize) -le $copy.Length) {
            # hash the bytes before the signature block and any bytes after it
            $null = $sha.TransformBlock($copy, 0, $certRva, $null, 0)
            $tail = $copy.Length - ($certRva + $certSize)
            if ($tail -gt 0) { $null = $sha.TransformBlock($copy, $certRva + $certSize, $tail, $null, 0) }
            $null = $sha.TransformFinalBlock(@(), 0, 0)
            $hash = $sha.Hash
        } else {
            $hash = $sha.ComputeHash($copy)
        }
    } finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Get-CrossCheck {
    # Cross-check a signed EXE against the original unsigned EXE: are they the same program,
    # with only a signature added? Order-independent - each file is classified by its own signature.
    param([string]$PathA, [string]$PathB)
    $ra = Get-ExeReport $PathA
    $rb = Get-ExeReport $PathB
    # the "signed" slot is whichever file actually carries an embedded signature
    $aEmbedded = ($ra.Signer -and $ra.SigType -ne 'Catalog')
    $bEmbedded = ($rb.Signer -and $rb.SigType -ne 'Catalog')
    if ($bEmbedded -and -not $aEmbedded) { $signed = $rb; $unsigned = $ra }
    else { $signed = $ra; $unsigned = $rb }

    $hs = Get-PeNormalizedHash $signed.Path
    $hu = Get-PeNormalizedHash $unsigned.Path
    $bothPe = $signed.Pe.IsPe -and $unsigned.Pe.IsPe
    $codeMatches = $bothPe -and $hs -and $hu -and ($hs -eq $hu)

    $verdict = 'mismatch'; $level = 'bad'
    if (-not $bothPe) { $verdict = 'notpe'; $level = 'bad' }
    elseif ($signed.Path -eq $unsigned.Path) { $verdict = 'samefile'; $level = 'warn' }
    elseif (-not ($signed.Signer -and $signed.SigType -ne 'Catalog')) { $verdict = 'nosigned'; $level = 'warn' }
    elseif ($codeMatches) {
        if ($signed.SigStatus -eq 'Valid') { $verdict = 'match-valid'; $level = 'ok' }
        else { $verdict = 'match-untrusted'; $level = 'warn' }
    }

    [pscustomobject]@{
        Signed = $signed; Unsigned = $unsigned
        SignedNormHash = $hs; UnsignedNormHash = $hu
        CodeMatches = $codeMatches
        BothArePe = $bothPe
        UnsignedAlsoSigned = ($unsigned.Signer -and $unsigned.SigType -ne 'Catalog')
        Verdict = $verdict
        Level = $level
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
