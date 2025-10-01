# Show-IntuneWinAppUtilGui.ps1
# Show the main GUI window and handle all events.
function Show-IntuneWinAppUtilGui {
    [CmdletBinding()]
    param ()

    $moduleRoot = Split-Path -Path $PSScriptRoot -Parent
    $configPath = Join-Path -Path $env:APPDATA -ChildPath "IntuneWinAppUtilGUI\config.json"
    $xamlPath = Join-Path $moduleRoot 'UI\UI.xaml'
    $iconPath = Join-Path $moduleRoot 'Assets\Intune.ico'
    $iconPngPath = Join-Path $moduleRoot 'Assets\Intune.png'

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
    $DownloadTool = $window.FindName("DownloadTool")
    
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
        if ($src) { Set-SetupFromSource -SourcePath $src -SetupFileControl $SetupFile -FinalFilenameControl $FinalFilename }
    })

    # Preload config.json if it exists
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.ToolPath -and (Test-Path $cfg.ToolPath)) {
                $ToolPathBox.Text = $cfg.ToolPath
                Show-ToolVersion -Path $cfg.ToolPath -Target $ToolVersionText
            }
        } catch {}
    }

    # Browse for Source Folder
    $BrowseSource.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dialog.ShowDialog() -eq 'OK') {
            $SourceFolder.Text = $dialog.SelectedPath
            # Auto-suggest Invoke-AppDeployToolkit.exe when present in the selected source
            Set-SetupFromSource -SourcePath $dialog.SelectedPath -SetupFileControl $SetupFile -FinalFilenameControl $FinalFilename
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
                    $relativePath = Get-RelativePath -BasePath $sourceRoot -TargetPath $selectedPath
                    if (-not ($relativePath.StartsWith(".."))) {
                        $SetupFile.Text = $relativePath # File is inside source folder or subdir
                    } else {
                        $SetupFile.Text = $selectedPath # Outside of source folder
                    }
                } catch {
                    $SetupFile.Text = $selectedPath # If relative path fails (e.g. bad format), fallback
                }
            # } else {
            #     $SetupFile.Text = $selectedPath # Source folder not set or invalid, fallback
            # }
            } else {
                $SourceFolder.Text = Split-Path $selectedPath -Parent # Source folder not set or invalid -> infer it from the selected setup path
                $SetupFile.Text = [System.IO.Path]::GetFileName($selectedPath) # Store only the file name in SetupFile so it is relative to SourceFolder
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
            Show-ToolVersion -Path $dlg.FileName -Target $ToolVersionText
        }
    })

    # Force download the IntuneWinAppUtil.exe tool
    $DownloadTool.Add_Click({
        $confirm = [System.Windows.MessageBox]::Show(
            "This will download the latest IntuneWinAppUtil.exe and replace (if already exists) the one in your bin folder.`n`nProceed?",
            "Confirm force download",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

        try {
            $newPath = Invoke-DownloadIntuneTool
            $ToolPathBox.Text = $newPath
            Show-ToolVersion -Path $newPath -Target $ToolVersionText

            [System.Windows.MessageBox]::Show(
                "IntuneWinAppUtil.exe has been refreshed.`n`nPath:`n$newPath",
                "Download complete",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
        } catch {
            [System.Windows.MessageBox]::Show(
                "Download failed:`n$($_.Exception.Message)",
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
        if ($p) { Show-ToolVersion -Path $p -Target $ToolVersionText } else { Show-ToolVersion -Path $null -Target $ToolVersionText }
    })

    # If the user typed/pasted an absolute setup path before setting SourceFolder,
    # infer SourceFolder from that path and convert SetupFile to a relative file name.
    $SetupFile.Add_LostFocus({
        $sText = $SetupFile.Text.Trim()
        # Only act if SourceFolder is empty and SetupFile looks like an absolute existing path
        if ([string]::IsNullOrWhiteSpace($SourceFolder.Text) -and
            -not [string]::IsNullOrWhiteSpace($sText) -and
            [System.IO.Path]::IsPathRooted($sText) -and
            (Test-Path $sText)) {

            $SourceFolder.Text = Split-Path $sText -Parent
            $SetupFile.Text = [System.IO.Path]::GetFileName($sText)
            # Note: SourceFolder.Text change will NOT override SetupFile because Set-SetupFromSource
            # early-returns if SetupFile already points to an existing file (absolute or relative).
        }
    })

    # Run button: validate inputs, run IntuneWinAppUtil.exe, rename output if needed
    $RunButton.Add_Click({
        $c = $SourceFolder.Text.Trim() # Source folder
        $s = $SetupFile.Text.Trim() # Setup file (relative or absolute)
        $o = $OutputFolder.Text.Trim() # Output folder
        $f = $FinalFilename.Text.Trim() # Final filename

        # Clean FinalFilename from invalid chars
        $f = -join ($f.ToCharArray() | Where-Object { [System.IO.Path]::GetInvalidFileNameChars() -notcontains $_ })

        # Validate source folder
        if (-not (Test-Path $c)) { [System.Windows.MessageBox]::Show("Invalid source folder path.", "Error", "OK", "Error"); return }
        
        # Validate setup file
        if (-not (Test-Path $s)) {
            $s = Join-Path $c $s
            if (-not (Test-Path $s)) { [System.Windows.MessageBox]::Show("Setup file not found.", "Error", "OK", "Error"); return }
        }

        # Validate extension before running the tool
        $extSetup = [System.IO.Path]::GetExtension($s).ToLowerInvariant()
        if ($extSetup -notin @(".exe", ".msi")) {
            [System.Windows.MessageBox]::Show(
                "Setup file must be .exe or .msi (got '$extSetup').",
                "Invalid setup type", "OK", "Error"
            )
            return
        }

        # Validate output folder
        if (-not (Test-Path $o)) { 
            try {
                New-Item -Path $o -ItemType Directory -Force | Out-Null
            } catch {
                [System.Windows.MessageBox]::Show("Output folder path is invalid and could not be created.", "Error", "OK", "Error")
                return
            }
        }

        # Normalize all paths to absolute
        try {
            $c = [System.IO.Path]::GetFullPath($c)
            $s = [System.IO.Path]::GetFullPath($s)
            $o = [System.IO.Path]::GetFullPath($o)
        } catch {
            [System.Windows.MessageBox]::Show("Invalid path format: $($_.Exception.Message)", "Error", "OK", "Error")
            return
        }

        # IntuneWinAppUtil.exe path check (or initialize/download if not set)
        $toolPath = Initialize-IntuneWinAppUtil -UiToolPath ($ToolPathBox.Text.Trim())

        if (-not $toolPath -or -not (Test-Path $toolPath)) {
            [System.Windows.MessageBox]::Show(
                "IntuneWinAppUtil.exe not found and could not be initialized.",
                "Error", "OK", "Error"
            )
            return
        }

        # Keep UI in sync and show version
        $ToolPathBox.Text = $toolPath
        Show-ToolVersion -Path $toolPath -Target $ToolVersionText
        
        # Build a single, properly-quoted argument string
        # -c = source folder, -s = setup file (EXE/MSI), -o = output folder.
        $iwaArgs = ('-c "{0}" -s "{1}" -o "{2}"' -f $c, $s, $o)

        # Launch IntuneWinAppUtil.exe, wait, and capture exit code (WorkingDirectory is set to the tool's folder to avoid relative path issues)
        try {
            $proc = Start-Process -FilePath $toolPath `
                -ArgumentList $iwaArgs `
                -WorkingDirectory (Split-Path $toolPath) `
                -WindowStyle Normal `
                -PassThru
        } catch {
            [System.Windows.MessageBox]::Show(
                "Failed to start IntuneWinAppUtil.exe:`n$($_.Exception.Message)",
                "Execution error", "OK", "Error"
            )
            return
        }
        $proc.WaitForExit()

        # Fail early if tool returned non-zero
        if ($proc.ExitCode -ne 0) {
            [System.Windows.MessageBox]::Show(
                "IntuneWinAppUtil exited with code $($proc.ExitCode).",
                "Packaging failed", "OK", "Error"
            )
            return
        }

        # Wait a bit for the output file to appear (up to 10 seconds, checking every 250ms)
        # Compute the default output filename that IntuneWinAppUtil generates. By default it matches the setup's base name + ".intunewin".
        $defaultName = [System.IO.Path]::GetFileNameWithoutExtension($s) + ".intunewin"
        $defaultPath = Join-Path $o $defaultName

        $timeoutSec = 10
        $elapsed = 0
        while (-not (Test-Path $defaultPath) -and $elapsed -lt $timeoutSec) {
            Start-Sleep -Milliseconds 250
            $elapsed += 0.25
        }

        if (Test-Path $defaultPath) {
            # Build desired name from $f (if any), ensuring exactly one ".intunewin":
            # - If FinalFilename ($f) is blank, fallback to using the source folder name.
            # - Otherwise use the provided FinalFilename.
            if ([string]::IsNullOrWhiteSpace($f)) {
                $desiredName = (Split-Path $c -Leaf) + ".intunewin"
            } else {
                $extF = [System.IO.Path]::GetExtension($f).ToLowerInvariant()
                $baseF = if ($extF -eq ".intunewin") { [System.IO.Path]::GetFileNameWithoutExtension($f) } else { $f }
                $desiredName = $baseF + ".intunewin"
            }

            $newName = $desiredName

            try {
                # Prepare collision-safe rename:
                # If a file with the desired name already exists, append _1, _2, ... until unique.
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($newName)
                $ext = [System.IO.Path]::GetExtension($newName)
                $finalName = $newName
                $counter = 1

                while (Test-Path (Join-Path $o $finalName)) {
                    $finalName = "$baseName" + "_$counter" + "$ext"
                    $counter++
                }

                # Perform the rename operation from the tool's default output to our final target name.
                Rename-Item -Path $defaultPath -NewName $finalName -Force
                $fullPath = Join-Path $o $finalName

                # Inform the user and optionally offer to open File Explorer with the file selected.
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
                    Start-Process explorer.exe "/select,`"$fullPath`"" # Open Explorer with the new file pre-selected.
                }

            } catch {
                [System.Windows.MessageBox]::Show("Renaming failed: $($_.Exception.Message)", "Warning", "OK", "Warning") # If anything goes wrong during the rename, show a warning.
            }

        } else {
            [System.Windows.MessageBox]::Show(
                "Output file not found:`n$defaultPath",
                "Warning", "OK", "Warning"
            ) # The expected output was not found; warn the user (the tool may have failed).
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

    # Keyboard shortcuts: Esc to exit (with confirmation), Enter to run packaging
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

    # When the window is closed, save the ToolPath to config.json
    $window.Add_Closed({
        if (-not (Test-Path (Split-Path $configPath))) {
            New-Item -Path (Split-Path $configPath) -ItemType Directory -Force | Out-Null
        }
        $cfg = @{ ToolPath = $ToolPathBox.Text.Trim() }
        $cfg | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
    })

    # Set window icon if available
    if (Test-Path $iconPath) {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri $iconPath, [System.UriKind]::Absolute))
    }

    # Find the Image control in XAML and load the PNG from disk and assign it to the Image.Source
    $HeaderIcon = $window.FindName('HeaderIcon')
    if ($HeaderIcon -and (Test-Path $iconPngPath)) {
        # Use BitmapImage with OnLoad so the file is not locked after loading
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.UriSource = [Uri]::new($iconPngPath, [UriKind]::Absolute)
        $bmp.EndInit()

        $HeaderIcon.Source = $bmp
    }

    # Hyperlink in the ToolVersionText to open the GitHub version history page (and other links if needed)
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
