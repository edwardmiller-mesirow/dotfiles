#Requires -Version 7.4
<#
    PowerShell profile - pwsh 7.6.x on Windows 11 / Windows Terminal.

    Install at $PROFILE.CurrentUserCurrentHost, i.e.
        $HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1

    Layout
        1. Interactive-only guard
        2. Console encoding
        3. PSReadLine options
        4. Key bindings
        5. Aliases
        6. Deferred initialisation (posh-git, fnm, predictors)
        7. Prompt + Windows Terminal shell integration

    Measuring startup:
        Measure-Command { pwsh -NoLogo -Command '' }              # with profile
        Measure-Command { pwsh -NoLogo -NoProfile -Command '' }   # baseline
#>

#region 1. Interactive-only guard ---------------------------------------------

# PowerShell loads PSReadLine during engine initialisation - before profiles
# run - and only for interactive sessions. Its absence is a cheap, reliable
# signal that this is `pwsh -Command`, `pwsh -File`, a VS Code task or CI.
# None of those want the prompt, the aliases or the key bindings below, and all
# of them start faster and behave more predictably without them.
if (-not (Get-Module -Name PSReadLine)) { return }

#endregion

#region 2. Console encoding ----------------------------------------------------

# PowerShell 7 already sends UTF-8 to native commands ($OutputEncoding), but it
# still *reads* their output using the console code page, which on a default
# Windows install is 437 or 1252. Fixing that is what makes bat, rg, git, delta
# and friends render box-drawing characters and accented text correctly.
# InputEncoding is deliberately left alone: its setter throws when stdin is
# redirected, and PSReadLine reads keys through the console API regardless.
if ([Console]::OutputEncoding.CodePage -ne 65001) {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
}

#endregion

#region 3. PSReadLine options --------------------------------------------------

# Splatted rather than one call per option: a single cmdlet invocation, and the
# whole configuration is readable in one place.
$psReadLineOptions = @{
    EditMode = 'Windows'

    # No terminal beep on a failed completion or a backspace at column zero.
    BellStyle = 'None'

    # Default, restated: history is the only prediction source until a plugin
    # registers itself (see the deferred CompletionPredictor import below).
    PredictionSource = 'HistoryAndPlugin'

    # InlineView is the low-friction default - grey ghost text after the cursor.
    # F2 switches to ListView (scrollable, grouped by source, up to 50 results)
    # at any time; set it here instead if you prefer that permanently.
    PredictionViewStyle = 'InlineView'

    # Deeper history means better predictions. PSReadLine 2.4 reads the history
    # file as a stream, so this is cheap; the read also happens on the first
    # ReadLine call rather than during profile execution.
    MaximumHistoryCount = 10000
    HistoryNoDuplicates = $true

    # Essential companion to HistorySearchBackward/Forward below: without it the
    # cursor is left mid-command after recalling a line.
    HistorySearchCursorMovesToEnd = $true

    ShowToolTips = $true
}
Set-PSReadLineOption @psReadLineOptions

#endregion

#region 4. Key bindings --------------------------------------------------------

# Up/Down filter history down to commands that start with what is already typed,
# and fall back to plain history navigation when the line is empty. When the
# ListView prediction popup is open they navigate the list instead.
Set-PSReadLineKeyHandler -Chord 'UpArrow'   -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Chord 'DownArrow' -Function HistorySearchForward

# Tab opens the interactive completion menu instead of cycling one result at a
# time. Left at their defaults: Shift+Tab walks the menu backwards, Ctrl+Space
# also opens it, F2 toggles the prediction view, Alt+a selects command
# arguments, Ctrl+r reverse-searches history.
Set-PSReadLineKeyHandler -Chord 'Tab' -Function MenuComplete

# RightArrow accepts an entire inline suggestion at end of line. Ctrl+f takes it
# one word at a time, which is the piece most people never discover - useful
# when the prediction is nearly right.
Set-PSReadLineKeyHandler -Chord 'Ctrl+f' -Function ForwardWord

# End goes to the end of the typed text; pressing it there accepts the whole
# inline suggestion, matching RightArrow and zsh-autosuggestions. PSReadLine has
# no built-in function that combines the two (PSReadLine issue #4929), so this
# stays a script block. BriefDescription/Description make it show up properly in
# Get-PSReadLineKeyHandler.
$endOfLineOrAcceptSuggestion = @{
    Chord            = 'End'
    BriefDescription = 'EndOfLineOrAcceptSuggestion'
    Description      = 'Move to the end of the line, or accept the inline suggestion if already there'
    ScriptBlock      = {
        param($key, $arg)

        $line = $null
        $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

        if ($cursor -lt $line.Length) {
            [Microsoft.PowerShell.PSConsoleReadLine]::EndOfLine($key, $arg)
        }
        else {
            # ForwardChar at end of buffer is AcceptSuggestion, and a plain
            # cursor move otherwise - so this stays correct with predictions off.
            [Microsoft.PowerShell.PSConsoleReadLine]::ForwardChar($key, $arg)
        }
    }
}
Set-PSReadLineKeyHandler @endOfLineOrAcceptSuggestion

