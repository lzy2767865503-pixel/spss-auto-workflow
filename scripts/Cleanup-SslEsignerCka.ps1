param(
    [Parameter(Mandatory = $true)]
    [string]$StatePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $IsWindows) { throw "SSL.com eSigner CKA cleanup must run on Windows." }
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw "RUNNER_TEMP is required." }
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
$runnerTempItem = Get-Item -LiteralPath $runnerTemp.TrimEnd('\') -Force
if (-not $runnerTempItem.PSIsContainer -or ($runnerTempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "RUNNER_TEMP must be one existing non-reparse directory."
}
$stateFile = [IO.Path]::GetFullPath($StatePath)
if (-not $stateFile.StartsWith($runnerTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing CKA cleanup outside RUNNER_TEMP."
}
if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
    Write-Host "No eSigner CKA state remains to clean."
    return
}
$stateFileItem = Get-Item -LiteralPath $stateFile -Force
if (($stateFileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing a linked CKA state file."
}
$stateRoot = Split-Path -Parent $stateFile
if ((Split-Path -Leaf $stateRoot) -notlike "statflow-cka-state-*" -or
    [IO.Directory]::GetParent($stateRoot).FullName.TrimEnd('\') -cne $runnerTemp.TrimEnd('\')) {
    throw "Refusing CKA cleanup outside its exact dedicated state directory."
}
$state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
if ([int]$state.schemaVersion -ne 2 -or [string]$state.provider -cne "SSL.com eSigner CKA 1.1.2" -or
    [string]$state.mode -cne "product") {
    throw "Refusing cleanup for an unexpected CKA state schema."
}

function Assert-OwnedPath([string]$Path, [string]$ExpectedLeafPattern, [string]$Label) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($runnerTemp, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Directory]::GetParent($resolved).FullName.TrimEnd('\') -cne $runnerTemp.TrimEnd('\') -or
        (Split-Path -Leaf $resolved) -notlike $ExpectedLeafPattern) {
        throw "$Label is outside the exact owned RUNNER_TEMP scope: $resolved"
    }
    return $resolved
}

function Assert-NoReparseTree([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label root is a reparse point: $Path"
    }
    if ($rootItem.PSIsContainer) {
        $linked = @(
            Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop |
                Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }
        )
        if ($linked.Count -gt 0) { throw "$Label contains a reparse point: $($linked[0].FullName)" }
    }
}

function Invoke-BoundedCleanupProcess([string]$FilePath, [string[]]$Arguments, [string]$Label) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "$Label did not start." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(300000)) {
            $killError = ""
            try { $process.Kill($true) } catch { $killError = $_.Exception.Message }
            if (-not $process.WaitForExit(30000) -or -not $process.HasExited) {
                throw "$Label remained alive after process-tree termination attempt: $killError"
            }
            throw "$Label exceeded its five minute timeout."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $message = "$stdout`n$stderr"
            if ($message.Length -gt 2000) { $message = $message.Substring($message.Length - 2000) }
            throw "$Label failed with exit code $($process.ExitCode): $message"
        }
    } finally { $process.Dispose() }
}

function Get-CryptoProviderBaseline {
    $certutil = Join-Path $env:SystemRoot "System32\certutil.exe"
    $signature = Get-AuthenticodeSignature -LiteralPath $certutil
    if ($signature.Status -ne "Valid" -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne "Microsoft Windows") {
        throw "System certutil.exe identity is invalid."
    }
    $machineLines = @(& $certutil -csplist 2>&1)
    if ($LASTEXITCODE -ne 0 -or $machineLines.Count -eq 0) { throw "Could not capture machine cryptographic provider baseline." }
    $userLines = @(& $certutil -user -csplist 2>&1)
    if ($LASTEXITCODE -ne 0 -or $userLines.Count -eq 0) { throw "Could not capture current-user cryptographic provider baseline." }
    return @(
        @($machineLines | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | ForEach-Object { "machine|$_" })
        @($userLines | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | ForEach-Object { "current-user|$_" })
    ) | Sort-Object -Unique
}

