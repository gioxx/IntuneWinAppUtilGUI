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
        Should -Invoke Invoke-IwaGraph -Times 1 -ParameterFilter { $Uri -like "*isof('microsoft.graph.win32LobApp')*" }
    }
    It 'returns every app with an empty search and handles an empty page' {
        Mock Invoke-IwaGraph { [pscustomobject]@{ value = @() } }
        @(Get-IwaWin32App).Count | Should -Be 0
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
        $package = [pscustomobject]@{ UnencryptedSize = 99; EncryptionInfo = [ordered]@{ encryptionKey = 'a2V5' } }
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
        Should -Invoke Invoke-IwaGraph -Times 1 -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/files' -and $Body.size -eq 99 -and $Body.sizeEncrypted -eq 13 }
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
    }
}
