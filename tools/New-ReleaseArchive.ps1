param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$releaseDirectory = Join-Path $root 'release'
$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wowravox-release-' + [guid]::NewGuid().ToString('N'))
$addonDirectory = Join-Path $stagingRoot 'WoWraVox'
$archive = Join-Path $releaseDirectory "WoWraVox-$Version.zip"
$tocPath = Join-Path $root 'WoWraVox.toc'

# Runtime files = the TOC itself + every non-metadata TOC line (so a new .lua can never be forgotten).
$tocFiles = @(Get-Content -LiteralPath $tocPath | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_ -replace '\\', '/' })
$runtimeFiles = @('WoWraVox.toc') + $tocFiles
# Only game-loadable assets ship; source PNGs live in docs/branding/.
$assetFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'Assets') -File |
    Where-Object { $_.Extension -in '.ogg', '.tga' } | ForEach-Object { "Assets/$($_.Name)" })
$expected = @($runtimeFiles + $assetFiles | Sort-Object -Unique)

try {
    New-Item -ItemType Directory -Path $addonDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
    foreach ($file in $expected) {
        $source = Join-Path $root $file
        if (-not (Test-Path -LiteralPath $source)) { throw "TOC/asset entry is missing on disk: $file" }
        $target = Join-Path $addonDirectory $file
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    Compress-Archive -LiteralPath $addonDirectory -DestinationPath $archive -CompressionLevel Optimal

    # Gate: every TOC entry must be inside the ZIP (and nothing unexpected).
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entries = @($zip.Entries | Where-Object { $_.Name } |
            ForEach-Object { ($_.FullName -replace '\\', '/') -replace '^WoWraVox/', '' })
    }
    finally { $zip.Dispose() }
    $missing = @($expected | Where-Object { $entries -notcontains $_ })
    $extra = @($entries | Where-Object { $expected -notcontains $_ })
    if ($missing.Count -or $extra.Count) {
        Remove-Item -LiteralPath $archive -Force
        throw "ZIP content mismatch. Missing: [$($missing -join ', ')] Unexpected: [$($extra -join ', ')]"
    }
    Write-Output $archive
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
}
