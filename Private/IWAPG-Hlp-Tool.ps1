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

function Publish-IntuneWinPackage {
    <#
    .SYNOPSIS
    Moves a finished .intunewin package to its final path, retrying while the file is locked.
    .DESCRIPTION
    With -CopyFirst (package built in a staging folder, possibly on another volume), the file is
    copied next to the destination as '~iwa-<guid>.partial' and then renamed, so sync clients never see
    a half-written file under the final name; the source is deleted only after the rename succeeds.
    Without -CopyFirst the file is simply moved (same-folder rename).
    If the destination name is taken (also by another GUI instance publishing at the same time),
    the first free '<name>_1', '<name>_2', ... is used; each attempt picks a free name again.
    Throws when all attempts fail; the source file is never removed in that case.
    .PARAMETER Path
    Full path of the generated package.
    .PARAMETER Destination
    Desired final path of the package.
    .OUTPUTS
    [string] The path the package was published to.
    .PARAMETER CopyFirst
    Copy under a temporary name, then rename. Use when Path is in a staging folder.
    .PARAMETER MaxAttempts
    Attempts for each step (default 10), with an increasing pause between them.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$CopyFirst,
        [int]$MaxAttempts = 10
    )

    # Runs $Action until it succeeds or attempts run out; rethrows the last error.
    $retry = {
        param([scriptblock]$Action)
        for ($attempt = 1; ; $attempt++) {
            try { & $Action; return }
            catch {
                if ($attempt -ge $MaxAttempts) { throw }
                Start-Sleep -Milliseconds (250 * $attempt)
            }
        }
    }

    # Moves $From to the first free name derived from $Destination; the chosen path is kept in $state.
    $state = @{ Final = $null }
    $moveToFreeName = {
        param([string]$From)
        $dir  = Split-Path $Destination -Parent
        $base = [System.IO.Path]::GetFileNameWithoutExtension($Destination)
        $ext  = [System.IO.Path]::GetExtension($Destination)
        $candidate = $Destination
        for ($n = 1; Test-Path -LiteralPath $candidate; $n++) { $candidate = Join-Path $dir "$base`_$n$ext" }
        Move-Item -LiteralPath $From -Destination $candidate -ErrorAction Stop
        $state.Final = $candidate
    }

    if (-not $CopyFirst) {
        & $retry { & $moveToFreeName $Path }
        return $state.Final
    }

    # Unique per run, so two GUI instances publishing the same name never share a partial file;
    # short and independent of the final name, so it never exceeds the 255-character name limit.
    $partial = Join-Path (Split-Path $Destination -Parent) ("~iwa-{0}.partial" -f [guid]::NewGuid().ToString('N'))
    try {
        & $retry { Copy-Item -LiteralPath $Path -Destination $partial -ErrorAction Stop }
        & $retry { & $moveToFreeName $partial }
    } catch {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw
    }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $state.Final
}

function Get-IntuneWinAppUtilWorkFolder {
    <#
    .SYNOPSIS
    Returns the working folder a run of IntuneWinAppUtil.exe used, read from its console output.
    .DESCRIPTION
    The tool compresses the source into '<temp>\<guid>\IntuneWinPackage\Contents\IntunePackage.intunewin'
    and does not always remove <guid>. Only the GUID is read from the output (so quotes or apostrophes
    in the source path cannot break the match) and joined to the temp folder the tool inherits from us
    (which may be printed in long or 8.3 form), so only this run's folder is ever returned.
    .PARAMETER ToolOutput
    Captured standard output of the tool.
    .PARAMETER TempPath
    The temp folder the tool used (default: this process's temp folder).
    .OUTPUTS
    [string] Full path of the work folder, or $null when it cannot be determined.
    #>

    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$ToolOutput,
        [string]$TempPath = [System.IO.Path]::GetTempPath()
    )

    # Anchored to the end of the "Compressing the source folder" line (the destination field), so a
    # similar-looking segment inside the source path can never be picked.
    if ($ToolOutput -match "(?m)Compressing the source folder .*\\(?<guid>[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})\\IntuneWinPackage\\Contents\\IntunePackage\.intunewin'\s*$") {
        return (Join-Path $TempPath $Matches['guid'])
    }
    $null
}

