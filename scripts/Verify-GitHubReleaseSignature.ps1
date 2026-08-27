param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,
    [switch]$AllowPortableExecutable
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true

. (Join-Path $PSScriptRoot "Trusted-WindowsSdkTool.ps1")

if (-not $IsWindows) { throw "GitHub release signature verification must run on Windows." }
$allowedReleaseExtensions = @(".exe", ".msix", ".appx")
$allowedSignerNames = @("LAI ZEYU", "来泽宇")
$codeSigningOid = "1.3.6.1.5.5.7.3.3"
$timeStampingOid = "1.3.6.1.5.5.7.3.8"
$sha256Oid = "2.16.840.1.101.3.4.2.1"
$rfc3161AttributeOids = @(
    "1.2.840.113549.1.9.16.2.14", # id-aa-signatureTimeStampToken
    "1.3.6.1.4.1.311.3.3.1"      # Microsoft SPC_RFC3161_OBJID wrapper
)

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Security.Cryptography.Pkcs

function Assert-SignToolOutputPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$CompactOutput,
        [Parameter(Mandatory = $true)][string]$VerboseOutput,
        [Parameter(Mandatory = $true)][string]$BinaryPath
    )
    $signatureRows = [regex]::Matches(
        $CompactOutput,
        '(?im)^\s*(?<index>\d+)\s+(?<algorithm>sha(?:1|256|384|512))\s+(?<timestamp>\S+)\s*$'
    )
    if ($signatureRows.Count -ne 1 -or
        $signatureRows[0].Groups['index'].Value -cne '0' -or
        $signatureRows[0].Groups['algorithm'].Value.ToLowerInvariant() -cne 'sha256' -or
        $signatureRows[0].Groups['timestamp'].Value.ToUpperInvariant() -cne 'RFC3161') {
        throw "Binary must contain exactly one SHA-256 signature with an RFC 3161 timestamp: $BinaryPath"
    }
    $signatureIndexes = [regex]::Matches($VerboseOutput, '(?im)^\s*Signature Index:\s*(?<index>\d+)(?:\s|$)')
    if ($signatureIndexes.Count -ne 1 -or $signatureIndexes[0].Groups['index'].Value -cne '0') {
        throw "SignTool did not prove exactly one embedded signature: $BinaryPath"
    }
    $fileHashes = [regex]::Matches(
        $VerboseOutput,
        '(?im)^\s*Hash of file \((?<algorithm>[^)]+)\):\s*[0-9a-f]{64}\s*$'
    )
    if ($fileHashes.Count -ne 1 -or $fileHashes[0].Groups['algorithm'].Value.ToLowerInvariant() -cne 'sha256') {
        throw "SignTool did not prove exactly one SHA-256 file digest: $BinaryPath"
    }
    if ([regex]::Matches(
            $VerboseOutput,
            '(?im)^\s*Number of (?:files|signatures) successfully Verified:\s*1\s*$'
        ).Count -ne 1 -or
        $VerboseOutput -notmatch '(?im)^\s*Number of warnings:\s*0\s*$' -or
        $VerboseOutput -notmatch '(?im)^\s*Number of errors:\s*0\s*$') {
        throw "SignTool did not return one warning-free successful verification: $BinaryPath"
    }
}

function Invoke-BoundedSignToolVerify {
    param([string]$SignToolPath, [string]$BinaryPath, [switch]$Verbose)
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('verify', '/pa', '/all', '/tw')) { $arguments.Add($argument) }
    if ($Verbose) { $arguments.Add('/v') }
    $arguments.Add($BinaryPath)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $SignToolPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "SignTool verification did not start: $BinaryPath" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(180000)) {
            try { $process.Kill($true) } catch { throw "SignTool timeout tree kill failed: $BinaryPath" }
            if (-not $process.WaitForExit(30000)) { throw "SignTool remained alive after timeout: $BinaryPath" }
            throw "SignTool verification exceeded 180 seconds: $BinaryPath"
        }
        $output = $stdout.GetAwaiter().GetResult() + [Environment]::NewLine + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "SignTool rejected '$BinaryPath' with exit code $($process.ExitCode)." }
        return $output
    } finally { $process.Dispose() }
}

