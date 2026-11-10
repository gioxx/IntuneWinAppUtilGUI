# IWAPG-Hlp-IntuneWindow.ps1
# "Publish to Intune" window: create or update a Win32 app from a .intunewin package.

$script:IwaV1Limitations = 'Not handled here yet: assignments, icon, supersedence, dependencies, custom return codes (Intune defaults are used). Use "Open in Intune" to set them in the portal.'

function Get-IwaIntuneWindowControlName {
    @(
        'ModeNew', 'ModeUpdate', 'AccountText', 'InstallGraphButton', 'SignInButton', 'GraphStatusText', 'LimitsText',
        'FormPanel', 'SearchPanel', 'SearchBox', 'SearchButton', 'SearchResults',
        'PackagePath', 'BrowsePackage', 'UploadContent',
        'DisplayName', 'Publisher', 'DisplayVersion', 'Description',
        'InstallCommandLine', 'UninstallCommandLine', 'RunAsAccount', 'DeviceRestartBehavior', 'MaxRunTimeInMinutes',
        'ArchX64', 'ArchX86', 'ArchArm64', 'MinimumWindowsRelease',
        'RulesList', 'RemoveRuleButton', 'NewRuleType', 'MsiRulePanel', 'RuleProductCode',
        'FileRulePanel', 'RuleFilePath', 'RuleFileName', 'RuleFileOperation', 'RuleFileValue', 'RuleFile32Bit',
        'RegistryRulePanel', 'RuleKeyPath', 'RuleValueName', 'RuleRegOperation', 'RuleRegValue', 'RuleReg32Bit',
        'ScriptRulePanel', 'RuleScriptPath', 'BrowseScript', 'RuleScriptRunAs32', 'RuleScriptSignature',
        'AddRuleButton', 'RuleErrorText',
        'ValidationText', 'StatusText', 'ProgressPanel', 'ProgressText', 'UploadProgress',
        'OpenInIntune', 'RetryUploadButton', 'UploadButton', 'CloseButton'
    )
}

function Get-IwaIntuneWindowXaml {
    <#
    .SYNOPSIS
    Returns IntuneWindow.xaml with the styles of UI.xaml injected, so both windows share one style source.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModuleRoot)

    $main = Get-Content -LiteralPath (Join-Path $ModuleRoot 'UI\UI.xaml') -Raw
    $resources = [regex]::Match($main, '(?s)<Window\.Resources>.*?</Window\.Resources>')
    if (-not $resources.Success) { throw 'Window.Resources not found in UI.xaml.' }
    (Get-Content -LiteralPath (Join-Path $ModuleRoot 'UI\IntuneWindow.xaml') -Raw).Replace('<!-- SHARED_RESOURCES -->', $resources.Value)
}

