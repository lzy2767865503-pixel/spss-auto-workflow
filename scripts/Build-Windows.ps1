param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [ValidateSet("x64")]
    [string]$Architecture = "x64",
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repo = Split-Path -Parent $PSScriptRoot
$venv = Join-Path $repo ".venv-windows"
$artifacts = Join-Path $repo "artifacts\windows-$Architecture"
$layout = Join-Path $artifacts "layout"
$backendDist = Join-Path $artifacts "pyinstaller"
$backendWork = Join-Path $artifacts "pyinstaller-work"

if (-not $IsWindows) { throw "Build-Windows.ps1 must run on Windows." }

function Assert-DisposableBuildTree([string]$Path, [string]$ExpectedPath, [string]$Label) {
    if ([IO.Path]::GetFullPath($Path) -cne [IO.Path]::GetFullPath($ExpectedPath)) {
        throw "$Label path changed; refusing recursive cleanup."
    }
    $parent = Split-Path -Parent $Path
    if (Test-Path -LiteralPath $parent) {
        $parentItem = Get-Item -LiteralPath $parent -Force
        if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label parent is a reparse point; refusing recursive cleanup."
        }
    }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $items = @(Get-Item -LiteralPath $Path -Force; Get-ChildItem -LiteralPath $Path -Recurse -Force)
    if (@($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
        throw "$Label contains a reparse point; refusing recursive cleanup."
    }
}

if (Test-Path -LiteralPath $artifacts) {
    Assert-DisposableBuildTree -Path $artifacts -ExpectedPath (Join-Path $repo "artifacts\windows-$Architecture") -Label "Windows artifact tree"
    Remove-Item -LiteralPath $artifacts -Recurse -Force
}
New-Item -ItemType Directory -Path $layout -Force | Out-Null

python -c "import sys; raise SystemExit(sys.version_info[:3] != (3, 12, 10))"
if ($LASTEXITCODE -ne 0) { throw "The Windows candidate requires exact Python 3.12.10." }
python (Join-Path $repo "scripts\check_attribution.py")
if ($LASTEXITCODE -ne 0) { throw "Bilingual attribution gate failed." }
if (Test-Path -LiteralPath $venv) {
    Assert-DisposableBuildTree -Path $venv -ExpectedPath (Join-Path $repo ".venv-windows") -Label "Windows build environment"
    Remove-Item -LiteralPath $venv -Recurse -Force
}
python -m venv $venv
if ($LASTEXITCODE -ne 0) { throw "Could not create the Windows Python environment." }
$python = Join-Path $venv "Scripts\python.exe"
& $python -m pip install "pip==26.2.1"
if ($LASTEXITCODE -ne 0) { throw "Could not install pinned pip 26.2.1." }
& $python -m pip install -r (Join-Path $repo "requirements-build.txt")
if ($LASTEXITCODE -ne 0) { throw "Could not install locked build dependencies." }

Push-Location (Join-Path $repo "frontend")
try {
    npm ci
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed." }
    npm run build
    if ($LASTEXITCODE -ne 0) { throw "Frontend build failed." }
} finally { Pop-Location }

if (-not $SkipTests) {
    & $python -m unittest discover -s (Join-Path $repo "tests") -v
    if ($LASTEXITCODE -ne 0) { throw "Python test gate failed." }
}

$pyInstallerArgs = @(
    "-m", "PyInstaller",
    "--noconfirm",
    "--clean",
    "--distpath", $backendDist,
    "--workpath", $backendWork,
    (Join-Path $repo "packaging\statflow-backend.spec")
)
& $python @pyInstallerArgs
if ($LASTEXITCODE -ne 0) { throw "PyInstaller build failed." }

$project = Join-Path $repo "desktop\StatFlow.Workbench.Desktop\StatFlow.Workbench.Desktop.csproj"
$publishArgs = @(
    "publish", $project,
    "--configuration", $Configuration,
    "--runtime", "win-$Architecture",
    "--self-contained", "true",
    "--output", $layout
)
dotnet @publishArgs
if ($LASTEXITCODE -ne 0) { throw ".NET desktop publish failed." }

$backendTarget = Join-Path $layout "backend"
New-Item -ItemType Directory -Path $backendTarget -Force | Out-Null
Copy-Item -Recurse -Force (Join-Path $backendDist "statflow-backend\*") $backendTarget
if ($Configuration -eq "Release") {
    $debugSymbols = @(Get-ChildItem -LiteralPath $layout -Recurse -File -Force | Where-Object { $_.Extension -ieq ".pdb" })
    if ($debugSymbols.Count -gt 0) {
        throw "Release layout contains forbidden PDB debug symbols: $($debugSymbols.FullName -join ', ')"
    }
    Write-Host "Release layout debug-symbol gate passed: no PDB files."
}

$legalTarget = Join-Path $layout "legal"
New-Item -ItemType Directory -Path $legalTarget -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repo "LICENSE") -Destination (Join-Path $legalTarget "LICENSE.txt")
Copy-Item -LiteralPath (Join-Path $repo "NOTICE.md") -Destination (Join-Path $legalTarget "NOTICE.md")
Copy-Item -LiteralPath (Join-Path $repo "THIRD_PARTY_NOTICES.md") -Destination (Join-Path $legalTarget "THIRD_PARTY_NOTICES_SUMMARY.md")
& $python (Join-Path $repo "scripts\Generate-ThirdPartyNotices.py") `
    --repo $repo `
    --publish-directory $layout `
    --output (Join-Path $legalTarget "THIRD_PARTY_NOTICES.txt")
if ($LASTEXITCODE -ne 0) { throw "Could not generate candidate third-party notices." }

if (-not (Test-Path (Join-Path $layout "StatFlow.Workbench.Desktop.exe"))) {
    throw "Desktop executable was not produced."
}
if (-not (Test-Path (Join-Path $backendTarget "statflow-backend.exe"))) {
    throw "Backend sidecar was not produced."
}
foreach ($legalName in @("LICENSE.txt", "NOTICE.md", "THIRD_PARTY_NOTICES_SUMMARY.md", "THIRD_PARTY_NOTICES.txt")) {
    $legalPath = Join-Path $legalTarget $legalName
    if (-not (Test-Path -LiteralPath $legalPath -PathType Leaf) -or (Get-Item -LiteralPath $legalPath).Length -le 0) {
        throw "Required legal notice is missing or empty: $legalName"
    }
}

Write-Host "Windows layout ready: $layout"
