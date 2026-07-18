[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PackageRoot,
    [Parameter(Mandatory)][string] $AppRoot,
    [Parameter(Mandatory)][string] $AuthorizedUserSid,
    [Parameter(Mandatory)][string] $ResultPath,
    [ValidateSet('Fresh', 'Migrate')][string] $Mode = 'Fresh',
    [Parameter(Mandatory)][switch] $AcceptTestCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CommMonitor.InstallHelpers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lemon.Platform.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lemon.SetupTransactions.psm1') -Force

$productVersion = '0.1.1'
$filterName = 'CommMonitorFilter'
$kernelServiceName = 'CommMonitorFilter'
$userServiceName = 'CommMonitorService'
$portsClassPath =
    'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E978-E325-11CE-BFC1-08002BE10318}'
$CoreRoot = Join-Path $env:ProgramFiles 'CommMonitor'
$DataRoot = Join-Path $env:ProgramData 'CommMonitor'
$InstallerRoot = Join-Path $env:ProgramData 'LemonSerialMonitor\Installer'
$AiStateRoot = $null
$installId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
$context = [ordered]@{
    RebootRequired = $false
    RootsCreated = @()
    Certificate = $null
    Driver = $null
    UserServiceCreated = $false
    PnpMutationSucceeded = $false
    DriverPackagesBefore = @()
    DriverSourceInfSha256 = $null
    TestSigningChangedByInstaller = $false
    Migration = $null
    MigrationBackupRoot = $null
    AiClient = $null
    ServiceCommandLine = $null
    UpperFiltersBefore = $null
    Shortcut = $null
    StatePath = $null
}

function Write-LemonInstallResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Completed', 'PendingReboot', 'Failed')]
        [string] $Status,
        [Parameter(Mandatory)][string] $Message,
        [AllowNull()][string] $FailureType
    )

    $result = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Operation = 'Install'
        InstallId = $installId
        Status = $Status
        RebootRequired = $Status -eq 'PendingReboot'
        ProductVersion = $productVersion
        AppRoot = [IO.Path]::GetFullPath($AppRoot).TrimEnd('\', '/')
        CoreRoot = $CoreRoot
        DataRoot = $DataRoot
        InstallerRoot = $InstallerRoot
        AiStateRoot = $AiStateRoot
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

function Set-LemonAuthorizedUserAcl {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Sid
    )

    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $user = [Security.Principal.SecurityIdentifier]::new($Sid)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($user)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($system, $administrators, $user)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $identity,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Remove-LemonCreatedTree {
    param([AllowNull()][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path)) {
        return
    }
    [void](Assert-CommMonitorNoReparsePoint -Path $Path)
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

function Copy-LemonPayloadDirectory {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Required payload directory is missing: $Source"
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item `
            -LiteralPath $item.FullName `
            -Destination $Destination `
            -Recurse `
            -Force
    }
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

function Set-LemonUpperFiltersSnapshot {
    param(
        [Parameter(Mandatory)][bool] $Present,
        [AllowEmptyCollection()][string[]] $Values
    )

    $key = Get-Item -LiteralPath $portsClassPath
    $currentlyPresent = @($key.GetValueNames()) -contains 'UpperFilters'
    if (-not $Present) {
        if ($currentlyPresent) {
            Remove-ItemProperty -LiteralPath $portsClassPath -Name UpperFilters
        }
        return
    }
    if ($currentlyPresent) {
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

function Get-LemonDriverPackagesByInfHash {
    param([Parameter(Mandatory)][string] $InfSha256)

    return @(
        Get-WindowsDriver -Online -All -ErrorAction Stop |
            Where-Object {
                $path = [string]$_.OriginalFileName
                -not [string]::IsNullOrWhiteSpace($path) -and
                (Test-Path -LiteralPath $path -PathType Leaf) -and
                [string]::Equals(
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash,
                    $InfSha256,
                    [StringComparison]::OrdinalIgnoreCase)
            })
}

function Get-LemonDriverPackageByPublishedName {
    param([Parameter(Mandatory)][string] $PublishedName)

    return Get-WindowsDriver -Online -All -ErrorAction Stop |
        Where-Object {
            [string]::Equals(
                [string]$_.Driver,
                $PublishedName,
                [StringComparison]::OrdinalIgnoreCase)
        } |
        Select-Object -First 1
}

function Stop-LemonOwnedProcessByImagePath {
    param([Parameter(Mandatory)][string] $ExpectedImagePath)

    $expected = [IO.Path]::GetFullPath($ExpectedImagePath)
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        $imagePath = [string]$process.ExecutablePath
        if (-not [string]::IsNullOrWhiteSpace($imagePath) -and
            [string]::Equals(
                [IO.Path]::GetFullPath($imagePath),
                $expected,
                [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process `
                -Id ([int]$process.ProcessId) `
                -Force `
                -ErrorAction Stop
        }
    }
}

function Get-LemonAuthenticatedMigrationState {
    param([Parameter(Mandatory)][string] $ExpectedCertificateThumbprint)

    $legacyMarkerPath = Join-Path $CoreRoot '.commmonitor-install.json'
    $legacyBackupPath = Join-Path $DataRoot 'install-backup.latest.json'
    if (-not (Test-Path -LiteralPath $legacyMarkerPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $legacyBackupPath -PathType Leaf)) {
        throw 'Authenticated migration requires the protected manual marker and backup.'
    }
    [void](Assert-CommMonitorNoReparsePoint -Path $CoreRoot)
    [void](Assert-CommMonitorNoReparsePoint -Path $DataRoot)
    Assert-CommMonitorTrustedDirectory -Path $CoreRoot
    Assert-CommMonitorTrustedDirectory -Path $DataRoot

    $marker = Get-Content `
        -Raw `
        -LiteralPath $legacyMarkerPath `
        -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    $backupHash = (Get-FileHash `
            -LiteralPath $legacyBackupPath `
            -Algorithm SHA256).Hash
    if (-not (Test-CommMonitorInstallMarker `
            -Marker $marker `
            -ExpectedInstallPath $CoreRoot `
            -ExpectedBackupPath $legacyBackupPath `
            -ExpectedBackupSha256 $backupHash)) {
        throw 'The protected manual installation marker failed authentication.'
    }
    $backup = ConvertFrom-CommMonitorInstallBackupJson `
        -Json (Get-Content `
            -Raw `
            -LiteralPath $legacyBackupPath `
            -Encoding UTF8)
    if ($backup.SchemaVersion -ne 2 -or
        -not [string]::Equals(
            [string]$backup.InstallId,
            [string]$marker.InstallId,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$backup.InstallPath).TrimEnd('\'),
            [IO.Path]::GetFullPath($CoreRoot).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase) -or
        $backup.DriverPackageAdded -isnot [bool] -or
        -not [bool]$backup.DriverPackageAdded -or
        $backup.UserServiceCreated -isnot [bool] -or
        -not [bool]$backup.UserServiceCreated -or
        $backup.RootCertificateAdded -isnot [bool] -or
        $backup.PublisherCertificateAdded -isnot [bool]) {
        throw 'The protected manual installation backup is incomplete.'
    }
    if (-not [string]::Equals(
            [string]$backup.CertificateThumbprint,
            $ExpectedCertificateThumbprint,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Migration requires the same local signing certificate as the installed driver.'
    }

    $userService = Get-CimInstance `
        -ClassName Win32_Service `
        -Filter "Name='$userServiceName'" `
        -ErrorAction Stop
    $expectedLegacyService = Join-Path $CoreRoot `
        'service\CommMonitor.Service.exe'
    if ($null -eq $userService -or
        -not (Test-CommMonitorServiceImagePath `
            -ImagePath ([string]$userService.PathName) `
            -ExpectedExecutable $expectedLegacyService) -or
        -not (Test-CommMonitorServiceImagePath `
            -ImagePath ([string]$backup.UserServiceImagePath) `
            -ExpectedExecutable $expectedLegacyService)) {
        throw 'The manual user service no longer matches its protected ownership record.'
    }
    $kernelService = Get-CimInstance `
        -ClassName Win32_SystemDriver `
        -Filter "Name='$kernelServiceName'" `
        -ErrorAction Stop
    if ($null -eq $kernelService -or
        -not (Test-CommMonitorServiceImagePath `
            -ImagePath ([string]$kernelService.PathName) `
            -ExpectedExecutable ([string]$backup.KernelServiceImagePath))) {
        throw 'The manual kernel service no longer matches its protected ownership record.'
    }

    $driverPackage = Get-LemonDriverPackageByPublishedName `
        -PublishedName ([string]$backup.DriverPackagePublishedName)
    if ($null -eq $driverPackage) {
        throw 'The protected manual Driver Store package is missing.'
    }
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
            -ExpectedPublishedName ([string]$backup.DriverPackagePublishedName) `
            -ExpectedOriginalFileName ([string]$backup.DriverPackageOriginalFileName) `
            -ExpectedInfSha256 ([string]$backup.DriverPackageInfSha256))) {
        throw 'The manual Driver Store package no longer matches its protected identity.'
    }

    $matchingFilters = @((Get-LemonUpperFiltersSnapshot).Values |
            Where-Object {
                [string]::Equals(
                    $_,
                    $filterName,
                    [StringComparison]::OrdinalIgnoreCase)
            })
    if ($matchingFilters.Count -ne 1) {
        throw 'The manual serial filter registration is missing or ambiguous.'
    }
    foreach ($storePath in @(
            'Cert:\LocalMachine\Root',
            'Cert:\LocalMachine\TrustedPublisher')) {
        if ($null -eq (Get-ChildItem -LiteralPath $storePath |
                Where-Object Thumbprint -EQ $ExpectedCertificateThumbprint |
                Select-Object -First 1)) {
            throw "The protected manual signing certificate is missing from $storePath."
        }
    }

    return [pscustomobject][ordered]@{
        Marker = $marker
        MarkerPath = $legacyMarkerPath
        Backup = $backup
        BackupPath = $legacyBackupPath
        UserService = $userService
        KernelService = $kernelService
        DriverPackage = $driverPackage
    }
}

function Remove-LemonCertificateIfOwned {
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

function Get-LemonTestSigningState {
    $result = Invoke-LemonCheckedNativeCommand `
        -FilePath (Join-Path $env:SystemRoot 'System32\bcdedit.exe') `
        -ArgumentList @('/enum', '{current}') `
        -SuccessExitCodes @(0)
    return Test-CommMonitorTestSigningOutput -Output $result.Output
}

function Get-LemonSecureBootEnabled {
    try {
        return [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
    }
    catch [PlatformNotSupportedException] {
        return $false
    }
}

function Assert-LemonSupportedHost {
    $detectedPlatform = Get-LemonWindowsPlatform
    if (-not [bool]$detectedPlatform.Supported) {
        throw "This Windows build is unsupported ($($detectedPlatform.ReasonCode))."
    }
    return $detectedPlatform
}

try {
    if (-not $AcceptTestCertificate) {
        throw 'Installation agreement acceptance for the local test certificate is required.'
    }
    if (-not (Test-CommMonitorAdministrator)) {
        throw 'Installation requires an elevated administrator token.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw 'Installation requires 64-bit Windows PowerShell.'
    }
    $platform = Assert-LemonSupportedHost
    $installLayout = Get-LemonInstallLayout -Platform $platform
    if (Get-LemonSecureBootEnabled) {
        throw 'Secure Boot is enabled and blocks this local test-signed driver.'
    }

    $resolvedPackageRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\', '/')
    $resolvedAppRoot = [IO.Path]::GetFullPath($AppRoot).TrimEnd('\', '/')
    Assert-CommMonitorTrustedPackageTree -Path $resolvedPackageRoot
    $payloadManifest = Assert-LemonPayloadManifest `
        -PackageRoot $resolvedPackageRoot
    $helperSource = Join-Path $resolvedPackageRoot 'helper\Lemon.UninstallHelper.exe'
    if (-not (Test-Path -LiteralPath $helperSource -PathType Leaf)) {
        throw "Required native helper is missing: $helperSource"
    }
    $helperSha256 = (Get-FileHash -LiteralPath $helperSource -Algorithm SHA256).Hash.ToLowerInvariant()
    Initialize-CommMonitorWindowsOwnershipProvider `
        -NativeHelperPath $helperSource `
        -ExpectedSha256 $helperSha256 `
        -AuthorizedUserSid $AuthorizedUserSid | Out-Null
    $probeCapability = New-CommMonitorWindowsOwnershipProbeCapability
    $authorizedUser = Resolve-CommMonitorAuthorizedUser `
        -AuthorizedUserSid $AuthorizedUserSid `
        -OwnershipProbeCapability $probeCapability `
        -AiRelativePath 'LemonSerialMonitor\AI'
    $AiStateRoot = [string]$authorizedUser.AiRoot

    $rootPlatformKind = switch ([string]$platform.PlatformKind) {
        'ClientDesktop' { 'Desktop' }
        'ServerDesktop' { 'ServerDesktop' }
        'ServerCore' { 'ServerCore' }
        default { throw "Unsupported platform kind '$($platform.PlatformKind)'." }
    }
    $rootComponents = if ($rootPlatformKind -eq 'ServerCore') {
        @('Service', 'Driver', 'AI', 'Headless')
    }
    else {
        @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
    }

    $requiredFiles = [string[]]$installLayout.RequiredRelativePaths
    foreach ($relativePath in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (
                    Join-Path $resolvedPackageRoot $relativePath) -PathType Leaf)) {
            throw "Required payload file is missing: $relativePath"
        }
    }

    $certificatePath = Join-Path $resolvedPackageRoot 'driver\CommMonitor.LocalTestDriver.cer'
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $certificatePath)
    try { $certificateThumbprint = $certificate.Thumbprint }
    finally { $certificate.Dispose() }
    foreach ($signedFile in @(
            (Join-Path $resolvedPackageRoot 'driver\CommMonitor.Driver.sys'),
            (Join-Path $resolvedPackageRoot 'driver\CommMonitor.Driver.cat'))) {
        $signature = Get-AuthenticodeSignature -LiteralPath $signedFile
        if ($null -eq $signature.SignerCertificate -or
            -not [string]::Equals(
                $signature.SignerCertificate.Thumbprint,
                $certificateThumbprint,
                [StringComparison]::OrdinalIgnoreCase) -or
            $signature.Status -notin @(
                [Management.Automation.SignatureStatus]::Valid,
                [Management.Automation.SignatureStatus]::NotTrusted,
                [Management.Automation.SignatureStatus]::UnknownError)) {
            throw "Driver signature identity is invalid: $signedFile"
        }
    }

    if ($Mode -eq 'Fresh') {
        $roots = Resolve-CommMonitorOwnershipRoots `
            -PlatformKind $rootPlatformKind `
            -PlatformBuild ([int]$platform.BuildNumber) `
            -PlatformComponents $rootComponents `
            -AppRoot $resolvedAppRoot `
            -ProgramFilesPath $env:ProgramFiles `
            -ProgramDataPath $env:ProgramData `
            -AuthorizedUserBinding $authorizedUser `
            -InstallMode $Mode
        $CoreRoot = [string]$roots.CoreRoot.CanonicalPath
        $DataRoot = [string]$roots.DataRoot.CanonicalPath
        $InstallerRoot = [string]$roots.InstallerRoot.CanonicalPath
        foreach ($serviceName in @($userServiceName, $kernelServiceName)) {
            if ($null -ne (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
                throw "An existing internal service '$serviceName' must be removed before a fresh install."
            }
        }
    }
    else {
        if ($rootPlatformKind -eq 'ServerCore') {
            throw 'Protected manual migration is available only on a desktop installation.'
        }
        $context.Migration = Get-LemonAuthenticatedMigrationState `
            -ExpectedCertificateThumbprint $certificateThumbprint
        $migrationProbes = [ordered]@{
            AppRoot = Get-CommMonitorValidatedRootProbe `
                -Path $resolvedAppRoot `
                -Role AppRoot `
                -RequireEmpty $true
            CoreRoot = Get-CommMonitorValidatedRootProbe `
                -Path $CoreRoot `
                -Role CoreRoot `
                -RequireEmpty $false `
                -RequireProtectedAcl $true
            DataRoot = Get-CommMonitorValidatedRootProbe `
                -Path $DataRoot `
                -Role DataRoot `
                -RequireEmpty $false `
                -RequireProtectedAcl $true
            InstallerRoot = Get-CommMonitorValidatedRootProbe `
                -Path $InstallerRoot `
                -Role InstallerRoot `
                -RequireEmpty $true
            AiStateRoot = Get-CommMonitorValidatedRootProbe `
                -Path $AiStateRoot `
                -Role AiStateRoot `
                -RequireEmpty $true
        }
        Assert-CommMonitorDistinctPhysicalRoots `
            -ValidatedRoots $migrationProbes
        if (-not [string]::Equals(
                [string]$migrationProbes.CoreRoot.VolumeSerialNumber,
                [string]$migrationProbes.InstallerRoot.VolumeSerialNumber,
                [StringComparison]::Ordinal)) {
            throw 'Migration requires CoreRoot and InstallerRoot on the same fixed volume.'
        }
        $roots = [pscustomobject][ordered]@{
            AppRoot = [pscustomobject]@{ CanonicalPath = $resolvedAppRoot }
            CoreRoot = [pscustomobject]@{ CanonicalPath = $CoreRoot }
            DataRoot = [pscustomobject]@{ CanonicalPath = $DataRoot }
            InstallerRoot = [pscustomobject]@{ CanonicalPath = $InstallerRoot }
        }
    }

    $aiClientPackagePath = Join-Path $resolvedPackageRoot `
        'ai\Lemon.SerialMonitor.AI.exe'
    $aiClientPackageSha256 = (Get-FileHash `
            -LiteralPath $aiClientPackagePath `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    $aiClientExecutable = if ($rootPlatformKind -eq 'ServerCore') {
        Join-Path $CoreRoot 'ai\Lemon.SerialMonitor.AI.exe'
    }
    else {
        Join-Path $resolvedAppRoot 'ai\Lemon.SerialMonitor.AI.exe'
    }

    $context.UpperFiltersBefore = Get-LemonUpperFiltersSnapshot
    $steps = [Collections.Generic.List[object]]::new()
    if (-not (Get-LemonTestSigningState)) {
        $steps.Add([pscustomobject]@{
                Name = 'EnableTestSigning'
                Apply = {
                    $result = Invoke-LemonCheckedNativeCommand `
                        -FilePath (Join-Path $env:SystemRoot 'System32\bcdedit.exe') `
                        -ArgumentList @('/set', 'testsigning', 'on') `
                        -SuccessExitCodes @(0)
                    $context.RebootRequired = $true
                    $context.TestSigningChangedByInstaller = $true
                    $result
                }
                Rollback = {
                    Invoke-LemonCheckedNativeCommand `
                        -FilePath (Join-Path $env:SystemRoot 'System32\bcdedit.exe') `
                        -ArgumentList @('/set', 'testsigning', 'off') `
                        -SuccessExitCodes @(0) | Out-Null
                }
            })
    }

    if ($Mode -eq 'Migrate') {
        $migrationBackupRoot = Join-Path $InstallerRoot `
            'state\migration-backup'
        $migrationAttemptPath = Join-Path $InstallerRoot `
            'state\migration-attempt.v1.json'
        $context.MigrationBackupRoot = $migrationBackupRoot
        $steps.Add([pscustomobject]@{
                Name = 'PrepareMigration'
                Apply = {
                    New-Item `
                        -ItemType Directory `
                        -Path $migrationBackupRoot `
                        -Force | Out-Null
                    Set-LemonProtectedStateAcl -Path $InstallerRoot
                    Write-CommMonitorAtomicTextFile `
                        -LiteralPath $migrationAttemptPath `
                        -Value ([pscustomobject][ordered]@{
                                SchemaVersion = 1
                                SourceInstallId = [string]$context.Migration.Marker.InstallId
                                NewInstallId = $installId
                                StartedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                            } | ConvertTo-Json -Depth 4)

                    Stop-LemonOwnedProcessByImagePath `
                        -ExpectedImagePath (Join-Path $CoreRoot `
                            'app\CommMonitor.App.exe')
                    $legacyService = Get-Service `
                        -Name $userServiceName `
                        -ErrorAction Stop
                    if ($legacyService.Status -ne 'Stopped') {
                        Stop-Service `
                            -Name $userServiceName `
                            -Force `
                            -ErrorAction Stop
                        $legacyService.WaitForStatus(
                            'Stopped',
                            [TimeSpan]::FromSeconds(30))
                    }

                    foreach ($name in @('app', 'service', 'driver')) {
                        $source = Join-Path $CoreRoot $name
                        if (Test-Path -LiteralPath $source) {
                            Move-Item `
                                -LiteralPath $source `
                                -Destination (Join-Path $migrationBackupRoot $name) `
                                -Force
                        }
                    }
                    Move-Item `
                        -LiteralPath ([string]$context.Migration.MarkerPath) `
                        -Destination (Join-Path $migrationBackupRoot `
                            '.commmonitor-install.json') `
                        -Force
                    [pscustomobject]@{
                        BackupRoot = $migrationBackupRoot
                    }
                }
                Rollback = {
                    foreach ($name in @('app', 'service', 'driver')) {
                        $destination = Join-Path $CoreRoot $name
                        $source = Join-Path $migrationBackupRoot $name
                        if (Test-Path -LiteralPath $destination) {
                            Remove-LemonCreatedTree -Path $destination
                        }
                        if (Test-Path -LiteralPath $source) {
                            Move-Item `
                                -LiteralPath $source `
                                -Destination $destination `
                                -Force
                        }
                    }
                    $markerBackup = Join-Path $migrationBackupRoot `
                        '.commmonitor-install.json'
                    if (Test-Path -LiteralPath $markerBackup -PathType Leaf) {
                        Move-Item `
                            -LiteralPath $markerBackup `
                            -Destination ([string]$context.Migration.MarkerPath) `
                            -Force
                    }
                    if (Test-Path -LiteralPath $migrationAttemptPath -PathType Leaf) {
                        Remove-Item -LiteralPath $migrationAttemptPath -Force
                    }
                    foreach ($directory in @(
                            $migrationBackupRoot,
                            (Join-Path $InstallerRoot 'state\results'),
                            (Join-Path $InstallerRoot 'state'),
                            $InstallerRoot)) {
                        if ((Test-Path -LiteralPath $directory -PathType Container) -and
                            @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
                            Remove-Item -LiteralPath $directory -Force
                        }
                    }
                    Invoke-LemonCheckedNativeCommand `
                        -FilePath (Join-Path $env:SystemRoot 'System32\sc.exe') `
                        -ArgumentList @(
                            'config', $userServiceName,
                            'binPath=', (ConvertTo-LemonScNativeBinaryPathArgument `
                                -Value ([string]$context.Migration.UserService.PathName)),
                            'start=', 'auto') `
                        -SuccessExitCodes @(0) | Out-Null
                    Start-Service -Name $userServiceName -ErrorAction Stop
                }
            })
    }

    $steps.Add([pscustomobject]@{
            Name = 'InstallFiles'
            Apply = {
                $activeRoots = @($CoreRoot, $DataRoot, $InstallerRoot, $AiStateRoot)
                if ($rootPlatformKind -ne 'ServerCore') {
                    $activeRoots += $resolvedAppRoot
                }
                foreach ($root in $activeRoots) {
                    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                        New-Item -ItemType Directory -Path $root -Force | Out-Null
                        $context.RootsCreated += $root
                    }
                }
                if ($rootPlatformKind -ne 'ServerCore') {
                    Copy-LemonPayloadDirectory `
                        -Source (Join-Path $resolvedPackageRoot 'app') `
                        -Destination (Join-Path $resolvedAppRoot 'app')
                    Copy-LemonPayloadDirectory `
                        -Source (Join-Path $resolvedPackageRoot 'docs') `
                        -Destination (Join-Path $resolvedAppRoot 'docs')
                    Copy-LemonPayloadDirectory `
                        -Source (Join-Path $resolvedPackageRoot 'examples') `
                        -Destination (Join-Path $resolvedAppRoot 'examples')
                    Copy-LemonPayloadDirectory `
                        -Source (Join-Path $resolvedPackageRoot 'manual') `
                        -Destination (Join-Path $resolvedAppRoot 'manual')
                    Copy-LemonPayloadDirectory `
                        -Source (Join-Path $resolvedPackageRoot 'ai') `
                        -Destination (Join-Path $resolvedAppRoot 'ai')
                    Set-CommMonitorRestrictedAcl -Path $resolvedAppRoot
                }
                foreach ($directory in @('service', 'driver')) {
                    $source = Join-Path $resolvedPackageRoot $directory
                    if (Test-Path -LiteralPath $source -PathType Container) {
                        Copy-LemonPayloadDirectory `
                            -Source $source `
                            -Destination (Join-Path $CoreRoot $directory)
                    }
                }
                if ($rootPlatformKind -eq 'ServerCore') {
                    Copy-LemonPayloadDirectory `
                        -Source (Join-Path $resolvedPackageRoot 'ai') `
                        -Destination (Join-Path $CoreRoot 'ai')
                    Copy-LemonPayloadDirectory `
                        -Source (Join-Path $resolvedPackageRoot 'docs') `
                        -Destination (Join-Path $CoreRoot 'docs')
                    Copy-LemonPayloadDirectory `
                        -Source (Join-Path $resolvedPackageRoot 'examples') `
                        -Destination (Join-Path $CoreRoot 'examples')
                    Copy-LemonPayloadDirectory `
                        -Source (Join-Path $resolvedPackageRoot 'manual') `
                        -Destination (Join-Path $CoreRoot 'manual')
                }
                New-Item `
                    -ItemType Directory `
                    -Path (Join-Path $CoreRoot 'metadata') `
                    -Force | Out-Null
                Copy-LemonPayloadDirectory `
                    -Source (Join-Path $resolvedPackageRoot 'helper') `
                    -Destination (Join-Path $InstallerRoot 'bin')
                Copy-LemonPayloadDirectory `
                    -Source (Join-Path $resolvedPackageRoot 'scripts') `
                    -Destination (Join-Path $InstallerRoot 'scripts')
                foreach ($directory in @(
                        (Join-Path $InstallerRoot 'state'),
                        (Join-Path $InstallerRoot 'state\results'))) {
                    New-Item -ItemType Directory -Path $directory -Force | Out-Null
                }
                Set-CommMonitorRestrictedAcl -Path $CoreRoot
                Set-CommMonitorRestrictedAcl -Path $DataRoot
                Set-LemonAuthorizedUserAcl -Path $AiStateRoot -Sid $AuthorizedUserSid
                Set-LemonProtectedStateAcl -Path $InstallerRoot
                Set-LemonProtectedStateAcl -Path (Join-Path $InstallerRoot 'state')
                Set-LemonProtectedStateAcl -Path (Join-Path $InstallerRoot 'state\results')
                $deployedAiSha256 = (Get-FileHash `
                        -LiteralPath $aiClientExecutable `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                if (-not [string]::Equals(
                        $deployedAiSha256,
                        $aiClientPackageSha256,
                        [StringComparison]::Ordinal)) {
                    throw 'The installed AI client does not match its packaged SHA-256.'
                }
                $context.AiClient = [pscustomobject][ordered]@{
                    AuthorizedClientImagePath = $aiClientExecutable
                    AuthorizedClientSha256 = $deployedAiSha256
                }
                [pscustomobject]@{ Roots = $activeRoots }
            }
            Rollback = {
                foreach ($target in @(
                        (Join-Path $resolvedAppRoot 'app'),
                        (Join-Path $resolvedAppRoot 'docs'),
                        (Join-Path $resolvedAppRoot 'examples'),
                        (Join-Path $resolvedAppRoot 'manual'),
                        (Join-Path $resolvedAppRoot 'ai'),
                        (Join-Path $CoreRoot 'service'),
                        (Join-Path $CoreRoot 'driver'),
                        (Join-Path $CoreRoot 'ai'),
                        (Join-Path $CoreRoot 'docs'),
                        (Join-Path $CoreRoot 'examples'),
                        (Join-Path $CoreRoot 'manual'),
                        (Join-Path $CoreRoot 'metadata'),
                        (Join-Path $InstallerRoot 'bin'),
                        (Join-Path $InstallerRoot 'scripts'))) {
                    Remove-LemonCreatedTree -Path $target
                }
                foreach ($root in @($context.RootsCreated | Sort-Object Length -Descending)) {
                    Remove-LemonCreatedTree -Path $root
                }
            }
        })

    $steps.Add([pscustomobject]@{
            Name = 'TrustTestCertificate'
            Apply = {
                $rootPresent = $null -ne (Get-ChildItem Cert:\LocalMachine\Root |
                        Where-Object Thumbprint -EQ $certificateThumbprint |
                        Select-Object -First 1)
                $publisherPresent = $null -ne (
                    Get-ChildItem Cert:\LocalMachine\TrustedPublisher |
                        Where-Object Thumbprint -EQ $certificateThumbprint |
                        Select-Object -First 1)
                if (-not $rootPresent) {
                    Import-Certificate `
                        -FilePath $certificatePath `
                        -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
                }
                if (-not $publisherPresent) {
                    Import-Certificate `
                        -FilePath $certificatePath `
                        -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
                }
                $rootAddedThisAttempt = -not $rootPresent
                $publisherAddedThisAttempt = -not $publisherPresent
                $context.Certificate = [pscustomobject][ordered]@{
                    Thumbprint = $certificateThumbprint
                    RootAdded = if ($Mode -eq 'Migrate') {
                        [bool]$context.Migration.Backup.RootCertificateAdded
                    }
                    else { $rootAddedThisAttempt }
                    PublisherAdded = if ($Mode -eq 'Migrate') {
                        [bool]$context.Migration.Backup.PublisherCertificateAdded
                    }
                    else { $publisherAddedThisAttempt }
                    RootAddedThisAttempt = $rootAddedThisAttempt
                    PublisherAddedThisAttempt = $publisherAddedThisAttempt
                }
                $context.Certificate
            }
            Rollback = {
                if ($null -ne $context.Certificate) {
                    Remove-LemonCertificateIfOwned `
                        -StorePath Cert:\LocalMachine\Root `
                        -Thumbprint $certificateThumbprint `
                        -Added ([bool]$context.Certificate.RootAddedThisAttempt)
                    Remove-LemonCertificateIfOwned `
                        -StorePath Cert:\LocalMachine\TrustedPublisher `
                        -Thumbprint $certificateThumbprint `
                        -Added ([bool]$context.Certificate.PublisherAddedThisAttempt)
                }
            }
        })

    if ($Mode -eq 'Migrate') {
        $context.Driver = [pscustomobject][ordered]@{
            PublishedName = [string]$context.Migration.Backup.DriverPackagePublishedName
            OriginalFileName = [string]$context.Migration.Backup.DriverPackageOriginalFileName
            InfSha256 = ([string]$context.Migration.Backup.DriverPackageInfSha256).ToLowerInvariant()
            Added = [bool]$context.Migration.Backup.DriverPackageAdded
        }
    }
    else {
        $sourceInf = Join-Path $CoreRoot 'driver\CommMonitor.Driver.inf'
        $sourceInfSha256 = (Get-FileHash -LiteralPath (
                Join-Path $resolvedPackageRoot 'driver\CommMonitor.Driver.inf') -Algorithm SHA256).Hash
        $beforeDriverNames = @(Get-LemonDriverPackagesByInfHash `
                -InfSha256 $sourceInfSha256 | ForEach-Object { [string]$_.Driver })
        $context.DriverPackagesBefore = [string[]]$beforeDriverNames
        $context.DriverSourceInfSha256 = $sourceInfSha256
        $steps.Add([pscustomobject]@{
            Name = 'InstallDriverPackage'
            Apply = {
                $native = Invoke-LemonCheckedNativeCommand `
                    -FilePath (Join-Path $env:SystemRoot 'System32\pnputil.exe') `
                    -ArgumentList @('/add-driver', $sourceInf, '/install') `
                    -SuccessExitCodes @(0, 3010) `
                    -RebootExitCodes @(3010)
                $context.PnpMutationSucceeded = $true
                if ($native.Status -eq 'PendingReboot') {
                    $context.RebootRequired = $true
                }
                $after = @(Get-LemonDriverPackagesByInfHash -InfSha256 $sourceInfSha256)
                $new = @($after | Where-Object {
                        $beforeDriverNames -notcontains [string]$_.Driver
                    })
                if ($new.Count -gt 1 -or ($new.Count -eq 0 -and $after.Count -ne 1)) {
                    throw 'The exact installed Driver Store package could not be identified.'
                }
                $package = if ($new.Count -eq 1) { $new[0] } else { $after[0] }
                $context.Driver = [pscustomobject][ordered]@{
                    PublishedName = [string]$package.Driver
                    OriginalFileName = [string]$package.OriginalFileName
                    InfSha256 = $sourceInfSha256.ToLowerInvariant()
                    Added = $new.Count -eq 1
                }
                $context.Driver
            }
            Rollback = {
                if ($null -ne $context.Driver -and [bool]$context.Driver.Added) {
                    Invoke-LemonCheckedNativeCommand `
                        -FilePath (Join-Path $env:SystemRoot 'System32\pnputil.exe') `
                        -ArgumentList @(
                            '/delete-driver',
                            [string]$context.Driver.PublishedName,
                            '/uninstall',
                            '/force') `
                        -SuccessExitCodes @(0, 3010) `
                        -RebootExitCodes @(3010) | Out-Null
                }
                elseif ($context.PnpMutationSucceeded) {
                    $rollbackCandidates = @(Get-LemonDriverPackagesByInfHash `
                            -InfSha256 $context.DriverSourceInfSha256 |
                            Where-Object {
                                $context.DriverPackagesBefore -notcontains
                                    [string]$_.Driver
                            })
                    if ($rollbackCandidates.Count -eq 1) {
                        Invoke-LemonCheckedNativeCommand `
                            -FilePath (Join-Path $env:SystemRoot 'System32\pnputil.exe') `
                            -ArgumentList @(
                                '/delete-driver',
                                [string]$rollbackCandidates[0].Driver,
                                '/uninstall',
                                '/force') `
                            -SuccessExitCodes @(0, 3010) `
                            -RebootExitCodes @(3010) | Out-Null
                    }
                    elseif ($rollbackCandidates.Count -gt 1) {
                        throw 'Rollback found multiple new driver packages and refused ambiguous deletion.'
                    }
                }
            }
            })
    }

    $serviceExecutable = Join-Path $CoreRoot 'service\CommMonitor.Service.exe'
    $serviceConfigurationArguments = [string[]]@(
        "--Storage:ManagedRoot=$DataRoot",
        "--Storage:SessionRoot=$(Join-Path $DataRoot 'Sessions')",
        "--Storage:ExportRoot=$(Join-Path $DataRoot 'Exports')",
        "--InstallSecurity:CoreRootMetadataPath=$(Join-Path $CoreRoot 'metadata')",
        "--InstallSecurity:AuthorizedUserSid=$AuthorizedUserSid",
        "--InstallSecurity:AuthorizedClientImagePath=$aiClientExecutable",
        "--InstallSecurity:AuthorizedClientSha256=$aiClientPackageSha256")
    $quotedServiceArguments = $serviceConfigurationArguments |
        ForEach-Object { '"{0}"' -f $_ }
    $serviceCommandLine = ('"{0}" {1}' -f
        $serviceExecutable,
        ($quotedServiceArguments -join ' '))
    $serviceNativeCommandLine = ConvertTo-LemonScNativeBinaryPathArgument `
        -Value $serviceCommandLine
    $serviceDisplayName = (Get-LemonProductDisplayName) +
        [char]0x670d + [char]0x52a1
    $steps.Add([pscustomobject]@{
            Name = 'InstallService'
            Apply = {
                if ($Mode -eq 'Migrate') {
                    Invoke-LemonCheckedNativeCommand `
                        -FilePath (Join-Path $env:SystemRoot 'System32\sc.exe') `
                        -ArgumentList @(
                            'config', $userServiceName,
                            'binPath=', $serviceNativeCommandLine,
                            'start=', 'auto',
                            'obj=', 'LocalSystem',
                            'DisplayName=', $serviceDisplayName) `
                        -SuccessExitCodes @(0) | Out-Null
                }
                else {
                    Invoke-LemonCheckedNativeCommand `
                        -FilePath (Join-Path $env:SystemRoot 'System32\sc.exe') `
                        -ArgumentList @(
                            'create', $userServiceName,
                            'binPath=', $serviceNativeCommandLine,
                            'start=', 'auto',
                            'obj=', 'LocalSystem',
                            'DisplayName=', $serviceDisplayName) `
                        -SuccessExitCodes @(0) | Out-Null
                }
                Invoke-LemonCheckedNativeCommand `
                    -FilePath (Join-Path $env:SystemRoot 'System32\sc.exe') `
                    -ArgumentList @(
                        'description', $userServiceName,
                        $serviceDisplayName) `
                    -SuccessExitCodes @(0) | Out-Null
                $context.UserServiceCreated = $true
                $context.ServiceCommandLine = $serviceCommandLine
                if ($Mode -eq 'Migrate') {
                    Start-Service -Name $userServiceName -ErrorAction Stop
                    (Get-Service -Name $userServiceName -ErrorAction Stop).WaitForStatus(
                        'Running',
                        [TimeSpan]::FromSeconds(30))
                }
                [pscustomobject]@{
                    ImagePath = $serviceExecutable
                    CommandLine = $serviceCommandLine
                    AuthorizedClientImagePath = $aiClientExecutable
                    AuthorizedClientSha256 = $aiClientPackageSha256
                }
            }
            Rollback = {
                if ($Mode -eq 'Migrate') {
                    Invoke-LemonCheckedNativeCommand `
                        -FilePath (Join-Path $env:SystemRoot 'System32\sc.exe') `
                        -ArgumentList @(
                            'config', $userServiceName,
                            'binPath=', (ConvertTo-LemonScNativeBinaryPathArgument `
                                -Value ([string]$context.Migration.UserService.PathName)),
                            'start=', 'auto') `
                        -SuccessExitCodes @(0) | Out-Null
                }
                elseif ($context.UserServiceCreated) {
                    Invoke-LemonCheckedNativeCommand `
                        -FilePath (Join-Path $env:SystemRoot 'System32\sc.exe') `
                        -ArgumentList @('delete', $userServiceName) `
                        -SuccessExitCodes @(0, 1060) | Out-Null
                }
            }
        })

    $steps.Add([pscustomobject]@{
            Name = 'InstallUpperFilter'
            Apply = {
                $current = Get-LemonUpperFiltersSnapshot
                $updated = [string[]](Add-MultiStringValue `
                        -Values $current.Values `
                        -Entry $filterName)
                Set-LemonUpperFiltersSnapshot -Present $true -Values $updated
                if ($Mode -eq 'Fresh') {
                    $context.RebootRequired = $true
                }
                [pscustomobject]@{ Values = $updated }
            }
            Rollback = {
                Set-LemonUpperFiltersSnapshot `
                    -Present ([bool]$context.UpperFiltersBefore.Present) `
                    -Values ([string[]]$context.UpperFiltersBefore.Values)
            }
        })

    if ($rootPlatformKind -ne 'ServerCore') {
        $shortcutPlan = Get-LemonStartMenuShortcutPlan -InstallRoot $resolvedAppRoot
        $steps.Add([pscustomobject]@{
                Name = 'CreateShortcut'
                Apply = {
                    $context.Shortcut = New-LemonStartMenuShortcut -Plan $shortcutPlan
                    $context.Shortcut
                }
                Rollback = {
                    if ($null -ne $context.Shortcut) {
                        Remove-LemonStartMenuShortcut `
                            -Record $context.Shortcut `
                            -Plan $shortcutPlan | Out-Null
                    }
                }
            })
    }

    $statePath = Join-Path $InstallerRoot 'state\install-state.v1.json'
    $context.StatePath = $statePath
    $steps.Add([pscustomobject]@{
            Name = 'CommitInstallState'
            Apply = {
                $state = [pscustomobject][ordered]@{
                    SchemaVersion = 1
                    ProductId = 'LemonSerialMonitor'
                    ProductVersion = $productVersion
                    InstallId = $installId
                    InstalledUtc = [DateTimeOffset]::UtcNow.ToString('o')
                    InstallMode = $Mode
                    MigratedFromInstallId = if ($Mode -eq 'Migrate') {
                        [string]$context.Migration.Marker.InstallId
                    }
                    else { $null }
                    TestSigningChangedByInstaller =
                        [bool]$context.TestSigningChangedByInstaller
                    PlatformKind = $rootPlatformKind
                    AuthorizedUserSid = $AuthorizedUserSid
                    Roots = [pscustomobject][ordered]@{
                        AppRoot = $resolvedAppRoot
                        CoreRoot = $CoreRoot
                        DataRoot = $DataRoot
                        InstallerRoot = $InstallerRoot
                        AiStateRoot = $AiStateRoot
                    }
                    Certificate = $context.Certificate
                    Driver = $context.Driver
                    UserService = [pscustomobject][ordered]@{
                        Name = $userServiceName
                        ImagePath = $serviceExecutable
                        CommandLine = $serviceCommandLine
                        AuthorizedClientImagePath = $aiClientExecutable
                        AuthorizedClientSha256 = $aiClientPackageSha256
                        Created = $context.UserServiceCreated
                    }
                    KernelService = [pscustomobject][ordered]@{
                        Name = $kernelServiceName
                        ImagePath = [string](Get-CimInstance `
                                -ClassName Win32_SystemDriver `
                                -Filter "Name='$kernelServiceName'" `
                                -ErrorAction Stop).PathName
                    }
                    UpperFiltersBefore = $context.UpperFiltersBefore
                    Shortcut = $context.Shortcut
                }
                Write-CommMonitorAtomicTextFile `
                    -LiteralPath $statePath `
                    -Value ($state | ConvertTo-Json -Depth 12)
                Set-LemonProtectedStateAcl -Path $InstallerRoot
                Set-LemonProtectedStateAcl -Path $statePath
                $state
            }
            Rollback = {
                if (Test-Path -LiteralPath $statePath -PathType Leaf) {
                    Remove-Item -LiteralPath $statePath -Force
                }
            }
        })

    Invoke-LemonMutationTransaction -Steps $steps.ToArray() | Out-Null
    $status = if ($context.RebootRequired) { 'PendingReboot' } else { 'Completed' }
    Write-LemonInstallResult `
        -Status $status `
        -Message $(if ($status -eq 'PendingReboot') {
                'Installation completed; restart Windows to activate capture.'
            }
            else {
                'Installation completed.'
            }) `
        -FailureType $null
    if ($status -eq 'PendingReboot') { exit 3010 }
    exit 0
}
catch {
    $failure = $_
    try {
        Write-LemonInstallResult `
            -Status Failed `
            -Message $failure.Exception.Message `
            -FailureType $failure.Exception.GetType().FullName
    }
    catch {
        Write-Error "Installation failed and its result file could not be written: $($_.Exception.Message)"
    }
    Write-Error $failure
    exit 1
}