# Runs in a second runspace of the same process, so it shares the Connect-MgGraph sign-in
# (checked by Tools/Test-IwaGraphSpike.ps1). Reports through the synchronized $State hashtable.
$script:IwaIntuneTaskScript = {
    param($State, $ModuleRoot, $Body, $Package)
    $ErrorActionPreference = 'Stop'
    $work = $null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        foreach ($helper in @('IWAPG-Hlp-IntunePackage.ps1', 'IWAPG-Hlp-IntuneGraph.ps1')) {
            . (Join-Path $ModuleRoot "Private\$helper")
        }
        Import-Module Microsoft.Graph.Authentication

        if (-not $State.AppId) {
            $State.Step = 'Creating the app in Intune'
            $State.AppId = (Invoke-IwaGraph -Method POST -Uri $script:IwaGraphAppsUri -Body $Body).id
            $State.Saved = $true
        } elseif ($Body) {
            $State.Step = 'Saving the app settings'
            Invoke-IwaGraph -Method PATCH -Uri "$script:IwaGraphAppsUri/$($State.AppId)" -Body $Body | Out-Null
            $State.Saved = $true
        }

        if ($Package) {
            $State.Step = 'Extracting the encrypted content'
            $work = Join-Path ([System.IO.Path]::GetTempPath()) ('IwaUpload-' + [guid]::NewGuid())
            $content = Expand-IwaIntuneWinContent -Package $Package -Destination $work
            $State.Step = 'Uploading the content'
            Publish-IwaWin32AppContent -AppId $State.AppId -Package $Package -ContentFile $content -OnProgress {
                param($sent, $total)
                $State.Percent = [int](100 * $sent / [Math]::Max(1, $total))
                $State.Step = 'Uploading the content ({0:N0} of {1:N0} MB)' -f ($sent / 1MB), ($total / 1MB)
            } | Out-Null
        }
        $State.Done = $true
    } catch {
        $State.Error = if (Get-Command Get-IwaGraphErrorMessage -ErrorAction SilentlyContinue) { Get-IwaGraphErrorMessage -ErrorRecord $_ } else { $_.Exception.Message }
    } finally {
        if ($work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Show-IwaIntuneWindow {
    <#
    .SYNOPSIS
    Opens the "Publish to Intune" window (modal) for a new or an existing Win32 app.
    #>
    [CmdletBinding()]
    param(
        $Owner,
        [Parameter(Mandatory)][string]$ModuleRoot,
        [string]$PackagePath,
        [string]$DisplayVersion
    )

    $win = [Windows.Markup.XamlReader]::Parse((Get-IwaIntuneWindowXaml -ModuleRoot $ModuleRoot))
    if ($Owner) { $win.Owner = $Owner }
    $ui = @{}
    foreach ($name in Get-IwaIntuneWindowControlName) { $ui[$name] = $win.FindName($name) }

    # Handlers run in this scope while ShowDialog() is open, but an assignment inside a handler
    # creates a local variable: every value a handler changes lives in $state.
    $state = @{
        Package = $null; DisplayVersion = $DisplayVersion; AppId = $null; Account = $null
        Rules = New-Object System.Collections.ArrayList
        SearchResults = @(); LoadedApp = $null; Task = $null
        Busy = $false; Loading = $false; LoadingResults = $false; KeepAppId = $false; LastUpload = $false
        InstallError = $null; SignInError = $null; SearchError = $null; LoadError = $null
    }
    $errorBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xC0, 0x39, 0x2B))
    $successBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x1E, 0x7B, 0x34))
    $visible = [System.Windows.Visibility]::Visible
    $collapsed = [System.Windows.Visibility]::Collapsed
    $fieldControls = @('DisplayName', 'Publisher', 'Description', 'InstallCommandLine', 'UninstallCommandLine', 'MaxRunTimeInMinutes', 'PackagePath', 'RulesList')

    $ui.LimitsText.Text = $script:IwaV1Limitations
    foreach ($release in $script:IwaWindowsReleases) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $release
        $item.Tag = $release
        [void]$ui.MinimumWindowsRelease.Items.Add($item)
    }

    # --- Helpers ------------------------------------------------------------------------------
    $doEvents = {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $null = $win.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [System.Windows.Threading.DispatcherOperationCallback]{ param($f) $f.Continue = $false; $null },
            $frame)
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }
    # shortcut: sign-in, install, search and app loading block the window while they run (seconds);
    # move them to the background task if large tenants make that noticeable.
    $withWait = {
        param([scriptblock]$Action)
        $win.Cursor = [System.Windows.Input.Cursors]::Wait
        & $doEvents
        try { & $Action } finally { $win.Cursor = $null }
    }
    $selectByTag = {
        param($Combo, $Tag)
        foreach ($item in $Combo.Items) {
            if ([string]$item.Tag -eq [string]$Tag) { $Combo.SelectedItem = $item; return }
        }
        if ($Combo -eq $ui.MinimumWindowsRelease -and $Tag) {
            # Keep a release set in the portal even if it is not in the list.
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $Tag
            $item.Tag = $Tag
            [void]$Combo.Items.Add($item)
            $Combo.SelectedItem = $item
            return
        }
        $Combo.SelectedIndex = 0
    }
    $showStatus = {
        param([string]$Kind, [string]$Text)
        $ui.StatusText.Text = $Text
        $ui.StatusText.Foreground = if ($Kind -eq 'error') { $errorBrush } else { $successBrush }
        $ui.StatusText.Visibility = $visible
    }
    $hideStatus = { $ui.StatusText.Visibility = $collapsed }

    $emptySpec = {
        [ordered]@{
            DisplayName = ''; Publisher = ''; DisplayVersion = ''; Description = ''
            InstallCommandLine = ''; UninstallCommandLine = ''
            RunAsAccount = 'system'; DeviceRestartBehavior = 'basedOnReturnCode'; MaxRunTimeInMinutes = 60
            Architectures = @('x64'); MinimumWindowsRelease = $script:IwaWindowsReleases[0]; Rules = @()
        }
    }
    $getForm = {
        $arch = @()
        if ($ui.ArchX64.IsChecked) { $arch += 'x64' }
        if ($ui.ArchX86.IsChecked) { $arch += 'x86' }
        if ($ui.ArchArm64.IsChecked) { $arch += 'arm64' }
        [ordered]@{
            DisplayName           = $ui.DisplayName.Text.Trim()
            Publisher             = $ui.Publisher.Text.Trim()
            DisplayVersion        = $ui.DisplayVersion.Text.Trim()
            Description           = $ui.Description.Text.Trim()
            InstallCommandLine    = $ui.InstallCommandLine.Text.Trim()
            UninstallCommandLine  = $ui.UninstallCommandLine.Text.Trim()
            RunAsAccount          = [string]$ui.RunAsAccount.SelectedItem.Tag
            DeviceRestartBehavior = [string]$ui.DeviceRestartBehavior.SelectedItem.Tag
            MaxRunTimeInMinutes   = $ui.MaxRunTimeInMinutes.Text.Trim()
            Architectures         = $arch
            MinimumWindowsRelease = [string]$ui.MinimumWindowsRelease.SelectedItem.Tag
            Rules                 = @($state.Rules)
        }
    }
    $validate = {
        if ($state.Loading) { return }
        $errors = @(Test-IwaWin32AppSpec -Spec (& $getForm) -Package $state.Package -UploadContent ([bool]$ui.UploadContent.IsChecked))
        if ($ui.ModeUpdate.IsChecked -and -not $state.AppId) { $errors += [pscustomobject]@{ Field = 'SearchResults'; Message = 'Select the app to update.' } }
        if (-not $state.Account) { $errors += [pscustomobject]@{ Field = 'SignInButton'; Message = 'Sign in to Intune.' } }
        foreach ($name in $fieldControls) { $ui[$name].ClearValue([System.Windows.Controls.Control]::BorderBrushProperty) }
        foreach ($err in $errors) {
            $target = if ($err.Field -eq 'Rules') { 'RulesList' } else { [string]$err.Field }
            if ($fieldControls -contains $target) { $ui[$target].BorderBrush = $errorBrush }
        }
        $ui.ValidationText.Text = (@($errors | ForEach-Object { $_.Message }) -join "`n")
        $ui.ValidationText.Visibility = if ($errors.Count -and -not $state.Busy) { $visible } else { $collapsed }
        $ui.UploadButton.IsEnabled = ($errors.Count -eq 0) -and -not $state.Busy
    }
    $refreshRules = {
        $ui.RulesList.Items.Clear()
        foreach ($rule in $state.Rules) { [void]$ui.RulesList.Items.Add((Get-IwaRuleSummary -Rule $rule)) }
        & $validate
    }
    $setForm = {
        param($Spec)
        $state.Loading = $true
        try {
            $ui.DisplayName.Text = [string]$Spec.DisplayName
            $ui.Publisher.Text = [string]$Spec.Publisher
            $ui.DisplayVersion.Text = [string]$Spec.DisplayVersion
            $ui.Description.Text = [string]$Spec.Description
            $ui.InstallCommandLine.Text = [string]$Spec.InstallCommandLine
            $ui.UninstallCommandLine.Text = [string]$Spec.UninstallCommandLine
            $ui.MaxRunTimeInMinutes.Text = [string]$Spec.MaxRunTimeInMinutes
            & $selectByTag $ui.RunAsAccount $Spec.RunAsAccount
            & $selectByTag $ui.DeviceRestartBehavior $Spec.DeviceRestartBehavior
            & $selectByTag $ui.MinimumWindowsRelease $Spec.MinimumWindowsRelease
            $arch = @($Spec.Architectures)
            $ui.ArchX64.IsChecked = $arch -contains 'x64'
            $ui.ArchX86.IsChecked = $arch -contains 'x86'
            $ui.ArchArm64.IsChecked = $arch -contains 'arm64'
            $state.Rules.Clear()
            foreach ($rule in @($Spec.Rules | Where-Object { $_ })) { [void]$state.Rules.Add($rule) }
        } finally {
            $state.Loading = $false
        }
        & $refreshRules
    }
    $loadPackage = {
        param([string]$Path)
        $state.Package = $null
        $ui.PackagePath.Text = $Path
        if ($Path) {
            try { $state.Package = Read-IwaIntuneWinPackage -Path $Path }
            catch { & $showStatus 'error' $_.Exception.Message }
        }
        if ($state.Package -and $ui.ModeNew.IsChecked) {
            & $setForm (Get-IwaWin32AppDefault -Package $state.Package -DisplayVersion $state.DisplayVersion)
        } else {
            & $validate
        }
    }
    $refreshAccount = {
        $hasModule = Test-IwaGraphModule
        $ui.InstallGraphButton.Visibility = if ($hasModule) { $collapsed } else { $visible }
        $ui.SignInButton.IsEnabled = $hasModule
        $state.Account = $null
        if ($hasModule) {
            try { $state.Account = Get-IwaIntuneAccount } catch { Write-IwaDebugLog "Reading the Graph context failed: $($_.Exception.Message)" }
            $ui.GraphStatusText.Visibility = $collapsed
        } else {
            $ui.GraphStatusText.Text = 'Publishing needs the Microsoft.Graph.Authentication module. Select Install now, or run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
            $ui.GraphStatusText.Visibility = $visible
        }
        $ui.AccountText.Text = if ($state.Account) { [string]$state.Account } else { 'Not signed in' }
        $ui.SignInButton.Content = if ($state.Account) { 'Sign out' } else { 'Sign in' }
        $ui.SearchButton.IsEnabled = [bool]$state.Account
        & $validate
    }
    $applyMode = {
        $isNew = [bool]$ui.ModeNew.IsChecked
        $ui.SearchPanel.Visibility = if ($isNew) { $collapsed } else { $visible }
        $ui.UploadContent.IsEnabled = -not $isNew
        if ($isNew) { $ui.UploadContent.IsChecked = $true }
        $ui.RetryUploadButton.Visibility = $collapsed
        & $hideStatus
        if (-not $state.KeepAppId) {
            $state.AppId = $null
            $ui.OpenInIntune.IsEnabled = $false
            $state.LoadingResults = $true
            $ui.SearchResults.Items.Clear()
            $state.LoadingResults = $false
            if ($isNew) {
                if ($state.Package) { & $setForm (Get-IwaWin32AppDefault -Package $state.Package -DisplayVersion $state.DisplayVersion) }
                else { & $setForm (& $emptySpec) }
            }
        }
        & $validate
    }
    $setBusy = {
        param([bool]$Busy)
        $state.Busy = $Busy
        foreach ($control in @($ui.FormPanel, $ui.ModeNew, $ui.ModeUpdate, $ui.SignInButton)) { $control.IsEnabled = -not $Busy }
        $ui.ProgressPanel.Visibility = if ($Busy) { $visible } else { $collapsed }
        if ($Busy) { $ui.UploadButton.IsEnabled = $false; $ui.ValidationText.Visibility = $collapsed }
    }
    $startTask = {
        param($AppId, $Body, $Package)
        & $setBusy $true
        $state.LastUpload = [bool]$Package
        $ui.RetryUploadButton.Visibility = $collapsed
        & $hideStatus
        $ui.UploadProgress.Value = 0
        $ui.ProgressText.Text = 'Starting'
        $taskState = [hashtable]::Synchronized(@{
            Step = 'Starting'; Percent = 0; AppId = $AppId; Saved = ([bool]$AppId -and -not $Body); Error = $null; Done = $false
        })
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script:IwaIntuneTaskScript.ToString())
        [void]$ps.AddArgument($taskState).AddArgument($ModuleRoot).AddArgument($Body).AddArgument($Package)
        $state.Task = @{ PowerShell = $ps; Handle = $ps.BeginInvoke(); State = $taskState; IsNew = [bool]$ui.ModeNew.IsChecked }
        $timer.Start()
    }

    # --- Background task polling ---------------------------------------------------------------
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({
        $task = $state.Task
        if (-not $task) { $timer.Stop(); return }
        $ui.ProgressText.Text = [string]$task.State.Step
        $ui.UploadProgress.Value = [int]$task.State.Percent
        if (-not $task.Handle.IsCompleted) { return }

        $timer.Stop()
        try { $null = $task.PowerShell.EndInvoke($task.Handle) } catch { if (-not $task.State.Error) { $task.State.Error = $_.Exception.Message } }
        $task.PowerShell.Dispose()
        $state.Task = $null
        & $setBusy $false
        if ($task.State.AppId) {
            $state.AppId = $task.State.AppId
            $ui.OpenInIntune.IsEnabled = $true
        }
        if ($task.State.Error) {
            Write-IwaDebugLog "Publish to Intune failed: $($task.State.Error)"
            $message = "Upload failed: $($task.State.Error)"
            if ($task.State.Saved -and $state.LastUpload) {
                $message += if ($task.IsNew) {
                    "`nThe app was created in Intune without content. Select Retry upload to send the package to the same app."
                } else {
                    "`nThe app settings were saved and the previous content is still in use. Select Retry upload to send the package again."
                }
                $ui.RetryUploadButton.Visibility = $visible
            }
            & $showStatus 'error' $message
        } else {
            $ui.UploadContent.IsChecked = $false
            if ($task.IsNew) {
                # The app now exists: further changes are updates of the same app, not new apps.
                $state.KeepAppId = $true
                $ui.ModeUpdate.IsChecked = $true
                $state.KeepAppId = $false
            }
            & $showStatus 'success' ("Done: ""{0}"" is in Intune.`n{1}" -f $ui.DisplayName.Text, $script:IwaV1Limitations)
        }
        & $validate
    })

    # --- Events ------------------------------------------------------------------------------
    $ui.ModeNew.Add_Checked({ & $applyMode })
    $ui.ModeUpdate.Add_Checked({ & $applyMode })

    $ui.InstallGraphButton.Add_Click({
        $ui.GraphStatusText.Text = 'Installing Microsoft.Graph.Authentication for the current user...'
        $ui.GraphStatusText.Visibility = $visible
        $state.InstallError = $null
        & $withWait { try { Install-IwaGraphModule } catch { $state.InstallError = $_.Exception.Message } }
        & $refreshAccount
        if ($state.InstallError) {
            $ui.GraphStatusText.Text = "Installing the module failed: $($state.InstallError)`nRun it manually: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
            $ui.GraphStatusText.Visibility = $visible
        }
    })

    $ui.SignInButton.Add_Click({
        if ($state.Account) { Disconnect-IwaIntune; & $refreshAccount; return }
        $ui.GraphStatusText.Text = 'Signing in... complete the sign-in in the window that opens.'
        $ui.GraphStatusText.Visibility = $visible
        $state.SignInError = $null
        & $withWait { try { Connect-IwaIntune | Out-Null } catch { $state.SignInError = $_.Exception.Message } }
        & $refreshAccount
        if ($state.SignInError) {
            Write-IwaDebugLog "Intune sign-in failed: $($state.SignInError)"
            $ui.GraphStatusText.Text = if ($state.SignInError -match 'AADSTS65001|AADSTS90094|consent') {
                'Admin consent is needed for DeviceManagementApps.ReadWrite.All on "Microsoft Graph Command Line Tools". Ask a tenant administrator to grant it, then sign in again.'
            } elseif ($state.SignInError -match 'window handle') {
                'Sign-in could not open the Windows account prompt. Start the GUI from a PowerShell console window (Windows Terminal or the PowerShell console) and try again.'
            } else {
                "Sign-in failed: $($state.SignInError)"
            }
            $ui.GraphStatusText.Visibility = $visible
        }
    })

    $ui.BrowsePackage.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = 'Intune Win32 package (*.intunewin)|*.intunewin'
        if ($ui.PackagePath.Text) { $dialog.InitialDirectory = Split-Path $ui.PackagePath.Text -Parent }
        if ($dialog.ShowDialog($win)) {
            # The version from the main window belongs to the package it built, not to this one.
            $state.DisplayVersion = $null
            & $hideStatus
            if ($ui.ModeUpdate.IsChecked) { $ui.UploadContent.IsChecked = $true }
            & $loadPackage $dialog.FileName
        }
    })

    $runSearch = {
        & $hideStatus
        $state.SearchError = $null
        & $withWait {
            try { $state.SearchResults = @(Get-IwaWin32App -Search $ui.SearchBox.Text.Trim()) }
            catch { $state.SearchResults = @(); $state.SearchError = Get-IwaGraphErrorMessage -ErrorRecord $_ }
        }
        $state.LoadingResults = $true
        $ui.SearchResults.Items.Clear()
        foreach ($app in $state.SearchResults) {
            [void]$ui.SearchResults.Items.Add(('{0}  |  {1}  |  {2}' -f $app.displayName, $app.publisher, $app.displayVersion))
        }
        $state.LoadingResults = $false
        if ($state.SearchError) { & $showStatus 'error' "Search failed: $($state.SearchError)" }
        elseif (-not $state.SearchResults.Count) { & $showStatus 'error' 'No Win32 app matches that name.' }
    }
    $ui.SearchButton.Add_Click({ & $runSearch })
    $ui.SearchBox.Add_KeyDown({
        param($evtSender, $e)
        if ($e.Key -eq 'Return' -and $ui.SearchButton.IsEnabled) { & $runSearch; $e.Handled = $true }
    })
    $ui.SearchResults.Add_SelectionChanged({
        $index = $ui.SearchResults.SelectedIndex
        if ($state.LoadingResults -or $index -lt 0) { return }
        $picked = $state.SearchResults[$index]
        $state.LoadError = $null
        $state.LoadedApp = $null
        & $withWait {
            try { $state.LoadedApp = Get-IwaWin32App -Id $picked.id }
            catch { $state.LoadError = Get-IwaGraphErrorMessage -ErrorRecord $_ }
        }
        if ($state.LoadError) { & $showStatus 'error' "Loading the app failed: $($state.LoadError)"; return }
        $state.AppId = [string]$state.LoadedApp.id
        $ui.OpenInIntune.IsEnabled = $true
        $ui.RetryUploadButton.Visibility = $collapsed
        & $setForm (ConvertFrom-IwaGraphApp -App $state.LoadedApp)
        & $showStatus 'success' ('Loaded "{0}". Change what you need, then select Upload.' -f $state.LoadedApp.displayName)
    })

    $ui.NewRuleType.Add_SelectionChanged({
        $type = [string]$ui.NewRuleType.SelectedItem.Tag
        $ui.MsiRulePanel.Visibility = if ($type -eq 'MsiProductCode') { $visible } else { $collapsed }
        $ui.FileRulePanel.Visibility = if ($type -eq 'File') { $visible } else { $collapsed }
        $ui.RegistryRulePanel.Visibility = if ($type -eq 'Registry') { $visible } else { $collapsed }
        $ui.ScriptRulePanel.Visibility = if ($type -eq 'Script') { $visible } else { $collapsed }
        $ui.RuleErrorText.Visibility = $collapsed
    })
    $ui.BrowseScript.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = 'PowerShell script (*.ps1)|*.ps1'
        if ($dialog.ShowDialog($win)) { $ui.RuleScriptPath.Text = $dialog.FileName }
    })
    $ui.AddRuleButton.Add_Click({
        $type = [string]$ui.NewRuleType.SelectedItem.Tag
        $ruleArgs = @{ Type = $type }
        try {
            switch ($type) {
                'MsiProductCode' { $ruleArgs.ProductCode = $ui.RuleProductCode.Text.Trim() }
                'File' {
                    $ruleArgs.Path = $ui.RuleFilePath.Text
                    $ruleArgs.FileOrFolderName = $ui.RuleFileName.Text
                    $ruleArgs.Operation = [string]$ui.RuleFileOperation.SelectedItem.Tag
                    $ruleArgs.Value = $ui.RuleFileValue.Text
                    $ruleArgs.Check32BitOn64System = [bool]$ui.RuleFile32Bit.IsChecked
                }
                'Registry' {
                    $ruleArgs.KeyPath = $ui.RuleKeyPath.Text
                    $ruleArgs.ValueName = $ui.RuleValueName.Text
                    $ruleArgs.Operation = [string]$ui.RuleRegOperation.SelectedItem.Tag
                    $ruleArgs.Value = $ui.RuleRegValue.Text
                    $ruleArgs.Check32BitOn64System = [bool]$ui.RuleReg32Bit.IsChecked
                }
                'Script' {
                    $scriptPath = $ui.RuleScriptPath.Text.Trim()
                    if (-not $scriptPath -or -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw 'Select an existing .ps1 detection script.' }
                    $ruleArgs.ScriptContent = Get-Content -LiteralPath $scriptPath -Raw
                    $ruleArgs.RunAs32Bit = [bool]$ui.RuleScriptRunAs32.IsChecked
                    $ruleArgs.EnforceSignatureCheck = [bool]$ui.RuleScriptSignature.IsChecked
                }
            }
            [void]$state.Rules.Add((New-IwaDetectionRule @ruleArgs))
            $ui.RuleErrorText.Visibility = $collapsed
            & $refreshRules
        } catch {
            $ui.RuleErrorText.Text = $_.Exception.Message
            $ui.RuleErrorText.Visibility = $visible
        }
    })
    $ui.RemoveRuleButton.Add_Click({
        $index = $ui.RulesList.SelectedIndex
        if ($index -ge 0) { $state.Rules.RemoveAt($index); & $refreshRules }
    })

    foreach ($name in @('DisplayName', 'Publisher', 'DisplayVersion', 'Description', 'InstallCommandLine', 'UninstallCommandLine', 'MaxRunTimeInMinutes', 'PackagePath')) {
        $ui[$name].Add_TextChanged({ & $validate })
    }
    foreach ($name in @('ArchX64', 'ArchX86', 'ArchArm64', 'UploadContent')) {
        $ui[$name].Add_Click({ & $validate })
    }

    $ui.UploadButton.Add_Click({
        $package = if ($ui.UploadContent.IsChecked) { $state.Package } else { $null }
        $body = New-IwaWin32AppBody -Spec (& $getForm) -Package $package -ForUpdate:(-not $ui.ModeNew.IsChecked)
        & $startTask $state.AppId $body $package
    })
    $ui.RetryUploadButton.Add_Click({ & $startTask $state.AppId $null $state.Package })
    $ui.OpenInIntune.Add_Click({ if ($state.AppId) { Start-Process (Get-IwaIntunePortalUrl -AppId $state.AppId) } })
    $ui.CloseButton.Add_Click({ $win.Close() })
    $win.Add_KeyDown({
        param($evtSender, $e)
        if ($e.Key -eq 'Escape') { $win.Close() }
    })
    $win.Add_Closing({
        param($evtSender, $e)
        if (-not $state.Task) { return }
        $answer = [System.Windows.MessageBox]::Show($win, 'An upload is still running. Stop it and close the window?', 'Publish to Intune',
            [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { $e.Cancel = $true; return }
        $timer.Stop()
        try { $state.Task.PowerShell.Stop() } catch { }
        $state.Task.PowerShell.Dispose()
        $state.Task = $null
    })

    # --- Start -------------------------------------------------------------------------------
    & $refreshAccount
    & $applyMode
    & $loadPackage $PackagePath
    [void]$win.ShowDialog()
}
