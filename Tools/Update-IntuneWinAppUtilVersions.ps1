<#
.SYNOPSIS
    Downloads all releases of Microsoft-Win32-Content-Prep-Tool, extracts IntuneWinAppUtil.exe and reads its FileVersion.
.DESCRIPTION
    This PowerShell script queries all available tags in the Microsoft-Win32-Content-Prep-Tool GitHub repository.
    For each release, it downloads the public ZIP archive, extracts its contents, locates the IntuneWinAppUtil.exe executable,
    and reads its FileVersion property. The script outputs a Markdown table with the results directly to the console
    and saves the table to a Markdown file.
.PARAMETER RepositoryOwner
    The GitHub repository owner name. Default is "microsoft".
.PARAMETER RepositoryName
    The GitHub repository name. Default is "Microsoft-Win32-Content-Prep-Tool".
.PARAMETER MaxReleases
    The maximum number of releases to process. Default is 100.
.PARAMETER OutputDirectory
    The temporary directory where ZIP files will be downloaded and extracted. Default is the system TEMP folder.
.EXAMPLE
    .\Update-IntuneWinAppUtilVersions.ps1
.EXAMPLE
    .\Update-IntuneWinAppUtilVersions.ps1 -MaxReleases 10
.NOTES
    Requires PowerShell 5.1 or later.
    Needs internet access to download ZIP files.
    Suitable for integration in CI pipelines such as GitHub Actions.

    Author: Giovanni Solone
    Date: 2025-09-04
    License: MIT

    Modifications history:
    - 2024-09-04: Initial version.
#>

param(
    [string] $RepositoryOwner = "microsoft",
    [string] $RepositoryName = "Microsoft-Win32-Content-Prep-Tool",
    [int] $MaxReleases = 100,
    [string] $OutputDirectory = "$env:TEMP\Win32ContentPrepTmp"
)

if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
}

$markdownFile = Join-Path $OutputDirectory "IntuneWinAppUtilVersions.md"
$apiUrl = "https://api.github.com/repos/$RepositoryOwner/$RepositoryName/tags?per_page=$MaxReleases"
$headers = @{
    "User-Agent" = "PowerShell"
    "Accept"     = "application/vnd.github.v3+json"
}

try {
    $tags = Invoke-RestMethod -Uri $apiUrl -Headers $headers
} catch {
    Write-Error "Error fetching tags from GitHub: $_"
    exit 1
}

$results = @()
$total = $tags.Count
$current = 0

# Initialize index to track first release as 'latest'
$index = 0

foreach ($tag in $tags) {
    $current++
    $index++
    $version = $tag.name
    $zipUrl = "https://github.com/$RepositoryOwner/$RepositoryName/archive/refs/tags/$version.zip"
    $zipFile = Join-Path $OutputDirectory "$version.zip"
    $extractPath = Join-Path $OutputDirectory $version
    
    Write-Progress -Activity "Downloading ZIP ($version)" -Status "Release $current of $total" -PercentComplete (($current / $total) * 100)
    
    if (-not (Test-Path $extractPath)) {
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -ErrorAction Stop
            Expand-Archive -Path $zipFile -DestinationPath $extractPath -Force
        } catch {
            Write-Warning "Failed to download or extract $($version): $_"
            continue
        }
    }
    
    # Search for IntuneWinAppUtil.exe inside extracted files, read FileVersion property or mark as "Not found"
    $exePath = Get-ChildItem -Path $extractPath -Recurse -Filter "IntuneWinAppUtil.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    $fileVersion = if ($exePath) { (Get-Item $exePath.FullName).VersionInfo.FileVersion } else { "Not found" }
    
    # Append "(latest)" tag to the first release's version and file version
    if ($index -eq 1) {
        $version += " (latest)"
        $fileVersion += " (latest)"
    }
    
    $results += [PSCustomObject]@{
        ReleaseVersion = $version
        FileVersion    = $fileVersion
    }
}

Write-Progress -Activity "Complete" -Completed

# Clean up downloaded ZIP files and extracted folders
try {
    Write-Host "Cleaning up downloaded files and extracted folders ..."
    Get-ChildItem -Path $OutputDirectory -Filter *.zip -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $OutputDirectory -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    Write-Warning "Cleanup failed: $_"
}

$table = "| Release Version | FileVersion |`n"
$table += "|-----------------|-------------|`n"
foreach ($row in $results) {
    $table += "| $($row.ReleaseVersion) | $($row.FileVersion) |`n"
}

Write-Host "`n$table"
$table | Out-File -FilePath $markdownFile -Encoding UTF8
