param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateRoot,
    [Parameter(Mandatory = $true)]
    [string]$SigningStatePath,
    [ValidateRange(1, 2)]
    [int]$Pass = 1,
    [string]$IdentityName = "LAIZEYU.SurveyDataWorkbenchbyLAIZEYU",
    [string]$Publisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8",
    [string]$PublisherDisplayName = "LAI ZEYU",
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$ExpectedWackToolSha256,
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^\d+(?:\.\d+){1,3}$")]
    [string]$ExpectedWackToolFileVersion,
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^\d+(?:\.\d+){1,3}$")]
    [string]$ExpectedWackKitVersion,
    [string]$DiagnosticsDirectory = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true

. (Join-Path $PSScriptRoot "Trusted-WindowsSdkTool.ps1")

if (-not $IsWindows) { throw "Test-MsixLifecycle.ps1 must run on Windows." }
if ($IdentityName -cne "LAIZEYU.SurveyDataWorkbenchbyLAIZEYU" -or
    $Publisher -cne "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8") {
    throw "MSIX lifecycle identity must exactly match the reserved Survey Data Workbench Partner Center product."
}
if ($PublisherDisplayName -cne "LAI ZEYU") {
    throw "PublisherDisplayName must be exactly LAI ZEYU; the technical Publisher CN is a separate package identity."
}
$candidate = (Resolve-Path -LiteralPath $CandidateRoot).Path
$candidateItems = @(Get-Item -LiteralPath $candidate -Force; Get-ChildItem -LiteralPath $candidate -Recurse -Force)
if (@($candidateItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
    throw "The Store candidate contains a reparse point."
}
$packages = @(Get-ChildItem -LiteralPath $candidate -File -Filter "*.msix")
if ($packages.Count -ne 1) { throw "Expected exactly one MSIX under $candidate; found $($packages.Count)." }
$signingStateFile = (Resolve-Path -LiteralPath $SigningStatePath).Path
$signingStateFileItem = Get-Item -LiteralPath $signingStateFile -Force
if ($signingStateFileItem.PSIsContainer -or ($signingStateFileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "The frozen QA signing state must be one regular non-reparse file."
}
$signingState = Get-Content -LiteralPath $signingStateFile -Raw | ConvertFrom-Json
if ([int]$signingState.schemaVersion -ne 1 -or [string]$signingState.publisher -cne $Publisher) {
    throw "The frozen signing state does not match the fixed Partner Center publisher or schema."
}
$signingStateRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $signingStateFile)).Path
$signingStateRootItem = Get-Item -LiteralPath $signingStateRoot -Force
if (-not $signingStateRootItem.PSIsContainer -or ($signingStateRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "The frozen QA signing state root must be one non-reparse directory."
}
$signedPackage = (Resolve-Path -LiteralPath ([string]$signingState.signedPackagePath)).Path
if ((Split-Path -Parent $signedPackage) -cne $signingStateRoot -or
    [IO.Path]::GetExtension($signedPackage) -cne ".msix") {
    throw "The frozen signed package must be the MSIX directly inside its dedicated signing state directory."
}
$signedPackageItem = Get-Item -LiteralPath $signedPackage -Force
if ($signedPackageItem.PSIsContainer -or ($signedPackageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "The frozen signed QA MSIX must be one regular non-reparse file."
}
$expectedSignedPackageHash = ([string]$signingState.signedPackageSha256).ToLowerInvariant()
$actualSignedPackageHash = (Get-FileHash -LiteralPath $signedPackage -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expectedSignedPackageHash -notmatch "^[0-9a-f]{64}$" -or $actualSignedPackageHash -cne $expectedSignedPackageHash) {
    throw "The frozen signed QA MSIX hash does not match its immutable signing state."
}
$sourcePackageHash = (Get-FileHash -LiteralPath $packages[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sourcePackageHash -cne ([string]$signingState.sourcePackageSha256).ToLowerInvariant()) {
    throw "The unsigned source MSIX no longer matches the package that was signed once for both passes."
}
$candidateManifestHash = (Get-FileHash -LiteralPath (Join-Path $candidate "SHA256SUMS.txt") -Algorithm SHA256).Hash.ToLowerInvariant()
if ($candidateManifestHash -cne ([string]$signingState.candidateManifestSha256).ToLowerInvariant()) {
    throw "The candidate manifest no longer matches the manifest frozen before QA signing."
}
$signature = Get-AuthenticodeSignature -FilePath $signedPackage
if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -cne $Publisher) {
    throw "The frozen one-time signed QA MSIX is not currently valid for the fixed Partner Center publisher."
}
$preexistingPackages = @(Get-AppxPackage -Name $IdentityName -ErrorAction SilentlyContinue)
if ($preexistingPackages.Count -gt 0) {
    $names = ($preexistingPackages | ForEach-Object { $_.PackageFullName }) -join ", "
    throw "Refusing to alter a pre-existing package with identity '$IdentityName': $names"
}
$preexistingProcesses = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -ieq "StatFlow.Workbench.Desktop.exe" -or $_.Name -ieq "statflow-backend.exe"
})
if ($preexistingProcesses.Count -gt 0) {
    $processes = ($preexistingProcesses | ForEach-Object { "$($_.Name) [$($_.ProcessId)]" }) -join ", "
    throw "Refusing to alter pre-existing Survey Data Workbench processes: $processes"
}

