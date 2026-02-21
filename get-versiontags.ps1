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

.PARAMETER OutFile
Optional. If specified, the output will be written to the given file in addition to being printed to stderr.

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

.PARAMETER Y
When specified with `-All`, automatically uses the GitHub CLI token (if available) without
prompting. Useful for non-interactive or scripted workflows.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $version,
    [string] $Latest = $true,
    [switch] $Help,
    [switch] $All,
    [switch] $Y,
    [string] $OutFile,
    [int] $ThrottleMs = 0
)

Set-StrictMode -Version Latest

Write-Verbose "[START] Version=$version Latest=$Latest All=$All ThrottleMs=$ThrottleMs"

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
    Write-Verbose "[API] Uri=$Uri"
    $hdr = @{
        "User-Agent" = "pacman-for-git-update-script"
        "Accept"     = "application/vnd.github.v3+json"
    }
    # Use GITHUB_TOKEN from environment (if pre-existing) or from script variable (if obtained locally)
    $token = $env:GITHUB_TOKEN
    if (-not $token -and (Get-Variable -Name GitHubToken -Scope Script -ErrorAction SilentlyContinue)) {
        $token = $script:GitHubToken
    }
    if ($token) {
        $hdr.Authorization = "token $token"
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
    Write-Verbose "[SDK] Repo=$ownerRepo UntilTime=$untilIso"
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
    Write-Verbose "[TAG] Input=$tag Output=$normalized"
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
        Write-Verbose "[FILE] Status=Found Url=$rawUrl"
        return $true
    } catch {
        Write-Verbose "[FILE] Status=NotFound Url=$rawUrl"
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
        Write-Verbose "[PARSE] Content=Empty Result=Null"
        return $null 
    }
    $PackageLine = ($content -split '\r?\n' | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^mingw-w64-x86_64-git\s+' } | Select-Object -First 1)
    if (-not $PackageLine) { 
        Write-Verbose "[PARSE] Package=mingw-w64-x86_64-git Status=NotFound"
        return $null 
    }
    Write-Verbose "[PARSE] PackageLine=$PackageLine"
    $m = [regex]::Match($PackageLine, '^mingw-w64-x86_64-git\s+(.+)$')
    if (-not $m.Success) { 
        Write-Verbose "[PARSE] Status=Failed Line=$PackageLine"
        return $null
    }
    $version = $m.Groups[1].Value.Trim()
    Write-Verbose "[PARSE] Version=$version Status=Success"
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
    $normalizedTag = $null
    if ($c.PSObject.Properties.Match('VersionsFilename')) {
        $versionsFilename = $c.VersionsFilename
        $normalizedTag = Normalize-TagToVersion $c.tag_name
    } else {
        $normalizedTag = Normalize-TagToVersion $c.tag_name
        $versionsFilename = Get-VersionsFilenameFromVersion $normalizedTag
    }

    $content = Get-VersionFileContent $versionsFilename
    $ver = Get-VersionFromVersionsContent $content
    if (-not $ver) { return $null }

    # Validate that extracted version matches the normalized tag
    if (-not $ver.StartsWith($normalizedTag)) {
        [Console]::Error.WriteLine("`nWarning: Invalid package-versions file for tag '$($c.tag_name)': extracted version '$ver' does not match normalized tag '$normalizedTag'. Skipping this release.`n")
        write-verbose "[VALIDATE] Tag=$($c.tag_name) NormalizedTag=$normalizedTag ExtractedVersion=$ver Status=Mismatch"
        return $null
    }

    Write-Verbose "[VALIDATE] Tag=$($c.tag_name) NormalizedTag=$normalizedTag ExtractedVersion=$ver Status=Valid"
    return Create-VersionObject $ver $c
}

function Output-Entries {
    param([array] $entries)
    if (-not $entries -or $entries.Count -eq 0) { return }

    # Sort entries by PublishedAt descending (newest first)
    $sortedEntries = $entries | Sort-Object -Property PublishedAt -Descending

    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=")
    [Console]::Error.WriteLine("Git Release Version Tags")
    [Console]::Error.WriteLine("=-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=")


    if ($OutFile) {
       # If the output file already exists, clear it before appending new content
        if (Test-Path -LiteralPath $OutFile) {
            Clear-Content -LiteralPath $OutFile
            Write-Verbose "[FILE] Cleared existing output file: $OutFile"
        }
    }

    foreach ($e in $sortedEntries) {
        [Console]::Error.WriteLine($e.Line64)
        if ($OutFile) {
            Add-Content -LiteralPath $OutFile -Value $e.Line64
        }
    }

    [Console]::Error.WriteLine("")
    if ($OutFile) {
        Add-Content -LiteralPath $OutFile -Value ""
    }

    foreach ($e in $sortedEntries) {
        [Console]::Error.WriteLine($e.Line32)
        if ($OutFile) {
            Add-Content -LiteralPath $OutFile -Value $e.Line32
        }
    }

    [Console]::Error.WriteLine("`n************************************************************`n")
    [Console]::Error.WriteLine("Total Entries Output: $($entries.Count * 2) (64-bit and 32-bit lines)")
}

# If the runtime help switch was provided, show the fallback help and exit.
if ($Help) {
    exit (Show-HelpRuntime)
}

