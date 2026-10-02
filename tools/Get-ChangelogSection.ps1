param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version
)

# Prints the CHANGELOG.md section "## <Version>" (including ### subsections) up to the next "## " line.
# The heading line itself is omitted and surrounding blank lines are trimmed.
$ErrorActionPreference = 'Stop'
$changelogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CHANGELOG.md'
if (-not (Test-Path -LiteralPath $changelogPath)) { throw "CHANGELOG.md is missing: $changelogPath" }

$lines = [System.IO.File]::ReadAllText($changelogPath) -split "\r?\n"
$heading = '^##\s+' + [regex]::Escape($Version) + '\s*$'
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $heading) { $start = $i + 1; break }
}
if ($start -lt 0) { throw "CHANGELOG.md has no '## $Version' section." }

$end = $lines.Count
for ($i = $start; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^##\s') { $end = $i; break }
}

$section = if ($end -gt $start) { @($lines[$start..($end - 1)]) } else { @() }
while ($section.Count -and [string]::IsNullOrWhiteSpace($section[0])) { $section = @($section | Select-Object -Skip 1) }
while ($section.Count -and [string]::IsNullOrWhiteSpace($section[-1])) { $section = @($section | Select-Object -SkipLast 1) }
if (-not $section.Count) { throw "CHANGELOG.md section '## $Version' is empty." }

$section -join "`n"