function Get-PortableExecutableSignatureBlob {
    param([Parameter(Mandatory = $true)][string]$FilePath)
    $stream = [IO.File]::Open($FilePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 256 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw "File is not a Portable Executable."
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset + 256 -gt $stream.Length) { throw "PE header offset is invalid." }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "PE signature is missing." }
        $optionalHeader = $peOffset + 24
        $stream.Position = $optionalHeader
        $magic = $reader.ReadUInt16()
        $dataDirectoryOffset = switch ($magic) {
            0x10B { $optionalHeader + 96 }
            0x20B { $optionalHeader + 112 }
            default { throw "Unsupported PE optional-header magic 0x$($magic.ToString('X'))." }
        }
        $stream.Position = $dataDirectoryOffset + (4 * 8)
        $certificateOffset = [int64]$reader.ReadUInt32()
        $certificateTableSize = [int64]$reader.ReadUInt32()
        if ($certificateOffset -le 0 -or $certificateTableSize -lt 8 -or
            $certificateOffset + $certificateTableSize -gt $stream.Length) {
            throw "PE Authenticode certificate table is absent or out of bounds."
        }
        $stream.Position = $certificateOffset
        $certificateLength = [int64]$reader.ReadUInt32()
        $revision = $reader.ReadUInt16()
        $certificateType = $reader.ReadUInt16()
        if ($certificateLength -lt 8 -or $certificateLength -gt $certificateTableSize -or
            $certificateType -ne 2 -or $revision -notin @(0x0100, 0x0200)) {
            throw "PE WIN_CERTIFICATE metadata is invalid or is not PKCS#7."
        }
        $alignedCertificateLength = ($certificateLength + 7) -band (-bnot 7)
        if ($alignedCertificateLength -ne $certificateTableSize) {
            throw "PE certificate table must contain exactly one aligned WIN_CERTIFICATE entry."
        }
        return $reader.ReadBytes([int]($certificateLength - 8))
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-AppPackageSignatureBlob {
    param([Parameter(Mandatory = $true)][string]$FilePath)
    $archive = [IO.Compression.ZipFile]::OpenRead($FilePath)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -ceq "AppxSignature.p7x" })
        if ($entries.Count -ne 1 -or $entries[0].Length -lt 8 -or $entries[0].Length -gt 16MB) {
            throw "App package must contain one bounded AppxSignature.p7x entry."
        }
        $source = $entries[0].Open()
        $memory = [IO.MemoryStream]::new()
        try { $source.CopyTo($memory) } finally { $source.Dispose() }
        $bytes = $memory.ToArray()
        $memory.Dispose()
        if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne "PKCX") {
            throw "AppxSignature.p7x is missing its PKCX header."
        }
        $pkcs7 = [byte[]]::new($bytes.Length - 4)
        [Array]::Copy($bytes, 4, $pkcs7, 0, $pkcs7.Length)
        return $pkcs7
    } finally {
        $archive.Dispose()
    }
}

function Get-MsixManifestPublisher {
    param([Parameter(Mandatory = $true)][string]$FilePath)
    $archive = [IO.Compression.ZipFile]::OpenRead($FilePath)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -ceq "AppxManifest.xml" })
        if ($entries.Count -ne 1 -or $entries[0].Length -le 0 -or $entries[0].Length -gt 4MB) {
            throw "App package must contain one bounded AppxManifest.xml."
        }
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $source = $entries[0].Open()
        $reader = [Xml.XmlReader]::Create($source, $settings)
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        try { $document.Load($reader) } finally { $reader.Dispose(); $source.Dispose() }
        $manager = [Xml.XmlNamespaceManager]::new($document.NameTable)
        $manager.AddNamespace("appx", $document.DocumentElement.NamespaceURI)
        $identity = $document.SelectSingleNode("/appx:Package/appx:Identity", $manager)
        $publisher = if ($identity) { [string]$identity.Attributes["Publisher"].Value } else { "" }
        if ([string]::IsNullOrWhiteSpace($publisher)) { throw "AppxManifest Identity Publisher is missing." }
        return $publisher
    } finally {
        $archive.Dispose()
    }
}

function Assert-Rfc3161Timestamp {
    param([Parameter(Mandatory = $true)][string]$FilePath, [Parameter(Mandatory = $true)][string]$Extension)
    $blob = if ($Extension -in @(".msix", ".appx")) {
        Get-AppPackageSignatureBlob -FilePath $FilePath
    } else {
        Get-PortableExecutableSignatureBlob -FilePath $FilePath
    }
    $cms = [Security.Cryptography.Pkcs.SignedCms]::new()
    $cms.Decode($blob)
    if ($cms.SignerInfos.Count -ne 1) {
        throw "Trusted GitHub binary must contain exactly one primary Authenticode signer."
    }
    if ($cms.SignerInfos[0].DigestAlgorithm.Value -cne $sha256Oid) {
        throw "Trusted GitHub binary primary signature is not SHA-256."
    }
    $unsignedOids = @($cms.SignerInfos[0].UnsignedAttributes | ForEach-Object { $_.Oid.Value })
    if (@($unsignedOids | Where-Object { $rfc3161AttributeOids -ccontains $_ }).Count -eq 0) {
        throw "Trusted GitHub binary does not contain an RFC 3161 timestamp-token attribute."
    }
}

