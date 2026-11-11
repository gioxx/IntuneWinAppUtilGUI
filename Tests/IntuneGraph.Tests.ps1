BeforeAll {
    . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-IntuneGraph.ps1')
    # CI has no Graph module: give Pester a command to mock.
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        function script:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $OutputType) }
    }
}

Describe 'Invoke-IwaGraph' {
    It 'sends the body as JSON' {
        Mock Invoke-MgGraphRequest { [pscustomobject]@{ id = 'x' } }
        (Invoke-IwaGraph -Method POST -Uri 'https://graph.example/apps' -Body @{ a = 1 }).id | Should -Be 'x'
        Should -Invoke Invoke-MgGraphRequest -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $ContentType -eq 'application/json' -and $OutputType -eq 'PSObject' -and ($Body | ConvertFrom-Json).a -eq 1
        }
    }
    It 'sends no body on GET' {
        Mock Invoke-MgGraphRequest { }
        Invoke-IwaGraph -Method GET -Uri 'https://graph.example/apps'
        Should -Invoke Invoke-MgGraphRequest -Times 1 -ParameterFilter { $null -eq $Body }
    }
}

Describe 'Get-IwaGraphErrorMessage' {
    It 'extracts the Graph error code and message' {
        $exception = New-Object System.Exception 'Response status code 400. {"error":{"code":"BadRequest","message":"Invalid displayName"}} trailing'
        $record = New-Object System.Management.Automation.ErrorRecord $exception, 'id', 'NotSpecified', $null
        Get-IwaGraphErrorMessage -ErrorRecord $record | Should -Be 'BadRequest: Invalid displayName'
    }
    It 'prefers ErrorDetails when present' {
        $record = New-Object System.Management.Automation.ErrorRecord (New-Object System.Exception 'generic'), 'id', 'NotSpecified', $null
        $record.ErrorDetails = New-Object System.Management.Automation.ErrorDetails '{"error":{"code":"Forbidden","message":"No access"}}'
        Get-IwaGraphErrorMessage -ErrorRecord $record | Should -Be 'Forbidden: No access'
    }
    It 'falls back to the exception message' {
        $record = New-Object System.Management.Automation.ErrorRecord (New-Object System.Exception 'Network down'), 'id', 'NotSpecified', $null
        Get-IwaGraphErrorMessage -ErrorRecord $record | Should -Be 'Network down'
    }
}

