$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'scripts\CommMonitor.InstallHelpers.psm1'
Import-Module $modulePath -Force

Describe 'CommMonitor multi-string filter helpers' {
    It 'appends CommMonitorFilter without changing existing order' {
        $actual = @(Add-MultiStringValue `
            -Values @('serenum', 'VendorAudit') `
            -Entry 'CommMonitorFilter')

        ($actual -join '|') | Should Be 'serenum|VendorAudit|CommMonitorFilter'
    }

    It 'does not add a case-insensitive duplicate' {
        $actual = @(Add-MultiStringValue `
            -Values @('serenum', 'commmonitorfilter', 'VendorAudit') `
            -Entry 'CommMonitorFilter')

        ($actual -join '|') | Should Be 'serenum|commmonitorfilter|VendorAudit'
    }

    It 'removes only CommMonitorFilter and preserves unrelated entries' {
        $actual = @(Remove-MultiStringValue `
            -Values @('serenum', 'CommMonitorFilter', 'VendorAudit') `
            -Entry 'CommMonitorFilter')

        ($actual -join '|') | Should Be 'serenum|VendorAudit'
    }
}

Describe 'CommMonitor backup serialization' {
    It 'round-trips the exact original UpperFilters order and duplicates' {
        $original = @('serenum', 'VendorAudit', 'serenum')
        $backup = New-CommMonitorInstallBackup `
            -UpperFiltersPresent $true `
            -UpperFilters $original `
            -KernelServiceState 'Running' `
            -UserServiceState 'Stopped' `
            -DriverTarget 'C:\Windows\System32\drivers\old.sys' `
            -InstallPath 'C:\Program Files\CommMonitor'

        $restored = ConvertFrom-CommMonitorInstallBackupJson `
            (ConvertTo-CommMonitorInstallBackupJson $backup)

        $restored.UpperFiltersPresent | Should Be $true
        $restored.UpperFiltersWasNull | Should Be $false
        (@($restored.UpperFilters) -join '|') | Should Be ($original -join '|')
        $restored.KernelServiceState | Should Be 'Running'
        $restored.DriverTarget | Should Be 'C:\Windows\System32\drivers\old.sys'
    }

    It 'distinguishes a missing registry value from a present empty value' {
        $missing = New-CommMonitorInstallBackup `
            -UpperFiltersPresent $false `
            -UpperFilters $null
        $presentEmpty = New-CommMonitorInstallBackup `
            -UpperFiltersPresent $true `
            -UpperFilters @()

        $missingRoundTrip = ConvertFrom-CommMonitorInstallBackupJson `
            (ConvertTo-CommMonitorInstallBackupJson $missing)
        $emptyRoundTrip = ConvertFrom-CommMonitorInstallBackupJson `
            (ConvertTo-CommMonitorInstallBackupJson $presentEmpty)

        $missingRoundTrip.UpperFiltersPresent | Should Be $false
        $missingRoundTrip.UpperFiltersWasNull | Should Be $true
        $emptyRoundTrip.UpperFiltersPresent | Should Be $true
        $emptyRoundTrip.UpperFiltersWasNull | Should Be $false
        @($emptyRoundTrip.UpperFilters).Count | Should Be 0
    }
}

Describe 'CommMonitor administrator guard' {
    It 'stops before invoking any write when elevation is missing' {
        $script:writeCount = 0

        {
            Invoke-CommMonitorAdminGuardedAction `
                -AdministratorProbe { $false } `
                -WriteAction { $script:writeCount++ }
        } | Should Throw

        $script:writeCount | Should Be 0
    }

    It 'invokes the write exactly once after the administrator check succeeds' {
        $script:writeCount = 0

        Invoke-CommMonitorAdminGuardedAction `
            -AdministratorProbe { $true } `
            -WriteAction { $script:writeCount++ }

        $script:writeCount | Should Be 1
    }
}

Describe 'CommMonitor install path safety' {
    It 'accepts only the exact Program Files CommMonitor directory' {
        $programFiles = 'C:\Program Files'

        $actual = Resolve-CommMonitorInstallRoot `
            -InstallRoot 'C:\Program Files\CommMonitor\' `
            -ProgramFilesPath $programFiles

        $actual | Should Be 'C:\Program Files\CommMonitor'
        {
            Resolve-CommMonitorInstallRoot `
                -InstallRoot 'D:\CommMonitor' `
                -ProgramFilesPath $programFiles
        } | Should Throw
        {
            Resolve-CommMonitorInstallRoot `
                -InstallRoot 'C:\Program Files\Vendor\CommMonitor' `
                -ProgramFilesPath $programFiles
        } | Should Throw
    }

    It 'recognizes reparse-point attributes as unsafe' {
        (Test-CommMonitorReparseAttributes `
            -Attributes ([IO.FileAttributes]::Directory)) | Should Be $false
        (Test-CommMonitorReparseAttributes `
            -Attributes ([IO.FileAttributes]::Directory -bor `
                [IO.FileAttributes]::ReparsePoint)) | Should Be $true
    }

    It 'rejects untrusted owners and writable access rules' {
        $readOnlyUsers = @([pscustomobject]@{
                IdentitySid = 'S-1-5-32-545'
                AccessControlType = 'Allow'
                FileSystemRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute
            })
        $writableUsers = @([pscustomobject]@{
                IdentitySid = 'S-1-5-32-545'
                AccessControlType = 'Allow'
                FileSystemRights = [Security.AccessControl.FileSystemRights]::Modify
            })
        $writableCurrentUser = @([pscustomobject]@{
                IdentitySid = 'S-1-5-21-1-2-3-1001'
                AccessControlType = 'Allow'
                FileSystemRights = [Security.AccessControl.FileSystemRights]::Modify
            })

        (Test-CommMonitorAclTrusted `
            -OwnerSid 'S-1-5-32-544' `
            -AccessRules $readOnlyUsers) | Should Be $true
        (Test-CommMonitorAclTrusted `
            -OwnerSid 'S-1-5-32-545' `
            -AccessRules $readOnlyUsers) | Should Be $false
        (Test-CommMonitorAclTrusted `
            -OwnerSid 'S-1-5-18' `
            -AccessRules $writableUsers) | Should Be $false
        (Test-CommMonitorAclTrusted `
            -OwnerSid 'S-1-5-21-1-2-3-1001' `
            -AccessRules $writableCurrentUser `
            -AdditionalTrustedSids @('S-1-5-21-1-2-3-1001')) | Should Be $true
    }

    It 'uses CreateNew and atomic replacement for protected JSON files' {
        $moduleText = Get-Content -Raw -LiteralPath $modulePath

        $moduleText.Contains('[IO.FileMode]::CreateNew') | Should Be $true
        $moduleText.Contains('[IO.File]::Replace') | Should Be $true
        $moduleText.Contains('Assert-CommMonitorTrustedDirectory') | Should Be $true
    }

    It 'atomically replaces an existing protected text file on Windows PowerShell 5.1' {
        InModuleScope CommMonitor.InstallHelpers {
            Mock Assert-CommMonitorTrustedDirectory {}
            $testRoot = Join-Path $TestDrive 'atomic-replace'
            [void][IO.Directory]::CreateDirectory($testRoot)
            $targetPath = Join-Path $testRoot 'state.json'

            Write-CommMonitorAtomicTextFile -LiteralPath $targetPath -Value 'first'
            Write-CommMonitorAtomicTextFile -LiteralPath $targetPath -Value 'second'

            [IO.File]::ReadAllText($targetPath) | Should Be 'second'
            $remainingItems = @(Get-ChildItem -LiteralPath $testRoot -Force)
            $remainingItems.Count | Should Be 1
            $remainingItems[0].FullName | Should Be $targetPath
        }
    }

    It 'checks existing ancestors before inspecting the target tree' {
        $moduleText = Get-Content -Raw -LiteralPath $modulePath

        $moduleText.Contains('$ancestorPath') | Should Be $true
        $moduleText.Contains('[IO.Path]::GetPathRoot') | Should Be $true
    }

    It 'detects any file changed after a package manifest is captured' {
        $sourceRoot = Join-Path $TestDrive 'package'
        $serviceRoot = Join-Path $sourceRoot 'service'
        New-Item -ItemType Directory -Path $serviceRoot | Out-Null
        $serviceFile = Join-Path $serviceRoot 'CommMonitor.Service.exe'
        Set-Content -LiteralPath $serviceFile -Value 'trusted' -Encoding ASCII

        $before = Get-CommMonitorFileManifest -Root $sourceRoot
        Set-Content -LiteralPath $serviceFile -Value 'changed' -Encoding ASCII
        $after = Get-CommMonitorFileManifest -Root $sourceRoot

        (Test-CommMonitorFileManifestMatch `
            -Expected $before `
            -Actual $before) | Should Be $true
        (Test-CommMonitorFileManifestMatch `
            -Expected $before `
            -Actual $after) | Should Be $false
    }
}

Describe 'CommMonitor exact uninstall identity' {
    It 'round-trips the exact published name path hashes and service image paths' {
        $backup = New-CommMonitorInstallBackup `
            -UpperFiltersPresent $false `
            -UpperFilters $null `
            -DriverPackagePublishedName 'oem42.inf' `
            -DriverPackageOriginalFileName 'C:\Windows\System32\DriverStore\FileRepository\cmon\CommMonitor.Driver.inf' `
            -DriverPackageInfSha256 ('A' * 64) `
            -KernelServiceImagePath '\SystemRoot\System32\DriverStore\FileRepository\cmon\CommMonitor.Driver.sys' `
            -UserServiceImagePath '"C:\Program Files\CommMonitor\service\CommMonitor.Service.exe"'

        $restored = ConvertFrom-CommMonitorInstallBackupJson `
            (ConvertTo-CommMonitorInstallBackupJson $backup)

        $restored.DriverPackagePublishedName | Should Be 'oem42.inf'
        $restored.DriverPackageOriginalFileName | Should Be `
            'C:\Windows\System32\DriverStore\FileRepository\cmon\CommMonitor.Driver.inf'
        $restored.DriverPackageInfSha256 | Should Be ('A' * 64)
        $restored.KernelServiceImagePath | Should Be `
            '\SystemRoot\System32\DriverStore\FileRepository\cmon\CommMonitor.Driver.sys'
        $restored.UserServiceImagePath | Should Be `
            '"C:\Program Files\CommMonitor\service\CommMonitor.Service.exe"'
    }

    It 'requires every backed-up driver package field to match exactly' {
        (Test-CommMonitorDriverPackageRecord `
            -PublishedName 'oem42.inf' `
            -OriginalFileName 'C:\Store\CommMonitor.Driver.inf' `
            -InfSha256 ('A' * 64) `
            -ExpectedPublishedName 'OEM42.INF' `
            -ExpectedOriginalFileName 'c:\store\commmonitor.driver.inf' `
            -ExpectedInfSha256 ('a' * 64)) | Should Be $true

        (Test-CommMonitorDriverPackageRecord `
            -PublishedName 'oem43.inf' `
            -OriginalFileName 'C:\Store\CommMonitor.Driver.inf' `
            -InfSha256 ('A' * 64) `
            -ExpectedPublishedName 'oem42.inf' `
            -ExpectedOriginalFileName 'C:\Store\CommMonitor.Driver.inf' `
            -ExpectedInfSha256 ('A' * 64)) | Should Be $false
    }

    It 'compares service executable paths without substring matches' {
        (Test-CommMonitorServiceImagePath `
            -ImagePath '"C:\Program Files\CommMonitor\service\CommMonitor.Service.exe" --service' `
            -ExpectedExecutable 'C:\Program Files\CommMonitor\service\CommMonitor.Service.exe') |
            Should Be $true
        (Test-CommMonitorServiceImagePath `
            -ImagePath '"C:\Program Files\CommMonitor\service\CommMonitor.Service.exe.evil"' `
            -ExpectedExecutable 'C:\Program Files\CommMonitor\service\CommMonitor.Service.exe') |
            Should Be $false

        $driverTail =
            'System32\DriverStore\FileRepository\cmon\CommMonitor.Driver.sys'
        (Test-CommMonitorServiceImagePath `
            -ImagePath (Join-Path $env:SystemRoot $driverTail) `
            -ExpectedExecutable ('\SystemRoot\' + $driverTail)) |
            Should Be $true
        (Test-CommMonitorServiceImagePath `
            -ImagePath (Join-Path $env:SystemRoot $driverTail) `
            -ExpectedExecutable ('\SystemRootEvil\' + $driverTail)) |
            Should Be $false
    }

    It 'selects only exact packages whose published names were absent before install' {
        $packages = @(
            [pscustomobject]@{ Driver = 'oem10.inf' },
            [pscustomobject]@{ Driver = 'oem11.inf' },
            [pscustomobject]@{ Driver = 'oem12.inf' }
        )

        $actual = @(Get-CommMonitorNewDriverPackageCandidates `
            -DriverPackages $packages `
            -PublishedNamesBefore @('OEM10.INF', 'oem12.inf'))

        $actual.Count | Should Be 1
        $actual[0].Driver | Should Be 'oem11.inf'
        @(Get-CommMonitorNewDriverPackageCandidates `
            -DriverPackages @($packages[0]) `
            -PublishedNamesBefore @('oem10.inf')).Count | Should Be 0
        @(Get-CommMonitorNewDriverPackageCandidates `
            -DriverPackages $packages `
            -PublishedNamesBefore @()).Count | Should Be 3
    }
}

Describe 'CommMonitor install marker' {
    It 'validates the product path and protected backup identity' {
        $marker = New-CommMonitorInstallMarker `
            -InstallPath 'C:\Program Files\CommMonitor' `
            -BackupPath 'C:\ProgramData\CommMonitor\install-backup.latest.json' `
            -BackupSha256 ('B' * 64) `
            -InstallId '11111111-1111-1111-1111-111111111111'

        (Test-CommMonitorInstallMarker `
            -Marker $marker `
            -ExpectedInstallPath 'c:\program files\commmonitor' `
            -ExpectedBackupPath 'c:\programdata\commmonitor\install-backup.latest.json' `
            -ExpectedBackupSha256 ('b' * 64)) | Should Be $true

        $marker.Product = 'NotCommMonitor'
        (Test-CommMonitorInstallMarker `
            -Marker $marker `
            -ExpectedInstallPath 'C:\Program Files\CommMonitor' `
            -ExpectedBackupPath 'C:\ProgramData\CommMonitor\install-backup.latest.json' `
            -ExpectedBackupSha256 ('B' * 64)) | Should Be $false
    }
}

Describe 'CommMonitor native exit handling' {
    It 'treats PnPUtil success and reboot-required as success' {
        (Test-CommMonitorNativeExitCode -ExitCode 0 -SuccessExitCodes @(0, 3010)) |
            Should Be $true
        (Test-CommMonitorNativeExitCode -ExitCode 3010 -SuccessExitCodes @(0, 3010)) |
            Should Be $true
        (Test-CommMonitorNativeExitCode -ExitCode 1 -SuccessExitCodes @(0, 3010)) |
            Should Be $false
    }

    It 'recognizes English and localized Chinese test-signing enabled values' {
        (Test-CommMonitorTestSigningOutput -Output "testsigning Yes") |
            Should Be $true
        $localizedYes = [char]0x662F
        (Test-CommMonitorTestSigningOutput `
            -Output ("testsigning {0}" -f $localizedYes)) | Should Be $true
        (Test-CommMonitorTestSigningOutput -Output "testsigning No") |
            Should Be $false
    }
}

