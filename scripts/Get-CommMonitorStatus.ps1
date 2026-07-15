[CmdletBinding()]
param([switch] $PassThru)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CommMonitor.InstallHelpers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lemon.Platform.psm1') -Force

$filterName = 'CommMonitorFilter'
$kernelServiceName = 'CommMonitorFilter'
$userServiceName = 'CommMonitorService'
$portsClassPath =
    'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E978-E325-11CE-BFC1-08002BE10318}'
$CoreRoot = Join-Path $env:ProgramFiles 'CommMonitor'
$DataRoot = Join-Path $env:ProgramData 'CommMonitor'
$InstallerRoot = Join-Path $env:ProgramData 'LemonSerialMonitor\Installer'
$statePath = Join-Path $InstallerRoot 'state\install-state.v1.json'
$AppRoot = Join-Path $env:ProgramFiles (Get-LemonProductDisplayName)
$AiStateRoot = Join-Path $env:LocalAppData 'LemonSerialMonitor\AI'
$AuthorizedClientImagePath = Join-Path $AppRoot `
    'ai\Lemon.SerialMonitor.AI.exe'
$AuthorizedClientSha256 = $null
$state = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $state = Get-Content -Raw -LiteralPath $statePath -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
        if ($state.SchemaVersion -eq 1 -and
            [string]::Equals(
                [string]$state.ProductId,
                'LemonSerialMonitor',
                [StringComparison]::Ordinal)) {
            $AppRoot = [string]$state.Roots.AppRoot
            $CoreRoot = [string]$state.Roots.CoreRoot
            $DataRoot = [string]$state.Roots.DataRoot
            $InstallerRoot = [string]$state.Roots.InstallerRoot
            $AiStateRoot = [string]$state.Roots.AiStateRoot
            $AuthorizedClientImagePath = if ($null -ne $state.UserService -and
                $null -ne $state.UserService.PSObject.Properties[
                    'AuthorizedClientImagePath']) {
                [string]$state.UserService.AuthorizedClientImagePath
            }
            elseif ([string]$state.PlatformKind -eq 'ServerCore') {
                Join-Path $CoreRoot 'ai\Lemon.SerialMonitor.AI.exe'
            }
            else {
                Join-Path $AppRoot 'ai\Lemon.SerialMonitor.AI.exe'
            }
            if ($null -ne $state.UserService -and
                $null -ne $state.UserService.PSObject.Properties[
                    'AuthorizedClientSha256']) {
                $AuthorizedClientSha256 =
                    [string]$state.UserService.AuthorizedClientSha256
            }
        }
        else {
            $state = $null
        }
    }
    catch {
        $state = $null
    }
}

function Get-LemonServiceStatus {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][ValidateSet('Win32_Service', 'Win32_SystemDriver')]
        [string] $ClassName
    )

    $record = Get-CimInstance `
        -ClassName $ClassName `
        -Filter "Name='$Name'" `
        -ErrorAction SilentlyContinue
    if ($null -eq $record) {
        return [pscustomobject][ordered]@{
            Name = $Name
            Present = $false
            State = 'Missing'
            StartMode = $null
            ImagePath = $null
        }
    }
    return [pscustomobject][ordered]@{
        Name = $Name
        Present = $true
        State = [string]$record.State
        StartMode = [string]$record.StartMode
        ImagePath = [string]$record.PathName
    }
}

