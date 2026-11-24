#Requires -Version 7.7
<#
    Install at $PROFILE.CurrentUserCurrentHost for the pwsh console.
    Optional: posh-git (1.1+), CompletionPredictor, fnm, bat, ripgrep,
    and Microsoft.Coreutils. Open a new shell after changing this file.
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

    # Only yield PowerShell names to available executables, not aliases or functions.
    $coreutilsNames = 'cat', 'cp', 'ls', 'mv', 'rm', 'rmdir', 'sort'
    $applications = @{}
    $exeNames = @($coreutilsNames | ForEach-Object { "$_.exe" }) + @('bat.exe', 'rg.exe', 'fnm.exe')
    foreach ($application in (Get-Command -Name $exeNames -CommandType Application -ErrorAction Ignore)) {
        if (-not $applications.ContainsKey($application.Name)) {
            $applications[$application.Name] = $application.Path
        }
    }
    foreach ($name in $coreutilsNames) {
        $executable = $applications["$name.exe"]
        # The Windows sort.exe is not Coreutils and is normally already on PATH.
        if ($executable -and -not ($name -eq 'sort' -and $executable -like "$env:SystemRoot\*")) {
            Remove-Alias -Name $name -Scope Global -Force -ErrorAction Ignore
        }
    }
    if ($applications['bat.exe']) {
        Set-Alias -Name cat -Value $applications['bat.exe'] -Scope Global -Force
    }
    if ($applications['rg.exe']) {
        Set-Alias -Name grep -Value $applications['rg.exe'] -Scope Global
    }
    $fnmExe = $applications['fnm.exe']
    if ($fnmExe) {
        Set-Alias -Name nvm -Value $fnmExe -Scope Global
    }

    $lsExe = $applications['ls.exe']
    if ($lsExe) {
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
}

#region 6. Deferred initialisation ---------------------------------------------

# posh-git (~300 ms) and fnm (~80 ms) are the only expensive pieces here, and
# neither is needed until a prompt is actually drawn. Running them from the
# first prompt makes pwsh interactive immediately while still completing before
# a command can realistically be typed.
#
# A flag is used rather than rewriting $function:prompt, so any wrapper a host
# has already installed - VS Code's shell integration, for instance - survives.
# The flag is set before the work, so a failure cannot cause a retry every line.

$global:__ProfileInitialized = $false

function global:__Initialize-Profile {
    $global:__ProfileInitialized = $true

    # Git status in the prompt. Defines $GitPromptScriptBlock, which the prompt
    # below calls. Install with: Install-PSResource posh-git
    Import-Module posh-git -Global -MinimumVersion 1.1.0 -NoClobber -ErrorAction Ignore

    # Tab-completion results as prediction suggestions - this is what makes
    # PredictionSource 'HistoryAndPlugin' mean more than plain history, and it
    # is where ListView really pays off. Install with:
    #   Install-PSResource CompletionPredictor
    Import-Module CompletionPredictor -Global -ErrorAction Ignore

    # fnm: PATH and environment, plus a `cd` hook that activates the Node
    # version pinned by .node-version / .nvmrc in the directory you land in.
    # Note --use-on-cd rebinds `cd` (to Set-LocationWithFnm); Set-Location and
    # pushd are not hooked. Joining the lines instead of using fnm's documented
    # `| Out-String` avoids any chance of the formatter wrapping the long
    # `$env:PATH = ...` line at the console width.
    if (Get-Command fnm -CommandType Application -ErrorAction Ignore) {
        Invoke-Expression ((fnm env --use-on-cd --shell powershell) -join "`n")
    }
}

#endregion

#region 7. Prompt --------------------------------------------------------------

# The prompt proper. Falls back to PowerShell's default rendering if posh-git
# is not installed, so a missing module degrades visibly instead of erroring on
# every line.
function global:__Get-CorePrompt {
    if (-not $global:__ProfileInitialized) { __Initialize-Profile }

    if ($GitPromptScriptBlock) {
        & $GitPromptScriptBlock
    }
    else {
        "PS $($ExecutionContext.SessionState.Path.CurrentLocation)$('>' * ($NestedPromptLevel + 1)) "
    }
}

# Windows Terminal shell integration: OSC 133 semantic marks and OSC 9;9 for the
# working directory. This is what enables marks on the scrollbar, Ctrl+Up/Down
# between prompts, "select command output", recent-command suggestions, and new
# tabs opening in the current directory.
#
# Skipped inside VS Code, which injects its own OSC 633 integration after the
# profile runs and would end up double-marking. WT_SESSION alone is not enough:
# launching `code` from Windows Terminal leaks that variable into VS Code's
# integrated terminals.
#
# Terminal side, in settings.json:
#   "profiles": { "defaults": { "showMarksOnScrollbar": true, "autoMarkPrompts": true } }
if ($env:WT_SESSION -and $env:TERM_PROGRAM -ne 'vscode') {

    # PSReadLine uses PromptText to recolour the prompt on a parse error. It
    # looks for that text at the end of the rendered prompt, which is now an
    # escape sequence, so the feature cannot work; disabling it explicitly
    # avoids any partial re-render.
    Set-PSReadLineOption -PromptText ''

    $global:__LastHistoryId = -1

    # Distinguishes "the last native command exited non-zero" from "PowerShell
    # itself raised an error", so the Terminal can colour the mark accordingly.
    # $? must be read before anything else runs, hence the separate function.
    function global:__Get-LastExitCode {
        if ($?) { return 0 }

        $lastHistoryEntry = Get-History -Count 1
        if ($Error[0].InvocationInfo.HistoryId -eq $lastHistoryEntry.Id) { return -1 }

        return $LASTEXITCODE
    }

    function global:prompt {
        # Keep this first: any other statement would overwrite $?.
        $exitCode = __Get-LastExitCode
        $lastHistoryEntry = Get-History -Count 1
        $out = ''

        # OSC 133;D - end of the previous command, with its status. Skipped
        # before the first command, and emitted without a status when Enter was
        # pressed on an empty line or the line was cancelled with Ctrl+c.
        if ($global:__LastHistoryId -ne -1) {
            $out += if ($lastHistoryEntry.Id -eq $global:__LastHistoryId) {
                "`e]133;D`a"
            }
            else {
                "`e]133;D;$exitCode`a"
            }
        }

        # OSC 133;A - prompt start.
        $out += "`e]133;A`a"

        # OSC 9;9 - working directory, for "duplicate tab" and new panes. Only
        # meaningful for a real filesystem path, so Registry: / Cert: locations
        # are skipped rather than reported as nonsense.
        $location = $ExecutionContext.SessionState.Path.CurrentLocation
        if ($location.Provider.Name -eq 'FileSystem') {
            $out += "`e]9;9;`"$($location.ProviderPath)`"`a"
        }

        $out += __Get-CorePrompt

        # OSC 133;B - prompt end / command start.
        $out += "`e]133;B`a"

        $global:__LastHistoryId = $lastHistoryEntry.Id
        $out
    }
}
else {
    function global:prompt { __Get-CorePrompt }
}

#endregion
