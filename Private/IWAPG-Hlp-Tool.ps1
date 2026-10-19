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

function Get-IntuneWinAppUtilExitMessage {
    <#
    .SYNOPSIS
    Builds a readable error message for a non-zero IntuneWinAppUtil.exe exit code.
    .DESCRIPTION
    IntuneWinAppUtil returns HRESULTs such as -2147024891 (0x80070005). For Win32 HRESULTs
    (0x8007xxxx) the Windows error text is added, plus a hint for access-denied and sharing
    violations, which are usually caused by sync clients or antivirus locking files.
    .PARAMETER ExitCode
    The process exit code.
    .OUTPUTS
    [string]
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode
    )

    $hex = '0x{0:X8}' -f $ExitCode
    $msg = "IntuneWinAppUtil exited with code $ExitCode ($hex)."

    if (($ExitCode -band 0xFFFF0000) -eq (0x80070000 -as [int])) {
        $win32Code = $ExitCode -band 0xFFFF
        $msg += "`n`n" + ([System.ComponentModel.Win32Exception]::new($win32Code)).Message
        # 5 = ERROR_ACCESS_DENIED, 32 = ERROR_SHARING_VIOLATION, 33 = ERROR_LOCK_VIOLATION
        if ($win32Code -in 5, 32, 33) {
            $msg += "`n`nA file in the source folder may be locked or not readable. Close programs that use it, and pause sync clients (Dropbox, OneDrive) or antivirus scans on the source folder, then try again."
        }
    }

    $msg
}

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
