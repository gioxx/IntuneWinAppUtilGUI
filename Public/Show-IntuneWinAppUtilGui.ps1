# Show-Gui.ps1
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Returns a relative path from BasePath to TargetPath when possible; otherwise returns the absolute path.
function Get-RelativePath {
    param(
        [Parameter(Mandatory)] [string]$BasePath,
        [Parameter(Mandatory)] [string]$TargetPath
    )
    
    try {
        $baseFull = [System.IO.Path]::GetFullPath(($BasePath.TrimEnd('\') + '\'))
        $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
        $uriBase   = [Uri]$baseFull
        $uriTarget = [Uri]$targetFull
        return $uriBase.MakeRelativeUri($uriTarget).ToString().Replace('/','\')
    } catch {
        return $TargetPath
    }
}

# If Invoke-AppDeployToolkit.exe exists under SourcePath, suggest it into the Setup textbox
# and optionally populate FinalFilename if AppName/AppVersion are found in Invoke-AppDeployToolkit.ps1
function Set-SetupFromSource {
    param([string]$SourcePath)

    if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path $SourcePath)) { return }

    # If current SetupFile value already points to an existing file (absolute or relative to source), do not override.
    $current = $SetupFile.Text.Trim()
    if ($current) {
        if (Test-Path $current) { return }
        $maybeRelative = Join-Path $SourcePath $current
        if (Test-Path $maybeRelative) { return }
    }

    # Search for Invoke-AppDeployToolkit.exe
    $exeHit = Get-ChildItem -Path $SourcePath -Filter 'Invoke-AppDeployToolkit.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exeHit) {
        # Prefer a relative path when the file is inside the source folder
        $relativeExe = Get-RelativePath -BasePath $SourcePath -TargetPath $exeHit.FullName
        $SetupFile.Text = $relativeExe

        # Look for Invoke-AppDeployToolkit.ps1 in the same folder
        $ps1Path = Join-Path $exeHit.Directory.FullName 'Invoke-AppDeployToolkit.ps1'
        if (Test-Path $ps1Path) {
            try {
                $content = Get-Content $ps1Path -Raw

                $appName = if ($content -match "AppName\s*=\s*'([^']+)'") { $matches[1] } else { $null }
                $appVersion = if ($content -match "AppVersion\s*=\s*'([^']+)'") { $matches[1] } else { $null }

                if ($appName -and $appVersion) {
                    # Clean filename: remove spaces and invalid chars
                    $cleanName = ($appName -replace '\s+', '' -replace '[\\/:*?"<>|]', '-')
                    $cleanVer = ($appVersion -replace '\s+', '' -replace '[\\/:*?"<>|]', '-')
                    $FinalFilename.Text = "${cleanName}_${cleanVer}"
                }
            } catch {
                # Fail silently if parsing goes wrong
            }
        }
    }
}

# Returns file version (FileVersion preferred, then ProductVersion); $null if not available.
function Get-ExeVersion {
    param([Parameter(Mandatory)][string]$Path)

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

# Updates the ToolVersion TextBlock with current version or a default message.
function Show-ToolVersion {
    param([string]$Path)

    if (-not $ToolVersionText) { return }
    $ver = if ($Path) { Get-ExeVersion -Path $Path } else { $null }
    $ToolVersionText.Text = if ($ver) {
        "IntuneWinAppUtil version: $ver"
    } else {
        "IntuneWinAppUtil version: (not detected)"
    }
}

# Downloads the latest IntuneWinAppUtil.exe by fetching the master zip from GitHub, 
# extracting it, locating the EXE, and copying it into %APPDATA%\IntuneWinAppUtilGUI\bin.
function Invoke-RedownloadIntuneTool {
    param()

    $appRoot   = Join-Path $env:APPDATA 'IntuneWinAppUtilGUI'
    $binDir    = Join-Path $appRoot 'bin'
    $exePath   = Join-Path $binDir 'IntuneWinAppUtil.exe'
    $zipUrl    = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/heads/master.zip'
    $zipPath   = Join-Path $env:TEMP 'IntuneWinAppUtil-master.zip'
    $extractTo = Join-Path $env:TEMP 'IntuneExtract'

    try {
        # Clean previous temp
        if (Test-Path $extractTo) { Remove-Item $extractTo -Recurse -Force }

        # Ensure bin dir exists (and clear old exe to avoid stale versions)
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        if (Test-Path $exePath) { Remove-Item $exePath -Force -ErrorAction SilentlyContinue }

        # Download ZIP
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

        # Extract ZIP
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractTo, $true)

        # Find EXE in extracted content
        $found = Get-ChildItem -Path $extractTo -Recurse -Filter 'IntuneWinAppUtil.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) {
            throw "IntuneWinAppUtil.exe not found in extracted archive."
        }

        # Copy to bin
        Copy-Item -Path $found.FullName -Destination $exePath -Force

        # Cleanup temp
        if (Test-Path $zipPath)   { Remove-Item $zipPath -Force }
        if (Test-Path $extractTo) { Remove-Item $extractTo -Recurse -Force }

        return $exePath
    } catch {
        throw $_
    }
}

