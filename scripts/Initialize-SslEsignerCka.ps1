param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerPath,
    [Parameter(Mandatory = $true)]
    [string]$InstallDirectory,
    [Parameter(Mandatory = $true)]
    [string]$StatePath,
    [Parameter(Mandatory = $true)]
    [string]$CredentialBrokerPath,
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$ExpectedCredentialBrokerSha256,
    [string]$ExpectedInstallerSha256 = "3f088403139505ddfb0ed3b56b72893f92c865f98b382753a1e1c695a5cece35"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $IsWindows) { throw "SSL.com eSigner CKA initialization must run on Windows." }
if ($env:STATFLOW_TRUSTED_GITHUB_BUILD -cne "1") {
    throw "Refusing to initialize the production cloud signer outside the protected release job."
}

function Assert-WithinRunnerTemp([string]$RequestedPath, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw "RUNNER_TEMP is required." }
    $runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($RequestedPath)
    if (-not $resolved.StartsWith($runnerTemp, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be inside RUNNER_TEMP: $resolved"
    }
    return $resolved
}

function Invoke-BoundedRedactedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label,
        [int]$TimeoutSeconds = 600
    )
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
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $killError = ""
            try { $process.Kill($true) } catch { $killError = $_.Exception.Message }
            if (-not $process.WaitForExit(30000) -or -not $process.HasExited) {
                throw "$Label timed out and remained alive after process-tree termination attempt: $killError"
            }
            throw "$Label exceeded its $TimeoutSeconds second hard timeout."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $message = "$stdout`n$stderr"
            if ($message.Length -gt 4000) { $message = $message.Substring($message.Length - 4000) }
            throw "$Label failed with exit code $($process.ExitCode): $message"
        }
    } finally {
        $process.Dispose()
    }
}

