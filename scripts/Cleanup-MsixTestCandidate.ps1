param(
    [Parameter(Mandatory = $true)]
    [string]$StateDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $IsWindows) { throw "Cleanup-MsixTestCandidate.ps1 must run on Windows." }
$stateRoot = [IO.Path]::GetFullPath($StateDirectory)
$runnerTempRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$stateParent = [IO.Directory]::GetParent($stateRoot).FullName.TrimEnd('\')
if ((Split-Path -Leaf $stateRoot) -notlike "statflow-msix-test-*" -or
    -not [string]::Equals($stateParent, $runnerTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean anything except a direct statflow-msix-test-* child of RUNNER_TEMP."
}
if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    Write-Host "No QA signing state directory remains to clean."
    return
}
$reparseItems = @(
    Get-Item -LiteralPath $stateRoot -Force
    Get-ChildItem -LiteralPath $stateRoot -Recurse -Force -ErrorAction Stop
) | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }
if ($reparseItems.Count -gt 0) {
    throw "QA signing state contains a reparse point; refusing recursive cleanup."
}

$statePath = Join-Path $stateRoot "state.json"
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "QA signing state exists without state.json; refusing an unverifiable cleanup."
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ([int]$state.schemaVersion -ne 1 -or
    [string]$state.publisher -cne "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8") {
    throw "QA signing state has an unexpected schema or publisher."
}

$cleanupErrors = [Collections.Generic.List[string]]::new()
foreach ($thumbprintValue in @($state.trustedThumbprints)) {
    $thumbprint = [string]$thumbprintValue
    if ($thumbprint -notmatch "^[0-9A-Fa-f]{40,64}$") {
        $cleanupErrors.Add("State contains an invalid certificate thumbprint.")
        continue
    }
    $certificatePath = "Cert:\LocalMachine\TrustedPeople\$thumbprint"
    try {
        if (Test-Path -LiteralPath $certificatePath) {
            $certificate = Get-Item -LiteralPath $certificatePath
            if ($certificate.Subject -cne "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8") {
                throw "certificate subject is '$($certificate.Subject)'"
            }
            Remove-Item -LiteralPath $certificatePath -Force
        }
        if (Test-Path -LiteralPath $certificatePath) { throw "certificate still exists" }
    } catch {
        $cleanupErrors.Add("TrustedPeople certificate $thumbprint was not removed: $($_.Exception.Message)")
    }
}
if ($cleanupErrors.Count -gt 0) {
    throw ($cleanupErrors -join [Environment]::NewLine)
}

Remove-Item -LiteralPath $stateRoot -Recurse -Force
if (Test-Path -LiteralPath $stateRoot) {
    throw "The dedicated QA signing state directory remained after cleanup."
}
Write-Host "Removed the frozen QA MSIX and its exact temporary trust certificate."
