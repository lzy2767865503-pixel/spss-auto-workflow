param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerPath,
    [ValidateRange(1, 2)]
    [int]$Pass = 1,
    [Parameter(Mandatory = $true)]
    [string]$DiagnosticsDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $IsWindows) { throw "GitHub installer lifecycle testing must run on Windows." }
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$installerItem = Get-Item -LiteralPath $installer -Force
if ($installerItem.PSIsContainer -or ($installerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "GitHub lifecycle input must be one regular non-reparse installer file."
}
& (Join-Path $PSScriptRoot "Verify-GitHubReleaseSignature.ps1") -Path $installer
$installerHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
$installRoot = Join-Path $env:LOCALAPPDATA "Programs\Survey Data Workbench by LAI ZEYU"
$dataRoot = Join-Path $env:LOCALAPPDATA "LAI Systems\Survey Data Workbench"
$uninstallRegistry = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{8A95FB16-D832-4FE4-AD7C-CDFED12E4274}_is1"
$uninstallRegistryRelative = "Software\Microsoft\Windows\CurrentVersion\Uninstall\{8A95FB16-D832-4FE4-AD7C-CDFED12E4274}_is1"
$startMenuShortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Survey Data Workbench by LAI ZEYU.lnk"
$expectedDesktopPath = [IO.Path]::GetFullPath((Join-Path $installRoot "StatFlow.Workbench.Desktop.exe"))
$expectedBackendPath = [IO.Path]::GetFullPath((Join-Path $installRoot "backend\statflow-backend.exe"))
$expectedUninstallerPath = [IO.Path]::GetFullPath((Join-Path $installRoot "unins000.exe"))

foreach ($preexistingPath in @($installRoot, $dataRoot, $uninstallRegistry, $startMenuShortcut)) {
    if (Test-Path -LiteralPath $preexistingPath) {
        throw "Refusing to overwrite or later delete a pre-existing installer lifecycle path: $preexistingPath"
    }
}
$preexistingProcesses = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -ieq "StatFlow.Workbench.Desktop.exe" -or $_.Name -ieq "statflow-backend.exe"
})
if ($preexistingProcesses.Count -gt 0) {
    throw "Refusing to alter pre-existing Survey Data Workbench processes."
}
if (Test-Path -LiteralPath $DiagnosticsDirectory) {
    throw "Refusing to reuse a lifecycle diagnostics directory."
}
New-Item -ItemType Directory -Path $DiagnosticsDirectory | Out-Null
$diagnostics = (Resolve-Path -LiteralPath $DiagnosticsDirectory).Path

function Invoke-BoundedNativeProcess {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$Label)
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
                throw "$Label remained alive after process-tree termination attempt: $killError"
            }
            throw "$Label exceeded its $TimeoutSeconds second timeout."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $message = "$stdout`n$stderr"
            if ($message.Length -gt 4000) { $message = $message.Substring($message.Length - 4000) }
            throw "$Label failed with exit code $($process.ExitCode): $message"
        }
    } finally { $process.Dispose() }
}

function Wait-Until {
    param([scriptblock]$Condition, [string]$FailureMessage, [int]$TimeoutSeconds = 120)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $value = & $Condition
        if ($null -ne $value -and $value -ne $false) { return $value }
        Start-Sleep -Milliseconds 400
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $FailureMessage
}

function Assert-PathWithinRoot([string]$Path, [string]$Root, [string]$Label) {
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $normalizedPath.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escaped the exact installer root: $normalizedPath"
    }
    return $normalizedPath
}

