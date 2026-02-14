<#
.SYNOPSIS
Selects a git-for-windows release and prints pacman version-tag lines with SDK commit SHAs.

.DESCRIPTION
`get-versiontags` queries the GitHub releases for `git-for-windows`, allows selecting a matching
release (or auto-selects the latest), looks up the corresponding `package-versions-<version>.txt`
file from `git-for-windows/build-extra`, extracts the `mingw-w64-x86_64-git` package version,
finds the SDK commit SHAs as of the release time, and prints two package/version/sha lines.

.PARAMETER Version
Optional. The release version to match (substring match against release tag names).
If omitted the script will search all releases; use `-Latest:$false` to force interactive
selection when multiple matches are found. Example: `v2`, `2.39` or `2.39.1`.

.PARAMETER Latest
When true (default), the script auto-selects the first matching release that has a matching
versions file. To force the interactive menu, pass `-Latest:$false`.

.PARAMETER All
When specified, the script will collect all matching releases (those that have a
corresponding `package-versions-*.txt` file), compute the 64- and 32-bit lines with
SDK commit SHAs for each release, and print all lines to stdout sorted newest-first
(most recent release first). The output prints all 64-bit lines first, then an empty
line, then all 32-bit lines.

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
9  : `-All` was specified and no `$env:GITHUB_TOKEN` was set.
10 : Selection out of range (interactive prompt).
11 : Invalid selection (non-numeric) from interactive prompt.

.NOTES
This script preserves the existing normalization rules for release tags (leading `v` removed,
`.windows.1` normalized, and `.windows` removed) to build the versions filename. Avoid changing
those normalization steps unless you intend to change how versions files are named.

ENVIRONMENT
- If you set the environment variable `GITHUB_TOKEN` (a personal access token), the script will
    use it for authenticated GitHub API requests which increases the rate limit (recommended when
    running `-All` across many releases).

.PARAMETER ThrottleMs
Milliseconds to wait between GitHub API calls (default: 0). Increase this value (for example
500) if you still hit rate limits when using `-All`.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $version,
    [string] $Latest = $true,
    [switch] $Help,
    [switch] $All,
    [int] $ThrottleMs = 0
)

Set-StrictMode -Version Latest

Write-Verbose "Starting script with parameters: Version='$version', Latest=$Latest, All=$All"

# Runtime help fallback: if the user requests `-Help` at runtime we extract the
# comment-based help block from the top of this file and print it. This is a
# guaranteed fallback when `Get-Help` on the host system fails to show the
# full comment-based help (for example due to encoding/BOM issues or platform
# quirks).
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

function Invoke-GhApi {
    param($Uri)
    Write-Verbose "GitHub API request: $Uri"
    $hdr = @{
        "User-Agent" = "pacman-for-git-update-script"
        "Accept"     = "application/vnd.github.v3+json"
    }
    # If the user provided a GITHUB_TOKEN in the environment, use it to raise rate limits.
    if ($env:GITHUB_TOKEN) {
        $hdr.Authorization = "token $($env:GITHUB_TOKEN)"
    }

    try {
        return Invoke-RestMethod -Uri $Uri -Headers $hdr -ErrorAction Stop
    } catch {
        # If the error looks like a rate-limit/403, provide a helpful message.
        $msg = $_.Exception.Message
        if ($msg -match 'rate limit' -or $msg -match '403') {
            Write-Error "GitHub API request failed (possible rate limit)."
            Write-Error "Consider setting GITHUB_TOKEN or increasing -ThrottleMs. Error: $msg"
        }
        throw
    }
}

function Get-LatestCommitBefore {
    param($ownerRepo, $untilIso)
    Write-Verbose "Looking for SDK commits before $untilIso in $ownerRepo"
    $parts = $ownerRepo -split '/'
    $owner = $parts[0]
    $repo  = $parts[1]
    $api = "https://api.github.com/repos/$owner/$repo/commits?sha=main&until=$([uri]::EscapeDataString($untilIso))&per_page=1"
    if ($ThrottleMs -gt 0) { Start-Sleep -Milliseconds $ThrottleMs }
    $res = Invoke-GhApi $api
    if (-not $res) { return $null }
    return $res[0].sha
}

# --- Helper functions (reduce duplication) ---
# Normalize a release tag into a version used for package-versions filenames
function Normalize-TagToVersion {
    param([string] $tag)
    if (-not $tag) { return $null }
    $t = $tag.Trim()
    if ($t -match '^[vV](.+)') { $t = $Matches[1] }
    $t = $t -replace '(?i)\.windows\.1', '.windows'
    $t = $t -replace '(?i)\.windows', ''
    $normalized = $t.Trim()
    Write-Verbose "Normalized tag: $tag -> $normalized"
    return $normalized
}