if (-not $DiagnosticsDirectory) {
    $DiagnosticsDirectory = Join-Path ([IO.Path]::GetTempPath()) "statflow-msix-diagnostics-pass-$Pass"
}
New-Item -ItemType Directory -Path $DiagnosticsDirectory -Force | Out-Null
$DiagnosticsDirectory = (Resolve-Path -LiteralPath $DiagnosticsDirectory).Path
$transcript = Join-Path $DiagnosticsDirectory "lifecycle-transcript.txt"
Start-Transcript -Path $transcript -Force | Out-Null

function Assert-WackXmlPass {
    param([Parameter(Mandatory = $true)][string]$ReportPath)
    $reportItem = Get-Item -LiteralPath $ReportPath
    if ($reportItem.Length -lt 512 -or $reportItem.Length -gt 50MB) {
        throw "WACK XML report size is outside the strict evidence bounds."
    }
    [xml]$report = Get-Content -LiteralPath $ReportPath -Raw
    $root = $report.DocumentElement
    if (-not $root -or $root.LocalName -cne "REPORT") { throw "WACK XML root is not REPORT." }
    $overallResult = $root.GetAttribute("OVERALL_RESULT")
    $partialRun = $root.GetAttribute("PARTIAL_RUN")
    $latestVersion = $root.GetAttribute("LATEST_VERSION")
    $kitVersion = $root.GetAttribute("VERSION")
    if ($overallResult -cne "PASS") { throw "WACK OVERALL_RESULT was '$overallResult', not PASS." }
    if ($partialRun -cne "FALSE") { throw "WACK PARTIAL_RUN was '$partialRun', not FALSE." }
    if ($latestVersion -cne "TRUE") { throw "WACK LATEST_VERSION was '$latestVersion', not TRUE." }
    if ($kitVersion -notmatch '^\d+(?:\.\d+){1,3}$') { throw "WACK VERSION is missing or malformed." }
    $tests = @($root.SelectNodes(".//*[local-name()='TEST']"))
    if ($tests.Count -eq 0) { throw "WACK XML contains no TEST nodes." }
    $indices = [Collections.Generic.HashSet[int]]::new()
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($test in $tests) {
        $indexText = $test.GetAttribute("INDEX")
        $index = 0
        $name = $test.GetAttribute("NAME")
        if (-not [int]::TryParse($indexText, [ref]$index) -or $index -lt 0 -or -not $indices.Add($index)) {
            throw "WACK TEST indices are missing, malformed, or duplicated."
        }
        if ([string]::IsNullOrWhiteSpace($name) -or -not $names.Add($name)) {
            throw "WACK TEST names are missing or duplicated."
        }
        $results = @($test.SelectNodes("./*[local-name()='RESULT']"))
        if ($results.Count -ne 1) { throw "Each WACK TEST must have exactly one direct RESULT." }
        $result = $results[0].InnerText.Trim().ToUpperInvariant()
        if ($result -notin @("PASS", "NOT_APPLICABLE")) {
            throw "WACK TEST '$name' returned '$result'."
        }
    }
    return [pscustomobject]@{
        OverallResult = $overallResult
        PartialRun = $partialRun
        LatestVersion = $latestVersion
        KitVersion = $kitVersion
        TestCount = $tests.Count
    }
}

function Invoke-BoundedNativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "$Label did not start." }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $killError = ""
            try { $process.Kill($true) } catch { $killError = $_.Exception.Message }
            if (-not $process.WaitForExit(30000) -or -not $process.HasExited) {
                throw "$Label timed out and remained alive after process-tree termination attempt: $killError"
            }
            throw "$Label exceeded its $TimeoutSeconds second hard timeout."
        }
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [Parameter(Mandatory = $true)][string]$FailureMessage,
        [int]$TimeoutSeconds = 90
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $value = & $Condition
        if ($null -ne $value -and $value -ne $false) { return $value }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $FailureMessage
}

function Assert-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $normalizedPath.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label '$normalizedPath' is not inside the installed package root '$normalizedRoot'."
    }
    return $normalizedPath
}

