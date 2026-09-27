param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$root = Split-Path -Parent $PSScriptRoot
$releaseDirectory = Join-Path $root 'release'
$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wowravox-release-' + [guid]::NewGuid().ToString('N'))
$addonDirectory = Join-Path $stagingRoot 'WoWraVox'
$archive = Join-Path $releaseDirectory "WoWraVox-$Version.zip"
$runtimeFiles = @(
    'WoWraVox.toc',
    'WoWraVox.lua',
    'WoWraVoxLauncher.lua',
    'WoWraVoxTooltip.lua',
    'Defaults.lua'
)

try {
    New-Item -ItemType Directory -Path $addonDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
    foreach ($file in $runtimeFiles) {
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $addonDirectory $file) -Force
    }
    Copy-Item -LiteralPath (Join-Path $root 'Assets') -Destination $addonDirectory -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'Locales') -Destination $addonDirectory -Recurse -Force
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    Compress-Archive -LiteralPath $addonDirectory -DestinationPath $archive -CompressionLevel Optimal
    Write-Output $archive
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
}
