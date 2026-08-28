param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,
    [Parameter(Mandatory = $true)]
    [string]$StatePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "Trusted-WindowsSdkTool.ps1")

if (-not $IsWindows) { throw "SSL.com eSigner CKA signing must run on Windows." }
if ($env:STATFLOW_TRUSTED_GITHUB_BUILD -cne "1") {
    throw "Refusing production signing outside the protected GitHub release workflow."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Invoke-BoundedSignTool {
    param([string]$SignTool, [string[]]$Arguments, [string]$Label)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $SignTool
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
        if (-not $process.WaitForExit(900000)) {
            $killError = ""
            try { $process.Kill($true) } catch { $killError = $_.Exception.Message }
            if (-not $process.WaitForExit(30000) -or -not $process.HasExited) {
                throw "$Label remained alive after process-tree termination attempt: $killError"
            }
            throw "$Label exceeded its 15 minute hard timeout."
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

function Get-AppPackageManifestPublisher([string]$FilePath) {
    $archive = [IO.Compression.ZipFile]::OpenRead($FilePath)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -ceq "AppxManifest.xml" })
        if ($entries.Count -ne 1 -or $entries[0].Length -le 0 -or $entries[0].Length -gt 4MB) {
            throw "App package signing requires one bounded AppxManifest.xml."
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
        $publisher = if ($identity -and $identity.Attributes["Publisher"]) {
            [string]$identity.Attributes["Publisher"].Value
        } else { "" }
        if ([string]::IsNullOrWhiteSpace($publisher)) {
            throw "App package Identity Publisher is missing."
        }
        return $publisher
    } finally { $archive.Dispose() }
}

$stateFile = (Resolve-Path -LiteralPath $StatePath).Path
$state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
if ([int]$state.schemaVersion -ne 2 -or [string]$state.provider -cne "SSL.com eSigner CKA 1.1.2" -or
    [string]$state.mode -cne "product") {
    throw "eSigner CKA state has an unexpected schema, provider, or mode."
}
$thumbprint = ([string]$state.signerThumbprint).ToUpperInvariant()
if ($thumbprint -notmatch "^[0-9A-F]{40,64}$" -or [string]$state.signerSimpleName -notin @("LAI ZEYU", "来泽宇")) {
    throw "eSigner CKA state does not identify the exact allowed LAI author certificate."
}
$certificates = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction Stop |
    Where-Object { ([string]$_.Thumbprint).ToUpperInvariant() -ceq $thumbprint })
if ($certificates.Count -ne 1 -or -not $certificates[0].HasPrivateKey -or
    $certificates[0].Subject -cne [string]$state.signerSubject) {
    throw "The exact eSigner CKA certificate/private-key binding is absent or ambiguous."
}
$signTool = Get-TrustedWindowsSdkTool -Name "signtool.exe"
$workspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\') + '\'
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'

foreach ($requested in $Path) {
    $resolved = (Resolve-Path -LiteralPath $requested).Path
    $item = Get-Item -LiteralPath $resolved
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The cloud signer target must be one regular non-symlink file: $resolved"
    }
    if (-not ($resolved.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase) -or
        $resolved.StartsWith($runnerTemp, [StringComparison]::OrdinalIgnoreCase))) {
        throw "The cloud signer target must be inside GITHUB_WORKSPACE or RUNNER_TEMP: $resolved"
    }
    $extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
    $isAppPackage = $extension -in @(".msix", ".appx")
    if ($isAppPackage) {
        $manifestPublisher = Get-AppPackageManifestPublisher -FilePath $resolved
        if ($manifestPublisher -cne $certificates[0].Subject) {
            throw "Refusing to sign app package Publisher '$manifestPublisher' with certificate Subject '$($certificates[0].Subject)'. Use the separate signed EXE for GitHub when the Partner Center technical Publisher differs."
        }
    } else {
        $stream = [IO.File]::OpenRead($resolved)
        try {
            if ($stream.Length -lt 2 -or $stream.ReadByte() -ne 0x4D -or $stream.ReadByte() -ne 0x5A) {
                throw "The cloud signer accepts only MZ Portable Executables or real MSIX/AppX packages: $resolved"
            }
        } finally { $stream.Dispose() }
    }

    $before = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
    Invoke-BoundedSignTool `
        -SignTool $signTool `
        -Arguments @(
            "sign", "/fd", "SHA256", "/tr", "http://ts.ssl.com", "/td", "SHA256",
            "/s", "My", "/sha1", $thumbprint,
            "/d", "Survey Data Workbench by LAI ZEYU", $resolved
        ) `
        -Label "Windows SDK SignTool through SSL.com eSigner CKA"
    $after = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($after -ceq $before) { throw "SignTool returned success without changing '$($item.Name)'." }
    if ($isAppPackage) {
        & (Join-Path $PSScriptRoot "Verify-GitHubReleaseSignature.ps1") -Path $resolved
    } else {
        & (Join-Path $PSScriptRoot "Verify-GitHubReleaseSignature.ps1") -Path $resolved -AllowPortableExecutable
    }
    if ($LASTEXITCODE -ne 0) { throw "Immediate trusted signature verification failed for '$($item.Name)'." }
}