function Get-CurrentUserKeyFileBaseline {
    $roots = @(
        (Join-Path ([Environment]::GetFolderPath("ApplicationData")) "Microsoft\Crypto"),
        (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Microsoft\Crypto")
    )
    $values = [Collections.Generic.List[string]]::new()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $rootPath = [IO.Path]::GetFullPath($root).TrimEnd('\')
        Assert-NoReparseTree -Path $rootPath -Label "current-user key store"
        foreach ($file in Get-ChildItem -LiteralPath $rootPath -File -Recurse -Force -ErrorAction Stop) {
            $relative = [IO.Path]::GetRelativePath($rootPath, $file.FullName)
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $values.Add("$rootPath|$relative|$($file.Length)|$hash")
        }
    }
    return @($values | Sort-Object -Unique)
}

function Assert-OnlineChain($Certificate, [string]$Label) {
    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $chain.ChainPolicy.RevocationFlag = [Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
        $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(60)
        if (-not $chain.Build($Certificate)) {
            $statuses = @($chain.ChainStatus | ForEach-Object { $_.Status.ToString() }) -join ", "
            throw "$Label certificate chain is not trusted with online revocation checking: $statuses"
        }
        if ($chain.ChainElements.Count -le 1) { throw "$Label certificate is self-signed or incomplete." }
    } finally { $chain.Dispose() }
}

$installRoot = Assert-OwnedPath -Path ([string]$state.installDirectory) -ExpectedLeafPattern "statflow-esigner-cka-*" -Label "CKA install directory"
Assert-NoReparseTree -Path $stateRoot -Label "CKA state directory"
Assert-NoReparseTree -Path $installRoot -Label "CKA install directory"
$tool = [IO.Path]::GetFullPath([string]$state.ckaToolPath)
if (-not $tool.StartsWith($installRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $tool -PathType Leaf)) {
    throw "CKA tool is absent or outside its exact install directory."
}
$toolItem = Get-Item -LiteralPath $tool -Force
if (($toolItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    (Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$state.installedComponentSha256.eSignerCKATool) {
    throw "CKA tool identity changed after initialization."
}
$thumbprint = ([string]$state.signerThumbprint).ToUpperInvariant()
if ($thumbprint -notmatch "^[0-9A-F]{40,64}$" -or [string]$state.signerSimpleName -notin @("LAI ZEYU", "来泽宇")) {
    throw "CKA cleanup state does not identify an allowed exact LAI certificate."
}
$preexisting = @($state.preexistingThumbprints | ForEach-Object { ([string]$_).ToUpperInvariant() })
if ($preexisting -ccontains $thumbprint) { throw "Refusing to remove a signer certificate that predates this CKA session." }

$uninstaller = [IO.Path]::GetFullPath([string]$state.uninstallerPath)
if (-not $uninstaller.StartsWith($installRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
    throw "The exact verified CKA uninstaller is absent or outside the install directory."
}
$uninstallerItem = Get-Item -LiteralPath $uninstaller -Force
$uninstallerSignature = Get-AuthenticodeSignature -LiteralPath $uninstaller
if (($uninstallerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    (Get-FileHash -LiteralPath $uninstaller -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$state.uninstallerSha256 -or
    $uninstallerSignature.Status -ne "Valid" -or -not $uninstallerSignature.SignerCertificate -or
    $uninstallerSignature.SignerCertificate.Subject -ceq $uninstallerSignature.SignerCertificate.Issuer) {
    throw "The exact CKA uninstaller identity changed after initialization."
}
Assert-OnlineChain -Certificate $uninstallerSignature.SignerCertificate -Label "CKA uninstaller signer"

$cleanupErrors = [Collections.Generic.List[string]]::new()
try { Invoke-BoundedCleanupProcess -FilePath $tool -Arguments @("unload") -Label "eSigner CKA certificate unload" } catch {
    $cleanupErrors.Add("CKA unload failed: $($_.Exception.Message)")
}
$certificatePath = "Cert:\CurrentUser\My\$thumbprint"
try {
    if (Test-Path -LiteralPath $certificatePath) {
        $certificate = Get-Item -LiteralPath $certificatePath
        if ($certificate.Subject -cne [string]$state.signerSubject) { throw "certificate subject changed to '$($certificate.Subject)'" }
        Remove-Item -LiteralPath $certificatePath -DeleteKey -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $certificatePath) { throw "exact certificate still exists" }
} catch { $cleanupErrors.Add("Exact CKA signer certificate/private key was not removed: $($_.Exception.Message)") }

$masterKey = [IO.Path]::GetFullPath([string]$state.masterKeyPath)
try {
    if (-not $masterKey.StartsWith($installRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "master key path escaped the owned install directory" }
    if (Test-Path -LiteralPath $masterKey) {
        $masterKeyItem = Get-Item -LiteralPath $masterKey -Force
        if ($masterKeyItem.PSIsContainer -or ($masterKeyItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "master key is not a regular file" }
        Remove-Item -LiteralPath $masterKey -Force
    }
    if (Test-Path -LiteralPath $masterKey) { throw "master key still exists" }
} catch { $cleanupErrors.Add("CKA master key was not removed: $($_.Exception.Message)") }

try {
    Invoke-BoundedCleanupProcess -FilePath $uninstaller -Arguments @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") -Label "eSigner CKA uninstaller"
} catch { $cleanupErrors.Add("CKA uninstaller failed: $($_.Exception.Message)") }

$ckaData = [IO.Path]::GetFullPath([string]$state.ckaDataDirectory)
$expectedCkaData = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath("ApplicationData")) "eSignerCKA"))
try {
    if ($ckaData -cne $expectedCkaData) { throw "CKA profile path changed" }
    Assert-NoReparseTree -Path $ckaData -Label "owned CKA profile"
    if (Test-Path -LiteralPath $ckaData) { Remove-Item -LiteralPath $ckaData -Recurse -Force }
    if (Test-Path -LiteralPath $ckaData) { throw "CKA profile remains" }
} catch { $cleanupErrors.Add("Owned CKA profile was not removed: $($_.Exception.Message)") }

try {
    Assert-NoReparseTree -Path $installRoot -Label "owned CKA install directory"
    if (Test-Path -LiteralPath $installRoot) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
    if (Test-Path -LiteralPath $installRoot) { throw "owned directory remains" }
} catch { $cleanupErrors.Add("Owned CKA install directory was not removed: $($_.Exception.Message)") }

try {
    $expectedProviderBaseline = @($state.providerBaseline | ForEach-Object { [string]$_ })
    $currentProviderBaseline = @(Get-CryptoProviderBaseline)
    if (Compare-Object -ReferenceObject $expectedProviderBaseline -DifferenceObject $currentProviderBaseline) {
        throw "cryptographic provider baseline changed"
    }
} catch { $cleanupErrors.Add("Provider cleanup verification failed: $($_.Exception.Message)") }
try {
    $expectedKeyBaseline = @($state.currentUserKeyFileBaseline | ForEach-Object { [string]$_ })
    $currentKeyBaseline = @(Get-CurrentUserKeyFileBaseline)
    if (Compare-Object -ReferenceObject $expectedKeyBaseline -DifferenceObject $currentKeyBaseline) {
        throw "current-user key-container baseline changed"
    }
} catch { $cleanupErrors.Add("Key-container cleanup verification failed: $($_.Exception.Message)") }
try {
    $remaining = @(
        Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
            Where-Object { ([string]$_.Thumbprint).ToUpperInvariant() -ceq $thumbprint }
    )
    if ($remaining.Count -ne 0 -or (Test-Path -LiteralPath $certificatePath)) { throw "exact signer certificate remains" }
} catch { $cleanupErrors.Add("Certificate-store cleanup verification failed: $($_.Exception.Message)") }

if ($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join [Environment]::NewLine) }
Assert-NoReparseTree -Path $stateRoot -Label "CKA state directory"
Remove-Item -LiteralPath $stateRoot -Recurse -Force
if (Test-Path -LiteralPath $stateRoot) { throw "CKA state remained after cleanup." }
Write-Host "SSL.com eSigner CKA certificate/private key, master key, profile, provider state, key containers, and exact temporary installation were removed."
