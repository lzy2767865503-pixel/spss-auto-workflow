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
$hashFile = Join-Path $root "SHA256SUMS.txt"
$allItems = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)
if (@($allItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
    throw "Artifact tree contains a reparse point."
}
if (Test-Path -LiteralPath $hashFile) { throw "Refusing to overwrite an existing SHA256SUMS.txt." }
$files = @($allItems | Where-Object { -not $_.PSIsContainer } |
    Where-Object { $_.FullName -ne $hashFile } |
    Sort-Object FullName)
if (-not $files -or $files.Count -gt 100000) { throw "Candidate file count is empty or exceeds 100000." }

$relativePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$lines = @(foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    if ($relative -match '[\r\n]' -or $relative.Split('/') -contains '..' -or -not $relativePaths.Add($relative)) {
        throw "Candidate relative path is unsafe or duplicated: $relative"
    }
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relative"
})
[IO.File]::WriteAllLines($hashFile, $lines, [Text.UTF8Encoding]::new($false))

if (-not (Test-Path (Join-Path $root "layout\StatFlow.Workbench.Desktop.exe"))) {
    throw "The hash set does not contain the desktop executable."
}
if (-not (Get-ChildItem -LiteralPath $root -File -Filter "*.msix")) {
    throw "The hash set does not contain an MSIX candidate."
}
Write-Host "Wrote $($lines.Count) SHA-256 entries to $hashFile"
