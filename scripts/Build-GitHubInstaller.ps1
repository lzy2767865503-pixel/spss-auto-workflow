param(
    [Parameter(Mandatory = $true)]
    [string]$LayoutDirectory,
    [Parameter(Mandatory = $true)]
    [string]$InnoCompilerPath,
    [Parameter(Mandatory = $true)]
    [string]$SigningStatePath,
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,
    [string]$Version = "1.1.0"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $IsWindows) { throw "The trusted GitHub installer must be built on Windows." }
if ($env:STATFLOW_TRUSTED_GITHUB_BUILD -cne "1") {
    throw "Refusing to build a public installer outside the protected trusted-release job."
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "GitHub installer Version must have three numeric components." }

function Test-MzFile([string]$FilePath) {
    $stream = [IO.File]::OpenRead($FilePath)
    try { return $stream.Length -ge 2 -and $stream.ReadByte() -eq 0x4D -and $stream.ReadByte() -eq 0x5A }
    finally { $stream.Dispose() }
}

function Invoke-BoundedCompiler([string]$FilePath, [string[]]$Arguments) {
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
        if (-not $process.Start()) { throw "Inno Setup compiler did not start." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(1800000)) {
            $killError = ""
            try { $process.Kill($true) } catch { $killError = $_.Exception.Message }
            if (-not $process.WaitForExit(30000) -or -not $process.HasExited) {
                throw "Inno Setup remained alive after process-tree termination attempt: $killError"
            }
            throw "Inno Setup exceeded its 30 minute hard timeout."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $message = "$stdout`n$stderr"
            if ($message.Length -gt 8000) { $message = $message.Substring($message.Length - 8000) }
            throw "Inno Setup failed with exit code $($process.ExitCode): $message"
        }
    } finally { $process.Dispose() }
}

$layout = (Resolve-Path -LiteralPath $LayoutDirectory).Path
$compiler = (Resolve-Path -LiteralPath $InnoCompilerPath).Path
$signingState = (Resolve-Path -LiteralPath $SigningStatePath).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$template = Join-Path $repo "packaging\GitHubInstaller.iss"
if (-not (Test-Path -LiteralPath (Join-Path $layout "StatFlow.Workbench.Desktop.exe") -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $layout "backend\statflow-backend.exe") -PathType Leaf)) {
    throw "The GitHub installer layout is incomplete."
}
if (Test-Path -LiteralPath $output) { throw "Refusing to reuse an existing public installer output directory." }
New-Item -ItemType Directory -Path $output | Out-Null

$compilerItem = Get-Item -LiteralPath $compiler
if ($compilerItem.PSIsContainer -or ($compilerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Inno Setup compiler must be one regular file."
}
$compilerSignature = Get-AuthenticodeSignature -FilePath $compiler
if ($compilerSignature.Status -ne "Valid" -or -not $compilerSignature.SignerCertificate -or
    $compilerSignature.SignerCertificate.GetNameInfo(
        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
        $false
    ) -cne "Pyrsys B.V.") {
    throw "Inno Setup compiler is not the trusted Pyrsys B.V. Authenticode build."
}

$allLayoutFiles = @(Get-ChildItem -LiteralPath $layout -File -Recurse | Sort-Object FullName)
if ($allLayoutFiles.Count -eq 0) { throw "GitHub installer layout is empty." }
foreach ($file in $allLayoutFiles) {
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "GitHub installer layout cannot contain a reparse point: $($file.FullName)"
    }
}
$portableExecutables = @($allLayoutFiles | Where-Object { Test-MzFile $_.FullName })
if ($portableExecutables.Count -lt 2) { throw "GitHub installer layout did not contain the desktop and sidecar PEs." }
& (Join-Path $PSScriptRoot "Invoke-SslEsignerSign.ps1") `
    -Path @($portableExecutables.FullName) `
    -StatePath $signingState

$hashFile = Join-Path $layout "SHA256SUMS.txt"
if (Test-Path -LiteralPath $hashFile) { throw "Fresh GitHub layout unexpectedly contains SHA256SUMS.txt." }
$lines = @(
    Get-ChildItem -LiteralPath $layout -File -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($layout, $_.FullName).Replace('\', '/')
            if ($relative -match '[\r\n]' -or $relative.Split('/') -contains '..') {
                throw "Unsafe path in signed layout: $relative"
            }
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            "$hash  $relative"
        }
)
[IO.File]::WriteAllLines($hashFile, $lines, [Text.UTF8Encoding]::new($false))
$layoutManifestHash = (Get-FileHash -LiteralPath $hashFile -Algorithm SHA256).Hash.ToLowerInvariant()

foreach ($pe in $portableExecutables) {
    & (Join-Path $PSScriptRoot "Verify-GitHubReleaseSignature.ps1") -Path $pe.FullName -AllowPortableExecutable
}

$powerShell = (Get-Process -Id $PID).Path
$signScript = Join-Path $PSScriptRoot "Invoke-SslEsignerSign.ps1"
# Inno expands $q to a quote and $f to the generated uninstaller path.  The
# callback therefore uses the same bounded CKA+SignTool verifier as every
# layout PE, without a PFX or exported private key.
$signCommand = '$q' + $powerShell + '$q -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $q' +
    $signScript + '$q -Path $f -StatePath $q' + $signingState + '$q'
