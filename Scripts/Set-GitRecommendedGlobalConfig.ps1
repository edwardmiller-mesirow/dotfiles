<#
.SYNOPSIS
Applies recommended Git 2.54 global configuration for Windows only when settings differ.

.DESCRIPTION
Checks each recommended Git setting, compares the current effective value against the desired value, and writes only the global settings that need to change. The script emits a report that shows what changed, what was already correct, and why each setting is recommended.

Use -WhatIf to preview changes without writing to the global Git config.

.EXAMPLE
.\tools\Set-GitRecommendedGlobalConfig.ps1

Applies the recommended global configuration and prints a report.

.EXAMPLE
.\tools\Set-GitRecommendedGlobalConfig.ps1 -WhatIf

Shows which settings would change without modifying Git config.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Invoke-GitConfigGet {
    param([Parameter(Mandatory = $true)][string]$Name)

    $output = & git config get --show-scope --show-origin $Name 2>$null
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 1) {
        return $null
    }

    if ($exitCode -ne 0) {
        throw "git config get failed for '$Name' with exit code $exitCode."
    }

    if ($null -eq $output) {
        return $null
    }

    $line = @($output)[-1]
    $parts = $line -split '\s+', 3

    if ($parts.Count -lt 3) {
        throw "Could not parse git config output for '$Name': $line"
    }

    [pscustomobject]@{
        Scope = $parts[0]
        Origin = $parts[1]
        Value = $parts[2]
    }
}

function Set-GitConfigGlobalValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    & git config set --global $Name $Value

    if ($LASTEXITCODE -ne 0) {
        throw "git config set failed for '$Name'."
    }
}

function ConvertTo-ComparableGitValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $normalizedValue = $Value.Trim()

    switch -Regex ($normalizedValue) {
        '^(?i:true|yes|on|1)$' { return 'true' }
        '^(?i:false|no|off|0)$' { return 'false' }
        default { return $normalizedValue }
    }
}

function Write-SectionHeader {
    param([Parameter(Mandatory = $true)][string]$Title)

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkCyan
}

function Write-CountBadge {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][int]$Count,
        [Parameter(Mandatory = $true)][ConsoleColor]$Color
    )

    Write-Host ('{0,-14}' -f "${Label}:") -NoNewline
    Write-Host $Count -ForegroundColor $Color
}

function Write-SettingTable {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Rows,
        [Parameter(Mandatory = $true)][ConsoleColor]$Color,
        [switch]$IncludePrevious
    )

    if ($Rows.Count -eq 0) {
        return
    }

    Write-SectionHeader -Title $Title

    if ($IncludePrevious) {
        $Rows |
            Sort-Object Name |
            Select-Object @(
                @{ Name = 'Name'; Expression = { $_.Name } },
                @{ Name = 'From'; Expression = { $_.PreviousValue } },
                @{ Name = 'To'; Expression = { $_.DesiredValue } },
                @{ Name = 'Source'; Expression = { $_.PreviousScope } }
            ) |
            Format-Table -AutoSize | Out-String -Stream |
            ForEach-Object { Write-Host $_ -ForegroundColor $Color }

        return
    }

    $Rows |
        Sort-Object Name |
        Select-Object @(
            @{ Name = 'Name'; Expression = { $_.Name } },
            @{ Name = 'Value'; Expression = { $_.DesiredValue } },
            @{ Name = 'Source'; Expression = { $_.PreviousScope } }
        ) |
        Format-Table -AutoSize | Out-String -Stream |
        ForEach-Object { Write-Host $_ -ForegroundColor $Color }
}

function Write-RationaleList {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Rows
    )

    Write-SectionHeader -Title 'Rationale'

    foreach ($row in ($Rows | Sort-Object Name)) {
        $actionColor = switch ($row.Action) {
            'Changed' { 'Green' }
            'WouldChange' { 'Yellow' }
            default { 'DarkGray' }
        }

        Write-Host $row.Name -ForegroundColor White -NoNewline
        Write-Host " [$($row.Action)]" -ForegroundColor $actionColor
        Write-Host "  $($row.Why)" -ForegroundColor DarkGray
    }
}

