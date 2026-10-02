param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,
    [switch]$AllowExistingTag,
    [switch]$RequireExistingTag,
    [switch]$SkipSameDayGate
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tocPath = Join-Path $root 'WoWraVox.toc'
$readmePath = Join-Path $root 'README.md'
$changelogPath = Join-Path $root 'CHANGELOG.md'
$tag = "v$Version"

function Require-Match([string]$Path, [string]$Pattern, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Description file is missing: $Path" }
    $content = Get-Content -LiteralPath $Path -Raw
    if ($content -notmatch $Pattern) { throw "$Description does not declare version $Version." }
}

function Get-BerlinTimeZone {
    foreach ($id in @('W. Europe Standard Time', 'Europe/Berlin')) {
        try { return [TimeZoneInfo]::FindSystemTimeZoneById($id) } catch { }
    }
    throw 'Europe/Berlin time zone is unavailable on this host.'
}

Push-Location $root
try {
    $tagOutput = & git tag --list $tag
    $existingTag = if ($tagOutput) { [string]::Join("`n", $tagOutput).Trim() } else { '' }
    if ($existingTag -and -not $AllowExistingTag) {
        throw "Tag $tag already exists. Resume that release; do not create another version."
    }
    if (-not $existingTag -and $RequireExistingTag) {
        throw "Tag $tag does not exist. Create and push the release tag before resuming an upload."
    }

    Require-Match $tocPath "(?m)^## Version: $([regex]::Escape($Version))\s*$" 'WoWraVox.toc'
    Require-Match $readmePath "(?m)^Current stable version: \*\*$([regex]::Escape($Version))\*\*\.\s*$" 'README.md'
    Require-Match $changelogPath "(?m)^##\s+$([regex]::Escape($Version))\s*$" 'CHANGELOG.md'

    # Every TOC entry must be tracked by git. Enforced for tag/CI runs only; locally,
    # new files are legitimately untracked until the release commit.
    if ($RequireExistingTag -or $env:GITHUB_ACTIONS) {
        $tocEntries = @(Get-Content -LiteralPath $tocPath | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') })
        $tracked = @(& git ls-files)
        $untracked = @($tocEntries | Where-Object { $tracked -notcontains ($_ -replace '\\', '/') })
        if ($untracked.Count) { throw "TOC entries not tracked by git: $($untracked -join ', ')" }
    }

    # Repo hygiene gate: nothing internal (handoffs, agent files, backups, release output, runtime data)
    # may be tracked, and only known top-level paths may appear. Tag/CI runs check tracked files;
    # a local pre-check also covers what `git add` would pick up (untracked files not ignored by .gitignore).
    $denylist = '^\.agents/', 'SECOND_OPINION', '\.(bak|tmp|orig)$', '^release/', '^WTF/', 'SavedVariables',
        '^docs/UI-ALIGNMENT', '/unused/', '^\.wago$', '\.zip$', '^Libs/'
    $allowlist = '^(WoWraVox\.toc$|[A-Za-z]+\.lua$|Locales/|Assets/|docs/branding/|tools/|\.github/|README\.md$|CHANGELOG\.md$|LICENSE$|\.editorconfig$|\.gitattributes$|\.gitignore$)'
    $hygienePaths = if ($RequireExistingTag -or $env:GITHUB_ACTIONS) { @(& git -c core.quotepath=off ls-files) }
        else { @(& git -c core.quotepath=off ls-files --cached --others --exclude-standard) }
    $violations = @()
    foreach ($path in ($hygienePaths | Sort-Object -Unique)) {
        $hit = @($denylist | Where-Object { $path -match $_ })
        if ($hit.Count) { $violations += "$path (denied by: $($hit -join ' '))" }
        elseif ($path -notmatch $allowlist) { $violations += "$path (not in the allowed top-level paths)" }
    }
    if ($violations.Count) { throw "Repo hygiene gate failed:`n  $($violations -join "`n  ")" }

    $diffCheck = & git diff --check HEAD
    if ($LASTEXITCODE -ne 0) { throw "git diff --check failed.`n$diffCheck" }

    $berlin = Get-BerlinTimeZone
    $today = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $berlin).Date
    # Same-day gate guards tag creation; resuming an existing tag (or CI, -SkipSameDayGate) must not be blocked by it.
    $recentTags = if ($RequireExistingTag -or $SkipSameDayGate) { @() } else { & git for-each-ref --format='%(refname:short)|%(creatordate:iso-strict)' refs/tags/v* }
    foreach ($entry in $recentTags) {
        $parts = $entry -split '\|', 2
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[1])) { continue }
        if ($parts[0] -eq $tag) { continue }
        $releasedAt = [DateTimeOffset]::Parse($parts[1])
        $releaseDate = [TimeZoneInfo]::ConvertTime($releasedAt, $berlin).Date
        if ($releaseDate -eq $today) {
            throw "Stable release $($parts[0]) already exists for $($today.ToString('yyyy-MM-dd')) Europe/Berlin. Keep approved work queued until the next day."
        }
    }

    Write-Output "Release gate passed for $tag."
}
finally {
    Pop-Location
}
