# Import necessary modules
Import-Module posh-git

# Set key handlers for PSReadLine
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadlineKeyHandler -Key Tab -Function MenuComplete

# Set aliases
Set-Alias -Name cat -Value bat
New-Alias -Name nvm -Value nvs
New-Alias -Name grep -Value rg