Describe 'Get-IwaWin32App' {
    It 'follows paging and filters by name' {
        Mock Invoke-IwaGraph {
            if ($Uri -like '*page2*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = '3'; displayName = 'Contoso Viewer' }) }
            }
            [pscustomobject]@{
                value = @([pscustomobject]@{ id = '1'; displayName = 'Fabrikam Tool' }, [pscustomobject]@{ id = '2'; displayName = 'Contoso Agent' })
                '@odata.nextLink' = 'https://graph.example/page2'
            }
        }
        $apps = @(Get-IwaWin32App -Search 'contoso')
        $apps.Count | Should -Be 2
        $apps[0].displayName | Should -Be 'Contoso Agent'
        $apps[1].displayName | Should -Be 'Contoso Viewer'
        Should -Invoke Invoke-IwaGraph -Times 1 -ParameterFilter { $Uri -like "*isof('microsoft.graph.win32LobApp')*" -and $Uri -like '*`$select=id,displayName,publisher' }
    }
    It 'returns every app with an empty search and handles an empty page' {
        Mock Invoke-IwaGraph { [pscustomobject]@{ value = @() } }
        @(Get-IwaWin32App).Count | Should -Be 0
    }
    It 'matches wildcard characters in the search literally' {
        Mock Invoke-IwaGraph {
            [pscustomobject]@{ value = @(
                [pscustomobject]@{ id = '1'; displayName = 'Contoso [x64] Agent' },
                [pscustomobject]@{ id = '2'; displayName = 'Contoso x Agent' },
                [pscustomobject]@{ id = '3'; displayName = 'Contoso * Tool' }
            ) }
        }
        @(Get-IwaWin32App -Search '[x64]').id | Should -Be @('1')
        @(Get-IwaWin32App -Search '*').id | Should -Be @('3')
    }
    It 'reads one app by id' {
        Mock Invoke-IwaGraph { [pscustomobject]@{ id = 'abc' } }
        (Get-IwaWin32App -Id 'abc').id | Should -Be 'abc'
        Should -Invoke Invoke-IwaGraph -Times 1 -ParameterFilter { $Method -eq 'GET' -and $Uri -eq 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/abc' }
    }
}

Describe 'Get-IwaIntunePortalUrl' {
    It 'links to the app page in the Intune admin center' {
        Get-IwaIntunePortalUrl -AppId '00000000-0000-0000-0000-000000000001' | Should -Be 'https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/00000000-0000-0000-0000-000000000001'
    }
}

Describe 'Invoke-IwaBlobRequest' {
    BeforeEach { Mock Start-Sleep { } }
    It 'retries a failed block and then succeeds' {
        $script:attempts = 0
        Mock Invoke-WebRequest { $script:attempts++; if ($script:attempts -lt 3) { throw 'busy' } }
        Invoke-IwaBlobRequest -Uri 'https://blob.example/c?sv=1&comp=block' -Body ([byte[]](1, 2))
        Should -Invoke Invoke-WebRequest -Times 3
    }
    It 'gives up after the last attempt' {
        Mock Invoke-WebRequest { throw 'busy' }
        { Invoke-IwaBlobRequest -Uri 'https://blob.example/c?sv=1' -Body 'x' } | Should -Throw '*after 3 attempts*'
    }
    It 'does not retry a request Azure Storage rejects' {
        Mock Invoke-WebRequest {
            $ex = New-Object System.Exception 'Forbidden'
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 403 })
            throw $ex
        }
        { Invoke-IwaBlobRequest -Uri 'https://blob.example/c?sv=1' -Body 'x' } | Should -Throw 'Upload to Azure Storage failed: *'
        Should -Invoke Invoke-WebRequest -Times 1
    }
    It 'passes the method, headers and content type to Invoke-WebRequest' {
        Mock Invoke-WebRequest { }
        Invoke-IwaBlobRequest -Uri 'https://blob.example/c?sv=1' -Body 'x' -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -ContentType 'application/xml'
        Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $Method -eq 'Put' -and $Headers['x-ms-blob-type'] -eq 'BlockBlob' -and $ContentType -eq 'application/xml' -and $UseBasicParsing }
    }
}

Describe 'Wait-IwaContentFileState' {
    BeforeEach { Mock Start-Sleep { } }
    It 'polls until the state succeeds' {
        $script:polls = 0
        Mock Invoke-IwaGraph { $script:polls++; if ($script:polls -lt 2) { [pscustomobject]@{ uploadState = 'commitFilePending' } } else { [pscustomobject]@{ uploadState = 'commitFileSuccess' } } }
        (Wait-IwaContentFileState -Uri 'https://graph.example/f' -State 'commitFile').uploadState | Should -Be 'commitFileSuccess'
        $script:polls | Should -Be 2
    }
    It 'throws when Intune reports a failure' {
        Mock Invoke-IwaGraph { [pscustomobject]@{ uploadState = 'commitFileFailed' } }
        { Wait-IwaContentFileState -Uri 'https://graph.example/f' -State 'commitFile' } | Should -Throw '*commitFileFailed*'
    }
    It 'throws after the last attempt' {
        Mock Invoke-IwaGraph { [pscustomobject]@{ uploadState = 'commitFilePending' } }
        { Wait-IwaContentFileState -Uri 'https://graph.example/f' -State 'commitFile' -MaxAttempts 2 } | Should -Throw '*Timed out*'
    }
}

