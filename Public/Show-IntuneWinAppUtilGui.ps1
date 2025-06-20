# Show-Gui.ps1

function Show-IntuneWinAppUtilGui {
    [CmdletBinding()]
    param ()

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName System.Windows.Forms

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
    $FinalFilename = $window.FindName("FinalFilename")
    
    $BrowseSource = $window.FindName("BrowseSource")
    $BrowseSetup = $window.FindName("BrowseSetup")
    $BrowseOutput = $window.FindName("BrowseOutput")
    $BrowseTool = $window.FindName("BrowseTool")
    
    $RunButton = $window.FindName("RunButton")
    $ClearButton = $window.FindName("ClearButton")
    $ExitButton = $window.FindName("ExitButton")

    # Preload config.json if it exists
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.ToolPath -and (Test-Path $cfg.ToolPath)) {
                $ToolPathBox.Text = $cfg.ToolPath
            }
        } catch {}
    }

    # Eventi Browse
    $BrowseSource.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq 'OK') { $SourceFolder.Text = $dlg.SelectedPath }
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

    $BrowseOutput.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq 'OK') { $OutputFolder.Text = $dlg.SelectedPath }
    })

    $BrowseTool.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "IntuneWinAppUtil.exe|IntuneWinAppUtil.exe"
        if ($dlg.ShowDialog() -eq 'OK') { $ToolPathBox.Text = $dlg.FileName }
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
                    Add-Type -AssemblyName System.IO.Compression.FileSystem

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
                Rename-Item -Path $defaultPath -NewName $newName -Force
                $fullPath = Join-Path $o $newName
                $resp = [System.Windows.MessageBox]::Show("Package created and renamed to:`n$newName`n`nOpen folder?", "Success", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
                if ($resp -eq "Yes") { Start-Process explorer.exe "/select,`"$fullPath`"" }
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