function Assert-ExactInstalledManifest($Package) {
    $manifest = Get-AppxPackageManifest -Package $Package
    $applications = @($manifest.Package.Applications.Application)
    if ([string]$manifest.Package.Identity.Name -cne "LAIZEYU.SurveyDataWorkbenchbyLAIZEYU" -or
        [string]$manifest.Package.Identity.Publisher -cne "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8" -or
        [string]$manifest.Package.Identity.Version -cne "1.1.0.0" -or
        [string]$manifest.Package.Properties.PublisherDisplayName -cne "LAI ZEYU" -or
        $applications.Count -ne 1 -or [string]$applications[0].Id -cne "StatFlowWorkbench" -or
        [string]$applications[0].Executable -cne "StatFlow.Workbench.Desktop.exe" -or
        [string]$applications[0].EntryPoint -cne "Windows.FullTrustApplication") {
        throw "Installed manifest does not preserve the literal production identity, version, author display name, application ID, executable, and entry point."
    }
    return $manifest
}

function New-OwnedProcessRecord($Process) {
    if (-not $Process -or -not $Process.ExecutablePath -or -not $Process.CreationDate) {
        throw "Owned process did not expose an executable path and creation identity."
    }
    return [pscustomobject]@{
        Id = [uint32]$Process.ProcessId
        Name = [string]$Process.Name
        ExecutablePath = [IO.Path]::GetFullPath([string]$Process.ExecutablePath)
        CreationDate = ([DateTime]$Process.CreationDate).ToUniversalTime().ToString("o")
        ParentProcessId = [uint32]$Process.ParentProcessId
    }
}

function Assert-OwnedProcessIdentity($Record) {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($Record.Id)" -ErrorAction SilentlyContinue
    if (-not $current) { return $null }
    $currentCreation = ([DateTime]$current.CreationDate).ToUniversalTime().ToString("o")
    $currentPath = if ($current.ExecutablePath) { [IO.Path]::GetFullPath([string]$current.ExecutablePath) } else { "" }
    if ([string]$current.Name -ine [string]$Record.Name -or
        $currentPath -ine [string]$Record.ExecutablePath -or
        $currentCreation -cne [string]$Record.CreationDate -or
        [uint32]$current.ParentProcessId -ne [uint32]$Record.ParentProcessId) {
        throw "PID $($Record.Id) no longer matches the owned name/path/creation/parent identity."
    }
    return $current
}

