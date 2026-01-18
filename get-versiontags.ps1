<#
.SYNOPSIS
Selects a git-for-windows release and prints pacman version-tag lines with SDK commit SHAs.

.DESCRIPTION
`get-versiontags` queries the GitHub releases for `git-for-windows`, allows selecting a matching
release (or auto-selects the latest), looks up the corresponding `package-versions-<version>.txt`
file from `git-for-windows/build-extra`, extracts the `mingw-w64-x86_64-git` package version,
finds the SDK commit SHAs as of the release time, and prints two package/version/sha lines.

.PARAMETER Version
Optional. The release version token to match (substring match against release tag names).
If omitted the script will search all releases; use `-Latest:$false` to force interactive
selection when multiple matches are found. Example: `v2`, `2.39` or `2.39.1`.

.PARAMETER Latest
When true (default), the script auto-selects the first matching release that has a matching
versions file. To force the interactive menu, pass `-Latest:$false`.

.EXAMPLE
.\get-versiontags
Displays the latest release hashes available.

.EXAMPLE
.\get-versiontags -Version 2.39
Displays the latest 2.39.x release hashes available.

.EXAMPLE
.\get-versiontags -Version 2.39 -Latest:$false
Shows the selection menu showing all 2.39.x releases so a specific release can be selected.

.EXITCODE
0  : Success (or user chose to quit with `q`).
1  : (reserved)
2  : Missing or invalid input parameter.
3  : Failed to fetch versions file.
4  : Package line not found or malformed.
7  : Failed to find SDK commit SHAs.
8  : No matching releases with a versions file were found.

.NOTES
This script preserves the existing normalization rules for release tags (leading `v` removed,
`.windows.1` normalized, and `.windows` removed) to build the versions filename. Avoid changing
those normalization steps unless you intend to change how versions files are named.
#>

param(
    [string] $version,
    [string] $latest = $true,
    [switch] $Help
)

Set-StrictMode -Version Latest

# Runtime help fallback: if the user requests `-Help` at runtime we extract the
# comment-based help block from the top of this file and print it. This is a
# guaranteed fallback when `Get-Help` on the host system fails to show the
# full comment-based help (for example due to encoding/BOM issues or platform
# quirks). Use `.	hisscript.ps1 -Help` to show the same help text as
# `Get-Help -Full` would.
function Show-HelpRuntime {
    param()
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Definition }
    try {
        $text = Get-Content -Raw -LiteralPath $scriptPath -ErrorAction Stop
        if ($text -match '(?s)<#(.*?)#>') {
            $helpBlock = $Matches[1].Trim()
            # Print the help block as-is so it matches what comment-based help contains.
            Write-Host $helpBlock
            return 0
        } else {
            Write-Host "No embedded comment-based help found in $scriptPath"
            return 2
        }
    } catch {
        Write-Error "Failed to read script for help fallback: $_"
        return 1
    }
}

# If the runtime help switch was provided, show the fallback help and exit.
if ($Help) {
    exit (Show-HelpRuntime)
}

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

# Pre-filter candidates by validating that the corresponding versions file exists
$choice = $null
$VersionsFilename = $null
$candidatesWithVersions = @()
foreach ($c in $candidates) {
    $candidateTag = $c.tag_name.Trim()
    if ($candidateTag -match '^[vV](.+)') { $candidateTag = $Matches[1] }
    $candidateTag = $candidateTag -replace '(?i)\.windows\.1', '.windows'
    $candidateTag = $candidateTag -replace '(?i)\.windows', ''
    $candidateTag = $candidateTag.Trim()
    $candidateVersionsFilename = "package-versions-$candidateTag.txt"
    $candidateRawUrl = "https://raw.githubusercontent.com/git-for-windows/build-extra/main/versions/$candidateVersionsFilename"
    try {
        $req = [System.Net.WebRequest]::Create($candidateRawUrl)
        $req.Method = 'HEAD'
        $resp = $req.GetResponse()
        $resp.Close()
        # attach the computed filename to the candidate for later use
        $c | Add-Member -NotePropertyName VersionsFilename -NotePropertyValue $candidateVersionsFilename -Force

        $candidatesWithVersions += $c

        if ($latest -eq 'true') {
            break
        }
    } catch {
        # skip candidates without a versions file
        continue
    }
}

if (-not $candidatesWithVersions) {
    Write-Error "No releases matched '$version' that have a corresponding versions file."
    exit 8
}

if ($candidatesWithVersions.Count -eq 1 -or $latest -eq 'true') {
    # pick the only/latest release automatically
    $choice = $candidatesWithVersions[0]
}
else {
    write-host "=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-="
    Write-Host "Multiple Matching Releases Found Pick One"
    write-host "=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=`n"
    $i = 1
    foreach ($c in $candidatesWithVersions) {
        "{0}: {1}  - {2}" -f $i, $c.tag_name, $c.published_at
        $i++
    }

    write-host "`n=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-="
    $sel = Read-Host "Enter number of release to use (1..$($candidatesWithVersions.Count)) [default: 1, q to quit]"
    if ($sel -eq '') {
        $sel = '1'
        Write-Host "No selection made; defaulting to 1."
    }
    if ($sel -match '^[qQ]$') {
        Write-Host "Selection: quit requested; aborting."
        exit 0
    }
    if ($sel -notmatch '^[0-9]+$') {
        Write-Error "Invalid selection: must be a numeric value"
        exit 9
    }
    $sel = [int]$sel
    if ($sel -lt 1 -or $sel -gt $candidatesWithVersions.Count) {
        Write-Error "Selection out of range"
        exit 10
    }
    $choice = $candidatesWithVersions[$sel - 1]
}

# derive a version token from the chosen tag to pick the right versions file name
$selectedVersion = $choice.tag_name.Trim()
if ($selectedVersion -match '^[vV](.+)') { $selectedVersion = $Matches[1] }
$selectedVersion = $selectedVersion -replace '(?i)\.windows\.1', '.windows'  # normalize .windows.1 to .windows.0
$selectedVersion = $selectedVersion -replace '(?i)\.windows', ''          # remove .windows
$selectedVersion = $selectedVersion.Trim()

$VersionsFilename = "package-versions-$selectedVersion.txt"

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
Write-Host "New entries to be added to 'version-tags.txt'."
write-host "=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=`n"
Write-Host $line64WithSha
Write-Host $line32WithSha
write-host "`n************************************************************`n"