$recommendations = @(
    [pscustomobject]@{ Name = 'core.longpaths'; Value = 'true'; Why = 'Allows Windows working trees to handle paths beyond the legacy MAX_PATH limit.' }
    [pscustomobject]@{ Name = 'core.fsmonitor'; Value = 'true'; Why = 'Uses Git for Windows built-in file system monitoring to speed status and index refreshes.' }
    [pscustomobject]@{ Name = 'core.untrackedCache'; Value = 'true'; Why = 'Caches untracked directory scans to reduce repeated status cost in large worktrees.' }
    [pscustomobject]@{ Name = 'checkout.workers'; Value = '0'; Why = 'Lets Git choose parallel checkout workers based on available CPU cores.' }
    [pscustomobject]@{ Name = 'fetch.parallel'; Value = '0'; Why = 'Lets Git choose a sensible parallel fetch count for multiple remotes or submodules.' }
    [pscustomobject]@{ Name = 'submodule.fetchJobs'; Value = '0'; Why = 'Lets Git choose parallel submodule fetch jobs when a repo uses submodules.' }
    [pscustomobject]@{ Name = 'fetch.prune'; Value = 'true'; Why = 'Removes stale remote-tracking refs during fetch so local refs match the server.' }
    [pscustomobject]@{ Name = 'fetch.writeCommitGraph'; Value = 'true'; Why = 'Keeps commit-graph metadata fresh after fetches for faster log, merge-base, and push checks.' }
    [pscustomobject]@{ Name = 'commitGraph.changedPaths'; Value = 'true'; Why = 'Writes changed-path Bloom filters to speed history queries scoped to paths.' }
    [pscustomobject]@{ Name = 'gc.cruftPacks'; Value = 'true'; Why = 'Stores unreachable objects in cruft packs instead of loose objects for cleaner object storage.' }
    [pscustomobject]@{ Name = 'gc.writeCommitGraph'; Value = 'true'; Why = 'Refreshes commit-graph metadata during garbage collection.' }
    [pscustomobject]@{ Name = 'repack.writeBitmaps'; Value = 'true'; Why = 'Writes reachability bitmaps during full repacks to speed clone, fetch, and object traversal.' }
    [pscustomobject]@{ Name = 'maintenance.strategy'; Value = 'incremental'; Why = 'Uses Git maintenance tasks designed for frequent, low-disruption background cleanup.' }
    [pscustomobject]@{ Name = 'maintenance.auto'; Value = 'true'; Why = 'Allows Git to run automatic maintenance when normal commands cross maintenance thresholds.' }
    [pscustomobject]@{ Name = 'maintenance.autoDetach'; Value = 'true'; Why = 'Lets automatic maintenance continue in the background instead of blocking foreground Git commands.' }
    [pscustomobject]@{ Name = 'core.fsyncMethod'; Value = 'batch'; Why = 'Uses Git 2.54 batch fsync behavior, a good Windows durability/performance balance on NTFS/ReFS.' }
    [pscustomobject]@{ Name = 'core.fsync'; Value = 'committed'; Why = 'Hardens committed objects without paying the heavier cost of syncing every derived metadata file.' }
    [pscustomobject]@{ Name = 'transfer.fsckObjects'; Value = 'true'; Why = 'Checks transferred objects when fetch/receive-specific fsck settings fall back to transfer defaults.' }
    [pscustomobject]@{ Name = 'fetch.fsckObjects'; Value = 'true'; Why = 'Checks fetched objects for malformed or missing data before accepting new remote data.' }
    [pscustomobject]@{ Name = 'receive.fsckObjects'; Value = 'true'; Why = 'Checks objects received by local server-side operations such as pushes into local repos.' }
    [pscustomobject]@{ Name = 'protocol.version'; Value = '2'; Why = 'Uses Git protocol v2, the modern default protocol with more efficient negotiation.' }
    [pscustomobject]@{ Name = 'transfer.credentialsInUrl'; Value = 'die'; Why = 'Rejects remote URLs that contain plaintext credentials in config.' }
    [pscustomobject]@{ Name = 'safe.bareRepository'; Value = 'explicit'; Why = 'Limits accidental use of embedded bare repositories unless explicitly selected.' }
    [pscustomobject]@{ Name = 'http.sslBackend'; Value = 'schannel'; Why = 'Uses the Windows certificate store for HTTPS validation in Git for Windows.' }
    [pscustomobject]@{ Name = 'core.autocrlf'; Value = 'input'; Why = 'Commits normalized LF line endings without forcing CRLF checkout conversion globally.' }
    [pscustomobject]@{ Name = 'core.safecrlf'; Value = 'warn'; Why = 'Warns when line-ending conversion may be irreversible.' }
    [pscustomobject]@{ Name = 'init.defaultBranch'; Value = 'main'; Why = 'Uses the modern default branch name for new repositories.' }
    [pscustomobject]@{ Name = 'merge.conflictStyle'; Value = 'zdiff3'; Why = 'Shows both sides plus base context while reducing repeated matching conflict lines.' }
    [pscustomobject]@{ Name = 'rerere.enabled'; Value = 'true'; Why = 'Records conflict resolutions so repeated conflicts can be resolved automatically.' }
    [pscustomobject]@{ Name = 'diff.algorithm'; Value = 'histogram'; Why = 'Uses a diff algorithm that often produces more readable diffs for code moves and repeated lines.' }
    [pscustomobject]@{ Name = 'push.default'; Value = 'simple'; Why = 'Keeps default push behavior conservative by pushing the current branch to its matching upstream.' }
    [pscustomobject]@{ Name = 'push.autoSetupRemote'; Value = 'true'; Why = 'Automatically sets upstream tracking when first pushing a new branch with simple/current behavior.' }
    [pscustomobject]@{ Name = 'pack.packSizeLimit'; Value = '0'; Why = 'Overrides Git for Windows legacy 2g pack limit so modern 64-bit Git can use fewer, faster packfiles.' }
)