function Assert-OnlineCertificateChain {
    param(
        [Parameter(Mandatory = $true)]$Certificate,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$FileName
    )
    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $chain.ChainPolicy.RevocationFlag = [Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
        $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(60)
        if (-not $chain.Build($Certificate)) {
            $statuses = @($chain.ChainStatus | ForEach-Object { $_.Status.ToString() }) -join ", "
            throw "GitHub downloadable binary '$FileName' has an untrusted $Label certificate chain: $statuses"
        }
        if ($Label -ceq "signer" -and $chain.ChainElements.Count -le 1) {
            throw "GitHub downloadable binary '$FileName' signer chain is self-signed or incomplete."
        }
    } finally {
        $chain.Dispose()
    }
}

$signTool = Get-TrustedWindowsSdkTool -Name "signtool.exe"
foreach ($requested in $Path) {
    $resolved = (Resolve-Path -LiteralPath $requested -ErrorAction Stop).Path
    $item = Get-Item -LiteralPath $resolved
    if ($item.PSIsContainer) {
        throw "GitHub binary release gate requires explicit file paths, not a directory: $resolved"
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "GitHub binary release gate rejects symlinks/reparse points: $resolved"
    }
    $extension = $item.Extension.ToLowerInvariant()
    if (-not $AllowPortableExecutable -and $allowedReleaseExtensions -notcontains $extension) {
        throw "GitHub binary release gate rejects '$($item.Name)'. Upload an individually verifiable signed EXE/MSIX/AppX, never an archive or certificate."
    }
    if ($AllowPortableExecutable -and $extension -notin @(".msix", ".appx")) {
        $stream = [IO.File]::OpenRead($resolved)
        try {
            if ($stream.Length -lt 2 -or $stream.ReadByte() -ne 0x4D -or $stream.ReadByte() -ne 0x5A) {
                throw "Nested signing gate accepts only MZ Portable Executable files: $resolved"
            }
        } finally { $stream.Dispose() }
    }

    $compactSignTool = Invoke-BoundedSignToolVerify -SignToolPath $signTool -BinaryPath $resolved
    $verboseSignTool = Invoke-BoundedSignToolVerify -SignToolPath $signTool -BinaryPath $resolved -Verbose
    Assert-SignToolOutputPolicy `
        -CompactOutput $compactSignTool `
        -VerboseOutput $verboseSignTool `
        -BinaryPath $resolved
    $signature = Get-AuthenticodeSignature -FilePath $resolved
    if ($signature.Status -ne "Valid" -or -not $signature.SignerCertificate) {
        throw "GitHub downloadable binary '$($item.Name)' does not have a valid trusted Authenticode signature."
    }
    if (-not $signature.TimeStamperCertificate) {
        throw "GitHub downloadable binary '$($item.Name)' has no trusted Authenticode timestamp."
    }
    Assert-Rfc3161Timestamp -FilePath $resolved -Extension $extension
    $simpleName = $signature.SignerCertificate.GetNameInfo(
        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
        $false
    )
    if ($allowedSignerNames -cnotcontains $simpleName) {
        throw "GitHub downloadable binary '$($item.Name)' is signed by '$simpleName'; required signer SimpleName/CN is exactly LAI ZEYU or 来泽宇."
    }
    $codeSigningEku = @(
        $signature.SignerCertificate.Extensions |
            Where-Object { $_.Oid.Value -eq "2.5.29.37" } |
            ForEach-Object {
                ([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$_).EnhancedKeyUsages
            } |
            ForEach-Object { $_.Value }
    )
    if ($codeSigningEku -cnotcontains $codeSigningOid) {
        throw "GitHub downloadable binary '$($item.Name)' signer certificate lacks the Code Signing EKU."
    }
    $timestampEku = @(
        $signature.TimeStamperCertificate.Extensions |
            Where-Object { $_.Oid.Value -eq "2.5.29.37" } |
            ForEach-Object {
                ([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$_).EnhancedKeyUsages
            } |
            ForEach-Object { $_.Value }
    )
    if ($timestampEku -cnotcontains $timeStampingOid) {
        throw "GitHub downloadable binary '$($item.Name)' timestamp certificate lacks the Time Stamping EKU."
    }
    if ($signature.SignerCertificate.Subject -ceq $signature.SignerCertificate.Issuer) {
        throw "GitHub downloadable binary '$($item.Name)' uses a self-issued signer certificate."
    }
    Assert-OnlineCertificateChain -Certificate $signature.SignerCertificate -Label "signer" -FileName $item.Name
    Assert-OnlineCertificateChain -Certificate $signature.TimeStamperCertificate -Label "timestamp" -FileName $item.Name

    if ($extension -in @(".msix", ".appx")) {
        $manifestPublisher = Get-MsixManifestPublisher -FilePath $resolved
        if ($signature.SignerCertificate.Subject -cne $manifestPublisher) {
            throw "AppxManifest Publisher '$manifestPublisher' does not exactly match signer Subject '$($signature.SignerCertificate.Subject)'. Store technical Publisher and a personal GitHub signer cannot be mixed in one MSIX."
        }
    }
    Write-Host "Trusted GitHub binary signature verified: $($item.Name) -> $simpleName (RFC 3161, online chains)"
}