# Show the main GUI window and handle all events.
function Show-IntuneWinAppUtilGui {
    [CmdletBinding()]
    param ()

    $configPath = Join-Path -Path $env:APPDATA -ChildPath "IntuneWinAppUtilGUI\config.json"
    $xamlPath = Join-Path -Path $PSScriptRoot -ChildPath "..\UI\UI.xaml"
    $iconPath = Join-Path -Path $PSScriptRoot -ChildPath "..\Assets\Intune.ico"

    if (-not (Test-Path $xamlPath)) {
        Write-Error "XAML file not found: $xamlPath"
        return
    }

    $xaml = Get-Content $xamlPath -Raw
    $window = [Windows.Markup.XamlReader]::Parse($xaml)

    $SourceFolder = $window.FindName("SourceFolder")
    $SetupFile = $window.FindName("SetupFile")
    $OutputFolder = $window.FindName("OutputFolder")

    $ToolPathBox = $window.FindName("ToolPathBox")
    $ToolVersion = $window.FindName("ToolVersion")
    $ToolVersionText = $window.FindName("ToolVersionText")
    $ToolVersionLink = $window.FindName("ToolVersionLink")
    $RedownloadTool = $window.FindName("RedownloadTool")
    
    $FinalFilename = $window.FindName("FinalFilename")
    
    $BrowseSource = $window.FindName("BrowseSource")
    $BrowseSetup = $window.FindName("BrowseSetup")
    $BrowseOutput = $window.FindName("BrowseOutput")
    $BrowseTool = $window.FindName("BrowseTool")
    
    $RunButton = $window.FindName("RunButton")
    $ClearButton = $window.FindName("ClearButton")
    $ExitButton = $window.FindName("ExitButton")

    # When user types/pastes the source path manually, try to auto-suggest the setup file if found.
    $SourceFolder.Add_TextChanged({
        param($sender, $e)
        $src = $SourceFolder.Text.Trim()
        if ($src) { Set-SetupFromSource -SourcePath $src }
    })

    # Preload config.json if it exists
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.ToolPath -and (Test-Path $cfg.ToolPath)) {
                $ToolPathBox.Text = $cfg.ToolPath
                Show-ToolVersion -Path $cfg.ToolPath
            }
        } catch {}
    }

    # Browse for Source Folder
    $BrowseSource.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dialog.ShowDialog() -eq 'OK') {
            $SourceFolder.Text = $dialog.SelectedPath
            # Auto-suggest Invoke-AppDeployToolkit.exe when present in the selected source
            Set-SetupFromSource -SourcePath $dialog.SelectedPath
        }
    })

    # Browse for Setup File
    $BrowseSetup.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = "Executable or MSI (*.exe;*.msi)|*.exe;*.msi"
        if ($dialog.ShowDialog() -eq 'OK') {
            $selectedPath = $dialog.FileName
            $sourceRoot = $SourceFolder.Text.Trim()

            if (-not [string]::IsNullOrWhiteSpace($sourceRoot) -and (Test-Path $sourceRoot)) {
                try {
                    $relativePath = [System.IO.Path]::GetRelativePath($sourceRoot, $selectedPath)
                    if (-not ($relativePath.StartsWith(".."))) {
                        # File is inside source folder or subdir
                        $SetupFile.Text = $relativePath
                    } else {
                        # Outside of source folder
                        $SetupFile.Text = $selectedPath
                    }
                } catch {
                    # If relative path fails (e.g. bad format), fallback
                    $SetupFile.Text = $selectedPath
                }
            } else {
                # Source folder not set or invalid, fallback
                $SetupFile.Text = $selectedPath
            }
        }
    })

    # Browse for Output Folder
    $BrowseOutput.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq 'OK') { $OutputFolder.Text = $dlg.SelectedPath }
    })

    # Browse for IntuneWinAppUtil.exe
    $BrowseTool.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "IntuneWinAppUtil.exe|IntuneWinAppUtil.exe"
        if ($dlg.ShowDialog() -eq 'OK') {
            $ToolPathBox.Text = $dlg.FileName
            Show-ToolVersion -Path $dlg.FileName
        }
    })

    # Force download the IntuneWinAppUtil.exe tool
    $RedownloadTool.Add_Click({
        $confirm = [System.Windows.MessageBox]::Show(
            "This will re-download the latest IntuneWinAppUtil.exe and replace the one in your bin folder.`n`nProceed?",
            "Confirm re-download",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

        try {
            $newPath = Invoke-RedownloadIntuneTool
            $ToolPathBox.Text = $newPath
            Show-ToolVersion -Path $newPath

            [System.Windows.MessageBox]::Show(
                "IntuneWinAppUtil.exe has been refreshed.`n`nPath:`n$newPath",
                "Download complete",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
        } catch {
            [System.Windows.MessageBox]::Show(
                "Re-download failed:`n$($_.Exception.Message)",
                "Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
        }
    })

    # When user types/pastes the tool path manually, show version if valid
    $ToolPathBox.Add_TextChanged({
        param($sender, $e)
        $p = $ToolPathBox.Text.Trim()
        if ($p) { Show-ToolVersion -Path $p } else { Show-ToolVersion -Path $null }
    })

    $RunButton.Add_Click({
        $c = $SourceFolder.Text.Trim()
        $s = $SetupFile.Text.Trim()
        $o = $OutputFolder.Text.Trim()
        $f = $FinalFilename.Text.Trim()

        $f = -join ($f.ToCharArray() | Where-Object { [System.IO.Path]::GetInvalidFileNameChars() -notcontains $_ })

        if (-not (Test-Path $c)) { [System.Windows.MessageBox]::Show("Invalid source folder path.", "Error", "OK", "Error"); return }
        if (-not (Test-Path $s)) {
            $s = Join-Path $c $s
            if (-not (Test-Path $s)) { [System.Windows.MessageBox]::Show("Setup file not found.", "Error", "OK", "Error"); return }
        }
        if (-not (Test-Path $o)) { [System.Windows.MessageBox]::Show("Invalid output folder path.", "Error", "OK", "Error"); return }

        # IntuneWinAppUtil.exe path check (or download if not set)
        $toolPath = $ToolPathBox.Text.Trim()
        $downloadDir = Join-Path $env:APPDATA "IntuneWinAppUtilGUI\bin"
        $exePath = Join-Path $downloadDir "IntuneWinAppUtil.exe"

        if ([string]::IsNullOrWhiteSpace($toolPath) -or -not (Test-Path $toolPath)) {
            if (-not (Test-Path $exePath)) {
                try {
                    $url = "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/heads/master.zip"
                    $zipPath = Join-Path $env:TEMP "IntuneWinAppUtil-master.zip"
                    $extractPath = Join-Path $env:TEMP "IntuneExtract"

                    if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }

                    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractPath, $true)
                    Remove-Item $zipPath -Force

                    # Find the executable in the extracted structure
                    $sourceExe = Get-ChildItem -Path $extractPath -Recurse -Filter "IntuneWinAppUtil.exe" | Select-Object -First 1

                    if (-not $sourceExe) {
                        throw "IntuneWinAppUtil.exe not found in extracted archive."
                    }

                    # Copy to destination
                    New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
                    Copy-Item -Path $sourceExe.FullName -Destination $exePath -Force

                    [System.Windows.MessageBox]::Show("Tool downloaded and extracted to:`n$exePath", "Download Complete", "OK", "Info")
                } catch {
                    [System.Windows.MessageBox]::Show("Failed to download or extract the archive:`n$($_.Exception.Message)", "Download Error", "OK", "Error")
                    return
                }
            }

            if (Test-Path $exePath) {
                $toolPath = $exePath
                $ToolPathBox.Text = $toolPath
                Show-ToolVersion -Path $toolPath  # equivalent -Path $exePath
            }
        }

        if (-not (Test-Path $toolPath)) {
            [System.Windows.MessageBox]::Show("IntuneWinAppUtil.exe not found at:`n$toolPath", "Error", "OK", "Error")
            return
        }

        $IWAUtilargs = "-c `"$c`" -s `"$s`" -o `"$o`""
        Start-Process -FilePath $toolPath -ArgumentList $IWAUtilargs -WorkingDirectory (Split-Path $toolPath) -WindowStyle Normal -Wait

        Start-Sleep -Seconds 1
        $defaultName = [System.IO.Path]::GetFileNameWithoutExtension($s) + ".intunewin"
        $defaultPath = Join-Path $o $defaultName

        if (Test-Path $defaultPath) {
            $newName = if ([string]::IsNullOrWhiteSpace($f)) {
            (Split-Path $c -Leaf) + ".intunewin"
            } else {
                $f + ".intunewin"
            }

            try {
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($newName)
                $ext = [System.IO.Path]::GetExtension($newName)
                $finalName = $newName
                $counter = 1
        
                while (Test-Path (Join-Path $o $finalName)) {
                    $finalName = "$baseName" + "_$counter" + "$ext"
                    $counter++
                }
        
                Rename-Item -Path $defaultPath -NewName $finalName -Force
                $fullPath = Join-Path $o $finalName
        
                $msg = "Package created and renamed to:`n$finalName"
                if ($finalName -ne $newName) {
                    $msg += "`n(Note: original name '$newName' already existed.)"
                }
                $msg += "`n`nOpen folder?"
        
                $resp = [System.Windows.MessageBox]::Show(
                    $msg,
                    "Success",
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Information
                )
                if ($resp -eq "Yes") {
                    Start-Process explorer.exe "/select,`"$fullPath`""
                }
        
            } catch {
                [System.Windows.MessageBox]::Show("Renaming failed: $($_.Exception.Message)", "Warning", "OK", "Warning")
            }
            
        } else {
            [System.Windows.MessageBox]::Show("Output file not found.", "Warning", "OK", "Warning")
        }
    })

    # Clear button: reset all except ToolPath if loaded from config
    $ClearButton.Add_Click({
        $SourceFolder.Clear()
        $SetupFile.Clear()
        $OutputFolder.Clear()
        $FinalFilename.Clear()
    })

    # Exit button: close the window
    $ExitButton.Add_Click({
        $window.Close()
    })

    $window.Add_KeyDown({
        param($sender, $e)
        switch ($e.Key) {
            'Escape' {
                if ([System.Windows.MessageBox]::Show("Exit the tool?", "Confirm", "YesNo", "Question") -eq "Yes") {
                    $window.Close()
                }
            }
            'Return' {
                $RunButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
            }
        }
    })

    $window.Add_Closed({
        if (-not (Test-Path (Split-Path $configPath))) {
            New-Item -Path (Split-Path $configPath) -ItemType Directory -Force | Out-Null
        }
        $cfg = @{ ToolPath = $ToolPathBox.Text.Trim() }
        $cfg | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
    })

    if (Test-Path $iconPath) {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri $iconPath, [System.UriKind]::Absolute))
    }

    $window.AddHandler([
        System.Windows.Documents.Hyperlink]::RequestNavigateEvent,
        [System.Windows.Navigation.RequestNavigateEventHandler] {
            param($sender, $e)
            Start-Process $e.Uri.AbsoluteUri
            $e.Handled = $true
        })
    
    $window.ShowDialog() | Out-Null
}

Export-ModuleMember -Function Show-IntuneWinAppUtilGui
