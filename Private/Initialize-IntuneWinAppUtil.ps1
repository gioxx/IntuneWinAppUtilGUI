function Initialize-IntuneWinAppUtil {
    <#
    .SYNOPSIS
    Returns a valid IntuneWinAppUtil.exe path or $null on failure.
    .DESCRIPTION
    - If a UI-provided path is valid, use it.
    - Else, use cached copy under %APPDATA%\IntuneWinAppUtilGUI\bin.
    - Else, download the latest via Invoke-DownloadIntuneTool (private helper).
    .PARAMETER UiToolPath
    Optional path provided by the UI (textbox).
    .OUTPUTS
    [string] or $null
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][string]$UiToolPath
    )

    try {
        $appRoot = Join-Path $env:APPDATA 'IntuneWinAppUtilGUI'
        $binDir = Join-Path $appRoot 'bin'
        $exePath = Join-Path $binDir 'IntuneWinAppUtil.exe'

        if (-not [string]::IsNullOrWhiteSpace($UiToolPath) -and (Test-Path $UiToolPath)) { return $UiToolPath }
        if (Test-Path $exePath) { return $exePath }

        # Fallback: download latest tool
        return (Invoke-DownloadIntuneTool)
    } catch {
        return $null
    }
}