function Get-CryptoProviderBaseline {
    $certutil = Join-Path $env:SystemRoot "System32\certutil.exe"
    $signature = Get-AuthenticodeSignature -LiteralPath $certutil
    if ($signature.Status -ne "Valid" -or
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

function Test-CodeSigningEku($Certificate) {
    $oids = @(
        $Certificate.Extensions |
            Where-Object { $_.Oid.Value -eq "2.5.29.37" } |
            ForEach-Object {
                ([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$_).EnhancedKeyUsages
            } |
            ForEach-Object { $_.Value }
    )
    return $oids -ccontains "1.3.6.1.5.5.7.3.3"
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

$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$installRoot = Assert-WithinRunnerTemp -RequestedPath $InstallDirectory -Label "CKA install directory"
$stateFile = Assert-WithinRunnerTemp -RequestedPath $StatePath -Label "CKA state path"
$stateRoot = Split-Path -Parent $stateFile
$runnerTempRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$runnerTempItem = Get-Item -LiteralPath $runnerTempRoot -Force
if (-not $runnerTempItem.PSIsContainer -or ($runnerTempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "RUNNER_TEMP must be one existing non-reparse directory."
}
if ((Split-Path -Leaf $installRoot) -notlike "statflow-esigner-cka-*" -or
    (Split-Path -Leaf $stateRoot) -notlike "statflow-cka-state-*" -or
    [IO.Directory]::GetParent($installRoot).FullName.TrimEnd('\') -cne $runnerTempRoot -or
    [IO.Directory]::GetParent($stateRoot).FullName.TrimEnd('\') -cne $runnerTempRoot) {
    throw "CKA install/state directories must be dedicated direct RUNNER_TEMP children."
}
if (Test-Path -LiteralPath $installRoot) { throw "Refusing to reuse an existing CKA install directory." }
if (Test-Path -LiteralPath $stateRoot) { throw "Refusing to reuse an existing CKA state directory." }

$installerItem = Get-Item -LiteralPath $installer
if ($installerItem.PSIsContainer -or ($installerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "The pinned CKA installer must be one regular file."
}
$installerHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
if ($installerHash -cne $ExpectedInstallerSha256) { throw "Pinned SSL.com eSigner CKA installer checksum mismatch." }
$installerSignature = Get-AuthenticodeSignature -FilePath $installer
if ($installerSignature.Status -ne "Valid" -or -not $installerSignature.SignerCertificate -or
    $installerSignature.SignerCertificate.Subject -ceq $installerSignature.SignerCertificate.Issuer) {
    throw "Pinned SSL.com eSigner CKA installer lacks a valid non-self-issued Authenticode signature."
}
Assert-OnlineChain -Certificate $installerSignature.SignerCertificate -Label "CKA installer signer"

$credentialBroker = (Resolve-Path -LiteralPath $CredentialBrokerPath).Path
$brokerItem = Get-Item -LiteralPath $credentialBroker -Force
$workspaceRoot = if ([string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) { $null } else {
    [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\') + '\'
}
if (($workspaceRoot -and $credentialBroker.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase)) -or
    $brokerItem.PSIsContainer -or ($brokerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    [IO.Path]::GetExtension($credentialBroker) -ine ".exe" -or
    (Get-FileHash -LiteralPath $credentialBroker -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedCredentialBrokerSha256) {
    throw "The out-of-repository CKA credential broker is absent, linked, or hash-mismatched."
}
$brokerSignature = Get-AuthenticodeSignature -LiteralPath $credentialBroker
if ($brokerSignature.Status -ne "Valid" -or -not $brokerSignature.SignerCertificate -or
    -not $brokerSignature.TimeStamperCertificate -or
    $brokerSignature.SignerCertificate.Subject -ceq $brokerSignature.SignerCertificate.Issuer) {
    throw "The CKA credential broker lacks a trusted timestamped Authenticode signature."
}
Assert-OnlineChain -Certificate $brokerSignature.SignerCertificate -Label "CKA credential broker signer"
$allowedNames = @("LAI ZEYU", "来泽宇")
$providerBaseline = @(Get-CryptoProviderBaseline)
$keyFileBaseline = @(Get-CurrentUserKeyFileBaseline)
$preexistingThumbprints = @(
    Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        ForEach-Object { [string]$_.Thumbprint }
)
$ckaData = Join-Path ([Environment]::GetFolderPath("ApplicationData")) "eSignerCKA"
if (Test-Path -LiteralPath $ckaData) {
    throw "A pre-existing eSignerCKA profile exists; refusing to overwrite or later delete it."
}

$ckaTool = $null
$masterKey = Join-Path $installRoot "master.key"
$loadedThumbprint = $null
$verifiedUninstaller = $null
$verifiedUninstallerHash = $null
$succeeded = $false
try {
    New-Item -ItemType Directory -Path $stateRoot | Out-Null
    Invoke-BoundedRedactedProcess `
        -FilePath $installer `
        -Arguments @("/CURRENTUSER", "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/DIR=$installRoot") `
        -Label "SSL.com eSigner CKA installer" `
        -TimeoutSeconds 600
    $tools = @(Get-ChildItem -LiteralPath $installRoot -File -Filter "eSignerCKATool.exe" -Recurse)
    if ($tools.Count -ne 1) { throw "Pinned CKA installation did not produce exactly one eSignerCKATool.exe." }
    $ckaTool = $tools[0].FullName
    $requiredComponents = [ordered]@{
        eSignerCKATool = $ckaTool
    }
    foreach ($componentName in @("RegisterKSP.exe", "eSignerCSP.Config.exe", "eSignerKSP32.dll", "eSignerKSP64.dll")) {
        $matches = @(Get-ChildItem -LiteralPath $installRoot -File -Filter $componentName -Recurse)
        if ($matches.Count -ne 1) {
            throw "Pinned CKA installation did not produce exactly one required $componentName component."
        }
        $requiredComponents[[IO.Path]::GetFileNameWithoutExtension($componentName)] = $matches[0].FullName
    }
    $componentHashes = [ordered]@{}
    foreach ($component in $requiredComponents.GetEnumerator()) {
        $componentItem = Get-Item -LiteralPath $component.Value
        if (($componentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Installed CKA component is a reparse point: $($componentItem.Name)"
        }
        $componentSignature = Get-AuthenticodeSignature -FilePath $component.Value
        if ($componentSignature.Status -ne "Valid" -or -not $componentSignature.SignerCertificate -or
            $componentSignature.SignerCertificate.Subject -ceq $componentSignature.SignerCertificate.Issuer) {
            throw "Installed CKA component lacks a valid non-self-issued Authenticode identity: $($componentItem.Name)"
        }
        Assert-OnlineChain -Certificate $componentSignature.SignerCertificate -Label "installed $($componentItem.Name) signer"
        $componentHashes[$component.Key] = (Get-FileHash -LiteralPath $component.Value -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $uninstallers = @(Get-ChildItem -LiteralPath $installRoot -File -Filter "unins*.exe" -ErrorAction Stop)
    if ($uninstallers.Count -ne 1 -or
        ($uninstallers[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Pinned CKA installation did not produce exactly one regular top-level uninstaller."
    }
    $uninstallerSignature = Get-AuthenticodeSignature -LiteralPath $uninstallers[0].FullName
    if ($uninstallerSignature.Status -ne "Valid" -or -not $uninstallerSignature.SignerCertificate -or
        $uninstallerSignature.SignerCertificate.Subject -ceq $uninstallerSignature.SignerCertificate.Issuer) {
        throw "Installed CKA uninstaller lacks a valid non-self-issued Authenticode identity."
    }
    Assert-OnlineChain -Certificate $uninstallerSignature.SignerCertificate -Label "installed CKA uninstaller signer"
    $verifiedUninstaller = $uninstallers[0].FullName
    $verifiedUninstallerHash = (Get-FileHash -LiteralPath $verifiedUninstaller -Algorithm SHA256).Hash.ToLowerInvariant()

    # SSL.com's CKA workflow registers both KSP architectures and the companion
    # CSP configuration before account configuration. These bounded calls plus
    # the later HasPrivateKey check prove that SignTool sees the cloud key through
    # the Windows cryptographic provider rather than merely seeing a certificate.
    Invoke-BoundedRedactedProcess `
        -FilePath ([string]$requiredComponents.RegisterKSP) `
        -Arguments @() `
        -Label "eSigner CKA KSP registration" `
        -TimeoutSeconds 120
    Invoke-BoundedRedactedProcess `
        -FilePath ([string]$requiredComponents."eSignerCSP.Config") `
        -Arguments @() `
        -Label "eSigner CKA CSP configuration" `
        -TimeoutSeconds 120

    # CKA 1.1.2's vendor CLI accepts the reusable account secret on its command
    # line. Repository code must never do that. This pinned, pre-provisioned
    # broker obtains credentials through the runner's machine-bound secret
    # channel; only non-secret paths and a one-run nonce cross this boundary.
    $brokerSession = [Guid]::NewGuid().ToString("N")
    Invoke-BoundedRedactedProcess `
        -FilePath $credentialBroker `
        -Arguments @("provision-cka", "--cka-tool", $ckaTool, "--master-key", $masterKey, "--session", $brokerSession) `
        -Label "machine-bound eSigner CKA credential broker" `
        -TimeoutSeconds 300
    Invoke-BoundedRedactedProcess -FilePath $ckaTool -Arguments @("unload") -Label "eSigner CKA certificate unload" -TimeoutSeconds 120
    Invoke-BoundedRedactedProcess -FilePath $ckaTool -Arguments @("load") -Label "eSigner CKA certificate load" -TimeoutSeconds 300

    $candidates = @(
        Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction Stop |
            Where-Object {
                $simpleName = $_.GetNameInfo(
                    [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
                    $false
                )
                $allowedNames -ccontains $simpleName -and
                $_.HasPrivateKey -and
                $_.Subject -cne $_.Issuer -and
                $preexistingThumbprints -cnotcontains [string]$_.Thumbprint -and
                (Test-CodeSigningEku $_)
            }
    )
    if ($candidates.Count -ne 1) {
        throw "eSigner CKA must load exactly one new private-key Code Signing certificate whose SimpleName/CN is LAI ZEYU or 来泽宇; found $($candidates.Count)."
    }
    $certificate = $candidates[0]
    Assert-OnlineChain -Certificate $certificate -Label "LAI release signer"
    $loadedThumbprint = ([string]$certificate.Thumbprint).ToUpperInvariant()

    $state = [ordered]@{
        schemaVersion = 2
        provider = "SSL.com eSigner CKA 1.1.2"
        mode = "product"
        installDirectory = $installRoot
        ckaToolPath = $ckaTool
        ckaDataDirectory = $ckaData
        masterKeyPath = $masterKey
        signerThumbprint = $loadedThumbprint
        signerSubject = [string]$certificate.Subject
        signerSimpleName = $certificate.GetNameInfo(
            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false
        )
        preexistingThumbprints = @($preexistingThumbprints)
        installerSha256 = $installerHash
        installedComponentSha256 = $componentHashes
        uninstallerPath = $verifiedUninstaller
        uninstallerSha256 = $verifiedUninstallerHash
        credentialBrokerPath = $credentialBroker
        credentialBrokerSha256 = $ExpectedCredentialBrokerSha256
        providerBaseline = @($providerBaseline)
        currentUserKeyFileBaseline = @($keyFileBaseline)
        createdAtUtc = [DateTime]::UtcNow.ToString("o")
    }
    $temporaryState = "$stateFile.tmp"
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryState -Encoding UTF8
    Move-Item -LiteralPath $temporaryState -Destination $stateFile
    $succeeded = $true
    Write-Host "SSL.com eSigner CKA loaded one exact LAI author certificate through the Windows CNG/KSP store."
} finally {
    if (-not $succeeded) {
        $failureCleanupErrors = [Collections.Generic.List[string]]::new()
        if ($ckaTool -and (Test-Path -LiteralPath $ckaTool)) {
            try {
                Invoke-BoundedRedactedProcess -FilePath $ckaTool -Arguments @("unload") -Label "failed CKA initialization unload" -TimeoutSeconds 120
            } catch { $failureCleanupErrors.Add("Failed CKA unload: $($_.Exception.Message)") }
        }
        $currentCertificates = @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue)
        foreach ($certificate in $currentCertificates) {
            $simpleName = $certificate.GetNameInfo(
                [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
                $false
            )
            if ($preexistingThumbprints -cnotcontains [string]$certificate.Thumbprint -and
                $allowedNames -ccontains $simpleName -and
                (Test-CodeSigningEku $certificate)) {
                try {
                    $certificatePath = "Cert:\CurrentUser\My\$($certificate.Thumbprint)"
                    Remove-Item -LiteralPath $certificatePath -DeleteKey -Force -ErrorAction Stop
                    if (Test-Path -LiteralPath $certificatePath) { throw "certificate remains" }
                } catch { $failureCleanupErrors.Add("New CKA certificate cleanup failed: $($_.Exception.Message)") }
            }
        }
        if ($verifiedUninstaller -and (Test-Path -LiteralPath $verifiedUninstaller -PathType Leaf)) {
            try {
                $uninstallerItem = Get-Item -LiteralPath $verifiedUninstaller -Force
                $uninstallerSignature = Get-AuthenticodeSignature -LiteralPath $verifiedUninstaller
                if (($uninstallerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    (Get-FileHash -LiteralPath $verifiedUninstaller -Algorithm SHA256).Hash.ToLowerInvariant() -cne $verifiedUninstallerHash -or
                    $uninstallerSignature.Status -ne "Valid" -or -not $uninstallerSignature.SignerCertificate -or
                    $uninstallerSignature.SignerCertificate.Subject -ceq $uninstallerSignature.SignerCertificate.Issuer) {
                    throw "Previously verified CKA uninstaller identity changed."
                }
                Assert-OnlineChain -Certificate $uninstallerSignature.SignerCertificate -Label "failure-path CKA uninstaller signer"
                Invoke-BoundedRedactedProcess `
                    -FilePath $verifiedUninstaller `
                    -Arguments @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") `
                    -Label "failed CKA initialization uninstaller" `
                    -TimeoutSeconds 300
            } catch { $failureCleanupErrors.Add("Partial CKA uninstall failed: $($_.Exception.Message)") }
        }
        foreach ($ownedPath in @($installRoot, $ckaData, $stateRoot)) {
            try {
                Assert-NoReparseTree -Path $ownedPath -Label "failed-init owned path"
                if (Test-Path -LiteralPath $ownedPath) { Remove-Item -LiteralPath $ownedPath -Recurse -Force }
                if (Test-Path -LiteralPath $ownedPath) { throw "owned path remains: $ownedPath" }
            } catch { $failureCleanupErrors.Add("Failed CKA owned-path cleanup: $($_.Exception.Message)") }
        }
        $remainingOwnedCertificates = @(
            Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
                Where-Object {
                    $candidateName = $_.GetNameInfo(
                        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
                        $false
                    )
                    $preexistingThumbprints -cnotcontains [string]$_.Thumbprint -and
                    $allowedNames -ccontains $candidateName -and
                    (Test-CodeSigningEku $_)
                }
        )
        if ($remainingOwnedCertificates.Count -gt 0) {
            $failureCleanupErrors.Add("One or more new LAI Code Signing certificates remained after failed CKA initialization.")
        }
        try {
            $currentProviderBaseline = @(Get-CryptoProviderBaseline)
            if (Compare-Object -ReferenceObject $providerBaseline -DifferenceObject $currentProviderBaseline) { throw "cryptographic provider baseline changed" }
        } catch { $failureCleanupErrors.Add("Provider cleanup verification failed: $($_.Exception.Message)") }
        try {
            $currentKeyFileBaseline = @(Get-CurrentUserKeyFileBaseline)
            if (Compare-Object -ReferenceObject $keyFileBaseline -DifferenceObject $currentKeyFileBaseline) { throw "current-user key-file baseline changed" }
        } catch { $failureCleanupErrors.Add("Key-container cleanup verification failed: $($_.Exception.Message)") }
        if ($failureCleanupErrors.Count -gt 0) {
            throw ($failureCleanupErrors -join [Environment]::NewLine)
        }
    }
}
