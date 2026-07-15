[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $InstallId,
    [Parameter(Mandatory)][string] $ResultPath,
    [switch] $Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CommMonitor.InstallHelpers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lemon.Platform.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lemon.SetupTransactions.psm1') -Force

$filterName = 'CommMonitorFilter'
$kernelServiceName = 'CommMonitorFilter'
$userServiceName = 'CommMonitorService'
$portsClassPath =
    'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E978-E325-11CE-BFC1-08002BE10318}'
$InstallerRoot = Join-Path $env:ProgramData 'LemonSerialMonitor\Installer'
$statePath = Join-Path $InstallerRoot 'state\install-state.v1.json'
$workPath = Join-Path $InstallerRoot 'state\uninstall-work.v1.json'
$normalizedInstallId = $null
$AppRoot = $null
$CoreRoot = Join-Path $env:ProgramFiles 'CommMonitor'
$DataRoot = Join-Path $env:ProgramData 'CommMonitor'
$AiStateRoot = $null

function Write-LemonUninstallResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Completed', 'PendingReboot', 'Failed')]
        [string] $Status,
        [Parameter(Mandatory)][string] $Message,
        [AllowEmptyCollection()][string[]] $ResidualObjectIds = @(),
        [AllowNull()][string] $FailureType
    )

    $result = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Operation = 'Uninstall'
        InstallId = $normalizedInstallId
        Status = $Status
        RebootRequired = $Status -eq 'PendingReboot'
        AppRoot = $AppRoot
        CoreRoot = $CoreRoot
        DataRoot = $DataRoot
        InstallerRoot = $InstallerRoot
        AiStateRoot = $AiStateRoot
        ResidualObjectIds = [string[]]$ResidualObjectIds
        Message = $Message
        FailureType = $FailureType
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $fullResultPath = [IO.Path]::GetFullPath($ResultPath)
    $temporaryResultPath = $fullResultPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryResultPath,
            ($result | ConvertTo-Json -Depth 8),
            [Text.UTF8Encoding]::new($false))
        Move-Item `
            -LiteralPath $temporaryResultPath `
            -Destination $fullResultPath `
            -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryResultPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryResultPath -Force
        }
    }
}

function ConvertTo-LemonCanonicalLocalPath {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Role
    )

    if (-not [regex]::IsMatch(
            $Path,
            '^[A-Za-z]:\\',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
        $Path.StartsWith('\\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith('\\.\', [StringComparison]::OrdinalIgnoreCase) -or
        $Path.Substring(2).Contains(':')) {
        throw "$Role is not an ordinary local path."
    }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Set-LemonProtectedStateAcl {
    param([Parameter(Mandatory)][string] $Path)

    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $acl = [Security.AccessControl.DirectorySecurity]::new()
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        $inheritance = [Security.AccessControl.InheritanceFlags]::None
        $acl = [Security.AccessControl.FileSecurity]::new()
    }
    else {
        throw "Protected state path does not exist: $Path"
    }
    $acl.SetOwner($administrators)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($system, $administrators)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $identity,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-LemonUpperFiltersSnapshot {
    $key = Get-Item -LiteralPath $portsClassPath
    $present = @($key.GetValueNames()) -contains 'UpperFilters'
    return [pscustomobject][ordered]@{
        Present = $present
        Values = if ($present) {
            [string[]]@($key.GetValue(
                    'UpperFilters',
                    $null,
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
        }
        else {
            [string[]]@()
        }
    }
}

function Set-LemonUpperFilters {
    param([AllowEmptyCollection()][string[]] $Values)

    $key = Get-Item -LiteralPath $portsClassPath
    $present = @($key.GetValueNames()) -contains 'UpperFilters'
    if (@($Values).Count -eq 0) {
        if ($present) {
            Remove-ItemProperty -LiteralPath $portsClassPath -Name UpperFilters
        }
        return
    }
    if ($present) {
        Set-ItemProperty -LiteralPath $portsClassPath -Name UpperFilters -Value $Values
    }
    else {
        New-ItemProperty `
            -LiteralPath $portsClassPath `
            -Name UpperFilters `
            -PropertyType MultiString `
            -Value $Values | Out-Null
    }
}

function Stop-LemonOwnedProcesses {
    param([AllowEmptyCollection()][string[]] $ExpectedImagePaths)

    $canonical = @($ExpectedImagePaths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [IO.Path]::GetFullPath($_) })
    if ($canonical.Count -eq 0) { return }
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        $image = [string]$process.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($image)) { continue }
        foreach ($expected in $canonical) {
            if ([string]::Equals(
                    [IO.Path]::GetFullPath($image),
                    $expected,
                    [StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
                break
            }
        }
    }
}

function Remove-LemonOwnedCertificate {
    param(
        [Parameter(Mandatory)][string] $StorePath,
        [Parameter(Mandatory)][string] $Thumbprint,
        [Parameter(Mandatory)][bool] $Added
    )

    if (-not $Added) { return }
    Get-ChildItem -LiteralPath $StorePath -ErrorAction SilentlyContinue |
        Where-Object Thumbprint -EQ $Thumbprint |
        Remove-Item -Force -ErrorAction Stop
}

function Remove-LemonProtectedTree {
    param([AllowNull()][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path)) {
        return $true
    }
    [void](Assert-CommMonitorNoReparsePoint -Path $Path)
    Assert-CommMonitorTrustedDirectory -Path $Path
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return -not (Test-Path -LiteralPath $Path)
    }
    catch [IO.IOException] {
        return $false
    }
    catch [UnauthorizedAccessException] {
        return $false
    }
}

function ConvertTo-LemonPathBase64 {
    param([AllowNull()][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '-' }
    return [Convert]::ToBase64String(
        [Text.UTF8Encoding]::new($false, $true).GetBytes($Path))
}

function Write-LemonProtectedWorkManifest {
    param(
        [Parameter(Mandatory)][string] $HelperPath,
        [Parameter(Mandatory)][string] $OwnershipSha256,
        [AllowNull()][string] $OwnedAppRoot,
        [AllowNull()][string] $OwnedAiRoot
    )

    $output = @(& $HelperPath `
            'prepare-work' `
            '--install-id' $normalizedInstallId `
            '--ownership-sha256' $OwnershipSha256 `
            '--app-root-base64' (ConvertTo-LemonPathBase64 $OwnedAppRoot) `
            '--ai-root-base64' (ConvertTo-LemonPathBase64 $OwnedAiRoot))
    $exitCode = [int]$LASTEXITCODE
    if ($exitCode -ne 0 -or $output.Count -ne 1 -or
        $output[0] -isnot [string]) {
        throw "Native uninstall work preparation failed with exit code $exitCode."
    }
    try {
        $bytes = [Convert]::FromBase64String([string]$output[0])
    }
    catch [FormatException] {
        throw 'Native uninstall work preparation returned malformed base64.'
    }
    if ($bytes.Length -lt 3 -or $bytes[$bytes.Length - 1] -ne 10) {
        throw 'Native uninstall work preparation returned invalid framing.'
    }
    [IO.File]::WriteAllBytes($workPath, $bytes)
    Set-LemonProtectedStateAcl -Path $workPath
}

