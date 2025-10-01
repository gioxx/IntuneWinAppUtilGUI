function Set-SetupFromSource {
    <#
    .SYNOPSIS
    Suggests the setup file and (optionally) proposes the final package name from a given source folder.
    .DESCRIPTION
    - Recursively searches for 'Invoke-AppDeployToolkit.exe' under SourcePath.
    - If found, populates the provided TextBox control (SetupFileControl) with a relative path
      (via Get-RelativePath) when the exe resides under SourcePath.
    - Does not overwrite SetupFileControl if it already points to an existing file (absolute
      or relative to SourcePath).
    - If 'Invoke-AppDeployToolkit.ps1' exists in the same folder, extracts AppName/AppVersion
      and sets FinalFilenameControl.Text to 'AppName_Version' (sanitizing spaces and invalid
      filename characters).
    - Fails silently on parsing/IO errors.
    .PARAMETER SourcePath
    The source directory to inspect. Must exist.
    .PARAMETER SetupFileControl
    The TextBox to populate with the suggested setup path (relative when possible).
    .PARAMETER FinalFilenameControl
    The TextBox to populate with the proposed final filename (e.g., 'AppName_Version').
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
        
        # Look for Invoke-AppDeployToolkit.ps1 in the same folder
        $ps1Path = Join-Path $exeHit.Directory.FullName 'Invoke-AppDeployToolkit.ps1'
        if (Test-Path $ps1Path) {
            try {
                $content = Get-Content $ps1Path -Raw
                $appName = $null
                $appVersion = $null
                if ($content -match "AppName\s*=\s*'([^']+)'") { $appName = $matches[1] }
                if ($content -match "AppVersion\s*=\s*'([^']+)'") { $appVersion = $matches[1] }

                if ($appName -and $appVersion) {
                    # Clean filename: remove spaces and invalid chars
                    $cleanName = ($appName -replace '\s+', '' -replace '[\\/:*?"<>|]', '-')
                    $cleanVer = ($appVersion -replace '\s+', '' -replace '[\\/:*?"<>|]', '-')
                    $FinalFilenameControl.Text = "${cleanName}_${cleanVer}"
                }
            } catch {
                # fail silently
            }
        }
    }
}