$runnerTemp = (Resolve-Path -LiteralPath $env:RUNNER_TEMP).Path
$runnerTempItem = Get-Item -LiteralPath $runnerTemp -Force
if (-not $runnerTempItem.PSIsContainer -or ($runnerTempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "RUNNER_TEMP must be one existing non-reparse directory."
}
$signedUninstallerCache = Join-Path $runnerTemp ("statflow-inno-signed-uninstaller-" + [Guid]::NewGuid().ToString("N"))
if ([IO.Directory]::GetParent([IO.Path]::GetFullPath($signedUninstallerCache)).FullName.TrimEnd('\') -cne
        [IO.Path]::GetFullPath($runnerTemp).TrimEnd('\') -or
    (Test-Path -LiteralPath $signedUninstallerCache)) {
    throw "Refusing to reuse an existing Inno signed-uninstaller cache."
}
New-Item -ItemType Directory -Path $signedUninstallerCache | Out-Null
$arguments = @(
    "/DLayoutDirectory=$layout",
    "/DInstallerOutputDirectory=$output",
    "/DSignedUninstallerDirectory=$signedUninstallerCache",
    "/DApplicationVersion=$Version",
    "/SLAISigner=$signCommand",
    $template
)
try {
    Invoke-BoundedCompiler -FilePath $compiler -Arguments $arguments

    $cachedFiles = @(Get-ChildItem -LiteralPath $signedUninstallerCache -File -Recurse)
    $cachedExecutables = @($cachedFiles | Where-Object { Test-MzFile $_.FullName })
    if ($cachedExecutables.Count -lt 1) {
        throw "Inno Setup did not preserve a signed uninstaller in the dedicated cache."
    }
    foreach ($cachedFile in $cachedFiles) {
        if (($cachedFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The Inno signed-uninstaller cache contains a reparse point."
        }
    }
    foreach ($cachedExecutable in $cachedExecutables) {
        & (Join-Path $PSScriptRoot "Verify-GitHubReleaseSignature.ps1") `
            -Path $cachedExecutable.FullName `
            -AllowPortableExecutable
    }
} finally {
    if (Test-Path -LiteralPath $signedUninstallerCache) {
        $cacheItems = @(
            Get-Item -LiteralPath $signedUninstallerCache -Force
            Get-ChildItem -LiteralPath $signedUninstallerCache -Recurse -Force
        )
        if (@($cacheItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
            throw "Refusing recursive signed-uninstaller cache cleanup because a reparse point appeared."
        }
        Remove-Item -LiteralPath $signedUninstallerCache -Recurse -Force
    }
    if (Test-Path -LiteralPath $signedUninstallerCache) {
        throw "Failed to remove the dedicated Inno signed-uninstaller cache."
    }
}

$installers = @(Get-ChildItem -LiteralPath $output -File -Filter "*.exe")
if ($installers.Count -ne 1 -or @(Get-ChildItem -LiteralPath $output -File).Count -ne 1) {
    throw "Inno Setup output must contain exactly one signed installer."
}
& (Join-Path $PSScriptRoot "Verify-GitHubReleaseSignature.ps1") -Path $installers[0].FullName

$currentLayoutManifestHash = (Get-FileHash -LiteralPath $hashFile -Algorithm SHA256).Hash.ToLowerInvariant()
if ($currentLayoutManifestHash -cne $layoutManifestHash) {
    throw "Installer compilation changed the frozen signed layout manifest."
}
$manifestRelativePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($line in Get-Content -LiteralPath $hashFile -Encoding UTF8) {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Malformed signed layout hash line." }
    if (-not $manifestRelativePaths.Add($Matches[2])) { throw "Duplicate signed layout hash path." }
    $target = [IO.Path]::GetFullPath((Join-Path $layout $Matches[2]))
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Matches[1]) {
        throw "Signed layout changed during installer compilation: $($Matches[2])"
    }
}
$currentLayoutRelativePaths = @(
    Get-ChildItem -LiteralPath $layout -File -Recurse |
        Where-Object { $_.FullName -cne $hashFile } |
        ForEach-Object { [IO.Path]::GetRelativePath($layout, $_.FullName).Replace('\', '/') } |
        Sort-Object
)
if ($currentLayoutRelativePaths.Count -ne $manifestRelativePaths.Count -or
    (Compare-Object @($manifestRelativePaths | Sort-Object) $currentLayoutRelativePaths)) {
    throw "Signed layout inventory changed after its manifest was frozen."
}

$installerHash = (Get-FileHash -LiteralPath $installers[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$releaseHashFile = Join-Path $output "SHA256SUMS.txt"
[IO.File]::WriteAllText(
    $releaseHashFile,
    "$installerHash  $($installers[0].Name)`n",
    [Text.UTF8Encoding]::new($false)
)
Write-Host "Trusted GitHub EXE installer ready; signed layout manifest SHA-256: $layoutManifestHash"
