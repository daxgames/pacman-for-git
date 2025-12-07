param(
    [string] $Version,
    [int] $RecentCount = 10
)

Set-StrictMode -Version Latest

function Invoke-GhApi {
    param($Uri)
    $hdr = @{ "User-Agent" = "pacman-for-git-script" }
    return Invoke-RestMethod -Uri $Uri -Headers $hdr -ErrorAction Stop
}

if (-not $Version) {
    Write-Error "Missing -Version argument (e.g. -version 2.39.1)."
    exit 2
}

$VersionsFilename = "package-versions-$Version.txt"

$rawUrl = "https://raw.githubusercontent.com/git-for-windows/build-extra/main/versions/$VersionsFilename"
try {
    $content = Invoke-RestMethod -Uri $rawUrl -UseBasicParsing -ErrorAction Stop
} catch {
    Write-Error "Failed to fetch versions file: $rawUrl"
    exit 3
}

$PackageLine = ($content -split "`n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^mingw-w64-x86_64-git\s+' } | Select-Object -First 1)
if (-not $PackageLine) {
    Write-Error "Couldn't find a line starting with 'mingw-w64-x86_64-git' in $VersionsFilename"
    exit 4
}

if ($PackageLine -notmatch '^mingw-w64-x86_64-git\s+(.+)$') {
    Write-Error "Package line must start with 'mingw-w64-x86_64-git '"
    exit 5
}
$version = $Matches[1].Trim()
$line64 = "mingw-w64-x86_64-git $version"
$line32 = "mingw-w64-i686-git $version"

# Try to derive a simpler version token to find the release (numeric prefix)
if ($version -match '^(\d+(?:\.\d+)+)') { $simpleVer = $Matches[1] } else { $simpleVer = $version }

# Find candidate releases in git-for-windows/git
$releases = Invoke-GhApi "https://api.github.com/repos/git-for-windows/git/releases?per_page=100"
$candidates = $releases | Where-Object {
    ($_.tag_name -like "*$simpleVer*") -or ($_.name -like "*$simpleVer*") -or ($_.body -like "*$simpleVer*")
} | Select-Object tag_name, name, published_at, id

if (-not $candidates) {
    # fallback: show recent releases for manual pick
    Write-Host "No release matched '$simpleVer'. Listing $RecentCount most recent releases for manual selection..."
    $recent = $releases | Select-Object tag_name, name, published_at | Select-Object -First $RecentCount
    $i=0
    foreach ($r in $recent) {
        "{0}: {1}  — {2}" -f $i, ($r.tag_name), ($r.published_at)
        $i++
    }
    $sel = Read-Host "Enter index of release to use (or blank to abort)"
    if ($sel -eq '') { Write-Error "Aborted"; exit 1 }
    $choice = $recent[$sel]
} else {
    if ($candidates.Count -gt 1) {
        Write-Host "Multiple matching releases found:"
        $i = 0
        foreach ($c in $candidates) {
            "{0}: {1}  — {2}" -f $i, $c.tag_name, $c.published_at
            $i++
        }
        $sel = Read-Host "Enter index of release to use"
        $choice = $candidates[$sel]
    } else {
        $choice = $candidates[0]
    }
}

if (-not $choice) { Write-Error "No release selected"; exit 6 }

$publishedAt = (Get-Date $choice.published_at).ToUniversalTime().ToString("o")
Write-Host "Selected release: $($choice.tag_name) published at $publishedAt (UTC)"

function Get-LatestCommitBefore {
    param($ownerRepo, $untilIso)
    $owner, $repo = $ownerRepo -split '/'
    $api = "https://api.github.com/repos/$owner/$repo/commits?sha=main&until=$([uri]::EscapeDataString($untilIso))&per_page=1"
    $res = Invoke-GhApi $api
    if (-not $res) { return $null }
    return $res[0].sha
}

$sha64 = Get-LatestCommitBefore "git-for-windows/git-sdk-64" $publishedAt
$sha32 = Get-LatestCommitBefore "git-for-windows/git-sdk-32" $publishedAt

if (-not $sha64 -or -not $sha32) {
    Write-Error "Failed to find one or both SDK commits before release time. sha64='$sha64' sha32='$sha32'"
    exit 7
}

$line64WithSha = "$line64 $sha64"
$line32WithSha = "$line32 $sha32"

Write-Host "`nNew entries to be added to 'version-tags.txt'.`n"
Write-Host $line64WithSha
Write-Host $line32WithSha
