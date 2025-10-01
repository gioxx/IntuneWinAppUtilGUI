function Get-RelativePath {
    <#
    .SYNOPSIS
    Returns a relative Windows path from BasePath to TargetPath when possible; 
    otherwise returns the absolute, normalized TargetPath.
    .DESCRIPTION
    - Normalizes base and target paths via [System.IO.Path]::GetFullPath.
    - If paths are on different roots (drive letters or UNC shares), falls back to absolute.
    - Uses Uri.MakeRelativeUri to compute the relative portion.
    - Decodes URL-encoded characters and converts forward slashes to backslashes.
    .PARAMETER BasePath
    The base directory you want to compute the relative path from.
    .PARAMETER TargetPath
    The file or directory path you want to compute the relative path to.
    .OUTPUTS
    [string] Relative path if computable, otherwise absolute normalized TargetPath.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$BasePath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TargetPath
    )

    try {
        # Normalize and ensure BasePath ends with a directory separator so Uri treats it as a folder
        $baseFull = [System.IO.Path]::GetFullPath(($BasePath.TrimEnd('\') + '\'))
        $targetFull = [System.IO.Path]::GetFullPath($TargetPath)

        # If roots differ (e.g., C:\ vs D:\ or different UNC shares), relative path is not possible
        $baseRoot = [System.IO.Path]::GetPathRoot($baseFull)
        $targetRoot = [System.IO.Path]::GetPathRoot($targetFull)
        if (-not [string]::Equals($baseRoot, $targetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $targetFull
        }

        # Compute the relative URI and convert it to a Windows path
        $uriBase = [Uri]$baseFull
        $uriTarget = [Uri]$targetFull

        $rel = $uriBase.MakeRelativeUri($uriTarget).ToString()
        # Decode URL-encoded chars (e.g., spaces) and switch to backslashes
        $relWin = [Uri]::UnescapeDataString($rel).Replace('/', '\')

        return $relWin
    } catch {
        # On any unexpected error, just return the original target (best-effort behavior)
        return $TargetPath
    }
}