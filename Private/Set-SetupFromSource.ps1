function Set-SetupFromSource {
    <#
    .SYNOPSIS
    Suggests the setup file and (optionally) proposes the final package name from a given source folder.
    .DESCRIPTION
    - Recursively searches for 'Invoke-AppDeployToolkit.exe' under SourcePath.
    - If found, populates SetupFileControl with a relative path (via Get-RelativePath) when the exe resides under SourcePath.
    - Does not overwrite SetupFileControl if it already points to an existing file (absolute or relative to SourcePath).
    - If 'Invoke-AppDeployToolkit.ps1' exists in the same folder, extracts AppName/AppVersion and sets FinalFilenameControl.Text:
        * 'AppName_Version' when both are present;
        * 'AppName' when AppVersion is missing/empty.
      Filename is sanitized (spaces removed, invalid filename chars replaced with '-').
    - Parsing/IO errors are swallowed.
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

    if (-not (Test-Path $SourcePath)) { return }

    # If current SetupFile value already points to an existing file (absolute or relative to source), do not override.
    $current = $SetupFileControl.Text.Trim()
    if ($current) {
        if (Test-Path $current) { return }
        $maybeRelative = Join-Path $SourcePath $current
        if (Test-Path $maybeRelative) { return }
    }

    # Search for Invoke-AppDeployToolkit.exe
    $exeHit = Get-ChildItem -Path $SourcePath -Filter 'Invoke-AppDeployToolkit.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exeHit) {
        # Prefer a relative path when the file is inside the source folder
        $SetupFileControl.Text = Get-RelativePath -BasePath $SourcePath -TargetPath $exeHit.FullName

        # If FinalFilenameControl already has a value, don't override user's input.
        $finalCurrent = $FinalFilenameControl.Text.Trim()
        if (-not $finalCurrent) {
            # Look for Invoke-AppDeployToolkit.ps1 in the same folder
            $ps1Path = Join-Path $exeHit.Directory.FullName 'Invoke-AppDeployToolkit.ps1'
            if (Test-Path $ps1Path) {
                try {
                    $content = Get-Content $ps1Path -Raw

                    # Support both single and double quotes: AppName = 'X' or AppName = "X"
                    $appName = $null
                    $appVersion = $null
                    if ($content -match '(?m)AppName\s*=\s*[''"]([^''"]+)[''"]') { $appName = $matches[1] }
                    if ($content -match '(?m)AppVersion\s*=\s*[''"]([^''"]*)[''"]') { $appVersion = $matches[1] }

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
                        $FinalFilenameControl.Text = ($parts -join '_')
                    }
                    # else: do nothing when AppName is missing
                }
                catch {
                    # fail silently
                }
            }
        }
    }
}