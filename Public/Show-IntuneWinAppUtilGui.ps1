# Show-IntuneWinAppUtilGUI.ps1
# Show the main GUI window and handle all events.
function Show-IntuneWinAppUtilGUI {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Show diagnostic information")][switch] $Diag
    )

    $moduleRoot   = Split-Path -Path $PSScriptRoot -Parent
    $configPath   = Join-Path -Path $env:APPDATA -ChildPath "IntuneWinAppUtilGUI\config.json"
    $xamlPath     = Join-Path $moduleRoot 'UI\UI.xaml'
    $iconPath     = Join-Path $moduleRoot 'Assets\Intune.ico'
    $iconPngPath  = Join-Path $moduleRoot 'Assets\Intune.png'

    if (-not (Test-Path $xamlPath)) {
        Write-Error "XAML file not found: $xamlPath"
        return
    }

    # Relaunch in STA if needed
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        $modulePath = $MyInvocation.MyCommand.Module.Path
        $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
        Start-Process $shell -ArgumentList @(
            '-NoProfile',
            '-STA',
            '-Command', "Import-Module `"$modulePath`"; Show-IntuneWinAppUtilGUI"
        ) | Out-Null
        return
    }

    if ($Diag) {
        # Diagnostics: print handles/memory when the GUI starts
        try {
            $p = Get-Process -Id $PID
            Write-Verbose ("[Diagnostics/Start] Handles: {0}, GDI: {1}, WS: {2:N0} KB" -f $p.HandleCount, $p.GDIHandles, ($p.WorkingSet64/1KB)) -Verbose
            Write-Verbose "This PowerShell process will be available again when IntuneWinAppUtil GUI closes." -Verbose
        } catch { }
    }

    # Prefer software rendering to avoid GPU/driver glitches
    try { [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly } catch { }

    # Ensure there is a single Application for the whole PowerShell session
    $app = [System.Windows.Application]::Current
    if (-not $app) {
        $app = New-Object System.Windows.Application
        # Keep the dispatcher alive between runs
        $app.ShutdownMode = 'OnExplicitShutdown'
    }

    # Register global WPF dispatcher handler only once
    if (-not $app.Resources.Contains('IntuneGUI_HandlersRegistered')) {
        $app.add_DispatcherUnhandledException({
            param($evtSender, $e)
            [System.Windows.MessageBox]::Show(
                "Unexpected UI error:`n$($e.Exception.Message)",
                "UI Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
            $e.Handled = $true
        })
        $null = $app.Resources.Add('IntuneGUI_HandlersRegistered', $true)
    }

    # Parse XAML and get the main window
    $xaml   = Get-Content $xamlPath -Raw
    $window = [Windows.Markup.XamlReader]::Parse($xaml)

    # Grab controls
    $SourceFolder    = $window.FindName("SourceFolder")
    $SetupFile       = $window.FindName("SetupFile")
    $OutputFolder    = $window.FindName("OutputFolder")

    $ToolPathBox     = $window.FindName("ToolPathBox")
    $ToolVersionText = $window.FindName("ToolVersionText")
    $DownloadTool    = $window.FindName("DownloadTool")
    
    $FinalFilename   = $window.FindName("FinalFilename")
    
    $BrowseSource    = $window.FindName("BrowseSource")
    $BrowseSetup     = $window.FindName("BrowseSetup")
    $BrowseOutput    = $window.FindName("BrowseOutput")
    $BrowseTool      = $window.FindName("BrowseTool")
    
    $RunButton       = $window.FindName("RunButton")
    $ClearButton     = $window.FindName("ClearButton")
    $ExitButton      = $window.FindName("ExitButton")

    # When user types/pastes the source path manually, try to auto-suggest the setup file if found.
    $SourceFolder.Add_TextChanged({
        param($evtSender, $e)
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

    # Browse for Source Folder (dispose dialog via finally)
    $BrowseSource.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $SourceFolder.Text = $dialog.SelectedPath
                Set-SetupFromSource -SourcePath $dialog.SelectedPath -SetupFileControl $SetupFile -FinalFilenameControl $FinalFilename
            }
        } finally {
            $dialog.Dispose()
        }
    })

    # Browse for Setup File
    $BrowseSetup.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        try {
            $dialog.Filter = "Executable or MSI (*.exe;*.msi)|*.exe;*.msi"
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $selectedPath = $dialog.FileName
                $sourceRoot   = $SourceFolder.Text.Trim()

                if (-not [string]::IsNullOrWhiteSpace($sourceRoot) -and (Test-Path $sourceRoot)) {
                    try {
                        $relativePath = Get-RelativePath -BasePath $sourceRoot -TargetPath $selectedPath
                        if (-not ($relativePath.StartsWith(".."))) {
                            $SetupFile.Text = $relativePath
                        } else {
                            $SetupFile.Text = $selectedPath
                        }
                    } catch {
                        $SetupFile.Text = $selectedPath
                    }
                } else {
                    $SourceFolder.Text = Split-Path $selectedPath -Parent
                    $SetupFile.Text    = [System.IO.Path]::GetFileName($selectedPath)
                }
            }
        } finally {
            $dialog.Dispose()
        }
    })

    # Browse for Output Folder
    $BrowseOutput.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $OutputFolder.Text = $dialog.SelectedPath
            }
        } finally {
            $dialog.Dispose()
        }
    })

    # Browse for IntuneWinAppUtil.exe
    $BrowseTool.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        try {
            $dialog.Filter = "IntuneWinAppUtil.exe|IntuneWinAppUtil.exe"
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $ToolPathBox.Text = $dialog.FileName
                Show-ToolVersion -Path $dialog.FileName -Target $ToolVersionText
            }
        } finally {
            $dialog.Dispose()
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
        param($evtSender, $e)
        $p = $ToolPathBox.Text.Trim()
        if ($p) { Show-ToolVersion -Path $p -Target $ToolVersionText } else { Show-ToolVersion -Path $null -Target $ToolVersionText }
    })

    # If the user typed/pasted an absolute setup path before setting SourceFolder,
    # infer SourceFolder from that path and convert SetupFile to a relative file name.
    $SetupFile.Add_LostFocus({
        param($evtSender, $e)
        $sText = $SetupFile.Text.Trim()
        # Only act if SourceFolder is empty and SetupFile looks like an absolute existing path
        if ([string]::IsNullOrWhiteSpace($SourceFolder.Text) -and
            -not [string]::IsNullOrWhiteSpace($sText) -and
            [System.IO.Path]::IsPathRooted($sText) -and
            (Test-Path $sText)) {

            $SourceFolder.Text = Split-Path $sText -Parent
            $SetupFile.Text    = [System.IO.Path]::GetFileName($sText)
            # Note: SourceFolder.Text change will NOT override SetupFile because Set-SetupFromSource
            # early-returns if SetupFile already points to an existing file (absolute or relative).
        }
    })

    # Run button: validate inputs, run IntuneWinAppUtil.exe, rename output if needed
    $RunButton.Add_Click({
        $c = $SourceFolder.Text.Trim() # Source folder
        $s = $SetupFile.Text.Trim()    # Setup file (relative or absolute)
        $o = $OutputFolder.Text.Trim() # Output folder
        $f = $FinalFilename.Text.Trim()# Final filename

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

        # Launch IntuneWinAppUtil.exe
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

        if ($proc.ExitCode -ne 0) {
            [System.Windows.MessageBox]::Show(
                "IntuneWinAppUtil exited with code $($proc.ExitCode).",
                "Packaging failed", "OK", "Error"
            )
            return
        }

        # Wait for the output file to appear (up to 10 seconds)
        $defaultName = [System.IO.Path]::GetFileNameWithoutExtension($s) + ".intunewin"
        $defaultPath = Join-Path $o $defaultName

        $timeoutSec = 10
        $elapsed = 0
        while (-not (Test-Path $defaultPath) -and $elapsed -lt $timeoutSec) {
            Start-Sleep -Milliseconds 250
            $elapsed += 0.25
        }

        if (Test-Path $defaultPath) {
            # Build desired name from $f (if any), ensuring exactly one ".intunewin"
            if ([string]::IsNullOrWhiteSpace($f)) {
                $desiredName = (Split-Path $c -Leaf) + ".intunewin"
            } else {
                $extF  = [System.IO.Path]::GetExtension($f).ToLowerInvariant()
                $baseF = if ($extF -eq ".intunewin") { [System.IO.Path]::GetFileNameWithoutExtension($f) } else { $f }
                $desiredName = $baseF + ".intunewin"
            }

            $newName = $desiredName

            try {
                # Collision-safe rename (_1, _2, ...)
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($newName)
                $ext      = [System.IO.Path]::GetExtension($newName)
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

                if ($resp -eq [System.Windows.MessageBoxResult]::Yes) {
                    Start-Process explorer.exe "/select,`"$fullPath`""
                }

            } catch {
                [System.Windows.MessageBox]::Show("Renaming failed: $($_.Exception.Message)", "Warning", "OK", "Warning")
            }

        } else {
            [System.Windows.MessageBox]::Show(
                "Output file not found:`n$defaultPath",
                "Warning", "OK", "Warning"
            )
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
        param($evtSender, $e)
        switch ($e.Key) {
            'Escape' {
                if ([System.Windows.MessageBox]::Show("Exit the tool?", "Confirm", "YesNo", "Question") -eq [System.Windows.MessageBoxResult]::Yes) {
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
        try {
            if (-not (Test-Path (Split-Path $configPath))) {
                New-Item -Path (Split-Path $configPath) -ItemType Directory -Force | Out-Null
            }
            $cfg = @{ ToolPath = $ToolPathBox.Text.Trim() }
            $cfg | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
        } catch { }
    })

    # Set window icon if available
    if (Test-Path $iconPath) {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri $iconPath, [System.UriKind]::Absolute))
    }

    # Load PNG header icon without locking the file
    $HeaderIcon = $window.FindName('HeaderIcon')
    if ($HeaderIcon -and (Test-Path $iconPngPath)) {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.UriSource = [Uri]::new($iconPngPath, [UriKind]::Absolute)
        $bmp.EndInit()
        $HeaderIcon.Source = $bmp
    }

    # Hyperlink navigate handler (handles any Hyperlink in the XAML)
    $window.AddHandler(
        [System.Windows.Documents.Hyperlink]::RequestNavigateEvent,
        [System.Windows.Navigation.RequestNavigateEventHandler]{
            param($evtSender, $e)
            Start-Process $e.Uri.AbsoluteUri
            $e.Handled = $true
        }
    )
    
    # Show the window (modal)
    $window.ShowDialog() | Out-Null

    # Proactively release WPF/GDI/USER resources after window closes
    try {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
    } catch { }

    if ($Diag) {
        # Diagnostics: print handles/memory after the GUI closes
        try {
            $p2 = Get-Process -Id $PID
            Write-Verbose ("[Diagnostics/End]   Handles: {0}, GDI: {1}, WS: {2:N0} KB" -f $p2.HandleCount, $p2.GDIHandles, ($p2.WorkingSet64/1KB)) -Verbose
        } catch { }
    }
}

Export-ModuleMember -Function Show-IntuneWinAppUtilGUI
