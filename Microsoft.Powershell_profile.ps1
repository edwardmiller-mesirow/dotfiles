#Requires -Version 7.7
<#
    PowerShell loads $PROFILE.CurrentUserCurrentHost, not the checkout.
    Back up any existing profile, then run these commands from the repo:
        $target = $PROFILE.CurrentUserCurrentHost
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath .\Microsoft.Powershell_profile.ps1 -Destination $target

    Copy again after updating the checkout, then open a fresh pwsh terminal.
    Tab opens PSReadLine's menu. Type to filter by prefix or use Tab and the arrow
    keys to navigate. Subcommand search falls back to substrings before Tab
    ('winget nst' finds install and uninstall). Packages need a prefix before Tab
    ('winget install vscode'); lengthen it first if the menu is full.
    Uncached lookups can wait up to five seconds. Cached results refresh in the
    background. Plain update/upgrade queries may show names while the full search
    runs; shortened labels still insert the full package name.
    Optional: posh-git (1.1+), CompletionPredictor, fnm, bat, ripgrep, and
    Microsoft.Coreutils. Native shortcuts bind to executables on PATH at startup.
#>

using namespace System.Diagnostics
using namespace System.Globalization
using namespace System.Management.Automation

# Source once per session so fnm's PATH setup and prompt wrappers are not repeated.
if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected -or
    -not (Get-Module -Name PSReadLine) -or (Get-Variable -Name DotfilesProfileLoaded -Scope Global -ErrorAction Ignore)) {
    return
}
Set-Variable -Name DotfilesProfileLoaded -Value $true -Scope Global

