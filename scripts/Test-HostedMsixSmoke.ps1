param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateRoot,
    [Parameter(Mandatory = $true)]
    [string]$SigningStatePath,
    [Parameter(Mandatory = $true)]
    [ValidateSet("push", "pull_request")]
    [string]$RunKind,
    [string]$DiagnosticsDirectory = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true

if (-not $IsWindows) { throw "Test-HostedMsixSmoke.ps1 must run on Windows." }

$identityName = "LAIZEYU.SurveyDataWorkbenchbyLAIZEYU"
$publisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"
$candidate = (Resolve-Path -LiteralPath $CandidateRoot).Path
$statePath = (Resolve-Path -LiteralPath $SigningStatePath).Path
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$signedPackage = (Resolve-Path -LiteralPath ([string]$state.signedPackagePath)).Path
$expectedSignedHash = ([string]$state.signedPackageSha256).ToLowerInvariant()

if ([int]$state.schemaVersion -ne 1 -or [string]$state.publisher -cne $publisher) {
    throw "Hosted signing state does not bind the exact Store technical publisher."
}
if ((Get-FileHash -LiteralPath $signedPackage -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedSignedHash) {
    throw "Hosted signed MSIX differs from its frozen signing state."
}
$signature = Get-AuthenticodeSignature -LiteralPath $signedPackage
if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -cne $publisher) {
    throw "Hosted signed MSIX does not have the exact temporary QA identity."
}
& (Join-Path $PSScriptRoot "Verify-ArtifactHashes.ps1") -ArtifactRoot $candidate

if (-not $DiagnosticsDirectory) {
    $DiagnosticsDirectory = Join-Path ([IO.Path]::GetTempPath()) ("statflow-hosted-msix-" + [Guid]::NewGuid().ToString("N"))
}
New-Item -ItemType Directory -Path $DiagnosticsDirectory -Force | Out-Null
$diagnostics = (Resolve-Path -LiteralPath $DiagnosticsDirectory).Path

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [Parameter(Mandatory = $true)][string]$FailureMessage,
        [int]$TimeoutSeconds = 120
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $value = & $Condition
        if ($null -ne $value -and $value -ne $false) { return $value }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $FailureMessage
}

function New-OwnedProcessRecord($Process) {
    if (-not $Process -or -not $Process.ExecutablePath -or -not $Process.CreationDate) {
        throw "Hosted smoke process does not expose an exact path and creation identity."
    }
    return [pscustomobject]@{
        Id = [uint32]$Process.ProcessId
        Name = [string]$Process.Name
        Path = [IO.Path]::GetFullPath([string]$Process.ExecutablePath)
        Created = ([DateTime]$Process.CreationDate).ToUniversalTime().ToString("o")
        ParentId = [uint32]$Process.ParentProcessId
    }
}

function Get-OwnedProcess($Record) {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($Record.Id)" -ErrorAction SilentlyContinue
    if (-not $current) { return $null }
    $currentPath = if ($current.ExecutablePath) { [IO.Path]::GetFullPath([string]$current.ExecutablePath) } else { "" }
    $currentCreated = ([DateTime]$current.CreationDate).ToUniversalTime().ToString("o")
    if ([string]$current.Name -ine [string]$Record.Name -or
        $currentPath -ine [string]$Record.Path -or
        $currentCreated -cne [string]$Record.Created -or
        [uint32]$current.ParentProcessId -ne [uint32]$Record.ParentId) {
        throw "Hosted smoke PID $($Record.Id) no longer has its captured process identity."
    }
    return $current
}