Describe 'Publish-IwaWin32AppContent' {
    BeforeEach {
        $script:calls = New-Object System.Collections.Generic.List[string]
        $script:blockList = $null
        $script:blockListType = $null
        $script:blockPuts = New-Object System.Collections.Generic.List[object]
        Mock Start-Sleep { }
        Mock Invoke-IwaGraph {
            $script:calls.Add("$Method $Uri")
            if ($Uri -like '*/contentVersions') { return [pscustomobject]@{ id = 'cv1' } }
            if ($Uri -like '*/files') { return [pscustomobject]@{ id = 'f1' } }
            [pscustomobject]@{ }
        }
        Mock Wait-IwaContentFileState {
            $script:calls.Add("WAIT $State")
            [pscustomobject]@{ uploadState = "${State}Success"; azureStorageUri = 'https://blob.example/c?sv=1&sig=x' }
        }
        Mock Invoke-IwaBlobRequest {
            $script:calls.Add("BLOB $Uri")
            if ($Uri -like '*comp=block&*') {
                $rawId = [regex]::Match($Uri, 'blockid=([^&]+)').Groups[1].Value
                $script:blockPuts.Add([pscustomobject]@{ Id = [uri]::UnescapeDataString($rawId); Length = $Body.Length; Header = $Headers['x-ms-blob-type'] })
            }
            if ($Uri -like '*comp=blocklist') { $script:blockList = $Body; $script:blockListType = $ContentType }
        }
        $content = Join-Path $TestDrive 'IntunePackage.intunewin'
        [System.IO.File]::WriteAllBytes($content, [byte[]](1..13))
        $package = [pscustomobject]@{ FileName = 'IntunePackage.intunewin'; UnencryptedSize = 99; EncryptionInfo = [ordered]@{ encryptionKey = 'a2V5' } }
    }

    It 'uploads in blocks, commits, then sets the committed content version' {
        Publish-IwaWin32AppContent -AppId 'app1' -Package $package -ContentFile $content -ChunkSizeBytes 5 | Should -Be 'cv1'
        @($script:calls | Where-Object { $_ -like 'BLOB*comp=block&*' }).Count | Should -Be 3
        ([regex]::Matches($script:blockList, '<Latest>')).Count | Should -Be 3
        $commit = $script:calls.IndexOf((@($script:calls | Where-Object { $_ -like 'POST*/files/f1/commit' }))[0])
        $patch = $script:calls.IndexOf((@($script:calls | Where-Object { $_ -like 'PATCH*/mobileApps/app1' }))[0])
        $commit | Should -BeGreaterOrEqual 0
        $commit | Should -BeLessThan $patch
        $expectedIds = @('0000', '0001', '0002' | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($_)) })
        @($script:blockPuts | ForEach-Object { $_.Length }) | Should -Be @(5, 5, 3)
        @($script:blockPuts | ForEach-Object { $_.Header } | Select-Object -Unique) | Should -Be @('BlockBlob')
        @($script:blockPuts | ForEach-Object { $_.Id }) | Should -Be $expectedIds
        @($expectedIds | ForEach-Object { $_.Length } | Select-Object -Unique).Count | Should -Be 1
        @([regex]::Matches($script:blockList, '<Latest>([^<]+)</Latest>') | ForEach-Object { $_.Groups[1].Value }) | Should -Be $expectedIds
        $script:blockListType | Should -Be 'application/xml'
        $blocklistCall = $script:calls.IndexOf((@($script:calls | Where-Object { $_ -like 'BLOB*comp=blocklist' }))[0])
        $blocklistCall | Should -BeGreaterOrEqual 0
        $blocklistCall | Should -BeLessThan $commit
        Should -Invoke Invoke-IwaGraph -Times 1 -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/files' -and $Body.name -eq 'IntunePackage.intunewin' -and $Body.size -eq 99 -and $Body.sizeEncrypted -eq 13 }
        Should -Invoke Invoke-IwaGraph -Times 1 -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/commit' -and $Body.fileEncryptionInfo.encryptionKey -eq 'a2V5' }
        Should -Invoke Invoke-IwaGraph -Times 1 -ParameterFilter { $Method -eq 'PATCH' -and $Body.committedContentVersion -eq 'cv1' }
    }

    It 'reports progress after each block' {
        $script:progress = New-Object System.Collections.Generic.List[long]
        Publish-IwaWin32AppContent -AppId 'app1' -Package $package -ContentFile $content -ChunkSizeBytes 5 -OnProgress { param($sent, $total) $script:progress.Add($sent) } | Out-Null
        @($script:progress) | Should -Be @(5, 10, 13)
    }

    It 'renews the SAS URI when it gets old' {
        Publish-IwaWin32AppContent -AppId 'app1' -Package $package -ContentFile $content -ChunkSizeBytes 5 -SasRenewSeconds 0 | Out-Null
        Should -Invoke Invoke-IwaGraph -Times 3 -ParameterFilter { $Uri -like '*/renewUpload' }
        Should -Invoke Wait-IwaContentFileState -Times 3 -ParameterFilter { $State -eq 'azureStorageUriRenewal' }
    }

    It 'keeps the previous content version when the commit fails' {
        Mock Wait-IwaContentFileState {
            if ($State -eq 'commitFile') { throw "Intune reported 'commitFileFailed' for the package upload." }
            [pscustomobject]@{ azureStorageUri = 'https://blob.example/c?sv=1&sig=x' }
        }
        { Publish-IwaWin32AppContent -AppId 'app1' -Package $package -ContentFile $content -ChunkSizeBytes 5 } | Should -Throw '*commitFileFailed*'
        Should -Invoke Invoke-IwaGraph -Times 0 -ParameterFilter { $Method -eq 'PATCH' }
        { Publish-IwaWin32AppContent -AppId 'app1' -Package $package -ContentFile $content -ChunkSizeBytes 5 -AppBody ([ordered]@{ displayName = 'Contoso Tool' }) } | Should -Throw '*commitFileFailed*'
        Should -Invoke Invoke-IwaGraph -Times 0 -ParameterFilter { $Method -eq 'PATCH' }
    }

    It 'applies the app settings in the same PATCH as the new content version' {
        Publish-IwaWin32AppContent -AppId 'app1' -Package $package -ContentFile $content -ChunkSizeBytes 5 -AppBody ([ordered]@{ displayName = 'Contoso Tool'; installCommandLine = 'setup.exe /S' }) | Out-Null
        Should -Invoke Invoke-IwaGraph -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
        Should -Invoke Invoke-IwaGraph -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PATCH' -and $Body.displayName -eq 'Contoso Tool' -and $Body.installCommandLine -eq 'setup.exe /S' -and
            $Body.committedContentVersion -eq 'cv1' -and $Body['@odata.type'] -eq '#microsoft.graph.win32LobApp'
        }
    }

    It 'retries the activation PATCH while Intune is not ready, then gives up' {
        $script:patches = 0
        Mock Invoke-IwaGraph -ParameterFilter { $Method -eq 'PATCH' } { $script:patches++; if ($script:patches -lt 2) { throw 'BadRequest' } }
        Publish-IwaWin32AppContent -AppId 'app1' -Package $package -ContentFile $content -ChunkSizeBytes 5 -ActivationRetrySeconds 0 | Should -Be 'cv1'
        $script:patches | Should -Be 2

        Mock Invoke-IwaGraph -ParameterFilter { $Method -eq 'PATCH' } { throw 'BadRequest' }
        { Publish-IwaWin32AppContent -AppId 'app1' -Package $package -ContentFile $content -ChunkSizeBytes 5 -ActivationAttempts 3 -ActivationRetrySeconds 0 } | Should -Throw '*BadRequest*'
    }
}