function Get-LemonTestSigningStatus {
    try {
        $output = & (Join-Path $env:SystemRoot 'System32\bcdedit.exe') `
            /enum '{current}' 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return 'Unknown' }
        if (Test-CommMonitorTestSigningOutput -Output $output) {
            return 'Enabled'
        }
        return 'Disabled'
    }
    catch { return 'Unknown' }
}

function Get-LemonSecureBootStatus {
    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { return 'Enabled' }
        return 'Disabled'
    }
    catch [PlatformNotSupportedException] { return 'UnsupportedOrLegacyBios' }
    catch { return 'Unknown' }
}

$filters = [string[]]@()
try {
    $key = Get-Item -LiteralPath $portsClassPath -ErrorAction Stop
    if (@($key.GetValueNames()) -contains 'UpperFilters') {
        $filters = [string[]]@($key.GetValue(
                'UpperFilters',
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
    }
}
catch {
    $filters = [string[]]@()
}

$thumbprint = if ($null -ne $state -and $null -ne $state.Certificate) {
    [string]$state.Certificate.Thumbprint
}
else { $null }
$rootCertificate = if (-not [string]::IsNullOrWhiteSpace($thumbprint)) {
    $null -ne (Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
        Where-Object Thumbprint -EQ $thumbprint |
        Select-Object -First 1)
}
else { $false }
$publisherCertificate = if (-not [string]::IsNullOrWhiteSpace($thumbprint)) {
    $null -ne (Get-ChildItem Cert:\LocalMachine\TrustedPublisher -ErrorAction SilentlyContinue |
        Where-Object Thumbprint -EQ $thumbprint |
        Select-Object -First 1)
}
else { $false }

$actualAiClientSha256 = if (Test-Path `
        -LiteralPath $AuthorizedClientImagePath `
        -PathType Leaf) {
    try {
        (Get-FileHash `
                -LiteralPath $AuthorizedClientImagePath `
                -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    catch { $null }
}
else { $null }
$aiClientMatchesAuthorization =
    -not [string]::IsNullOrWhiteSpace($AuthorizedClientSha256) -and
    -not [string]::IsNullOrWhiteSpace($actualAiClientSha256) -and
    [string]::Equals(
        $AuthorizedClientSha256,
        $actualAiClientSha256,
        [StringComparison]::OrdinalIgnoreCase)

$userService = Get-LemonServiceStatus `
    -Name $userServiceName `
    -ClassName Win32_Service
$kernelService = Get-LemonServiceStatus `
    -Name $kernelServiceName `
    -ClassName Win32_SystemDriver
$platform = Get-LemonWindowsPlatform
$report = [pscustomobject][ordered]@{
    ProductName = Get-LemonProductDisplayName
    TimestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
    InstallStatePresent = $null -ne $state
    InstallId = if ($null -ne $state) { [string]$state.InstallId } else { $null }
    ProductVersion = if ($null -ne $state) {
        [string]$state.ProductVersion
    }
    else { $null }
    Platform = $platform
    AppRoot = [pscustomobject]@{
        Path = $AppRoot
        Present = Test-Path -LiteralPath $AppRoot -PathType Container
    }
    CoreRoot = [pscustomobject]@{
        Path = $CoreRoot
        Present = Test-Path -LiteralPath $CoreRoot -PathType Container
    }
    DataRoot = [pscustomobject]@{
        Path = $DataRoot
        Present = Test-Path -LiteralPath $DataRoot -PathType Container
    }
    InstallerRoot = [pscustomobject]@{
        Path = $InstallerRoot
        Present = Test-Path -LiteralPath $InstallerRoot -PathType Container
    }
    AiStateRoot = [pscustomobject]@{
        Path = $AiStateRoot
        Present = Test-Path -LiteralPath $AiStateRoot -PathType Container
    }
    DesktopAppPresent = Test-Path -LiteralPath (
        Join-Path $AppRoot 'app\Lemon.SerialMonitor.exe') -PathType Leaf
    AiCliPresent = Test-Path `
        -LiteralPath $AuthorizedClientImagePath `
        -PathType Leaf
    AiClient = [pscustomobject]@{
        AuthorizedClientImagePath = $AuthorizedClientImagePath
        AuthorizedClientSha256 = $AuthorizedClientSha256
        ActualSha256 = $actualAiClientSha256
        MatchesAuthorization = $aiClientMatchesAuthorization
    }
    UserService = $userService
    KernelService = $kernelService
    UpperFilters = $filters
    FilterInstalled = @($filters | Where-Object {
            [string]::Equals(
                $_,
                $filterName,
                [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
    TestSigning = Get-LemonTestSigningStatus
    TestSigningChangedByInstaller = if ($null -ne $state -and
        $null -ne $state.PSObject.Properties['TestSigningChangedByInstaller']) {
        [bool]$state.TestSigningChangedByInstaller
    }
    else { $false }
    SecureBoot = Get-LemonSecureBootStatus
    CertificateThumbprint = $thumbprint
    CertificateInRoot = $rootCertificate
    CertificateInTrustedPublisher = $publisherCertificate
    ControlPipeName = 'Lemon.SerialMonitor.Control.v2'
    AiPipeName = 'Lemon.SerialMonitor.AI.v1'
    ControlPipeExpected = [bool]$userService.Present
    AiPipeExpected = [bool]$userService.Present
    RebootLikelyRequired = (@($filters | Where-Object {
                [string]::Equals(
                    $_,
                    $filterName,
                    [StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0) -and
        (-not $kernelService.Present -or $kernelService.State -ne 'Running')
}

if ($PassThru) { return $report }
$report | Format-List
