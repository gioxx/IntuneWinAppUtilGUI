BeforeAll {
    . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-IntuneApp.ps1')

    $exePackage = [pscustomobject]@{ Path = 'C:\Out\Contoso Tool_1.0.intunewin'; Name = 'setup.exe'; SetupFile = 'setup.exe'; MsiInfo = $null }
    $msiPackage = [pscustomobject]@{
        Path = 'C:\Out\contoso-tool.intunewin'; Name = 'Contoso Tool'; SetupFile = 'contoso-tool.msi'
        MsiInfo = [pscustomobject]@{
            ProductCode = '{11111111-2222-3333-4444-555555555555}'; ProductVersion = '2.1.0'
            UpgradeCode = '{66666666-7777-8888-9999-000000000000}'; Publisher = 'Contoso Ltd'
            RequiresReboot = $false; ExecutionContext = 'System'
        }
    }
    function New-ValidSpec {
        @{
            DisplayName = 'Contoso Tool'; Publisher = 'Contoso Ltd'; DisplayVersion = '2.1.0'; Description = 'Contoso Tool'
            InstallCommandLine = 'setup.exe /S'; UninstallCommandLine = 'uninstall.exe /S'
            RunAsAccount = 'system'; DeviceRestartBehavior = 'basedOnReturnCode'; MaxRunTimeInMinutes = 60
            Architectures = @('x64', 'x86'); MinimumWindowsRelease = '1607'
            Rules = @(@{ Type = 'MsiProductCode'; ProductCode = '{11111111-2222-3333-4444-555555555555}' })
        }
    }
}

Describe 'Get-IwaWin32AppDefault' {
    It 'prefills an EXE package from the package file name' {
        $spec = Get-IwaWin32AppDefault -Package $exePackage -DisplayVersion '1.0'
        $spec.DisplayName | Should -Be 'Contoso Tool_1.0'
        $spec.Description | Should -Be 'Contoso Tool_1.0'
        $spec.DisplayVersion | Should -Be '1.0'
        $spec.InstallCommandLine | Should -Be '"setup.exe"'
        $spec.UninstallCommandLine | Should -Be ''
        $spec.RunAsAccount | Should -Be 'system'
        $spec.Architectures | Should -Be @('x64')
        $spec.MinimumWindowsRelease | Should -Be $script:IwaWindowsReleases[0]
        @($spec.Rules).Count | Should -Be 0
    }

    It 'prefills an MSI package with commands and the product code rule' {
        $spec = Get-IwaWin32AppDefault -Package $msiPackage
        $spec.DisplayName | Should -Be 'Contoso Tool'
        $spec.Publisher | Should -Be 'Contoso Ltd'
        $spec.DisplayVersion | Should -Be '2.1.0'
        $spec.InstallCommandLine | Should -Be 'msiexec /i "contoso-tool.msi" /qn'
        $spec.UninstallCommandLine | Should -Be 'msiexec /x {11111111-2222-3333-4444-555555555555} /qn'
        $spec.Rules[0].Type | Should -Be 'MsiProductCode'
        $spec.Rules[0].ProductCode | Should -Be '{11111111-2222-3333-4444-555555555555}'
    }

    It 'uses the name and publisher read from the source folder over the package values' {
        $spec = Get-IwaWin32AppDefault -Package $exePackage -DisplayVersion '26.06' -DisplayName 'Contoso Tool (x64)' -Publisher 'Contoso Ltd'
        $spec.DisplayName | Should -Be 'Contoso Tool (x64)'
        $spec.Description | Should -Be 'Contoso Tool (x64)'
        $spec.Publisher | Should -Be 'Contoso Ltd'
        $spec.DisplayVersion | Should -Be '26.06'
    }
}

Describe 'Get-IwaWindowsReleaseLabel' {
    It 'labels <Release> as <Label>' -TestCases @(
        @{ Release = '1607'; Label = 'Windows 10 1607' }
        @{ Release = 'Windows10_22H2'; Label = 'Windows 10 22H2' }
        @{ Release = 'Windows11_24H2'; Label = 'Windows 11 24H2' }
    ) {
        Get-IwaWindowsReleaseLabel -Release $Release | Should -Be $Label
    }
}

