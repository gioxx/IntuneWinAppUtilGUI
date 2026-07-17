function Get-IntuneFileVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $item = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop

    if ($item.PSIsContainer) {
        throw "Path '$Path' is not a file."
    }

    [System.Diagnostics.FileVersionInfo]::GetVersionInfo($resolvedPath).FileVersion
}
