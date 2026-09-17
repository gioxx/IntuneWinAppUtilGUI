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

function Get-MsiPackageMetadata {
    <#
    .SYNOPSIS
    Reads ProductName and ProductVersion from an MSI package.
    .DESCRIPTION
    Uses the Windows Installer COM object to inspect the MSI Property table.
    Returns $null when the file cannot be read or the required values are missing.
    .PARAMETER MsiPath
    Full path to the MSI file.
    .OUTPUTS
    [pscustomobject] with ProductName and ProductVersion, or $null.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MsiPath
    )

    if (-not (Test-Path $MsiPath)) { return $null }

    $installer = $null
    $database = $null
    $views = @()

    try {
        $fullPath = (Resolve-Path -LiteralPath $MsiPath).Path
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.OpenDatabase($fullPath, 0)

        $metadata = [ordered]@{}
        foreach ($propertyName in @('ProductName', 'ProductVersion')) {
            $view = $null
            try {
                $query = 'SELECT `Value` FROM `Property` WHERE `Property`=''' + $propertyName + ''''
                $view = $database.OpenView($query)
                $views += $view
                $view.Execute()
                $record = $view.Fetch()
                if ($record) {
                    $value = $record.StringData(1)
                    if (-not [string]::IsNullOrWhiteSpace($value)) {
                        $metadata[$propertyName] = $value.Trim()
                    }
                }
            } catch {
                continue
            }
        }

        if (-not $metadata.Contains('ProductName') -and -not $metadata.Contains('ProductVersion')) {
            return $null
        }

        [pscustomobject]$metadata
    } catch {
        return $null
    } finally {
        foreach ($view in $views) {
            if ($view) {
                try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view) } catch { }
            }
        }
        if ($database) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($database) } catch { }
        }
        if ($installer) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) } catch { }
        }
    }
}

function Get-SetupSuggestion {
    <#
    .SYNOPSIS
    Computes the suggested setup file and (optionally) proposed final package name from a given source folder.
    .DESCRIPTION
    Pure, UI-free version of the scan performed by Set-SetupFromSource: it touches only the filesystem
    (and, for MSI metadata, the Windows Installer COM object), never a WPF control. This lets callers run
    the scan on a background job/runspace and apply the result to controls on the dispatcher thread afterwards.
    - Recursively searches for 'Invoke-AppDeployToolkit.exe' under SourcePath.
    - Does not return a suggestion when CurrentSetupFile already points to an existing file (absolute or relative to SourcePath).
    - If 'Invoke-AppDeployToolkit.ps1' exists in the same folder, extracts AppName/AppVersion for the proposed filename:
        * 'AppName_Version' when both are present;
        * 'AppName' when AppVersion is missing/empty.
    - If the PSADT metadata is missing, falls back to the first MSI found under SourcePath and uses its ProductName/ProductVersion.
      Filename is sanitized (spaces removed, invalid filename chars replaced with '-').
    - Parsing/IO errors are swallowed.
    .PARAMETER SourcePath
    The source directory to inspect. Must exist.
    .PARAMETER CurrentSetupFile
    The current value of the Setup File field (absolute or relative to SourcePath). Optional.
    .PARAMETER CurrentFinalFilename
    The current value of the Final Filename field. Optional; when non-empty, FinalFilename is never suggested.
    .OUTPUTS
    [pscustomobject] with SetupFile and FinalFilename (either may be $null), or $null when there is nothing to suggest.
    .EXAMPLE
    Get-SetupSuggestion -SourcePath $SourceFolder.Text -CurrentSetupFile $SetupFile.Text -CurrentFinalFilename $FinalFilename.Text
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SourcePath,
        [string]$CurrentSetupFile,
        [string]$CurrentFinalFilename
    )

    if (-not (Test-Path $SourcePath)) { return $null }

    # If current SetupFile value already points to an existing file (absolute or relative to source), do not override.
    $current = if ($CurrentSetupFile) { $CurrentSetupFile.Trim() } else { '' }
    if ($current) {
        if (Test-Path $current) { return $null }
        $maybeRelative = Join-Path $SourcePath $current
        if (Test-Path $maybeRelative) { return $null }
    }

    # Search for Invoke-AppDeployToolkit.exe first, and keep an MSI candidate for metadata fallback.
    $exeHit = Get-ChildItem -Path $SourcePath -Filter 'Invoke-AppDeployToolkit.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $msiHit = Get-ChildItem -Path $SourcePath -Filter '*.msi' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object @{
            Expression = {
                if ($_.FullName -match '\\Files\\') { 0 } else { 1 }
            }
        }, FullName |
        Select-Object -First 1

    $selectedHit = if ($exeHit) { $exeHit } else { $msiHit }
    if (-not $selectedHit) { return $null }

    # Prefer a relative path when the file is inside the source folder
    $result = [ordered]@{
        SetupFile     = (Get-RelativePath -BasePath $SourcePath -TargetPath $selectedHit.FullName)
        FinalFilename = $null
    }

    # If FinalFilenameControl already has a value, don't override user's input.
    $finalCurrent = if ($CurrentFinalFilename) { $CurrentFinalFilename.Trim() } else { '' }
    if (-not $finalCurrent) {
            try {
                # Look for Invoke-AppDeployToolkit.ps1 in the same folder when we are dealing with PSADT packages.
                $appName = $null
                $appVersion = $null

                if ($exeHit) {
                    $ps1Path = Join-Path $exeHit.Directory.FullName 'Invoke-AppDeployToolkit.ps1'
                    if (Test-Path $ps1Path) {
                        $content = Get-Content $ps1Path -Raw

                        # Support common PSADT forms such as $appName, $adtSession.AppName, and direct AppName assignments.
                        if ($content -match '(?im)(?:\$[\w.]+\.)?AppName\s*=\s*[''"]([^''"]*)[''"]') { $appName = $matches[1] }
                        if ($content -match '(?im)(?:\$[\w.]+\.)?AppVersion\s*=\s*[''"]([^''"]*)[''"]') { $appVersion = $matches[1] }
                    }
                }

                # Fall back to MSI metadata when PSADT metadata is missing or incomplete.
                if ([string]::IsNullOrWhiteSpace($appName)) {
                    $msiSource = if ($msiHit) { $msiHit } elseif ($selectedHit.Extension -ieq '.msi') { $selectedHit } else { $null }
                    if ($msiSource) {
                        $msiMeta = Get-MsiPackageMetadata -MsiPath $msiSource.FullName
                        if ($msiMeta) {
                            if ([string]::IsNullOrWhiteSpace($appName) -and $msiMeta.ProductName) {
                                $appName = $msiMeta.ProductName
                            }
                            if ([string]::IsNullOrWhiteSpace($appVersion) -and $msiMeta.ProductVersion) {
                                $appVersion = $msiMeta.ProductVersion
                            }
                        }
                    }
                }

                # Sanitize function: remove spaces, replace invalid filename chars with '-'
                function _Sanitize([string]$s) {
                    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
                    $noSpaces = ($s -replace '\s+', '')
                    return ($noSpaces -replace '[\\/:*?"<>|]', '-')
                }

                $cleanName = _Sanitize $appName
                $cleanVer = _Sanitize $appVersion

                # Build proposed filename:
                # - If both present: "Name_Version"
                # - If version missing/empty but name present: "Name"
                if ($cleanName) {
                    $parts = @($cleanName)
                    if ($cleanVer) { $parts += $cleanVer }
                    $result.FinalFilename = ($parts -join '_')
                }
                # else: do nothing when AppName is missing
            }
            catch {
                # fail silently
            }
    }

    [pscustomobject]$result
}

function Set-SetupFromSource {
    <#
    .SYNOPSIS
    Suggests the setup file and (optionally) proposes the final package name from a given source folder.
    .DESCRIPTION
    Thin, synchronous wrapper around Get-SetupSuggestion that applies the suggestion directly to the
    given WPF controls. Prefer calling Get-SetupSuggestion on a background job/runspace for large or
    slow (e.g. network) source folders, since the scan it performs is synchronous and recursive.
    .PARAMETER SourcePath
    The source directory to inspect. Must exist.
    .PARAMETER SetupFileControl
    The TextBox to populate with the suggested setup path (relative when possible).
    .PARAMETER FinalFilenameControl
    The TextBox to populate with the proposed final filename (e.g., 'AppName_Version' or 'AppName').
    .OUTPUTS
    None. Mutates the provided TextBox controls.
    .EXAMPLE
    Set-SetupFromSource -SourcePath $SourceFolder.Text -SetupFileControl $SetupFile -FinalFilenameControl $FinalFilename
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SourcePath,
        [Parameter(Mandatory)][ValidateNotNull()][System.Windows.Controls.TextBox]$SetupFileControl,
        [Parameter(Mandatory)][ValidateNotNull()][System.Windows.Controls.TextBox]$FinalFilenameControl
    )

    $suggestion = Get-SetupSuggestion -SourcePath $SourcePath -CurrentSetupFile $SetupFileControl.Text -CurrentFinalFilename $FinalFilenameControl.Text
    if (-not $suggestion) { return }

    $SetupFileControl.Text = $suggestion.SetupFile
    if ($suggestion.FinalFilename) {
        $FinalFilenameControl.Text = $suggestion.FinalFilename
    }
}
