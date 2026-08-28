param(
    [Parameter(Mandatory = $true)]
    [string]$LayoutDirectory,
    [string]$IdentityName = "",
    [string]$Publisher = "",
    [string]$PublisherDisplayName = "",
    [string]$Version = "1.1.0.0",
    [string]$OutputPath = "",
    [string]$SigningStatePath = "",
    [switch]$Development
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Trusted-WindowsSdkTool.ps1")

$ExpectedStoreIdentityName = "LAIZEYU.SurveyDataWorkbenchbyLAIZEYU"
$ExpectedStorePublisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"
$ExpectedStoreVersion = "1.1.0.0"

if (-not $IsWindows) { throw "Build-Msix.ps1 must run on Windows." }
if (-not (Test-Path (Join-Path $LayoutDirectory "StatFlow.Workbench.Desktop.exe"))) {
    throw "The Windows layout is incomplete."
}
$debugSymbols = @(Get-ChildItem -LiteralPath $LayoutDirectory -Recurse -File -Force | Where-Object { $_.Extension -ieq ".pdb" })
if ($debugSymbols.Count -gt 0) {
    throw "MSIX layout contains forbidden PDB debug symbols: $($debugSymbols.FullName -join ', ')"
}
Write-Host "MSIX layout debug-symbol gate passed: no PDB files."
if ($Development) {
    if (-not $IdentityName) { $IdentityName = "LAISystems.StatFlowWorkbench.Dev" }
    if (-not $Publisher) { $Publisher = "CN=StatFlowDevelopment" }
    if (-not $PublisherDisplayName) { $PublisherDisplayName = "LAI ZEYU" }
} elseif (-not $IdentityName -or -not $Publisher -or -not $PublisherDisplayName) {
    throw "Store packages require the exact Partner Center -IdentityName, -Publisher, and -PublisherDisplayName. Use -Development only for an unsigned local/CI package."
}
if (-not $Development -and
    ($IdentityName -cne $ExpectedStoreIdentityName -or $Publisher -cne $ExpectedStorePublisher)) {
    throw "Store IdentityName and Publisher must exactly match the reserved Survey Data Workbench Partner Center identity."
}
if (-not $Development -and $Version -cne $ExpectedStoreVersion) {
    throw "Production Store Version must be the literal reserved submission version $ExpectedStoreVersion."
}
if ($PublisherDisplayName -cne "LAI ZEYU") {
    throw "PublisherDisplayName must be exactly LAI ZEYU; Partner Center technical Publisher CN is a separate system identity."
}
if ($IdentityName -notmatch '^[A-Za-z0-9.-]+$') {
    throw "IdentityName contains characters that are not valid for this package script."
}
if ($Version -notmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}\.\d{1,5}$') {
    throw "Version must contain four numeric components, for example 1.1.0.0."
}
$versionParts = $Version.Split('.') | ForEach-Object { [int]$_ }
if ($versionParts | Where-Object { $_ -gt 65535 }) {
    throw "Each Version component must be between 0 and 65535."
}

$repo = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $LayoutDirectory "Assets"
& (Join-Path $PSScriptRoot "Generate-WindowsAssets.ps1") -OutputDirectory $assets

$template = Get-Content (Join-Path $repo "packaging\AppxManifest.template.xml") -Raw
$escapedPublisher = [Security.SecurityElement]::Escape($Publisher)
$escapedPublisherDisplayName = [Security.SecurityElement]::Escape($PublisherDisplayName)
$manifest = $template.Replace("__IDENTITY_NAME__", $IdentityName)
$manifest = $manifest.Replace("__PUBLISHER__", $escapedPublisher)
$manifest = $manifest.Replace("__PUBLISHER_DISPLAY_NAME__", $escapedPublisherDisplayName)
$manifest = $manifest.Replace("__VERSION__", $Version)
if ($manifest -match '__[A-Z0-9_]+__') {
    throw "The generated AppxManifest still contains an unresolved identity placeholder."
}
[IO.File]::WriteAllText((Join-Path $LayoutDirectory "AppxManifest.xml"), $manifest, [Text.UTF8Encoding]::new($false))

$makeappxPath = Get-TrustedWindowsSdkTool -Name "makeappx.exe"

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $LayoutDirectory) "StatFlow.Workbench_$Version`_$IdentityName.msix"
}
& $makeappxPath pack /o /d $LayoutDirectory /p $OutputPath
if ($LASTEXITCODE -ne 0) { throw "makeappx failed with exit code $LASTEXITCODE" }

if ($SigningStatePath) {
    if ($Development) {
        throw "The production SSL.com CKA signer cannot be mixed with the self-contained development identity."
    }
    if (-not (Test-Path -LiteralPath $SigningStatePath -PathType Leaf)) {
        throw "The requested SSL.com eSigner CKA state file does not exist: $SigningStatePath"
    }
    # The CKA signer parses AppxManifest.xml before signing and refuses any
    # certificate Subject that is not byte-for-byte equal to Identity Publisher.
    # It then verifies the changed MSIX immediately: Valid Authenticode,
    # SHA-256, RFC 3161, online chains, EKUs, non-self-issued certificate, and
    # exact LAI ZEYU/来泽宇 SimpleName.  No PFX or exported production key exists.
    & (Join-Path $PSScriptRoot "Invoke-SslEsignerSign.ps1") `
        -Path $OutputPath `
        -StatePath $SigningStatePath
}

Write-Host "MSIX ready: $OutputPath"
