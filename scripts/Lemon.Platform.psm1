Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-LemonPlatformResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $Supported,
        [Parameter(Mandatory)][string] $PlatformKind,
        [Parameter(Mandatory)][AllowEmptyString()][string] $DisplayName,
        [Parameter(Mandatory)][int] $ProductType,
        [Parameter(Mandatory)][int] $BuildNumber,
        [AllowNull()][string] $InstallationType,
        [Parameter(Mandatory)][bool] $Is64BitOperatingSystem,
        [AllowEmptyCollection()][string[]] $Components = @(),
        [AllowEmptyString()][string] $ReasonCode = ''
    )

    return [pscustomobject][ordered]@{
        Supported = $Supported
        PlatformKind = $PlatformKind
        DisplayName = $DisplayName
        ProductType = $ProductType
        BuildNumber = $BuildNumber
        InstallationType = $InstallationType
        Is64BitOperatingSystem = $Is64BitOperatingSystem
        Components = @($Components)
        ReasonCode = $ReasonCode
    }
}

function New-LemonUnsupportedPlatformResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ReasonCode,
        [int] $ProductType = 0,
        [int] $BuildNumber = 0,
        [AllowNull()][string] $InstallationType,
        [bool] $Is64BitOperatingSystem = $false
    )

    return New-LemonPlatformResult `
        -Supported $false `
        -PlatformKind 'Unsupported' `
        -DisplayName '' `
        -ProductType $ProductType `
        -BuildNumber $BuildNumber `
        -InstallationType $InstallationType `
        -Is64BitOperatingSystem $Is64BitOperatingSystem `
        -Components @() `
        -ReasonCode $ReasonCode
}

function Resolve-LemonWindowsPlatform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $ProductType,
        [Parameter(Mandatory)][int] $BuildNumber,
        [Parameter(Mandatory)][AllowEmptyString()][string] $InstallationType,
        [Parameter(Mandatory)][bool] $Is64BitOperatingSystem
    )

    if (-not $Is64BitOperatingSystem) {
        return New-LemonUnsupportedPlatformResult `
            -ReasonCode 'X64Required' `
            -ProductType $ProductType `
            -BuildNumber $BuildNumber `
            -InstallationType $InstallationType `
            -Is64BitOperatingSystem $false
    }

    $desktopComponents = @(
        'Driver',
        'Service',
        'AiInterface',
        'Documentation',
        'DesktopApp',
        'StartMenuShortcut'
    )
    $coreComponents = @(
        'Driver',
        'Service',
        'AiInterface',
        'Documentation'
    )

    if ($ProductType -eq 1) {
        if (-not [string]::Equals(
                $InstallationType,
                'Client',
                [StringComparison]::OrdinalIgnoreCase)) {
            return New-LemonUnsupportedPlatformResult `
                -ReasonCode 'ProductTypeMismatch' `
                -ProductType $ProductType `
                -BuildNumber $BuildNumber `
                -InstallationType $InstallationType `
                -Is64BitOperatingSystem $true
        }
        if ($BuildNumber -lt 10240) {
            return New-LemonUnsupportedPlatformResult `
                -ReasonCode 'UnsupportedClientBuild' `
                -ProductType $ProductType `
                -BuildNumber $BuildNumber `
                -InstallationType $InstallationType `
                -Is64BitOperatingSystem $true
        }

        $displayName = if ($BuildNumber -ge 22000) {
            'Windows 11'
        }
        else {
            'Windows 10'
        }
        return New-LemonPlatformResult `
            -Supported $true `
            -PlatformKind 'ClientDesktop' `
            -DisplayName $displayName `
            -ProductType $ProductType `
            -BuildNumber $BuildNumber `
            -InstallationType $InstallationType `
            -Is64BitOperatingSystem $true `
            -Components $desktopComponents
    }

    if ($ProductType -notin @(2, 3)) {
        return New-LemonUnsupportedPlatformResult `
            -ReasonCode 'UnsupportedProductType' `
            -ProductType $ProductType `
            -BuildNumber $BuildNumber `
            -InstallationType $InstallationType `
            -Is64BitOperatingSystem $true
    }

    $serverRelease = switch ($BuildNumber) {
        17763 { '2019'; break }
        20348 { '2022'; break }
        26100 { '2025'; break }
        default { $null }
    }
    if ($null -eq $serverRelease) {
        return New-LemonUnsupportedPlatformResult `
            -ReasonCode 'UnsupportedServerBuild' `
            -ProductType $ProductType `
            -BuildNumber $BuildNumber `
            -InstallationType $InstallationType `
            -Is64BitOperatingSystem $true
    }

    if ([string]::Equals(
            $InstallationType,
            'Server Core',
            [StringComparison]::OrdinalIgnoreCase)) {
        return New-LemonPlatformResult `
            -Supported $true `
            -PlatformKind 'ServerCore' `
            -DisplayName "Windows Server $serverRelease Server Core" `
            -ProductType $ProductType `
            -BuildNumber $BuildNumber `
            -InstallationType $InstallationType `
            -Is64BitOperatingSystem $true `
            -Components $coreComponents
    }

    if ([string]::Equals(
            $InstallationType,
            'Server',
            [StringComparison]::OrdinalIgnoreCase)) {
        return New-LemonPlatformResult `
            -Supported $true `
            -PlatformKind 'ServerDesktop' `
            -DisplayName "Windows Server $serverRelease Desktop Experience" `
            -ProductType $ProductType `
            -BuildNumber $BuildNumber `
            -InstallationType $InstallationType `
            -Is64BitOperatingSystem $true `
            -Components $desktopComponents
    }

    return New-LemonUnsupportedPlatformResult `
        -ReasonCode 'UnsupportedInstallationType' `
        -ProductType $ProductType `
        -BuildNumber $BuildNumber `
        -InstallationType $InstallationType `
        -Is64BitOperatingSystem $true
}

function Get-LemonInstallLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject] $Platform
    )

    if ($null -eq $Platform.PSObject.Properties['Supported'] -or
        -not [bool]$Platform.Supported -or
        $null -eq $Platform.PSObject.Properties['Components']) {
        throw 'A supported Lemon Windows platform result is required.'
    }

    $components = @($Platform.Components | ForEach-Object { [string]$_ })
    $allowedComponents = @(
        'Driver',
        'Service',
        'AiInterface',
        'Documentation',
        'DesktopApp',
        'StartMenuShortcut'
    )
    foreach ($component in $components) {
        if ($allowedComponents -notcontains $component) {
            throw "Unsupported Lemon install component '$component'."
        }
    }
    foreach ($requiredComponent in @(
            'Driver',
            'Service',
            'AiInterface',
            'Documentation')) {
        if ($components -notcontains $requiredComponent) {
            throw "Required Lemon install component '$requiredComponent' is missing."
        }
    }

    $installDesktopApp = $components -contains 'DesktopApp'
    $createStartMenuShortcut = $components -contains 'StartMenuShortcut'
    if ($installDesktopApp -ne $createStartMenuShortcut) {
        throw 'Desktop app and Start Menu shortcut components must be selected together.'
    }
    $packageDirectories = if ($installDesktopApp) {
        @('app', 'service', 'ai', 'helper', 'driver', 'scripts', 'docs')
    }
    else {
        @('service', 'ai', 'helper', 'driver', 'scripts', 'docs')
    }
    $requiredRelativePaths = @(
        'service\CommMonitor.Service.exe',
        'ai\Lemon.SerialMonitor.AI.exe',
        'helper\Lemon.UninstallHelper.exe',
        'driver\CommMonitor.Driver.sys',
        'driver\CommMonitor.Driver.inf',
        'driver\CommMonitor.Driver.cat',
        'driver\CommMonitor.LocalTestDriver.cer',
        'scripts\Uninstall-CommMonitor.ps1',
        'scripts\Get-CommMonitorStatus.ps1',
        'scripts\CommMonitor.InstallHelpers.psm1',
        'scripts\Lemon.Platform.psm1',
        'scripts\Lemon.SetupTransactions.psm1',
        'docs\INSTALL.md',
        'docs\USER_GUIDE.md',
        'docs\TROUBLESHOOTING.md'
    )
    if ($installDesktopApp) {
        $requiredRelativePaths = @('app\Lemon.SerialMonitor.exe') +
            $requiredRelativePaths
    }

    return [pscustomobject][ordered]@{
        InstallDesktopApp = $installDesktopApp
        CreateStartMenuShortcut = $createStartMenuShortcut
        PackageDirectories = @($packageDirectories)
        InstallDirectories = @($packageDirectories)
        RequiredRelativePaths = @($requiredRelativePaths)
    }
}

function Get-LemonProductDisplayName {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $tail = -join ([char[]]@(
            0x4E32,
            0x53E3,
            0x76D1,
            0x63A7))
    return 'Lemon' + $tail
}

function Get-LemonStartMenuShortcutPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $InstallRoot,
        [string] $CommonProgramsRoot
    )

    if ([string]::IsNullOrWhiteSpace($CommonProgramsRoot)) {
        $CommonProgramsRoot = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::CommonPrograms)
    }
    if ([string]::IsNullOrWhiteSpace($CommonProgramsRoot)) {
        throw 'The common Start Menu Programs directory is unavailable.'
    }

    $resolvedInstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    $resolvedProgramsRoot = [IO.Path]::GetFullPath($CommonProgramsRoot).TrimEnd('\', '/')
    $displayName = Get-LemonProductDisplayName
    $directoryPath = Join-Path $resolvedProgramsRoot $displayName
    return [pscustomobject][ordered]@{
        DisplayName = $displayName
        CommonProgramsRoot = $resolvedProgramsRoot
        DirectoryPath = $directoryPath
        ShortcutPath = Join-Path $directoryPath ($displayName + '.lnk')
        TargetPath = Join-Path $resolvedInstallRoot 'app\Lemon.SerialMonitor.exe'
        WorkingDirectory = Join-Path $resolvedInstallRoot 'app'
        Description = 'Lemon serial monitor'
    }
}

function Test-LemonStartMenuPlanSafety {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject] $Plan
    )

    foreach ($name in @(
            'CommonProgramsRoot',
            'DirectoryPath',
            'ShortcutPath')) {
        if ($null -eq $Plan.PSObject.Properties[$name] -or
            [string]::IsNullOrWhiteSpace([string]$Plan.$name)) {
            return $false
        }
    }

    try {
        $programsRoot = [IO.Path]::GetFullPath(
            [string]$Plan.CommonProgramsRoot).TrimEnd('\', '/')
        $directoryPath = [IO.Path]::GetFullPath(
            [string]$Plan.DirectoryPath).TrimEnd('\', '/')
        $shortcutPath = [IO.Path]::GetFullPath([string]$Plan.ShortcutPath)
        if (-not [string]::Equals(
                [IO.Path]::GetDirectoryName($directoryPath),
                $programsRoot,
                [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals(
                [IO.Path]::GetDirectoryName($shortcutPath),
                $directoryPath,
                [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }

        if (-not (Test-LemonDirectoryChainWithoutReparsePoint `
                -Path $programsRoot)) {
            return $false
        }
        if ((Test-Path -LiteralPath $directoryPath) -and
            -not (Test-LemonDirectoryChainWithoutReparsePoint `
                -Path $directoryPath)) {
            return $false
        }

        if (Test-Path -LiteralPath $shortcutPath) {
            $shortcutItem = Get-Item -LiteralPath $shortcutPath -Force
            if ($shortcutItem.PSIsContainer -or
                ($shortcutItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $false
            }
        }

        return $true
    }
    catch {
        return $false
    }
}

function Test-LemonDirectoryChainWithoutReparsePoint {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Path
    )

    try {
        $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        $root = [IO.Path]::GetPathRoot($fullPath)
        if ([string]::IsNullOrWhiteSpace($root) -or
            $root.StartsWith('\\', [StringComparison]::Ordinal) -or
            -not (Test-Path -LiteralPath $root -PathType Container)) {
            return $false
        }

        $rootPath = [IO.Path]::GetFullPath($root)
        $rootItem = Get-Item -LiteralPath $rootPath -Force
        if (-not $rootItem.PSIsContainer -or
            ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        $relativePath = $fullPath.Substring($rootPath.Length)
        $components = $relativePath.Split(
            [char[]]@(
                [IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar),
            [StringSplitOptions]::RemoveEmptyEntries)
        $current = $rootPath
        foreach ($component in $components) {
            $current = Join-Path $current $component
            if (-not (Test-Path -LiteralPath $current -PathType Container)) {
                return $false
            }
            $item = Get-Item -LiteralPath $current -Force
            if (-not $item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $false
            }
        }

        return $true
    }
    catch {
        return $false
    }
}

function Test-LemonStartMenuShortcutOwnership {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject] $Record,
        [Parameter(Mandatory)][ValidateNotNull()][psobject] $Plan
    )

    foreach ($name in @(
            'ShortcutCreated',
            'ShortcutPath',
            'ShortcutSha256',
            'DirectoryPath',
            'DirectoryCreated')) {
        if ($null -eq $Record.PSObject.Properties[$name]) {
            return $false
        }
    }
    foreach ($name in @(
            'CommonProgramsRoot',
            'ShortcutPath',
            'DirectoryPath')) {
        if ($null -eq $Plan.PSObject.Properties[$name]) {
            return $false
        }
    }
    if (-not [bool]$Record.ShortcutCreated -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$Record.ShortcutPath),
            [IO.Path]::GetFullPath([string]$Plan.ShortcutPath),
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$Record.DirectoryPath),
            [IO.Path]::GetFullPath([string]$Plan.DirectoryPath),
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [regex]::IsMatch(
            [string]$Record.ShortcutSha256,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        return $false
    }

    if (-not (Test-LemonStartMenuPlanSafety -Plan $Plan)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $Plan.ShortcutPath -PathType Leaf)) {
        return $true
    }
    $item = Get-Item -LiteralPath $Plan.ShortcutPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
    }
    $actualHash = (Get-FileHash `
            -LiteralPath $Plan.ShortcutPath `
            -Algorithm SHA256).Hash
    return [string]::Equals(
        $actualHash,
        [string]$Record.ShortcutSha256,
        [StringComparison]::OrdinalIgnoreCase)
}

function New-LemonStartMenuShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject] $Plan,
        [scriptblock] $ShortcutWriter
    )

    foreach ($name in @(
            'ShortcutPath',
            'DirectoryPath',
            'TargetPath',
            'WorkingDirectory',
            'Description')) {
        if ($null -eq $Plan.PSObject.Properties[$name] -or
            [string]::IsNullOrWhiteSpace([string]$Plan.$name)) {
            throw "Shortcut plan field '$name' is missing."
        }
    }
    if (-not (Test-Path -LiteralPath $Plan.TargetPath -PathType Leaf)) {
        throw "Shortcut target not found: $($Plan.TargetPath)"
    }
    if (Test-Path -LiteralPath $Plan.ShortcutPath) {
        throw "Refusing to replace a pre-existing Start Menu shortcut: $($Plan.ShortcutPath)"
    }
    if (-not (Test-LemonStartMenuPlanSafety -Plan $Plan)) {
        throw 'Refusing an unsafe Start Menu path.'
    }

    $directoryCreated = $false
    try {
        if (Test-Path -LiteralPath $Plan.DirectoryPath) {
            $directory = Get-Item -LiteralPath $Plan.DirectoryPath -Force
            if (-not $directory.PSIsContainer -or
                ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing an unsafe Start Menu directory: $($Plan.DirectoryPath)"
            }
        }
        else {
            [void][IO.Directory]::CreateDirectory([string]$Plan.DirectoryPath)
            $directoryCreated = $true
        }
        if (-not (Test-LemonStartMenuPlanSafety -Plan $Plan)) {
            throw 'The Start Menu path became unsafe during creation.'
        }

        if ($null -ne $ShortcutWriter) {
            & $ShortcutWriter $Plan
        }
        else {
            $shell = $null
            $shortcut = $null
            try {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut([string]$Plan.ShortcutPath)
                $shortcut.TargetPath = [string]$Plan.TargetPath
                $shortcut.WorkingDirectory = [string]$Plan.WorkingDirectory
                $shortcut.Description = [string]$Plan.Description
                $shortcut.IconLocation = ([string]$Plan.TargetPath) + ',0'
                $shortcut.Save()
            }
            finally {
                if ($null -ne $shortcut) {
                    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject(
                        $shortcut)
                }
                if ($null -ne $shell) {
                    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject(
                        $shell)
                }
            }
        }

        if (-not (Test-LemonStartMenuPlanSafety -Plan $Plan)) {
            throw 'The Start Menu path became unsafe while writing the shortcut.'
        }
        if (-not (Test-Path -LiteralPath $Plan.ShortcutPath -PathType Leaf)) {
            throw 'The Start Menu shortcut writer did not create the expected file.'
        }
        $shortcutItem = Get-Item -LiteralPath $Plan.ShortcutPath -Force
        if (($shortcutItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The Start Menu shortcut is an unsafe reparse point.'
        }
        return [pscustomobject][ordered]@{
            ShortcutCreated = $true
            ShortcutPath = [IO.Path]::GetFullPath([string]$Plan.ShortcutPath)
            ShortcutSha256 = (Get-FileHash `
                    -LiteralPath $Plan.ShortcutPath `
                    -Algorithm SHA256).Hash
            DirectoryPath = [IO.Path]::GetFullPath([string]$Plan.DirectoryPath)
            DirectoryCreated = $directoryCreated
        }
    }
    catch {
        $pathSafe = Test-LemonStartMenuPlanSafety -Plan $Plan
        if ($pathSafe -and
            (Test-Path -LiteralPath $Plan.ShortcutPath -PathType Leaf)) {
            Remove-Item -LiteralPath $Plan.ShortcutPath -Force
        }
        if ($pathSafe -and
            $directoryCreated -and
            (Test-Path -LiteralPath $Plan.DirectoryPath -PathType Container) -and
            @(Get-ChildItem -LiteralPath $Plan.DirectoryPath -Force).Count -eq 0) {
            Remove-Item -LiteralPath $Plan.DirectoryPath -Force
        }
        throw
    }
}

function Remove-LemonStartMenuShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject] $Record,
        [Parameter(Mandatory)][ValidateNotNull()][psobject] $Plan
    )

    $shortcutExistedBeforeValidation = Test-Path `
        -LiteralPath $Plan.ShortcutPath `
        -PathType Leaf
    if (-not (Test-LemonStartMenuShortcutOwnership `
            -Record $Record `
            -Plan $Plan)) {
        throw 'Refusing to remove a Start Menu shortcut whose path or hash changed.'
    }

    $shortcutRemoved = $false
    if ($shortcutExistedBeforeValidation -and
        (Test-Path -LiteralPath $Plan.ShortcutPath -PathType Leaf)) {
        if (-not (Test-LemonStartMenuShortcutOwnership `
                -Record $Record `
                -Plan $Plan) -or
            -not (Test-LemonStartMenuPlanSafety -Plan $Plan)) {
            throw 'The Start Menu shortcut changed before removal.'
        }
        Remove-Item -LiteralPath $Plan.ShortcutPath -Force
        $shortcutRemoved = $true
    }
    $directoryRemoved = $false
    if ([bool]$Record.DirectoryCreated -and
        (Test-Path -LiteralPath $Plan.DirectoryPath -PathType Container)) {
        if (-not (Test-LemonStartMenuPlanSafety -Plan $Plan)) {
            throw 'Refusing to remove an unsafe Start Menu directory.'
        }
        if (@(Get-ChildItem -LiteralPath $Plan.DirectoryPath -Force).Count -eq 0) {
            Remove-Item -LiteralPath $Plan.DirectoryPath -Force
            $directoryRemoved = $true
        }
    }

    return [pscustomobject][ordered]@{
        ShortcutRemoved = $shortcutRemoved
        DirectoryRemoved = $directoryRemoved
    }
}

function ConvertFrom-LemonRegistryProductType {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ProductType
    )

    switch ($ProductType.Trim().ToUpperInvariant()) {
        'WINNT' { return 1 }
        'LANMANNT' { return 2 }
        'SERVERNT' { return 3 }
        default {
            throw "Unsupported Windows registry product type '$ProductType'."
        }
    }
}

function Get-LemonWindowsPlatform {
    [CmdletBinding()]
    param(
        [scriptblock] $CurrentVersionProbe = {
            Get-ItemProperty `
                -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
                -Name CurrentBuildNumber, InstallationType `
                -ErrorAction Stop
        },
        [scriptblock] $ProductOptionsProbe = {
            Get-ItemProperty `
                -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\ProductOptions' `
                -Name ProductType `
                -ErrorAction Stop
        },
        [scriptblock] $Is64BitProbe = {
            [Environment]::Is64BitOperatingSystem
        }
    )

    try {
        $currentVersion = & $CurrentVersionProbe
        $productOptions = & $ProductOptionsProbe
        $is64Bit = [bool](& $Is64BitProbe)
        $buildNumber = 0
        if (-not [int]::TryParse(
                [string]$currentVersion.CurrentBuildNumber,
                [ref]$buildNumber)) {
            throw 'The Windows build number is missing or invalid.'
        }
        $productType = ConvertFrom-LemonRegistryProductType `
            -ProductType ([string]$productOptions.ProductType)

        return Resolve-LemonWindowsPlatform `
            -ProductType $productType `
            -BuildNumber $buildNumber `
            -InstallationType ([string]$currentVersion.InstallationType) `
            -Is64BitOperatingSystem $is64Bit
    }
    catch {
        return New-LemonUnsupportedPlatformResult `
            -ReasonCode 'PlatformProbeFailed'
    }
}

Export-ModuleMember -Function @(
    'Resolve-LemonWindowsPlatform',
    'Get-LemonInstallLayout',
    'Get-LemonProductDisplayName',
    'Get-LemonStartMenuShortcutPlan',
    'Test-LemonStartMenuShortcutOwnership',
    'New-LemonStartMenuShortcut',
    'Remove-LemonStartMenuShortcut',
    'ConvertFrom-LemonRegistryProductType',
    'Get-LemonWindowsPlatform'
)