& {
    $useTerminalMarks = $env:WT_SESSION -and $env:TERM_PROGRAM -ne 'vscode'
    if ($IsWindows -and [Console]::OutputEncoding.CodePage -ne 65001) {
        try {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        }
        catch [System.IO.IOException] {
            Write-Warning "Could not set console output to UTF-8: $($_.Exception.Message)"
        }
    }

    $readLineOptions = @{
        EditMode                      = 'Windows'
        BellStyle                     = 'None'
        PredictionViewStyle           = 'InlineView'
        MaximumHistoryCount           = 10000
        HistoryNoDuplicates           = $true
        HistorySearchCursorMovesToEnd = $true
        ShowToolTips                  = $true
    }
    if ($Host.UI.SupportsVirtualTerminal) {
        $readLineOptions.PredictionSource = 'HistoryAndPlugin'
    }
    if ($useTerminalMarks) {
        # The trailing OSC marker prevents PSReadLine from matching the prompt suffix.
        $readLineOptions.PromptText = ''
    }
    Set-PSReadLineOption @readLineOptions

    Set-PSReadLineKeyHandler -Chord UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Chord DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Chord Tab -Function MenuComplete
    Set-PSReadLineKeyHandler -Chord Ctrl+f -Function ForwardWord
    Set-PSReadLineKeyHandler -Chord End -BriefDescription 'EndOfLineOrAcceptSuggestion' -ScriptBlock {
        param($key, $arg)

        $line = ''
        $cursor = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ($cursor -lt $line.Length) {
            [Microsoft.PowerShell.PSConsoleReadLine]::EndOfLine($key, $arg)
        }
        else {
            [Microsoft.PowerShell.PSConsoleReadLine]::ForwardChar($key, $arg)
        }
    }

    $nativeAliases = @{
        cat   = 'cat.exe'
        cp    = 'cp.exe'
        mv    = 'mv.exe'
        rm    = 'rm.exe'
        rmdir = 'rmdir.exe'
        sort  = 'sort.exe'
        grep  = 'rg.exe'
        nvm   = 'fnm.exe'
    }
    $applications = @{}
    $exeNames = @($nativeAliases.Values) + @('bat.exe', 'ls.exe', 'winget.exe', 'dotnet.exe')
    foreach ($application in (Get-Command -Name $exeNames -CommandType Application -All -ErrorAction Ignore)) {
        # Windows sort.exe can be earlier on PATH than Coreutils sort.exe.
        if ($IsWindows -and $application.Name -eq 'sort.exe' -and
            $application.Path.StartsWith("$env:SystemRoot\", [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $applications[$application.Name] ??= $application.Path
    }
    if ($applications['bat.exe']) { $nativeAliases['cat'] = 'bat.exe' }
    foreach ($shortcut in $nativeAliases.GetEnumerator()) {
        $executable = $applications[$shortcut.Value]
        if (-not $executable) { continue }

        # Built-in aliases such as cp cannot lose their AllScope option.
        $existingAlias = Get-Alias -Name $shortcut.Key -Scope Global -ErrorAction Ignore
        Set-Alias -Name $shortcut.Key -Value $executable -Option (${existingAlias}?.Options ?? 'None') -Scope Global -Force
    }

    $lsExe = $applications['ls.exe']
    if ($lsExe) {
        Remove-Alias -Name ls -Scope Global -Force -ErrorAction Ignore
        $lsOptions = '--color=auto', '--group-directories-first', '--human-readable'
        Set-Item -Path Function:\global:ls -Value ({ & $lsExe @lsOptions @args }.GetNewClosure())
        Set-Item -Path Function:\global:ll -Value ({ & $lsExe @lsOptions -la @args }.GetNewClosure())

        if ($null -eq $env:LS_COLORS) {
            $env:LS_COLORS = @(
                'di=1;38;5;75', 'ln=1;38;5;80', 'or=1;38;5;203', 'ex=1;38;5;114'
                '*.ps1=38;5;114', '*.psm1=38;5;114', '*.psd1=38;5;114'
                '*.zip=38;5;180', '*.7z=38;5;180', '*.gz=38;5;180', '*.tar=38;5;180'
                '*.md=38;5;186', '*.txt=38;5;186'
                '*.json=38;5;186', '*.yml=38;5;186', '*.yaml=38;5;186', '*.toml=38;5;186'
                '*.png=38;5;177', '*.jpg=38;5;177', '*.svg=38;5;177', '*.webp=38;5;177'
            ) -join ':'
        }
    }
    else {
        function global:ll { Get-ChildItem -Force @args }
    }

    $getPreferredMatches = {
        param($candidates, [string]$word, [switch]$commandNames)

        # MenuComplete starts filtering from the common prefix. Keep non-prefix
        # matches out of that menu unless there are no prefix matches at all.
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $fallback = [System.Collections.Generic.List[CompletionResult]]::new()
        $hasPrefixMatch = $false
        foreach ($candidate in $candidates) {
            $text = $candidate.ListItemText
            if (($commandNames -and $text -notmatch '^[a-z0-9][a-z0-9-]*$') -or -not $seen.Add($candidate.CompletionText)) {
                continue
            }
            if ($text.StartsWith($word, [StringComparison]::OrdinalIgnoreCase)) {
                $hasPrefixMatch = $true
                $candidate
            }
            elseif (-not $commandNames -or $text.Contains($word, [StringComparison]::OrdinalIgnoreCase)) {
                $fallback.Add($candidate)
            }
        }
        if (-not $hasPrefixMatch) {
            $fallback
        }
    }

    $fitPackageMenu = {
        param($candidates, [bool]$compact)

        if ($candidates.Count -le 1) {
            $candidates
            return
        }

        # PSReadLine prints a static list if the menu doesn't fit. Cap the display, not the cache.
        $rows = [Math]::Max(1, [Console]::WindowHeight - 2 - (Get-PSReadLineOption).ExtraPromptLineCount)
        $width = [Math]::Max(1, [Console]::BufferWidth)
        $maxLabelWidth = [Math]::Floor($width / 2) - 2
        $rawUI = $Host.UI.RawUI
        $columnWidth = 1
        $shown = 0
        foreach ($candidate in $candidates) {
            $label = $candidate.ListItemText
            $labelWidth = $rawUI.LengthInBufferCells($label)
            if ($compact -and $maxLabelWidth -ge 24 -and $labelWidth -gt $maxLabelWidth) {
                # Keep full insertion and filtering text; clip only the label at a text element boundary.
                $elements = [StringInfo]::GetTextElementEnumerator($label)
                $end = 0
                $cells = 3
                while ($elements.MoveNext()) {
                    $element = $elements.GetTextElement()
                    $cells += $rawUI.LengthInBufferCells($element)
                    if ($cells -gt $maxLabelWidth) {
                        break
                    }
                    $end += $element.Length
                }
                $shortLabel = $label.Substring(0, $end) + '...'
                $labelWidth = $rawUI.LengthInBufferCells($shortLabel)
                $candidate = [CompletionResult]::new($candidate.CompletionText, $shortLabel, $candidate.ResultType, "Package: $label")
            }
            $columnWidth = [Math]::Min($width, [Math]::Max($columnWidth, $labelWidth + 2))
            if ($shown -ge $rows * [Math]::Floor($width / $columnWidth)) {
                break
            }
            $candidate
            $shown++
        }
    }

    $stopCompletion = {
        param([Process]$process)

        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -ErrorAction SilentlyContinue -ErrorVariable stopError
            if ($stopError -and -not $process.HasExited) {
                Write-Warning "Could not stop native completion: $stopError"
            }
        }
    }
    $watchCompletion = {
        $state = $Event.MessageData
        $pending = $state.Pending
        if (-not $pending -or $pending.Done.IsCompleted) {
            return
        }

        $remaining = $pending.Deadline - [Environment]::TickCount64
        if ($Event.SourceIdentifier -eq 'PowerShell.Exiting' -or $remaining -le 0) {
            $pending.TimedOut = $true
            & $state.Stop $pending.Process
        }
        elseif (-not $Sender.Enabled) {
            # A queued timer event can arrive just before the current deadline.
            $Sender.Interval = $remaining
            $Sender.Start()
        }
    }
    $findCachedPrefix = {
        param($cache, $key, [long]$now)

        # Reuse the longest matching prefix from the same argument slot and context.
        $line, $word, $position, $cwd = $key.Item1, $key.Item2, $key.Item3, $key.Item4
        $bestLength, $preview = 0, $null
        foreach ($cached in $cache.GetEnumerator()) {
            $prefix = $cached.Key.Item2
            $extra = $word.Length - $prefix.Length
            $end = $position - $extra
            if ($prefix.Length -le $bestLength -or $extra -le 0 -or $cached.Key.Item3 -ne $end -or
                $now -ge $cached.Value.ExpiresAt -or -not $cached.Value.Results -or
                -not $word.StartsWith($prefix, [StringComparison]::Ordinal) -or
                -not $cwd.Equals($cached.Key.Item4, [StringComparison]::Ordinal) -or
                -not $line.Remove($end, $extra).Equals($cached.Key.Item1, [StringComparison]::Ordinal)) {
                continue
            }
            $matches = foreach ($candidate in $cached.Value.Results) {
                if ($candidate.ListItemText.StartsWith($word, [StringComparison]::OrdinalIgnoreCase)) { $candidate }
            }
            if ($matches) {
                $bestLength, $preview = $prefix.Length, $matches
            }
        }
        $preview
    }
    $completionTimeoutMs = 5000
    foreach ($cliName in 'winget', 'dotnet') {
        $exeName = "$cliName.exe"
        $completionExe = $applications[$exeName]
        if (-not $completionExe) {
            continue
        }

        $completionState = @{
            Cache = [System.Collections.Generic.OrderedDictionary[ValueTuple[string,string,int,string],object]]::new()
            Pending = $null
            Stop = $stopCompletion
        }
        $completionTimer = [System.Timers.Timer]::new($completionTimeoutMs)
        $completionTimer.AutoReset = $false
        $null = Register-ObjectEvent -InputObject $completionTimer -EventName Elapsed -MessageData $completionState -Action $watchCompletion
        $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -MessageData $completionState -Action $watchCompletion

        $receiveCompletion = {
            param($pending)

            $completionTimer.Stop()
            $completionState.Pending = $null
            try {
                $failure = if ($pending.TimedOut) { 'timed out.' }
                elseif ($pending.Done.IsFaulted) { "failed: $($pending.Done.Exception.GetBaseException().Message)" }
                elseif ($pending.Process.ExitCode -ne 0) {
                    "failed (exit code $($pending.Process.ExitCode)): $($pending.Error.Result.Trim())"
                }
                if ($failure) {
                    Write-Verbose "$exeName completion $failure"
                    return $false
                }

                $results = foreach ($candidate in $pending.Output.Result -split '\r?\n') {
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                        # WinGet quotes names with spaces for insertion, not for display or filtering.
                        $label = if ($cliName -eq 'winget' -and $candidate.Length -gt 2 -and
                            $candidate[0] -eq '"' -and $candidate[-1] -eq '"') {
                            $candidate.Substring(1, $candidate.Length - 2)
                        }
                        else { $candidate }
                        [CompletionResult]::new($candidate, $label, 'ParameterValue', $label)
                    }
                }
                $cache = $completionState.Cache
                [void]$cache.Remove($pending.Key)
                if ($cache.Count -ge 64) {
                    $cache.RemoveAt(0)
                }
                $ttl = if ($results) { 60000 } else { 15000 }
                $cache.Add($pending.Key, @{
                    Results = $results
                    RefreshAt = $pending.StartedAt + $ttl
                    ExpiresAt = $pending.StartedAt + 300000
                })
                return $true
            }
            finally {
                $pending.Process.Dispose()
            }
        }.GetNewClosure()

        $startCompletion = {
            param($key, [long]$startedAt, [int]$timeoutMs)

            $line, $word, $position, $cwd = $key.Item1, $key.Item2, $key.Item3, $key.Item4
            $arguments = if ($cliName -eq 'winget') {
                $textPosition = [StringInfo]::new($line.Substring(0, $position)).LengthInTextElements
                'complete', "--word=$word", '--commandline', $line, '--position', $textPosition
            }
            else {
                'complete', '--position', $position, $line
            }
            $start = [ProcessStartInfo]@{
                FileName = $completionExe
                WorkingDirectory = $cwd
                UseShellExecute = $false
                CreateNoWindow = $true
                RedirectStandardInput = $true
                RedirectStandardOutput = $true
                RedirectStandardError = $true
                StandardOutputEncoding = [Text.Encoding]::UTF8
                StandardErrorEncoding = [Text.Encoding]::UTF8
            }
            foreach ($argument in $arguments) {
                $start.ArgumentList.Add([string]$argument)
            }

            $process = $null
            try {
                $process = [Process]::Start($start)
                $process.StandardInput.Close()
                $output = $process.StandardOutput.ReadToEndAsync()
                $errorOutput = $process.StandardError.ReadToEndAsync()
                $completionState.Pending = @{
                    Key = $key
                    Process = $process
                    Output = $output
                    Error = $errorOutput
                    Done = [System.Threading.Tasks.Task]::WhenAll([System.Threading.Tasks.Task[]]@(
                        $output, $errorOutput, $process.WaitForExitAsync()
                    ))
                    StartedAt = $startedAt
                    Deadline = [Environment]::TickCount64 + $timeoutMs
                    TimedOut = $false
                }
                $completionTimer.Interval = $timeoutMs
                $completionTimer.Start()
            }
            catch [System.ComponentModel.Win32Exception], [InvalidOperationException], [System.IO.IOException] {
                Write-Verbose "Could not start $exeName completion: $($_.Exception.Message)"
                $completionState.Pending = $null
                if ($process) {
                    & $completionState.Stop $process
                    $process.Dispose()
                }
            }
        }.GetNewClosure()

        $getCompletion = {
            param(
                [ValueTuple[string,string,int,string]]$key, [long]$deadline,
                [switch]$reusePrefix, [switch]$cacheOnly, [switch]$background, [int]$processTimeoutMs = $completionTimeoutMs
            )

            $now = [Environment]::TickCount64
            $cache = $completionState.Cache
            $pending = $completionState.Pending
            $failed = $false

            if ($pending -and ($pending.TimedOut -or $pending.Done.IsCompleted)) {
                $received = & $receiveCompletion $pending
                $failed = -not $received -and $key.Equals($pending.Key)
                $pending = $null
            }

            $entry = $null
            if ($cache.Remove($key, [ref]$entry) -and $now -lt $entry.ExpiresAt) {
                $cache.Add($key, $entry)
            }
            else {
                $entry = $null
            }

            $preview = if ($reusePrefix -and -not $entry) { & $findCachedPrefix $cache $key $now }

            if ($cacheOnly -and -not $entry -and -not $preview) {
                return
            }

            $allowBackground = $processTimeoutMs -gt $completionTimeoutMs
            # Only a miss without a preview can displace another query's refresh.
            $canStart = -not $pending -or (-not $entry -and -not $preview -and -not $key.Equals($pending.Key))
            $needsRefresh = -not $entry -or $now -ge $entry.RefreshAt
            if (-not $failed -and $canStart -and $needsRefresh -and ($entry -or $allowBackground -or $now -lt $deadline)) {
                if ($pending) {
                    $completionTimer.Stop()
                    $completionState.Pending = $null
                    & $completionState.Stop $pending.Process
                    $pending.Process.Dispose()
                }

                & $startCompletion $key $now $processTimeoutMs
            }

            if ($entry -or $preview) {
                # A prefix preview isn't the exact answer and is never stored under this key.
                if ($entry) { $entry.Results } else { $preview }
                return
            }
            $pending = $completionState.Pending
            if ($background -or -not $pending -or -not $key.Equals($pending.Key)) {
                return
            }

            # PSReadLine needs the matches before this completion call returns.
            if (-not $pending.TimedOut) {
                $remaining = [Math]::Max(0, [Math]::Min($deadline, $pending.Deadline) - [Environment]::TickCount64)
                try {
                    $null = $pending.Done.Wait([int]$remaining)
                }
                catch [AggregateException] {
                    if (-not $pending.Done.IsFaulted) {
                        throw
                    }
                    # The receiver reports the task error.
                }
            }
            if (-not $pending.Done.IsCompleted -and -not $pending.TimedOut) {
                if ($allowBackground -and [Environment]::TickCount64 -lt $pending.Deadline) {
                    return
                }
                $pending.TimedOut = $true
                & $completionState.Stop $pending.Process
            }
            if (& $receiveCompletion $pending) {
                $cache[$key].Results
            }
        }.GetNewClosure()

        $getUpgradeCandidates = {
            param($key, [long]$deadline)

            # A name-only lookup can open the menu while the broad search finishes in the background.
            $lookup = @{ Key = $key; Deadline = $deadline; ReusePrefix = $true; ProcessTimeoutMs = 20000 }
            $cached = @(& $getCompletion @lookup -CacheOnly)
            if ($cached.Count) {
                $cached
                return
            }

            $line, $word, $position, $cwd = $key.Item1, $key.Item2, $key.Item3, $key.Item4
            $fullPending = $completionState.Pending -and $key.Equals($completionState.Pending.Key)
            $option = '--name '
            $nameKey = [ValueTuple[string,string,int,string]]::new(
                $line.Insert($position - $word.Length, $option), $word, $position + $option.Length, $cwd
            )
            $names = @(& $getCompletion $nameKey $deadline -ReusePrefix -CacheOnly:$fullPending)
            $full = @(& $getCompletion @lookup -Background:($names.Count -gt 0))
            if ($full.Count) { $full } else { $names }
        }.GetNewClosure()

        Register-ArgumentCompleter -Native -CommandName $cliName, $exeName -ScriptBlock ({
            param([string]$wordToComplete, $commandAst, $cursorPosition)

            $deadline = [Environment]::TickCount64 + $completionTimeoutMs
            # The AST omits trailing spaces and may start after other statements.
            $position = $cursorPosition - $commandAst.Extent.StartOffset
            $commandLine = $commandAst.Extent.Text.PadRight($position)
            $cwd = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
            $key = [ValueTuple[string,string,int,string]]::new($commandLine, $wordToComplete, $position, $cwd)
            $subcommand = if ($commandAst.CommandElements.Count -gt 1) { $commandAst.CommandElements[1].Extent }
            if ($subcommand -and $cursorPosition -ge $subcommand.StartOffset -and $cursorPosition -le $subcommand.EndOffset -and
                $wordToComplete -match '^[a-z0-9][a-z0-9-]*$') {
                $catalog = [ValueTuple[string,string,int,string]]::new("$cliName ", '', $cliName.Length + 1, $cwd)
                $candidates = @(& $getCompletion $catalog $deadline)
                if ($cliName -eq 'winget' -or -not $candidates) {
                    # WinGet includes aliases only when completing a non-empty word.
                    $candidates = @(& $getCompletion $key $deadline) + $candidates
                }
                & $getPreferredMatches $candidates $wordToComplete -CommandNames
                return
            }

            $wordStart = $cursorPosition - $wordToComplete.Length
            $packageWord = if ($cliName -eq 'winget' -and $wordToComplete -and $wordToComplete[0] -ne '-' -and
                $subcommand -and $wordStart -gt $subcommand.EndOffset -and
                $subcommand.Text -in 'install', 'add', 'search', 'find', 'show', 'view', 'list', 'ls',
                    'upgrade', 'update', 'uninstall', 'remove', 'rm', 'download', 'repair') {
                $wordToComplete.Trim([char]34, [char]39)
            }
            if (-not $packageWord) {
                & $getCompletion $key $deadline
                return
            }

            $reusePrefix = $wordToComplete -match '^[\p{L}\p{Nd}][\p{L}\p{M}\p{Nd}._+-]*$' -and
                ($position -eq $commandLine.Length -or [char]::IsWhiteSpace($commandLine[$position])) -and
                $commandLine.Substring($position - $wordToComplete.Length, $wordToComplete.Length) -ceq $wordToComplete
            $plainUpgradeQuery = $reusePrefix -and $subcommand.Text -in 'upgrade', 'update' -and
                $commandAst.CommandElements.Count -eq 3 -and $position -eq $commandLine.Length
            $candidates = if ($plainUpgradeQuery) { & $getUpgradeCandidates $key $deadline }
            else { & $getCompletion $key $deadline -ReusePrefix:$reusePrefix }
            & $fitPackageMenu @(& $getPreferredMatches $candidates $packageWord) $plainUpgradeQuery
        }.GetNewClosure())
    }

    # Load optional tools before the first prompt so drawing it has no setup work.
    foreach ($spec in @(@{ ModuleName = 'posh-git'; ModuleVersion = '1.1.0' }, 'CompletionPredictor')) {
        $module = Get-Module -ListAvailable -FullyQualifiedName $spec | Select-Object -First 1
        if (-not $module) { continue }
        try {
            Import-Module -ModuleInfo $module -Global -NoClobber -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not load $($module.Name): $($_.Exception.Message)"
        }
    }

    $fnmExe = $applications['fnm.exe']
    if ($fnmExe) {
        try {
            $fnmScript = & {
                # Decode fnm's UTF-8 output without relying on the console code page.
                Set-Variable -Name PSApplicationOutputEncoding -Value ([System.Text.Encoding]::UTF8)
                $code = (& $fnmExe env --use-on-cd --shell powershell) -join "`n"
                if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($code)) {
                    throw "fnm env returned no usable PowerShell script (exit code $LASTEXITCODE)."
                }
                $code
            }
            # fnm emits the environment changes and the global cd hook.
            & ([scriptblock]::Create($fnmScript))
        }
        catch {
            Write-Warning "Could not initialize fnm: $($_.Exception.Message)"
        }
    }

    if ($useTerminalMarks) {
        $basePrompt = $function:prompt
        $history = @{ HasPrompted = $false; Id = $null }
        Set-Item -Path Function:\global:prompt -Value ({
            $succeeded = $?
            $entry = Get-History -Count 1
            $historyId = ${entry}?.Id
            $finished = if ($history.HasPrompted) {
                # Terminal colors only need success/failure; LASTEXITCODE can be stale.
                if ($historyId -eq $history.Id) { "`e]133;D`a" }
                elseif ($succeeded) { "`e]133;D;0`a" }
                else { "`e]133;D;1`a" }
            }
            $history.HasPrompted = $true
            $history.Id = $historyId

            $location = $ExecutionContext.SessionState.Path.CurrentLocation
            $cwd = if ($location.Provider.Name -eq 'FileSystem' -and $location.ProviderPath -notmatch '["\p{Cc}]') {
                "`e]9;9;`"$($location.ProviderPath)`"`a"
            }
            "$finished`e]133;A`a$cwd$((& $basePrompt) -join '')`e]133;B`a"
        }.GetNewClosure())
    }
}
