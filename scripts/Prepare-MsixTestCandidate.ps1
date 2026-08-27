param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateRoot,
    [Parameter(Mandatory = $true)]
    [string]$StateDirectory,
    [string]$Publisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot "Trusted-WindowsSdkTool.ps1")

if (-not $IsWindows) { throw "Prepare-MsixTestCandidate.ps1 must run on Windows." }
if ($Publisher -cne "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8") {
    throw "The QA signing publisher must exactly match the reserved Partner Center technical publisher."
}

$candidate = (Resolve-Path -LiteralPath $CandidateRoot).Path
$candidateItems = @(Get-Item -LiteralPath $candidate -Force; Get-ChildItem -LiteralPath $candidate -Recurse -Force)
if (@($candidateItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
    throw "The unsigned QA candidate contains a reparse point."
}
$packages = @(Get-ChildItem -LiteralPath $candidate -File -Filter "*.msix")
if ($packages.Count -ne 1) {
    throw "Expected exactly one unsigned QA MSIX under $candidate; found $($packages.Count)."
}

$stateRoot = [IO.Path]::GetFullPath($StateDirectory)
$runnerTempRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$runnerTempItem = Get-Item -LiteralPath $runnerTempRoot -Force
if (-not $runnerTempItem.PSIsContainer -or ($runnerTempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "RUNNER_TEMP must be one existing non-reparse directory."
}
$stateParent = [IO.Directory]::GetParent($stateRoot).FullName.TrimEnd('\')
if ((Split-Path -Leaf $stateRoot) -notlike "statflow-msix-test-*" -or
    -not [string]::Equals($stateParent, $runnerTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "StateDirectory must be a direct statflow-msix-test-* child of RUNNER_TEMP."
}
if (Test-Path -LiteralPath $stateRoot) {
    throw "Refusing to reuse an existing QA signing state directory: $stateRoot"
}
New-Item -ItemType Directory -Path $stateRoot | Out-Null

$signedPackage = Join-Path $stateRoot "SurveyDataWorkbench.qa-signed.msix"
$cerPath = Join-Path $stateRoot "development-signing.cer"
$personalThumbprint = $null
$trustedThumbprints = [Collections.Generic.List[string]]::new()
$succeeded = $false

try {
    Copy-Item -LiteralPath $packages[0].FullName -Destination $signedPackage
    $certificate = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $Publisher `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -HashAlgorithm SHA256 `
        -KeyExportPolicy NonExportable `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -NotAfter ([DateTime]::UtcNow.AddDays(2)) `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
    $personalThumbprint = [string]$certificate.Thumbprint
    if ($certificate.Subject -cne $Publisher) {
        throw "Ephemeral certificate subject '$($certificate.Subject)' does not match '$Publisher'."
    }
    Export-Certificate -Cert $certificate -FilePath $cerPath -Type CERT | Out-Null
    $trustedCertificate = Import-Certificate -FilePath $cerPath -CertStoreLocation "Cert:\LocalMachine\TrustedPeople"
    foreach ($trustedItem in @($trustedCertificate)) {
        $trustedThumbprints.Add([string]$trustedItem.Thumbprint)
        if ($trustedItem.Subject -cne $Publisher) {
            throw "Imported QA certificate has an unexpected subject: $($trustedItem.Subject)"
        }
    }
    if ($trustedThumbprints.Count -eq 0) { throw "No QA certificate was imported into TrustedPeople." }

    $signTool = Get-TrustedWindowsSdkTool -Name "signtool.exe"
    & $signTool sign /fd SHA256 /s My /sha1 $personalThumbprint $signedPackage
    if ($LASTEXITCODE -ne 0) { throw "The one-time non-exportable QA signing operation failed." }
    & $signTool verify /pa /all /v $signedPackage
    if ($LASTEXITCODE -ne 0) { throw "The one-time QA MSIX signature did not verify." }
    $signature = Get-AuthenticodeSignature -FilePath $signedPackage
    if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -cne $Publisher) {
        throw "The one-time QA MSIX signature is not valid for the fixed Partner Center publisher."
    }

    Remove-Item -LiteralPath $cerPath -Force
    Remove-Item -LiteralPath "Cert:\CurrentUser\My\$personalThumbprint" -DeleteKey -Force
    if ((Test-Path -LiteralPath $cerPath) -or
        (Test-Path -LiteralPath "Cert:\CurrentUser\My\$personalThumbprint")) {
        throw "Private QA signing material was not removed immediately after signing."
    }
    $personalThumbprint = $null

    $state = [ordered]@{
        schemaVersion = 1
        publisher = $Publisher
        signedPackagePath = $signedPackage
        signedPackageSha256 = (Get-FileHash -LiteralPath $signedPackage -Algorithm SHA256).Hash.ToLowerInvariant()
        sourcePackageSha256 = (Get-FileHash -LiteralPath $packages[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        trustedThumbprints = @($trustedThumbprints)
        createdAtUtc = [DateTime]::UtcNow.ToString("o")
    }
    $statePath = Join-Path $stateRoot "state.json"
    $temporaryStatePath = "$statePath.tmp"
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryStatePath -Encoding UTF8
    Move-Item -LiteralPath $temporaryStatePath -Destination $statePath
    $succeeded = $true
    Write-Host "Prepared one frozen signed QA MSIX: $($state.signedPackageSha256)"
} finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    foreach ($privatePath in @($cerPath)) {
        try {
            if (Test-Path -LiteralPath $privatePath) { Remove-Item -LiteralPath $privatePath -Force }
            if (Test-Path -LiteralPath $privatePath) { throw "file still exists" }
        } catch {
            $cleanupErrors.Add("Private signing file was not removed: $privatePath ($($_.Exception.Message))")
        }
    }
    if ($personalThumbprint) {
        $personalPath = "Cert:\CurrentUser\My\$personalThumbprint"
        try {
            if (Test-Path -LiteralPath $personalPath) { Remove-Item -LiteralPath $personalPath -DeleteKey -Force }
            if (Test-Path -LiteralPath $personalPath) { throw "certificate still exists" }
        } catch {
            $cleanupErrors.Add("CurrentUser signing certificate was not removed: $($_.Exception.Message)")
        }
    }
    if (-not $succeeded) {
        foreach ($thumbprint in $trustedThumbprints) {
            $trustedPath = "Cert:\LocalMachine\TrustedPeople\$thumbprint"
            try {
                if (Test-Path -LiteralPath $trustedPath) { Remove-Item -LiteralPath $trustedPath -Force }
                if (Test-Path -LiteralPath $trustedPath) { throw "certificate still exists" }
            } catch {
                $cleanupErrors.Add("TrustedPeople signing certificate was not removed: $($_.Exception.Message)")
            }
        }
        try {
            if (Test-Path -LiteralPath $stateRoot) { Remove-Item -LiteralPath $stateRoot -Recurse -Force }
            if (Test-Path -LiteralPath $stateRoot) { throw "state directory still exists" }
        } catch {
            $cleanupErrors.Add("Failed QA signing state was not removed: $($_.Exception.Message)")
        }
    }
    if ($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join [Environment]::NewLine) }
}
