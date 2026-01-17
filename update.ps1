param(
    [string] $version
)

Set-StrictMode -Version Latest

function Invoke-GhApi {
    param($Uri)
    $hdr = @{
        "User-Agent" = "pacman-for-git-update-script"
        "Accept"     = "application/vnd.github.v3+json"
    }
    return Invoke-RestMethod -Uri $Uri -Headers $hdr -ErrorAction Stop
}

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

# Ensure TLS 1.2 so GitHub API calls succeed under Windows PowerShell 5.x
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
} catch {
    # ignore on platforms that don't support ServicePointManager
}

if (-not $version) {
    Write-Error "Missing -Version argument (e.g. -version 2.39.1)."
    exit 2
}

# --- Step 1: fetch releases and offer selection; exclude 'rc' releases ---
$releases = Invoke-GhApi "https://api.github.com/repos/git-for-windows/git/releases?per_page=100"
$candidates = @(
    $releases |
    Where-Object {
        ($_.tag_name -like "*$version*") -and
        ($_.tag_name -notmatch '(?i)-rc')
    } |
    Select-Object tag_name, name, published_at, id
)

if (-not $candidates) {
    Write-Error "No release matched '$version'. Aborting because selection is restricted to matching releases only."
    exit 8
}

$choice = $null
$VersionsFilename = $null

if ($candidates.Count -gt 1) {
    write-host "=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-="
    Write-Host "Multiple Matching Releases Found Pick One"
    write-host "=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=`n"
    $i = 1
    foreach ($c in $candidates) {
        "{0}: {1}  - {2}" -f $i, $c.tag_name, $c.published_at
        $i++
    }

    write-host "`n=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-="
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

    # derive a version token from the chosen tag to pick the right versions file name
    $realVersion = $choice.tag_name.Trim()
} else {
    # single candidate: use the provided short $version for the versions filename
    $choice = $candidates[0]
    $realVersion = $choice.tag_name.Trim()
}

if ($realVersion -match '^[vV](.+)') { $realVersion = $Matches[1] }
$realVersion = $realVersion -replace '(?i)\.windows\.1', '.windows'  # normalize .windows.1 to .windows.0
$realVersion = $realVersion -replace '(?i)\.windows', ''          # remove .windows
$realVersion = $realVersion.Trim()

$VersionsFilename = "package-versions-$realVersion.txt"

# --- Step 2: fetch the chosen versions file and parse the package line ---
$rawUrl = "https://raw.githubusercontent.com/git-for-windows/build-extra/main/versions/$VersionsFilename"
try {
    $content = Invoke-GhApi $rawUrl
} catch {
    Write-Error "Failed to fetch versions file: $rawUrl"
    exit 3
}

$PackageLine = ($content -split '\r?\n' | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^mingw-w64-x86_64-git\s+' } | Select-Object -First 1)
if (-not ($PackageLine -match '^mingw-w64-x86_64-git\s+(.+)$')) {
    Write-Error "Couldn't find a proper 'mingw-w64-x86_64-git <version>' line in $VersionsFilename"
    exit 4
}

# --- Step 3: Get the version as recorded in the versions file ---
$versionFromFile = $Matches[1].Trim()

$line64 = "mingw-w64-x86_64-git $versionFromFile"
$line32 = "mingw-w64-i686-git $versionFromFile"

# --- Step 4: Find the commit SHAs for both SDKs as of the release time ---
$publishedAt = (Get-Date $choice.published_at).ToUniversalTime().ToString("o")

$sha64 = Get-LatestCommitBefore "git-for-windows/git-sdk-64" $publishedAt
$sha32 = Get-LatestCommitBefore "git-for-windows/git-sdk-32" $publishedAt

if (-not $sha64 -or -not $sha32) {
    Write-Error "Failed to find one or both SDK commits before release time. sha64='$sha64' sha32='$sha32'"
    exit 7
}

# --- Step 6: Prepare the new lines with SHAs appended ---
$line64WithSha = "$line64 $sha64"
$line32WithSha = "$line32 $sha32"

# --- Step 7: Output the new lines ---
write-host "`n=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-="
Write-Host "New entries to be added to 'version-tags.txt'."
write-host "=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=`n"
Write-Host $line64WithSha
Write-Host $line32WithSha
write-host "`n************************************************************`n"
