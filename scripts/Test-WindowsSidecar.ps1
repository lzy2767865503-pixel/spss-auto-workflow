param(
    [Parameter(Mandatory = $true)]
    [string]$LayoutDirectory,
    [string]$DiagnosticsDirectory = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true

$layout = (Resolve-Path -LiteralPath $LayoutDirectory).Path
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$fixture = Join-Path $repo "examples\synthetic_survey.csv"
if (-not (Test-Path -LiteralPath $fixture -PathType Leaf)) { throw "Missing synthetic fixture: $fixture" }
$executable = Join-Path $layout "backend\statflow-backend.exe"
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Missing sidecar: $executable" }
$desktopExecutable = Join-Path $layout "StatFlow.Workbench.Desktop.exe"
if (-not (Test-Path -LiteralPath $desktopExecutable -PathType Leaf)) { throw "Missing desktop executable: $desktopExecutable" }
foreach ($legalName in @("LICENSE.txt", "NOTICE.md", "THIRD_PARTY_NOTICES_SUMMARY.md", "THIRD_PARTY_NOTICES.txt")) {
    $legalPath = Join-Path $layout "legal\$legalName"
    if (-not (Test-Path -LiteralPath $legalPath -PathType Leaf) -or (Get-Item -LiteralPath $legalPath).Length -le 0) {
        throw "Missing packaged legal notice: $legalName"
    }
}
$desktopVersion = (Get-Item -LiteralPath $desktopExecutable).VersionInfo
if ($desktopVersion.CompanyName -ne "LAI ZEYU（来泽宇）" -or
    $desktopVersion.ProductName -ne "Survey Data Workbench by LAI ZEYU") {
    throw "Compiled desktop attribution metadata is missing or incorrect."
}

if ($DiagnosticsDirectory) {
    New-Item -ItemType Directory -Path $DiagnosticsDirectory -Force | Out-Null
    $DiagnosticsDirectory = (Resolve-Path -LiteralPath $DiagnosticsDirectory).Path
}
$testData = Join-Path ([IO.Path]::GetTempPath()) ("statflow-smoke-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $testData | Out-Null
$bundlePath = Join-Path $testData "downloaded-preview.zip"

function Assert-StatusCode {
    param([Parameter(Mandatory = $true)]$Response, [Parameter(Mandatory = $true)][int]$Expected, [Parameter(Mandatory = $true)][string]$Label)
    if ([int]$Response.StatusCode -ne $Expected) { throw "$Label returned HTTP $($Response.StatusCode), expected $Expected." }
}

function Assert-ZipIntegrity {
    param([Parameter(Mandatory = $true)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $files = @($archive.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
        if ($files.Count -eq 0) { throw "Downloaded preview ZIP contains no files." }
        foreach ($formalName in @("analysis_data.sav", "analysis_output.spv", "analysis_output.pdf")) {
            if (@($files | Where-Object { $_.Name -ceq $formalName }).Count -gt 0) {
                throw "Downloaded preview ZIP contains forbidden formal output: $formalName"
            }
        }
        $buffer = [byte[]]::new(1048576)
        foreach ($entry in $files) {
            $stream = $entry.Open()
            try { while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) { } } finally { $stream.Dispose() }
        }
        return $files.Count
    } finally {
        $archive.Dispose()
    }
}

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $executable
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.ArgumentList.Add("--port")
$startInfo.ArgumentList.Add("0")
$startInfo.ArgumentList.Add("--data-dir")
$startInfo.ArgumentList.Add($testData)
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$started = $false
$jobId = $null
$ready = $null
$headers = $null

try {
    if (-not $process.Start()) { throw "Could not start sidecar." }
    $started = $true
    $readTask = $process.StandardOutput.ReadLineAsync()
    if (-not $readTask.Wait([TimeSpan]::FromSeconds(120))) { throw "Sidecar readiness timeout." }
    $ready = $readTask.Result | ConvertFrom-Json
    if ($ready.event -ne "ready" -or -not $ready.apiToken) { throw "Invalid readiness payload." }

    $headers = @{ "X-StatFlow-Token" = $ready.apiToken }
    $healthResponse = Invoke-WebRequest -Uri ($ready.url + "api/health") -Headers $headers -UseBasicParsing
    Assert-StatusCode $healthResponse 200 "Health request"
    $health = $healthResponse.Content | ConvertFrom-Json
    if (-not $health.ok -or
        $health.formalOutputPolicy -cne "format-integrity-only" -or
        $health.semanticValidationPolicy -cne "external-two-authorised-environments") {
        throw "Sidecar health check did not preserve the format-versus-semantic validation boundary."
    }
    if (-not $healthResponse.Headers["Content-Security-Policy"]) { throw "Security headers are missing." }

    try {
        Invoke-WebRequest -Uri ($ready.url + "api/health") -UseBasicParsing | Out-Null
        throw "Tokenless API request unexpectedly succeeded."
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 401) { throw }
    }

    $uploadResponse = Invoke-WebRequest `
        -Uri ($ready.url + "api/upload") `
        -Method Post `
        -Headers $headers `
        -Form @{ file = (Get-Item -LiteralPath $fixture) } `
        -UseBasicParsing
    Assert-StatusCode $uploadResponse 200 "Synthetic CSV upload"
    $uploaded = $uploadResponse.Content | ConvertFrom-Json -Depth 20
    $jobId = [string]$uploaded.jobId
    if (-not $jobId -or @($uploaded.detectedConstructs).Count -eq 0) { throw "Synthetic upload did not return a configurable job." }

    $config = [ordered]@{
        sheet = $uploaded.selectedSheet
        constructs = @($uploaded.detectedConstructs)
        analyses = @("descriptives", "reliability", "correlations")
        models = @()
        executeSpss = $false
    }
    $runResponse = Invoke-WebRequest `
        -Uri ($ready.url + "api/jobs/$jobId/run") `
        -Method Post `
        -Headers $headers `
        -ContentType "application/json" `
        -Body ($config | ConvertTo-Json -Depth 20 -Compress) `
        -UseBasicParsing
    Assert-StatusCode $runResponse 202 "Synthetic preview start"

    $job = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        Start-Sleep -Milliseconds 400
        $jobResponse = Invoke-WebRequest -Uri ($ready.url + "api/jobs/$jobId") -Headers $headers -UseBasicParsing
        Assert-StatusCode $jobResponse 200 "Synthetic preview poll"
        $job = $jobResponse.Content | ConvertFrom-Json -Depth 30
    } while ($job.status -eq "running" -and [DateTime]::UtcNow -lt $deadline)
    if ($job.status -ne "complete") { throw "Synthetic preview ended in '$($job.status)', not complete." }
    if ($job.result.spss.state -ne "skipped") { throw "Preview unexpectedly reported a formal SPSS state." }

    $formalNames = @("analysis_data.sav", "analysis_output.spv", "analysis_output.pdf")
    $resultNames = @($job.result.files | ForEach-Object { [string]$_.name })
    foreach ($formalName in $formalNames) {
        if ($resultNames -contains $formalName) { throw "Preview exposed forbidden formal output: $formalName" }
    }
    $bundleName = [string]$job.result.bundle
    if (-not $bundleName -or $resultNames -notcontains $bundleName) { throw "Preview bundle was not listed for download." }

    $downloadResponse = Invoke-WebRequest `
        -Uri ($ready.url + "api/jobs/$jobId/download/$([Uri]::EscapeDataString($bundleName))") `
        -Headers $headers `
        -OutFile $bundlePath `
        -PassThru `
        -UseBasicParsing
    Assert-StatusCode $downloadResponse 200 "Preview ZIP download"
    $zipEntries = Assert-ZipIntegrity -Path $bundlePath

    $deleteResponse = Invoke-WebRequest -Uri ($ready.url + "api/jobs/$jobId") -Method Delete -Headers $headers -UseBasicParsing
    Assert-StatusCode $deleteResponse 204 "Synthetic job deletion"
    try {
        Invoke-WebRequest -Uri ($ready.url + "api/jobs/$jobId") -Headers $headers -UseBasicParsing | Out-Null
        throw "Deleted synthetic job remained readable."
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw }
    }
    $jobId = $null

    $evidence = [ordered]@{
        product = "Survey Data Workbench by LAI ZEYU"
        author = "LAI ZEYU（来泽宇）"
        uploadRows = [int]$uploaded.rows
        previewStatus = [string]$job.status
        formalOutputsAbsent = $true
        zipEntries = [int]$zipEntries
        jobDeleted = $true
    }
    if ($DiagnosticsDirectory) {
        $evidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $DiagnosticsDirectory "sidecar-evidence.json") -Encoding UTF8
    }
    Write-Host "Windows sidecar synthetic upload/preview/ZIP/delete test passed on a random loopback port."
} finally {
    if ($jobId -and $ready -and $headers) {
        try { Invoke-WebRequest -Uri ($ready.url + "api/jobs/$jobId") -Method Delete -Headers $headers -UseBasicParsing | Out-Null } catch { }
    }
    if ($started) {
        if (-not $process.HasExited) {
            $killError = ""
            try { $process.Kill($true) } catch { $killError = $_.Exception.Message }
            if (-not $process.WaitForExit(15000) -or -not $process.HasExited) {
                throw "The sidecar process tree remained alive after forced cleanup: $killError"
            }
        } else {
            $process.WaitForExit()
        }
    }
    $process.Dispose()
    if (Test-Path -LiteralPath $testData) { Remove-Item -LiteralPath $testData -Recurse -Force }
    if (Test-Path -LiteralPath $testData) { throw "The sidecar test data directory remained after cleanup." }
}