$report = foreach ($recommendation in $recommendations) {
    $current = Invoke-GitConfigGet -Name $recommendation.Name
    $currentValue = if ($null -eq $current) { $null } else { $current.Value }
    $currentScope = if ($null -eq $current) { $null } else { $current.Scope }
    $currentOrigin = if ($null -eq $current) { $null } else { $current.Origin }
    $currentComparable = ConvertTo-ComparableGitValue -Value $currentValue
    $desiredComparable = ConvertTo-ComparableGitValue -Value $recommendation.Value
    $action = 'Unchanged'

    if ($currentComparable -ne $desiredComparable) {
        $action = 'WouldChange'

        if ($PSCmdlet.ShouldProcess($recommendation.Name, "set global value to '$($recommendation.Value)'; current effective value is '$currentValue'")) {
            Set-GitConfigGlobalValue -Name $recommendation.Name -Value $recommendation.Value
            $action = 'Changed'
        }
    }

    [pscustomobject]@{
        Action = $action
        Name = $recommendation.Name
        DesiredValue = $recommendation.Value
        PreviousValue = if ($null -eq $currentValue) { '<unset>' } else { $currentValue }
        PreviousScope = if ($null -eq $currentScope) { '<none>' } else { $currentScope }
        PreviousOrigin = if ($null -eq $currentOrigin) { '<none>' } else { $currentOrigin }
        Why = $recommendation.Why
    }
}

$changed = @($report.Where({ $_.Action -eq 'Changed' }))
$wouldChange = @($report.Where({ $_.Action -eq 'WouldChange' }))
$unchanged = @($report.Where({ $_.Action -eq 'Unchanged' }))

Write-Host ''
Write-Host 'Git Recommended Global Config' -ForegroundColor Cyan
Write-Host ('=' * 29) -ForegroundColor DarkCyan
Write-CountBadge -Label 'Changed' -Count $changed.Count -Color Green
Write-CountBadge -Label 'Would change' -Count $wouldChange.Count -Color Yellow
Write-CountBadge -Label 'Unchanged' -Count $unchanged.Count -Color DarkGray

Write-SettingTable -Title 'Changed Settings' -Rows $changed -Color Green -IncludePrevious
Write-SettingTable -Title 'Preview Changes' -Rows $wouldChange -Color Yellow -IncludePrevious
Write-SettingTable -Title 'Already Correct' -Rows $unchanged -Color DarkGray
Write-RationaleList -Rows $report

if ($PassThru) {
    $report
}