Describe 'CommMonitor install script safety structure' {
    $installPath = Join-Path $repoRoot 'scripts\Install-CommMonitor.ps1'
    $uninstallPath = Join-Path $repoRoot 'scripts\Uninstall-CommMonitor.ps1'
    $installText = Get-Content -Raw -LiteralPath $installPath
    $uninstallText = Get-Content -Raw -LiteralPath $uninstallPath

    It 'checks elevation before payload validation and every mutation' {
        $guardIndex = $installText.IndexOf(
            'if (-not (Test-CommMonitorAdministrator))',
            [StringComparison]::Ordinal)
        $manifestIndex = $installText.IndexOf(
            'Assert-LemonPayloadManifest',
            [StringComparison]::Ordinal)
        $mutationIndex = $installText.IndexOf(
            'Invoke-LemonMutationTransaction -Steps',
            [StringComparison]::Ordinal)

        ($guardIndex -ge 0) | Should Be $true
        ($manifestIndex -gt $guardIndex) | Should Be $true
        ($mutationIndex -gt $manifestIndex) | Should Be $true
    }

    It 'uses the exact Ports class key in install and uninstall' {
        $classGuid = '{4D36E978-E325-11CE-BFC1-08002BE10318}'

        $installText.Contains($classGuid) | Should Be $true
        $uninstallText.Contains($classGuid) | Should Be $true
    }

    It 'never changes Secure Boot or test-signing configuration' {
        $mutatingBootPattern = '(?im)bcdedit(?:\.exe)?\s+/(?:set|deletevalue)'

        ($installText -match $mutatingBootPattern) | Should Be $false
        ($uninstallText -match $mutatingBootPattern) | Should Be $false
    }

    It 'uses language-neutral test-signing patterns compatible with Windows PowerShell 5.1' {
        $statusText = Get-Content -Raw -LiteralPath (
            Join-Path $repoRoot 'scripts\Get-CommMonitorStatus.ps1')

        [regex]::IsMatch($installText, '[^\x00-\x7F]') | Should Be $false
        [regex]::IsMatch($statusText, '[^\x00-\x7F]') | Should Be $false
        $installText.Contains('Test-CommMonitorTestSigningOutput') | Should Be $true
        $statusText.Contains('Test-CommMonitorTestSigningOutput') | Should Be $true
    }

    It 'queries kernel drivers and user services through their correct CIM classes' {
        $statusText = Get-Content -Raw -LiteralPath (
            Join-Path $repoRoot 'scripts\Get-CommMonitorStatus.ps1')

        $statusText.Contains("ValidateSet('Win32_Service', 'Win32_SystemDriver')") |
            Should Be $true
        ($statusText -match '(?s)\$kernelService\s*=\s*Get-LemonServiceStatus.+?-ClassName\s+Win32_SystemDriver') |
            Should Be $true
        ($statusText -match '(?s)\$userService\s*=\s*Get-LemonServiceStatus.+?-ClassName\s+Win32_Service') |
            Should Be $true
    }

    It 'avoids return-if syntax that Windows PowerShell 5.1 executes as a command' {
        $scriptPaths = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -File |
            Where-Object { $_.Extension -in @('.ps1', '.psm1') }

        foreach ($scriptPath in $scriptPaths) {
            $scriptText = Get-Content -Raw -LiteralPath $scriptPath.FullName
            ($scriptText -match '(?m)\breturn\s+if\s*\(') | Should Be $false
        }
    }

    It 'guards all install roots and deletion with the exact path reparse and marker checks' {
        $statusText = Get-Content -Raw -LiteralPath (
            Join-Path $repoRoot 'scripts\Get-CommMonitorStatus.ps1')

        $installText.Contains('Resolve-CommMonitorOwnershipRoots') | Should Be $true
        $installText.Contains('-InstallMode $Mode') | Should Be $true
        $uninstallText.Contains('ConvertTo-LemonCanonicalLocalPath') | Should Be $true
        $uninstallText.Contains('Assert-CommMonitorNoReparsePoint') | Should Be $true
        $installText.Contains('Set-CommMonitorRestrictedAcl') | Should Be $true
        $installText.Contains('Assert-CommMonitorTrustedPackageTree') | Should Be $true
        $installText.Contains('Write-CommMonitorAtomicTextFile') | Should Be $true
        $uninstallText.Contains('Assert-CommMonitorTrustedDirectory') | Should Be $true
        $uninstallText.Contains('Test-CommMonitorServiceImagePath') | Should Be $true
    }

    It 'refuses pre-existing services and a non-empty install root instead of taking them over' {
        $installText.Contains("An existing internal service '`$serviceName' must be removed before a fresh install.") |
            Should Be $true
        $installText.Contains('Resolve-CommMonitorOwnershipRoots') | Should Be $true
        $installText.Contains('-InstallMode $Mode') | Should Be $true
        $installText.Contains('''config'', $userServiceName') | Should Be $true
        $installText.Contains("if (`$Mode -eq 'Migrate')") | Should Be $true
        $installText.Contains('Get-LemonAuthenticatedMigrationState') |
            Should Be $true
    }

    It 'trust-checks the package tree and compares source and installed manifests' {
        $installText.Contains('Assert-CommMonitorTrustedPackageTree') | Should Be $true
        $installText.Contains('Assert-LemonPayloadManifest') | Should Be $true
        $installText.Contains('$payloadManifest') | Should Be $true
        $installText.Contains('$deployedAiSha256') | Should Be $true
        $installText.Contains('$aiClientPackageSha256') | Should Be $true
    }

    It 'rolls back only changes made by the failed install attempt' {
        $installText.Contains('Invoke-LemonMutationTransaction -Steps') | Should Be $true
        $installText.Contains('$context.Certificate') | Should Be $true
        $installText.Contains('$context.UserServiceCreated') | Should Be $true
        $installText.Contains('$context.UpperFiltersBefore') | Should Be $true
        $installText.Contains('$context.PnpMutationSucceeded') | Should Be $true
        $installText.Contains('$context.DriverPackagesBefore') | Should Be $true
    }

    It 'records PnP mutation before exact package discovery and recovers the failure window' {
        $pnpAddIndex = $installText.IndexOf(
            "-ArgumentList @('/add-driver', `$sourceInf, '/install')",
            [StringComparison]::Ordinal)
        $mutationIndex = $installText.IndexOf(
            '$context.PnpMutationSucceeded = $true',
            $pnpAddIndex,
            [StringComparison]::Ordinal)
        $discoveryIndex = $installText.IndexOf(
            '$after = @(Get-LemonDriverPackagesByInfHash',
            $pnpAddIndex,
            [StringComparison]::Ordinal)

        ($pnpAddIndex -ge 0) | Should Be $true
        ($mutationIndex -gt $pnpAddIndex) | Should Be $true
        ($discoveryIndex -gt $mutationIndex) | Should Be $true
        $installText.Contains('elseif ($context.PnpMutationSucceeded)') | Should Be $true
        $installText.Contains('$context.DriverPackagesBefore') | Should Be $true
        $installText.Contains('$rollbackCandidates.Count -eq 1') | Should Be $true
        $installText.Contains('$rollbackCandidates.Count -gt 1') | Should Be $true
        $installText.Contains('refused ambiguous deletion') | Should Be $true
        $installText.Contains('$context.DriverSourceInfSha256') | Should Be $true
    }

    It 'never enumerates driver packages by a shared original INF filename' {
        ($uninstallText -match "GetFileName\([^\r\n]+OriginalFileName") |
            Should Be $false
        $uninstallText.Contains('$state.Driver.PublishedName') | Should Be $true
        $uninstallText.Contains('$state.Driver.OriginalFileName') | Should Be $true
        $uninstallText.Contains('$state.Driver.InfSha256') | Should Be $true
        $uninstallText.Contains('Test-CommMonitorDriverPackageRecord') | Should Be $true
        $uninstallText.Contains('Test-CommMonitorServiceImagePath') | Should Be $true
    }

    It 'parses every shipped install script without AST errors' {
        foreach ($path in @(
                $installPath,
                $uninstallPath,
                (Join-Path $repoRoot 'scripts\Get-CommMonitorStatus.ps1'),
                $modulePath)) {
            $tokens = $null
            $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref]$tokens,
                [ref]$parseErrors)
            @($parseErrors).Count | Should Be 0
        }
    }

    It 'captures rollback evidence before certificate service driver or filter changes' {
        $snapshotIndex = $installText.IndexOf(
            '$context.UpperFiltersBefore = Get-LemonUpperFiltersSnapshot',
            [StringComparison]::Ordinal)
        $certificateIndex = $installText.IndexOf(
            'Import-Certificate',
            $snapshotIndex,
            [StringComparison]::Ordinal)
        $driverSnapshotIndex = $installText.IndexOf(
            '$context.DriverPackagesBefore = [string[]]$beforeDriverNames',
            $snapshotIndex,
            [StringComparison]::Ordinal)
        $filterIndex = $installText.IndexOf(
            'Set-LemonUpperFiltersSnapshot -Present $true',
            $snapshotIndex,
            [StringComparison]::Ordinal)

        ($snapshotIndex -ge 0) | Should Be $true
        ($certificateIndex -gt $snapshotIndex) | Should Be $true
        ($driverSnapshotIndex -gt $snapshotIndex) | Should Be $true
        ($filterIndex -gt $driverSnapshotIndex) | Should Be $true
    }

    It 'creates only a non-exportable signing key and never writes a PFX' {
        $signingText = Get-Content -Raw -LiteralPath (
            Join-Path $repoRoot 'scripts\Test-SignDriver.ps1')

        $signingText.Contains('-KeyExportPolicy NonExportable') | Should Be $true
        ($signingText -match '(?i)Export-PfxCertificate|\.pfx') | Should Be $false
    }

    It 'signs SYS before Inf2Cat hashes it and signs CAT afterwards' {
        $signingText = Get-Content -Raw -LiteralPath (
            Join-Path $repoRoot 'scripts\Test-SignDriver.ps1')
        $sysSign = $signingText.IndexOf(
            '($signArguments + $sysPath)',
            [StringComparison]::Ordinal)
        $inf2Cat = $signingText.IndexOf(
            'Invoke-SigningTool -FilePath $inf2Cat',
            [StringComparison]::Ordinal)
        $catSign = $signingText.IndexOf(
            '($signArguments + $catPath)',
            [StringComparison]::Ordinal)

        ($sysSign -ge 0) | Should Be $true
        ($inf2Cat -gt $sysSign) | Should Be $true
        ($catSign -gt $inf2Cat) | Should Be $true
    }
}

Describe 'CommMonitor package documentation layout' {
    $buildText = Get-Content -Raw -LiteralPath (
        Join-Path $repoRoot 'scripts\Build-All.ps1')

    It 'keeps the acceptance record in source without creating a self-referential payload' {
        Test-Path -LiteralPath (Join-Path $repoRoot `
                'tests\manual\lemon-installer-acceptance.md') -PathType Leaf |
            Should Be $true
        $buildText | Should Not Match 'acceptanceOutput'
        $buildText | Should Not Match 'tests\\manual'
    }
}