Describe 'New-IwaDetectionRule' {
    It 'accepts an MSI product code' {
        (New-IwaDetectionRule -Type MsiProductCode -ProductCode '{11111111-2222-3333-4444-555555555555}').ProductCode | Should -Be '{11111111-2222-3333-4444-555555555555}'
    }
    It 'rejects a product code that is not a GUID' {
        { New-IwaDetectionRule -Type MsiProductCode -ProductCode 'abc' } | Should -Throw '*{GUID}*'
    }
    It 'builds a file exists rule without a comparison' {
        $r = New-IwaDetectionRule -Type File -Path 'C:\Program Files\Contoso' -FileOrFolderName 'tool.exe'
        $r.Operation | Should -Be 'exists'
        $r.Operator | Should -Be 'notConfigured'
        $r.Value | Should -BeNullOrEmpty
    }
    It 'needs a value for a version comparison' {
        { New-IwaDetectionRule -Type File -Path 'C:\Program Files\Contoso' -FileOrFolderName 'tool.exe' -Operation version } | Should -Throw '*value*'
    }
    It 'maps a registry string comparison to equal' {
        $r = New-IwaDetectionRule -Type Registry -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\Contoso' -ValueName 'Version' -Operation string -Value '2.1'
        $r.Operator | Should -Be 'equal'
        $r.Value | Should -Be '2.1'
    }
    It 'needs script content' {
        { New-IwaDetectionRule -Type Script -ScriptContent '' } | Should -Throw '*script*'
    }
}

