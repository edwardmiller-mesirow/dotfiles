#Requires -Version 7.7
<#
    PowerShell loads $PROFILE.CurrentUserCurrentHost, not the checkout.
    Back up any existing profile, then run these commands from the repo:
        $target = $PROFILE.CurrentUserCurrentHost
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath .\Microsoft.Powershell_profile.ps1 -Destination $target

    Copy again after updating the checkout, then open a fresh pwsh terminal.
    Press Tab after 'winget ' or 'dotnet ' to open the PSReadLine menu. Type to
    narrow it by prefix, or navigate with Tab and the arrow keys.
    Before Tab, subcommands fall back to substring matches when no prefix matches
    (e.g. 'winget nst' finds install and uninstall).
    For WinGet packages, type a prefix before Tab (e.g. 'winget install vscode').
    Type more in the open menu to narrow the results without calling WinGet again.
    If the menu is full, narrow the query before pressing Tab to find more matches.
    Plain 'winget update Mic' and 'winget upgrade Mic' queries can show installed
    package names first; the full WinGet results are cached in the background.
    Long update labels may be shortened to fit two columns, but insert in full.
    The first Tab can wait up to five seconds for uncached native suggestions.
    Cached suggestions appear immediately and refresh in the background.
    Optional: posh-git (1.1+), CompletionPredictor, fnm, bat, ripgrep, and
    Microsoft.Coreutils. Native shortcuts bind to executables on PATH at startup.
#>

if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected -or
    [Console]::IsOutputRedirected -or -not (Get-Module -Name PSReadLine)) {
    return
}

