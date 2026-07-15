$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'scripts\Lemon.Platform.psm1'
Import-Module $modulePath -Force

Describe 'Lemon Windows platform contract' {
    It 'supports Windows Server 2019 Desktop Experience' {
        $actual = Resolve-LemonWindowsPlatform `
            -ProductType 3 `
            -BuildNumber 17763 `
            -InstallationType 'Server' `
            -Is64BitOperatingSystem $true

        $actual.Supported | Should Be $true
        $actual.PlatformKind | Should Be 'ServerDesktop'
        $actual.DisplayName | Should Be 'Windows Server 2019 Desktop Experience'
        (@($actual.Components) -join '|') |
            Should Be 'Driver|Service|AiInterface|Documentation|DesktopApp|StartMenuShortcut'
    }

    It 'supports Windows Server 2022 Core without desktop components' {
        $actual = Resolve-LemonWindowsPlatform `
            -ProductType 3 `
            -BuildNumber 20348 `
            -InstallationType 'Server Core' `
            -Is64BitOperatingSystem $true

        $actual.Supported | Should Be $true
        $actual.PlatformKind | Should Be 'ServerCore'
        $actual.DisplayName | Should Be 'Windows Server 2022 Server Core'
        (@($actual.Components) -join '|') |
            Should Be 'Driver|Service|AiInterface|Documentation'
        @($actual.Components) -contains 'DesktopApp' | Should Be $false
        @($actual.Components) -contains 'StartMenuShortcut' | Should Be $false
    }

    It 'supports a Windows Server 2025 domain controller installation' {
        $actual = Resolve-LemonWindowsPlatform `
            -ProductType 2 `
            -BuildNumber 26100 `
            -InstallationType 'Server' `
            -Is64BitOperatingSystem $true

        $actual.Supported | Should Be $true
        $actual.PlatformKind | Should Be 'ServerDesktop'
        $actual.DisplayName | Should Be 'Windows Server 2025 Desktop Experience'
    }

    It 'matches installation type without depending on English casing' {
        $actual = Resolve-LemonWindowsPlatform `
            -ProductType 3 `
            -BuildNumber 26100 `
            -InstallationType 'server core' `
            -Is64BitOperatingSystem $true

        $actual.Supported | Should Be $true
        $actual.PlatformKind | Should Be 'ServerCore'
    }

    It 'covers every supported Server release mode and product type' {
        $releases = @(
            [pscustomobject]@{ Build = 17763; Name = '2019' },
            [pscustomobject]@{ Build = 20348; Name = '2022' },
            [pscustomobject]@{ Build = 26100; Name = '2025' }
        )
        foreach ($release in $releases) {
            foreach ($productType in @(2, 3)) {
                foreach ($installationType in @('Server', 'Server Core')) {
                    $actual = Resolve-LemonWindowsPlatform `
                        -ProductType $productType `
                        -BuildNumber $release.Build `
                        -InstallationType $installationType `
                        -Is64BitOperatingSystem $true

                    $actual.Supported | Should Be $true
                    $actual.DisplayName.Contains($release.Name) | Should Be $true
                    if ($installationType -eq 'Server Core') {
                        $actual.PlatformKind | Should Be 'ServerCore'
                        @($actual.Components) -contains 'DesktopApp' |
                            Should Be $false
                    }
                    else {
                        $actual.PlatformKind | Should Be 'ServerDesktop'
                        @($actual.Components) -contains 'DesktopApp' |
                            Should Be $true
                    }
                }
            }
        }
    }

    It 'fails closed for Server 2016 and unknown future Server builds' {
        $server2016 = Resolve-LemonWindowsPlatform `
            -ProductType 3 `
            -BuildNumber 14393 `
            -InstallationType 'Server' `
            -Is64BitOperatingSystem $true
        $futureServer = Resolve-LemonWindowsPlatform `
            -ProductType 3 `
            -BuildNumber 27000 `
            -InstallationType 'Server' `
            -Is64BitOperatingSystem $true

        $server2016.Supported | Should Be $false
        $server2016.ReasonCode | Should Be 'UnsupportedServerBuild'
        $futureServer.Supported | Should Be $false
        $futureServer.ReasonCode | Should Be 'UnsupportedServerBuild'
        @($futureServer.Components).Count | Should Be 0
    }

    It 'fails closed for an unknown Server installation type' {
        $actual = Resolve-LemonWindowsPlatform `
            -ProductType 3 `
            -BuildNumber 20348 `
            -InstallationType 'Server Minimal Interface' `
            -Is64BitOperatingSystem $true

        $actual.Supported | Should Be $false
        $actual.ReasonCode | Should Be 'UnsupportedInstallationType'
    }

    It 'rejects all 32-bit operating systems before selecting components' {
        $actual = Resolve-LemonWindowsPlatform `
            -ProductType 3 `
            -BuildNumber 20348 `
            -InstallationType 'Server Core' `
            -Is64BitOperatingSystem $false

        $actual.Supported | Should Be $false
        $actual.ReasonCode | Should Be 'X64Required'
        @($actual.Components).Count | Should Be 0
    }

    It 'preserves supported Windows 10 and Windows 11 desktop installs' {
        $windows10 = Resolve-LemonWindowsPlatform `
            -ProductType 1 `
            -BuildNumber 19045 `
            -InstallationType 'Client' `
            -Is64BitOperatingSystem $true
        $windows11 = Resolve-LemonWindowsPlatform `
            -ProductType 1 `
            -BuildNumber 26100 `
            -InstallationType 'Client' `
            -Is64BitOperatingSystem $true

        $windows10.Supported | Should Be $true
        $windows10.PlatformKind | Should Be 'ClientDesktop'
        $windows10.DisplayName | Should Be 'Windows 10'
        $windows11.Supported | Should Be $true
        $windows11.PlatformKind | Should Be 'ClientDesktop'
        $windows11.DisplayName | Should Be 'Windows 11'
        @($windows11.Components) -contains 'DesktopApp' | Should Be $true
    }

    It 'builds a headless install layout for Server Core' {
        $platform = Resolve-LemonWindowsPlatform `
            -ProductType 3 `
            -BuildNumber 20348 `
            -InstallationType 'Server Core' `
            -Is64BitOperatingSystem $true

        $layout = Get-LemonInstallLayout -Platform $platform

        $layout.InstallDesktopApp | Should Be $false
        $layout.CreateStartMenuShortcut | Should Be $false
        (@($layout.PackageDirectories) -join '|') |
            Should Be 'service|ai|helper|driver|scripts|docs'
        (@($layout.InstallDirectories) -join '|') |
            Should Be 'service|ai|helper|driver|scripts|docs'
        @($layout.RequiredRelativePaths) -contains 'app\Lemon.SerialMonitor.exe' |
            Should Be $false
        @($layout.RequiredRelativePaths) -contains 'service\CommMonitor.Service.exe' |
            Should Be $true
        @($layout.RequiredRelativePaths) -contains 'docs\INSTALL.md' |
            Should Be $true
    }

    It 'builds a complete desktop install layout for Client and Server Desktop' {
        $client = Resolve-LemonWindowsPlatform `
            -ProductType 1 `
            -BuildNumber 26100 `
            -InstallationType 'Client' `
            -Is64BitOperatingSystem $true
        $server = Resolve-LemonWindowsPlatform `
            -ProductType 3 `
            -BuildNumber 26100 `
            -InstallationType 'Server' `
            -Is64BitOperatingSystem $true

        foreach ($platform in @($client, $server)) {
            $layout = Get-LemonInstallLayout -Platform $platform

            $layout.InstallDesktopApp | Should Be $true
            $layout.CreateStartMenuShortcut | Should Be $true
            (@($layout.PackageDirectories) -join '|') |
                Should Be 'app|service|ai|helper|driver|scripts|docs'
            @($layout.RequiredRelativePaths) -contains 'app\Lemon.SerialMonitor.exe' |
                Should Be $true
        }
    }

    It 'refuses to create an install layout from unsupported or inconsistent input' {
        $unsupported = Resolve-LemonWindowsPlatform `
            -ProductType 3 `
            -BuildNumber 14393 `
            -InstallationType 'Server Core' `
            -Is64BitOperatingSystem $true
        $inconsistent = [pscustomobject]@{
            Supported = $true
            Components = @('Driver', 'Service', 'DesktopApp')
        }
        $desktopWithoutShortcut = [pscustomobject]@{
            Supported = $true
            Components = @(
                'Driver',
                'Service',
                'AiInterface',
                'Documentation',
                'DesktopApp')
        }

        { Get-LemonInstallLayout -Platform $unsupported } | Should Throw
        { Get-LemonInstallLayout -Platform $inconsistent } | Should Throw
        { Get-LemonInstallLayout -Platform $desktopWithoutShortcut } |
            Should Throw
    }

    It 'creates and removes only the owned common Start Menu shortcut' {
        $installRoot = Join-Path $TestDrive 'install'
        $appRoot = Join-Path $installRoot 'app'
        $commonPrograms = Join-Path $TestDrive 'CommonPrograms'
        [void][IO.Directory]::CreateDirectory($appRoot)
        [void][IO.Directory]::CreateDirectory($commonPrograms)
        Set-Content `
            -LiteralPath (Join-Path $appRoot 'Lemon.SerialMonitor.exe') `
            -Value 'app' `
            -Encoding ASCII
        $plan = Get-LemonStartMenuShortcutPlan `
            -InstallRoot $installRoot `
            -CommonProgramsRoot $commonPrograms
        $plan.TargetPath | Should Be (
            Join-Path $appRoot 'Lemon.SerialMonitor.exe')

        $record = New-LemonStartMenuShortcut `
            -Plan $plan `
            -ShortcutWriter {
                param($writerPlan)
                [IO.File]::WriteAllText(
                    $writerPlan.ShortcutPath,
                    'shortcut-bytes',
                    [Text.Encoding]::ASCII)
            }

        $record.ShortcutCreated | Should Be $true
        $record.DirectoryCreated | Should Be $true
        $record.ShortcutSha256 | Should Match '^[0-9A-F]{64}$'
        (Test-LemonStartMenuShortcutOwnership `
            -Record $record `
            -Plan $plan) | Should Be $true

        $removed = Remove-LemonStartMenuShortcut -Record $record -Plan $plan

        $removed.ShortcutRemoved | Should Be $true
        $removed.DirectoryRemoved | Should Be $true
        Test-Path -LiteralPath $plan.ShortcutPath | Should Be $false
        Test-Path -LiteralPath $plan.DirectoryPath | Should Be $false
    }

    It 'refuses to remove a changed shortcut and leaves it intact' {
        $installRoot = Join-Path $TestDrive 'tamper-install'
        $appRoot = Join-Path $installRoot 'app'
        $commonPrograms = Join-Path $TestDrive 'TamperPrograms'
        [void][IO.Directory]::CreateDirectory($appRoot)
        [void][IO.Directory]::CreateDirectory($commonPrograms)
        Set-Content `
            -LiteralPath (Join-Path $appRoot 'Lemon.SerialMonitor.exe') `
            -Value 'app' `
            -Encoding ASCII
        $plan = Get-LemonStartMenuShortcutPlan `
            -InstallRoot $installRoot `
            -CommonProgramsRoot $commonPrograms
        $record = New-LemonStartMenuShortcut `
            -Plan $plan `
            -ShortcutWriter {
                param($writerPlan)
                [IO.File]::WriteAllText(
                    $writerPlan.ShortcutPath,
                    'original',
                    [Text.Encoding]::ASCII)
            }
        [IO.File]::WriteAllText(
            $plan.ShortcutPath,
            'changed',
            [Text.Encoding]::ASCII)

        (Test-LemonStartMenuShortcutOwnership `
            -Record $record `
            -Plan $plan) | Should Be $false
        { Remove-LemonStartMenuShortcut -Record $record -Plan $plan } |
            Should Throw
        Test-Path -LiteralPath $plan.ShortcutPath | Should Be $true
    }

    It 'refuses a junctioned Start Menu directory without deleting its target' {
        $installRoot = Join-Path $TestDrive 'junction-install'
        $appRoot = Join-Path $installRoot 'app'
        $commonPrograms = Join-Path $TestDrive 'JunctionPrograms'
        $outsideDirectory = Join-Path $TestDrive 'OutsideProductDirectory'
        [void][IO.Directory]::CreateDirectory($appRoot)
        [void][IO.Directory]::CreateDirectory($commonPrograms)
        [void][IO.Directory]::CreateDirectory($outsideDirectory)
        Set-Content `
            -LiteralPath (Join-Path $appRoot 'Lemon.SerialMonitor.exe') `
            -Value 'app' `
            -Encoding ASCII
        $plan = Get-LemonStartMenuShortcutPlan `
            -InstallRoot $installRoot `
            -CommonProgramsRoot $commonPrograms
        $outsideShortcut = Join-Path $outsideDirectory (
            [IO.Path]::GetFileName($plan.ShortcutPath))
        [IO.File]::WriteAllText(
            $outsideShortcut,
            'outside-shortcut',
            [Text.Encoding]::ASCII)
        [void](New-Item `
                -ItemType Junction `
                -Path $plan.DirectoryPath `
                -Target $outsideDirectory)
        $record = [pscustomobject][ordered]@{
            ShortcutCreated = $true
            ShortcutPath = $plan.ShortcutPath
            ShortcutSha256 = (Get-FileHash `
                    -LiteralPath $outsideShortcut `
                    -Algorithm SHA256).Hash
            DirectoryPath = $plan.DirectoryPath
            DirectoryCreated = $true
        }

        (Test-LemonStartMenuShortcutOwnership `
            -Record $record `
            -Plan $plan) | Should Be $false
        { Remove-LemonStartMenuShortcut -Record $record -Plan $plan } |
            Should Throw
        Test-Path -LiteralPath $outsideShortcut -PathType Leaf |
            Should Be $true
    }

    It 'refuses a junction in a Start Menu ancestor without deleting its target' {
        $installRoot = Join-Path $TestDrive 'ancestor-junction-install'
        $appRoot = Join-Path $installRoot 'app'
        $outsideAncestor = Join-Path $TestDrive 'OutsideProgramsAncestor'
        $outsidePrograms = Join-Path $outsideAncestor 'Programs'
        $junctionAncestor = Join-Path $TestDrive 'JunctionProgramsAncestor'
        [void][IO.Directory]::CreateDirectory($appRoot)
        [void][IO.Directory]::CreateDirectory($outsidePrograms)
        Set-Content `
            -LiteralPath (Join-Path $appRoot 'Lemon.SerialMonitor.exe') `
            -Value 'app' `
            -Encoding ASCII
        [void](New-Item `
                -ItemType Junction `
                -Path $junctionAncestor `
                -Target $outsideAncestor)
        $plan = Get-LemonStartMenuShortcutPlan `
            -InstallRoot $installRoot `
            -CommonProgramsRoot (Join-Path $junctionAncestor 'Programs')
        [void][IO.Directory]::CreateDirectory(
            (Join-Path $outsidePrograms $plan.DisplayName))
        $outsideShortcut = Join-Path `
            (Join-Path $outsidePrograms $plan.DisplayName) `
            ([IO.Path]::GetFileName($plan.ShortcutPath))
        [IO.File]::WriteAllText(
            $outsideShortcut,
            'outside-ancestor-shortcut',
            [Text.Encoding]::ASCII)
        $record = [pscustomobject][ordered]@{
            ShortcutCreated = $true
            ShortcutPath = $plan.ShortcutPath
            ShortcutSha256 = (Get-FileHash `
                    -LiteralPath $outsideShortcut `
                    -Algorithm SHA256).Hash
            DirectoryPath = $plan.DirectoryPath
            DirectoryCreated = $true
        }

        (Test-LemonStartMenuShortcutOwnership `
            -Record $record `
            -Plan $plan) | Should Be $false
        { Remove-LemonStartMenuShortcut -Record $record -Plan $plan } |
            Should Throw
        Test-Path -LiteralPath $outsideShortcut -PathType Leaf |
            Should Be $true
    }

    It 'rejects a Start Menu directory swapped by the shortcut writer' {
        $installRoot = Join-Path $TestDrive 'writer-swap-install'
        $appRoot = Join-Path $installRoot 'app'
        $commonPrograms = Join-Path $TestDrive 'WriterSwapPrograms'
        $outsideDirectory = Join-Path $TestDrive 'WriterSwapOutside'
        [void][IO.Directory]::CreateDirectory($appRoot)
        [void][IO.Directory]::CreateDirectory($commonPrograms)
        [void][IO.Directory]::CreateDirectory($outsideDirectory)
        Set-Content `
            -LiteralPath (Join-Path $appRoot 'Lemon.SerialMonitor.exe') `
            -Value 'app' `
            -Encoding ASCII
        $plan = Get-LemonStartMenuShortcutPlan `
            -InstallRoot $installRoot `
            -CommonProgramsRoot $commonPrograms
        $outsideShortcut = Join-Path $outsideDirectory (
            [IO.Path]::GetFileName($plan.ShortcutPath))

        {
            New-LemonStartMenuShortcut `
                -Plan $plan `
                -ShortcutWriter {
                    param($writerPlan)
                    Remove-Item `
                        -LiteralPath $writerPlan.DirectoryPath `
                        -Force
                    [void](New-Item `
                            -ItemType Junction `
                            -Path $writerPlan.DirectoryPath `
                            -Target $outsideDirectory)
                    [IO.File]::WriteAllText(
                        $writerPlan.ShortcutPath,
                        'writer-swapped-shortcut',
                        [Text.Encoding]::ASCII)
                }
        } | Should Throw
        Test-Path -LiteralPath $outsideShortcut -PathType Leaf |
            Should Be $true
    }

    It 'does not delete a shortcut that appears after absence validation' {
        $installRoot = Join-Path $TestDrive 'late-shortcut-install'
        $appRoot = Join-Path $installRoot 'app'
        $commonPrograms = Join-Path $TestDrive 'LateShortcutPrograms'
        [void][IO.Directory]::CreateDirectory($appRoot)
        [void][IO.Directory]::CreateDirectory($commonPrograms)
        Set-Content `
            -LiteralPath (Join-Path $appRoot 'Lemon.SerialMonitor.exe') `
            -Value 'app' `
            -Encoding ASCII
        $global:LemonLateShortcutPlan = Get-LemonStartMenuShortcutPlan `
            -InstallRoot $installRoot `
            -CommonProgramsRoot $commonPrograms
        [void][IO.Directory]::CreateDirectory(
            $global:LemonLateShortcutPlan.DirectoryPath)
        $global:LemonLateShortcutRecord = [pscustomobject][ordered]@{
            ShortcutCreated = $true
            ShortcutPath = $global:LemonLateShortcutPlan.ShortcutPath
            ShortcutSha256 = ('0' * 64)
            DirectoryPath = $global:LemonLateShortcutPlan.DirectoryPath
            DirectoryCreated = $true
        }

        try {
            InModuleScope Lemon.Platform {
                Mock Test-LemonStartMenuShortcutOwnership {
                    [IO.File]::WriteAllText(
                        $global:LemonLateShortcutPlan.ShortcutPath,
                        'appeared-after-validation',
                        [Text.Encoding]::ASCII)
                    return $true
                }

                $removed = Remove-LemonStartMenuShortcut `
                    -Record $global:LemonLateShortcutRecord `
                    -Plan $global:LemonLateShortcutPlan

                $removed.ShortcutRemoved | Should Be $false
                Test-Path `
                    -LiteralPath $global:LemonLateShortcutPlan.ShortcutPath `
                    -PathType Leaf |
                    Should Be $true
            }
        }
        finally {
            Remove-Variable LemonLateShortcutPlan -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable LemonLateShortcutRecord -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'rejects unsupported client builds and mismatched installation types' {
        $oldClient = Resolve-LemonWindowsPlatform `
            -ProductType 1 `
            -BuildNumber 9600 `
            -InstallationType 'Client' `
            -Is64BitOperatingSystem $true
        $mismatchedClient = Resolve-LemonWindowsPlatform `
            -ProductType 1 `
            -BuildNumber 19045 `
            -InstallationType 'Server' `
            -Is64BitOperatingSystem $true

        $oldClient.Supported | Should Be $false
        $oldClient.ReasonCode | Should Be 'UnsupportedClientBuild'
        $mismatchedClient.Supported | Should Be $false
        $mismatchedClient.ReasonCode | Should Be 'ProductTypeMismatch'
    }

    It 'maps registry product types without using WMI' {
        (ConvertFrom-LemonRegistryProductType -ProductType 'WinNT') |
            Should Be 1
        (ConvertFrom-LemonRegistryProductType -ProductType 'LanmanNT') |
            Should Be 2
        (ConvertFrom-LemonRegistryProductType -ProductType 'ServerNT') |
            Should Be 3
        {
            ConvertFrom-LemonRegistryProductType -ProductType 'UnknownNT'
        } | Should Throw

        $moduleText = Get-Content -Raw -LiteralPath $modulePath
        $moduleText.Contains('Get-CimInstance') | Should Be $false
        $moduleText.Contains('Win32_OperatingSystem') | Should Be $false
    }

    It 'collects the current platform through injectable read-only probes' {
        $actual = Get-LemonWindowsPlatform `
            -CurrentVersionProbe {
                [pscustomobject]@{
                    CurrentBuildNumber = '20348'
                    InstallationType = 'Server Core'
                }
            } `
            -ProductOptionsProbe {
                [pscustomobject]@{ ProductType = 'ServerNT' }
            } `
            -Is64BitProbe { $true }

        $actual.Supported | Should Be $true
        $actual.PlatformKind | Should Be 'ServerCore'
        $actual.BuildNumber | Should Be 20348
    }

    It 'returns a stable probe failure instead of guessing platform support' {
        $actual = Get-LemonWindowsPlatform `
            -CurrentVersionProbe { throw 'registry unavailable' } `
            -ProductOptionsProbe { throw 'must not run after first failure' } `
            -Is64BitProbe { $true }

        $actual.Supported | Should Be $false
        $actual.ReasonCode | Should Be 'PlatformProbeFailed'
        @($actual.Components).Count | Should Be 0
    }

    It 'fails closed when registry probe values are malformed or incomplete' {
        $invalidBuild = Get-LemonWindowsPlatform `
            -CurrentVersionProbe {
                [pscustomobject]@{
                    CurrentBuildNumber = 'not-a-build'
                    InstallationType = 'Server'
                }
            } `
            -ProductOptionsProbe {
                [pscustomobject]@{ ProductType = 'ServerNT' }
            } `
            -Is64BitProbe { $true }
        $missingInstallationType = Get-LemonWindowsPlatform `
            -CurrentVersionProbe {
                [pscustomobject]@{ CurrentBuildNumber = '20348' }
            } `
            -ProductOptionsProbe {
                [pscustomobject]@{ ProductType = 'ServerNT' }
            } `
            -Is64BitProbe { $true }

        $invalidBuild.Supported | Should Be $false
        $invalidBuild.ReasonCode | Should Be 'PlatformProbeFailed'
        $missingInstallationType.Supported | Should Be $false
        $missingInstallationType.ReasonCode | Should Be 'PlatformProbeFailed'
    }

    It 'wires the same platform contract into install and status scripts' {
        $installPath = Join-Path $repoRoot 'scripts\Install-CommMonitor.ps1'
        $statusPath = Join-Path $repoRoot 'scripts\Get-CommMonitorStatus.ps1'
        $installText = Get-Content -Raw -LiteralPath $installPath
        $statusText = Get-Content -Raw -LiteralPath $statusPath
        $uninstallPath = Join-Path $repoRoot 'scripts\Uninstall-CommMonitor.ps1'
        $uninstallText = Get-Content -Raw -LiteralPath $uninstallPath

        $installText.Contains("Import-Module (Join-Path `$PSScriptRoot 'Lemon.Platform.psm1') -Force") |
            Should Be $true
        ($installText -match '(?s)function Assert-LemonSupportedHost.+?Get-LemonWindowsPlatform') |
            Should Be $true
        $installText.Contains('$platform = Assert-LemonSupportedHost') |
            Should Be $true
        $installText.Contains('$installLayout = Get-LemonInstallLayout -Platform $platform') |
            Should Be $true
        $installText.Contains('$installLayout.RequiredRelativePaths') |
            Should Be $true
        $installText.Contains('Assert-LemonPayloadManifest') | Should Be $true
        $platformText = Get-Content -Raw -LiteralPath (
            Join-Path $repoRoot 'scripts\Lemon.Platform.psm1')
        foreach ($directoryName in @(
                'app', 'service', 'ai', 'helper', 'driver', 'scripts', 'docs')) {
            $platformText.Contains("'$directoryName'") | Should Be $true
        }
        $installText.Contains('New-LemonStartMenuShortcut') | Should Be $true
        $installText.Contains('Remove-LemonStartMenuShortcut') | Should Be $true
        $installText.Contains('$context.Shortcut') | Should Be $true

        $uninstallText.Contains("Import-Module (Join-Path `$PSScriptRoot 'Lemon.Platform.psm1') -Force") |
            Should Be $true
        $uninstallText.Contains('Test-LemonStartMenuShortcutOwnership') |
            Should Be $true
        $uninstallText.Contains('Remove-LemonStartMenuShortcut') |
            Should Be $true

        $statusText.Contains("Import-Module (Join-Path `$PSScriptRoot 'Lemon.Platform.psm1') -Force") |
            Should Be $true
        $statusText.Contains('$platform = Get-LemonWindowsPlatform') |
            Should Be $true
        $statusText.Contains('Platform = $platform') |
            Should Be $true
    }

    It 'runs hosted compatibility checks on Server 2022 and Server 2025' {
        $workflowPath = Join-Path $repoRoot `
            '.github\workflows\windows-server-compat.yml'
        $workflowText = Get-Content -Raw -LiteralPath $workflowPath

        $workflowText.Contains('windows-2022') | Should Be $true
        $workflowText.Contains('windows-2025') | Should Be $true
        $workflowText.Contains('Get-LemonWindowsPlatform') | Should Be $true
        $workflowText.Contains('LemonPlatform.Tests.ps1') | Should Be $true
        $workflowText.Contains('dotnet test') | Should Be $true
        $workflowText.Contains('Server 2019 requires a self-hosted VM') |
            Should Be $true
        $workflowText.Contains('does not install the kernel driver') |
            Should Be $true
    }
}
