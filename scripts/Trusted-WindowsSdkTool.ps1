function Get-TrustedWindowsSdkTool {
    param([Parameter(Mandatory = $true)][ValidateSet("makeappx.exe", "signtool.exe")][string]$Name)
    $kitsRoot = [IO.Path]::GetFullPath(
        (Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) "Windows Kits\10")
    ).TrimEnd('\')
    $binRoot = Join-Path $kitsRoot "bin"
    $escapedName = [Regex]::Escape($Name)
    $candidates = @(
        Get-ChildItem -LiteralPath $binRoot -Filter $Name -File -Recurse -ErrorAction Stop |
            Where-Object { $_.FullName -match "\\bin\\\d+(?:\.\d+){3}\\x64\\$escapedName$" } |
            Sort-Object { [version]$_.Directory.Parent.Name } -Descending
    )
    if ($candidates.Count -eq 0) { throw "$Name was not found under a versioned Windows SDK x64 directory." }
    $tool = $candidates[0]
    $current = $tool
    $reachedRoot = $false
    while ($current) {
        $currentPath = [IO.Path]::GetFullPath($current.FullName).TrimEnd('\')
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name path contains a reparse point."
        }
        if ([string]::Equals($currentPath, $kitsRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $reachedRoot = $true
            break
        }
        $current = $current.Parent
    }
    if (-not $reachedRoot -or $tool.VersionInfo.CompanyName -cne "Microsoft Corporation") {
        throw "$Name is outside the exact Windows Kits root or lacks Microsoft Corporation metadata."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $tool.FullName
    $simpleName = if ($signature.SignerCertificate) {
        $signature.SignerCertificate.GetNameInfo(
            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false
        )
    } else { "" }
    if ($signature.Status -ne "Valid" -or -not $signature.TimeStamperCertificate -or
        $simpleName -notin @("Microsoft Windows", "Microsoft Corporation")) {
        throw "$Name does not have the expected valid Microsoft Authenticode identity."
    }
    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $chain.ChainPolicy.RevocationFlag = [Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
        $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
        $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(60)
        if (-not $chain.Build($signature.SignerCertificate)) {
            throw "$Name Microsoft signer chain did not pass online validation."
        }
    } finally { $chain.Dispose() }
    return $tool.FullName
}

function Get-TrustedWindowsAppCertificationKit {
    $kitsRoot = [IO.Path]::GetFullPath(
        (Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) "Windows Kits\10")
    ).TrimEnd('\')
    $toolPath = Join-Path $kitsRoot "App Certification Kit\appcert.exe"
    if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
        throw "appcert.exe was not found at the exact Windows App Certification Kit path."
    }
    $tool = Get-Item -LiteralPath $toolPath -Force
    $current = $tool
    $reachedRoot = $false
    while ($current) {
        $currentPath = [IO.Path]::GetFullPath($current.FullName).TrimEnd('\')
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "appcert.exe path contains a reparse point."
        }
        if ([string]::Equals($currentPath, $kitsRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $reachedRoot = $true
            break
        }
        $current = $current.Parent
    }
    if (-not $reachedRoot -or $tool.VersionInfo.CompanyName -cne "Microsoft Corporation") {
        throw "appcert.exe is outside the exact Windows Kits root or lacks Microsoft Corporation metadata."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $tool.FullName
    $simpleName = if ($signature.SignerCertificate) {
        $signature.SignerCertificate.GetNameInfo(
            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false
        )
    } else { "" }
    if ($signature.Status -ne "Valid" -or -not $signature.TimeStamperCertificate -or
        $simpleName -notin @("Microsoft Windows", "Microsoft Corporation")) {
        throw "appcert.exe does not have the expected valid Microsoft Authenticode identity."
    }
    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $chain.ChainPolicy.RevocationFlag = [Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
        $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
        $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(60)
        if (-not $chain.Build($signature.SignerCertificate)) {
            throw "appcert.exe Microsoft signer chain did not pass online validation."
        }
    } finally { $chain.Dispose() }
    return $tool.FullName
}
