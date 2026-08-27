param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$assetRoot = New-Item -ItemType Directory -Path $OutputDirectory -Force

function New-StatFlowAsset {
    param(
        [int]$Width,
        [int]$Height,
        [string]$Name,
        [bool]$IncludeWordmark = $false
    )

    $visual = [System.Windows.Media.DrawingVisual]::new()
    $context = $visual.RenderOpen()
    $background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0, 139, 139))
    $context.DrawRectangle($background, $null, [System.Windows.Rect]::new(0, 0, $Width, $Height))

    $typeface = [System.Windows.Media.Typeface]::new("Segoe UI Semibold")
    $markSize = [Math]::Max(18, [Math]::Min($Width, $Height) * 0.42)
    $mark = [System.Windows.Media.FormattedText]::new(
        "S",
        [Globalization.CultureInfo]::GetCultureInfo("en-US"),
        [System.Windows.FlowDirection]::LeftToRight,
        $typeface,
        $markSize,
        [System.Windows.Media.Brushes]::White,
        1.0
    )
    $markX = if ($IncludeWordmark) { $Width * 0.16 } else { ($Width - $mark.Width) / 2 }
    $context.DrawText($mark, [System.Windows.Point]::new($markX, ($Height - $mark.Height) / 2))

    if ($IncludeWordmark) {
        $wordmark = [System.Windows.Media.FormattedText]::new(
            "Survey Data Workbench by LAI ZEYU",
            [Globalization.CultureInfo]::GetCultureInfo("en-US"),
            [System.Windows.FlowDirection]::LeftToRight,
            [System.Windows.Media.Typeface]::new("Segoe UI"),
            [Math]::Max(14, $Height * 0.14),
            [System.Windows.Media.Brushes]::White,
            1.0
        )
        $context.DrawText($wordmark, [System.Windows.Point]::new($Width * 0.34, ($Height - $wordmark.Height) / 2))
    }

    $context.Close()
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $Width,
        $Height,
        96,
        96,
        [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($visual)
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create((Join-Path $assetRoot.FullName $Name))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

New-StatFlowAsset -Width 44 -Height 44 -Name "Square44x44Logo.png"
New-StatFlowAsset -Width 150 -Height 150 -Name "Square150x150Logo.png"
New-StatFlowAsset -Width 50 -Height 50 -Name "StoreLogo.png"
New-StatFlowAsset -Width 310 -Height 150 -Name "Wide310x150Logo.png" -IncludeWordmark $true
New-StatFlowAsset -Width 620 -Height 300 -Name "SplashScreen.png" -IncludeWordmark $true

Get-ChildItem $assetRoot.FullName -Filter "*.png" | ForEach-Object {
    if ($_.Length -le 0) { throw "Generated asset is empty: $($_.FullName)" }
}