function Read-SharedTextFile {
    <#
    .SYNOPSIS
    Reads a text file that another process may still be writing; returns '' when it cannot be read.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    try {
        $fs = [System.IO.FileStream]::new($Path, 'Open', 'Read', ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            $reader = [System.IO.StreamReader]::new($fs)
            $reader.ReadToEnd()
        } finally {
            $fs.Dispose()
        }
    } catch {
        ''
    }
}

function Get-IntuneWinAppUtilProgress {
    <#
    .SYNOPSIS
    Estimates packaging progress (0-95%) from the console output IntuneWinAppUtil.exe has written so far.
    .DESCRIPTION
    The tool reports steps, not percentages. Fixed steps get fixed values; the two compression steps
    (the slow ones) advance with the size of the archive being written compared with the folder size
    the tool prints just before ("Calculated size for folder ... is N"). The remaining 5% is left for
    publishing the package to the output folder.
    .PARAMETER ToolOutput
    Output captured so far.
    .OUTPUTS
    [pscustomobject] with Percent ([int]) and Step ([string]).
    #>

    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$ToolOutput
    )

    # Progress inside a compression step, from the size of the archive being written.
    $compressionShare = {
        param([string]$Archive)
        $total = 0
        $sizes = [regex]::Matches($ToolOutput, 'Calculated size for folder .* is (\d+)')
        if ($sizes.Count) { $total = [double]$sizes[$sizes.Count - 1].Groups[1].Value }
        $written = 0
        try { if ($Archive -and (Test-Path -LiteralPath $Archive)) { $written = (Get-Item -LiteralPath $Archive).Length } } catch { }
        if ($total -le 0) { return 0 }
        [Math]::Min(1.0, $written / $total)   # 1.0, not 1: an int literal selects Min(int, int) and truncates
    }

    $lines = @($ToolOutput -split "`r?`n" | Where-Object { $_ -match '\S' })
    $last = if ($lines.Count) { $lines[-1] } else { '' }

    switch -Regex ($last) {
        'Done!!!|has been generated successfully' { return [pscustomobject]@{ Percent = 95; Step = 'Finishing' } }
        'Removing temporary files|Removed temporary files' { return [pscustomobject]@{ Percent = 94; Step = 'Removing temporary files' } }
        "Compressing folder '.*' to '|Calculated size for folder .*IntuneWinPackage|Compressed folder '.*IntuneWinPackage'" {
            $archive = if ($ToolOutput -match "(?m)Compressing folder '.*' to '(?<out>[^']+)'\s*$") { $Matches['out'] } else { $null }
            return [pscustomobject]@{ Percent = 85 + [int](8 * (& $compressionShare $archive)); Step = 'Building the .intunewin package' }
        }
        'detection XML' { return [pscustomobject]@{ Percent = 82; Step = 'Generating the detection metadata' } }
        'SHA256|Copying encrypted file|got updated' { return [pscustomobject]@{ Percent = 78; Step = 'Verifying the encrypted content' } }
        'Encrypting|encrypted successfully|Checking file type|Checked file type' { return [pscustomobject]@{ Percent = 72; Step = 'Encrypting the content' } }
        "Compressing the source folder|Calculated size for folder|Compressed folder" {
            $archive = if ($ToolOutput -match "Compressing the source folder '.*' to '(?<out>[^']+IntunePackage\.intunewin)'") { $Matches['out'] } else { $null }
            return [pscustomobject]@{ Percent = 5 + [int](65 * (& $compressionShare $archive)); Step = 'Compressing the source folder' }
        }
        'Validat' { return [pscustomobject]@{ Percent = 3; Step = 'Validating parameters' } }
    }
    [pscustomobject]@{ Percent = 2; Step = 'Starting IntuneWinAppUtil' }
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
