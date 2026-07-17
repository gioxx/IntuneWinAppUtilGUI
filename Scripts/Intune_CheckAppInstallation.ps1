<# 
.SYNOPSIS
    Intune detection script for a specific application path/executable.
.DESCRIPTION
    Checks for a specific application installed under Program Files (both 64-bit and 32-bit paths).
    You must provide a search path (e.g., "Google\Chrome\Application\chrome.exe").
    Returns exit code 0 if installed (and meets minimum version if specified), 1 otherwise.
    Writes a concise message to stdout so Intune logs are readable.
.EXAMPLE
    .\Intune_CheckAppInstallation.ps1
.NOTES
    Run in 64-bit PowerShell host if possible, but the script checks both paths anyway.

    You must change the search path to match your application (row 30).
    You must change the minimum version to match your application (row 138).

    Examples to use Get-AppStatus with / without minimum version requirement:
      - With minimum version:  $status = Get-AppStatus -MinimumVersion "1.2.3.4"
      - Without minimum:       $status = Get-AppStatus

    Author: Giovanni Solone
    Date: 2025-11-11

    Modification History:
    - 2025-11-11: Added optional MinimumVersion; generalized for any application; added robust version parsing.
    - 2025-10-27: Initial version.
#>

# CONFIGURATION: set the relative path of the target executable here
$searchPath = "Google\Chrome\Application\chrome.exe"

# Build candidate paths (64-bit and 32-bit Program Files)
$candidatePaths = @()
if ($env:ProgramFiles) {
    $candidatePaths += (Join-Path -Path $env:ProgramFiles -ChildPath $searchPath)
}
if (${env:ProgramFiles(x86)}) {
    $candidatePaths += (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath $searchPath)
}

# Helper: normalize a version-like string into a [System.Version] (returns $null if impossible)
function Convert-ToVersion {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][string]$InputVersion
    )
    
    if ([string]::IsNullOrWhiteSpace($InputVersion)) { return $null } # If empty, nothing to convert

    try {
        # Keep only digits and dots, remove everything else (e.g., "R25.1.164.0.0" -> "25.1.164.0.0")
        $clean = ($InputVersion -replace '[^\d\.]', '')

        # Collapse multiple dots and trim leading/trailing dots
        $clean = $clean -replace '\.{2,}', '.'
        $clean = $clean.Trim('.')

        if ([string]::IsNullOrWhiteSpace($clean)) { return $null }

        # Split into parts, keep max 4 components (System.Version supports up to 4)
        $parts = $clean -split '\.'
        if ($parts.Count -gt 4) {
            $parts = $parts[0..3]
        }

        # Ensure each part is numeric; if not, default to 0
        $parts = $parts | ForEach-Object { if ($_ -match '^\d+$') { $_ } else { '0' } }

        # Rejoin and cast
        $normalized = ($parts -join '.')
        return [version]$normalized
    } catch {
        return $null
    }
}

function Get-AppStatus {
    param(
        [string]$MinimumVersion  # Optional minimum version requirement (e.g. "23.0.1.0" or "R25.1.164.0.0")
    )

    $foundPaths = @()
    $installed = $false
    $meetsVersion = $false
    $versionStr = $null
    $verObj = $null

    foreach ($path in $candidatePaths) {
        if (Test-Path -LiteralPath $path) {
            $foundPaths += $path
        }
    }

    if ($foundPaths.Count -gt 0) {
        try {
            $file = Get-Item -LiteralPath $foundPaths[0]
            $versionStr = $file.VersionInfo.FileVersion
            
            if ([string]::IsNullOrWhiteSpace($versionStr)) {
                $versionStr = $file.VersionInfo.ProductVersion # Try ProductVersion if FileVersion is empty
            }

            $verObj = Convert-ToVersion -InputVersion $versionStr # Parse detected version

            if ($MinimumVersion) {
                $minObj = Convert-ToVersion -InputVersion $MinimumVersion
                # If we cannot parse either side, consider the requirement not met
                if ($verObj -and $minObj) {
                    $meetsVersion = ($verObj -ge $minObj)
                } else {
                    $meetsVersion = $false
                }
            } else {
                $meetsVersion = $true # No minimum specified → automatically valid
            }

            $installed = $true
        } catch {
            # If reading file/version fails, keep defaults (installed may still be true if path exists)
            $installed = $true
            if ($MinimumVersion) {
                $meetsVersion = $false
            } else {
                $meetsVersion = $true
            }
        }
    }

    return @{
        Installed    = $installed
        Version      = $versionStr
        VersionObj   = $verObj
        MeetsVersion = $meetsVersion
        Paths        = $foundPaths
    }
}

# CONFIGURATION: Set the desired minimum (or comment it out to ignore)
$status = Get-AppStatus # e.g., "25.1.164.0" or "R25.1.164.0.0"; or remove param to ignore

if ($status.Installed -and $status.MeetsVersion) {
    $ver = if ($status.Version) { $status.Version } else { "<unknown>" }
    $paths = if ($status.Paths) { ($status.Paths -join '; ') } else { "<n/a>" }
    Write-Output "App detected. Version: $ver. Paths: $paths"
    exit 0
} elseif ($status.Installed -and -not $status.MeetsVersion) {
    $ver = if ($status.Version) { $status.Version } else { "<unknown>" }
    Write-Output "App detected but version below minimum requirement. Detected: $ver"
    exit 1
} else {
    Write-Output "App NOT detected."
    exit 1
}