# Build a package-versions filename from a Version
function Get-VersionsFilenameFromVersion {
    param([string] $version)
    if (-not $version) { return $null }
    return "package-versions-$version.txt"
}

# HEAD-check if a raw versions URL exists (throttles if requested)
function Test-VersionsFileExists {
    param([string] $rawUrl)
    try {
        if ($ThrottleMs -gt 0) { Start-Sleep -Milliseconds $ThrottleMs }
        $req = [System.Net.WebRequest]::Create($rawUrl)
        $req.Method = 'HEAD'
        $resp = $req.GetResponse()
        $resp.Close()
        Write-Verbose "Versions file found: $rawUrl"
        return $true
    } catch {
        Write-Verbose "Versions file not found: $rawUrl"
        return $false
    }
}

function Get-VersionFileContent {
    param([string] $VersionsFilename)
    if (-not $VersionsFilename) { return $null }
    $rawUrl = "https://raw.githubusercontent.com/git-for-windows/build-extra/main/versions/$VersionsFilename"

    try {
        if ($ThrottleMs -gt 0) { Start-Sleep -Milliseconds $ThrottleMs }
        $content = Invoke-GhApi $rawUrl
    } catch {
        Write-Error "Failed to fetch versions file: $rawUrl"
        exit 3
    }

    return $content
}

# Parse the versions file content and return the mingw-w64-x86_64-git version
function Get-VersionFromVersionsContent {
    param([string] $content)
    if (-not $content) { 
        Write-Verbose "No content to parse"
        return $null 
    }
    $PackageLine = ($content -split '\r?\n' | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^mingw-w64-x86_64-git\s+' } | Select-Object -First 1)
    if (-not $PackageLine) { 
        Write-Verbose "mingw-w64-x86_64-git package line not found"
        return $null 
    }
    Write-Verbose "Found package line: $PackageLine"
    $m = [regex]::Match($PackageLine, '^mingw-w64-x86_64-git\s+(.+)$')
    if (-not $m.Success) { 
        Write-Verbose "Failed to parse version from line: $PackageLine"
        return $null 
    }
    $version = $m.Groups[1].Value.Trim()
    Write-Verbose "Extracted version: $version"
    return $version
}

function Create-VersionObject {
    param([string] $ver, [psobject] $c)
    if (-not $ver -or -not $c) { return $null }

    # --- Step 4: Find the commit SHAs for both SDKs as of the release time ---
    $line64 = "mingw-w64-x86_64-git $ver"
    $line32 = "mingw-w64-i686-git $ver"
    $publishedAt = (Get-Date $c.published_at).ToUniversalTime()

    $sha64 = Get-LatestCommitBefore "git-for-windows/git-sdk-64" $publishedAt.ToString("o")
    $sha32 = Get-LatestCommitBefore "git-for-windows/git-sdk-32" $publishedAt.ToString("o")

    if (-not $sha64 -or -not $sha32) {
        Write-Error "Failed to find one or both SDK commits before release time. sha64='$sha64' sha32='$sha32'"
        return $null
    }

    return [pscustomobject]@{
        PublishedAt = $publishedAt
        Line64 = "$line64 $sha64"
        Line32 = "$line32 $sha32"
    }
}

# Collect an entry for a candidate: returns PSCustomObject {PublishedAt, Line64, Line32} or $null
function Collect-EntryForCandidate {
    param([psobject] $c)
    if (-not $c) { return $null }

    # Determine versions filename
    if ($c.PSObject.Properties.Match('VersionsFilename')) {
        $versionsFilename = $c.VersionsFilename
    } else {
        $version = Normalize-TagToVersion $c.tag_name
        $versionsFilename = Get-VersionsFilenameFromVersion $version
    }

    $content = Get-VersionFileContent $versionsFilename
    $ver = Get-VersionFromVersionsContent $content
    if (-not $ver) { return $null }

    return Create-VersionObject $ver $c
}

function Output-Entries {
    param([array] $entries)
    if (-not $entries -or $entries.Count -eq 0) { return }

    # Sort entries by PublishedAt descending (newest first)
    $sortedEntries = $entries | Sort-Object -Property PublishedAt -Descending

    write-host ""
    write-output "=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-="
    Write-output "Git Release Version Tags"
    write-output "=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=`n"

    foreach ($e in $sortedEntries) {
        Write-output $e.Line64
    }

    Write-Output ""
    foreach ($e in $sortedEntries) {
        Write-Output $e.Line32
    }

    write-Output "`n************************************************************`n"

    write-host "Total Entries Output: $($entries.Count * 2) (64-bit and 32-bit lines)"
}

# If the runtime help switch was provided, show the fallback help and exit.
if ($Help) {
    exit (Show-HelpRuntime)
}

if ($all) {
    Write-Verbose "All flag enabled, processing all candidates"
    $Latest = $false
    if (!$env:GITHUB_TOKEN) {
        Write-Error "Set 'GITHUB_TOKEN' in the environment to increase GitHub API rate limits when using '-All'."
        exit 9
    }

    write-host "Please wait, gathering data for all releases..."
}

# Ensure TLS 1.2 so GitHub API calls succeed under Windows PowerShell 5.x
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
} catch {
    # ignore on platforms that don't support ServicePointManager
}

