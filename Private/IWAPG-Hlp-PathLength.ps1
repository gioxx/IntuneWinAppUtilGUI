function Get-MaxFilePathInfo {
    <#
    .SYNOPSIS
    Returns the longest full file path length under a root directory.
    .DESCRIPTION
    Enumerates files recursively and returns the maximum FullName length and the path.
    If no files are found, returns the root path and its length.
    .PARAMETER RootPath
    The root directory to scan.
    .OUTPUTS
    PSCustomObject with Length and Path.
    #>

    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RootPath)

    try {
        $maxLen = 0
        $maxPath = $null
        $foundAny = $false

        foreach ($item in Get-ChildItem -Path $RootPath -Recurse -Force -File -ErrorAction SilentlyContinue) {
            $len = $item.FullName.Length
            if ($len -gt $maxLen) {
                $maxLen = $len
                $maxPath = $item.FullName
            }
            $foundAny = $true
        }

        if (-not $foundAny) {
            $maxLen = $RootPath.Length
            $maxPath = $RootPath
        }

        return [PSCustomObject]@{
            Length = $maxLen
            Path   = $maxPath
        }
    } catch {
        return $null
    }
}

function Update-PathLengthIndicator {
    <#
    .SYNOPSIS
    Updates a TextBlock with path length info and warning color.
    .PARAMETER PathText
    The path text to measure.
    .PARAMETER Indicator
    The TextBlock to update.
    .PARAMETER Limit
    The max length threshold.
    #>

    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyString()][string] $PathText,
        [Parameter(Mandatory)][System.Windows.Controls.TextBlock] $Indicator,
        [Parameter(Mandatory)][int] $Limit
    )

    if (-not $Indicator) { return }
    $len = if ($PathText) { $PathText.Length } else { 0 }
    if ($len -gt 0) {
        $Indicator.Visibility = [System.Windows.Visibility]::Visible
        $Indicator.Text = "Path length: $len/$Limit"
        $Indicator.Foreground = if ($len -gt $Limit) {
            [System.Windows.Media.Brushes]::Red
        } else {
            [System.Windows.Media.Brushes]::Gray
        }
    } else {
        $Indicator.Visibility = [System.Windows.Visibility]::Collapsed
    }
}