function Stop-OwnedProcess($Record, [string]$Label) {
    $current = Assert-OwnedProcessIdentity -Record $Record
    if (-not $current) { return }
    Stop-Process -Id ([uint32]$Record.Id) -Force -ErrorAction Stop
    Wait-Until `
        -Condition { -not (Get-Process -Id ([uint32]$Record.Id) -ErrorAction SilentlyContinue) } `
        -FailureMessage "$Label remained alive" `
        -TimeoutSeconds 30 | Out-Null
}

function Wait-ExternalDesktopReady($DesktopRecord, $BackendRecord, [string]$Label) {
    if ([uint32]$BackendRecord.ParentProcessId -ne [uint32]$DesktopRecord.Id) {
        throw "$Label sidecar record does not belong to the exact desktop process."
    }
    Wait-Until -Condition {
        Assert-OwnedProcessIdentity -Record $DesktopRecord | Out-Null
        $process = Get-Process -Id ([uint32]$DesktopRecord.Id) -ErrorAction SilentlyContinue
        if ($process -and $process.MainWindowHandle -ne 0 -and
            $process.MainWindowTitle -ceq "Survey Data Workbench by LAI ZEYU") { return $true }
        return $false
    } -FailureMessage "$Label did not expose the exact product window title." -TimeoutSeconds 120 | Out-Null
    Wait-Until -Condition {
        Assert-OwnedProcessIdentity -Record $BackendRecord | Out-Null
        $listeners = @(Get-NetTCPConnection -State Listen -OwningProcess ([uint32]$BackendRecord.Id) -ErrorAction SilentlyContinue)
        if ($listeners.Count -eq 1 -and [string]$listeners[0].LocalAddress -ceq "127.0.0.1" -and
            [int]$listeners[0].LocalPort -ge 1024 -and [int]$listeners[0].LocalPort -le 65535) { return $true }
        return $false
    } -FailureMessage "$Label sidecar did not expose exactly one loopback listener." -TimeoutSeconds 120 | Out-Null
    $readyEventName = "Local\LAISystems.StatFlowWorkbench.Ready.$([uint32]$DesktopRecord.Id)"
    $readyEvent = Wait-Until -Condition {
        Assert-OwnedProcessIdentity -Record $DesktopRecord | Out-Null
        try { return [Threading.EventWaitHandle]::OpenExisting($readyEventName) }
        catch [Threading.WaitHandleCannotBeOpenedException] { return $null }
    } -FailureMessage "$Label did not publish its post-navigation UI readiness event." -TimeoutSeconds 120
    try {
        if (-not $readyEvent.WaitOne(0)) {
            throw "$Label UI readiness event was not signaled."
        }
    } finally {
        $readyEvent.Dispose()
    }
}

function Get-DescendantProcesses {
    param([Parameter(Mandatory = $true)][uint32]$RootProcessId)
    $all = @(Get-CimInstance Win32_Process)
    $known = [Collections.Generic.HashSet[uint32]]::new()
    [void]$known.Add($RootProcessId)
    $result = [Collections.Generic.List[object]]::new()
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($process in $all) {
            if ($known.Contains([uint32]$process.ProcessId)) { continue }
            if ($known.Contains([uint32]$process.ParentProcessId)) {
                [void]$known.Add([uint32]$process.ProcessId)
                $result.Add($process)
                $changed = $true
            }
        }
    }
    return @($result)
}

if (-not ("StatFlow.CI.PackageActivator" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace StatFlow.CI
{
    [Flags]
    public enum ActivateOptions : uint
    {
        None = 0,
        NoErrorUI = 2,
        NoSplashScreen = 4,
    }

    [ComImport]
    [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IApplicationActivationManager
    {
        [PreserveSig]
        int ActivateApplication(
            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments,
            ActivateOptions options,
            out uint processId);

        [PreserveSig]
        int ActivateForFile(IntPtr itemArray, [MarshalAs(UnmanagedType.LPWStr)] string verb, out uint processId);
        [PreserveSig]
        int ActivateForProtocol(IntPtr itemArray, out uint processId);
    }

    [ComImport]
    [Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    internal class ApplicationActivationManager
    {
    }

    public static class PackageActivator
    {
        public static uint Activate(string appUserModelId)
        {
            var manager = (IApplicationActivationManager)new ApplicationActivationManager();
            var result = manager.ActivateApplication(
                appUserModelId,
                null,
                ActivateOptions.NoErrorUI | ActivateOptions.NoSplashScreen,
                out var processId);
            if (result < 0) Marshal.ThrowExceptionForHR(result);
            return processId;
        }
    }
}
"@
}

$installedPackage = $null
$packageInstallAttempted = $false
$createdPackageFullName = $null
$createdPackageFamilyName = $null
$createdInstallLocation = $null
$packageDataRoot = $null
$desktopProcess = $null
$backendProcessId = $null
$webViewProcessIds = @()
$ownedProcessRecords = [Collections.Generic.List[object]]::new()
$succeeded = $false
$evidence = [ordered]@{
    pass = $Pass
    candidateManifest = (Get-FileHash (Join-Path $candidate "SHA256SUMS.txt") -Algorithm SHA256).Hash.ToLowerInvariant()
    signedPackageSha256 = $expectedSignedPackageHash
    identityName = $IdentityName
    publisher = $Publisher
    publisherDisplayName = $PublisherDisplayName
    packageFullName = $null
    firstDesktopProcessId = $null
    firstBackendProcessId = $null
    webViewProcessCount = 0
    forcedExitKilledSidecar = $false
    relaunchSucceeded = $false
    uninstallRemovedLocalState = $false
    wackOverallResult = $null
    wackPartialRun = $null
    wackLatestVersion = $null
    wackKitVersion = $null
    wackToolFileVersion = $null
    wackToolSha256 = $null
    wackReportSha256 = $null
    wackReportLength = 0
    firstExternalLaunchVerified = $false
    secondExternalLaunchVerified = $false
    sameSignedPackageVerified = $true
}

try {
    # Microsoft documents this exact reset/test order. Missing WACK, a native
    # non-zero exit, a missing report, a partial run, or any result other than
    # PASS is a hard failure; this CI gate must never degrade to a skip.
    $appCert = Get-TrustedWindowsAppCertificationKit
    $appCertItem = Get-Item -LiteralPath $appCert
    $evidence.wackToolFileVersion = [string]$appCertItem.VersionInfo.FileVersion
    $evidence.wackToolSha256 = (Get-FileHash -LiteralPath $appCert -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($evidence.wackToolFileVersion -cne $ExpectedWackToolFileVersion -or
        $evidence.wackToolSha256 -cne $ExpectedWackToolSha256) {
        throw "appcert.exe does not match the exact protected approved version and SHA-256."
    }
    $currentSessionId = (Get-Process -Id $PID).SessionId
    if ($currentSessionId -le 0) {
        throw "WACK requires an active interactive Windows user session; session 0 is not accepted."
    }
    $wackReport = Join-Path $DiagnosticsDirectory "wack-report.xml"
    if (Test-Path -LiteralPath $wackReport) {
        Remove-Item -LiteralPath $wackReport -Force
    }
    if (Test-Path -LiteralPath $wackReport) {
        throw "A stale WACK report could not be removed before this pass."
    }
    $wackStartedAtUtc = [DateTime]::UtcNow
    $resetExitCode = Invoke-BoundedNativeProcess `
        -FilePath $appCert `
        -Arguments @("reset") `
        -TimeoutSeconds 300 `
        -Label "appcert.exe reset"
    if ($resetExitCode -ne 0) {
        throw "appcert.exe reset failed with exit code $resetExitCode."
    }
    $wackExitCode = Invoke-BoundedNativeProcess `
        -FilePath $appCert `
        -Arguments @("test", "-appxpackagepath", $signedPackage, "-reportoutputpath", $wackReport) `
        -TimeoutSeconds 5400 `
        -Label "appcert.exe test"
    if ($wackExitCode -ne 0) {
        throw "appcert.exe test failed with exit code $wackExitCode. Inspect wack-report.xml."
    }
    if (-not (Test-Path -LiteralPath $wackReport -PathType Leaf) -or
        (Get-Item -LiteralPath $wackReport).Length -le 0) {
        throw "WACK did not create a non-empty XML report."
    }
    if ((Get-Item -LiteralPath $wackReport).LastWriteTimeUtc -lt $wackStartedAtUtc.AddSeconds(-2)) {
        throw "WACK report predates this certification run."
    }
    $wackSummary = Assert-WackXmlPass -ReportPath $wackReport
    $evidence.wackOverallResult = $wackSummary.OverallResult
    $evidence.wackPartialRun = $wackSummary.PartialRun
    $evidence.wackLatestVersion = $wackSummary.LatestVersion
    $evidence.wackKitVersion = $wackSummary.KitVersion
    $evidence.wackReportSha256 = (Get-FileHash -LiteralPath $wackReport -Algorithm SHA256).Hash.ToLowerInvariant()
    $evidence.wackReportLength = [long](Get-Item -LiteralPath $wackReport).Length
    if ($evidence.wackKitVersion -cne $ExpectedWackKitVersion) {
        throw "WACK report VERSION does not match the exact protected approved kit version."
    }

    $existing = @(Get-AppxPackage -Name $IdentityName -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        throw "The candidate identity appeared before installation; refusing to remove or replace it."
    }
    $packageInstallAttempted = $true
    Add-AppxPackage -Path $signedPackage
    $installedPackage = Wait-Until `
        -Condition { Get-AppxPackage -Name $IdentityName -ErrorAction SilentlyContinue | Select-Object -First 1 } `
        -FailureMessage "The signed development MSIX did not install."
    $createdPackageFullName = [string]$installedPackage.PackageFullName
    if ([string]::IsNullOrWhiteSpace($createdPackageFullName)) {
        throw "The installed package did not expose an exact PackageFullName for bounded cleanup."
    }
    if ($installedPackage.Publisher -cne $Publisher) {
        throw "Installed Publisher '$($installedPackage.Publisher)' does not match '$Publisher'."
    }
    $createdPackageFamilyName = [string]$installedPackage.PackageFamilyName
    $createdInstallLocation = [IO.Path]::GetFullPath([string]$installedPackage.InstallLocation)
    if ($createdPackageFamilyName -cnotmatch '^LAIZEYU\.SurveyDataWorkbenchbyLAIZEYU_[A-Za-z0-9]+$' -or
        [string]::IsNullOrWhiteSpace($createdInstallLocation)) {
        throw "Installed package family or location is malformed."
    }
    $installedManifest = Assert-ExactInstalledManifest -Package $installedPackage
    foreach ($legalName in @("LICENSE.txt", "NOTICE.md", "THIRD_PARTY_NOTICES_SUMMARY.md", "THIRD_PARTY_NOTICES.txt")) {
        $legalPath = Join-Path $installedPackage.InstallLocation "legal\$legalName"
        if (-not (Test-Path -LiteralPath $legalPath -PathType Leaf) -or (Get-Item -LiteralPath $legalPath).Length -le 0) {
            throw "Installed package is missing legal notice: $legalName"
        }
    }

    $evidence.packageFullName = $installedPackage.PackageFullName
    $appUserModelId = "$($installedPackage.PackageFamilyName)!StatFlowWorkbench"
    $packagesDataParent = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Packages")).TrimEnd('\')
    $packageDataRoot = [IO.Path]::GetFullPath((Join-Path $packagesDataParent $createdPackageFamilyName))
    if ([IO.Directory]::GetParent($packageDataRoot).FullName.TrimEnd('\') -cne $packagesDataParent) {
        throw "Package data root escaped the exact LocalAppData Packages directory."
    }
    if (Test-Path -LiteralPath $packageDataRoot -PathType Container) {
        if (((Get-Item -LiteralPath $packageDataRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Package data root is a reparse point."
        }
        $preexistingPackageData = @(Get-ChildItem -LiteralPath $packageDataRoot -Force)
        if ($preexistingPackageData.Count -gt 0) {
            throw "Package data already existed before the first launch; refusing to overwrite or later delete it."
        }
    }
    $localState = Join-Path $packageDataRoot "LocalState"
    $firstProcessId = [StatFlow.CI.PackageActivator]::Activate($appUserModelId)
    $desktopProcess = Wait-Until `
        -Condition {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId=$firstProcessId" -ErrorAction SilentlyContinue
            if ($process -and $process.ExecutablePath -and $process.CreationDate) { return $process }
            return $null
        } `
        -FailureMessage "The packaged WPF desktop did not remain running after activation."
    $firstDesktopRecord = New-OwnedProcessRecord -Process $desktopProcess
    $ownedProcessRecords.Add($firstDesktopRecord)
    $evidence.firstDesktopProcessId = $firstProcessId
    $desktopExecutable = $desktopProcess.ExecutablePath
    if (-not $desktopExecutable) { throw "The activated desktop process did not expose an executable path." }
    Assert-PathWithinRoot -Path $desktopExecutable -Root $installedPackage.InstallLocation -Label "Desktop process" | Out-Null
    $expectedDesktopExecutable = [IO.Path]::GetFullPath((Join-Path $installedPackage.InstallLocation "StatFlow.Workbench.Desktop.exe"))
    if ([IO.Path]::GetFullPath($desktopExecutable) -cne $expectedDesktopExecutable) { throw "Desktop process did not execute the literal manifest executable path." }

    $backend = Wait-Until `
        -Condition {
            Get-CimInstance Win32_Process -Filter "Name='statflow-backend.exe'" |
                Where-Object { [uint32]$_.ParentProcessId -eq [uint32]$firstProcessId } |
                Select-Object -First 1
        } `
        -FailureMessage "The packaged desktop did not start its Python sidecar." `
        -TimeoutSeconds 120
    $backendProcessId = [uint32]$backend.ProcessId
    $firstBackendRecord = New-OwnedProcessRecord -Process $backend
    $ownedProcessRecords.Add($firstBackendRecord)
    $evidence.firstBackendProcessId = $backendProcessId
    if (-not $backend.ExecutablePath) { throw "The packaged sidecar did not expose an executable path." }
    Assert-PathWithinRoot -Path $backend.ExecutablePath -Root $installedPackage.InstallLocation -Label "Sidecar process" | Out-Null
    $expectedBackendExecutable = [IO.Path]::GetFullPath((Join-Path $installedPackage.InstallLocation "backend\statflow-backend.exe"))
    if ([IO.Path]::GetFullPath([string]$backend.ExecutablePath) -cne $expectedBackendExecutable) { throw "Sidecar process did not execute the literal packaged backend path." }

    $webViews = Wait-Until `
        -Condition {
            $descendants = @(Get-DescendantProcesses -RootProcessId $firstProcessId)
            $matches = @($descendants | Where-Object { $_.Name -ieq "msedgewebview2.exe" })
            if ($matches.Count -gt 0) { return $matches }
            return $null
        } `
        -FailureMessage "Microsoft Edge WebView2 did not initialize for the packaged desktop." `
        -TimeoutSeconds 120
    $webViewProcessIds = @($webViews | ForEach-Object { [uint32]$_.ProcessId })
    foreach ($childProcessId in $webViewProcessIds) {
        $webView = @($webViews | Where-Object { [uint32]$_.ProcessId -eq $childProcessId })[0]
        $ownedProcessRecords.Add((New-OwnedProcessRecord -Process $webView))
    }
    $evidence.webViewProcessCount = $webViewProcessIds.Count

    foreach ($requiredDirectory in @("jobs", "logs", "WebView2")) {
        $requiredPath = Join-Path $localState $requiredDirectory
        Wait-Until `
            -Condition { Test-Path -LiteralPath $requiredPath -PathType Container } `
            -FailureMessage "Packaged application data was not created under LocalState: $requiredDirectory" | Out-Null
    }
    Wait-ExternalDesktopReady -DesktopRecord $firstDesktopRecord -BackendRecord $firstBackendRecord -Label "First installed launch"
    $evidence.firstExternalLaunchVerified = $true
    $evidence.firstUiReadySignalVerified = $true

    Stop-OwnedProcess -Record $firstDesktopRecord -Label "The force-terminated WPF process"
    Wait-Until `
        -Condition { -not (Assert-OwnedProcessIdentity -Record $firstBackendRecord) } `
        -FailureMessage "The sidecar survived forced WPF termination; Job Object/watchdog failed." `
        -TimeoutSeconds 30 | Out-Null
    foreach ($childProcessId in $webViewProcessIds) {
        $childRecord = @($ownedProcessRecords | Where-Object { [uint32]$_.Id -eq [uint32]$childProcessId })[0]
        Wait-Until `
            -Condition { -not (Assert-OwnedProcessIdentity -Record $childRecord) } `
            -FailureMessage "A WebView2 child survived forced WPF termination; Job Object cleanup failed." `
            -TimeoutSeconds 30 | Out-Null
    }
    $evidence.forcedExitKilledSidecar = $true

    $secondProcessId = [StatFlow.CI.PackageActivator]::Activate($appUserModelId)
    $desktopProcess = Wait-Until `
        -Condition {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId=$secondProcessId" -ErrorAction SilentlyContinue
            if ($process -and $process.ExecutablePath -and $process.CreationDate) { return $process }
            return $null
        } `
        -FailureMessage "The packaged desktop did not relaunch after forced termination."
    $secondDesktopRecord = New-OwnedProcessRecord -Process $desktopProcess
    $ownedProcessRecords.Add($secondDesktopRecord)
    $secondDesktopExecutable = $desktopProcess.ExecutablePath
    if (-not $secondDesktopExecutable) { throw "The relaunched desktop process did not expose an executable path." }
    Assert-PathWithinRoot -Path $secondDesktopExecutable -Root $installedPackage.InstallLocation -Label "Relaunched desktop process" | Out-Null
    if ([IO.Path]::GetFullPath($secondDesktopExecutable) -cne $expectedDesktopExecutable) { throw "Relaunched desktop did not execute the literal manifest executable path." }
    $secondBackend = Wait-Until `
        -Condition {
            Get-CimInstance Win32_Process -Filter "Name='statflow-backend.exe'" |
                Where-Object { [uint32]$_.ParentProcessId -eq [uint32]$secondProcessId } |
                Select-Object -First 1
        } `
        -FailureMessage "The sidecar did not restart with the packaged desktop." `
        -TimeoutSeconds 120
    $secondBackendRecord = New-OwnedProcessRecord -Process $secondBackend
    $ownedProcessRecords.Add($secondBackendRecord)
    if (-not $secondBackend.ExecutablePath) { throw "The relaunched sidecar did not expose an executable path." }
    Assert-PathWithinRoot -Path $secondBackend.ExecutablePath -Root $installedPackage.InstallLocation -Label "Relaunched sidecar process" | Out-Null
    if ([IO.Path]::GetFullPath([string]$secondBackend.ExecutablePath) -cne $expectedBackendExecutable) { throw "Relaunched sidecar did not execute the literal packaged backend path." }
    $secondWebViews = Wait-Until `
        -Condition {
            $descendants = @(Get-DescendantProcesses -RootProcessId $secondProcessId)
            $matches = @($descendants | Where-Object { $_.Name -ieq "msedgewebview2.exe" })
            if ($matches.Count -gt 0) { return $matches }
            return $null
        } `
        -FailureMessage "WebView2 did not reinitialize after forced desktop termination." `
        -TimeoutSeconds 120
    $secondWebViewProcessIds = @($secondWebViews | ForEach-Object { [uint32]$_.ProcessId })
    foreach ($childProcessId in $secondWebViewProcessIds) {
        $webView = @($secondWebViews | Where-Object { [uint32]$_.ProcessId -eq $childProcessId })[0]
        $ownedProcessRecords.Add((New-OwnedProcessRecord -Process $webView))
    }
    Wait-ExternalDesktopReady -DesktopRecord $secondDesktopRecord -BackendRecord $secondBackendRecord -Label "Relaunched installed app"
    $evidence.secondExternalLaunchVerified = $true
    $evidence.secondUiReadySignalVerified = $true
    $evidence.relaunchSucceeded = $true
    Set-Content -LiteralPath (Join-Path $localState "ci-uninstall-probe.txt") -Value "pass-$Pass" -Encoding UTF8

    Stop-OwnedProcess -Record $secondDesktopRecord -Label "Relaunched desktop"
    Wait-Until `
        -Condition { -not (Assert-OwnedProcessIdentity -Record $secondBackendRecord) } `
        -FailureMessage "The relaunched sidecar survived desktop termination." `
        -TimeoutSeconds 30 | Out-Null
    foreach ($childProcessId in $secondWebViewProcessIds) {
        $childRecord = @($ownedProcessRecords | Where-Object { [uint32]$_.Id -eq [uint32]$childProcessId })[0]
        Wait-Until `
            -Condition { -not (Assert-OwnedProcessIdentity -Record $childRecord) } `
            -FailureMessage "A relaunched WebView2 child survived desktop termination." `
            -TimeoutSeconds 30 | Out-Null
    }
    $exactInstalled = @(Get-AppxPackage -Name $IdentityName -ErrorAction Stop |
        Where-Object { $_.PackageFullName -ceq $createdPackageFullName })
    if ($exactInstalled.Count -ne 1) {
        throw "The exact PackageFullName was absent or duplicated immediately before uninstall."
    }
    $uninstallLocation = [IO.Path]::GetFullPath([string]$exactInstalled[0].InstallLocation)
    if ($exactInstalled[0].Publisher -cne $Publisher -or
        [string]$exactInstalled[0].PackageFamilyName -cne $createdPackageFamilyName -or
        $uninstallLocation -cne $createdInstallLocation) {
        throw "Package publisher/family/install location changed before exact uninstall."
    }
    Assert-ExactInstalledManifest -Package $exactInstalled[0] | Out-Null
    $uninstallTree = @(Get-Item -LiteralPath $uninstallLocation -Force; Get-ChildItem -LiteralPath $uninstallLocation -Recurse -Force)
    if (@($uninstallTree | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
        throw "Installed package tree contains a reparse point before uninstall."
    }
    if (-not (Test-Path -LiteralPath $expectedDesktopExecutable -PathType Leaf) -or
        -not (Test-Path -LiteralPath $expectedBackendExecutable -PathType Leaf)) {
        throw "Literal installed desktop or sidecar executable path disappeared before uninstall."
    }
    Remove-AppxPackage -Package $createdPackageFullName
    $installedPackage = $null
    Wait-Until `
        -Condition {
            -not @(Get-AppxPackage -Name $IdentityName -ErrorAction SilentlyContinue |
                Where-Object { $_.PackageFullName -ceq $createdPackageFullName }).Count
        } `
        -FailureMessage "The exact development PackageFullName remained registered after uninstall." | Out-Null
    Wait-Until `
        -Condition { -not (Test-Path -LiteralPath $localState) } `
        -FailureMessage "LocalState remained after MSIX uninstall." `
        -TimeoutSeconds 60 | Out-Null
    $evidence.uninstallRemovedLocalState = $true
    $evidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $DiagnosticsDirectory "lifecycle-evidence.json") -Encoding UTF8
    $succeeded = $true
    Write-Host "MSIX lifecycle pass $Pass succeeded for $($evidence.packageFullName)."
} finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    foreach ($record in @($ownedProcessRecords | Group-Object Id | ForEach-Object { $_.Group[0] })) {
        try {
            Stop-OwnedProcess -Record $record -Label "Owned process"
        } catch {
            $cleanupErrors.Add("Owned process $($record.Name) [$($record.Id)] was not safely stopped: $($_.Exception.Message)")
        }
    }
    if ($packageInstallAttempted) {
        try {
            if ([string]::IsNullOrWhiteSpace($createdPackageFullName)) {
                $unownedMatches = @(Get-AppxPackage -Name $IdentityName -ErrorAction SilentlyContinue)
                if ($unownedMatches.Count -gt 0) {
                    throw "installation did not capture an exact PackageFullName; refusing broad identity cleanup"
                }
            } else {
                $exactRemaining = @(Get-AppxPackage -Name $IdentityName -ErrorAction SilentlyContinue |
                    Where-Object { $_.PackageFullName -ceq $createdPackageFullName })
                if ($exactRemaining.Count -gt 1) {
                    throw "multiple registrations unexpectedly share the captured PackageFullName"
                }
                if ($exactRemaining.Count -eq 1) {
                    $remainingLocation = [IO.Path]::GetFullPath([string]$exactRemaining[0].InstallLocation)
                    if ($exactRemaining[0].Publisher -cne $Publisher -or
                        [string]$exactRemaining[0].PackageFamilyName -cne $createdPackageFamilyName -or
                        $remainingLocation -cne $createdInstallLocation) {
                        throw "refusing to remove captured PackageFullName whose publisher/family/install location changed"
                    }
                    Assert-ExactInstalledManifest -Package $exactRemaining[0] | Out-Null
                    Remove-AppxPackage -Package $createdPackageFullName -ErrorAction Stop
                }
                if (@(Get-AppxPackage -Name $IdentityName -ErrorAction SilentlyContinue |
                    Where-Object { $_.PackageFullName -ceq $createdPackageFullName }).Count -gt 0) {
                    throw "captured PackageFullName still exists"
                }
            }
            if ($packageDataRoot) {
                Wait-Until `
                    -Condition { -not (Test-Path -LiteralPath $packageDataRoot) } `
                    -FailureMessage "package data created by this pass still exists" `
                    -TimeoutSeconds 60 | Out-Null
            }
        } catch {
            $cleanupErrors.Add("The package created by this pass was not fully removed: $($_.Exception.Message)")
        }
    }
    try {
        $finalSignedPackageHash = (Get-FileHash -LiteralPath $signedPackage -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($finalSignedPackageHash -cne $expectedSignedPackageHash) {
            throw "signed MSIX hash changed from $expectedSignedPackageHash to $finalSignedPackageHash"
        }
    } catch {
        $cleanupErrors.Add("Frozen signed QA package integrity failed: $($_.Exception.Message)")
    }
    if (-not $succeeded) {
        $evidence["completed"] = $false
        $evidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $DiagnosticsDirectory "lifecycle-evidence.json") -Encoding UTF8
    }
    $evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $DiagnosticsDirectory "lifecycle-evidence.json") -Encoding UTF8
    try { Stop-Transcript | Out-Null } catch { }
    if ($cleanupErrors.Count -gt 0) {
        throw ($cleanupErrors -join [Environment]::NewLine)
    }
}