function Get-LemonDriverPackageRecord {
    param([AllowNull()][string] $PublishedName)

    if ([string]::IsNullOrWhiteSpace($PublishedName)) { return $null }
    return Get-WindowsDriver -Online -All -ErrorAction Stop |
            Where-Object {
                [string]::Equals(
                    [string]$_.Driver,
                    $PublishedName,
                    [StringComparison]::OrdinalIgnoreCase)
            } |
            Select-Object -First 1
}

function Get-LemonDriverPackagePresent {
    param([AllowNull()][string] $PublishedName)

    return $null -ne (Get-LemonDriverPackageRecord `
            -PublishedName $PublishedName)
}

function Get-LemonResidualObservation {
    param([Parameter(Mandatory)][object] $State)

    $filters = (Get-LemonUpperFiltersSnapshot).Values
    $thumbprint = [string]$State.Certificate.Thumbprint
    $rootCertificatePresent = [bool]$State.Certificate.RootAdded -and
        $null -ne (Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
            Where-Object Thumbprint -EQ $thumbprint |
            Select-Object -First 1)
    $publisherCertificatePresent = [bool]$State.Certificate.PublisherAdded -and
        $null -ne (Get-ChildItem Cert:\LocalMachine\TrustedPublisher -ErrorAction SilentlyContinue |
            Where-Object Thumbprint -EQ $thumbprint |
            Select-Object -First 1)
    $userServicePresent = $null -ne (
        Get-Service -Name $userServiceName -ErrorAction SilentlyContinue)
    $kernelServicePresent = $null -ne (
        Get-Service -Name $kernelServiceName -ErrorAction SilentlyContinue)
    $shortcutPresent = $false
    if ($null -ne $State.Shortcut -and
        $null -ne $State.Shortcut.PSObject.Properties['ShortcutPath']) {
        $shortcutPresent = Test-Path -LiteralPath ([string]$State.Shortcut.ShortcutPath)
    }
    return [pscustomobject][ordered]@{
        UserServicePresent = $userServicePresent
        KernelServicePresent = $kernelServicePresent
        DriverPackagePresent = Get-LemonDriverPackagePresent `
            -PublishedName ([string]$State.Driver.PublishedName)
        OwnedRootCertificatePresent = $rootCertificatePresent
        OwnedPublisherCertificatePresent = $publisherCertificatePresent
        OwnedEventSourcePresent = $false
        AppRootPresent = -not [string]::IsNullOrWhiteSpace($AppRoot) -and
            (Test-Path -LiteralPath $AppRoot)
        CoreRootPresent = Test-Path -LiteralPath $CoreRoot
        DataRootPresent = Test-Path -LiteralPath $DataRoot
        InstallerNonAuthorityPresent =
            (Test-Path -LiteralPath (Join-Path $InstallerRoot `
                    'state\migration-backup')) -or
            (Test-Path -LiteralPath (Join-Path $InstallerRoot `
                    'state\migration-attempt.v1.json'))
        AiRootPresent = -not [string]::IsNullOrWhiteSpace($AiStateRoot) -and
            (Test-Path -LiteralPath $AiStateRoot)
        StartMenuShortcutPresent = $shortcutPresent
        DesktopShortcutPresent = $false
        UninstallEntryPresent = $false
        ContinuationTaskPresent = $false
        RunEntryPresent = $false
        PendingRenamePresent = $false
        ControlPipePresent = $userServicePresent
        AiPipePresent = $userServicePresent
        LegacyPipePresent = $false
        UpperFilterValues = [string[]]@($filters)
        CoexistenceBaselineUnchanged = $true
    }
}