#endregion

#region 5. Aliases -------------------------------------------------------------

# Coreutils for Windows (winget install Microsoft.Coreutils) ships cat, cp, ls,
# mv, rm, rmdir, sleep, sort, tee and others that PowerShell shadows with an
# alias to a cmdlet. Clearing those aliases is what lets the real binaries win.
#
# Two things about how that package integrates with PowerShell:
#   * Its installer hooks PSConsoleHostReadLine and rewrites interactive input
#     before PowerShell resolves the command name. At the prompt that can beat
#     an alias defined here, and Get-Command will not reveal it - the README is
#     explicit that Get-Command/Get-Help still report PowerShell's own names.
#     `coreutils-manager disable <name>` (elevated) hands a name back.
#   * That hook loads only in the console host, so scripts and the VS Code
#     terminal still see PowerShell's aliases. Clearing them here is what keeps
#     the two environments behaving the same way.
#
# -Force is needed because the built-ins are ReadOnly; -ErrorAction Ignore keeps
# $Error empty, which matters because the prompt below inspects $Error[0].
# `find` is deliberately absent: it was never a PowerShell alias, so Coreutils'
# find already wins as long as its directory precedes System32 on PATH.
Remove-Alias -Name cat, cp, ls, mv, rm, rmdir, sort -Force -ErrorAction Ignore

# Set-Alias rather than New-Alias: idempotent, so re-sourcing this profile or
# running it in a session that already has these aliases does not error.
# Coreutils ships both `cat` and `grep`, so see the note above if these two
# appear to have no effect at the prompt.
Set-Alias -Name cat  -Value bat
Set-Alias -Name grep -Value rg

# fnm reads .node-version and .nvmrc, so nvm muscle memory mostly carries over.
Set-Alias -Name nvm  -Value fnm

# Coreutils' ls follows GNU and prints no colour unless asked, so wrap it. This
# only works because the `ls` alias was cleared above: an alias beats a
# function, but a function beats an executable. `dir` and `gci` are untouched,
# so object-based listing is still one keystroke away.
#
# Check anything you add here against `ls --help` first - an unrecognised option
# makes ls fail outright rather than being ignored. Two GNU options worth
# testing for, since uutils may or may not have them yet:
#   --time-style=long-iso   sortable 2026-09-02 14:33 timestamps under -l
#   --hyperlink=auto        clickable file names in Windows Terminal
$LsDefaultArgs = @(
    '--color=auto'                  # colour only when stdout is a terminal
    '--group-directories-first'     # directories above files
    '--human-readable'              # 4.2K rather than 4300, under -l
)

# ls.exe rather than ls: the explicit extension forces application resolution,
# so the function cannot recurse into itself. If you ever run
# `coreutils-manager disable ls`, switch these to `coreutils ls` - the multi-call
# binary still dispatches by name once its own entry point is gone.
function global:ls { ls.exe @LsDefaultArgs @args }
function global:ll { ls.exe @LsDefaultArgs -l -a @args }

# Palette. LS_COLORS replaces ls's built-in defaults wholesale rather than
# merging into them, so anything absent here renders uncoloured. `dircolors` is
# one of the utilities deliberately not shipped on Windows, so setting this by
# hand is the only route. Purely taste - delete it for the stock colours.
$env:LS_COLORS = @(
    'di=1;38;5;75'      # directories
    'ln=1;38;5;80'      # symlinks
    'or=1;38;5;203'     # broken symlinks
    'ex=1;38;5;114'     # executables
    '*.ps1=38;5;114', '*.psm1=38;5;114', '*.psd1=38;5;114'
    '*.zip=38;5;180', '*.7z=38;5;180', '*.gz=38;5;180', '*.tar=38;5;180'
    '*.md=38;5;186', '*.txt=38;5;186'
    '*.json=38;5;186', '*.yml=38;5;186', '*.yaml=38;5;186', '*.toml=38;5;186'
    '*.png=38;5;177', '*.jpg=38;5;177', '*.svg=38;5;177', '*.webp=38;5;177'
) -join ':'

#endregion

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