# Source once per session so fnm's PATH setup and prompt wrappers are not repeated.
if (Get-Variable -Name DotfilesProfileLoaded -Scope Global -ErrorAction Ignore) {
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
        if (-not $applications.ContainsKey($application.Name)) {
            $applications[$application.Name] = $application.Path
        }
    }
    if ($applications['bat.exe']) {
        $nativeAliases['cat'] = 'bat.exe'
    }
    foreach ($shortcut in $nativeAliases.GetEnumerator()) {
        $executable = $applications[$shortcut.Value]
        if ($executable) {
            # Built-in aliases such as cp cannot lose their AllScope option.
            $existingAlias = Get-Alias -Name $shortcut.Key -Scope Global -ErrorAction Ignore
            $options = if ($existingAlias) { $existingAlias.Options } else { 'None' }
            Set-Alias -Name $shortcut.Key -Value $executable -Option $options -Scope Global -Force
        }
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
        $fallback = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
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

    foreach ($cliName in 'winget', 'dotnet') {
        $exeName = "$cliName.exe"
        $completionExe = $applications[$exeName]
        if (-not $completionExe) {
            continue
        }

        $completionState = @{
            Cache = [System.Collections.Generic.OrderedDictionary[ValueTuple[string,string,int,string],object]]::new()
            Pending = $null
            Stop = {
                param([System.Diagnostics.Process]$process)

                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -ErrorAction SilentlyContinue -ErrorVariable stopError
                    if ($stopError -and -not $process.HasExited) {
                        Write-Warning "Could not stop native completion: $stopError"
                    }
                }
            }
        }
        $completionTimeoutMs = 5000
        $completionTimer = [System.Timers.Timer]::new($completionTimeoutMs)
        $completionTimer.AutoReset = $false
        $stopPendingCompletion = {
            $state = $Event.MessageData
            $pending = $state.Pending
            if ($pending -and -not $pending.Done.IsCompleted) {
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
        }
        Register-ObjectEvent -InputObject $completionTimer -EventName Elapsed -MessageData $completionState -Action $stopPendingCompletion | Out-Null
        Register-EngineEvent -SourceIdentifier PowerShell.Exiting -MessageData $completionState -Action $stopPendingCompletion | Out-Null

        $receiveCompletion = {
            param($pending)

            $completionTimer.Stop()
            $completionState.Pending = $null
            try {
                if ($pending.TimedOut) {
                    Write-Verbose "$exeName completion timed out."
                    return $false
                }
                if ($pending.Done.IsFaulted) {
                    Write-Verbose "$exeName completion failed: $($pending.Done.Exception.GetBaseException().Message)"
                    return $false
                }
                if ($pending.Process.ExitCode -ne 0) {
                    Write-Verbose "$exeName completion failed (exit code $($pending.Process.ExitCode)): $($pending.Error.Result.Trim())"
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
                        [System.Management.Automation.CompletionResult]::new($candidate, $label, 'ParameterValue', $label)
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

        $getCompletion = {
            param(
                [string]$commandLine, [string]$wordToComplete, [int]$position, [string]$cwd, [long]$deadline,
                [switch]$reusePrefix, [switch]$cacheOnly, [switch]$background, [int]$processTimeoutMs = $completionTimeoutMs
            )

            $key = [ValueTuple[string,string,int,string]]::new($commandLine, $wordToComplete, $position, $cwd)
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
            if ($cache.TryGetValue($key, [ref]$entry)) {
                [void]$cache.Remove($key)
                if ($now -lt $entry.ExpiresAt) {
                    $cache.Add($key, $entry)
                }
                else {
                    $entry = $null
                }
            }

            $preview = $null
            if ($reusePrefix -and -not $entry) {
                # Only reuse a shorter word in the same slot and context (including --source).
                $bestLength = 0
                foreach ($cached in $cache.GetEnumerator()) {
                    $prefix = $cached.Key.Item2
                    if ($prefix.Length -le $bestLength -or $prefix.Length -ge $wordToComplete.Length -or
                        $now -ge $cached.Value.ExpiresAt -or -not $cached.Value.Results -or
                        -not $cwd.Equals($cached.Key.Item4, [StringComparison]::Ordinal) -or
                        -not $wordToComplete.StartsWith($prefix, [StringComparison]::Ordinal)) {
                        continue
                    }
                    $removed = $wordToComplete.Length - $prefix.Length
                    $previousPosition = $position - $removed
                    if ($cached.Key.Item3 -ne $previousPosition -or
                        -not $commandLine.Remove($previousPosition, $removed).Equals($cached.Key.Item1, [StringComparison]::Ordinal)) {
                        continue
                    }
                    $matches = @(foreach ($candidate in $cached.Value.Results) {
                        if ($candidate.ListItemText.StartsWith($wordToComplete, [StringComparison]::OrdinalIgnoreCase)) {
                            $candidate
                        }
                    })
                    if ($matches.Count) {
                        $bestLength = $prefix.Length
                        $preview = $matches
                    }
                }
            }

            if ($cacheOnly -and -not $entry -and -not $preview) {
                return
            }

            $allowBackground = $processTimeoutMs -gt $completionTimeoutMs
            # A cache miss can replace a running refresh; a stale hit does not need to.
            if (-not $failed -and ($entry -or $allowBackground -or $now -lt $deadline) -and
                (-not $entry -or $now -ge $entry.RefreshAt) -and
                (-not $pending -or (-not $entry -and -not $preview -and -not $key.Equals($pending.Key)))) {
                if ($pending) {
                    $completionTimer.Stop()
                    $completionState.Pending = $null
                    & $completionState.Stop $pending.Process
                    $pending.Process.Dispose()
                }

                $start = [System.Diagnostics.ProcessStartInfo]::new($completionExe)
                $start.UseShellExecute = $false
                $start.CreateNoWindow = $true
                $start.WorkingDirectory = $cwd
                $start.RedirectStandardInput = $true
                $start.RedirectStandardOutput = $true
                $start.RedirectStandardError = $true
                $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
                $start.StandardErrorEncoding = [System.Text.Encoding]::UTF8
                $arguments = if ($cliName -eq 'winget') {
                    $textPosition = [System.Globalization.StringInfo]::new($commandLine.Substring(0, $position)).LengthInTextElements
                    'complete', "--word=$wordToComplete", '--commandline', $commandLine, '--position', $textPosition
                }
                else {
                    'complete', '--position', $position, $commandLine
                }
                foreach ($argument in $arguments) {
                    $start.ArgumentList.Add([string]$argument)
                }

                $process = $null
                try {
                    $process = [System.Diagnostics.Process]::Start($start)
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
                        StartedAt = $now
                        Deadline = [Environment]::TickCount64 + $processTimeoutMs
                        TimedOut = $false
                    }
                    $completionTimer.Interval = $processTimeoutMs
                    $completionTimer.Start()
                }
                catch [System.ComponentModel.Win32Exception], [System.InvalidOperationException], [System.IO.IOException] {
                    Write-Verbose "Could not start $exeName completion: $($_.Exception.Message)"
                    $completionState.Pending = $null
                    if ($process) {
                        & $completionState.Stop $process
                        $process.Dispose()
                    }
                }
            }

            if ($entry) {
                $entry.Results
                return
            }
            if ($preview) {
                # A shorter search need not be exhaustive. Don't cache this as the exact answer.
                $preview
                return
            }
            if ($background) {
                return
            }

            $pending = $completionState.Pending
            if ($pending -and $key.Equals($pending.Key)) {
                # PSReadLine needs the matches before this completion call returns.
                $remaining = [Math]::Max(0, [Math]::Min($deadline, $pending.Deadline) - [Environment]::TickCount64)
                if (-not $pending.TimedOut) {
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
            }
        }.GetNewClosure()

        Register-ArgumentCompleter -Native -CommandName $cliName, $exeName -ScriptBlock ({
            param([string]$wordToComplete, $commandAst, $cursorPosition)

            $deadline = [Environment]::TickCount64 + $completionTimeoutMs
            # The AST omits trailing spaces and may start after other statements.
            $position = $cursorPosition - $commandAst.Extent.StartOffset
            $commandLine = $commandAst.Extent.Text.PadRight($position)
            $cwd = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
            $firstArgument = if ($commandAst.CommandElements.Count -gt 1) { $commandAst.CommandElements[1] }
            if ($wordToComplete -notmatch '^[a-z0-9][a-z0-9-]*$' -or -not $firstArgument -or
                $cursorPosition -lt $firstArgument.Extent.StartOffset -or $cursorPosition -gt $firstArgument.Extent.EndOffset) {
                $packageWord = ''
                $wordStart = $cursorPosition - $wordToComplete.Length
                if ($cliName -eq 'winget' -and $wordToComplete -and $wordToComplete[0] -ne '-' -and
                    $firstArgument -and $wordStart -gt $firstArgument.Extent.EndOffset -and
                    $firstArgument.Extent.Text -in 'install', 'add', 'search', 'find', 'show', 'view', 'list', 'ls',
                        'upgrade', 'update', 'uninstall', 'remove', 'rm', 'download', 'repair') {
                    # Let WinGet resolve positional queries, filters, and other option values.
                    $packageWord = $wordToComplete.Trim([char]34, [char]39)
                }
                if (-not $packageWord) {
                    & $getCompletion $commandLine $wordToComplete $position $cwd $deadline
                    return
                }

                $reusePrefix = $wordToComplete -match '^[\p{L}\p{Nd}][\p{L}\p{M}\p{Nd}._+-]*$' -and
                    ($position -eq $commandLine.Length -or [char]::IsWhiteSpace($commandLine[$position])) -and
                    $commandLine.Substring($position - $wordToComplete.Length, $wordToComplete.Length) -ceq $wordToComplete
                $plainUpgradeQuery = $reusePrefix -and $firstArgument.Extent.Text -in 'upgrade', 'update' -and
                    $commandAst.CommandElements.Count -eq 3 -and $position -eq $commandLine.Length
                if ($plainUpgradeQuery) {
                    # A field-specific lookup is faster than WinGet's broad upgrade search.
                    # Use the full result when cached; don't overwrite it with the name preview.
                    $query = @{
                        CommandLine = $commandLine; WordToComplete = $wordToComplete; Position = $position
                        Cwd = $cwd; Deadline = $deadline; ReusePrefix = $true; ProcessTimeoutMs = 20000
                    }
                    $candidates = @(& $getCompletion @query -CacheOnly)
                    if (-not $candidates) {
                        $fullKey = [ValueTuple[string,string,int,string]]::new($commandLine, $wordToComplete, $position, $cwd)
                        $fullPending = $completionState.Pending -and $fullKey.Equals($completionState.Pending.Key)
                        $nameOption = '--name '
                        $nameQuery = $commandLine.Insert($position - $wordToComplete.Length, $nameOption)
                        $names = @(& $getCompletion $nameQuery $wordToComplete ($position + $nameOption.Length) $cwd $deadline -ReusePrefix -CacheOnly:$fullPending)
                        $candidates = @(& $getCompletion @query -Background:($names.Count -gt 0))
                        if (-not $candidates) {
                            $candidates = $names
                        }
                    }
                }
                else {
                    $candidates = @(& $getCompletion $commandLine $wordToComplete $position $cwd $deadline -ReusePrefix:$reusePrefix)
                }
                # The fallback keeps native matches such as Store IDs and monikers.
                $preferred = @(& $getPreferredMatches $candidates $packageWord)
                if ($preferred.Count -gt 1) {
                    # PSReadLine switches to a static list if the menu doesn't fit.
                    # Reserve space for the prompt and a wrapped input line; keep the cache uncapped.
                    $rows = [Math]::Max(1, [Console]::WindowHeight - 2 - (Get-PSReadLineOption).ExtraPromptLineCount)
                    $width = [Math]::Max(1, [Console]::BufferWidth)
                    $maxLabelWidth = [Math]::Floor($width / 2) - 2
                    $compactLabels = $plainUpgradeQuery -and $maxLabelWidth -ge 24
                    $menu = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
                    $columnWidth = 1
                    foreach ($candidate in $preferred) {
                        $label = $candidate.ListItemText
                        $labelWidth = $Host.UI.RawUI.LengthInBufferCells($label)
                        if ($compactLabels -and $labelWidth -gt $maxLabelWidth) {
                            # Clip at a text element boundary; PSReadLine also filters on the full CompletionText.
                            $elements = [Globalization.StringInfo]::GetTextElementEnumerator($label)
                            $end = 0
                            $cells = 0
                            while ($elements.MoveNext()) {
                                $element = $elements.GetTextElement()
                                $cells += $Host.UI.RawUI.LengthInBufferCells($element)
                                if ($cells + 3 -gt $maxLabelWidth) {
                                    break
                                }
                                $end += $element.Length
                            }
                            $shortLabel = $label.Substring(0, $end) + '...'
                            $labelWidth = $Host.UI.RawUI.LengthInBufferCells($shortLabel)
                            $candidate = [System.Management.Automation.CompletionResult]::new(
                                $candidate.CompletionText, $shortLabel, $candidate.ResultType, "Package: $label")
                        }
                        $columnWidth = [Math]::Min($width, [Math]::Max($columnWidth, $labelWidth + 2))
                        if ($menu.Count -ge $rows * [Math]::Floor($width / $columnWidth)) {
                            break
                        }
                        $menu.Add($candidate)
                    }
                    $preferred = $menu
                }
                $preferred
                return
            }

            $candidates = @(& $getCompletion "$cliName " '' ($cliName.Length + 1) $cwd $deadline)
            if ($cliName -eq 'winget' -or -not $candidates) {
                # WinGet includes aliases only when asked to match a non-empty word.
                $candidates = @(& $getCompletion $commandLine $wordToComplete $position $cwd $deadline) + $candidates
            }

            & $getPreferredMatches $candidates $wordToComplete -CommandNames
        }.GetNewClosure())
    }

    # Load optional tools before the first prompt so drawing it has no setup work.
    foreach ($spec in @(@{ ModuleName = 'posh-git'; ModuleVersion = '1.1.0' }, 'CompletionPredictor')) {
        $module = Get-Module -ListAvailable -FullyQualifiedName $spec | Select-Object -First 1
        if ($module) {
            try {
                Import-Module -ModuleInfo $module -Global -NoClobber -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not load $($module.Name): $($_.Exception.Message)"
            }
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
        & {
            $basePrompt = $function:prompt
            $history = @{ HasPrompted = $false; Id = $null }
            Set-Item -Path Function:\global:prompt -Value ({
                $succeeded = $?
                $entry = Get-History -Count 1
                $historyId = if ($entry) { $entry.Id }
                $finished = ''
                if ($history.HasPrompted) {
                    # Terminal colors only need success/failure; LASTEXITCODE can be stale.
                    $finished = if ($historyId -eq $history.Id) { "`e]133;D`a" }
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
}
