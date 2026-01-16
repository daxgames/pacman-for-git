param(
    [string] $Version
)

Set-StrictMode -Version Latest

# Ensure TLS 1.2 so GitHub API calls succeed under Windows PowerShell 5.x
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
} catch {
    # ignore on platforms that don't support ServicePointManager
}

# normalize version variable (PowerShell is case-insensitive, but be explicit)
$version = $Version

function Invoke-GhApi {
    param($Uri)
    $hdr = @{
        "User-Agent" = "pacman-for-git-script"
        "Accept"     = "application/vnd.github.v3+json"
    }
    return Invoke-RestMethod -Uri $Uri -Headers $hdr -ErrorAction Stop
}

if (-not $Version) {
    Write-Error "Missing -Version argument (e.g. -version 2.39.1)."
    exit 2
}

$VersionsFilename = "package-versions-$Version.txt"

$rawUrl = "https://raw.githubusercontent.com/git-for-windows/build-extra/main/versions/$VersionsFilename"
try {
    # use the helper so we don't rely on -UseBasicParsing (not available/necessary in some PS versions)
    $content = Invoke-GhApi $rawUrl
} catch {
    Write-Error "Failed to fetch versions file: $rawUrl"
    exit 3
}

$PackageLine = ($content -split '\r?\n' | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^mingw-w64-x86_64-git\s+' } | Select-Object -First 1)
if (-not $PackageLine) {
    Write-Error "Couldn't find a line starting with 'mingw-w64-x86_64-git' in $VersionsFilename"
    exit 4
}

if ($PackageLine -notmatch '^mingw-w64-x86_64-git\s+(.+)$') {
    Write-Error "Package line must start with 'mingw-w64-x86_64-git '"
    exit 5
}
$versionLong = $Matches[1].Trim()
$line64 = "mingw-w64-x86_64-git $versionLong"
$line32 = "mingw-w64-i686-git $versionLong"

# Find candidate releases in git-for-windows/git
$releases = Invoke-GhApi "https://api.github.com/repos/git-for-windows/git/releases?per_page=100"
$candidates = @($releases | Where-Object {
    ($_.tag_name -like "*$version*") 
} | Select-Object tag_name, name, published_at, id)

if (-not $candidates) {
    Write-Error "No release matched '$version'. Aborting because selection is restricted to matching releases only."
    exit 8
} else {
    if ($candidates.Count -gt 1) {
        Write-Host "Multiple matching releases found:"
        $i = 1
        foreach ($c in $candidates) {
            "{0}: {1}  - {2}" -f $i, $c.tag_name, $c.published_at
            $i++
        }
        $sel = Read-Host "Enter number of release to use (1..$($candidates.Count), empty to abort)"
        if ($sel -eq '') {
            Write-Host "No selection made; aborting.";
            exit 1
        }
        if ($sel -notmatch '^[0-9]+$') {
            Write-Error "Invalid selection: must be a numeric value"
            exit 9
        }
        $sel = [int]$sel
        if ($sel -lt 1 -or $sel -gt $candidates.Count) {
            Write-Error "Selection out of range"
            exit 10
        }
        $choice = $candidates[$sel - 1]
    } else {
        $choice = $candidates[0]
    }
}

if (-not $choice) { Write-Error "No release selected"; exit 6 }

$publishedAt = (Get-Date $choice.published_at).ToUniversalTime().ToString("o")
Write-Host "Selected release: $($choice.tag_name) published at $publishedAt (UTC)"

function Get-LatestCommitBefore {
    param($ownerRepo, $untilIso)
    $parts = $ownerRepo -split '/'
    $owner = $parts[0]
    $repo  = $parts[1]
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