Describe 'ConvertTo-IwaGraphRule' {
    It 'maps each rule type to its Graph type' {
        (ConvertTo-IwaGraphRule -Rule @{ Type = 'MsiProductCode'; ProductCode = '{11111111-2222-3333-4444-555555555555}' }).'@odata.type' | Should -Be '#microsoft.graph.win32LobAppProductCodeRule'
        (ConvertTo-IwaGraphRule -Rule (New-IwaDetectionRule -Type File -Path 'C:\X' -FileOrFolderName 'a.exe')).'@odata.type' | Should -Be '#microsoft.graph.win32LobAppFileSystemRule'
        (ConvertTo-IwaGraphRule -Rule (New-IwaDetectionRule -Type Registry -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\Contoso')).'@odata.type' | Should -Be '#microsoft.graph.win32LobAppRegistryRule'
    }
    It 'encodes script content as base64' {
        $g = ConvertTo-IwaGraphRule -Rule (New-IwaDetectionRule -Type Script -ScriptContent 'Write-Output ok')
        $g.'@odata.type' | Should -Be '#microsoft.graph.win32LobAppPowerShellScriptRule'
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($g.scriptContent)) | Should -Be 'Write-Output ok'
        $g.ruleType | Should -Be 'detection'
    }
    It 'returns raw rules unchanged' {
        $graph = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppRegistryRule'; ruleType = 'requirement' }
        ConvertTo-IwaGraphRule -Rule @{ Type = 'Raw'; Graph = $graph } | Should -Be $graph
    }
    It 'rejects an unknown type' {
        { ConvertTo-IwaGraphRule -Rule @{ Type = 'Nope' } } | Should -Throw '*Nope*'
    }
}

Describe 'New-IwaWin32AppBody' {
    It 'builds a create body with defaults and package data' {
        $body = New-IwaWin32AppBody -Spec (New-ValidSpec) -Package $msiPackage
        $body.'@odata.type' | Should -Be '#microsoft.graph.win32LobApp'
        $body.displayName | Should -Be 'Contoso Tool'
        $body.applicableArchitectures | Should -Be 'x64,x86'
        $body.installExperience.runAsAccount | Should -Be 'system'
        $body.installExperience.maxRunTimeInMinutes | Should -Be 60
        @($body.returnCodes).Count | Should -Be 5
        $body.returnCodes[0].returnCode | Should -Be 0
        $body.returnCodes[0].type | Should -Be 'success'
        @($body.rules).Count | Should -Be 1
        $body.fileName | Should -Be 'contoso-tool.intunewin'
        $body.setupFilePath | Should -Be 'contoso-tool.msi'
        $body.msiInformation.productCode | Should -Be '{11111111-2222-3333-4444-555555555555}'
        $body.msiInformation.packageType | Should -Be 'perMachine'
    }
    It 'leaves create-only fields and package fields out of an update without package' {
        $body = New-IwaWin32AppBody -Spec (New-ValidSpec) -ForUpdate
        $body.Contains('returnCodes') | Should -BeFalse
        $body.Contains('isFeatured') | Should -BeFalse
        $body.Contains('fileName') | Should -BeFalse
        $body.Contains('msiInformation') | Should -BeFalse
    }
    It 'serializes to JSON with the rules as an array' {
        $json = New-IwaWin32AppBody -Spec (New-ValidSpec) -ForUpdate | ConvertTo-Json -Depth 10
        ($json | ConvertFrom-Json).rules.Count | Should -Be 1
    }
}

Describe 'ConvertFrom-IwaGraphApp' {
    BeforeAll {
        $script64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('exit 0'))
        $app = [pscustomobject]@{
            id = '00000000-0000-0000-0000-000000000001'; displayName = 'Contoso Tool'; publisher = 'Contoso Ltd'
            displayVersion = '2.1.0'; description = 'Tool'; installCommandLine = 'setup.exe /S'; uninstallCommandLine = 'uninstall.exe /S'
            applicableArchitectures = 'x64,x86'; minimumSupportedWindowsRelease = '1607'
            installExperience = [pscustomobject]@{ runAsAccount = 'user'; deviceRestartBehavior = 'suppress'; maxRunTimeInMinutes = 30 }
            rules = @(
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppProductCodeRule'; ruleType = 'detection'; productCode = '{11111111-2222-3333-4444-555555555555}'; productVersionOperator = 'notConfigured'; productVersion = $null },
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptRule'; ruleType = 'detection'; scriptContent = $script64; runAs32Bit = $false; enforceSignatureCheck = $false; operationType = 'notConfigured' },
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppRegistryRule'; ruleType = 'requirement'; keyPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\Contoso' }
            )
        }
    }
    It 'maps app settings to the form model' {
        $spec = ConvertFrom-IwaGraphApp -App $app
        $spec.DisplayName | Should -Be 'Contoso Tool'
        $spec.RunAsAccount | Should -Be 'user'
        $spec.DeviceRestartBehavior | Should -Be 'suppress'
        $spec.MaxRunTimeInMinutes | Should -Be 30
        $spec.Architectures | Should -Be @('x64', 'x86')
        $spec.Rules[0].Type | Should -Be 'MsiProductCode'
        $spec.Rules[1].Type | Should -Be 'Script'
        $spec.Rules[1].ScriptContent | Should -Be 'exit 0'
        $spec.Rules[2].Type | Should -Be 'Raw'
    }
    It 'sends requirement rules back unchanged on update' {
        $body = New-IwaWin32AppBody -Spec (ConvertFrom-IwaGraphApp -App $app) -ForUpdate
        @($body.rules).Count | Should -Be 3
        $body.rules[2] | Should -Be $app.rules[2]
    }
    It 'writes allowedArchitectures back for apps created in the portal' {
        $portal = [pscustomobject]@{
            displayName = 'Contoso Tool'; applicableArchitectures = 'none'; allowedArchitectures = 'x64,arm64'
            rules = @([pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppProductCodeRule'; ruleType = 'detection'; productCode = '{11111111-2222-3333-4444-555555555555}'; productVersionOperator = 'notConfigured' })
        }
        $spec = ConvertFrom-IwaGraphApp -App $portal
        $spec.ArchitectureProperty | Should -Be 'allowedArchitectures'
        $body = New-IwaWin32AppBody -Spec $spec -ForUpdate
        $body.allowedArchitectures | Should -Be 'x64,arm64'
        $body.applicableArchitectures | Should -Be 'none'
    }
    It 'keeps applicableArchitectures for existing apps and new apps' {
        $spec = ConvertFrom-IwaGraphApp -App $app
        $spec.ArchitectureProperty | Should -Be 'applicableArchitectures'
        $body = New-IwaWin32AppBody -Spec $spec -ForUpdate
        $body.applicableArchitectures | Should -Be 'x64,x86'
        $body.Contains('allowedArchitectures') | Should -BeFalse
        (New-IwaWin32AppBody -Spec (New-ValidSpec)).Contains('allowedArchitectures') | Should -BeFalse
    }
    It 'keeps a script rule without content as raw' {
        $noContent = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptRule'; ruleType = 'detection'; scriptContent = $null }
        (ConvertFrom-IwaGraphRule -GraphRule $noContent).Type | Should -Be 'Raw'
    }
}

Describe 'Test-IwaWin32AppSpec' {
    It 'accepts a valid spec' {
        @(Test-IwaWin32AppSpec -Spec (New-ValidSpec)).Count | Should -Be 0
    }
    It 'reports every missing required field' {
        $spec = New-ValidSpec
        $spec.DisplayName = ' '; $spec.UninstallCommandLine = ''
        $fields = @(Test-IwaWin32AppSpec -Spec $spec | ForEach-Object { $_.Field })
        $fields | Should -Contain 'DisplayName'
        $fields | Should -Contain 'UninstallCommandLine'
    }
    It 'needs an architecture and a detection rule' {
        $spec = New-ValidSpec
        $spec.Architectures = @(); $spec.Rules = @(@{ Type = 'Raw'; Graph = [pscustomobject]@{ ruleType = 'requirement' } })
        $fields = @(Test-IwaWin32AppSpec -Spec $spec | ForEach-Object { $_.Field })
        $fields | Should -Contain 'Architectures'
        $fields | Should -Contain 'Rules'
    }
    It 'checks the max run time range' {
        $spec = New-ValidSpec
        $spec.MaxRunTimeInMinutes = '0'
        @(Test-IwaWin32AppSpec -Spec $spec | ForEach-Object { $_.Field }) | Should -Contain 'MaxRunTimeInMinutes'
    }
    It 'rejects a detection script over 200 KB' {
        $spec = New-ValidSpec
        $spec.Rules = @(@{ Type = 'Script'; ScriptContent = ('x' * 205000) })
        @(Test-IwaWin32AppSpec -Spec $spec | ForEach-Object { $_.Message }) | Should -Contain 'A detection script is larger than 200 KB.'
    }
    It 'blocks script rules that came back without content' {
        foreach ($ruleType in 'detection', 'requirement') {
            $spec = New-ValidSpec
            $spec.Rules += @{ Type = 'Raw'; Graph = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptRule'; ruleType = $ruleType; scriptContent = $null } }
            $found = @(Test-IwaWin32AppSpec -Spec $spec | Where-Object { $_.Field -eq 'Rules' })
            $found.Count | Should -Be 1 -Because $ruleType
            $found[0].Message | Should -Be 'A script rule of this app came back from Intune without its content. Edit this app''s script rules in the portal ("Open in Intune").'
        }
    }
    It 'needs a package when the content is uploaded' {
        @(Test-IwaWin32AppSpec -Spec (New-ValidSpec) -UploadContent $true | ForEach-Object { $_.Field }) | Should -Contain 'PackagePath'
        @(Test-IwaWin32AppSpec -Spec (New-ValidSpec) -Package $msiPackage -UploadContent $true).Count | Should -Be 0
    }
}

Describe 'Get-IwaRuleSummary' {
    It 'describes each rule type' {
        Get-IwaRuleSummary -Rule @{ Type = 'MsiProductCode'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } | Should -Be 'MSI product code {11111111-2222-3333-4444-555555555555}'
        Get-IwaRuleSummary -Rule (New-IwaDetectionRule -Type File -Path 'C:\Program Files\Contoso\' -FileOrFolderName 'tool.exe') | Should -Be 'File: C:\Program Files\Contoso\tool.exe: exists'
        Get-IwaRuleSummary -Rule (New-IwaDetectionRule -Type Registry -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\Contoso' -ValueName 'Version' -Operation version -Value '2.0') | Should -Be 'Registry: HKEY_LOCAL_MACHINE\SOFTWARE\Contoso [Version]: version greaterThanOrEqual 2.0'
        Get-IwaRuleSummary -Rule @{ Type = 'Raw'; Graph = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppRegistryRule'; ruleType = 'requirement' } } | Should -Be 'Kept from Intune: win32LobAppRegistryRule (requirement)'
    }
}

Describe 'ConvertFrom-IwaGraphRule' {
    It 'keeps a UTF-16 script unchanged as raw' {
        $utf16 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes('exit 0'))
        $rule = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptRule'; ruleType = 'detection'; scriptContent = $utf16 }
        (ConvertFrom-IwaGraphRule -GraphRule $rule).Type | Should -Be 'Raw'
    }
    It 'keeps a script with malformed base64 as raw without throwing' {
        $rule = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptRule'; ruleType = 'detection'; scriptContent = 'not base64!' }
        (ConvertFrom-IwaGraphRule -GraphRule $rule).Type | Should -Be 'Raw'
    }
    It 'still maps a UTF-8 script to Script' {
        $utf8 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('exit 0'))
        $rule = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptRule'; ruleType = 'detection'; scriptContent = $utf8; runAs32Bit = $false; enforceSignatureCheck = $false }
        $mapped = ConvertFrom-IwaGraphRule -GraphRule $rule
        $mapped.Type | Should -Be 'Script'
        $mapped.ScriptContent | Should -Be 'exit 0'
    }
}

Describe 'ConvertFrom-IwaGraphApp windows release default' {
    It 'falls back to the lowest release when Intune sends none' {
        $app = [pscustomobject]@{ displayName = 'Contoso Tool'; rules = @() }
        (ConvertFrom-IwaGraphApp -App $app).MinimumWindowsRelease | Should -Be $script:IwaWindowsReleases[0]
    }
}
