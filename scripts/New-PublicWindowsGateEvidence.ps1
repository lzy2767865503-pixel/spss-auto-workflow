param(
    [Parameter(Mandatory = $true)]
    [string]$TestResultsDirectory,
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,
    [Parameter(Mandatory = $true)]
    [string]$Commit
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Commit -cnotmatch '^[0-9a-f]{40}$') { throw "Canonical evidence requires one lowercase 40-character commit ID." }
$source = (Resolve-Path -LiteralPath $TestResultsDirectory).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Refusing to reuse a canonical public evidence directory." }
$sourceItems = @(Get-Item -LiteralPath $source -Force; Get-ChildItem -LiteralPath $source -Recurse -Force)
if (@($sourceItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
    throw "Private gate evidence contains a reparse point."
}
New-Item -ItemType Directory -Path $output | Out-Null

function Require-Exact([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Read-Json([string]$Relative) {
    $path = Join-Path $source $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-Item -LiteralPath $path).Length -le 0 -or (Get-Item -LiteralPath $path).Length -gt 1MB) {
        throw "Missing or oversized private gate input: $Relative"
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Get-EvidenceFile([string]$Relative, [long]$MinimumBytes, [long]$MaximumBytes) {
    $path = Join-Path $source $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Private evidence file is missing: $Relative" }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt $MinimumBytes -or $item.Length -gt $MaximumBytes) {
        throw "Private evidence file is linked or outside its exact size bounds: $Relative"
    }
    return $item
}

$candidateDigestPath = Join-Path $source "release-integrity\candidate-manifest-sha256.txt"
if (-not (Test-Path -LiteralPath $candidateDigestPath -PathType Leaf)) { throw "Candidate manifest digest is missing." }
$candidateDigest = (Get-Content -LiteralPath $candidateDigestPath -Raw).Trim()
if ($candidateDigest -cnotmatch '^[0-9a-f]{64}$') { throw "Candidate manifest digest is malformed." }
$binding = Read-Json "release-integrity\runner-binding.private.json"
$bindingProperties = @(
    "approvedWackKitVersion", "approvedWackToolFileVersion", "approvedWackToolSha256",
    "candidateManifestSha256", "evidenceKind", "handoffId", "osBuild", "osCaption", "osEvidenceSlug",
    "privateAclTextSha256", "repository", "repositoryId", "schemaVersion", "sessionId", "sourceCommit",
    "storeProductId", "upstreamRunAttempt", "upstreamRunId", "reviewWorkflowPath",
    "reviewWorkflowRunAttempt", "reviewWorkflowRunId", "reviewWorkflowSha"
) | Sort-Object
Require-Exact (-not (Compare-Object $bindingProperties (@($binding.PSObject.Properties.Name) | Sort-Object))) "Private runner binding schema differs."
Require-Exact ([int]$binding.schemaVersion -eq 2 -and
    [string]$binding.evidenceKind -ceq "same-run-reviewed-workflow-assertion") "Private runner binding scope is invalid."
Require-Exact ([string]$binding.repository -cmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -and
    ([string]$binding.repository).Length -le 200 -and
    [string]$binding.repositoryId -ceq "1311362169" -and
    [string]$binding.sourceCommit -ceq $Commit) "Private runner binding repository or commit differs."
Require-Exact ([string]$binding.upstreamRunId -cmatch '^\d+$' -and
    ([string]$binding.upstreamRunId).Length -le 20 -and
    [int]$binding.upstreamRunAttempt -gt 0 -and
    [string]$binding.handoffId -ceq "store-$Commit-$($binding.upstreamRunId)-$($binding.upstreamRunAttempt)") "Private runner binding run/handoff identity differs."
Require-Exact ([string]$binding.reviewWorkflowRunId -cmatch '^\d+$' -and
    ([string]$binding.reviewWorkflowRunId).Length -le 20 -and
    [int]$binding.reviewWorkflowRunAttempt -gt 0 -and
    [string]$binding.reviewWorkflowPath -ceq '.github/workflows/windows-store-interactive.yml' -and
    [string]$binding.reviewWorkflowSha -ceq $Commit) "Reviewed workflow provenance differs from exact current main."
Require-Exact ([string]$binding.privateAclTextSha256 -cmatch '^[0-9a-f]{64}$' -and
    [string]$binding.candidateManifestSha256 -ceq $candidateDigest -and
    [string]$binding.storeProductId -ceq '9NWXQZP2ZG2H' -and
    [string]$binding.osEvidenceSlug -cmatch '^windows-(?:10-22h2|11-24h2)$' -and
    [string]$binding.osBuild -cmatch '^\d+$' -and ([string]$binding.osBuild).Length -le 10 -and
    [int]$binding.sessionId -gt 0 -and
    [string]$binding.osCaption -cmatch '^[^\x00-\x1f]{1,128}$' -and
    [string]$binding.approvedWackToolSha256 -cmatch '^[0-9a-f]{64}$' -and
    [string]$binding.approvedWackToolFileVersion -cmatch '^\d+(?:\.\d+){1,3}$' -and
    ([string]$binding.approvedWackToolFileVersion).Length -le 32 -and
    [string]$binding.approvedWackKitVersion -cmatch '^\d+(?:\.\d+){1,3}$' -and
    ([string]$binding.approvedWackKitVersion).Length -le 32) "Private runner/candidate/OS/WACK approval binding is incomplete."

$passes = @()
foreach ($pass in 1..2) {
    $sidecarFile = Get-EvidenceFile "pass-$pass\sidecar-evidence.json" 2 1MB
    $lifecycleFile = Get-EvidenceFile "pass-$pass\lifecycle-evidence.json" 2 1MB
    $wackFile = Get-EvidenceFile "pass-$pass\wack-report.xml" 512 50MB
    $sidecarSha256 = (Get-FileHash -LiteralPath $sidecarFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $lifecycleSha256 = (Get-FileHash -LiteralPath $lifecycleFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $wackSha256 = (Get-FileHash -LiteralPath $wackFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $sidecar = Read-Json "pass-$pass\sidecar-evidence.json"
    $lifecycle = Read-Json "pass-$pass\lifecycle-evidence.json"
    Require-Exact ($sidecar.product -ceq "Survey Data Workbench by LAI ZEYU") "Pass $pass sidecar product differs."
    Require-Exact ($sidecar.author -ceq "LAI ZEYU（来泽宇）") "Pass $pass sidecar author differs."
    Require-Exact ([int]$sidecar.uploadRows -gt 0 -and [int]$sidecar.uploadRows -le 1000000) "Pass $pass sidecar upload row count is invalid."
    Require-Exact ($sidecar.previewStatus -ceq "complete" -and $sidecar.formalOutputsAbsent -eq $true -and
        [int]$sidecar.zipEntries -gt 0 -and $sidecar.jobDeleted -eq $true) "Pass $pass sidecar evidence is incomplete."
    Require-Exact ([int]$lifecycle.pass -eq $pass) "Pass $pass lifecycle number differs."
    Require-Exact ($lifecycle.identityName -ceq "LAIZEYU.SurveyDataWorkbenchbyLAIZEYU") "Pass $pass lifecycle identity differs."
    Require-Exact ($lifecycle.publisher -ceq "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8") "Pass $pass lifecycle publisher differs."
    Require-Exact ($lifecycle.publisherDisplayName -ceq "LAI ZEYU") "Pass $pass lifecycle publisher display name differs."
    Require-Exact ([string]$lifecycle.candidateManifest -ceq $candidateDigest) "Pass $pass lifecycle candidate hash is not the exact private handoff manifest."
    Require-Exact ([string]$lifecycle.signedPackageSha256 -cmatch '^[0-9a-f]{64}$') "Pass $pass signed package hash is invalid."
    Require-Exact ($lifecycle.forcedExitKilledSidecar -eq $true -and $lifecycle.relaunchSucceeded -eq $true -and
        $lifecycle.uninstallRemovedLocalState -eq $true -and $lifecycle.sameSignedPackageVerified -eq $true) "Pass $pass lifecycle flags are incomplete."
    Require-Exact ($lifecycle.wackOverallResult -ceq "PASS" -and
        [string]$lifecycle.wackPartialRun -ceq "FALSE" -and
        [string]$lifecycle.wackLatestVersion -ceq "TRUE" -and
        [string]$lifecycle.wackKitVersion -cmatch '^\d+(?:\.\d+){1,3}$' -and
        [string]$lifecycle.wackToolFileVersion -cmatch '^\d+(?:\.\d+){1,3}' -and
        [string]$lifecycle.wackToolSha256 -ceq [string]$binding.approvedWackToolSha256 -and
        [string]$lifecycle.wackToolFileVersion -ceq [string]$binding.approvedWackToolFileVersion -and
        [string]$lifecycle.wackKitVersion -ceq [string]$binding.approvedWackKitVersion -and
        [string]$lifecycle.wackReportSha256 -ceq $wackSha256 -and
        [long]$lifecycle.wackReportLength -eq $wackFile.Length) "Pass $pass WACK result, report hash, or approved tool binding is incomplete."
    Require-Exact ($lifecycle.firstExternalLaunchVerified -eq $true -and
        $lifecycle.secondExternalLaunchVerified -eq $true) "Pass $pass external installed-app launch evidence is incomplete."
    $passes += [ordered]@{
        pass = $pass
        sidecar = [ordered]@{
            privateEvidenceJsonSha256 = $sidecarSha256
            uploadRows = [int]$sidecar.uploadRows
            previewComplete = $true
            formalOutputsAbsent = $true
            zipEntries = [int]$sidecar.zipEntries
            jobDeleted = $true
        }
        package = [ordered]@{
            candidateManifestSha256 = [string]$lifecycle.candidateManifest
            signedQaMsixSha256 = [string]$lifecycle.signedPackageSha256
            identityName = "LAIZEYU.SurveyDataWorkbenchbyLAIZEYU"
            publisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"
            publisherDisplayName = "LAI ZEYU"
        }
        lifecycle = [ordered]@{
            privateEvidenceJsonSha256 = $lifecycleSha256
            firstExternalWindowAndLoopbackReady = $true
            forcedExitKilledSidecar = $true
            relaunchExternalWindowAndLoopbackReady = $true
            uninstallRemovedLocalState = $true
            sameSignedPackageVerified = $true
        }
        wack = [ordered]@{
            reportSha256 = $wackSha256
            reportLength = [long]$wackFile.Length
            overallResult = "PASS"
            partialRun = $false
            latestVersion = $true
            kitVersion = [string]$lifecycle.wackKitVersion
            toolFileVersion = [string]$lifecycle.wackToolFileVersion
            toolSha256 = [string]$lifecycle.wackToolSha256
        }
    }
}
Require-Exact ($passes[0].package.signedQaMsixSha256 -ceq $passes[1].package.signedQaMsixSha256) "The two passes did not use the same temporary-signed QA MSIX."
Require-Exact ($passes[0].package.candidateManifestSha256 -ceq $passes[1].package.candidateManifestSha256) "The two passes did not use the same candidate manifest."
Require-Exact ($passes[0].wack.toolSha256 -ceq $passes[1].wack.toolSha256) "The two passes did not use the same trusted appcert.exe bytes."

$canonical = [ordered]@{
    schemaVersion = 3
    commit = $Commit
    product = "Survey Data Workbench by LAI ZEYU"
    author = "LAI ZEYU（来泽宇）"
    evidenceScope = "same-run-protected-workflow-private-acl-handoff-assertion"
    trustBoundary = "This summary is produced by the approved same-run workflow and is not an independent or non-forgeable attestation."
    provenance = [ordered]@{
        repository = [string]$binding.repository
        repositoryId = [long]$binding.repositoryId
        sourceCommit = [string]$binding.sourceCommit
        upstreamRunId = [string]$binding.upstreamRunId
        upstreamRunAttempt = [int]$binding.upstreamRunAttempt
        reviewWorkflowRunId = [string]$binding.reviewWorkflowRunId
        reviewWorkflowRunAttempt = [int]$binding.reviewWorkflowRunAttempt
        reviewWorkflowPath = [string]$binding.reviewWorkflowPath
        reviewWorkflowSha = [string]$binding.reviewWorkflowSha
        handoffId = [string]$binding.handoffId
        privateAclTextSha256 = [string]$binding.privateAclTextSha256
        osEvidenceSlug = [string]$binding.osEvidenceSlug
        osCaption = [string]$binding.osCaption
        osBuild = [string]$binding.osBuild
        interactiveSessionId = [int]$binding.sessionId
        approvedWackToolSha256 = [string]$binding.approvedWackToolSha256
        approvedWackToolFileVersion = [string]$binding.approvedWackToolFileVersion
        approvedWackKitVersion = [string]$binding.approvedWackKitVersion
    }
    candidateManifestFileSha256 = $candidateDigest
    passes = $passes
    excludedClaims = @(
        "store-certification",
        "store-distributed-package-signature",
        "licensed-ibm-spss-semantic-validation",
        "public-github-binary-signature"
    )
}
$jsonPath = Join-Path $output "windows-gate-summary.v3.json"
$json = $canonical | ConvertTo-Json -Depth 8 -Compress
[IO.File]::WriteAllText($jsonPath, $json + "`n", [Text.UTF8Encoding]::new($false))
$hash = (Get-FileHash -LiteralPath $jsonPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(
    (Join-Path $output "SHA256SUMS.txt"),
    "$hash  windows-gate-summary.v3.json`n",
    [Text.UTF8Encoding]::new($false)
)
$publicFiles = @(Get-ChildItem -LiteralPath $output -File)
if ($publicFiles.Count -ne 2 -or
    (Get-Item -LiteralPath $jsonPath).Length -lt 1024 -or
    (Get-Item -LiteralPath $jsonPath).Length -gt 32KB -or
    (Get-Item -LiteralPath (Join-Path $output "SHA256SUMS.txt")).Length -gt 256) {
    throw "Canonical public evidence is not the exact bounded two-file inventory."
}
if ((Get-Content -LiteralPath (Join-Path $output "SHA256SUMS.txt") -Raw) -cne
    "$hash  windows-gate-summary.v3.json`n") {
    throw "Canonical public evidence checksum file changed after generation."
}
Write-Host "Created fixed-schema canonical public gate evidence without raw logs, XML, filesystem paths, or binaries."