function Stop-OwnedProcess($Record) {
    if (-not (Get-OwnedProcess -Record $Record)) { return }
    Stop-Process -Id ([uint32]$Record.Id) -Force -ErrorAction Stop
    Wait-Until `
        -Condition { -not (Get-Process -Id ([uint32]$Record.Id) -ErrorAction SilentlyContinue) } `
        -FailureMessage "Hosted smoke process $($Record.Id) remained alive after exact termination." `
        -TimeoutSeconds 30 | Out-Null
}

if (-not ("StatFlow.Hosted.PackageActivator" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace StatFlow.Hosted
{
    [Flags]
    public enum ActivateOptions : uint { None = 0, NoErrorUI = 2, NoSplashScreen = 4 }

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
    internal class ApplicationActivationManager { }

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

$preexistingPackages = @(Get-AppxPackage -Name $identityName -ErrorAction SilentlyContinue)
if ($preexistingPackages.Count -gt 0) {
    throw "Hosted runner already contains the reserved package identity; refusing to replace it."
}
$preexistingProcesses = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -ieq "StatFlow.Workbench.Desktop.exe" -or $_.Name -ieq "statflow-backend.exe"
})
if ($preexistingProcesses.Count -gt 0) {
    throw "Hosted runner already contains Survey Data Workbench processes."
}

$installAttempted = $false
$packageFullName = $null
$packageFamilyName = $null
$installLocation = $null
$desktopRecord = $null
$backendRecord = $null
$manifestHash = (Get-FileHash -LiteralPath (Join-Path $candidate "SHA256SUMS.txt") -Algorithm SHA256).Hash.ToLowerInvariant()
$succeeded = $false

try {
    $installAttempted = $true
    Add-AppxPackage -Path $signedPackage
    $package = Wait-Until `
        -Condition { Get-AppxPackage -Name $identityName -ErrorAction SilentlyContinue | Select-Object -First 1 } `
        -FailureMessage "Hosted signed MSIX did not install."
    $packageFullName = [string]$package.PackageFullName
    $packageFamilyName = [string]$package.PackageFamilyName
    $installLocation = [IO.Path]::GetFullPath([string]$package.InstallLocation)
    if ([string]::IsNullOrWhiteSpace($packageFullName) -or $package.Publisher -cne $publisher) {
        throw "Hosted installation did not expose the exact package identity and Publisher."
    }

    $manifest = Get-AppxPackageManifest -Package $package
    $applications = @($manifest.Package.Applications.Application)
    if ([string]$manifest.Package.Identity.Name -cne $identityName -or
        [string]$manifest.Package.Identity.Version -cne "1.1.0.0" -or
        [string]$manifest.Package.Properties.PublisherDisplayName -cne "LAI ZEYU" -or
        $applications.Count -ne 1 -or [string]$applications[0].Id -cne "StatFlowWorkbench" -or
        [string]$applications[0].Executable -cne "StatFlow.Workbench.Desktop.exe") {
        throw "Hosted installed manifest differs from the reserved Store identity or executable."
    }

    $sourceDesktop = Join-Path $candidate "layout\StatFlow.Workbench.Desktop.exe"
    $sourceBackend = Join-Path $candidate "layout\backend\statflow-backend.exe"
    $installedDesktop = Join-Path $installLocation "StatFlow.Workbench.Desktop.exe"
    $installedBackend = Join-Path $installLocation "backend\statflow-backend.exe"
    if ((Get-FileHash -LiteralPath $installedDesktop -Algorithm SHA256).Hash -cne
        (Get-FileHash -LiteralPath $sourceDesktop -Algorithm SHA256).Hash -or
        (Get-FileHash -LiteralPath $installedBackend -Algorithm SHA256).Hash -cne
        (Get-FileHash -LiteralPath $sourceBackend -Algorithm SHA256).Hash) {
        throw "Installed desktop or backend bytes differ from the hash-verified candidate layout."
    }

    & (Join-Path $PSScriptRoot "Test-WindowsSidecar.ps1") `
        -LayoutDirectory $installLocation `
        -DiagnosticsDirectory (Join-Path $diagnostics "installed-core")

    $appUserModelId = "$packageFamilyName!StatFlowWorkbench"
    $desktopProcessId = [StatFlow.Hosted.PackageActivator]::Activate($appUserModelId)
    $desktop = Wait-Until `
        -Condition {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId=$desktopProcessId" -ErrorAction SilentlyContinue
            if ($process -and $process.ExecutablePath -and $process.CreationDate) { return $process }
            return $null
        } `
        -FailureMessage "Hosted installed desktop did not remain running after package activation."
    $desktopRecord = New-OwnedProcessRecord -Process $desktop
    if ($desktopRecord.Path -cne [IO.Path]::GetFullPath($installedDesktop)) {
        throw "Hosted package activation did not start the literal installed desktop executable."
    }
    $backend = Wait-Until `
        -Condition {
            Get-CimInstance Win32_Process -Filter "Name='statflow-backend.exe'" |
                Where-Object { [uint32]$_.ParentProcessId -eq [uint32]$desktopProcessId } |
                Select-Object -First 1
        } `
        -FailureMessage "Hosted installed desktop did not start its packaged backend."
    $backendRecord = New-OwnedProcessRecord -Process $backend
    if ($backendRecord.Path -cne [IO.Path]::GetFullPath($installedBackend)) {
        throw "Hosted desktop started a backend outside the installed package."
    }
    Wait-Until `
        -Condition {
            $listeners = @(Get-NetTCPConnection -State Listen -OwningProcess ([uint32]$backendRecord.Id) -ErrorAction SilentlyContinue)
            if ($listeners.Count -eq 1 -and [string]$listeners[0].LocalAddress -ceq "127.0.0.1") { return $true }
            return $false
        } `
        -FailureMessage "Hosted installed backend did not expose exactly one IPv4 loopback listener." | Out-Null

    Stop-OwnedProcess -Record $desktopRecord
    Wait-Until `
        -Condition { -not (Get-OwnedProcess -Record $backendRecord) } `
        -FailureMessage "Hosted packaged backend survived desktop termination." `
        -TimeoutSeconds 30 | Out-Null
    $desktopRecord = $null
    $backendRecord = $null

    $exactPackage = @(Get-AppxPackage -Name $identityName -ErrorAction Stop |
        Where-Object { $_.PackageFullName -ceq $packageFullName })
    if ($exactPackage.Count -ne 1 -or [string]$exactPackage[0].PackageFamilyName -cne $packageFamilyName -or
        [IO.Path]::GetFullPath([string]$exactPackage[0].InstallLocation) -cne $installLocation) {
        throw "Hosted package identity changed before exact uninstall."
    }
    Remove-AppxPackage -Package $packageFullName
    Wait-Until `
        -Condition { -not @(Get-AppxPackage -Name $identityName -ErrorAction SilentlyContinue |
            Where-Object { $_.PackageFullName -ceq $packageFullName }).Count } `
        -FailureMessage "Hosted exact PackageFullName remained after uninstall." | Out-Null

    & (Join-Path $PSScriptRoot "Verify-ArtifactHashes.ps1") -ArtifactRoot $candidate
    if ((Get-FileHash -LiteralPath (Join-Path $candidate "SHA256SUMS.txt") -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifestHash) {
        throw "Hosted install/start/core/uninstall smoke changed candidate bytes."
    }
    [ordered]@{
        schemaVersion = 1
        runKind = $RunKind
        candidateManifestSha256 = $manifestHash
        signedQaPackageSha256 = $expectedSignedHash
        identityName = $identityName
        publisherDisplayName = "LAI ZEYU"
        author = "LAI ZEYU（来泽宇）"
        installVerified = $true
        installedBytesVerified = $true
        coreWorkflowVerified = $true
        desktopLaunchVerified = $true
        loopbackVerified = $true
        processTreeCleanupVerified = $true
        exactUninstallVerified = $true
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $diagnostics "hosted-msix-smoke.json") -Encoding UTF8
    $succeeded = $true
    Write-Host "Hosted MSIX install/start/core/uninstall smoke passed: $manifestHash"
} finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    foreach ($record in @($desktopRecord, $backendRecord)) {
        if (-not $record) { continue }
        try { Stop-OwnedProcess -Record $record } catch { $cleanupErrors.Add($_.Exception.Message) }
    }
    if ($installAttempted -and $packageFullName) {
        try {
            $remaining = @(Get-AppxPackage -Name $identityName -ErrorAction SilentlyContinue |
                Where-Object { $_.PackageFullName -ceq $packageFullName })
            if ($remaining.Count -gt 1) { throw "Hosted cleanup found duplicate exact PackageFullName records." }
            if ($remaining.Count -eq 1) {
                if ($remaining[0].Publisher -cne $publisher -or
                    [string]$remaining[0].PackageFamilyName -cne $packageFamilyName -or
                    [IO.Path]::GetFullPath([string]$remaining[0].InstallLocation) -cne $installLocation) {
                    throw "Hosted cleanup refused a package whose captured identity changed."
                }
                Remove-AppxPackage -Package $packageFullName -ErrorAction Stop
            }
        } catch { $cleanupErrors.Add($_.Exception.Message) }
    } elseif ($installAttempted) {
        $unknown = @(Get-AppxPackage -Name $identityName -ErrorAction SilentlyContinue)
        if ($unknown.Count -gt 0) {
            $cleanupErrors.Add("Installation did not capture an exact PackageFullName; refusing broad cleanup.")
        }
    }
    try {
        $finalSignedHash = (Get-FileHash -LiteralPath $signedPackage -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($finalSignedHash -cne $expectedSignedHash) { throw "Frozen hosted signed package changed." }
    } catch { $cleanupErrors.Add($_.Exception.Message) }
    if (-not $succeeded) {
        Write-Warning "Hosted MSIX smoke did not complete successfully."
    }
    if ($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join [Environment]::NewLine) }
}
