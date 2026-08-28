param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$requestedRoot = Get-Item -LiteralPath $ArtifactRoot -Force -ErrorAction Stop
if (-not $requestedRoot.PSIsContainer -or ($requestedRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Artifact root must be one regular directory, not a reparse point."
}
$root = $requestedRoot.FullName
$rootPrefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$hashFile = Join-Path $root "SHA256SUMS.txt"
if (-not (Test-Path -LiteralPath $hashFile -PathType Leaf)) { throw "Missing SHA256SUMS.txt under $root" }
$allItems = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)
if (@($allItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
    throw "Artifact tree contains a reparse point."
}
$hashItem = Get-Item -LiteralPath $hashFile -Force
if ($hashItem.Length -le 0 -or $hashItem.Length -gt 50MB) { throw "SHA256SUMS.txt size is outside strict bounds." }

$expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($line in Get-Content $hashFile -Encoding UTF8) {
    if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') {
        throw "Malformed SHA-256 manifest line."
    }
    $expectedHash = $Matches[1].ToLowerInvariant()
    $relative = $Matches[2].Replace(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '[\r\n]' -or $relative.Split('/') -contains '..') {
        throw "Unsafe path in SHA-256 manifest: $relative"
    }
    if ($expected.ContainsKey($relative)) { throw "Duplicate SHA-256 entry: $relative" }

    $target = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $target.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SHA-256 entry escapes the artifact root: $relative"
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Missing candidate file: $relative" }
    $actualHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw "SHA-256 mismatch: $relative" }
    $expected[$relative] = $expectedHash
}

$actualFiles = @($allItems | Where-Object { -not $_.PSIsContainer } |
    Where-Object { $_.FullName -ne $hashFile } |
    ForEach-Object {
        [IO.Path]::GetRelativePath($root, $_.FullName).Replace(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        )
    })
foreach ($relative in $actualFiles) {
    if (-not $expected.ContainsKey($relative)) { throw "Unhashed candidate file: $relative" }
}
if ($actualFiles.Count -ne $expected.Count) {
    throw "Candidate file count does not match the SHA-256 manifest."
}

if (-not (Test-Path (Join-Path $root "layout\StatFlow.Workbench.Desktop.exe"))) {
    throw "The verified candidate does not contain the desktop executable."
}
if (-not (Get-ChildItem -LiteralPath $root -File -Filter "*.msix")) {
    throw "The verified candidate does not contain an MSIX package."
}
Write-Host "Verified $($expected.Count) candidate files against SHA256SUMS.txt"
