# Import necessary modules
Import-Module posh-git

# Set key handlers for PSReadLine
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadlineKeyHandler -Key Tab -Function MenuComplete

# Initialize the dotnet cache if it doesn't exist
if ($null -eq $global:dotnetCompletionCache) {
    $global:dotnetCompletionCache = @{}
}

# PowerShell parameter completion shim for the dotnet CLI
Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
    param($commandName, $wordToComplete, $cursorPosition)

    $cacheKey = "$wordToComplete`:$cursorPosition"
    if ($global:dotnetCompletionCache.ContainsKey($cacheKey)) {
        $global:dotnetCompletionCache[$cacheKey] | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
    } else {
        try {
            $runspace = [powershell]::Create().AddScript({
                param($wordToComplete, $cursorPosition, $cacheKey)
                $results = dotnet complete --position $cursorPosition "$wordToComplete"
                $results | ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
                }
                $global:dotnetCompletionCache[$cacheKey] = $results
                return $results
            }).AddArgument($wordToComplete).AddArgument($cursorPosition).AddArgument($cacheKey)
            $runspace.Invoke()
            $runspace.Dispose()
        } catch {
            Write-Error "Failed to complete dotnet command: $_"
        }
    }
}

# Initialize the winget cache if it doesn't exist
if ($null -eq $global:wingetCache) {
    $global:wingetCache = @{}
}

# Windows Package Manager parameter completion shim for the winget CLI
Register-ArgumentCompleter -Native -CommandName winget -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    
    # Simplified cache key based on input parameters
    $cacheKey = "$wordToComplete|$cursorPosition"
    
    # Return cached results if available
    if ($global:wingetCache.ContainsKey($cacheKey)) {
        return $global:wingetCache[$cacheKey]
    }
    
    try {
        $runspace = [powershell]::Create().AddScript({
            param($wordToComplete, $commandAst, $cursorPosition, $cacheKey)
            $results = winget complete --word="$wordToComplete" --commandline "$commandAst" --position $cursorPosition | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
            }
            $global:wingetCache[$cacheKey] = $results
            return $results
        }).AddArgument($wordToComplete).AddArgument($commandAst).AddArgument($cursorPosition).AddArgument($cacheKey)
        
        $results = $runspace.Invoke()
        $runspace.Dispose()
        
        return $results
    } catch {
        Write-Error "Failed to complete winget command: $_"
    }
}

# Set aliases
Set-Alias -Name cat -Value bat
New-Alias -Name nvm -Value nvs
New-Alias -Name grep -Value rg