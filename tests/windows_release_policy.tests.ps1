$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Import-NamedFunction {
    param([string]$ScriptPath, [string]$FunctionName)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path -LiteralPath $ScriptPath).Path,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $FunctionName
    }, $true)
    if (-not $definition) { throw "Function not found: $FunctionName" }
    Set-Item -LiteralPath "Function:\global:$FunctionName" -Value $definition.Body.GetScriptBlock()
}

function Assert-Outcome([string]$Name, [bool]$ShouldPass, [scriptblock]$Operation) {
    $passed = $true
    try { & $Operation | Out-Null } catch { $passed = $false }
    if ($passed -ne $ShouldPass) { throw "$Name expected pass=$ShouldPass but observed pass=$passed." }
    Write-Host "$Name`: $(if ($passed) { 'ACCEPT' } else { 'REJECT' })"
}

$scriptPath = Join-Path $PSScriptRoot "..\scripts\Test-MsixLifecycle.ps1"
Import-NamedFunction -ScriptPath $scriptPath -FunctionName "Assert-WackXmlPass"
$signatureScript = Join-Path $PSScriptRoot "..\scripts\Verify-GitHubReleaseSignature.ps1"
Import-NamedFunction -ScriptPath $signatureScript -FunctionName "Assert-SignToolOutputPolicy"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("statflow-wack-policy-" + [Guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($tempRoot)
try {
    $padding = "x" * 700
    $cases = @(
        @{ Name="valid"; Pass=$true; Xml="<REPORT OVERALL_RESULT='PASS' PARTIAL_RUN='FALSE' LATEST_VERSION='TRUE' VERSION='10.0.26100.1'><TEST INDEX='1' NAME='Static'><RESULT>PASS</RESULT></TEST><TEST INDEX='2' NAME='Optional'><RESULT>NOT_APPLICABLE</RESULT></TEST><!--$padding--></REPORT>" },
        @{ Name="space-separated-not-applicable"; Pass=$false; Xml="<REPORT OVERALL_RESULT='PASS' PARTIAL_RUN='FALSE' LATEST_VERSION='TRUE' VERSION='10.0.26100.1'><TEST INDEX='1' NAME='Optional'><RESULT>NOT APPLICABLE</RESULT></TEST><!--$padding--></REPORT>" },
        @{ Name="stale-kit"; Pass=$false; Xml="<REPORT OVERALL_RESULT='PASS' PARTIAL_RUN='FALSE' LATEST_VERSION='FALSE' VERSION='10.0.26100.1'><TEST INDEX='1' NAME='Static'><RESULT>PASS</RESULT></TEST><!--$padding--></REPORT>" },
        @{ Name="partial"; Pass=$false; Xml="<REPORT OVERALL_RESULT='PASS' PARTIAL_RUN='TRUE' LATEST_VERSION='TRUE' VERSION='10.0.26100.1'><TEST INDEX='1' NAME='Static'><RESULT>PASS</RESULT></TEST><!--$padding--></REPORT>" },
        @{ Name="failed-result"; Pass=$false; Xml="<REPORT OVERALL_RESULT='PASS' PARTIAL_RUN='FALSE' LATEST_VERSION='TRUE' VERSION='10.0.26100.1'><TEST INDEX='1' NAME='Static'><RESULT>FAIL</RESULT></TEST><!--$padding--></REPORT>" },
        @{ Name="duplicate-index"; Pass=$false; Xml="<REPORT OVERALL_RESULT='PASS' PARTIAL_RUN='FALSE' LATEST_VERSION='TRUE' VERSION='10.0.26100.1'><TEST INDEX='1' NAME='A'><RESULT>PASS</RESULT></TEST><TEST INDEX='1' NAME='B'><RESULT>PASS</RESULT></TEST><!--$padding--></REPORT>" },
        @{ Name="duplicate-name"; Pass=$false; Xml="<REPORT OVERALL_RESULT='PASS' PARTIAL_RUN='FALSE' LATEST_VERSION='TRUE' VERSION='10.0.26100.1'><TEST INDEX='1' NAME='A'><RESULT>PASS</RESULT></TEST><TEST INDEX='2' NAME='A'><RESULT>PASS</RESULT></TEST><!--$padding--></REPORT>" }
    )
    foreach ($case in $cases) {
        $fixture = Join-Path $tempRoot ("$($case.Name).xml")
        [IO.File]::WriteAllText($fixture, $case.Xml, [Text.UTF8Encoding]::new($false))
        Assert-Outcome -Name $case.Name -ShouldPass $case.Pass -Operation {
            Assert-WackXmlPass -ReportPath $fixture
        }
    }

    $digest = "a" * 64
    $compact = "0 sha256 RFC3161"
    $verbose = @"
Signature Index: 0 (Primary Signature)
Hash of file (sha256): $digest
Number of signatures successfully Verified: 1
Number of warnings: 0
Number of errors: 0
"@
    $signatureCases = @(
        @{ Name="signature-valid"; Pass=$true; Compact=$compact; Verbose=$verbose },
        @{ Name="signature-sha1"; Pass=$false; Compact="0 sha1 RFC3161"; Verbose=$verbose },
        @{ Name="signature-legacy-timestamp"; Pass=$false; Compact="0 sha256 Authenticode"; Verbose=$verbose },
        @{ Name="signature-extra"; Pass=$false; Compact="$compact`n1 sha256 RFC3161"; Verbose="$verbose`nSignature Index: 1`nHash of file (sha256): $digest" },
        @{ Name="signature-warning"; Pass=$false; Compact=$compact; Verbose=($verbose -replace 'Number of warnings: 0', 'Number of warnings: 1') },
        @{ Name="signature-missing-digest"; Pass=$false; Compact=$compact; Verbose=($verbose -replace '(?m)^Hash of file.*\r?\n', '') }
    )
    foreach ($case in $signatureCases) {
        Assert-Outcome -Name $case.Name -ShouldPass $case.Pass -Operation {
            Assert-SignToolOutputPolicy -CompactOutput $case.Compact -VerboseOutput $case.Verbose -BinaryPath "fixture.exe"
        }
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) { [IO.Directory]::Delete($tempRoot, $true) }
}

function Assert-ReleaseDomainPolicy([string]$Workflow) {
    if ([regex]::Matches($Workflow, "publish-handoff").Count -ne 3 -or
        [regex]::Matches($Workflow, "assert-handoff").Count -ne 8 -or
        [regex]::Matches($Workflow, "--forbid-writer").Count -ne 9 -or
        [regex]::Matches($Workflow, "RELEASE_HANDOFF_OWNER_PRINCIPAL").Count -ne 6 -or
        [regex]::Matches($Workflow, "trusted-windows-release-cleanup").Count -ne 2) {
        throw "Private handoff atomic-transfer/owner policy differs."
    }
    $signerParts = $Workflow -split [regex]::Escape("`n  sign-release-in-clean-domain:"), 2
    $verifierParts = $Workflow -split [regex]::Escape("`n  verify-signed-release-in-clean-domain:"), 2
    if ($signerParts.Count -ne 2 -or $verifierParts.Count -ne 2) { throw "Release-domain job boundaries are absent." }
    $signer = ($signerParts[1] -split [regex]::Escape("`n  verify-signed-release-in-clean-domain:"), 2)[0]
    $verifier = ($verifierParts[1] -split [regex]::Escape("`n  publish-release:"), 2)[0]
    if ($signer -match "verify-signed-installer-lifecycle|--passes 2|Start-Process" -or
        $signer -notmatch "--forbid-candidate-execution" -or
        $verifier -match "actions/checkout|GH_TOKEN:|SIGNING_HARNESS_PATH:|secrets\.SSL_ESIGNER|Initialize-SslEsignerCka" -or
        $verifier -notmatch "verify-signed-installer-lifecycle" -or
        $verifier -notmatch [regex]::Escape('signingCredentialPresent -ne $false') -or
        $verifier -notmatch [regex]::Escape('--expected-install-directory') -or
        $verifier -notmatch [regex]::Escape('--signed-portable-executable-inventory') -or
        $verifier -notmatch [regex]::Escape('--forbid-preexisting-product-state') -or
        $verifier -notmatch [regex]::Escape('--forbid-reparse-points') -or
        $verifier -notmatch [regex]::Escape('$pass.sidecarParentProcessId') -or
        $verifier -notmatch [regex]::Escape('$pass.listenerCount') -or
        $verifier -notmatch [regex]::Escape('$pass.dataDirectoryRemoved') -or
        $verifier -notmatch [regex]::Escape('$pass.allInstalledPortableExecutablesHaveExactlyOneSignature') -or
        $verifier -notmatch [regex]::Escape('$pass.allInstalledPortableExecutablesMatchSignedInventory')) {
        throw "Signer/verifier execution and credential domains are not isolated."
    }
}

$workflowPath = Join-Path $PSScriptRoot "..\.github\workflows\windows-github-release.yml"
$workflow = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $workflowPath).Path)
Assert-Outcome -Name "release-domain-policy-valid" -ShouldPass $true -Operation { Assert-ReleaseDomainPolicy $workflow }
$releasePolicyCases = @(
    @{ Name="release-domain-writer-retained"; Text=[regex]::Replace($workflow, [regex]::Escape("--forbid-writer"), "--allow-writer", 1) },
    @{ Name="release-domain-nonatomic-copy"; Text=[regex]::Replace($workflow, [regex]::Escape("publish-handoff"), "copy-handoff", 1) },
    @{ Name="release-domain-owner-reused"; Text=[regex]::Replace($workflow, [regex]::Escape("RELEASE_HANDOFF_OWNER_PRINCIPAL"), "RELEASE_BUILD_PRINCIPAL", 1) },
    @{ Name="release-verifier-path-contract-removed"; Text=$workflow.Replace("--expected-install-directory", "--unchecked-install-directory") },
    @{ Name="release-verifier-single-signature-proof-removed"; Text=$workflow.Replace('$pass.allInstalledPortableExecutablesHaveExactlyOneSignature', '$pass.signaturePolicyNotChecked') },
    @{ Name="release-verifier-reparse-gate-removed"; Text=$workflow.Replace("--forbid-reparse-points", "--allow-reparse-points") }
)
foreach ($case in $releasePolicyCases) {
    Assert-Outcome -Name $case.Name -ShouldPass $false -Operation { Assert-ReleaseDomainPolicy $case.Text }
}
Write-Host "SPSS WACK, signature, and release-domain policy fixtures: 20/20 expected outcomes."