Describe 'Test-IwaTransientHttpError' {
    It 'retries network errors, timeouts, throttling and server errors only' {
        $record = { param($status)
            $ex = New-Object System.Exception 'failed'
            if ($null -ne $status) { $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $status }) }
            New-Object System.Management.Automation.ErrorRecord $ex, 'x', 'NotSpecified', $null
        }
        Test-IwaTransientHttpError -ErrorRecord (& $record $null) | Should -BeTrue
        foreach ($status in 408, 429, 500, 503) { Test-IwaTransientHttpError -ErrorRecord (& $record $status) | Should -BeTrue -Because $status }
        foreach ($status in 400, 403, 404) { Test-IwaTransientHttpError -ErrorRecord (& $record $status) | Should -BeFalse -Because $status }
    }
}

Describe 'Graph module and account' {
    It 'finds the Graph module only when it is installed' {
        Mock Get-Module { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } } -ParameterFilter { $ListAvailable }
        Test-IwaGraphModule | Should -BeTrue
        Mock Get-Module { } -ParameterFilter { $ListAvailable }
        Test-IwaGraphModule | Should -BeFalse
    }
    It 'returns the account only with the Intune apps scope' {
        if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) { function script:Get-MgContext { } }
        Mock Get-MgContext { [pscustomobject]@{ Account = 'admin@contoso.com'; Scopes = @('User.Read', 'DeviceManagementApps.ReadWrite.All') } }
        Get-IwaIntuneAccount | Should -Be 'admin@contoso.com'
        Mock Get-MgContext { [pscustomobject]@{ Account = 'admin@contoso.com'; Scopes = @('User.Read') } }
        Get-IwaIntuneAccount | Should -BeNullOrEmpty
        Mock Get-MgContext { }
        Get-IwaIntuneAccount | Should -BeNullOrEmpty
    }
}