# --- Step 1: fetch releases and offer selection; exclude 'rc' releases ---
Write-Verbose "Fetching releases from GitHub API"
$releases = Invoke-GhApi "https://api.github.com/repos/git-for-windows/git/releases?per_page=100"
Write-Verbose "Retrieved $($releases.Count) releases, filtering for version '$version'"
$candidates = @(
    $releases |
    Where-Object {
        ($_.tag_name -like "*$version*") -and
        ($_.tag_name -notmatch '(?i)-rc')
    } |
    Select-Object tag_name, name, published_at, id
)
Write-Verbose "Found $($candidates.Count) matching candidates"

if (-not $candidates) {
    Write-Error "No release matched '$version'. Aborting because selection is restricted to matching releases only."
    exit 8
}

# Pre-filter candidates by validating that the corresponding versions file exists
Write-Verbose "Validating candidates have versions files"
$choice = $null
$VersionsFilename = $null
$candidatesWithVersions = @()
foreach ($c in $candidates) {
    $selectedVersion = Normalize-TagToVersion $c.tag_name
    $candidateVersionsFilename = Get-VersionsFilenameFromVersion $selectedVersion
    $candidateRawUrl = "https://raw.githubusercontent.com/git-for-windows/build-extra/main/versions/$candidateVersionsFilename"
    try {
        Write-Verbose "Checking: $candidateVersionsFilename for $($c.tag_name)"
        if (Test-VersionsFileExists $candidateRawUrl) {
            # attach the computed filename to the candidate for later use
            $c | Add-Member -NotePropertyName VersionsFilename -NotePropertyValue $candidateVersionsFilename -Force
            $candidatesWithVersions += $c
            Write-Verbose "Success: versions file exists for $($c.tag_name)"

            if ($Latest -eq $true) { 
                Write-Verbose "Latest mode enabled, selecting first match"
                break 
            }
        }
    } catch {
        continue
    }
}

if (-not $candidatesWithVersions) {
    Write-Error "No releases matched '$version' that have a corresponding versions file."
    exit 8
}

# If requested, gather all entries (64/32 lines) for all candidates and print
# them to stdout sorted newest-first (most recent release first). 64-bit lines
# are printed first, then an empty line, then 32-bit lines.
$entries = @()
if ($All) {
    foreach ($c in $candidatesWithVersions) {
        $entry = Collect-EntryForCandidate $c
        if ($entry) { $entries += $entry }
    }
}
else {
    if ($candidatesWithVersions.Count -eq 1 -or $Latest -eq $true) {
        # pick the only/latest release automatically
        $choice = $candidatesWithVersions[0]
        Write-Verbose "Auto-selected release: $($choice.tag_name)"
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
            exit 11
        }
        $sel = [int]$sel
        if ($sel -lt 1 -or $sel -gt $candidatesWithVersions.Count) {
            Write-Error "Selection out of range"
            exit 10
        }
        $choice = $candidatesWithVersions[$sel - 1]
    }

    # Derive a version version from the chosen tag to pick the right versions file name
    $selectedVersion = $choice.tag_name.Trim()
    $selectedVersion = Normalize-TagToVersion $selectedVersion

    # --- Step 2: fetch the chosen versions file and parse the package line ---
    $versionsFilename = Get-VersionsFilenameFromVersion $selectedVersion
    $content = Get-VersionFileContent $versionsFilename

    # --- Step 3: Get the version as recorded in the versions file ---
    $versionFromFile = Get-VersionFromVersionsContent $content
    if (-not $versionFromFile) {
        Write-Error "Couldn't find a proper 'mingw-w64-x86_64-git <version>' line in $VersionsFilename"
        exit 4
    }

    $entry = Collect-EntryForCandidate $choice
    if ($entry) { $entries += $entry }
}

Output-Entries $entries
Write-Verbose "Script completed successfully"
