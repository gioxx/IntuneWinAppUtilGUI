function Invoke-DownloadIntuneTool {
    <#
    .SYNOPSIS
    Downloads the latest IntuneWinAppUtil.exe from GitHub and caches it under
    %APPDATA%\IntuneWinAppUtilGUI\bin.
    .DESCRIPTION
    - Forces TLS 1.2 for GitHub downloads.
    - Creates (or ensures) the bin directory under $env:APPDATA\IntuneWinAppUtilGUI\bin.
    - Removes any stale IntuneWinAppUtil.exe in the bin directory.
    - Downloads the repository master ZIP, extracts it to a unique temp folder,
      locates IntuneWinAppUtil.exe, and copies it into the bin directory.
    - Cleans up all temp files/folders in a finally block.
    - Returns the full path to the cached IntuneWinAppUtil.exe.
    - Throws on failure (caller can catch and show a message box).
    .PARAMETER DestinationRoot
    Optional base path for the cache (default: $env:APPDATA\IntuneWinAppUtilGUI).
    .PARAMETER RepoZipUrl
    Optional ZIP URL (default: master branch of Microsoft-Win32-Content-Prep-Tool).
    .OUTPUTS
    [string] Full path to IntuneWinAppUtil.exe.
    .EXAMPLE
    $exe = Invoke-DownloadIntuneTool
    # $exe now points to %APPDATA%\IntuneWinAppUtilGUI\bin\IntuneWinAppUtil.exe
    #>

    [CmdletBinding()]
    param(
        [string]$DestinationRoot = (Join-Path $env:APPDATA 'IntuneWinAppUtilGUI'),
        [string]$RepoZipUrl = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/heads/master.zip'
    )

    # Ensure TLS 1.2 for GitHub
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $binDir   = Join-Path $DestinationRoot 'bin'
    $exePath  = Join-Path $binDir 'IntuneWinAppUtil.exe'
    $tempZip  = Join-Path $env:TEMP ("IntuneWinAppUtil-{0}.zip" -f ([guid]::NewGuid()))
    $tempDir  = Join-Path $env:TEMP ("IntuneExtract-{0}" -f ([guid]::NewGuid()))

    try {
        # Prepare target folder and clean stale exe
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        if (Test-Path $exePath) { Remove-Item $exePath -Force -ErrorAction SilentlyContinue }

        # Download
        Invoke-WebRequest -Uri $RepoZipUrl -OutFile $tempZip -UseBasicParsing -ErrorAction Stop

        # Extract (fallback if overwrite overload isn't available)
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $zipType = [System.IO.Compression.ZipFile]
        $hasOverwrite = $zipType.GetMethod(
            'ExtractToDirectory',
            [Reflection.BindingFlags]'Public, Static',
            $null,
            @([string], [string], [bool]),
            $null
        )
        if ($hasOverwrite) {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($tempZip, $tempDir, $true)
        } else {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($tempZip, $tempDir)
        }

        # Locate exe
        $found = Get-ChildItem -Path $tempDir -Recurse -Filter 'IntuneWinAppUtil.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) {
            throw "IntuneWinAppUtil.exe not found in the extracted archive."
        }

        # Copy into cache
        Copy-Item -Path $found.FullName -Destination $exePath -Force
        return $exePath
    } catch {
        throw $_
    } finally {
        # Best-effort cleanup
        foreach ($p in @($tempZip, $tempDir)) {
            try {
                if (Test-Path $p) {
                    if (Test-Path $p -PathType Container) {
                        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
                    } else {
                        Remove-Item $p -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch {}
        }
    }
}