Describe 'Custom app registration (#30)' {
    BeforeAll {
        if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) { function script:Connect-MgGraph { param($Scopes, $ClientId, $TenantId, [switch]$NoWelcome) } }
        if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) { function script:Get-MgContext { } }
        $customId = '11111111-2222-3333-4444-555555555555'
    }
    It 'accepts both values empty, or a client GUID with a tenant GUID or domain' {
        Test-IwaConnectionSetting | Should -BeNullOrEmpty
        Test-IwaConnectionSetting -ClientId $customId -TenantId '00000000-0000-0000-0000-000000000000' | Should -BeNullOrEmpty
        Test-IwaConnectionSetting -ClientId " $customId " -TenantId 'contoso.onmicrosoft.com' | Should -BeNullOrEmpty
    }
    It 'rejects one value without the other, a client id that is not a GUID and a bad tenant' {
        Test-IwaConnectionSetting -ClientId $customId | Should -BeLike 'Fill in both*'
        Test-IwaConnectionSetting -TenantId 'contoso.onmicrosoft.com' | Should -BeLike 'Fill in both*'
        Test-IwaConnectionSetting -ClientId 'contoso-app' -TenantId 'contoso.onmicrosoft.com' | Should -BeLike 'The Client ID*'
        Test-IwaConnectionSetting -ClientId $customId -TenantId 'contoso' | Should -BeLike 'The Tenant ID*'
    }
    It 'signs in with the custom app only when one is set' {
        Mock Import-Module { }
        Mock Connect-MgGraph { }
        Mock Get-MgContext { }
        Connect-IwaIntune | Out-Null
        Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { -not $ClientId -and -not $TenantId -and $Scopes -eq 'DeviceManagementApps.ReadWrite.All' }
        Connect-IwaIntune -ClientId $customId -TenantId 'contoso.onmicrosoft.com' | Out-Null
        Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { $ClientId -eq $customId -and $TenantId -eq 'contoso.onmicrosoft.com' }
    }
    It 'counts a session only when it uses the configured app' {
        Mock Get-MgContext { [pscustomobject]@{ Account = 'admin@contoso.com'; ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'; Scopes = @('DeviceManagementApps.ReadWrite.All') } }
        Get-IwaIntuneAccount | Should -Be 'admin@contoso.com'
        Get-IwaIntuneAccount -ClientId $customId | Should -BeNullOrEmpty
        Mock Get-MgContext { [pscustomobject]@{ Account = 'admin@contoso.com'; ClientId = $customId; Scopes = @('DeviceManagementApps.ReadWrite.All') } }
        Get-IwaIntuneAccount -ClientId $customId | Should -Be 'admin@contoso.com'
        Get-IwaIntuneAccount | Should -BeNullOrEmpty
    }
    It 'explains the usual app registration sign-in errors' {
        Get-IwaSignInErrorMessage -Message 'AADSTS700016: Application not found' -CustomApp | Should -BeLike 'The app registration was not found*'
        Get-IwaSignInErrorMessage -Message 'AADSTS7000218: client_assertion or client_secret' -CustomApp | Should -BeLike '*Allow public client flows*'
        Get-IwaSignInErrorMessage -Message 'AADSTS50011: redirect URI' -CustomApp | Should -BeLike '*http://localhost*'
        Get-IwaSignInErrorMessage -Message 'AADSTS65001: consent' -CustomApp | Should -BeLike '*on your app registration*'
        Get-IwaSignInErrorMessage -Message 'AADSTS65001: consent' | Should -BeLike '*"Microsoft Graph Command Line Tools"*'
        Get-IwaSignInErrorMessage -Message 'boom' | Should -Be 'Sign-in failed: boom'
    }
}
