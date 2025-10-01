function Show-ToolVersion {
    <#
    .SYNOPSIS
    Updates the provided TextBlock with IntuneWinAppUtil version text.
    .PARAMETER Path
    Full path to IntuneWinAppUtil.exe (can be $null/empty).
    .PARAMETER Target
    WPF TextBlock (or any object with a 'Text' property) to update.
    #>
    
    param(
        [string]$Path,
        [Parameter(Mandatory)][object]$Target
    )

    $ver = if ($Path) { Get-ExeVersion -Path $Path } else { $null }
    $Target.Text = if ($ver) {
        "IntuneWinAppUtil version: $ver"
    } else {
        "IntuneWinAppUtil version: (not detected)"
    }
}