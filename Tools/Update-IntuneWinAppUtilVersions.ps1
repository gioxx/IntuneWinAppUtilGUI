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
    - 2026-11-11: Also writes IntuneWinAppUtilVersions.json; sorts releases by version; cleans up only its own files.
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
$jsonFile = Join-Path $OutputDirectory "IntuneWinAppUtilVersions.json"
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

foreach ($tag in $tags) {
    $current++
    $version = $tag.name
    $zipUrl = "https://github.com/$RepositoryOwner/$RepositoryName/archive/refs/tags/$version.zip"
    $zipFile = Join-Path $OutputDirectory "$version.zip"
    $extractPath = Join-Path $OutputDirectory $version

    Write-Progress -Activity "Downloading ZIP ($version)" -Status "Release $current of $total" -PercentComplete (($current / $total) * 100)

    try {
        if (-not (Test-Path $extractPath)) {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -ErrorAction Stop
            Expand-Archive -Path $zipFile -DestinationPath $extractPath -Force
        }

        # Search for IntuneWinAppUtil.exe inside extracted files, read FileVersion property or mark as "Not found"
        $exePath = Get-ChildItem -Path $extractPath -Recurse -Filter "IntuneWinAppUtil.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        $fileVersion = if ($exePath) { (Get-Item $exePath.FullName).VersionInfo.FileVersion } else { "Not found" }

        $results += [PSCustomObject]@{
            Release     = $version
            FileVersion = $fileVersion
        }
    } catch {
        Write-Warning "Failed to download or extract $($version): $_"
    } finally {
        # Remove only what this script created: -OutputDirectory may be a folder with other content.
        foreach ($p in @($zipFile, $extractPath)) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Write-Progress -Activity "Complete" -Completed

# Newest first, by tag number (tags are not always prefixed with "v", so API order is not reliable).
$tagVersion = {
    param([string]$Name)
    $v = $null
    if ([version]::TryParse(($Name -replace '^v', ''), [ref]$v)) { $v } else { [version]'0.0' }
}
$results = @($results | Sort-Object -Descending -Property @{ Expression = { & $tagVersion $_.Release } })

# The newest tag must be in the list: if only it failed, an older release would be written as "latest",
# and the workflow (which then records the newest tag as processed) would not regenerate the list again.
$newestTag = ($tags | Sort-Object -Descending -Property @{ Expression = { & $tagVersion $_.name } } | Select-Object -First 1).name
if ($newestTag -and -not @($results | Where-Object { $_.Release -eq $newestTag -and $_.FileVersion -ne 'Not found' }).Count) {
    Write-Error "The newest release ($newestTag) could not be processed: the version list was not updated."
    exit 1
}

$table = "| Release Version | FileVersion |`n"
$table += "|-----------------|-------------|`n"
$first = $true
foreach ($row in $results) {
    $suffix = if ($first) { ' (latest)' } else { '' }
    $table += "| $($row.Release)$suffix | $($row.FileVersion)$suffix |`n"
    $first = $false
}

Write-Host "`n$table"
$table | Out-File -FilePath $markdownFile -Encoding UTF8

# Machine-readable copy, read by the GUI (update check) and by the KB version history page.
$json = [ordered]@{
    updated  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    source   = "https://github.com/$RepositoryOwner/$RepositoryName"
    latest   = if ($results.Count) { [ordered]@{ release = $results[0].Release; fileVersion = $results[0].FileVersion } } else { $null }
    releases = @($results | ForEach-Object { [ordered]@{ release = $_.Release; fileVersion = $_.FileVersion } })
}
# UTF-8 without BOM on both PowerShell 5.1 and 7.
[System.IO.File]::WriteAllText($jsonFile, ($json | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding $false))
