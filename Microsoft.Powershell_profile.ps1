#Requires -Version 7.7
<#
    Install at $PROFILE.CurrentUserCurrentHost for the pwsh console.
    Optional: posh-git (1.1+), CompletionPredictor, fnm, bat, ripgrep,
    and Microsoft.Coreutils. WinGet and the .NET SDK provide on-demand tab
    completion. Native shortcuts bind to executables found on PATH at startup.
    Open a new shell after changing this file.
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
        if ($completionExe) {
            Register-ArgumentCompleter -Native -CommandName $cliName, $exeName -ScriptBlock ({
                param($wordToComplete, $commandAst, $cursorPosition)

                # The AST omits trailing spaces and may start after other statements.
                $position = $cursorPosition - $commandAst.Extent.StartOffset
                $commandLine = $commandAst.Extent.Text.PadRight($position)
                $completionArgs = if ($cliName -eq 'winget') {
                    $textPosition = [System.Globalization.StringInfo]::new($commandLine.Substring(0, $position)).LengthInTextElements
                    'complete', "--word=$wordToComplete", '--commandline', $commandLine, '--position', $textPosition
                }
                else {
                    'complete', '--position', $position, $commandLine
                }

                # Standard argument passing preserves quotes without manual escaping.
                Set-Variable -Name PSNativeCommandArgumentPassing -Value 'Standard'
                Set-Variable -Name PSApplicationOutputEncoding -Value ([System.Text.Encoding]::UTF8)
                $exitVariable = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
                $previousExitCode = if ($exitVariable) { $exitVariable.Value }
                try {
                    $candidates = & $completionExe @completionArgs
                    $exitCode = $LASTEXITCODE
                }
                finally {
                    if ($exitVariable) {
                        $exitVariable.Value = $previousExitCode
                    }
                    else {
                        Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
                    }
                }
                if ($exitCode -ne 0) {
                    Write-Verbose "$exeName completion failed (exit code $exitCode)."
                    return
                }

                foreach ($candidate in $candidates) {
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                        [System.Management.Automation.CompletionResult]::new($candidate, $candidate, 'ParameterValue', $candidate)
                    }
                }
            }.GetNewClosure())
        }
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
