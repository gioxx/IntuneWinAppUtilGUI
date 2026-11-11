BeforeAll {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-IntunePackage.ps1')

    function New-TestIntuneWin {
        param([string]$Path, [string]$DetectionXml, [byte[]]$Content = [byte[]](1..10))
        $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            if ($DetectionXml) {
                $writer = New-Object System.IO.StreamWriter($zip.CreateEntry('IntuneWinPackage/Metadata/Detection.xml').Open())
                try { $writer.Write($DetectionXml) } finally { $writer.Dispose() }
            }
            $stream = $zip.CreateEntry('IntuneWinPackage/Contents/IntunePackage.intunewin').Open()
            try { $stream.Write($Content, 0, $Content.Length) } finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
    }

    $exeXml = @'
<?xml version="1.0" encoding="utf-8"?>
<ApplicationInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ToolVersion="1.8.6.0">
  <Name>setup.exe</Name>
  <UnencryptedContentSize>2048</UnencryptedContentSize>
  <FileName>IntunePackage.intunewin</FileName>
  <SetupFile>setup.exe</SetupFile>
  <EncryptionInfo>
    <EncryptionKey>a2V5</EncryptionKey>
    <MacKey>bWFj</MacKey>
    <InitializationVector>aXY=</InitializationVector>
    <Mac>bWFjdmFs</Mac>
    <ProfileIdentifier>ProfileVersion1</ProfileIdentifier>
    <FileDigest>ZGlnZXN0</FileDigest>
    <FileDigestAlgorithm>SHA256</FileDigestAlgorithm>
  </EncryptionInfo>
</ApplicationInfo>
'@
    $msiInfoXml = @'
</EncryptionInfo>
  <MsiInfo>
    <MsiProductCode>{11111111-2222-3333-4444-555555555555}</MsiProductCode>
    <MsiProductVersion>2.1.0</MsiProductVersion>
    <MsiPackageCode>{00000000-0000-0000-0000-000000000000}</MsiPackageCode>
    <MsiUpgradeCode>{66666666-7777-8888-9999-000000000000}</MsiUpgradeCode>
    <MsiExecutionContext>System</MsiExecutionContext>
    <MsiRequiresLogon>false</MsiRequiresLogon>
    <MsiRequiresReboot>false</MsiRequiresReboot>
    <MsiIsMachineInstall>true</MsiIsMachineInstall>
    <MsiIsUserInstall>false</MsiIsUserInstall>
    <MsiIncludesServices>false</MsiIncludesServices>
    <MsiIncludesODBCDataSource>false</MsiIncludesODBCDataSource>
    <MsiContainsSystemRegistryKeys>false</MsiContainsSystemRegistryKeys>
    <MsiContainsSystemFolders>false</MsiContainsSystemFolders>
    <MsiPublisher>Contoso Ltd</MsiPublisher>
  </MsiInfo>
'@
    $msiXml = $exeXml.Replace('<Name>setup.exe</Name>', '<Name>Contoso Tool</Name>').Replace('<SetupFile>setup.exe</SetupFile>', '<SetupFile>contoso-tool.msi</SetupFile>').Replace('</EncryptionInfo>', $msiInfoXml)
}

Describe 'Read-IwaIntuneWinPackage' {
    It 'reads sizes, setup file and encryption info' {
        $path = Join-Path $TestDrive 'exe.intunewin'
        New-TestIntuneWin -Path $path -DetectionXml $exeXml
        $p = Read-IwaIntuneWinPackage -Path $path
        $p.Name | Should -Be 'setup.exe'
        $p.SetupFile | Should -Be 'setup.exe'
        $p.UnencryptedSize | Should -Be 2048
        $p.EncryptedSize | Should -Be 10
        $p.ContentEntry | Should -Be 'IntuneWinPackage/Contents/IntunePackage.intunewin'
        $p.FileName | Should -Be 'IntunePackage.intunewin'
        $p.EncryptionInfo.encryptionKey | Should -Be 'a2V5'
        $p.EncryptionInfo.profileIdentifier | Should -Be 'ProfileVersion1'
        $p.EncryptionInfo.fileDigestAlgorithm | Should -Be 'SHA256'
        $p.MsiInfo | Should -BeNullOrEmpty
    }

    It 'reads the MSI information when present' {
        $path = Join-Path $TestDrive 'msi.intunewin'
        New-TestIntuneWin -Path $path -DetectionXml $msiXml
        $p = Read-IwaIntuneWinPackage -Path $path
        $p.Name | Should -Be 'Contoso Tool'
        $p.MsiInfo.ProductCode | Should -Be '{11111111-2222-3333-4444-555555555555}'
        $p.MsiInfo.ProductVersion | Should -Be '2.1.0'
        $p.MsiInfo.UpgradeCode | Should -Be '{66666666-7777-8888-9999-000000000000}'
        $p.MsiInfo.Publisher | Should -Be 'Contoso Ltd'
        $p.MsiInfo.ExecutionContext | Should -Be 'System'
        $p.MsiInfo.RequiresReboot | Should -BeFalse
    }

    It 'rejects a missing file' {
        { Read-IwaIntuneWinPackage -Path (Join-Path $TestDrive 'nope.intunewin') } | Should -Throw '*Package not found*'
    }

    It 'rejects a file that is not a zip' {
        $path = Join-Path $TestDrive 'text.intunewin'
        Set-Content -Path $path -Value 'not a zip'
        { Read-IwaIntuneWinPackage -Path $path } | Should -Throw '*is not a valid .intunewin package*'
    }

    It 'rejects a Detection.xml that is not valid XML' {
        $path = Join-Path $TestDrive 'broken-xml.intunewin'
        New-TestIntuneWin -Path $path -DetectionXml '<ApplicationInfo><Name>setup.exe</Name>'
        { Read-IwaIntuneWinPackage -Path $path } | Should -Throw '*is not a valid .intunewin package: its Detection.xml cannot be read.'
    }
    It 'rejects a Detection.xml without encryption data' {
        $path = Join-Path $TestDrive 'no-encryption.intunewin'
        New-TestIntuneWin -Path $path -DetectionXml '<?xml version="1.0" encoding="utf-8"?><ApplicationInfo><Name>setup.exe</Name></ApplicationInfo>'
        { Read-IwaIntuneWinPackage -Path $path } | Should -Throw '*has no application or encryption data.'
    }
    It 'rejects a zip without Detection.xml' {
        $path = Join-Path $TestDrive 'nodetection.intunewin'
        New-TestIntuneWin -Path $path -DetectionXml ''
        { Read-IwaIntuneWinPackage -Path $path } | Should -Throw '*Detection.xml*'
    }
}

Describe 'Expand-IwaIntuneWinContent' {
    It 'extracts the encrypted content with the same bytes' {
        $path = Join-Path $TestDrive 'expand.intunewin'
        New-TestIntuneWin -Path $path -DetectionXml $exeXml -Content ([byte[]](5..20))
        $p = Read-IwaIntuneWinPackage -Path $path
        $file = Expand-IwaIntuneWinContent -Package $p -Destination (Join-Path $TestDrive 'out')
        Split-Path $file -Leaf | Should -Be 'IntunePackage.intunewin'
        [System.IO.File]::ReadAllBytes($file) | Should -Be ([byte[]](5..20))
    }
}
