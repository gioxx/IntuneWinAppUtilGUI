function Get-MaxFilePathInfo {
    <#
    .SYNOPSIS
    Returns the longest full file path length under a root directory.
    .DESCRIPTION
    Enumerates files recursively and returns the maximum FullName length and the path, plus the total
    size of the files (so callers need a single pass over large or slow source folders).
    If no files are found, returns the root path and its length.
    .PARAMETER RootPath
    The root directory to scan.
    .PARAMETER OnProgress
    Optional scriptblock invoked every 200 files (e.g. to let the UI repaint during a long scan).
    .OUTPUTS
    PSCustomObject with Length, Path and TotalBytes.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RootPath,
        [scriptblock] $OnProgress
    )

    try {
        $maxLen = 0
        $maxPath = $null
        $foundAny = $false
        $totalBytes = [long]0
        $count = 0

        foreach ($item in Get-ChildItem -Path $RootPath -Recurse -Force -File -ErrorAction SilentlyContinue) {
            $len = $item.FullName.Length
            if ($len -gt $maxLen) {
                $maxLen = $len
                $maxPath = $item.FullName
            }
            $totalBytes += $item.Length
            $foundAny = $true
            if ($OnProgress -and (++$count % 200) -eq 0) { & $OnProgress }
        }

        if (-not $foundAny) {
            $maxLen = $RootPath.Length
            $maxPath = $RootPath
        }

        return [PSCustomObject]@{
            Length     = $maxLen
            Path       = $maxPath
            TotalBytes = $totalBytes
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

function Remove-IwaPathQuote {
    <#
    .SYNOPSIS
    Strips the double quotes around a pasted path.
    .DESCRIPTION
    Explorer's "Copy as path" wraps paths in double quotes, which the folder scan and Test-Path cannot use.
    Returns the text unchanged unless, once trimmed, it starts and ends with a double quote.
    .PARAMETER Text
    The field text.
    #>

    [CmdletBinding()]
    param([Parameter()][AllowEmptyString()][AllowNull()][string] $Text)

    $trimmed = "$Text".Trim()
    if ($trimmed.Length -ge 2 -and $trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) {
        return $trimmed.Substring(1, $trimmed.Length - 2).Trim()
    }
    $Text
}

function Register-IwaPathQuoteStrip {
    <#
    .SYNOPSIS
    Makes a path field drop the double quotes around a pasted path as soon as it is pasted.
    .PARAMETER Control
    The TextBox, or editable ComboBox, holding the path.
    #>

    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Windows.Controls.Control] $Control)

    # TextChanged bubbles up from an editable ComboBox's inner text box, so one handler covers both.
    $Control.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [System.Windows.Controls.TextChangedEventHandler]{
        param($evtSender, $e)
        $clean = Remove-IwaPathQuote $evtSender.Text
        if ($clean -cne $evtSender.Text) {
            $evtSender.Text = $clean
            if ($evtSender -is [System.Windows.Controls.TextBox]) { $evtSender.CaretIndex = $clean.Length }
        }
    })
}