try {
    if (-not (Test-CommMonitorAdministrator)) {
        throw 'Uninstall requires an elevated administrator token.'
    }
    $parsedInstallId = [Guid]::Empty
    if (-not [Guid]::TryParseExact($InstallId, 'D', [ref]$parsedInstallId) -or
        -not [string]::Equals(
            $InstallId,
            $parsedInstallId.ToString('D').ToLowerInvariant(),
            [StringComparison]::Ordinal)) {
        throw 'InstallId must be a canonical lowercase GUID.'
    }
    $normalizedInstallId = $parsedInstallId.ToString('D').ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'The protected installation state is missing.'
    }
    [void](Assert-CommMonitorNoReparsePoint -Path $InstallerRoot)
    Assert-CommMonitorTrustedDirectory -Path $InstallerRoot
    Set-LemonProtectedStateAcl -Path $InstallerRoot
    Set-LemonProtectedStateAcl -Path (Join-Path $InstallerRoot 'state')
    $state = Get-Content -Raw -LiteralPath $statePath -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if ($state.SchemaVersion -ne 1 -or
        -not [string]::Equals(
            [string]$state.ProductId,
            'LemonSerialMonitor',
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$state.InstallId,
            $normalizedInstallId,
            [StringComparison]::Ordinal)) {
        throw 'The protected installation state identity is invalid.'
    }

    $AppRoot = ConvertTo-LemonCanonicalLocalPath `
        -Path ([string]$state.Roots.AppRoot) `
        -Role AppRoot
    $CoreRoot = ConvertTo-LemonCanonicalLocalPath `
        -Path ([string]$state.Roots.CoreRoot) `
        -Role CoreRoot
    $DataRoot = ConvertTo-LemonCanonicalLocalPath `
        -Path ([string]$state.Roots.DataRoot) `
        -Role DataRoot
    $stateInstallerRoot = ConvertTo-LemonCanonicalLocalPath `
        -Path ([string]$state.Roots.InstallerRoot) `
        -Role InstallerRoot
    $AiStateRoot = ConvertTo-LemonCanonicalLocalPath `
        -Path ([string]$state.Roots.AiStateRoot) `
        -Role AiStateRoot
    foreach ($pair in @(
            @($CoreRoot, (Join-Path $env:ProgramFiles 'CommMonitor')),
            @($DataRoot, (Join-Path $env:ProgramData 'CommMonitor')),
            @($stateInstallerRoot, $InstallerRoot))) {
        if (-not [string]::Equals(
                [IO.Path]::GetFullPath([string]$pair[0]).TrimEnd('\'),
                [IO.Path]::GetFullPath([string]$pair[1]).TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A protected fixed root no longer matches its system location.'
        }
    }

    $expectedAiClientImagePath = if (
        [string]::Equals(
            [string]$state.PlatformKind,
            'ServerCore',
            [StringComparison]::Ordinal)) {
        Join-Path $CoreRoot 'ai\Lemon.SerialMonitor.AI.exe'
    }
    else {
        Join-Path $AppRoot 'ai\Lemon.SerialMonitor.AI.exe'
    }
    $authorizedClientImagePath = $expectedAiClientImagePath
    if ($null -ne $state.UserService -and
        $null -ne $state.UserService.PSObject.Properties[
            'AuthorizedClientImagePath']) {
        $authorizedClientImagePath = ConvertTo-LemonCanonicalLocalPath `
            -Path ([string]$state.UserService.AuthorizedClientImagePath) `
            -Role AuthorizedClientImagePath
    }
    if (-not [string]::Equals(
            $authorizedClientImagePath,
            $expectedAiClientImagePath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The authorized AI client path does not match the protected platform layout.'
    }

    $expectedServiceExecutable = Join-Path $CoreRoot `
        'service\CommMonitor.Service.exe'
    if ($null -eq $state.UserService -or
        -not [string]::Equals(
            [string]$state.UserService.Name,
            $userServiceName,
            [StringComparison]::Ordinal) -or
        -not (Test-CommMonitorServiceImagePath `
            -ImagePath ([string]$state.UserService.ImagePath) `
            -ExpectedExecutable $expectedServiceExecutable)) {
        throw 'The protected user-service ownership record is invalid.'
    }
    $installedUserService = Get-CimInstance `
        -ClassName Win32_Service `
        -Filter "Name='$userServiceName'" `
        -ErrorAction SilentlyContinue
    if ($null -ne $installedUserService -and
        -not (Test-CommMonitorServiceImagePath `
            -ImagePath ([string]$installedUserService.PathName) `
            -ExpectedExecutable $expectedServiceExecutable)) {
        throw 'The installed user service no longer belongs to this installation.'
    }
    $installedKernelService = Get-CimInstance `
        -ClassName Win32_SystemDriver `
        -Filter "Name='$kernelServiceName'" `
        -ErrorAction SilentlyContinue
    $expectedKernelImage = [string]$state.KernelService.ImagePath
    if ($null -ne $installedKernelService -and
        -not (Test-CommMonitorServiceImagePath `
            -ImagePath ([string]$installedKernelService.PathName) `
            -ExpectedExecutable $expectedKernelImage)) {
        throw 'The installed kernel service no longer belongs to this installation.'
    }

    $driverPackage = Get-LemonDriverPackageRecord `
        -PublishedName ([string]$state.Driver.PublishedName)
    if ([bool]$state.Driver.Added -and $null -ne $driverPackage) {
        $currentInfPath = [string]$driverPackage.OriginalFileName
        $currentInfSha256 = if (Test-Path `
                -LiteralPath $currentInfPath `
                -PathType Leaf) {
            (Get-FileHash `
                    -LiteralPath $currentInfPath `
                    -Algorithm SHA256).Hash
        }
        else { $null }
        if (-not (Test-CommMonitorDriverPackageRecord `
                -PublishedName ([string]$driverPackage.Driver) `
                -OriginalFileName $currentInfPath `
                -InfSha256 $currentInfSha256 `
                -ExpectedPublishedName ([string]$state.Driver.PublishedName) `
                -ExpectedOriginalFileName ([string]$state.Driver.OriginalFileName) `
                -ExpectedInfSha256 ([string]$state.Driver.InfSha256))) {
            throw 'The installed Driver Store package no longer matches protected ownership state.'
        }
    }

    $stateHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $helperPath = Join-Path $InstallerRoot 'bin\Lemon.UninstallHelper.exe'
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw 'The protected native uninstall helper is missing.'
    }
    $pendingReboot = $false

    if (-not $Resume) {
        Stop-LemonOwnedProcesses -ExpectedImagePaths @(
            (Join-Path $AppRoot 'app\Lemon.SerialMonitor.exe'),
            $authorizedClientImagePath)

        $service = Get-Service -Name $userServiceName -ErrorAction SilentlyContinue
        if ($null -ne $service -and $service.Status -ne 'Stopped') {
            Stop-Service -Name $userServiceName -Force -ErrorAction Stop
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }

        $filtersBefore = (Get-LemonUpperFiltersSnapshot).Values
        $filtersAfter = [string[]](Get-LemonUpperFiltersAfterUninstall `
                -Values $filtersBefore `
                -Entry $filterName)
        Set-LemonUpperFilters -Values $filtersAfter
        if (-not (Test-LemonUpperFiltersRemoval `
                -Before $filtersBefore `
                -After (Get-LemonUpperFiltersSnapshot).Values `
                -Entry $filterName)) {
            throw 'UpperFilters verification failed after exact filter removal.'
        }

        if ($null -ne (Get-Service -Name $userServiceName -ErrorAction SilentlyContinue)) {
            Invoke-LemonCheckedNativeCommand `
                -FilePath (Join-Path $env:SystemRoot 'System32\sc.exe') `
                -ArgumentList @('delete', $userServiceName) `
                -SuccessExitCodes @(0, 1060, 1072) | Out-Null
        }
        if ([bool]$state.Driver.Added -and $null -ne $driverPackage) {
            $driverResult = Invoke-LemonCheckedNativeCommand `
                -FilePath (Join-Path $env:SystemRoot 'System32\pnputil.exe') `
                -ArgumentList @(
                    '/delete-driver',
                    [string]$state.Driver.PublishedName,
                    '/uninstall',
                    '/force') `
                -SuccessExitCodes @(0, 3010) `
                -RebootExitCodes @(3010)
            $pendingReboot = $pendingReboot -or
                $driverResult.Status -eq 'PendingReboot'
        }
        if ($null -ne (Get-Service -Name $kernelServiceName -ErrorAction SilentlyContinue)) {
            Invoke-LemonCheckedNativeCommand `
                -FilePath (Join-Path $env:SystemRoot 'System32\sc.exe') `
                -ArgumentList @('delete', $kernelServiceName) `
                -SuccessExitCodes @(0, 1060, 1072) | Out-Null
        }

        Remove-LemonOwnedCertificate `
            -StorePath Cert:\LocalMachine\Root `
            -Thumbprint ([string]$state.Certificate.Thumbprint) `
            -Added ([bool]$state.Certificate.RootAdded)
        Remove-LemonOwnedCertificate `
            -StorePath Cert:\LocalMachine\TrustedPublisher `
            -Thumbprint ([string]$state.Certificate.Thumbprint) `
            -Added ([bool]$state.Certificate.PublisherAdded)

        if ($null -ne $state.PSObject.Properties[
                'TestSigningChangedByInstaller'] -and
            [bool]$state.TestSigningChangedByInstaller) {
            Invoke-LemonCheckedNativeCommand `
                -FilePath (Join-Path $env:SystemRoot 'System32\bcdedit.exe') `
                -ArgumentList @('/set', 'testsigning', 'off') `
                -SuccessExitCodes @(0) | Out-Null
            $pendingReboot = $true
        }

        if ($null -ne $state.Shortcut) {
            $shortcutPlan = Get-LemonStartMenuShortcutPlan -InstallRoot $AppRoot
            if (Test-LemonStartMenuShortcutOwnership `
                    -Record $state.Shortcut `
                    -Plan $shortcutPlan) {
                Remove-LemonStartMenuShortcut `
                    -Record $state.Shortcut `
                    -Plan $shortcutPlan | Out-Null
            }
        }

        $ownedApp = if (Test-Path -LiteralPath $AppRoot -PathType Container) {
            $AppRoot
        }
        else { $null }
        $ownedAi = if (Test-Path -LiteralPath $AiStateRoot -PathType Container) {
            $AiStateRoot
        }
        else { $null }
        if ($null -ne $ownedApp -or $null -ne $ownedAi) {
            Write-LemonProtectedWorkManifest `
                -HelperPath $helperPath `
                -OwnershipSha256 $stateHash `
                -OwnedAppRoot $ownedApp `
                -OwnedAiRoot $ownedAi
        }
    }

    if (Test-Path -LiteralPath $workPath -PathType Leaf) {
        $resultDirectory = Join-Path $InstallerRoot 'state\results'
        if (-not (Test-Path -LiteralPath $resultDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
        }
        Set-LemonProtectedStateAcl -Path $resultDirectory
        $helperResultPath = Join-Path $resultDirectory (
            $normalizedInstallId + '.completion.v1.json')
        $helperResult = Invoke-LemonCheckedNativeCommand `
            -FilePath $helperPath `
            -ArgumentList @(
                'verify-delete',
                '--manifest', $workPath,
                '--install-id', $normalizedInstallId,
                '--result', $helperResultPath) `
            -SuccessExitCodes @(0, 3010) `
            -RebootExitCodes @(3010)
        $pendingReboot = $pendingReboot -or
            $helperResult.Status -eq 'PendingReboot'
    }

    if (-not (Remove-LemonProtectedTree -Path $CoreRoot)) {
        $pendingReboot = $true
    }
    if (-not (Remove-LemonProtectedTree -Path $DataRoot)) {
        $pendingReboot = $true
    }
    if (-not (Remove-LemonProtectedTree -Path (Join-Path $InstallerRoot `
                'state\migration-backup'))) {
        $pendingReboot = $true
    }
    $migrationAttemptPath = Join-Path $InstallerRoot `
        'state\migration-attempt.v1.json'
    if (Test-Path -LiteralPath $migrationAttemptPath -PathType Leaf) {
        Remove-Item -LiteralPath $migrationAttemptPath -Force -ErrorAction Stop
    }

    $observation = Get-LemonResidualObservation -State $state
    $firstAssessment = Get-LemonResidualAssessment `
        -Observation $observation `
        -AllowedPendingObjectIds @()
    $assessment = $firstAssessment
    if (@($firstAssessment.ResidualObjectIds).Count -gt 0 -and
        ($pendingReboot -or
            $observation.UserServicePresent -or
            $observation.KernelServicePresent)) {
        $unsafeResiduals = @($firstAssessment.ResidualObjectIds | Where-Object {
                $_ -in @(
                    'root-certificate',
                    'publisher-certificate',
                    'start-menu-shortcut',
                    'desktop-shortcut',
                    'coexistence-baseline')
            })
        if ($unsafeResiduals.Count -eq 0) {
            $assessment = Get-LemonResidualAssessment `
                -Observation $observation `
                -AllowedPendingObjectIds ([string[]]$firstAssessment.ResidualObjectIds)
        }
    }

    switch ([string]$assessment.Status) {
        'Completed' {
            Write-LemonUninstallResult `
                -Status Completed `
                -Message 'Product components and data were removed; setup will remove its final authority files.' `
                -ResidualObjectIds @() `
                -FailureType $null
            exit 0
        }
        'PendingReboot' {
            Write-LemonUninstallResult `
                -Status PendingReboot `
                -Message 'Verified components remain locked; cleanup will resume after restart.' `
                -ResidualObjectIds ([string[]]$assessment.ResidualObjectIds) `
                -FailureType $null
            exit 3010
        }
        default {
            throw ('Uninstall residual verification failed: ' +
                ([string[]]$assessment.ResidualObjectIds -join ', '))
        }
    }
}
catch {
    $failure = $_
    try {
        Write-LemonUninstallResult `
            -Status Failed `
            -Message $failure.Exception.Message `
            -ResidualObjectIds @() `
            -FailureType $failure.Exception.GetType().FullName
    }
    catch {
        Write-Error "Uninstall failed and its result file could not be written: $($_.Exception.Message)"
    }
    Write-Error $failure
    exit 1
}