if ($all) {
    Write-Verbose "[FLAG] All=$All Latest=$false (Was=$Latest)"
    $Latest = $false
    if (!$env:GITHUB_TOKEN) {
        [Console]::Error.WriteLine("GitHub API rate limits are strict for unauthenticated requests.")
        [Console]::Error.WriteLine("Using '-All' flag requires a GitHub personal access token.")
        
        $token = $null
        
        # Try to get token from 'gh' command if available
        Write-Verbose "[TOKEN] Checking if 'gh' command is available"
        $ghAvailable = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
        
        if ($ghAvailable) {
            Write-Verbose "[TOKEN] 'gh' command found, attempting to retrieve token"
            try {
                $ghToken = & gh auth token 2>$null
                if ($ghToken -and -not [string]::IsNullOrWhiteSpace($ghToken)) {
                    [Console]::Error.WriteLine("Found GitHub CLI authentication token.")
                    if ($Y) {
                        $token = $ghToken
                        Write-Verbose "[TOKEN] Using token from gh auth token (auto-accepted via -y)"
                    } else {
                        $useGhToken = Read-Host "Use the token from GitHub CLI? (yes/no, default: no)"
                        if ($useGhToken -match '^(yes|y)$') {
                            $token = $ghToken
                            Write-Verbose "[TOKEN] Using token from gh auth token"
                        }
                    }
                }
            } catch {
                Write-Verbose "[TOKEN] Failed to retrieve token from gh: $_"
            }
        }
        
        # If no token from gh, prompt user
        if (-not $token) {
            $secureToken = Read-Host "Enter your GitHub personal access token (or press Enter to abort)" -AsSecureString
            if ($secureToken.Length -eq 0) {
                Write-Error "GITHUB_TOKEN is required when using '-All' flag."
                exit 9
            }
            # Convert SecureString to plain text (compatible with all PowerShell versions)
            $cred = New-Object System.Management.Automation.PSCredential("dummy", $secureToken)
            $token = $cred.GetNetworkCredential().Password
            Write-Verbose "[TOKEN] Token set from user input"
        }
        
        # Store token in script variable without setting env variable
        $script:GitHubToken = $token
        Write-Verbose "[TOKEN] Token stored for script use (not set as environment variable)"
    }

    [Console]::Error.WriteLine("Please wait, gathering data for all releases...")
}

# Ensure TLS 1.2 so GitHub API calls succeed under Windows PowerShell 5.x
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
} catch {
    # ignore on platforms that don't support ServicePointManager
}

# --- Step 1: fetch releases and offer selection; exclude 'rc' releases ---
Write-Verbose "[FETCH] Retrieving releases from GitHub API"
$releases = Invoke-GhApi "https://api.github.com/repos/git-for-windows/git/releases?per_page=100"
Write-Verbose "[FETCH] Count=$($releases.Count) FilterVersion=$version"
$candidates = @(
    $releases |
    Where-Object {
        ($_.tag_name -like "*$version*") -and
        ($_.tag_name -notmatch '(?i)-rc')
    } |
    Select-Object tag_name, name, published_at, id
)
Write-Verbose "[FILTER] Candidates=$($candidates.Count) Version=$version"

if (-not $candidates) {
    Write-Error "No release matched '$version'. Aborting because selection is restricted to matching releases only."
    exit 8
}

# Pre-filter candidates by validating that the corresponding versions file exists
if ($All -eq $true) {
    [Console]::Error.WriteLine("Checking versions files for $($candidates.Count) candidates")
} else {
    [Console]::Error.WriteLine("Checking versions files candidates to find the latest valid release (up to $($candidates.Count) candidates)")
}
$choice = $null
$VersionsFilename = $null
$candidatesWithVersions = @()
foreach ($c in $candidates) {
    $selectedVersion = Normalize-TagToVersion $c.tag_name
    $candidateVersionsFilename = Get-VersionsFilenameFromVersion $selectedVersion
    $candidateRawUrl = "https://raw.githubusercontent.com/git-for-windows/build-extra/main/versions/$candidateVersionsFilename"
    try {
        Write-Verbose "[VALIDATE] PRE-FILTER Tag=$($c.tag_name) Filename=$candidateVersionsFilename"
        if (Test-VersionsFileExists $candidateRawUrl) {
            # attach the computed filename to the candidate for later use
            $c | Add-Member -NotePropertyName VersionsFilename -NotePropertyValue $candidateVersionsFilename -Force
            
            if ($Latest -eq $true) {
                if (Collect-EntryForCandidate $c) {
                    $candidatesWithVersions = @($c)
                    Write-Host "'$candidateVersionsFilename' exists and matches the release tag for release '$($c.tag_name)'."
                    Write-host "Found valid 'package-versions' file for release '$($c.tag_name)'. Auto-selecting this release because get latest mode is enabled."
                    break
                }
            }
            $candidatesWithVersions += $c
            Write-Verbose "[VALIDATE] PRE-FILTER Tag=$($c.tag_name) Status=Found"
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
    if ($candidatesWithVersions.Count -eq 1) {
        # pick the only release automatically
        $choice = $candidatesWithVersions[0]
        Write-Verbose "[SELECT] Mode=Auto Tag=$($choice.tag_name) PublishedAt=$($choice.published_at)"
        $entry = Collect-EntryForCandidate $choice
        if ($entry) { $entries += $entry }
    }
    elseif ($Latest -eq $true) {
        # pick the latest valid release (loop through until finding valid entry)
        Write-Verbose "[SELECT] Mode=Latest searching for valid release"
        foreach ($candidate in $candidatesWithVersions) {
            Write-Verbose "[SELECT] Trying candidate Tag=$($candidate.tag_name)"
            $entry = Collect-EntryForCandidate $candidate
            if ($entry) {
                $entries += $entry
                Write-Verbose "[SELECT] Latest Mode=Valid Tag=$($candidate.tag_name)"
                break
            }
        }
        if (-not $entries) {
            Write-Error "No valid package-versions file found for any release matching '$version'."
            exit 8
        }
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
        $entry = Collect-EntryForCandidate $choice
        if ($entry) { $entries += $entry }
    }
}

Output-Entries $entries
Write-Verbose "[COMPLETE] TotalEntries=$($entries.Count) ExitCode=0"
