# Show-IntuneWinAppUtilGUI.ps1
# Show the main GUI window and handle all events.
function Show-IntuneWinAppUtilGUI {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Show diagnostic information")][switch] $Diag,
        [Parameter(Mandatory = $false, HelpMessage = "Show installed and latest module versions")][switch] $ShowVersion,
        [Parameter(Mandatory = $false, HelpMessage = "Force update banner for testing")][switch] $ForceUpdateBanner
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
        $cmd = "Import-Module `"$modulePath`"; Show-IntuneWinAppUtilGUI"
        foreach ($switchName in @('Diag', 'ShowVersion', 'ForceUpdateBanner', 'Debug', 'Verbose')) {
            if ($PSBoundParameters.ContainsKey($switchName)) { $cmd += " -$switchName" }
        }
        Start-Process $shell -ArgumentList @(
            '-NoProfile',
            '-STA',
            '-Command', $cmd
        ) -NoNewWindow | Out-Null
        return
    }

    # -Diag also writes a detailed log of every packaging run (read by Write-IwaDebugLog).
    $script:IwaDebugLogPath = $null
    if ($Diag) {
        try {
            $logDir = Join-Path $env:APPDATA 'IntuneWinAppUtilGUI\logs'
            New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            $script:IwaDebugLogPath = Join-Path $logDir ("diag-{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID)
            Write-Verbose "[Diagnostics] Log file: $script:IwaDebugLogPath" -Verbose
        } catch {
            Write-Warning "Unable to create the diagnostic log: $($_.Exception.Message)"
        }
        Write-IwaDebugLog ("Start: module {0}, PowerShell {1} ({2}), {3}, temp '{4}'" -f $MyInvocation.MyCommand.Module.Version, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [System.Environment]::OSVersion.VersionString, [System.IO.Path]::GetTempPath())

        # Diagnostics: print handles/memory when the GUI starts
        try {
            $p = Get-Process -Id $PID
            $diagLine = "[Diagnostics/Start] Handles: {0}, GDI: {1}, WS: {2:N0} KB" -f $p.HandleCount, $p.GDIHandles, ($p.WorkingSet64/1KB)
            Write-Verbose $diagLine -Verbose
            Write-IwaDebugLog $diagLine
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

    # Parse XAML (with the "Publish to Intune" tab injected) and get the main window
    $xaml   = Get-IwaMainWindowXaml -ModuleRoot $moduleRoot
    $window = [Windows.Markup.XamlReader]::Parse($xaml)

    # Grab controls
    $SourceFolder    = $window.FindName("SourceFolder")
    $SetupFile       = $window.FindName("SetupFile")
    $SetupFileHint   = $window.FindName("SetupFileHint")
    $OutputFolder    = $window.FindName("OutputFolder")
    $SourceFolderPathLength = $window.FindName("SourceFolderPathLength")
    $OutputFolderPathLength = $window.FindName("OutputFolderPathLength")
    $UpdateAvailableText = $window.FindName("UpdateAvailableText")

    $ToolPathBox     = $window.FindName("ToolPathBox")
    $ToolVersionText = $window.FindName("ToolVersionText")
    $DownloadTool    = $window.FindName("DownloadTool")
    $CheckToolUpdate = $window.FindName("CheckToolUpdate")
    
    $FinalFilename   = $window.FindName("FinalFilename")
    
    $BrowseSource    = $window.FindName("BrowseSource")
    $BrowseSetup     = $window.FindName("BrowseSetup")
    $BrowseOutput    = $window.FindName("BrowseOutput")
    $ClearRecentOutput = $window.FindName("ClearRecentOutput")
    $BrowseTool      = $window.FindName("BrowseTool")
    
    $RunButton       = $window.FindName("RunButton")

    $ProgressOverlay = $window.FindName("ProgressOverlay")
    $ProgressStep    = $window.FindName("ProgressStep")
    $ProgressBar     = $window.FindName("ProgressBar")
    $ProgressPercent = $window.FindName("ProgressPercent")

    # Packaging runs on the UI thread; while it runs, the overlay blocks mouse input and the UI is kept
    # responsive by letting the dispatcher render between steps. Busy blocks re-entry (Enter), Esc and closing.
    # CloseConfirmed: the user already agreed to stop a running Intune upload and close.
    $runState = [pscustomobject]@{ Busy = $false; CloseConfirmed = $false }
    # WPF "DoEvents": run a nested message loop until all pending work down to Background priority
    # (layout, rendering, input, UI Automation) has been processed.
    $pumpUi = {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $null = $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [System.Windows.Threading.DispatcherOperationCallback]{ param($f) $f.Continue = $false; $null },
            $frame)
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }
    $showProgress = {
        param([int]$Percent, [string]$Step)
        $ProgressOverlay.Visibility = [System.Windows.Visibility]::Visible
        $ProgressBar.Value = $Percent
        $ProgressPercent.Text = "$Percent%"
        $ProgressStep.Text = $Step
        & $pumpUi
    }
    $hideProgress = {
        $ProgressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
        $ProgressBar.Value = 0
        $ProgressPercent.Text = '0%'
    }

    # Result overlay: in-window replacement for the "Package created" message box.
    $ResultOverlay    = $window.FindName("ResultOverlay")
    $ResultFileName   = $window.FindName("ResultFileName")
    $ResultFolder     = $window.FindName("ResultFolder")
    $ResultNote       = $window.FindName("ResultNote")
    $ResultOpenFolder = $window.FindName("ResultOpenFolder")
    $ResultClose      = $window.FindName("ResultClose")
    $ResultCopyPath   = $window.FindName("ResultCopyPath")
    $resultState = [pscustomobject]@{ Path = $null }

    $showResult = {
        param([string]$PackagePath, [string]$Note)
        $resultState.Path = $PackagePath
        $ResultFileName.Text = Split-Path $PackagePath -Leaf
        $ResultFolder.Text = Split-Path $PackagePath -Parent
        $ResultNote.Text = $Note
        $ResultNote.Visibility = if ($Note) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        $copyPathFeedbackTimer.Stop()
        $ResultCopyPath.Content = 'Copy path'
        $ResultOverlay.Visibility = [System.Windows.Visibility]::Visible
        $null = $ResultOpenFolder.Focus()
        # Success sound from the user's Windows sound scheme (error message boxes already play their own).
        try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
    }
    $hideResult = {
        $ResultOverlay.Visibility = [System.Windows.Visibility]::Collapsed
        $resultState.Path = $null
    }
    $openResultFolder = {
        if ($resultState.Path) { Start-Process explorer.exe "/select,`"$($resultState.Path)`"" }
        & $hideResult
    }
    # Copy path: puts the final .intunewin path on the clipboard and briefly confirms it on the button.
    $copyPathFeedbackTimer = New-Object System.Windows.Threading.DispatcherTimer
    $copyPathFeedbackTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $copyPathFeedbackTimer.Add_Tick({
        $copyPathFeedbackTimer.Stop()
        $ResultCopyPath.Content = 'Copy path'
    })
    $copyResultPath = {
        if (-not $resultState.Path) { return }
        try {
            [System.Windows.Clipboard]::SetText($resultState.Path)
            $ResultCopyPath.Content = 'Copied!'
        } catch {
            # The clipboard can be locked by another process for a moment.
            Write-IwaDebugLog "Copy path failed: $($_.Exception.Message)"
            $ResultCopyPath.Content = 'Copy failed'
        }
        $copyPathFeedbackTimer.Stop()
        $copyPathFeedbackTimer.Start()
    }
    $ResultOpenFolder.Add_Click({ & $openResultFolder })
    $ResultCopyPath.Add_Click({ & $copyResultPath })
    $ResultClose.Add_Click({ & $hideResult })
    # Tabs: Package and Publish to Intune. The Package tab sets the window size, so it is only hidden.
    $TabPackage   = $window.FindName("TabPackage")
    $TabIntune    = $window.FindName("TabIntune")
    $PackagePanel = $window.FindName("PackagePanel")
    $IntunePanel  = $window.FindName("IntunePanel")
    . Initialize-IwaIntunePanel -IwaWindow $window -ModuleRoot $moduleRoot
    $showTab = {
        $intune = [bool]$TabIntune.IsChecked
        $PackagePanel.Visibility = if ($intune) { [System.Windows.Visibility]::Hidden } else { [System.Windows.Visibility]::Visible }
        $IntunePanel.Visibility = if ($intune) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        if ($intune) { & $iwaActivate }
    }
    $TabPackage.Add_Checked({ & $showTab })
    $TabIntune.Add_Checked({ & $showTab })

    # "Upload to Intune..." in the result panel: the Intune tab with the package just built.
    $ResultUploadIntune = $window.FindName("ResultUploadIntune")
    $openInIntuneTab = {
        param([string]$PackagePath)
        if ($runState.Busy) { return }
        # Same name/version the main window uses for the file name (PSADT, then MSI), not the PSADT launcher's own version.
        $appInfo = $null
        $version = $null
        if ($PackagePath -and $SourceFolder.Text) {
            try { $appInfo = Get-SetupAppInfo -SourcePath $SourceFolder.Text } catch { Write-IwaDebugLog "Reading the app info failed: $($_.Exception.Message)" }
        }
        if ($appInfo -and $appInfo.Version) {
            $version = $appInfo.Version
        } elseif ($PackagePath -and $SetupFile.Text) {
            $setupPath = if ([System.IO.Path]::IsPathRooted($SetupFile.Text)) { $SetupFile.Text } else { Join-Path $SourceFolder.Text $SetupFile.Text }
            if (Test-Path -LiteralPath $setupPath -PathType Leaf) {
                try { $version = Get-IntuneFileVersion -Path $setupPath } catch { Write-IwaDebugLog "Reading the setup version failed: $($_.Exception.Message)" }
            }
        }
        $appName = if ($appInfo) { [string]$appInfo.Name } else { '' }
        $appPublisher = if ($appInfo) { [string]$appInfo.Publisher } else { '' }
        $TabIntune.IsChecked = $true
        & $iwaOpenPackage $PackagePath $version $appName $appPublisher
    }
    $ResultUploadIntune.Add_Click({
        $packagePath = $resultState.Path
        & $hideResult
        & $openInIntuneTab $packagePath
    })
    $HelpButton      = $window.FindName("HelpButton")
    $ClearButton     = $window.FindName("ClearButton")
    $ExitButton      = $window.FindName("ExitButton")

    $PathLengthLimit = 260
    $DefaultSetupFileHint = "Valid MSI or EXE. PSADT packages are detected automatically; MSI metadata is used when script metadata is missing."

    Update-PathLengthIndicator -PathText $SourceFolder.Text -Indicator $SourceFolderPathLength -Limit $PathLengthLimit
    Update-PathLengthIndicator -PathText $OutputFolder.Text -Indicator $OutputFolderPathLength -Limit $PathLengthLimit

    # Updates the hint below the Setup File field: warns when the selected file isn't EXE/MSI,
    # since the Intune install command then needs to be adjusted to match it (e.g. a .ps1 script).
    $UpdateSetupFileHint = {
        param($Path)
        if (-not $SetupFileHint) { return }
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $SetupFileHint.Text = $DefaultSetupFileHint
            return
        }
        # GetExtension throws on a path with characters .NET rejects (e.g. a stray '"' while
        # mid-edit); since this handler runs on every keystroke, treat that as "no extension yet"
        # rather than letting it surface as an unhandled dispatcher error dialog.
        try {
            $ext = [System.IO.Path]::GetExtension($Path)
        } catch {
            $ext = ''
        }
        if ($ext -notin @('.exe', '.msi')) {
            # Extensionless files (e.g. "install") also need the warning: they aren't EXE/MSI either.
            $extLabel = if ($ext) { "'$ext'" } else { 'no extension' }
            $SetupFileHint.Text = "Note: $extLabel is not EXE/MSI. Make sure your install command in Intune matches this setup file."
        } else {
            $SetupFileHint.Text = $DefaultSetupFileHint
        }
    }

    $SetupFile.Add_TextChanged({
        param($evtSender, $e)
        & $UpdateSetupFileHint $SetupFile.Text.Trim()
    })

    # When user types/pastes the source path manually, try to auto-suggest the setup file if found.
    # The lookup (Get-SetupSuggestion) recurses the source folder, which can be slow on large/network
    # folders, so it is debounced (runs once typing pauses) AND run on a background job, so a slow scan
    # never freezes the window; only the resulting control updates are marshaled back to the UI thread.
    #
    # $sourceFolderScanState is a shared, mutable reference (not a scalar variable) so that both plain
    # event handlers and the .GetNewClosure()'d poll-timer handler below observe the same RequestId:
    # GetNewClosure() rebinds a scriptblock into its own dynamic module, where a plain "$script:" lookup
    # would resolve against that private module instead of this one, silently breaking invalidation.
    $sourceFolderScanState = [pscustomobject]@{ RequestId = 0 }
    # Each entry pairs a background job with the DispatcherTimer polling it, so cancelling can
    # stop the timer too. Leaving an orphaned timer running after its job is force-removed/disposed
    # made it poll a dead job object forever, throwing on the dispatcher thread on its next tick.
    $sourceFolderScanJobs = New-Object System.Collections.Generic.List[object]

    # Kills every scan still in flight and forgets it. Called whenever an edit makes their
    # in-progress results stale, so a slow/large-folder scan doesn't keep running (and consuming
    # a background PowerShell process) after it can no longer be applied.
    $sourceFolderScanCancelAll = {
        foreach ($activeScan in $sourceFolderScanJobs.ToArray()) {
            try { $activeScan.Timer.Stop() } catch {}
            try { Remove-Job $activeScan.Job -Force -ErrorAction SilentlyContinue } catch {}
        }
        $sourceFolderScanJobs.Clear()
    }

    $sourceFolderScanTimer = New-Object System.Windows.Threading.DispatcherTimer
    $sourceFolderScanTimer.Interval = [TimeSpan]::FromMilliseconds(350)
    $sourceFolderScanTimer.Add_Tick({
        $sourceFolderScanTimer.Stop()
        $src = $SourceFolder.Text.Trim()
        if (-not $src) { return }

        $sourceFolderScanState.RequestId++
        $requestId = $sourceFolderScanState.RequestId
        $currentSetupFile = $SetupFile.Text
        $currentFinalFilename = $FinalFilename.Text

        $job = Start-Job -ArgumentList $moduleRoot, $src, $currentSetupFile, $currentFinalFilename -ScriptBlock {
            param($moduleRoot, $src, $currentSetupFile, $currentFinalFilename)
            $helperPath = Join-Path $moduleRoot 'Private\IWAPG-Hlp-Setup.ps1'
            if (-not (Test-Path $helperPath)) { return $null }
            # A fresh job process hasn't loaded PresentationFramework, but the helper file also
            # defines Set-SetupFromSource, whose param block references [System.Windows.Controls.TextBox];
            # without this, dot-sourcing fails before Get-SetupSuggestion can be defined.
            Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
            . $helperPath
            Get-SetupSuggestion -SourcePath $src -CurrentSetupFile $currentSetupFile -CurrentFinalFilename $currentFinalFilename
        }
        $pollTimer = New-Object System.Windows.Threading.DispatcherTimer
        $scanEntry = [pscustomobject]@{ Job = $job; Timer = $pollTimer }
        $sourceFolderScanJobs.Add($scanEntry)

        # GetNewClosure() below only reaches variables local to THIS scope (one level up from the
        # closure) — it does not walk further up into the enclosing function's scope. Without these
        # aliases, $sourceFolderScanJobs/$sourceFolderScanState/$SetupFile/$FinalFilename would all
        # resolve to $null inside the poll-timer closure.
        $scanJobsRef = $sourceFolderScanJobs
        $scanStateRef = $sourceFolderScanState
        $setupFileRef = $SetupFile
        $finalFilenameRef = $FinalFilename

        $pollTimer.Interval = [TimeSpan]::FromMilliseconds(100)
        $pollTimer.Add_Tick({
            try {
                if ($job.State -notin @('Completed', 'Failed', 'Stopped')) { return }
            } catch {
                # Job was force-removed/disposed elsewhere (e.g. cancelAll raced this tick); stop polling it.
                $pollTimer.Stop()
                return
            }
            $pollTimer.Stop()
            $suggestion = $null
            try { $suggestion = Receive-Job $job -ErrorAction SilentlyContinue } catch {}
            try { Remove-Job $job -Force -ErrorAction SilentlyContinue } catch {}
            $scanJobsRef.Remove($scanEntry) | Out-Null

            # Discard results from a scan superseded by newer typing.
            if ($suggestion -and $requestId -eq $scanStateRef.RequestId) {
                if ($suggestion.SetupFile -is [string]) { $setupFileRef.Text = $suggestion.SetupFile }
                if ($suggestion.FinalFilename -is [string]) { $finalFilenameRef.Text = $suggestion.FinalFilename }
            }
        }.GetNewClosure())
        $pollTimer.Start()
    })

    $SourceFolder.Add_TextChanged({
        param($evtSender, $e)
        Update-PathLengthIndicator -PathText $SourceFolder.Text -Indicator $SourceFolderPathLength -Limit $PathLengthLimit
        # Invalidate (and kill) any scan already in flight: its result was computed against the
        # old inputs and must not overwrite what the user is typing now.
        $sourceFolderScanState.RequestId++
        & $sourceFolderScanCancelAll
        $sourceFolderScanTimer.Stop()
        $sourceFolderScanTimer.Start()
    })

    # Cancel the pending auto-detect scan if the user starts editing Setup File manually,
    # so it doesn't overwrite their in-progress edit once the timer fires. Also invalidates
    # (and kills) any scan already running, so its result can't clobber this manual edit either.
    $SetupFile.Add_TextChanged({
        param($evtSender, $e)
        $sourceFolderScanState.RequestId++
        & $sourceFolderScanCancelAll
        $sourceFolderScanTimer.Stop()
    })

    # Editing Final Filename manually must also invalidate (and kill) an in-flight scan, so it
    # can't overwrite this field once the scan completes.
    $FinalFilename.Add_TextChanged({
        param($evtSender, $e)
        $sourceFolderScanState.RequestId++
        & $sourceFolderScanCancelAll
    })

    $updateCheckEnabled = $true

    # Recent output folders live in the OutputFolder drop-down; the field text is kept when the list changes.
    $setRecentOutputFolders = {
        param([string[]]$Folders)
        $currentText = $OutputFolder.Text
        $OutputFolder.Items.Clear()
        foreach ($folder in $Folders) { $null = $OutputFolder.Items.Add($folder) }
        $OutputFolder.Text = $currentText
        $ClearRecentOutput.IsEnabled = $OutputFolder.Items.Count -gt 0
    }
    $saveConfig = {
        if (-not (Test-Path (Split-Path $configPath))) {
            New-Item -Path (Split-Path $configPath) -ItemType Directory -Force | Out-Null
        }
        $cfg = @{
            ToolPath = $ToolPathBox.Text.Trim()
            UpdateCheckEnabled = $updateCheckEnabled
            RecentOutputFolders = @($OutputFolder.Items | ForEach-Object { [string]$_ })
        }
        $cfg | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
    }
    & $setRecentOutputFolders @()

    # Preload config.json if it exists
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.ToolPath -and (Test-Path $cfg.ToolPath)) {
                $ToolPathBox.Text = $cfg.ToolPath
                Show-ToolVersion -Path $cfg.ToolPath -Target $ToolVersionText
            }
            if ($null -ne $cfg.UpdateCheckEnabled) {
                $updateCheckEnabled = [bool]$cfg.UpdateCheckEnabled
            }
            # Missing folders are kept: Run recreates the output folder when it does not exist.
            & $setRecentOutputFolders (Get-IwaRecentFolderList -Recent @($cfg.RecentOutputFolders | Where-Object { $_ -is [string] }))
        } catch {}
    }

    # Browse for Source Folder (dispose dialog via finally)
    $BrowseSource.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $SourceFolder.Text = $dialog.SelectedPath
            }
        } finally {
            $dialog.Dispose()
        }
    })

    $updateCheckJob = $null
    $updateCheckTimer = $null

    $shouldCheckUpdates = ($updateCheckEnabled -or $ShowVersion) -and $UpdateAvailableText

    if ($shouldCheckUpdates) {
        $currentVersion = $MyInvocation.MyCommand.Module.Version
        $modulePath = $MyInvocation.MyCommand.Module.Path
        $moduleName = 'IntuneWinAppUtilGUI'
        $timeoutSeconds = 10

        if ($ForceUpdateBanner) {
            $UpdateAvailableText.Text = "Update available: test banner (run 'Update-Module IntuneWinAppUtilGUI' in your PowerShell session)"
            $UpdateAvailableText.Visibility = [System.Windows.Visibility]::Visible
        } elseif ($ShowVersion) {
            $UpdateAvailableText.Text = "Installed: $currentVersion | Latest: checking..."
            $UpdateAvailableText.Visibility = [System.Windows.Visibility]::Visible
        }

        $updateCheckJob = Start-Job -ArgumentList $modulePath, $moduleName, $currentVersion, $timeoutSeconds, [bool]$ShowVersion -ScriptBlock {
            param($modulePath, $moduleName, $currentVersion, $timeoutSeconds, $showVersion)
            $moduleRoot = Split-Path $modulePath -Parent
            $helperPath = Join-Path $moduleRoot 'Private\IWAPG-Hlp-UpdateCheck.ps1'
            if (Test-Path $helperPath) {
                . $helperPath
            } else {
                if ($showVersion) {
                    return [PSCustomObject]@{
                        Current = $currentVersion
                        Latest  = $null
                        Error   = "Helper not found: $helperPath"
                    }
                }
                return $null
            }
            $result = Get-PowerShellGalleryModuleVersion -ModuleName $moduleName -TimeoutSeconds $timeoutSeconds -Detailed
            $latest = $result.Latest
            $errMsg = $result.Error
            if ($showVersion) {
                return [PSCustomObject]@{
                    Current = $currentVersion
                    Latest  = $latest
                    Error   = $errMsg
                }
            }
            if ($latest -and ($latest -gt $currentVersion)) { return $latest }
        }

        $updateCheckTimer = New-Object System.Windows.Threading.DispatcherTimer
        $updateCheckTimer.Interval = [TimeSpan]::FromMilliseconds(300)
        $updateCheckTimer.Add_Tick({
            if (-not $updateCheckJob) { $updateCheckTimer.Stop(); return }
            if ($updateCheckJob.State -in @('Completed','Failed','Stopped')) {
                $updateCheckTimer.Stop()
                $latest = $null
                try { $latest = Receive-Job $updateCheckJob -ErrorAction SilentlyContinue } catch { }
                try { Remove-Job $updateCheckJob -Force -ErrorAction SilentlyContinue } catch { }
                $updateCheckJob = $null

                if ($ForceUpdateBanner) {
                    return
                } elseif ($ShowVersion) {
                    $latestText = if ($latest -and $latest.Latest) { $latest.Latest } else { 'unknown' }
                    if ($latest -and $latest.Error) {
                        $UpdateAvailableText.Text = "Installed: $($latest.Current) | Latest: $latestText (error: $($latest.Error))"
                    } else {
                        $UpdateAvailableText.Text = "Installed: $($latest.Current) | Latest: $latestText"
                    }
                    $UpdateAvailableText.Visibility = [System.Windows.Visibility]::Visible
                } elseif ($latest -is [version]) {
                    $UpdateAvailableText.Text = "Update available: $latest (run 'Update-Module IntuneWinAppUtilGUI' in your PowerShell session)"
                    $UpdateAvailableText.Visibility = [System.Windows.Visibility]::Visible
                }
            }
        })
        $updateCheckTimer.Start()
    }

    # Browse for Setup File
    $BrowseSetup.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        try {
            $dialog.Filter = "Executable or MSI (*.exe;*.msi)|*.exe;*.msi|Script files (*.ps1;*.bat;*.cmd)|*.ps1;*.bat;*.cmd|All files (*.*)|*.*"
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

    # ComboBox has no TextChanged event of its own; its editable text box raises it and it bubbles up.
    $OutputFolder.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [System.Windows.Controls.TextChangedEventHandler]{
        param($evtSender, $e)
        Update-PathLengthIndicator -PathText $OutputFolder.Text -Indicator $OutputFolderPathLength -Limit $PathLengthLimit
    })

    # Clear recent: empty the drop-down and save right away; the current field value stays.
    $ClearRecentOutput.Add_Click({
        & $setRecentOutputFolders @()
        try { & $saveConfig } catch { Write-IwaDebugLog "Saving config.json failed: $($_.Exception.Message)" }
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

    # Dialog overlay: in-window replacement for message boxes. Kind sets the icon (Info, Success, Question, Error).
    # With PrimaryText the dialog asks a question: OnPrimary runs (with Argument) only when the user confirms.
    $DialogOverlay   = $window.FindName("DialogOverlay")
    $DialogIcon      = $window.FindName("DialogIcon")
    $DialogIconText  = $window.FindName("DialogIconText")
    $DialogTitle     = $window.FindName("DialogTitle")
    $DialogMessage   = $window.FindName("DialogMessage")
    $DialogDetails   = $window.FindName("DialogDetails")
    $DialogPrimary   = $window.FindName("DialogPrimary")
    $DialogSecondary = $window.FindName("DialogSecondary")
    $dialogState = [pscustomobject]@{ OnPrimary = $null; Argument = $null }
    $dialogKinds = @{
        Info     = @('i', '#0B6BD3')
        Success  = @([string][char]0x2713, '#16A34A')
        Question = @('?', '#0B6BD3')
        Error    = @('!', '#DC2626')
    }
    $showDialog = {
        param([string]$Kind, [string]$Title, [string]$Message, [string]$Details, [string]$PrimaryText, [scriptblock]$OnPrimary, $Argument)
        $icon = $dialogKinds[$Kind]
        $DialogIconText.Text = $icon[0]
        $DialogIcon.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($icon[1])
        $DialogTitle.Text = $Title
        $DialogMessage.Text = $Message
        $DialogDetails.Text = $Details
        $DialogDetails.Visibility = if ($Details) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        $dialogState.OnPrimary = $OnPrimary
        $dialogState.Argument = $Argument
        $DialogOverlay.Visibility = [System.Windows.Visibility]::Visible
        if ($PrimaryText) {
            $DialogPrimary.Content = $PrimaryText
            $DialogPrimary.Visibility = [System.Windows.Visibility]::Visible
            $DialogSecondary.Content = 'Cancel'
            $null = $DialogPrimary.Focus()
        } else {
            $DialogPrimary.Visibility = [System.Windows.Visibility]::Collapsed
            $DialogSecondary.Content = 'Close'
            $null = $DialogSecondary.Focus()
        }
        if ($Kind -eq 'Error') { try { [System.Media.SystemSounds]::Hand.Play() } catch { } }
    }
    $hideDialog = {
        $DialogOverlay.Visibility = [System.Windows.Visibility]::Collapsed
        $dialogState.OnPrimary = $null
        $dialogState.Argument = $null
    }
    # Hide first: the action may open another dialog (e.g. the download result).
    $confirmDialog = {
        $action = $dialogState.OnPrimary
        $argument = $dialogState.Argument
        & $hideDialog
        if ($action) { & $action $argument }
    }
    $DialogPrimary.Add_Click({ & $confirmDialog })
    $DialogSecondary.Add_Click({ & $hideDialog })

    # Downloads IntuneWinAppUtil.exe into the local bin folder and selects it: from the given release ZIP,
    # or from the default (master branch) when none is given.
    $downloadToolNow = {
        param([string]$ZipUrl)
        $window.Cursor = [System.Windows.Input.Cursors]::Wait
        & $pumpUi
        try {
            $downloadArgs = @{}
            if ($ZipUrl) { $downloadArgs.RepoZipUrl = $ZipUrl }
            $newPath = Invoke-DownloadIntuneTool @downloadArgs
            $ToolPathBox.Text = $newPath
            Show-ToolVersion -Path $newPath -Target $ToolVersionText
            $window.Cursor = $null
            & $showDialog -Kind Success -Title 'Download complete' -Message 'IntuneWinAppUtil.exe has been downloaded and selected.' -Details $newPath
        } catch {
            $window.Cursor = $null
            & $showDialog -Kind Error -Title 'Download failed' -Message $_.Exception.Message
        }
    }

    # Force download the IntuneWinAppUtil.exe tool
    $DownloadTool.Add_Click({
        & $showDialog -Kind Question -Title 'Refresh IntuneWinAppUtil.exe' `
            -Message 'Download the latest IntuneWinAppUtil.exe now?' `
            -Details 'If a cached copy already exists in the local bin folder, it will be replaced.' `
            -PrimaryText 'Download' -OnPrimary $downloadToolNow
    })

    # Check for updates: compares the selected IntuneWinAppUtil.exe with the latest release
    # (Tools/IntuneWinAppUtilVersions.json in this repository) and offers the download only when needed.
    $CheckToolUpdate.Add_Click({
        $toolPath = $ToolPathBox.Text.Trim()
        $installed = if ($toolPath -and (Test-Path -LiteralPath $toolPath -PathType Leaf)) { Get-ExeVersion -Path $toolPath } else { $null }

        $window.Cursor = [System.Windows.Input.Cursors]::Wait
        try {
            $latest = Get-IntuneWinAppUtilLatestVersion
        } catch {
            $window.Cursor = $null
            & $showDialog -Kind Error -Title 'Check for updates' -Message "Unable to check for updates: $($_.Exception.Message)"
            return
        }
        $window.Cursor = $null

        $latestText = "Latest: $($latest.FileVersion) (release $($latest.Release))"
        if (-not (Test-IntuneWinAppUtilUpdateAvailable -InstalledVersion $installed -LatestVersion $latest.FileVersion)) {
            & $showDialog -Kind Success -Title 'IntuneWinAppUtil.exe is up to date' -Message "Installed: $installed`n$latestText"
            return
        }

        $current = if ($installed) { "Installed: $installed" } else { 'No IntuneWinAppUtil.exe selected, or its version cannot be read.' }
        # The release just advertised, not the master branch: the two can contain different binaries.
        & $showDialog -Kind Info -Title 'Update available' -Message "$current`n$latestText" `
            -Details 'The new version is saved in the local bin folder and selected here.' `
            -PrimaryText 'Download' -OnPrimary $downloadToolNow -Argument (Get-IntuneWinAppUtilReleaseZipUrl -Release $latest.Release)
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
    $runPackaging = {
        $c = $SourceFolder.Text.Trim() # Source folder
        $s = $SetupFile.Text.Trim()    # Setup file (relative or absolute)
        $o = $OutputFolder.Text.Trim() # Output folder
        $f = $FinalFilename.Text.Trim()# Final filename

        # Clean FinalFilename from invalid chars
        $f = -join ($f.ToCharArray() | Where-Object { [System.IO.Path]::GetInvalidFileNameChars() -notcontains $_ })

        # Validate source folder
        if (-not (Test-Path $c)) { [System.Windows.MessageBox]::Show("Invalid source folder path.", "Error", "OK", "Error"); return }
        
        # Validate setup file
        if (-not $s) { [System.Windows.MessageBox]::Show("Setup file not found.", "Error", "OK", "Error"); return }
        if (-not (Test-Path $s -PathType Leaf)) {
            $s = Join-Path $c $s
            if (-not (Test-Path $s -PathType Leaf)) { [System.Windows.MessageBox]::Show("Setup file not found.", "Error", "OK", "Error"); return }
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

        $runStart = Get-Date
        Write-IwaDebugLog "Run: source '$c', setup '$s', output '$o', final filename '$f'"
        & $showProgress 1 'Checking the source folder'

        $pathWarnings = @()
        if ($c.Length -gt $PathLengthLimit) { $pathWarnings += "Source folder: $($c.Length)/$PathLengthLimit" }
        $maxFileInfo = Get-MaxFilePathInfo -RootPath $c -OnProgress $pumpUi
        if ($null -ne $maxFileInfo -and $maxFileInfo.Length -gt $PathLengthLimit) {
            $pathWarnings += "Max file path in source: $($maxFileInfo.Length)/$PathLengthLimit"
            $pathWarnings += "Longest path: $($maxFileInfo.Path)"
        }
        if ($o.Length -gt $PathLengthLimit) { $pathWarnings += "Output folder: $($o.Length)/$PathLengthLimit" }
        if ($pathWarnings.Count -gt 0) {
            Write-IwaDebugLog ("Path length warnings:`n" + ($pathWarnings -join "`n"))
            $msg = "Some paths exceed the recommended $PathLengthLimit character limit.`n`n" +
                   ($pathWarnings -join "`n") +
                   "`n`nIntuneWinAppUtil may fail on Windows when paths are too long.`n`nContinue packaging anyway?"
            $confirm = [System.Windows.MessageBox]::Show(
                $window,
                $msg,
                "Path length warning",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
        }

        # IntuneWinAppUtil.exe path check (or initialize/download if not set)
        & $showProgress 1 'Preparing IntuneWinAppUtil'
        $toolPath = Initialize-IntuneWinAppUtil -UiToolPath ($ToolPathBox.Text.Trim())

        Write-IwaDebugLog ("Tool: '{0}', version {1}" -f $toolPath, $(if ($toolPath) { Get-ExeVersion -Path $toolPath }))
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
        
        # Package into a new, empty staging folder, then publish the finished file to the output folder,
        # so sync clients (Dropbox, OneDrive) never see a partial package. The staging folder is normally
        # under %TEMP%; if the temp volume lacks space (see below) it goes to the root of the output volume,
        # outside any synchronized folder, or as a last resort to a hidden subfolder of the output folder.
        $runId = [guid]::NewGuid().ToString('N')
        $tempRoot = [System.IO.Path]::GetTempPath()
        $stagingDir = Join-Path $tempRoot "IntuneWinAppUtilGUI-$runId"
        $stagingInTemp = $true
        try {
            $tempFree = ([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($tempRoot))).AvailableFreeSpace
            $sourceBytes = if ($maxFileInfo) { $maxFileInfo.TotalBytes } else { 0 }   # from the path-length scan above
            # IntuneWinAppUtil keeps its own zip and encrypted copy under %TEMP% while writing the
            # package, so staging needs room for about three source-sized files (incompressible worst case).
            if ($tempFree -lt (3 * $sourceBytes + 100MB)) {
                $stagingDir = Join-Path ([System.IO.Path]::GetPathRoot($o)) "IntuneWinAppUtilGUI-staging-$runId"
                $stagingInTemp = $false
            }
        } catch {
            # Free space unknown (e.g. temp on a UNC path): keep staging in %TEMP%.
        }

        try {
            $stagingItem = $null
            try {
                $stagingItem = New-Item -Path $stagingDir -ItemType Directory -Force -ErrorAction Stop
            } catch {
                if ($stagingInTemp) { throw }
                # Volume root not writable (or a share root): last resort, hidden subfolder of the output folder.
                $stagingDir = Join-Path $o "~iwa-staging-$runId"
                $stagingItem = New-Item -Path $stagingDir -ItemType Directory -Force -ErrorAction Stop
                $stagingItem.Attributes = $stagingItem.Attributes -bor [System.IO.FileAttributes]::Hidden
            }
        } catch {
            [System.Windows.MessageBox]::Show("Unable to create the staging folder:`n$stagingDir`n`n$($_.Exception.Message)", "Error", "OK", "Error")
            return
        }
        $packageDir = $stagingDir
        Write-IwaDebugLog ("Staging folder: '{0}' ({1}); temp free {2:N0} MB, source {3:N0} MB" -f $stagingDir, $(if ($stagingInTemp) { 'temp' } else { 'output volume' }), ($tempFree / 1MB), ($sourceBytes / 1MB))

        # Build a single, properly-quoted argument string
        # -c = source folder, -s = setup file, -o = staging folder.
        # -q avoids an "overwrite existing output (Y/N)?" prompt the hidden tool could not show;
        # nothing can be overwritten because the staging folder is new and empty.
        $iwaArgs = ('-c "{0}" -s "{1}" -o "{2}" -q' -f $c, $s, $stagingDir)

        # Launch IntuneWinAppUtil.exe without its own console window, capturing its output: started in a
        # new console window, the tool can fail with 0x80070005 (access denied) while replacing its
        # temporary package, a failure that does not occur with redirected output.
        $toolOut = Join-Path $tempRoot "IntuneWinAppUtilGUI-$runId.out.txt"
        $toolErr = Join-Path $tempRoot "IntuneWinAppUtilGUI-$runId.err.txt"
        Write-IwaDebugLog "Command: `"$toolPath`" $iwaArgs"
        try {
            $proc = Start-Process -FilePath $toolPath `
                -ArgumentList $iwaArgs `
                -WorkingDirectory (Split-Path $toolPath) `
                -NoNewWindow `
                -RedirectStandardOutput $toolOut `
                -RedirectStandardError $toolErr `
                -PassThru
        } catch {
            Write-IwaDebugLog "Failed to start the tool: $($_.Exception.Message)"
            Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
            [System.Windows.MessageBox]::Show(
                "Failed to start IntuneWinAppUtil.exe:`n$($_.Exception.Message)",
                "Execution error", "OK", "Error"
            )
            return
        }
        # Wait for the tool while updating the progress overlay from its output.
        while (-not $proc.HasExited) {
            $progress = Get-IntuneWinAppUtilProgress -ToolOutput (Read-SharedTextFile -Path $toolOut)
            & $showProgress $progress.Percent $progress.Step
            Start-Sleep -Milliseconds 150
        }
        $proc.WaitForExit()

        $toolOutput = ''
        foreach ($stream in @($toolOut, $toolErr)) {
            $content = Get-Content -LiteralPath $stream -Raw -ErrorAction SilentlyContinue
            if ($content) { $toolOutput += $content.TrimEnd() + "`n" }
            Remove-Item -LiteralPath $stream -Force -ErrorAction SilentlyContinue
        }

        if ($script:IwaDebugLogPath) {
            Write-IwaDebugLog ("Tool exit code: {0} (0x{0:X8})" -f $proc.ExitCode)
            if ($toolOutput) { Write-IwaDebugLog ("Tool output:`n" + $toolOutput.TrimEnd()) }
            # Only the staging folder: the output folder may hold many unrelated files.
            if ($proc.ExitCode -ne 0) { Write-IwaDebugFileState -Since $runStart -Folder $stagingDir }
        }

        # On success, remove the working folder this run of the tool may leave in %TEMP%
        # (kept on failure for troubleshooting). Its path is read from the tool's own output.
        if ($proc.ExitCode -eq 0) {
            $toolWork = Get-IntuneWinAppUtilWorkFolder -ToolOutput $toolOutput
            if ($toolWork -and (Test-Path -LiteralPath $toolWork)) {
                Remove-Item -LiteralPath $toolWork -Recurse -Force -ErrorAction SilentlyContinue
                Write-IwaDebugLog ("Removed tool work folder '{0}': {1}" -f $toolWork, (-not (Test-Path -LiteralPath $toolWork)))
            }
        }

        if ($proc.ExitCode -ne 0) {
            if ($stagingDir) { Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
            $failMsg = Get-IntuneWinAppUtilExitMessage -ExitCode $proc.ExitCode
            $lastLines = @($toolOutput -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 8)
            if ($lastLines.Count) { $failMsg += "`n`nLast lines of the tool output:`n" + ($lastLines -join "`n") }
            & $hideProgress
            [System.Windows.MessageBox]::Show($failMsg, "Packaging failed", "OK", "Error")
            return
        }

        # Wait for the output file to appear (up to 10 seconds)
        $defaultName = [System.IO.Path]::GetFileNameWithoutExtension($s) + ".intunewin"
        $defaultPath = Join-Path $packageDir $defaultName

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
                # Publish-IntuneWinPackage picks a free name (_1, _2, ...) if this one is taken.
                $fullPath = Join-Path $o $newName

                try {
                    & $showProgress 96 'Copying the package to the output folder'
                    # Staging in %TEMP%: copy-then-rename, since a cross-volume move would expose a partial
                    # final file. Fallback staging on the output volume: plain rename, because that volume
                    # may not have room for a second copy.
                    # shortcut: if the output folder is a junction/mount point to another volume, the fallback
                    # rename becomes a copy+delete; detect the backing volume if that setup ever matters.
                    $fullPath = Publish-IntuneWinPackage -Path $defaultPath -Destination $fullPath -CopyFirst:$stagingInTemp -OnProgress {
                        param($copied, $total)
                        & $showProgress (96 + [int](3 * $copied / [Math]::Max(1, $total))) 'Copying the package to the output folder'
                    }
                    $finalName = Split-Path $fullPath -Leaf
                } catch {
                    # Keep the staging folder: it holds the only copy of the package.
                    throw "Unable to move the package to '$fullPath' after several attempts. Last error: $($_.Exception.Message)`n`nThe package is still available at:`n$defaultPath"
                }

                if ($stagingDir) { Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
                Write-IwaDebugLog "Package created: '$fullPath'"

                & $showProgress 100 'Package created'
                & $hideProgress

                $note = if ($finalName -ne $newName) { "'$newName' already existed, so an incremental suffix was added." } else { $null }
                & $setRecentOutputFolders (Get-IwaRecentFolderList -Recent @($OutputFolder.Items | ForEach-Object { [string]$_ }) -Folder $o)
                try { & $saveConfig } catch { Write-IwaDebugLog "Saving config.json failed: $($_.Exception.Message)" }
                & $showResult $fullPath $note

            } catch {
                Write-IwaDebugLog "Moving the package failed: $($_.Exception.Message)"
                if ($script:IwaDebugLogPath) {
                    foreach ($pkgFile in @($defaultPath, $fullPath)) {
                        if ($pkgFile -and (Test-Path -LiteralPath $pkgFile)) {
                            Write-IwaDebugLog ("  {0} held by: {1}" -f $pkgFile, ((@(Get-FileLockingProcess -Path $pkgFile)) -join ', '))
                        }
                    }
                }
                & $hideProgress
                [System.Windows.MessageBox]::Show("Moving the package failed: $($_.Exception.Message)", "Warning", "OK", "Warning")
            }

        } else {
            Write-IwaDebugLog "Expected package not found: '$defaultPath'"
            Write-IwaDebugFileState -Since $runStart -Folder $stagingDir
            if ($stagingDir) { Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
            & $hideProgress
            [System.Windows.MessageBox]::Show(
                "IntuneWinAppUtil finished, but the expected package was not created:`n$defaultName",
                "Warning", "OK", "Warning"
            )
        }
    }

    $RunButton.Add_Click({
        if ($runState.Busy) { return }
        $runState.Busy = $true
        try {
            & $runPackaging
        } finally {
            & $hideProgress
            $runState.Busy = $false
        }
    })

    # Clear button: reset all except ToolPath if loaded from config
    $ClearButton.Add_Click({
        $SourceFolder.Clear()
        $SetupFile.Clear()
        $OutputFolder.Text = ''
        $FinalFilename.Clear()
    })

    # Help overlay: command-line switches and keyboard shortcuts (content in UI.xaml)
    $HelpOverlay = $window.FindName("HelpOverlay")
    $HelpClose   = $window.FindName("HelpClose")
    $hideHelp = { $HelpOverlay.Visibility = [System.Windows.Visibility]::Collapsed }
    $HelpButton.Add_Click({
        $HelpOverlay.Visibility = [System.Windows.Visibility]::Visible
        $null = $HelpClose.Focus()
    })
    $HelpClose.Add_Click({ & $hideHelp })

    # Exit button: close the window
    $ExitButton.Add_Click({
        $window.Close()
    })

    # Keyboard shortcuts: Esc to exit (with confirmation), Enter to run packaging
    $window.Add_KeyDown({
        param($evtSender, $e)
        if ($runState.Busy) { $e.Handled = $true; return }
        if ($ResultOverlay.Visibility -eq [System.Windows.Visibility]::Visible) {
            # Result overlay open: Enter opens the folder, Esc closes it; Tab moves between the panel
            # buttons (TabNavigation Cycle in UI.xaml). Nothing else reaches the form.
            if ($e.Key -eq 'Tab') { return }
            switch ($e.Key) {
                'Return' { & $openResultFolder }
                'Escape' { & $hideResult }
            }
            $e.Handled = $true
            return
        }
        if ($DialogOverlay.Visibility -eq [System.Windows.Visibility]::Visible) {
            # Dialog open: Enter confirms (or closes a message), Esc cancels. A focused button handles its own Enter.
            if ($e.Key -eq 'Tab') { return }
            switch ($e.Key) {
                'Return' { if ($DialogPrimary.Visibility -eq [System.Windows.Visibility]::Visible) { & $confirmDialog } else { & $hideDialog } }
                'Escape' { & $hideDialog }
            }
            $e.Handled = $true
            return
        }
        if ($ui.DoneOverlay.Visibility -eq [System.Windows.Visibility]::Visible) {
            # "App created/updated in Intune" open: Esc and Enter close it.
            if ($e.Key -eq 'Tab') { return }
            if ($e.Key -in 'Escape', 'Return') { $ui.DoneOverlay.Visibility = [System.Windows.Visibility]::Collapsed }
            $e.Handled = $true
            return
        }
        if ($HelpOverlay.Visibility -eq [System.Windows.Visibility]::Visible) {
            # Help open: Esc and Enter close it; nothing reaches the form behind it.
            if ($e.Key -eq 'Tab') { return }
            if ($e.Key -in 'Escape', 'Return') { & $hideHelp }
            $e.Handled = $true
            return
        }
        switch ($e.Key) {
            'Escape' {
                if (& $iwaUploadRunning) { & $confirmCloseDuringUpload; break }
                & $showDialog -Kind Question -Title 'Close IntuneWinAppUtil GUI?' `
                    -Message 'Current field values will not be kept, except the saved IntuneWinAppUtil path.' `
                    -PrimaryText 'Close' -OnPrimary { $window.Close() }
            }
            'Return' {
                # Only on the Package tab: Enter on the Intune tab must never start an upload or a packaging run.
                if ($TabPackage.IsChecked) {
                    $RunButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
                }
            }
        }
    })
    # Ctrl+Tab switches tab. Preview: focused controls would otherwise use it for keyboard navigation.
    $window.Add_PreviewKeyDown({
        param($evtSender, $e)
        if ($e.Key -ne 'Tab' -or -not ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { return }
        $overlayOpen = @($ResultOverlay, $DialogOverlay, $HelpOverlay, $ui.DoneOverlay) | Where-Object { $_.Visibility -eq [System.Windows.Visibility]::Visible }
        if ($runState.Busy -or $overlayOpen) { return }
        if ($TabPackage.IsChecked) { $TabIntune.IsChecked = $true } else { $TabPackage.IsChecked = $true }
        $e.Handled = $true
    })

    # Closing while an Intune upload runs: ask first, then stop the upload without waiting for it.
    $confirmCloseDuringUpload = {
        $TabIntune.IsChecked = $true
        & $showDialog -Kind Question -Title 'An upload is still running' `
            -Message 'Stop it and close IntuneWinAppUtil GUI?' `
            -Details 'If the app was just created, it stays in Intune without content.' `
            -PrimaryText 'Stop and close' -OnPrimary { $runState.CloseConfirmed = $true; $window.Close() }
    }

    # Do not close while packaging: the tool and the staging folder would be left behind.
    $window.Add_Closing({
        param($evtSender, $e)
        if ($runState.Busy) { $e.Cancel = $true; return }
        & $iwaReleaseFinishedUpload
        if (& $iwaUploadRunning) {
            if (-not $runState.CloseConfirmed) { $e.Cancel = $true; & $confirmCloseDuringUpload; return }
            & $iwaStopUpload
        }
    })

    # When the window is closed, save ToolPath, UpdateCheckEnabled and the recent output folders to config.json
    $window.Add_Closed({
        try {
            if ($updateCheckTimer) { $updateCheckTimer.Stop() }
            if ($updateCheckJob) { Remove-Job $updateCheckJob -Force -ErrorAction SilentlyContinue }
            if ($sourceFolderScanTimer) { $sourceFolderScanTimer.Stop() }
            if ($sourceFolderScanJobs) {
                foreach ($pendingScan in $sourceFolderScanJobs.ToArray()) {
                    try { $pendingScan.Timer.Stop() } catch {}
                    try { Remove-Job $pendingScan.Job -Force -ErrorAction SilentlyContinue } catch {}
                }
                $sourceFolderScanJobs.Clear()
            }
            & $saveConfig
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
            $diagLine = "[Diagnostics/End]   Handles: {0}, GDI: {1}, WS: {2:N0} KB" -f $p2.HandleCount, $p2.GDIHandles, ($p2.WorkingSet64/1KB)
            Write-Verbose $diagLine -Verbose
            Write-IwaDebugLog $diagLine
        } catch { }
    }
}

Export-ModuleMember -Function Show-IntuneWinAppUtilGUI, Get-IntuneFileVersion
