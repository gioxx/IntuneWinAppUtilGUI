function Get-ExeVersion {
    <#
    .SYNOPSIS
    Returns file version (FileVersion preferred, then ProductVersion); $null if not available.
    .DESCRIPTION
    - Uses [System.Diagnostics.FileVersionInfo] to read version metadata.
    - Prefers FileVersion, falls back to ProductVersion.
    .PARAMETER Path
    Absolute path to the executable file.
    .OUTPUTS
    [string] or $null
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    try {
        if (-not (Test-Path $Path)) { return $null }
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ($vi.FileVersion -and $vi.FileVersion.Trim()) { return $vi.FileVersion.Trim() }
        if ($vi.ProductVersion -and $vi.ProductVersion.Trim()) { return $vi.ProductVersion.Trim() }
        return $null
    } catch {
        return $null
    }
}