function Assert-NoReparseTree([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $items = @(Get-Item -LiteralPath $Path -Force; Get-ChildItem -LiteralPath $Path -Recurse -Force)
    if (@($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
        throw "$Label contains a reparse point."
    }
}

function Test-MzFile([string]$FilePath) {
    $stream = [IO.File]::OpenRead($FilePath)
    try { return $stream.Length -ge 2 -and $stream.ReadByte() -eq 0x4D -and $stream.ReadByte() -eq 0x5A }
    finally { $stream.Dispose() }
}

if (-not (Test-MzFile -FilePath $installer)) {
    throw "GitHub lifecycle input does not have an MZ Portable Executable header."
}

function Get-OwnedUninstallRegistrySnapshot {
    $record = Get-ItemProperty -LiteralPath $uninstallRegistry -ErrorAction Stop
    $location = [IO.Path]::GetFullPath(([string]$record.InstallLocation).TrimEnd('\'))
    $uninstallCommand = ([string]$record.UninstallString).Trim()
    if ($uninstallCommand.Length -lt 3 -or $uninstallCommand[0] -ne '"' -or $uninstallCommand[-1] -ne '"') {
        throw "Exact uninstall registry command is not one quoted executable path."
    }
    $registryUninstaller = [IO.Path]::GetFullPath($uninstallCommand.Substring(1, $uninstallCommand.Length - 2))
    if ([string]$record.DisplayName -cne "Survey Data Workbench by LAI ZEYU 1.1.0" -or
        [string]$record.DisplayVersion -cne "1.1.0" -or
        [string]$record.Publisher -cne "LAI ZEYU" -or
        $location -cne [IO.Path]::GetFullPath($installRoot) -or
        $registryUninstaller -cne $expectedUninstallerPath) {
        throw "Uninstall registry record does not belong to the exact installed product/version/path."
    }
    return [pscustomobject]@{
        DisplayName = [string]$record.DisplayName
        DisplayVersion = [string]$record.DisplayVersion
        Publisher = [string]$record.Publisher
        InstallLocation = $location
        UninstallExecutable = $registryUninstaller
    }
}

function Assert-OwnedUninstallRegistrySnapshot($Expected) {
    $actual = Get-OwnedUninstallRegistrySnapshot
    foreach ($property in @('DisplayName', 'DisplayVersion', 'Publisher', 'InstallLocation', 'UninstallExecutable')) {
        if ([string]$actual.$property -cne [string]$Expected.$property) {
            throw "Exact uninstall registry record changed at property $property."
        }
    }
}

function Remove-ExactOwnedUninstallRegistryKey($Expected) {
    Assert-OwnedUninstallRegistrySnapshot -Expected $Expected
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($uninstallRegistryRelative, $false)
    $remaining = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($uninstallRegistryRelative, $false)
    try {
        if ($null -ne $remaining) { throw "Exact uninstall registry key remains after DeleteSubKeyTree." }
    } finally {
        if ($null -ne $remaining) { $remaining.Dispose() }
    }
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
    Wait-Until -Condition { -not (Get-Process -Id ([uint32]$Record.Id) -ErrorAction SilentlyContinue) } `
        -FailureMessage "$Label remained alive" -TimeoutSeconds 30 | Out-Null
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
}

$ownedProcesses = [Collections.Generic.List[object]]::new()
$installAttempted = $false
$installed = $false
$succeeded = $false
$ownedUninstallerHash = $null
$ownedRegistrySnapshot = $null
$evidence = [ordered]@{
    schemaVersion = 1
    pass = $Pass
    installerSha256 = $installerHash
    author = "LAI ZEYU（来泽宇）"
    installedPeCount = 0
    firstLaunchVerified = $false
    forcedExitKilledSidecar = $false
    relaunchVerified = $false
    uninstallVerified = $false
    userDataPolicy = "retained-by-uninstaller-and-removed-by-ci-owner"
}
try {
    $installAttempted = $true
    Invoke-BoundedNativeProcess `
        -FilePath $installer `
        -Arguments @("/CURRENTUSER", "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/DIR=$installRoot") `
        -TimeoutSeconds 900 `
        -Label "trusted GitHub installer"
    $desktop = $expectedDesktopPath
    Wait-Until -Condition { Test-Path -LiteralPath $desktop -PathType Leaf } -FailureMessage "Installer did not create the desktop executable." | Out-Null
    if (-not (Test-Path -LiteralPath $uninstallRegistry)) { throw "Installer did not create its exact HKCU uninstall record." }
    $installed = $true
    Assert-NoReparseTree -Path $installRoot -Label "Fresh installer root"
    if (-not (Test-Path -LiteralPath $startMenuShortcut -PathType Leaf)) { throw "Installer did not create the exact Start menu shortcut." }
    $shortcutItem = Get-Item -LiteralPath $startMenuShortcut -Force
    if (($shortcutItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Installed Start menu shortcut is a reparse point." }
    $uninstallers = @(Get-ChildItem -LiteralPath $installRoot -File -Filter "unins*.exe")
    if ($uninstallers.Count -ne 1) { throw "Installed tree does not contain exactly one signed uninstaller." }
    & (Join-Path $PSScriptRoot "Verify-GitHubReleaseSignature.ps1") -Path $uninstallers[0].FullName
    if ([IO.Path]::GetFullPath($uninstallers[0].FullName) -cne $expectedUninstallerPath) {
        throw "Installed uninstaller is not the literal fresh-install path unins000.exe."
    }
    $ownedUninstallerHash = (Get-FileHash -LiteralPath $uninstallers[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $ownedRegistrySnapshot = Get-OwnedUninstallRegistrySnapshot

    $manifest = Join-Path $installRoot "SHA256SUMS.txt"
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "Installed signed-layout manifest is missing." }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in Get-Content -LiteralPath $manifest -Encoding UTF8) {
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Installed signed-layout manifest is malformed." }
        $relative = $Matches[2]
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Split('/') -contains '..') { throw "Unsafe installed hash path: $relative" }
        if (-not $expected.Add($relative)) { throw "Duplicate installed hash path: $relative" }
        $target = Assert-PathWithinRoot -Path (Join-Path $installRoot $relative) -Root $installRoot -Label "Installed hash target"
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Matches[1]) {
            throw "Installed layout hash mismatch: $relative"
        }
    }
    $installedRelativeFiles = @(
        Get-ChildItem -LiteralPath $installRoot -File -Recurse |
            ForEach-Object { [IO.Path]::GetRelativePath($installRoot, $_.FullName).Replace('\', '/') }
    )
    foreach ($relative in $installedRelativeFiles) {
        if ($expected.Contains($relative) -or $relative -ceq "SHA256SUMS.txt" -or
            $relative -cmatch '^unins[0-9]+\.(exe|dat|msg)$') {
            continue
        }
        throw "Installed tree contains a file outside the signed layout/uninstaller allowlist: $relative"
    }
    $installedPes = @(Get-ChildItem -LiteralPath $installRoot -File -Recurse | Where-Object { Test-MzFile $_.FullName })
    if ($installedPes.Count -lt 3) { throw "Installed tree lacks desktop, sidecar, or signed uninstaller PEs." }
    foreach ($pe in $installedPes) {
        & (Join-Path $PSScriptRoot "Verify-GitHubReleaseSignature.ps1") -Path $pe.FullName -AllowPortableExecutable
    }
    $installerThumbprint = (Get-AuthenticodeSignature -LiteralPath $installer).SignerCertificate.Thumbprint.ToUpperInvariant()
    $installedThumbprints = @(
        $installedPes |
            ForEach-Object { (Get-AuthenticodeSignature -LiteralPath $_.FullName).SignerCertificate.Thumbprint.ToUpperInvariant() } |
            Sort-Object -Unique
    )
    if ($installedThumbprints.Count -ne 1 -or $installedThumbprints[0] -cne $installerThumbprint) {
        throw "Installer and every recursively discovered installed PE must use one exact signer thumbprint."
    }
    $evidence.installedPeCount = $installedPes.Count

    $first = Start-Process -FilePath $desktop -PassThru
    $firstDesktop = Wait-Until -Condition {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($first.Id)" -ErrorAction SilentlyContinue
        if ($process -and $process.ExecutablePath -and $process.CreationDate) { return $process }
        return $null
    } -FailureMessage "Installed desktop did not remain running."
    Assert-PathWithinRoot -Path $firstDesktop.ExecutablePath -Root $installRoot -Label "First desktop process" | Out-Null
    if ([IO.Path]::GetFullPath([string]$firstDesktop.ExecutablePath) -cne $expectedDesktopPath) { throw "First desktop process did not execute the literal installed executable path." }
    $firstRecord = New-OwnedProcessRecord -Process $firstDesktop
    $ownedProcesses.Add($firstRecord)
    $firstBackend = Wait-Until -Condition {
        Get-CimInstance Win32_Process -Filter "Name='statflow-backend.exe'" |
            Where-Object { [uint32]$_.ParentProcessId -eq [uint32]$first.Id } |
            Select-Object -First 1
    } -FailureMessage "Installed desktop did not start its sidecar."
    Assert-PathWithinRoot -Path $firstBackend.ExecutablePath -Root $installRoot -Label "First sidecar process" | Out-Null
    if ([IO.Path]::GetFullPath([string]$firstBackend.ExecutablePath) -cne $expectedBackendPath) { throw "First sidecar process did not execute the literal installed backend path." }
    $firstBackendRecord = New-OwnedProcessRecord -Process $firstBackend
    $ownedProcesses.Add($firstBackendRecord)
    Wait-ExternalDesktopReady -DesktopRecord $firstRecord -BackendRecord $firstBackendRecord -Label "First installer launch"
    $evidence.firstLaunchVerified = $true
    Stop-OwnedProcess -Record $firstRecord -Label "First desktop"
    Wait-Until -Condition { -not (Assert-OwnedProcessIdentity -Record $firstBackendRecord) } -FailureMessage "First sidecar survived forced desktop exit." -TimeoutSeconds 30 | Out-Null
    $evidence.forcedExitKilledSidecar = $true

    $second = Start-Process -FilePath $desktop -PassThru
    $secondDesktop = Wait-Until -Condition {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($second.Id)" -ErrorAction SilentlyContinue
        if ($process -and $process.ExecutablePath -and $process.CreationDate) { return $process }
        return $null
    } -FailureMessage "Relaunched desktop did not remain running."
    Assert-PathWithinRoot -Path $secondDesktop.ExecutablePath -Root $installRoot -Label "Relaunched desktop process" | Out-Null
    if ([IO.Path]::GetFullPath([string]$secondDesktop.ExecutablePath) -cne $expectedDesktopPath) { throw "Relaunched desktop process did not execute the literal installed executable path." }
    $secondRecord = New-OwnedProcessRecord -Process $secondDesktop
    $ownedProcesses.Add($secondRecord)
    $secondBackend = Wait-Until -Condition {
        Get-CimInstance Win32_Process -Filter "Name='statflow-backend.exe'" |
            Where-Object { [uint32]$_.ParentProcessId -eq [uint32]$second.Id } |
            Select-Object -First 1
    } -FailureMessage "Relaunched desktop did not start its sidecar."
    Assert-PathWithinRoot -Path $secondBackend.ExecutablePath -Root $installRoot -Label "Relaunched sidecar process" | Out-Null
    if ([IO.Path]::GetFullPath([string]$secondBackend.ExecutablePath) -cne $expectedBackendPath) { throw "Relaunched sidecar process did not execute the literal installed backend path." }
    $secondBackendRecord = New-OwnedProcessRecord -Process $secondBackend
    $ownedProcesses.Add($secondBackendRecord)
    Wait-ExternalDesktopReady -DesktopRecord $secondRecord -BackendRecord $secondBackendRecord -Label "Relaunched installer app"
    $evidence.relaunchVerified = $true
    Stop-OwnedProcess -Record $secondRecord -Label "Relaunched desktop"
    Wait-Until -Condition { -not (Assert-OwnedProcessIdentity -Record $secondBackendRecord) } -FailureMessage "Relaunched sidecar survived desktop exit." -TimeoutSeconds 30 | Out-Null

    Assert-NoReparseTree -Path $installRoot -Label "Installed tree before uninstaller execution"
    $uninstallers = @(Get-ChildItem -LiteralPath $installRoot -File -Filter "unins*.exe")
    if ($uninstallers.Count -ne 1 -or
        [IO.Path]::GetFullPath($uninstallers[0].FullName) -cne $expectedUninstallerPath -or
        (Get-FileHash -LiteralPath $uninstallers[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ownedUninstallerHash) {
        throw "Previously verified exact uninstaller changed before execution."
    }
    Assert-OwnedUninstallRegistrySnapshot -Expected $ownedRegistrySnapshot
    & (Join-Path $PSScriptRoot "Verify-GitHubReleaseSignature.ps1") -Path $uninstallers[0].FullName
    Invoke-BoundedNativeProcess `
        -FilePath $uninstallers[0].FullName `
        -Arguments @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") `
        -TimeoutSeconds 600 `
        -Label "exact GitHub uninstaller"
    Wait-Until -Condition { -not (Test-Path -LiteralPath $installRoot) } -FailureMessage "Uninstaller left the application directory." -TimeoutSeconds 60 | Out-Null
    Wait-Until -Condition { -not (Test-Path -LiteralPath $uninstallRegistry) } -FailureMessage "Uninstaller left its exact registry record." -TimeoutSeconds 60 | Out-Null
    Wait-Until -Condition { -not (Test-Path -LiteralPath $startMenuShortcut) } -FailureMessage "Uninstaller left the exact Start menu shortcut." -TimeoutSeconds 60 | Out-Null
    $installed = $false
    $evidence.uninstallVerified = $true
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -cne $installerHash) {
        throw "Installer bytes changed during lifecycle pass $Pass."
    }
    $evidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $diagnostics "github-installer-lifecycle.json") -Encoding UTF8
    $succeeded = $true
} finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    foreach ($record in @($ownedProcesses | Group-Object Id | ForEach-Object { $_.Group[0] })) {
        try {
            Stop-OwnedProcess -Record $record -Label "Owned process"
        } catch { $cleanupErrors.Add("Owned process cleanup failed: $($_.Exception.Message)") }
    }
    if ($installAttempted -and (Test-Path -LiteralPath $installRoot)) {
        try {
            $uninstallers = @(Get-ChildItem -LiteralPath $installRoot -File -Filter "unins*.exe")
            if ($uninstallers.Count -ne 1) { throw "cannot identify one exact uninstaller" }
            if ([IO.Path]::GetFullPath($uninstallers[0].FullName) -cne $expectedUninstallerPath) { throw "failure-path uninstaller path differs" }
            Assert-NoReparseTree -Path $installRoot -Label "Failure-path installer root"
            if ($ownedUninstallerHash -notmatch '^[0-9a-f]{64}$') { throw "no previously verified uninstaller hash is available" }
            if ($null -eq $ownedRegistrySnapshot) { throw "no previously verified uninstall registry record is available" }
            Assert-OwnedUninstallRegistrySnapshot -Expected $ownedRegistrySnapshot
            & (Join-Path $PSScriptRoot "Verify-GitHubReleaseSignature.ps1") -Path $uninstallers[0].FullName
            if ((Get-FileHash -LiteralPath $uninstallers[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ownedUninstallerHash) {
                throw "failure-path uninstaller differs from the previously verified signed bytes"
            }
            Invoke-BoundedNativeProcess -FilePath $uninstallers[0].FullName -Arguments @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") -TimeoutSeconds 600 -Label "failure-path exact uninstaller"
            if (Test-Path -LiteralPath $installRoot) { throw "application directory remains" }
        } catch { $cleanupErrors.Add("Exact installer cleanup failed: $($_.Exception.Message)") }
    }
    if (Test-Path -LiteralPath $startMenuShortcut) {
        try {
            $shortcutItem = Get-Item -LiteralPath $startMenuShortcut -Force
            $shortcutParent = [IO.Path]::GetFullPath((Split-Path -Parent $startMenuShortcut))
            $expectedShortcutParent = [IO.Path]::GetFullPath((Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"))
            if ($shortcutParent -cne $expectedShortcutParent -or $shortcutItem.PSIsContainer -or
                ($shortcutItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "exact CI-created shortcut path/type changed" }
            Remove-Item -LiteralPath $startMenuShortcut -Force
            if (Test-Path -LiteralPath $startMenuShortcut) { throw "exact CI-created shortcut remains" }
        } catch { $cleanupErrors.Add("Exact shortcut cleanup failed: $($_.Exception.Message)") }
    }
    if (Test-Path -LiteralPath $dataRoot) {
        try {
            $expectedDataRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "LAI Systems\Survey Data Workbench"))
            if ([IO.Path]::GetFullPath($dataRoot) -cne $expectedDataRoot) { throw "CI data root changed" }
            $dataItems = @(Get-Item -LiteralPath $dataRoot -Force; Get-ChildItem -LiteralPath $dataRoot -Recurse -Force)
            if (@($dataItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
                throw "CI-owned data root contains a reparse point; refusing recursive deletion"
            }
            Remove-Item -LiteralPath $dataRoot -Recurse -Force
            if (Test-Path -LiteralPath $dataRoot) { throw "CI-owned data root remains" }
        } catch { $cleanupErrors.Add("CI-owned data cleanup failed: $($_.Exception.Message)") }
    }
    if (Test-Path -LiteralPath $uninstallRegistry) {
        try {
            if ($null -eq $ownedRegistrySnapshot) { throw "no verified ownership snapshot is available" }
            Remove-ExactOwnedUninstallRegistryKey -Expected $ownedRegistrySnapshot
        } catch { $cleanupErrors.Add("Exact uninstall registry DeleteSubKeyTree cleanup failed: $($_.Exception.Message)") }
    }
    if (-not $succeeded) {
        $evidence["completed"] = $false
        $evidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $diagnostics "github-installer-lifecycle.json") -Encoding UTF8
    }
    if ($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join [Environment]::NewLine) }
}
