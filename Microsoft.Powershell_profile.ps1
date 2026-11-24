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
                        [System.Management.Automation.CompletionResult]::new($candidate, $candidate, 'ParameterValue', $candidate)
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
            param([string]$commandLine, [string]$wordToComplete, [int]$position, [string]$cwd, [long]$deadline)

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

            # A cache miss can replace a running refresh; a stale hit does not need to.
            if (-not $failed -and ($entry -or $now -lt $deadline) -and
                (-not $entry -or $now -ge $entry.RefreshAt) -and
                (-not $pending -or (-not $entry -and -not $key.Equals($pending.Key)))) {
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
                        Deadline = [Environment]::TickCount64 + $completionTimeoutMs
                        TimedOut = $false
                    }
                    $completionTimer.Interval = $completionTimeoutMs
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
                    $pending.TimedOut = $true
                    & $completionState.Stop $pending.Process
                }
                if (& $receiveCompletion $pending) {
                    $cache[$key].Results
                }
            }
        }.GetNewClosure()

        Register-ArgumentCompleter -Native -CommandName $cliName, $exeName -ScriptBlock ({
            param($wordToComplete, $commandAst, $cursorPosition)

            $deadline = [Environment]::TickCount64 + $completionTimeoutMs
            # The AST omits trailing spaces and may start after other statements.
            $position = $cursorPosition - $commandAst.Extent.StartOffset
            $commandLine = $commandAst.Extent.Text.PadRight($position)
            $cwd = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
            $firstArgument = if ($commandAst.CommandElements.Count -gt 1) { $commandAst.CommandElements[1] }
            if ($wordToComplete -notmatch '^[a-z0-9][a-z0-9-]*$' -or -not $firstArgument -or
                $cursorPosition -lt $firstArgument.Extent.StartOffset -or $cursorPosition -gt $firstArgument.Extent.EndOffset) {
                & $getCompletion $commandLine $wordToComplete $position $cwd $deadline
                return
            }

            $candidates = @(& $getCompletion "$cliName " '' ($cliName.Length + 1) $cwd $deadline)
            if ($cliName -eq 'winget' -or -not $candidates) {
                # WinGet includes aliases only when asked to match a non-empty word.
                $candidates = @(& $getCompletion $commandLine $wordToComplete $position $cwd $deadline) + $candidates
            }

            # Mixing prefix and substring matches can make MenuComplete lose the
            # typed prefix, since it starts filtering from the common prefix.
            $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $hasPrefixMatch = $false
            $substringMatches = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
            foreach ($candidate in $candidates) {
                $text = $candidate.CompletionText
                if ($text -notmatch '^[a-z0-9][a-z0-9-]*$' -or -not $seen.Add($text)) {
                    continue
                }
                if ($text.StartsWith($wordToComplete, [StringComparison]::OrdinalIgnoreCase)) {
                    $hasPrefixMatch = $true
                    $candidate
                }
                elseif ($text.Contains($wordToComplete, [StringComparison]::OrdinalIgnoreCase)) {
                    $substringMatches.Add($candidate)
                }
            }
            if (-not $hasPrefixMatch) {
                $substringMatches
            }
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
