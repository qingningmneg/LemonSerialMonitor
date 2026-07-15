Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CommMonitorAuthorizedUserBindings =
    [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:CommMonitorDataRootAdoptionEvidence =
    [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:CommMonitorAuthenticatedOwnershipPayloads =
    [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:CommMonitorValidatedLegacyDataRootMarkers =
    [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:CommMonitorOwnershipProbeCapabilities =
    [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:CommMonitorTerminalPreparationCapabilities =
    [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:CommMonitorWindowsOwnershipProvider = $null

function Initialize-CommMonitorWindowsOwnershipProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $NativeHelperPath,
        [Parameter(Mandatory)][string] $ExpectedSha256,
        [Parameter(Mandatory)][string] $AuthorizedUserSid
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'The native ownership provider is available only on Windows.'
    }
    $canonicalSid = ConvertTo-CommMonitorCanonicalProfileUserSid `
        -Sid $AuthorizedUserSid
    if (-not [regex]::IsMatch(
            $ExpectedSha256,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw 'The native ownership helper requires an exact lowercase SHA-256.'
    }
    if (-not [regex]::IsMatch(
            $NativeHelperPath,
            '^[A-Za-z]:\\',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
        $NativeHelperPath.StartsWith('\\', [StringComparison]::Ordinal) -or
        $NativeHelperPath.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase) -or
        $NativeHelperPath.StartsWith('\\.\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The native ownership helper path must be fully qualified and local.'
    }
    $helperPath = [IO.Path]::GetFullPath($NativeHelperPath)
    $helper = Get-Item -LiteralPath $helperPath -Force -ErrorAction Stop
    if ($helper.PSIsContainer -or
        ($helper.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $helper.Length -le 0) {
        throw 'The native ownership helper must be a non-reparse regular file.'
    }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($helperPath))
    if ($drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw 'The native ownership helper must be stored on a fixed local drive.'
    }
    $actualSha256 = (Get-FileHash `
            -LiteralPath $helperPath `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not (Test-CommMonitorFixedTimeEquals `
            -LeftHex $actualSha256 `
            -RightHex $ExpectedSha256)) {
        throw 'The native ownership helper SHA-256 does not match the trusted payload.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $currentSid = $identity.User.Value
    }
    finally {
        $identity.Dispose()
    }
    if (-not [string]::Equals(
            $currentSid,
            $canonicalSid,
            [StringComparison]::Ordinal)) {
        throw 'The elevated token does not belong to the authorized interactive user.'
    }

    $record = [pscustomobject][ordered]@{
        NativeHelperPath = $helperPath
        NativeHelperSha256 = $actualSha256
        AuthorizedUserSid = $canonicalSid
    }
    if ($null -ne $script:CommMonitorWindowsOwnershipProvider) {
        $existing = ConvertTo-CommMonitorCanonicalJson `
            -InputObject $script:CommMonitorWindowsOwnershipProvider
        $candidate = ConvertTo-CommMonitorCanonicalJson -InputObject $record
        if (-not [string]::Equals(
                $existing,
                $candidate,
                [StringComparison]::Ordinal)) {
            throw 'The native ownership provider cannot be rebound in one process.'
        }
        return $script:CommMonitorWindowsOwnershipProvider
    }

    $script:CommMonitorWindowsOwnershipProvider = $record
    return $record
}

function Get-CommMonitorWindowsOwnershipProvider {
    [CmdletBinding()]
    param()

    if ($null -eq $script:CommMonitorWindowsOwnershipProvider) {
        throw ('The fixed pre-elevation interactive-session broker contract is unavailable; ' +
            'initialize the trusted native ownership provider before probing.')
    }
    return $script:CommMonitorWindowsOwnershipProvider
}

function Initialize-CommMonitorWindowsUserContextNativeType {
    [CmdletBinding()]
    param()

    if ($null -ne ('Lemon.SetupNative.UserContext' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Lemon.SetupNative
{
    public static class UserContext
    {
        private const uint BufferLength = 32768;
        private static readonly Guid LocalAppData =
            new Guid("f1b32785-6fba-4fcf-9d55-7b8e7f157091");

        public static string ExpandEnvironment(IntPtr token, string value)
        {
            var buffer = new StringBuilder((int)BufferLength);
            if (!ExpandEnvironmentStringsForUserW(
                    token, value, buffer, BufferLength))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return buffer.ToString();
        }

        public static string GetLocalAppData(IntPtr token)
        {
            IntPtr path;
            Guid folderId = LocalAppData;
            int result = SHGetKnownFolderPath(
                ref folderId, 0, token, out path);
            if (result != 0)
            {
                Marshal.ThrowExceptionForHR(result);
            }
            try
            {
                return Marshal.PtrToStringUni(path);
            }
            finally
            {
                Marshal.FreeCoTaskMem(path);
            }
        }

        [DllImport("userenv.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ExpandEnvironmentStringsForUserW(
            IntPtr token,
            string source,
            StringBuilder destination,
            uint size);

        [DllImport("shell32.dll")]
        private static extern int SHGetKnownFolderPath(
            ref Guid folderId,
            uint flags,
            IntPtr token,
            out IntPtr path);
    }
}
'@
}

function Copy-CommMonitorEvidenceValue {
    [CmdletBinding()]
    param([AllowNull()][object] $Value)

    if ($null -eq $Value -or $Value -is [string] -or
        $Value.GetType().IsValueType) {
        return $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        $copy = [Collections.Specialized.OrderedDictionary]::new(
            [StringComparer]::Ordinal)
        foreach ($key in $Value.Keys) {
            $copy.Add(
                [string]$key,
                (Copy-CommMonitorEvidenceValue -Value $Value[$key]))
        }
        return $copy
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((Copy-CommMonitorEvidenceValue -Value $item))
        }
        return $items.ToArray()
    }
    $dictionary = ConvertTo-CommMonitorOrderedDictionary -InputObject $Value
    return Copy-CommMonitorEvidenceValue -Value $dictionary
}
function Register-CommMonitorEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Registry,
        [Parameter(Mandatory)][object] $Evidence
    )

    $snapshot = ConvertTo-CommMonitorCanonicalJson -InputObject $Evidence
    $record = [pscustomobject]@{
        Snapshot = $snapshot
        Value = Copy-CommMonitorEvidenceValue -Value $Evidence
    }
    $Registry.Add($Evidence, $record)
    return $Evidence
}

function Test-CommMonitorRegisteredEvidence {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][object] $Registry,
        [AllowNull()][object] $Evidence
    )

    if ($null -eq $Evidence) { return $false }
    return $null -ne (Get-CommMonitorRegisteredEvidenceRecord `
        -Registry $Registry `
        -Evidence $Evidence)
}

function Get-CommMonitorRegisteredEvidenceRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Registry,
        [AllowNull()][object] $Evidence
    )

    if ($null -eq $Evidence) { return $null }
    $record = $null
    if (-not $Registry.TryGetValue($Evidence, [ref]$record)) {
        return $null
    }
    try {
        $current = ConvertTo-CommMonitorCanonicalJson -InputObject $Evidence
    }
    catch {
        return $null
    }
    if (-not [string]::Equals(
            [string]$record.Snapshot,
            $current,
            [StringComparison]::Ordinal)) {
        return $null
    }
    return $record
}

function Get-CommMonitorOwnershipProbeCapabilityRecord {
    [CmdletBinding()]
    param([AllowNull()][object] $Capability)

    if ($null -eq $Capability) { return $null }
    $record = $null
    if (-not $script:CommMonitorOwnershipProbeCapabilities.TryGetValue(
            $Capability,
            [ref]$record)) {
        return $null
    }
    try {
        $snapshot = ConvertTo-CommMonitorCanonicalJson -InputObject $Capability
    }
    catch {
        return $null
    }
    if (-not [string]::Equals(
            [string]$record.Snapshot,
            $snapshot,
            [StringComparison]::Ordinal)) {
        return $null
    }
    return $record
}

function New-CommMonitorWindowsOwnershipProbeCapability {
    [CmdletBinding()]
    param()

    $capability = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Provider = 'WindowsNativeOwnershipProbe'
        CapabilityId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
        Epoch = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    }
    $record = [pscustomobject]@{
        Snapshot = ConvertTo-CommMonitorCanonicalJson -InputObject $capability
        Provider = 'WindowsNativeOwnershipProbe'
        CapabilityId = [string]$capability.CapabilityId
        Epoch = [string]$capability.Epoch
    }
    $script:CommMonitorOwnershipProbeCapabilities.Add($capability, $record)
    return $capability
}

function Invoke-CommMonitorWindowsProfileListProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $AuthorizedUserSid)

    $subKeyPath =
        'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' +
        $AuthorizedUserSid
    $keyPath = 'HKLM:\' + $subKeyPath
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $profileKey = $baseKey.OpenSubKey($subKeyPath, $false)
        if ($null -eq $profileKey) { return @() }
        try {
            $valueKind = $profileKey.GetValueKind('ProfileImagePath')
            if ($valueKind -notin @(
                    [Microsoft.Win32.RegistryValueKind]::String,
                    [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
                throw 'ProfileImagePath has an unsupported Registry64 value kind.'
            }
            $rawPath = $profileKey.GetValue(
                'ProfileImagePath',
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($rawPath -isnot [string]) {
                throw 'The fixed HKLM ProfileList provider returned a non-string raw profile path.'
            }
        }
        finally {
            $profileKey.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
    return [pscustomobject][ordered]@{
        Sid = $AuthorizedUserSid
        ProfileListKeyPath = $keyPath
        ProfileImagePath = [string]$rawPath
        ProfileImagePathValueKind = [string]$valueKind
    }
}

function Invoke-CommMonitorWindowsProfilePathExpansionProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AuthorizedUserSid,
        [Parameter(Mandatory)][string] $RawProfileImagePath
    )

    $provider = Get-CommMonitorWindowsOwnershipProvider
    if (-not [string]::Equals(
            [string]$provider.AuthorizedUserSid,
            $AuthorizedUserSid,
            [StringComparison]::Ordinal)) {
        throw 'The profile expansion request is not bound to the authorized user.'
    }
    Initialize-CommMonitorWindowsUserContextNativeType
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if (-not [string]::Equals(
                $identity.User.Value,
                $AuthorizedUserSid,
                [StringComparison]::Ordinal)) {
            throw 'The profile expansion token does not match the authorized user.'
        }
        $expanded = [Lemon.SetupNative.UserContext]::ExpandEnvironment(
            $identity.Token,
            $RawProfileImagePath)
    }
    finally {
        $identity.Dispose()
    }
    return [pscustomobject][ordered]@{
        Source = 'ExpandEnvironmentStringsForUserW'
        Sid = $AuthorizedUserSid
        RawValue = $RawProfileImagePath
        Path = $expanded
        IdentityVerified = $true
    }
}

function Invoke-CommMonitorWindowsInteractiveSessionProbe {
    [CmdletBinding()]
    param()

    $provider = Get-CommMonitorWindowsOwnershipProvider
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $sid = $identity.User.Value
    }
    finally {
        $identity.Dispose()
    }
    if (-not [string]::Equals(
            $sid,
            [string]$provider.AuthorizedUserSid,
            [StringComparison]::Ordinal)) {
        throw 'The current Windows token does not match the authorized interactive user.'
    }
    return [pscustomobject][ordered]@{
        Source = 'WindowsTokenSessionProbe'
        OriginalInteractiveSid = $sid
        IdentityVerified = $true
    }
}

function Invoke-CommMonitorWindowsKnownFolderProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AuthorizedUserSid,
        [Parameter(Mandatory)][string] $KnownFolder
    )

    $provider = Get-CommMonitorWindowsOwnershipProvider
    if (-not [string]::Equals(
            [string]$provider.AuthorizedUserSid,
            $AuthorizedUserSid,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            $KnownFolder,
            'LocalAppData',
            [StringComparison]::Ordinal)) {
        throw 'The Known Folder request is not bound to the authorized user.'
    }
    Initialize-CommMonitorWindowsUserContextNativeType
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if (-not [string]::Equals(
                $identity.User.Value,
                $AuthorizedUserSid,
                [StringComparison]::Ordinal)) {
            throw 'The Known Folder token does not match the authorized user.'
        }
        $path = [Lemon.SetupNative.UserContext]::GetLocalAppData($identity.Token)
    }
    finally {
        $identity.Dispose()
    }
    return [pscustomobject][ordered]@{
        Sid = $AuthorizedUserSid
        KnownFolder = 'LocalAppData'
        KnownFolderId = '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}'
        Path = $path
        IdentityVerified = $true
    }
}

function Invoke-CommMonitorWindowsPathProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][ValidateSet(1, 2)][int] $Pass
    )

    $provider = Get-CommMonitorWindowsOwnershipProvider
    $pathBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($Path)
    $encodedPath = [Convert]::ToBase64String($pathBytes)
    $output = @(& ([string]$provider.NativeHelperPath) `
            'probe-path' `
            '--path-base64' `
            $encodedPath)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or $output.Count -ne 1 -or
        $output[0] -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$output[0])) {
        throw "The native ownership path probe failed with exit code $exitCode."
    }
    $probe = [string]$output[0] | ConvertFrom-Json -ErrorAction Stop
    $probe.AclProfile.DenyRuleCount = [int]$probe.AclProfile.DenyRuleCount
    foreach ($ancestor in @($probe.Ancestors)) {
        $ancestor.ReparseTag = [long]$ancestor.ReparseTag
    }
    return $probe
}

function Invoke-CommMonitorWindowsLegacyMarkerProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ExpectedDataRootPath)

    throw ('The fixed protected legacy-marker probe contract is unavailable; ' +
        'Task 5 must provide authenticated migration evidence.')
}

function Register-CommMonitorAuthorizedUserBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Binding,
        [Parameter(Mandatory)][object] $Capability,
        [Parameter(Mandatory)][object] $CapabilityRecord
    )

    $record = [pscustomobject]@{
        Snapshot = ConvertTo-CommMonitorCanonicalJson -InputObject $Binding
        BindingData = Copy-CommMonitorEvidenceValue -Value $Binding
        Capability = $Capability
        CapabilityRecord = $CapabilityRecord
        CapabilityId = [string]$CapabilityRecord.CapabilityId
        Epoch = [string]$CapabilityRecord.Epoch
    }
    $script:CommMonitorAuthorizedUserBindings.Add($Binding, $record)
    return $Binding
}

function Get-CommMonitorAuthorizedUserBindingRecord {
    [CmdletBinding()]
    param([AllowNull()][object] $Binding)

    if ($null -eq $Binding) { return $null }
    $record = $null
    if (-not $script:CommMonitorAuthorizedUserBindings.TryGetValue(
            $Binding,
            [ref]$record)) {
        return $null
    }
    try {
        $snapshot = ConvertTo-CommMonitorCanonicalJson -InputObject $Binding
    }
    catch {
        return $null
    }
    if (-not [string]::Equals(
            [string]$record.Snapshot,
            $snapshot,
            [StringComparison]::Ordinal)) {
        return $null
    }
    $currentCapabilityRecord = Get-CommMonitorOwnershipProbeCapabilityRecord `
        -Capability $record.Capability
    if ($null -eq $currentCapabilityRecord -or
        -not [object]::ReferenceEquals(
            $currentCapabilityRecord,
            $record.CapabilityRecord) -or
        -not [string]::Equals(
            [string]$record.CapabilityId,
            [string]$currentCapabilityRecord.CapabilityId,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$record.Epoch,
            [string]$currentCapabilityRecord.Epoch,
            [StringComparison]::Ordinal)) {
        return $null
    }
    return $record
}

function Register-CommMonitorAuthenticatedOwnershipPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Payload,
        [Parameter(Mandatory)][string] $PayloadSha256
    )

    $record = [pscustomobject]@{
        Snapshot = ConvertTo-CommMonitorCanonicalJson -InputObject $Payload
        Value = Copy-CommMonitorManifestSchemaValue -Value $Payload
        PayloadSha256 = $PayloadSha256
    }
    $script:CommMonitorAuthenticatedOwnershipPayloads.Add($Payload, $record)
    return $Payload
}

function Get-CommMonitorAuthenticatedOwnershipPayloadRecord {
    [CmdletBinding()]
    param([AllowNull()][object] $Payload)

    if ($null -eq $Payload) { return $null }
    $record = $null
    if (-not $script:CommMonitorAuthenticatedOwnershipPayloads.TryGetValue(
            $Payload,
            [ref]$record)) {
        return $null
    }
    $current = ConvertTo-CommMonitorCanonicalJson -InputObject $Payload
    if (-not [string]::Equals(
            [string]$record.Snapshot,
            $current,
            [StringComparison]::Ordinal)) {
        return $null
    }
    return $record
}

function Add-MultiStringValue {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [string[]] $Values,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Entry
    )

    $result = [Collections.Generic.List[string]]::new()
    foreach ($value in @($Values)) {
        $result.Add($value)
    }

    $alreadyPresent = $result.Exists(
        [Predicate[string]] {
            param($candidate)
            [string]::Equals(
                $candidate,
                $Entry,
                [StringComparison]::OrdinalIgnoreCase)
        })
    if (-not $alreadyPresent) {
        $result.Add($Entry)
    }

    return $result.ToArray()
}

function Remove-MultiStringValue {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [string[]] $Values,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Entry
    )

    $result = [Collections.Generic.List[string]]::new()
    foreach ($value in @($Values)) {
        if (-not [string]::Equals(
                $value,
                $Entry,
                [StringComparison]::OrdinalIgnoreCase)) {
            $result.Add($value)
        }
    }

    return $result.ToArray()
}

function New-CommMonitorInstallBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool] $UpperFiltersPresent,

        [AllowNull()]
        [object] $UpperFilters,

        [AllowNull()]
        [string] $KernelServiceState,

        [AllowNull()]
        [string] $UserServiceState,

        [AllowNull()]
        [string] $DriverTarget,

        [AllowNull()]
        [string] $InstallPath,

        [AllowNull()]
        [string] $DriverPackagePublishedName,

        [AllowNull()]
        [string] $DriverPackageOriginalFileName,

        [AllowNull()]
        [string] $DriverPackageInfSha256,

        [AllowNull()]
        [string] $KernelServiceImagePath,

        [AllowNull()]
        [string] $UserServiceImagePath,

        [AllowNull()]
        [string] $CertificateThumbprint,

        [bool] $RootCertificateAdded = $false,

        [bool] $PublisherCertificateAdded = $false,

        [bool] $DriverPackageAdded = $false,

        [bool] $KernelServiceCreated = $false,

        [bool] $UserServiceCreated = $false,

        [AllowNull()]
        [string] $InstallId
    )

    $upperFiltersWasNull = $null -eq $UpperFilters
    $filterCount = if ($upperFiltersWasNull) { -1 } else { @($UpperFilters).Count }
    $backupData = [ordered]@{
        SchemaVersion = 2
        CreatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        UpperFiltersPresent = $UpperFiltersPresent
        UpperFiltersWasNull = $upperFiltersWasNull
        UpperFiltersCount = $filterCount
        KernelServiceState = $KernelServiceState
        UserServiceState = $UserServiceState
        DriverTarget = $DriverTarget
        InstallPath = $InstallPath
        DriverPackagePublishedName = $DriverPackagePublishedName
        DriverPackageOriginalFileName = $DriverPackageOriginalFileName
        DriverPackageInfSha256 = $DriverPackageInfSha256
        KernelServiceImagePath = $KernelServiceImagePath
        UserServiceImagePath = $UserServiceImagePath
        CertificateThumbprint = $CertificateThumbprint
        RootCertificateAdded = $RootCertificateAdded
        PublisherCertificateAdded = $PublisherCertificateAdded
        DriverPackageAdded = $DriverPackageAdded
        KernelServiceCreated = $KernelServiceCreated
        UserServiceCreated = $UserServiceCreated
        InstallId = $InstallId
    }
    if ($upperFiltersWasNull) {
        $backupData['UpperFilters'] = $null
    }
    elseif ($filterCount -eq 0) {
        $backupData['UpperFilters'] = @()
    }
    else {
        $backupData['UpperFilters'] = [string[]]@($UpperFilters)
    }

    return [pscustomobject]$backupData
}

function ConvertTo-CommMonitorInstallBackupJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject] $Backup
    )

    process {
        return $Backup | ConvertTo-Json -Depth 8
    }
}

function ConvertFrom-CommMonitorInstallBackupJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string] $Json
    )

    process {
        $backup = $Json | ConvertFrom-Json
        if ($backup.SchemaVersion -notin @(1, 2)) {
            throw "Unsupported Lemon serial monitor install backup schema '$($backup.SchemaVersion)'."
        }

        if ($backup.UpperFiltersWasNull) {
            $normalizedFilters = $null
        }
        elseif ($backup.UpperFiltersCount -eq 0) {
            $normalizedFilters = [string[]]@()
        }
        else {
            $normalizedFilters = [string[]]@($backup.UpperFilters)
        }
        $backup | Add-Member `
            -MemberType NoteProperty `
            -Name UpperFilters `
            -Value $normalizedFilters `
            -Force
        return $backup
    }
}

function Resolve-CommMonitorInstallRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $InstallRoot,

        [string] $ProgramFilesPath = $env:ProgramFiles
    )

    if ([string]::IsNullOrWhiteSpace($ProgramFilesPath)) {
        throw 'The Program Files path is unavailable.'
    }

    $expected = [IO.Path]::GetFullPath(
        (Join-Path $ProgramFilesPath 'CommMonitor')).TrimEnd('\', '/')
    $actual = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    if (-not [string]::Equals(
            $actual,
            $expected,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "InstallRoot must be exactly '$expected'; received '$actual'."
    }

    return $expected
}

function ConvertTo-CommMonitorJsonEscapedString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        switch ([int]$character) {
            8 { [void]$builder.Append('\b'); break }
            9 { [void]$builder.Append('\t'); break }
            10 { [void]$builder.Append('\n'); break }
            12 { [void]$builder.Append('\f'); break }
            13 { [void]$builder.Append('\r'); break }
            34 { [void]$builder.Append('\"'); break }
            92 { [void]$builder.Append('\\'); break }
            default {
                if ([int]$character -lt 0x20) {
                    [void]$builder.AppendFormat(
                        [Globalization.CultureInfo]::InvariantCulture,
                        '\u{0:x4}',
                        [int]$character)
                }
                else {
                    [void]$builder.Append($character)
                }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-CommMonitorCanonicalJsonValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return 'null'
    }
    if ($Value -is [bool]) {
        if ([bool]$Value) { return 'true' }
        return 'false'
    }
    if ($Value -is [Guid]) {
        return ConvertTo-CommMonitorJsonEscapedString `
            -Value ([Guid]$Value).ToString('D').ToLowerInvariant()
    }
    if ($Value -is [DateTimeOffset]) {
        return ConvertTo-CommMonitorJsonEscapedString -Value (
            ([DateTimeOffset]$Value).ToUniversalTime().ToString(
                'yyyy-MM-ddTHH:mm:ss.fffffffZ',
                [Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [DateTime]) {
        return ConvertTo-CommMonitorJsonEscapedString -Value (
            ([DateTime]$Value).ToUniversalTime().ToString(
                'yyyy-MM-ddTHH:mm:ss.fffffffZ',
                [Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [string] -or $Value -is [char]) {
        return ConvertTo-CommMonitorJsonEscapedString -Value ([string]$Value)
    }
    if ($Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64] -or
        $Value -is [decimal]) {
        return ([IFormattable]$Value).ToString(
            $null,
            [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [single] -or $Value -is [double]) {
        $floatingPoint = [double]$Value
        if ([double]::IsNaN($floatingPoint) -or
            [double]::IsInfinity($floatingPoint)) {
            throw 'Canonical JSON rejects NaN and infinity.'
        }
        return $floatingPoint.ToString(
            'R',
            [Globalization.CultureInfo]::InvariantCulture).Replace('E', 'e')
    }

    if ($Value -is [Collections.IDictionary]) {
        $names = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($names, [StringComparer]::Ordinal)
        $seen = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        $members = [Collections.Generic.List[string]]::new()
        foreach ($name in $names) {
            if (-not $seen.Add($name)) {
                throw "Canonical JSON rejects duplicate or case-confused field '$name'."
            }
            $members.Add(
                (ConvertTo-CommMonitorJsonEscapedString -Value $name) + ':' +
                (ConvertTo-CommMonitorCanonicalJsonValue -Value $Value[$name]))
        }
        return '{' + [string]::Join(',', $members.ToArray()) + '}'
    }

    if ($Value -is [Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = [Collections.Generic.List[string]]::new()
        foreach ($item in $Value) {
            $items.Add((ConvertTo-CommMonitorCanonicalJsonValue -Value $item))
        }
        return '[' + [string]::Join(',', $items.ToArray()) + ']'
    }

    $dictionary = ConvertTo-CommMonitorOrderedDictionary -InputObject $Value
    if ($dictionary.Count -ne 0) {
        return ConvertTo-CommMonitorCanonicalJsonValue -Value $dictionary
    }

    throw "Canonical JSON does not support type '$($Value.GetType().FullName)'."
}

function ConvertTo-CommMonitorCanonicalJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        return ConvertTo-CommMonitorCanonicalJsonValue -Value $InputObject
    }
}

function Get-CommMonitorCanonicalJsonBytes {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        $json = ConvertTo-CommMonitorCanonicalJson -InputObject $InputObject
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        Write-Output -NoEnumerate ([byte[]]$bytes)
    }
}

function Get-CommMonitorCanonicalStateFileBytes {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        $authenticationBytes = Get-CommMonitorCanonicalJsonBytes `
            -InputObject $InputObject
        $diskBytes = [byte[]]::new($authenticationBytes.Length + 1)
        [Array]::Copy(
            $authenticationBytes,
            0,
            $diskBytes,
            0,
            $authenticationBytes.Length)
        $diskBytes[$diskBytes.Length - 1] = 0x0a
        Write-Output -NoEnumerate $diskBytes
    }
}

function Test-CommMonitorJsonWhitespace {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][char] $Character)

    $codePoint = [int]$Character
    return $codePoint -eq 0x20 -or
        $codePoint -eq 0x09 -or
        $codePoint -eq 0x0a -or
        $codePoint -eq 0x0d
}

function Move-CommMonitorJsonWhitespace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Json,
        [Parameter(Mandatory)][ref] $Index
    )

    while ($Index.Value -lt $Json.Length -and
        (Test-CommMonitorJsonWhitespace -Character $Json[$Index.Value])) {
        $Index.Value++
    }
}

function Read-CommMonitorJsonStringToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Json,
        [Parameter(Mandatory)][ref] $Index
    )

    if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne '"') {
        throw "Invalid JSON string at offset $($Index.Value)."
    }
    $Index.Value++
    $builder = [Text.StringBuilder]::new()
    while ($Index.Value -lt $Json.Length) {
        $character = $Json[$Index.Value]
        $Index.Value++
        if ($character -eq '"') {
            return $builder.ToString()
        }
        if ([int]$character -lt 0x20) {
            throw 'Invalid unescaped JSON control character.'
        }
        if ($character -ne '\') {
            [void]$builder.Append($character)
            continue
        }
        if ($Index.Value -ge $Json.Length) {
            throw 'Invalid trailing JSON escape.'
        }
        $escape = $Json[$Index.Value]
        $Index.Value++
        switch -CaseSensitive ($escape) {
            '"' { [void]$builder.Append('"') }
            '\' { [void]$builder.Append('\') }
            '/' { [void]$builder.Append('/') }
            'b' { [void]$builder.Append([char]8) }
            'f' { [void]$builder.Append([char]12) }
            'n' { [void]$builder.Append([char]10) }
            'r' { [void]$builder.Append([char]13) }
            't' { [void]$builder.Append([char]9) }
            'u' {
                if ($Index.Value + 4 -gt $Json.Length) {
                    throw 'Invalid JSON Unicode escape.'
                }
                $hex = $Json.Substring($Index.Value, 4)
                if (-not [regex]::IsMatch($hex, '^[0-9a-fA-F]{4}$')) {
                    throw 'Invalid JSON Unicode escape.'
                }
                [void]$builder.Append([char][Convert]::ToUInt16($hex, 16))
                $Index.Value += 4
            }
            default { throw "Invalid JSON escape '\$escape'." }
        }
    }
    throw 'Unterminated JSON string.'
}

function Read-CommMonitorJsonValueToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Json,
        [Parameter(Mandatory)][ref] $Index,
        [Parameter(Mandatory)][int] $Depth,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]] $RootFields
    )

    Move-CommMonitorJsonWhitespace -Json $Json -Index $Index
    if ($Index.Value -ge $Json.Length) {
        throw 'Unexpected end of JSON.'
    }
    $token = $Json[$Index.Value]
    if ($token -eq '{') {
        $Index.Value++
        $exact = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $folded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Move-CommMonitorJsonWhitespace -Json $Json -Index $Index
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq '}') {
            $Index.Value++
            return
        }
        while ($true) {
            Move-CommMonitorJsonWhitespace -Json $Json -Index $Index
            $name = Read-CommMonitorJsonStringToken -Json $Json -Index $Index
            if (-not $exact.Add($name)) {
                throw "Duplicate JSON field '$name'."
            }
            if (-not $folded.Add($name)) {
                throw "Case-confused JSON field '$name'."
            }
            if ($Depth -eq 0) {
                $RootFields.Add($name)
            }
            Move-CommMonitorJsonWhitespace -Json $Json -Index $Index
            if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne ':') {
                throw "JSON field '$name' is missing a colon."
            }
            $Index.Value++
            Read-CommMonitorJsonValueToken `
                -Json $Json `
                -Index $Index `
                -Depth ($Depth + 1) `
                -RootFields $RootFields
            Move-CommMonitorJsonWhitespace -Json $Json -Index $Index
            if ($Index.Value -ge $Json.Length) {
                throw 'Unterminated JSON object.'
            }
            if ($Json[$Index.Value] -eq '}') {
                $Index.Value++
                return
            }
            if ($Json[$Index.Value] -ne ',') {
                throw 'Invalid JSON object delimiter.'
            }
            $Index.Value++
        }
    }
    if ($token -eq '[') {
        $Index.Value++
        Move-CommMonitorJsonWhitespace -Json $Json -Index $Index
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq ']') {
            $Index.Value++
            return
        }
        while ($true) {
            Read-CommMonitorJsonValueToken `
                -Json $Json `
                -Index $Index `
                -Depth ($Depth + 1) `
                -RootFields $RootFields
            Move-CommMonitorJsonWhitespace -Json $Json -Index $Index
            if ($Index.Value -ge $Json.Length) {
                throw 'Unterminated JSON array.'
            }
            if ($Json[$Index.Value] -eq ']') {
                $Index.Value++
                return
            }
            if ($Json[$Index.Value] -ne ',') {
                throw 'Invalid JSON array delimiter.'
            }
            $Index.Value++
        }
    }
    if ($token -eq '"') {
        [void](Read-CommMonitorJsonStringToken -Json $Json -Index $Index)
        return
    }

    $start = $Index.Value
    while ($Index.Value -lt $Json.Length -and
        $Json[$Index.Value] -notin @(',', '}', ']') -and
        -not (Test-CommMonitorJsonWhitespace -Character $Json[$Index.Value])) {
        $Index.Value++
    }
    $primitive = $Json.Substring($start, $Index.Value - $start)
    if (-not [regex]::IsMatch(
            $primitive,
            '^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw "Invalid JSON primitive '$primitive'."
    }
}

function ConvertFrom-CommMonitorStrictJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Json,
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $AllowedRootFields
    )

    if ($null -eq $AllowedRootFields) {
        throw 'AllowedRootFields must not be null.'
    }
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $foldedAllowed = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($field in @($AllowedRootFields)) {
        if ($field -isnot [string]) {
            throw 'AllowedRootFields entries must be raw strings.'
        }
        if (-not $allowed.Add($field)) {
            throw "AllowedRootFields contains duplicate field '$field'."
        }
        if (-not $foldedAllowed.Add($field)) {
            throw "AllowedRootFields contains case-confused field '$field'."
        }
    }

    $index = 0
    Move-CommMonitorJsonWhitespace -Json $Json -Index ([ref]$index)
    if ($index -ge $Json.Length -or $Json[$index] -ne '{') {
        throw 'Strict JSON requires an object root.'
    }
    $rootFields = [Collections.Generic.List[string]]::new()
    Read-CommMonitorJsonValueToken `
        -Json $Json `
        -Index ([ref]$index) `
        -Depth 0 `
        -RootFields $rootFields
    Move-CommMonitorJsonWhitespace -Json $Json -Index ([ref]$index)
    if ($index -ne $Json.Length) {
        throw "Unexpected JSON content at offset $index."
    }

    foreach ($field in $rootFields) {
        if (-not $allowed.Contains($field)) {
            throw "Unknown JSON field '$field'."
        }
    }

    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $serializer = [Web.Script.Serialization.JavaScriptSerializer]::new()
    $serializer.MaxJsonLength = 16MB
    return $serializer.DeserializeObject($Json)
}

function Get-CommMonitorSha256Hex {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
                $sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-CommMonitorHmacSha256Hex {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes
    )

    if ($Key.Length -ne 32) {
        throw 'HMAC-SHA256 key must be exactly 256 bits.'
    }
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return ([BitConverter]::ToString(
                $hmac.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $hmac.Dispose()
    }
}

function Test-CommMonitorFixedTimeEquals {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][string] $LeftHex,
        [AllowNull()][string] $RightHex
    )

    if (-not [regex]::IsMatch([string]$LeftHex, '^[0-9a-f]{64}$') -or
        -not [regex]::IsMatch([string]$RightHex, '^[0-9a-f]{64}$')) {
        return $false
    }
    $difference = 0
    for ($index = 0; $index -lt 64; $index += 2) {
        $left = [Convert]::ToByte($LeftHex.Substring($index, 2), 16)
        $right = [Convert]::ToByte($RightHex.Substring($index, 2), 16)
        $difference = $difference -bor ($left -bxor $right)
    }
    return $difference -eq 0
}

function New-CommMonitorManifestKey {
    [CmdletBinding()]
    param(
        [AllowNull()][byte[]] $KeyBytes,
        [scriptblock] $ProtectScript
    )

    if ($null -eq $KeyBytes) {
        $KeyBytes = [byte[]]::new(32)
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $random.GetBytes($KeyBytes)
        }
        finally {
            $random.Dispose()
        }
    }
    else {
        $KeyBytes = [byte[]]@($KeyBytes)
    }
    if ($KeyBytes.Length -ne 32) {
        throw 'Manifest key must be exactly 256 random bits.'
    }

    $protectedBlob = if ($null -ne $ProtectScript) {
        [byte[]]@(& $ProtectScript $KeyBytes)
    }
    else {
        [Security.Cryptography.ProtectedData]::Protect(
            $KeyBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::LocalMachine)
    }
    if ($protectedBlob.Length -eq 0) {
        throw 'DPAPI returned an empty protected manifest key.'
    }

    $keyId = Get-CommMonitorSha256Hex -Bytes $KeyBytes
    $record = [ordered]@{
        algorithm = 'DPAPI'
        keyId = $keyId
        protectedBlob = [Convert]::ToBase64String($protectedBlob)
        protectedBlobSha256 = Get-CommMonitorSha256Hex -Bytes $protectedBlob
        schemaVersion = 1
        scope = 'LocalMachine'
        state = 'Active'
    }
    return [pscustomobject]@{
        KeyBytes = $KeyBytes
        Record = $record
    }
}

function Get-CommMonitorManifestKey {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][object] $Record,
        [scriptblock] $UnprotectScript
    )

    $keyRecord = ConvertTo-CommMonitorOrderedDictionary -InputObject $Record
    $fields = @(
        'algorithm', 'keyId', 'protectedBlob', 'protectedBlobSha256',
        'schemaVersion', 'scope', 'state')
    Assert-CommMonitorExactFields `
        -Dictionary $keyRecord `
        -Allowed $fields `
        -Required $fields `
        -Subject 'Manifest key record'
    if ($keyRecord.schemaVersion -ne 1 -or
        -not (Test-CommMonitorOrdinalValue `
            -Value $keyRecord.algorithm `
            -Allowed @('DPAPI')) -or
        -not (Test-CommMonitorOrdinalValue `
            -Value $keyRecord.scope `
            -Allowed @('LocalMachine')) -or
        -not (Test-CommMonitorOrdinalValue `
            -Value $keyRecord.state `
            -Allowed @('Active'))) {
        throw 'Invalid manifest key record metadata.'
    }
    Assert-CommMonitorHash -Value $keyRecord.keyId -Length 64 -Name keyId
    Assert-CommMonitorHash `
        -Value $keyRecord.protectedBlobSha256 `
        -Length 64 `
        -Name protectedBlobSha256
    try {
        $protectedBlob = [Convert]::FromBase64String([string]$keyRecord.protectedBlob)
    }
    catch {
        throw 'Manifest key protectedBlob is not canonical base64.'
    }
    $blobSha256 = Get-CommMonitorSha256Hex -Bytes $protectedBlob
    if (-not (Test-CommMonitorFixedTimeEquals `
            -LeftHex $blobSha256 `
            -RightHex ([string]$keyRecord.protectedBlobSha256))) {
        throw 'Manifest key protected blob digest mismatch.'
    }

    $key = if ($null -ne $UnprotectScript) {
        [byte[]]@(& $UnprotectScript $protectedBlob)
    }
    else {
        [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBlob,
            $null,
            [Security.Cryptography.DataProtectionScope]::LocalMachine)
    }
    if ($key.Length -ne 32) {
        throw 'Unprotected manifest key is not 256 bits.'
    }
    $actualKeyId = Get-CommMonitorSha256Hex -Bytes $key
    if (-not (Test-CommMonitorFixedTimeEquals `
            -LeftHex $actualKeyId `
            -RightHex ([string]$keyRecord.keyId))) {
        throw 'Manifest keyId does not match the unprotected key.'
    }
    return ,$key
}

function Test-CommMonitorKeyFileAcl {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $OwnerSid,
        [AllowEmptyCollection()][object[]] $AccessRules,
        [Parameter(Mandatory)][bool] $AreAccessRulesProtected
    )

    if (-not $AreAccessRulesProtected -or
        $OwnerSid -notin @('S-1-5-18', 'S-1-5-32-544')) {
        return $false
    }
    $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($rule in @($AccessRules)) {
        $sid = if ($null -ne $rule.PSObject.Properties['IdentitySid']) {
            [string]$rule.IdentitySid
        }
        else {
            [string]$rule.IdentityReference
        }
        if ($sid -notin @('S-1-5-18', 'S-1-5-32-544') -or
            -not [string]::Equals(
                [string]$rule.AccessControlType,
                'Allow',
                [StringComparison]::OrdinalIgnoreCase) -or
            (([Security.AccessControl.FileSystemRights]$rule.FileSystemRights -band
                    [Security.AccessControl.FileSystemRights]::FullControl) -ne
                [Security.AccessControl.FileSystemRights]::FullControl)) {
            return $false
        }
        [void]$required.Add($sid)
    }
    return $required.Contains('S-1-5-18') -and
        $required.Contains('S-1-5-32-544')
}

function New-CommMonitorOwnershipEnvelope {
    [CmdletBinding()]
    [OutputType([Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object] $Payload,
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][string] $KeyId
    )

    Assert-CommMonitorHash -Value $KeyId -Length 64 -Name keyId
    $actualKeyId = Get-CommMonitorSha256Hex -Bytes $Key
    if (-not (Test-CommMonitorFixedTimeEquals `
            -LeftHex $actualKeyId `
            -RightHex $KeyId)) {
        throw 'Envelope keyId does not match the supplied key.'
    }
    $validatedPayload = ConvertTo-CommMonitorCanonicalOwnershipPayload -Payload $Payload
    $payloadBytes = Get-CommMonitorCanonicalJsonBytes `
        -InputObject $validatedPayload
    $payloadSha256 = Get-CommMonitorSha256Hex -Bytes $payloadBytes
    return [ordered]@{
        integrity = [ordered]@{
            algorithm = 'HMAC-SHA256'
            keyId = $KeyId
            payloadSha256 = $payloadSha256
            tag = Get-CommMonitorHmacSha256Hex -Key $Key -Bytes $payloadBytes
        }
        payload = $validatedPayload
        schemaVersion = 3
    }
}

function New-CommMonitorOwnershipManifest {
    [CmdletBinding()]
    [OutputType([Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object] $Payload,
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][string] $KeyId,
        [Parameter(Mandatory)][object] $ActiveSlot
    )

    $activeSlotValue = Copy-CommMonitorSchemaString `
        -Value $ActiveSlot `
        -Subject 'Ownership manifest activeSlot'
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $activeSlotValue `
            -Allowed @('A', 'B'))) {
        throw 'Ownership manifest activeSlot must be exactly A or B.'
    }
    $envelope = New-CommMonitorOwnershipEnvelope `
        -Payload $Payload `
        -Key $Key `
        -KeyId $KeyId
    return [ordered]@{
        slots = [ordered]@{
            A = if ($activeSlotValue -eq 'A') { $envelope } else { $null }
            B = if ($activeSlotValue -eq 'B') { $envelope } else { $null }
        }
        schemaVersion = 3
    }
}

function Assert-CommMonitorOwnershipEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Envelope,
        [Parameter(Mandatory)][byte[]] $Key
    )

    $envelopeData = ConvertTo-CommMonitorSchemaObject `
        -Value $Envelope `
        -Subject 'Ownership envelope'
    Assert-CommMonitorExactFields `
        -Dictionary $envelopeData `
        -Allowed @('integrity', 'payload', 'schemaVersion') `
        -Required @('integrity', 'payload', 'schemaVersion') `
        -Subject 'Ownership envelope'
    $schemaVersion = Copy-CommMonitorSchemaInt32 `
        -Value $envelopeData.schemaVersion `
        -Subject 'Ownership envelope schemaVersion'
    if ($schemaVersion -ne 3) {
        throw 'Ownership envelope schemaVersion must be 3.'
    }
    $integrity = ConvertTo-CommMonitorSchemaObject `
        -Value $envelopeData.integrity `
        -Subject 'Ownership envelope integrity'
    $integrityFields = @('algorithm', 'keyId', 'payloadSha256', 'tag')
    Assert-CommMonitorExactFields `
        -Dictionary $integrity `
        -Allowed $integrityFields `
        -Required $integrityFields `
        -Subject 'Ownership envelope integrity'
    foreach ($field in $integrityFields) {
        [void](Copy-CommMonitorSchemaString `
                -Value $integrity[$field] `
                -Subject "Ownership envelope integrity $field")
    }
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $integrity.algorithm `
            -Allowed @('HMAC-SHA256'))) {
        throw 'Ownership envelope requires HMAC-SHA256.'
    }
    foreach ($hashName in @('keyId', 'payloadSha256', 'tag')) {
        Assert-CommMonitorHash -Value $integrity[$hashName] -Length 64 -Name $hashName
    }
    $validatedPayload = ConvertTo-CommMonitorCanonicalOwnershipPayload `
        -Payload $envelopeData.payload
    $actualKeyId = Get-CommMonitorSha256Hex -Bytes $Key
    if (-not (Test-CommMonitorFixedTimeEquals `
            -LeftHex $actualKeyId `
            -RightHex ([string]$integrity.keyId))) {
        throw 'Ownership envelope keyId mismatch.'
    }
    $payloadBytes = Get-CommMonitorCanonicalJsonBytes `
        -InputObject $validatedPayload
    $actualPayloadSha256 = Get-CommMonitorSha256Hex -Bytes $payloadBytes
    $actualTag = Get-CommMonitorHmacSha256Hex -Key $Key -Bytes $payloadBytes
    if (-not (Test-CommMonitorFixedTimeEquals `
            -LeftHex $actualPayloadSha256 `
            -RightHex ([string]$integrity.payloadSha256)) -or
        -not (Test-CommMonitorFixedTimeEquals `
            -LeftHex $actualTag `
            -RightHex ([string]$integrity.tag))) {
        throw 'Ownership envelope payload authentication failed.'
    }
    return $validatedPayload
}

function Assert-CommMonitorOwnershipManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Manifest,
        [Parameter(Mandatory)][byte[]] $Key
    )

    $manifestData = ConvertTo-CommMonitorSchemaObject `
        -Value $Manifest `
        -Subject 'Ownership manifest'
    Assert-CommMonitorExactFields `
        -Dictionary $manifestData `
        -Allowed @('slots', 'schemaVersion') `
        -Required @('slots', 'schemaVersion') `
        -Subject 'Ownership manifest'
    $schemaVersion = Copy-CommMonitorSchemaInt32 `
        -Value $manifestData.schemaVersion `
        -Subject 'Ownership manifest schemaVersion'
    if ($schemaVersion -ne 3) {
        throw 'Ownership manifest schemaVersion must be 3.'
    }
    $slots = ConvertTo-CommMonitorSchemaObject `
        -Value $manifestData.slots `
        -Subject 'Ownership manifest slots'
    Assert-CommMonitorExactFields `
        -Dictionary $slots `
        -Allowed @('A', 'B') `
        -Required @('A', 'B') `
        -Subject 'Ownership manifest slots'

    $slotRecords = [ordered]@{}
    foreach ($slotName in @('A', 'B')) {
        $slotEnvelope = $slots[$slotName]
        if ($null -eq $slotEnvelope) {
            $slotRecords[$slotName] = $null
            continue
        }
        if (-not (Test-CommMonitorRawSchemaObject -Value $slotEnvelope)) {
            throw "Ownership manifest slot $slotName must be null or a raw envelope object."
        }
        $payload = Assert-CommMonitorOwnershipEnvelope `
            -Envelope $slotEnvelope `
            -Key $Key
        $envelopeData = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $slotEnvelope
        $integrity = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $envelopeData.integrity
        $slotRecords[$slotName] = [pscustomobject]@{
            Envelope = $slotEnvelope
            Payload = $payload
            Integrity = $integrity
        }
    }
    if ($null -eq $slotRecords.A -and $null -eq $slotRecords.B) {
        throw 'Ownership manifest requires at least one populated slot.'
    }
    if ($null -ne $slotRecords.A -and $null -ne $slotRecords.B) {
        $aPayload = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $slotRecords.A.Payload
        $bPayload = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $slotRecords.B.Payload
        if (-not [string]::Equals(
                [string]$aPayload.appId,
                [string]$bPayload.appId,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$aPayload.installId,
                [string]$bPayload.installId,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$slotRecords.A.Integrity.keyId,
                [string]$slotRecords.B.Integrity.keyId,
                [StringComparison]::Ordinal)) {
            throw 'Ownership manifest slots belong to different installations or keys.'
        }
        $newer = if ([int]$aPayload.revision -gt [int]$bPayload.revision) {
            $slotRecords.A
        }
        else {
            $slotRecords.B
        }
        $older = if ([object]::ReferenceEquals($newer, $slotRecords.A)) {
            $slotRecords.B
        }
        else {
            $slotRecords.A
        }
        $newerPayload = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $newer.Payload
        $olderPayload = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $older.Payload
        if ([int]$newerPayload.revision -ne ([int]$olderPayload.revision + 1) -or
            -not [string]::Equals(
                [string]$newerPayload.previousPayloadSha256,
                [string]$older.Integrity.payloadSha256,
                [StringComparison]::Ordinal)) {
            throw 'Ownership manifest slots are not one authenticated adjacent revision chain.'
        }
    }
    return [pscustomobject]@{
        Manifest = $manifestData
        Slots = $slotRecords
    }
}

function New-CommMonitorOwnershipAnchor {
    [CmdletBinding()]
    [OutputType([Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object] $Payload,
        [Parameter(Mandatory)][string] $PayloadSha256,
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][string] $KeyId,
        [object] $ActiveSlot = 'A'
    )

    Assert-CommMonitorHash -Value $PayloadSha256 -Length 64 -Name payloadSha256
    $activeSlotValue = Copy-CommMonitorSchemaString `
        -Value $ActiveSlot `
        -Subject 'Ownership anchor activeSlot'
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $activeSlotValue `
            -Allowed @('A', 'B'))) {
        throw 'Ownership anchor activeSlot must be exactly A or B.'
    }
    $payloadData = ConvertTo-CommMonitorOrderedDictionary -InputObject $Payload
    foreach ($field in @('appId', 'installId', 'revision')) {
        if (-not $payloadData.Contains($field)) {
            throw "Anchor payload is missing '$field'."
        }
    }
    $canonicalManifestPath = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path $ManifestPath `
        -Role ManifestPath
    $binding = [ordered]@{
        activeSlot = $activeSlotValue
        appId = [string]$payloadData.appId
        installId = [string]$payloadData.installId
        keyId = $KeyId
        manifestPath = $canonicalManifestPath
        payloadSha256 = $PayloadSha256
        revision = [int]$payloadData.revision
    }
    $bindingBytes = Get-CommMonitorCanonicalJsonBytes -InputObject $binding
    return [ordered]@{
        binding = $binding
        integrity = [ordered]@{
            algorithm = 'HMAC-SHA256'
            keyId = $KeyId
            tag = Get-CommMonitorHmacSha256Hex -Key $Key -Bytes $bindingBytes
        }
        schemaVersion = 3
    }
}

function Assert-CommMonitorOwnershipState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Envelope,
        [Parameter(Mandatory)][object] $Anchor,
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][string] $ExpectedManifestPath,
        [Parameter(Mandatory)][string] $ExpectedAppId,
        [Parameter(Mandatory)][string] $ExpectedInstallId
    )

    $payload = Assert-CommMonitorOwnershipEnvelope -Envelope $Envelope -Key $Key
    $payloadData = ConvertTo-CommMonitorSchemaObject `
        -Value $payload `
        -Subject 'Ownership payload'
    $envelopeData = ConvertTo-CommMonitorSchemaObject `
        -Value $Envelope `
        -Subject 'Ownership envelope'
    $envelopeIntegrity = ConvertTo-CommMonitorSchemaObject `
        -Value $envelopeData.integrity `
        -Subject 'Ownership envelope integrity'
    $anchorData = ConvertTo-CommMonitorSchemaObject `
        -Value $Anchor `
        -Subject 'Ownership anchor'
    Assert-CommMonitorExactFields `
        -Dictionary $anchorData `
        -Allowed @('binding', 'integrity', 'schemaVersion') `
        -Required @('binding', 'integrity', 'schemaVersion') `
        -Subject 'Ownership anchor'
    $anchorSchemaVersion = Copy-CommMonitorSchemaInt32 `
        -Value $anchorData.schemaVersion `
        -Subject 'Ownership anchor schemaVersion'
    if ($anchorSchemaVersion -ne 3) {
        throw 'Ownership anchor schemaVersion must be 3.'
    }
    $binding = ConvertTo-CommMonitorSchemaObject `
        -Value $anchorData.binding `
        -Subject 'Ownership anchor binding'
    $bindingFields = @(
        'activeSlot', 'appId', 'installId', 'keyId', 'manifestPath',
        'payloadSha256', 'revision')
    Assert-CommMonitorExactFields `
        -Dictionary $binding `
        -Allowed $bindingFields `
        -Required $bindingFields `
        -Subject 'Ownership anchor binding'
    foreach ($field in @(
            'activeSlot', 'appId', 'installId', 'keyId',
            'manifestPath', 'payloadSha256')) {
        [void](Copy-CommMonitorSchemaString `
                -Value $binding[$field] `
                -Subject "Ownership anchor binding $field")
    }
    [void](Copy-CommMonitorSchemaInt32 `
            -Value $binding.revision `
            -Subject 'Ownership anchor binding revision')
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $binding.activeSlot `
            -Allowed @('A', 'B'))) {
        throw 'Ownership anchor binding activeSlot must be exactly A or B.'
    }
    $integrity = ConvertTo-CommMonitorSchemaObject `
        -Value $anchorData.integrity `
        -Subject 'Ownership anchor integrity'
    Assert-CommMonitorExactFields `
        -Dictionary $integrity `
        -Allowed @('algorithm', 'keyId', 'tag') `
        -Required @('algorithm', 'keyId', 'tag') `
        -Subject 'Ownership anchor integrity'
    foreach ($field in @('algorithm', 'keyId', 'tag')) {
        [void](Copy-CommMonitorSchemaString `
                -Value $integrity[$field] `
                -Subject "Ownership anchor integrity $field")
    }
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $integrity.algorithm `
            -Allowed @('HMAC-SHA256'))) {
        throw 'Ownership anchor requires HMAC-SHA256.'
    }
    $bindingBytes = Get-CommMonitorCanonicalJsonBytes -InputObject $binding
    $actualAnchorTag = Get-CommMonitorHmacSha256Hex -Key $Key -Bytes $bindingBytes
    if (-not (Test-CommMonitorFixedTimeEquals `
            -LeftHex $actualAnchorTag `
            -RightHex ([string]$integrity.tag))) {
        throw 'Ownership anchor authentication failed.'
    }
    $canonicalExpectedPath = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path $ExpectedManifestPath `
        -Role ExpectedManifestPath
    if (-not [string]::Equals(
            [string]$payloadData.appId,
            $ExpectedAppId,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$payloadData.installId,
            $ExpectedInstallId,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$binding.appId,
            [string]$payloadData.appId,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$binding.installId,
            [string]$payloadData.installId,
            [StringComparison]::Ordinal) -or
        [int]$binding.revision -ne [int]$payloadData.revision -or
        -not [string]::Equals(
            [string]$binding.keyId,
            [string]$envelopeIntegrity.keyId,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$integrity.keyId,
            [string]$envelopeIntegrity.keyId,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$binding.payloadSha256,
            [string]$envelopeIntegrity.payloadSha256,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$binding.manifestPath,
            $canonicalExpectedPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Ownership anchor does not cross-bind the expected manifest state.'
    }
    return Register-CommMonitorAuthenticatedOwnershipPayload `
        -Payload $payload `
        -PayloadSha256 ([string]$envelopeIntegrity.payloadSha256)
}

function Assert-CommMonitorOwnershipManifestState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Manifest,
        [Parameter(Mandatory)][object] $Anchor,
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][string] $ExpectedManifestPath,
        [Parameter(Mandatory)][string] $ExpectedAppId,
        [Parameter(Mandatory)][string] $ExpectedInstallId
    )

    $validatedManifest = Assert-CommMonitorOwnershipManifest `
        -Manifest $Manifest `
        -Key $Key
    $anchorData = ConvertTo-CommMonitorSchemaObject `
        -Value $Anchor `
        -Subject 'Ownership anchor'
    if (-not $anchorData.Contains('binding')) {
        throw "Ownership anchor is missing required field 'binding'."
    }
    $binding = ConvertTo-CommMonitorSchemaObject `
        -Value $anchorData.binding `
        -Subject 'Ownership anchor binding'
    if (-not $binding.Contains('activeSlot')) {
        throw "Ownership anchor binding is missing required field 'activeSlot'."
    }
    $activeSlot = Copy-CommMonitorSchemaString `
        -Value $binding.activeSlot `
        -Subject 'Ownership anchor binding activeSlot'
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $activeSlot `
            -Allowed @('A', 'B'))) {
        throw 'Ownership anchor binding activeSlot must be exactly A or B.'
    }
    $activeRecord = $validatedManifest.Slots[$activeSlot]
    if ($null -eq $activeRecord) {
        throw "Ownership anchor selects empty manifest slot $activeSlot."
    }
    return Assert-CommMonitorOwnershipState `
        -Envelope $activeRecord.Envelope `
        -Anchor $Anchor `
        -Key $Key `
        -ExpectedManifestPath $ExpectedManifestPath `
        -ExpectedAppId $ExpectedAppId `
        -ExpectedInstallId $ExpectedInstallId
}

function Throw-CommMonitorOwnershipTransitionSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Ownership transition semantics: $Message"
}

function Test-CommMonitorCanonicalSchemaValueEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][object] $Left,
        [AllowNull()][object] $Right
    )

    return [string]::Equals(
        (ConvertTo-CommMonitorCanonicalJson -InputObject $Left),
        (ConvertTo-CommMonitorCanonicalJson -InputObject $Right),
        [StringComparison]::Ordinal)
}

function Assert-CommMonitorSameOperationAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $CurrentOperation,
        [Parameter(Mandatory)][Collections.IDictionary] $NextOperation
    )

    foreach ($field in @(
            'operationId', 'nonce', 'resultRelativePath', 'helperSha256',
            'pendingObjectIds', 'requestedUtc')) {
        if (-not (Test-CommMonitorCanonicalSchemaValueEqual `
                -Left $CurrentOperation[$field] `
                -Right $NextOperation[$field])) {
            Throw-CommMonitorOwnershipTransitionSemanticError `
                -Message "Operation attempt field '$field' is immutable."
        }
    }
}

function Assert-CommMonitorSamePreparedSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $CurrentOperation,
        [Parameter(Mandatory)][Collections.IDictionary] $NextOperation
    )

    foreach ($field in @('preparedTargets', 'preparedUtc')) {
        if (-not (Test-CommMonitorCanonicalSchemaValueEqual `
                -Left $CurrentOperation[$field] `
                -Right $NextOperation[$field])) {
            Throw-CommMonitorOwnershipTransitionSemanticError `
                -Message "Prepared snapshot field '$field' is immutable."
        }
    }
}

function Assert-CommMonitorFreshOperationAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $CurrentOperation,
        [Parameter(Mandatory)][Collections.IDictionary] $NextOperation
    )

    foreach ($field in @(
            'operationId', 'nonce', 'resultRelativePath', 'requestedUtc')) {
        if (Test-CommMonitorCanonicalSchemaValueEqual `
                -Left $CurrentOperation[$field] `
                -Right $NextOperation[$field]) {
            Throw-CommMonitorOwnershipTransitionSemanticError `
                -Message "Retry field '$field' must identify a fresh attempt."
        }
    }
}

function Assert-CommMonitorOwnershipTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $CurrentPayload,
        [Parameter(Mandatory)][object] $NextPayload,
        [Parameter(Mandatory)][AllowNull()][object] $Actor
    )

    try {
        $actorValue = Copy-CommMonitorSchemaString `
            -Value $Actor `
            -Subject 'Ownership transition actor'
    }
    catch {
        Throw-CommMonitorOwnershipTransitionSemanticError `
            -Message $_.Exception.Message
    }
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $actorValue `
            -Allowed @('Task5', 'Helper'))) {
        Throw-CommMonitorOwnershipTransitionSemanticError `
            -Message "Actor '$actorValue' is not supported."
    }

    $current = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $CurrentPayload
    $next = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $NextPayload
    $from = [string]$current['state']
    $to = [string]$next['state']
    $edge = "$from->$to"
    $requiredActor = switch -CaseSensitive ($edge) {
        'Committed->UninstallRequested' { 'Task5' }
        'UninstallRequested->UninstallPrepared' { 'Helper' }
        'UninstallRequested->Abandoned' { 'Task5' }
        'UninstallPrepared->Abandoned' { 'Task5' }
        'UninstallPrepared->PendingReboot' { 'Helper' }
        'Abandoned->UninstallRequested' { 'Task5' }
        'PendingReboot->UninstallRequested' { 'Task5' }
        'UninstallPrepared->FinalizingAbsent' { 'Task5' }
        default {
            Throw-CommMonitorOwnershipTransitionSemanticError `
                -Message "State edge '$edge' is not legal."
        }
    }
    if (-not [string]::Equals(
            $actorValue,
            $requiredActor,
            [StringComparison]::Ordinal)) {
        Throw-CommMonitorOwnershipTransitionSemanticError `
            -Message "State edge '$edge' requires actor '$requiredActor'."
    }

    foreach ($field in @(
            'appId', 'installId', 'productVersion', 'createdUtc', 'platform',
            'roots', 'authorizedUser', 'ownedObjects', 'upperFiltersRollback',
            'keyMetadata')) {
        if (-not (Test-CommMonitorCanonicalSchemaValueEqual `
                -Left $current[$field] `
                -Right $next[$field])) {
            Throw-CommMonitorOwnershipTransitionSemanticError `
                -Message "Installation snapshot field '$field' is immutable."
        }
    }

    $currentContinuation = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $current['continuationState']
    $nextContinuation = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $next['continuationState']
    if ($edge -in @(
            'UninstallRequested->UninstallPrepared',
            'UninstallRequested->Abandoned',
            'UninstallPrepared->Abandoned',
            'Abandoned->UninstallRequested') -and
        -not (Test-CommMonitorCanonicalSchemaValueEqual `
            -Left $currentContinuation `
            -Right $nextContinuation)) {
        Throw-CommMonitorOwnershipTransitionSemanticError `
            -Message 'The continuation binding is immutable on this state edge.'
    }
    if ($edge -eq 'UninstallPrepared->PendingReboot' -and
        -not [string]::Equals(
            [string]$nextContinuation['status'],
            'Active',
            [StringComparison]::Ordinal)) {
        Throw-CommMonitorOwnershipTransitionSemanticError `
            -Message 'PendingReboot requires an Active continuation binding.'
    }
    if ($edge -eq 'PendingReboot->UninstallRequested' -and
        (-not [string]::Equals(
                [string]$currentContinuation['status'],
                'Active',
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$nextContinuation['status'],
                'Active',
                [StringComparison]::Ordinal))) {
        Throw-CommMonitorOwnershipTransitionSemanticError `
            -Message 'A PendingReboot retry must retain its Active continuation binding.'
    }

    $currentOperation = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $current['operationState']
    $nextOperation = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $next['operationState']
    if ($edge -in @(
            'UninstallRequested->UninstallPrepared',
            'UninstallRequested->Abandoned',
            'UninstallPrepared->Abandoned',
            'UninstallPrepared->PendingReboot')) {
        Assert-CommMonitorSameOperationAttempt `
            -CurrentOperation $currentOperation `
            -NextOperation $nextOperation
    }
    if ($edge -in @(
            'UninstallPrepared->Abandoned',
            'UninstallPrepared->PendingReboot')) {
        Assert-CommMonitorSamePreparedSnapshot `
            -CurrentOperation $currentOperation `
            -NextOperation $nextOperation
    }
    if ($edge -eq 'UninstallRequested->Abandoned') {
        if (@($nextOperation['preparedTargets']).Count -ne 0 -or
            $null -ne $nextOperation['preparedUtc']) {
            Throw-CommMonitorOwnershipTransitionSemanticError `
                -Message 'An unprepared attempt cannot gain prepared evidence while being abandoned.'
        }
    }
    if ($edge -in @(
            'Abandoned->UninstallRequested',
            'PendingReboot->UninstallRequested')) {
        Assert-CommMonitorFreshOperationAttempt `
            -CurrentOperation $currentOperation `
            -NextOperation $nextOperation
    }
    if ($edge -eq 'UninstallPrepared->FinalizingAbsent' -and
        -not [string]::Equals(
            [string]$currentOperation['operationId'],
            [string]$nextOperation['operationId'],
            [StringComparison]::Ordinal)) {
        Throw-CommMonitorOwnershipTransitionSemanticError `
            -Message 'Terminal authority must bind the prepared operationId.'
    }
}

function Update-CommMonitorOwnershipManifestCas {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $CurrentManifest,
        [Parameter(Mandatory)][object] $CurrentAnchor,
        [Parameter(Mandatory)][AllowNull()][object] $ExpectedRevision,
        [Parameter(Mandatory)][AllowNull()][object] $ExpectedPayloadSha256,
        [Parameter(Mandatory)][object] $NextPayload,
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][string] $KeyId,
        [Parameter(Mandatory)][AllowNull()][object] $Actor,
        [AllowNull()][object] $TerminalCleanupEnvelope,
        [scriptblock] $TerminalUnprotectScript,
        [AllowNull()][object] $TerminalPreparationCapability
    )

    $expectedRevisionValue = Copy-CommMonitorSchemaInt32 `
        -Value $ExpectedRevision `
        -Subject 'ExpectedRevision'
    $expectedPayloadSha256Value = Copy-CommMonitorSchemaString `
        -Value $ExpectedPayloadSha256 `
        -Subject 'ExpectedPayloadSha256'
    Assert-CommMonitorHash `
        -Value $expectedPayloadSha256Value `
        -Length 64 `
        -Name expectedPayloadSha256

    $anchorData = ConvertTo-CommMonitorSchemaObject `
        -Value $CurrentAnchor `
        -Subject 'Ownership anchor'
    $binding = ConvertTo-CommMonitorSchemaObject `
        -Value $anchorData.binding `
        -Subject 'Ownership anchor binding'
    $activeSlot = Copy-CommMonitorSchemaString `
        -Value $binding.activeSlot `
        -Subject 'Ownership anchor binding activeSlot'
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $activeSlot `
            -Allowed @('A', 'B'))) {
        throw 'Ownership anchor binding activeSlot must be exactly A or B.'
    }
    $validatedManifest = Assert-CommMonitorOwnershipManifest `
        -Manifest $CurrentManifest `
        -Key $Key
    $activeRecord = $validatedManifest.Slots[$activeSlot]
    if ($null -eq $activeRecord) {
        throw "Ownership anchor selects empty manifest slot $activeSlot."
    }
    $currentPayload = Assert-CommMonitorOwnershipManifestState `
        -Manifest $CurrentManifest `
        -Anchor $CurrentAnchor `
        -Key $Key `
        -ExpectedManifestPath $ManifestPath `
        -ExpectedAppId ([string]$activeRecord.Payload.appId) `
        -ExpectedInstallId ([string]$activeRecord.Payload.installId)
    $currentIntegrity = $activeRecord.Integrity
    if ([int]$currentPayload.revision -ne $expectedRevisionValue -or
        -not [string]::Equals(
            [string]$currentIntegrity.payloadSha256,
            $expectedPayloadSha256Value,
            [StringComparison]::Ordinal)) {
        throw 'Ownership manifest CAS expected revision or payload hash is stale.'
    }

    $next = ConvertTo-CommMonitorCanonicalOwnershipPayload `
        -Payload $NextPayload
    Assert-CommMonitorOwnershipTransition `
        -CurrentPayload $currentPayload `
        -NextPayload $next `
        -Actor $Actor
    $next.revision = $expectedRevisionValue + 1
    $next.previousPayloadSha256 = $expectedPayloadSha256Value
    $isTerminalEdge =
        [string]::Equals(
            [string]$currentPayload.state,
            'UninstallPrepared',
            [StringComparison]::Ordinal) -and
        [string]::Equals(
            [string]$next.state,
            'FinalizingAbsent',
            [StringComparison]::Ordinal)
    $hasTerminalEnvelope =
        $PSBoundParameters.ContainsKey('TerminalCleanupEnvelope') -and
        $null -ne $TerminalCleanupEnvelope
    $hasTerminalPreparationCapability =
        $PSBoundParameters.ContainsKey(
            'TerminalPreparationCapability') -and
        $null -ne $TerminalPreparationCapability
    $terminalPreparationRecord = $null
    if ($isTerminalEdge) {
        if (-not $hasTerminalEnvelope -or
            -not $hasTerminalPreparationCapability) {
            Throw-CommMonitorOwnershipTransitionSemanticError `
                -Message (
                    'FinalizingAbsent requires matching Prepared terminal cleanup authority ' +
                    'and an unused preparation capability.')
        }
        try {
            $terminal = Assert-CommMonitorTerminalCleanupEnvelope `
                -Envelope $TerminalCleanupEnvelope `
                -UnprotectScript $TerminalUnprotectScript
            if (-not [string]::Equals(
                    [string]$terminal.status,
                    'Prepared',
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$terminal.installId,
                    [string]$currentPayload.installId,
                    [StringComparison]::Ordinal)) {
                throw 'Terminal cleanup authority is not Prepared for this installation.'
            }
            $predecessorBinding =
                ConvertTo-CommMonitorOrderedDictionary `
                    -InputObject $terminal.predecessor
            $successorBinding =
                ConvertTo-CommMonitorOrderedDictionary `
                    -InputObject $terminal.successor
            $currentData = ConvertTo-CommMonitorOrderedDictionary `
                -InputObject $currentPayload
            $nextData = ConvertTo-CommMonitorOrderedDictionary `
                -InputObject $next
            $nextHash =
                Get-CommMonitorCanonicalOwnershipPayloadSha256 `
                    -Payload $next
            if (-not (Test-CommMonitorTerminalManifestBindingMatches `
                    -Binding $predecessorBinding `
                    -Payload $currentData `
                    -PayloadSha256 $expectedPayloadSha256Value) -or
                -not (Test-CommMonitorTerminalManifestBindingMatches `
                    -Binding $successorBinding `
                    -Payload $nextData `
                    -PayloadSha256 $nextHash `
                    -Successor)) {
                throw 'Prepared terminal cleanup authority does not bind this CAS pair.'
            }
            $currentOperation = ConvertTo-CommMonitorOrderedDictionary `
                -InputObject $currentPayload.operationState
            $terminalPreparationRecord =
                Assert-CommMonitorTerminalPreparationCapabilityBinding `
                    -Capability $TerminalPreparationCapability `
                    -ExpectedInstallId (
                        [string]$currentPayload.installId) `
                    -ExpectedOperationId (
                        [string]$currentOperation.operationId) `
                    -ExpectedManifestPayloadSha256 (
                        $expectedPayloadSha256Value) `
                    -AuthorityIdentity (
                        [string]$terminal.authorityIdentity)
        }
        catch {
            if ($_.Exception.Message.StartsWith(
                    'Ownership transition semantics:',
                    [StringComparison]::Ordinal)) {
                throw
            }
            Throw-CommMonitorOwnershipTransitionSemanticError `
                -Message $_.Exception.Message
        }
    }
    elseif ($hasTerminalEnvelope -or
        $hasTerminalPreparationCapability -or
        $PSBoundParameters.ContainsKey('TerminalUnprotectScript')) {
        Throw-CommMonitorOwnershipTransitionSemanticError `
            -Message 'Terminal cleanup authority is valid only for the terminal state edge.'
    }
    $newEnvelope = New-CommMonitorOwnershipEnvelope `
        -Payload $next `
        -Key $Key `
        -KeyId $KeyId
    $inactiveSlot = if ($activeSlot -eq 'A') { 'B' } else { 'A' }
    $newManifest = Copy-CommMonitorManifestSchemaValue `
        -Value $CurrentManifest
    $newSlots = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $newManifest.slots
    $newSlots[$inactiveSlot] = $newEnvelope
    $newManifest.slots = $newSlots
    $newAnchor = New-CommMonitorOwnershipAnchor `
        -Payload $next `
        -PayloadSha256 $newEnvelope.integrity.payloadSha256 `
        -ManifestPath $ManifestPath `
        -Key $Key `
        -KeyId $KeyId `
        -ActiveSlot $inactiveSlot
    [void](Assert-CommMonitorOwnershipManifestState `
        -Manifest $newManifest `
        -Anchor $newAnchor `
        -Key $Key `
        -ExpectedManifestPath $ManifestPath `
        -ExpectedAppId ([string]$currentPayload.appId) `
        -ExpectedInstallId ([string]$currentPayload.installId))
    if ($null -ne $terminalPreparationRecord) {
        $terminalPreparationRecord.Consumed = $true
    }
    return [pscustomobject]@{
        Manifest = $newManifest
        Anchor = $newAnchor
        ActiveEnvelope = $newEnvelope
        ActiveSlot = $inactiveSlot
    }
}

function Throw-CommMonitorContinuationSchemaError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Continuation schema: $Message"
}

function Throw-CommMonitorContinuationSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Continuation semantics: $Message"
}

function Throw-CommMonitorContinuationRecoverySemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Continuation recovery semantics: $Message"
}

function ConvertTo-CommMonitorCanonicalContinuationFileBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Value,
        [Parameter(Mandatory)][string] $Subject
    )

    $binding = ConvertTo-CommMonitorSchemaObject `
        -Value $Value `
        -Subject $Subject
    Assert-CommMonitorExactFields `
        -Dictionary $binding `
        -Allowed @('relativePath', 'sha256') `
        -Required @('relativePath', 'sha256') `
        -Subject $Subject
    $relativePath = Copy-CommMonitorSchemaString `
        -Value $binding.relativePath `
        -Subject "$Subject relativePath"
    Assert-CommMonitorRelativeOrdinaryPath -Path $relativePath
    $sha256 = Copy-CommMonitorSchemaString `
        -Value $binding.sha256 `
        -Subject "$Subject sha256"
    if (-not [regex]::IsMatch(
            $sha256,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw "$Subject sha256 must be a lowercase SHA-256 value."
    }
    return [ordered]@{
        relativePath = $relativePath
        sha256 = $sha256
    }
}

function ConvertTo-CommMonitorCanonicalContinuationManifestBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Value,
        [Parameter(Mandatory)][string] $Subject,
        [switch] $Successor
    )

    $binding = ConvertTo-CommMonitorSchemaObject `
        -Value $Value `
        -Subject $Subject
    $fields = if ($Successor) {
        @(
            'revision', 'previousPayloadSha256', 'payloadSha256',
            'state', 'operationState')
    }
    else {
        @('revision', 'payloadSha256', 'state')
    }
    Assert-CommMonitorExactFields `
        -Dictionary $binding `
        -Allowed $fields `
        -Required $fields `
        -Subject $Subject
    $revision = Copy-CommMonitorSchemaInt32 `
        -Value $binding.revision `
        -Subject "$Subject revision"
    if ($revision -lt 1) {
        throw "$Subject revision must be positive."
    }
    $payloadSha256 = Copy-CommMonitorSchemaString `
        -Value $binding.payloadSha256 `
        -Subject "$Subject payloadSha256"
    if (-not [regex]::IsMatch(
            $payloadSha256,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw "$Subject payloadSha256 must be lowercase SHA-256."
    }
    $state = Copy-CommMonitorSchemaString `
        -Value $binding.state `
        -Subject "$Subject state"
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $state `
            -Allowed @(
                'Committed', 'UninstallRequested', 'UninstallPrepared',
                'PendingReboot', 'Abandoned', 'FinalizingAbsent'))) {
        throw "$Subject state is unsupported."
    }
    if (-not $Successor) {
        return [ordered]@{
            revision = $revision
            payloadSha256 = $payloadSha256
            state = $state
        }
    }
    $previousPayloadSha256 = Copy-CommMonitorSchemaString `
        -Value $binding.previousPayloadSha256 `
        -Subject "$Subject previousPayloadSha256"
    if (-not [regex]::IsMatch(
            $previousPayloadSha256,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw "$Subject previousPayloadSha256 must be lowercase SHA-256."
    }
    return [ordered]@{
        revision = $revision
        previousPayloadSha256 = $previousPayloadSha256
        payloadSha256 = $payloadSha256
        state = $state
        operationState = ConvertTo-CommMonitorCanonicalOperationState `
            -State $state `
            -OperationState $binding.operationState
    }
}

function ConvertTo-CommMonitorCanonicalContinuationPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Payload)

    try {
        $data = ConvertTo-CommMonitorSchemaObject `
            -Value $Payload `
            -Subject 'Continuation payload'
        $common = @(
            'installId', 'status', 'createdUtc', 'pendingObjectIds',
            'helper', 'finalizer', 'task')
        $statusValue = if ($data.Contains('status')) {
            Copy-CommMonitorSchemaString `
                -Value $data.status `
                -Subject 'Continuation status'
        }
        else {
            $null
        }
        $specific = switch -CaseSensitive ($statusValue) {
            'Active' { @('current') }
            'Prepared' { @('predecessor', 'successor') }
            default { throw 'Continuation status must be exactly Active or Prepared.' }
        }
        $fields = [string[]]@($common + $specific)
        Assert-CommMonitorExactFields `
            -Dictionary $data `
            -Allowed $fields `
            -Required $fields `
            -Subject 'Continuation payload'

        $installId = Copy-CommMonitorCanonicalOperationGuid `
            -Value $data.installId `
            -Subject 'Continuation installId'
        $createdUtc = Copy-CommMonitorCanonicalOperationUtc `
            -Value $data.createdUtc `
            -Subject 'Continuation createdUtc'
        $pendingObjectIds = Copy-CommMonitorCanonicalStringSet `
            -Value $data.pendingObjectIds `
            -Subject 'Continuation pendingObjectIds'
        $helper = ConvertTo-CommMonitorCanonicalContinuationFileBinding `
            -Value $data.helper `
            -Subject 'Continuation helper'
        $finalizer = ConvertTo-CommMonitorCanonicalContinuationFileBinding `
            -Value $data.finalizer `
            -Subject 'Continuation finalizer'
        if ([string]::Equals(
                [string]$helper.relativePath,
                [string]$finalizer.relativePath,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Continuation helper and finalizer paths must be distinct.'
        }
        $task = ConvertTo-CommMonitorSchemaObject `
            -Value $data.task `
            -Subject 'Continuation task'
        Assert-CommMonitorExactFields `
            -Dictionary $task `
            -Allowed @('name', 'runAsSid', 'trigger') `
            -Required @('name', 'runAsSid', 'trigger') `
            -Subject 'Continuation task'
        $taskName = Copy-CommMonitorSchemaString `
            -Value $task.name `
            -Subject 'Continuation task name'
        $runAsSid = Copy-CommMonitorSchemaString `
            -Value $task.runAsSid `
            -Subject 'Continuation task runAsSid'
        $trigger = Copy-CommMonitorSchemaString `
            -Value $task.trigger `
            -Subject 'Continuation task trigger'
        $expectedTaskName = "\LemonSerialMonitor\Uninstall-$installId"
        if (-not [string]::Equals(
                $taskName,
                $expectedTaskName,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                $runAsSid,
                'S-1-5-18',
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                $trigger,
                'AtStartup',
                [StringComparison]::Ordinal)) {
            throw 'Continuation task identity is not bound to the installation.'
        }
        $copy = [ordered]@{
            installId = $installId
            status = $statusValue
            createdUtc = $createdUtc
            pendingObjectIds = $pendingObjectIds
            helper = $helper
            finalizer = $finalizer
            task = [ordered]@{
                name = $taskName
                runAsSid = $runAsSid
                trigger = $trigger
            }
        }
        if ($statusValue -eq 'Active') {
            $copy['current'] =
                ConvertTo-CommMonitorCanonicalContinuationManifestBinding `
                    -Value $data.current `
                    -Subject 'Continuation current binding'
        }
        else {
            $copy['predecessor'] =
                ConvertTo-CommMonitorCanonicalContinuationManifestBinding `
                    -Value $data.predecessor `
                    -Subject 'Continuation predecessor binding'
            $copy['successor'] =
                ConvertTo-CommMonitorCanonicalContinuationManifestBinding `
                    -Value $data.successor `
                    -Subject 'Continuation successor binding' `
                    -Successor
            if ($copy.successor.revision -ne
                    ($copy.predecessor.revision + 1) -or
                -not [string]::Equals(
                    [string]$copy.successor.previousPayloadSha256,
                    [string]$copy.predecessor.payloadSha256,
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$copy.predecessor.state,
                    'PendingReboot',
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$copy.successor.state,
                    'UninstallRequested',
                    [StringComparison]::Ordinal)) {
                throw 'Prepared continuation does not bind one PendingReboot retry successor.'
            }
        }
        return $copy
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Continuation schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Continuation semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorContinuationSchemaError -Message $_.Exception.Message
    }
}

function Get-CommMonitorCanonicalOwnershipPayloadSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object] $Payload)

    return Get-CommMonitorSha256Hex -Bytes (
        Get-CommMonitorCanonicalJsonBytes -InputObject $Payload)
}

function Assert-CommMonitorContinuationOperationBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Payload,
        [Parameter(Mandatory)][string[]] $PendingObjectIds,
        [Parameter(Mandatory)][string] $HelperSha256
    )

    $payloadData = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $Payload
    $continuation = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $payloadData.continuationState
    if (-not [string]::Equals(
            [string]$continuation.status,
            'Active',
            [StringComparison]::Ordinal)) {
        Throw-CommMonitorContinuationSemanticError `
            -Message 'The bound manifest must retain an Active continuation state.'
    }
    if (-not (Test-CommMonitorOrdinalValue `
            -Value ([string]$payloadData.state) `
            -Allowed @(
                'UninstallRequested', 'UninstallPrepared',
                'PendingReboot', 'Abandoned'))) {
        Throw-CommMonitorContinuationSemanticError `
            -Message 'The bound manifest state cannot carry reboot continuation authority.'
    }
    $operation = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $payloadData.operationState
    if (-not [string]::Equals(
            [string]$operation.helperSha256,
            $HelperSha256,
            [StringComparison]::Ordinal) -or
        -not (Test-CommMonitorCanonicalSchemaValueEqual `
            -Left ([object[]]@($operation.pendingObjectIds)) `
            -Right ([object[]]@($PendingObjectIds)))) {
        Throw-CommMonitorContinuationSemanticError `
            -Message 'Helper hash or pending object IDs are not bound to the operation.'
    }
}

function New-CommMonitorContinuationEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object] $Status,
        [AllowNull()][object] $CurrentPayload,
        [AllowNull()][object] $CurrentPayloadSha256,
        [AllowNull()][object] $PredecessorPayload,
        [AllowNull()][object] $PredecessorPayloadSha256,
        [AllowNull()][object] $SuccessorPayload,
        [Parameter(Mandatory)][AllowNull()][object] $HelperRelativePath,
        [Parameter(Mandatory)][AllowNull()][object] $HelperSha256,
        [Parameter(Mandatory)][AllowNull()][object] $FinalizerRelativePath,
        [Parameter(Mandatory)][AllowNull()][object] $FinalizerSha256,
        [Parameter(Mandatory)][AllowNull()][object] $CreatedUtc,
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][AllowNull()][object] $KeyId
    )

    try {
        $statusValue = Copy-CommMonitorSchemaString `
            -Value $Status `
            -Subject 'Continuation status'
        if (-not (Test-CommMonitorOrdinalValue `
                -Value $statusValue `
                -Allowed @('Active', 'Prepared'))) {
            throw 'Status must be exactly Active or Prepared.'
        }
        if ($Key.Length -ne 32) {
            throw 'Continuation key must contain exactly 256 bits.'
        }
        $keyIdValue = Copy-CommMonitorSchemaString `
            -Value $KeyId `
            -Subject 'Continuation keyId'
        if (-not [regex]::IsMatch(
                $keyIdValue,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not (Test-CommMonitorFixedTimeEquals `
                -LeftHex (Get-CommMonitorSha256Hex -Bytes $Key) `
                -RightHex $keyIdValue)) {
            throw 'Continuation keyId does not match the supplied key.'
        }
        $helperPathValue = Copy-CommMonitorSchemaString `
            -Value $HelperRelativePath `
            -Subject 'Continuation helper relativePath'
        $helperHashValue = Copy-CommMonitorSchemaString `
            -Value $HelperSha256 `
            -Subject 'Continuation helper sha256'
        $finalizerPathValue = Copy-CommMonitorSchemaString `
            -Value $FinalizerRelativePath `
            -Subject 'Continuation finalizer relativePath'
        $finalizerHashValue = Copy-CommMonitorSchemaString `
            -Value $FinalizerSha256 `
            -Subject 'Continuation finalizer sha256'
        $createdUtcValue = if ($CreatedUtc -is [DateTimeOffset]) {
            ([DateTimeOffset]$CreatedUtc).ToUniversalTime().ToString(
                'yyyy-MM-ddTHH:mm:ss.fffffffZ',
                [Globalization.CultureInfo]::InvariantCulture)
        }
        else {
            Copy-CommMonitorCanonicalOperationUtc `
                -Value $CreatedUtc `
                -Subject 'Continuation createdUtc'
        }

        $payload = $null
        if ($statusValue -eq 'Active') {
            if ($null -eq $CurrentPayload -or
                $null -eq $CurrentPayloadSha256 -or
                $null -ne $PredecessorPayload -or
                $null -ne $PredecessorPayloadSha256 -or
                $null -ne $SuccessorPayload) {
                throw 'Active continuation requires only current manifest authority.'
            }
            $current = ConvertTo-CommMonitorCanonicalOwnershipPayload `
                -Payload $CurrentPayload
            $currentHash = Copy-CommMonitorSchemaString `
                -Value $CurrentPayloadSha256 `
                -Subject 'Continuation current payloadSha256'
            $actualCurrentHash =
                Get-CommMonitorCanonicalOwnershipPayloadSha256 -Payload $current
            if (-not [regex]::IsMatch(
                    $currentHash,
                    '^[0-9a-f]{64}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
                -not (Test-CommMonitorFixedTimeEquals `
                    -LeftHex $actualCurrentHash `
                    -RightHex $currentHash)) {
                throw 'Active continuation current payload hash is invalid.'
            }
            $operation = ConvertTo-CommMonitorOrderedDictionary `
                -InputObject $current.operationState
            $pendingIds = [string[]]@($operation.pendingObjectIds)
            Assert-CommMonitorContinuationOperationBinding `
                -Payload $current `
                -PendingObjectIds $pendingIds `
                -HelperSha256 $helperHashValue
            $payload = [ordered]@{
                installId = [string]$current.installId
                status = 'Active'
                createdUtc = $createdUtcValue
                pendingObjectIds = $pendingIds
                helper = [ordered]@{
                    relativePath = $helperPathValue
                    sha256 = $helperHashValue
                }
                finalizer = [ordered]@{
                    relativePath = $finalizerPathValue
                    sha256 = $finalizerHashValue
                }
                task = [ordered]@{
                    name = "\LemonSerialMonitor\Uninstall-$($current.installId)"
                    runAsSid = 'S-1-5-18'
                    trigger = 'AtStartup'
                }
                current = [ordered]@{
                    revision = [int]$current.revision
                    payloadSha256 = $currentHash
                    state = [string]$current.state
                }
            }
        }
        else {
            if ($null -eq $PredecessorPayload -or
                $null -eq $PredecessorPayloadSha256 -or
                $null -eq $SuccessorPayload -or
                $null -ne $CurrentPayload -or
                $null -ne $CurrentPayloadSha256) {
                throw 'Prepared continuation requires only predecessor and successor authority.'
            }
            $predecessor = ConvertTo-CommMonitorCanonicalOwnershipPayload `
                -Payload $PredecessorPayload
            $successor = ConvertTo-CommMonitorCanonicalOwnershipPayload `
                -Payload $SuccessorPayload
            $predecessorHash = Copy-CommMonitorSchemaString `
                -Value $PredecessorPayloadSha256 `
                -Subject 'Continuation predecessor payloadSha256'
            $actualPredecessorHash =
                Get-CommMonitorCanonicalOwnershipPayloadSha256 -Payload $predecessor
            if (-not [regex]::IsMatch(
                    $predecessorHash,
                    '^[0-9a-f]{64}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
                -not (Test-CommMonitorFixedTimeEquals `
                    -LeftHex $actualPredecessorHash `
                    -RightHex $predecessorHash)) {
                throw 'Prepared continuation predecessor payload hash is invalid.'
            }
            Assert-CommMonitorOwnershipTransition `
                -CurrentPayload $predecessor `
                -NextPayload $successor `
                -Actor 'Task5'
            if ([int]$successor.revision -ne ([int]$predecessor.revision + 1) -or
                -not [string]::Equals(
                    [string]$successor.previousPayloadSha256,
                    $predecessorHash,
                    [StringComparison]::Ordinal)) {
                throw 'Prepared successor revision chain is not exact.'
            }
            $successorHash =
                Get-CommMonitorCanonicalOwnershipPayloadSha256 -Payload $successor
            $successorOperation = ConvertTo-CommMonitorOrderedDictionary `
                -InputObject $successor.operationState
            $pendingIds = [string[]]@($successorOperation.pendingObjectIds)
            Assert-CommMonitorContinuationOperationBinding `
                -Payload $successor `
                -PendingObjectIds $pendingIds `
                -HelperSha256 $helperHashValue
            $payload = [ordered]@{
                installId = [string]$successor.installId
                status = 'Prepared'
                createdUtc = $createdUtcValue
                pendingObjectIds = $pendingIds
                helper = [ordered]@{
                    relativePath = $helperPathValue
                    sha256 = $helperHashValue
                }
                finalizer = [ordered]@{
                    relativePath = $finalizerPathValue
                    sha256 = $finalizerHashValue
                }
                task = [ordered]@{
                    name = "\LemonSerialMonitor\Uninstall-$($successor.installId)"
                    runAsSid = 'S-1-5-18'
                    trigger = 'AtStartup'
                }
                predecessor = [ordered]@{
                    revision = [int]$predecessor.revision
                    payloadSha256 = $predecessorHash
                    state = [string]$predecessor.state
                }
                successor = [ordered]@{
                    revision = [int]$successor.revision
                    previousPayloadSha256 =
                        [string]$successor.previousPayloadSha256
                    payloadSha256 = $successorHash
                    state = [string]$successor.state
                    operationState = $successor.operationState
                }
            }
        }
        $validatedPayload =
            ConvertTo-CommMonitorCanonicalContinuationPayload -Payload $payload
        $bytes = Get-CommMonitorCanonicalJsonBytes `
            -InputObject $validatedPayload
        $payloadHash = Get-CommMonitorSha256Hex -Bytes $bytes
        return [ordered]@{
            integrity = [ordered]@{
                algorithm = 'HMAC-SHA256'
                keyId = $keyIdValue
                payloadSha256 = $payloadHash
                tag = Get-CommMonitorHmacSha256Hex `
                    -Key $Key `
                    -Bytes $bytes
            }
            payload = $validatedPayload
            schemaVersion = 1
        }
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Continuation schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Continuation semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorContinuationSemanticError -Message $_.Exception.Message
    }
}

function Assert-CommMonitorContinuationEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Envelope,
        [Parameter(Mandatory)][byte[]] $Key
    )

    try {
        $data = ConvertTo-CommMonitorSchemaObject `
            -Value $Envelope `
            -Subject 'Continuation envelope'
        Assert-CommMonitorExactFields `
            -Dictionary $data `
            -Allowed @('integrity', 'payload', 'schemaVersion') `
            -Required @('integrity', 'payload', 'schemaVersion') `
            -Subject 'Continuation envelope'
        $schemaVersion = Copy-CommMonitorSchemaInt32 `
            -Value $data.schemaVersion `
            -Subject 'Continuation envelope schemaVersion'
        if ($schemaVersion -ne 1) {
            throw 'Continuation envelope schemaVersion must be 1.'
        }
        if ($Key.Length -ne 32) {
            throw 'Continuation key must contain exactly 256 bits.'
        }
        $integrity = ConvertTo-CommMonitorSchemaObject `
            -Value $data.integrity `
            -Subject 'Continuation integrity'
        $integrityFields = @(
            'algorithm', 'keyId', 'payloadSha256', 'tag')
        Assert-CommMonitorExactFields `
            -Dictionary $integrity `
            -Allowed $integrityFields `
            -Required $integrityFields `
            -Subject 'Continuation integrity'
        $algorithm = Copy-CommMonitorSchemaString `
            -Value $integrity.algorithm `
            -Subject 'Continuation integrity algorithm'
        $keyId = Copy-CommMonitorSchemaString `
            -Value $integrity.keyId `
            -Subject 'Continuation integrity keyId'
        $payloadSha256 = Copy-CommMonitorSchemaString `
            -Value $integrity.payloadSha256 `
            -Subject 'Continuation integrity payloadSha256'
        $tag = Copy-CommMonitorSchemaString `
            -Value $integrity.tag `
            -Subject 'Continuation integrity tag'
        if (-not [string]::Equals(
                $algorithm,
                'HMAC-SHA256',
                [StringComparison]::Ordinal) -or
            -not [regex]::IsMatch(
                $keyId,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [regex]::IsMatch(
                $payloadSha256,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [regex]::IsMatch(
                $tag,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not (Test-CommMonitorFixedTimeEquals `
                -LeftHex (Get-CommMonitorSha256Hex -Bytes $Key) `
                -RightHex $keyId)) {
            throw 'Continuation integrity metadata or key is invalid.'
        }
        $payload = ConvertTo-CommMonitorCanonicalContinuationPayload `
            -Payload $data.payload
        $bytes = Get-CommMonitorCanonicalJsonBytes -InputObject $payload
        $actualHash = Get-CommMonitorSha256Hex -Bytes $bytes
        $actualTag = Get-CommMonitorHmacSha256Hex -Key $Key -Bytes $bytes
        if (-not (Test-CommMonitorFixedTimeEquals `
                -LeftHex $actualHash `
                -RightHex $payloadSha256) -or
            -not (Test-CommMonitorFixedTimeEquals `
                -LeftHex $actualTag `
                -RightHex $tag)) {
            throw 'Continuation envelope authentication failed.'
        }
        return $payload
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Continuation schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Continuation semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorContinuationSchemaError -Message $_.Exception.Message
    }
}

function Test-CommMonitorContinuationManifestBindingMatches {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Binding,
        [Parameter(Mandatory)][Collections.IDictionary] $Payload,
        [Parameter(Mandatory)][string] $PayloadSha256,
        [switch] $Successor
    )

    if ([int]$Binding.revision -ne [int]$Payload.revision -or
        -not [string]::Equals(
            [string]$Binding.payloadSha256,
            $PayloadSha256,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$Binding.state,
            [string]$Payload.state,
            [StringComparison]::Ordinal)) {
        return $false
    }
    if ($Successor -and
        (-not [string]::Equals(
                [string]$Binding.previousPayloadSha256,
                [string]$Payload.previousPayloadSha256,
                [StringComparison]::Ordinal) -or
            -not (Test-CommMonitorCanonicalSchemaValueEqual `
                -Left $Binding.operationState `
                -Right $Payload.operationState))) {
        return $false
    }
    return $true
}

function Resolve-CommMonitorContinuationPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Manifest,
        [Parameter(Mandatory)][object] $Anchor,
        [Parameter(Mandatory)][object] $Continuation,
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][string] $ExpectedManifestPath,
        [Parameter(Mandatory)][string] $ExpectedAppId,
        [Parameter(Mandatory)][string] $ExpectedInstallId
    )

    try {
        $currentPayload = Assert-CommMonitorOwnershipManifestState `
            -Manifest $Manifest `
            -Anchor $Anchor `
            -Key $Key `
            -ExpectedManifestPath $ExpectedManifestPath `
            -ExpectedAppId $ExpectedAppId `
            -ExpectedInstallId $ExpectedInstallId
        $current = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $currentPayload
        $anchorData = ConvertTo-CommMonitorSchemaObject `
            -Value $Anchor `
            -Subject 'Ownership anchor'
        $anchorBinding = ConvertTo-CommMonitorSchemaObject `
            -Value $anchorData.binding `
            -Subject 'Ownership anchor binding'
        $currentHash = [string]$anchorBinding.payloadSha256
        $continuationPayload = Assert-CommMonitorContinuationEnvelope `
            -Envelope $Continuation `
            -Key $Key
        $continuationData = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $continuationPayload
        if (-not [string]::Equals(
                [string]$continuationData.installId,
                [string]$current.installId,
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorContinuationRecoverySemanticError `
                -Message 'Continuation belongs to another installation.'
        }
        if ([string]::Equals(
                [string]$continuationData.status,
                'Active',
                [StringComparison]::Ordinal)) {
            $binding = ConvertTo-CommMonitorOrderedDictionary `
                -InputObject $continuationData.current
            if (-not (Test-CommMonitorContinuationManifestBindingMatches `
                    -Binding $binding `
                    -Payload $current `
                    -PayloadSha256 $currentHash)) {
                Throw-CommMonitorContinuationRecoverySemanticError `
                    -Message 'Active continuation does not bind the current manifest.'
            }
            Assert-CommMonitorContinuationOperationBinding `
                -Payload $current `
                -PendingObjectIds ([string[]]@(
                    $continuationData.pendingObjectIds)) `
                -HelperSha256 ([string]$continuationData.helper.sha256)
            return [pscustomobject]@{
                Disposition = 'ActiveCurrent'
                HelperAdmission = [string]::Equals(
                    [string]$current.state,
                    'UninstallRequested',
                    [StringComparison]::Ordinal)
                CurrentPayload = $currentPayload
                ContinuationPayload = $continuationPayload
            }
        }

        $predecessor = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $continuationData.predecessor
        $successor = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $continuationData.successor
        $matchesPredecessor =
            Test-CommMonitorContinuationManifestBindingMatches `
                -Binding $predecessor `
                -Payload $current `
                -PayloadSha256 $currentHash
        $matchesSuccessor =
            Test-CommMonitorContinuationManifestBindingMatches `
                -Binding $successor `
                -Payload $current `
                -PayloadSha256 $currentHash `
                -Successor
        if ($matchesPredecessor -eq $matchesSuccessor) {
            Throw-CommMonitorContinuationRecoverySemanticError `
                -Message 'Prepared continuation matches neither one exact recovery side nor only one side.'
        }
        if ($matchesSuccessor) {
            Assert-CommMonitorContinuationOperationBinding `
                -Payload $current `
                -PendingObjectIds ([string[]]@(
                    $continuationData.pendingObjectIds)) `
                -HelperSha256 ([string]$continuationData.helper.sha256)
        }
        return [pscustomobject]@{
            Disposition = if ($matchesPredecessor) {
                'RecoverPredecessor'
            }
            else {
                'PromoteSuccessor'
            }
            HelperAdmission = $false
            CurrentPayload = $currentPayload
            ContinuationPayload = $continuationPayload
        }
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Continuation recovery semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorContinuationRecoverySemanticError `
            -Message $_.Exception.Message
    }
}

function ConvertTo-CommMonitorActiveContinuationEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $PreparedEnvelope,
        [Parameter(Mandatory)][object] $Manifest,
        [Parameter(Mandatory)][object] $Anchor,
        [Parameter(Mandatory)][byte[]] $ManifestKey,
        [Parameter(Mandatory)][string] $ExpectedManifestPath,
        [Parameter(Mandatory)][string] $ExpectedAppId,
        [Parameter(Mandatory)][string] $ExpectedInstallId
    )

    try {
        $prepared = Assert-CommMonitorContinuationEnvelope `
            -Envelope $PreparedEnvelope `
            -Key $ManifestKey
        if (-not [string]::Equals(
                [string]$prepared.status,
                'Prepared',
                [StringComparison]::Ordinal)) {
            throw 'Only a Prepared continuation can be promoted.'
        }
        $resolution = Resolve-CommMonitorContinuationPair `
            -Manifest $Manifest `
            -Anchor $Anchor `
            -Continuation $PreparedEnvelope `
            -Key $ManifestKey `
            -ExpectedManifestPath $ExpectedManifestPath `
            -ExpectedAppId $ExpectedAppId `
            -ExpectedInstallId $ExpectedInstallId
        if (-not [string]::Equals(
                [string]$resolution.Disposition,
                'PromoteSuccessor',
                [StringComparison]::Ordinal)) {
            throw 'Prepared continuation is not paired with its exact successor manifest.'
        }
        $current = $resolution.CurrentPayload
        $anchorData = ConvertTo-CommMonitorSchemaObject `
            -Value $Anchor `
            -Subject 'Ownership anchor'
        $anchorBinding = ConvertTo-CommMonitorSchemaObject `
            -Value $anchorData.binding `
            -Subject 'Ownership anchor binding'
        $currentHash = [string]$anchorBinding.payloadSha256
        return New-CommMonitorContinuationEnvelope `
            -Status Active `
            -CurrentPayload $current `
            -CurrentPayloadSha256 $currentHash `
            -HelperRelativePath ([string]$prepared.helper.relativePath) `
            -HelperSha256 ([string]$prepared.helper.sha256) `
            -FinalizerRelativePath ([string]$prepared.finalizer.relativePath) `
            -FinalizerSha256 ([string]$prepared.finalizer.sha256) `
            -CreatedUtc ([string]$prepared.createdUtc) `
            -Key $ManifestKey `
            -KeyId (Get-CommMonitorSha256Hex -Bytes $ManifestKey)
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Continuation schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Continuation semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorContinuationSemanticError -Message $_.Exception.Message
    }
}

function Throw-CommMonitorTerminalCleanupSchemaError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Terminal cleanup schema: $Message"
}

function Throw-CommMonitorTerminalCleanupSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Terminal cleanup semantics: $Message"
}

function Throw-CommMonitorTerminalCleanupRecoverySemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Terminal cleanup recovery semantics: $Message"
}

function ConvertTo-CommMonitorCanonicalTerminalKeyRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Record)

    $key = ConvertTo-CommMonitorSchemaObject `
        -Value $Record `
        -Subject 'Terminal cleanup key record'
    $fields = @(
        'algorithm', 'keyId', 'protectedBlob', 'protectedBlobSha256',
        'schemaVersion', 'scope', 'state')
    Assert-CommMonitorExactFields `
        -Dictionary $key `
        -Allowed $fields `
        -Required $fields `
        -Subject 'Terminal cleanup key record'
    $algorithm = Copy-CommMonitorSchemaString `
        -Value $key.algorithm `
        -Subject 'Terminal cleanup key algorithm'
    $keyId = Copy-CommMonitorSchemaString `
        -Value $key.keyId `
        -Subject 'Terminal cleanup keyId'
    $protectedBlob = Copy-CommMonitorSchemaString `
        -Value $key.protectedBlob `
        -Subject 'Terminal cleanup protectedBlob'
    $protectedBlobSha256 = Copy-CommMonitorSchemaString `
        -Value $key.protectedBlobSha256 `
        -Subject 'Terminal cleanup protectedBlobSha256'
    $schemaVersion = Copy-CommMonitorSchemaInt32 `
        -Value $key.schemaVersion `
        -Subject 'Terminal cleanup key schemaVersion'
    $scope = Copy-CommMonitorSchemaString `
        -Value $key.scope `
        -Subject 'Terminal cleanup key scope'
    $state = Copy-CommMonitorSchemaString `
        -Value $key.state `
        -Subject 'Terminal cleanup key state'
    if (-not [string]::Equals(
            $algorithm,
            'DPAPI',
            [StringComparison]::Ordinal) -or
        $schemaVersion -ne 1 -or
        -not [string]::Equals(
            $scope,
            'LocalMachine',
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            $state,
            'Active',
            [StringComparison]::Ordinal) -or
        -not [regex]::IsMatch(
            $keyId,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
        -not [regex]::IsMatch(
            $protectedBlobSha256,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw 'Terminal cleanup key metadata is invalid.'
    }
    try {
        $blobBytes = [Convert]::FromBase64String($protectedBlob)
    }
    catch {
        throw 'Terminal cleanup protectedBlob is not canonical base64.'
    }
    if ($blobBytes.Length -eq 0 -or
        -not [string]::Equals(
            [Convert]::ToBase64String($blobBytes),
            $protectedBlob,
            [StringComparison]::Ordinal) -or
        -not (Test-CommMonitorFixedTimeEquals `
            -LeftHex (Get-CommMonitorSha256Hex -Bytes $blobBytes) `
            -RightHex $protectedBlobSha256)) {
        throw 'Terminal cleanup protectedBlob digest or encoding is invalid.'
    }
    return [ordered]@{
        algorithm = $algorithm
        keyId = $keyId
        protectedBlob = $protectedBlob
        protectedBlobSha256 = $protectedBlobSha256
        schemaVersion = $schemaVersion
        scope = $scope
        state = $state
    }
}

function ConvertTo-CommMonitorCanonicalTerminalDeletePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $DeletePlan)

    Assert-CommMonitorRawSchemaArray `
        -Value $DeletePlan `
        -Subject 'Terminal cleanup deletePlan'
    if (@($DeletePlan).Count -lt 3 -or @($DeletePlan).Count -gt 4) {
        throw 'Terminal cleanup deletePlan requires three mandatory records and one optional continuation.'
    }
    $expected = [ordered]@{
        continuation = [pscustomobject]@{
            Root = 'InstallerRoot'
            RelativePath = 'state\continuation.v1.json'
            Optional = $true
        }
        anchor = [pscustomobject]@{
            Root = 'CoreRoot'
            RelativePath = 'metadata\install-anchor.v3.json'
            Optional = $false
        }
        manifest = [pscustomobject]@{
            Root = 'InstallerRoot'
            RelativePath = 'state\ownership-manifest.v3.json'
            Optional = $false
        }
        'manifest-key' = [pscustomobject]@{
            Root = 'InstallerRoot'
            RelativePath = 'state\ownership-manifest-key.v1.json'
            Optional = $false
        }
    }
    $seenIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $seenPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $copy = [Collections.Generic.List[object]]::new()
    $lastOrder = 0
    foreach ($recordInput in $DeletePlan) {
        $record = ConvertTo-CommMonitorSchemaObject `
            -Value $recordInput `
            -Subject 'Terminal cleanup delete record'
        $fields = @(
            'objectId', 'root', 'relativePath', 'kind',
            'volumeSerialNumber', 'fileId', 'size', 'sha256', 'deleteOrder')
        Assert-CommMonitorExactFields `
            -Dictionary $record `
            -Allowed $fields `
            -Required $fields `
            -Subject 'Terminal cleanup delete record'
        $objectId = Copy-CommMonitorSchemaString `
            -Value $record.objectId `
            -Subject 'Terminal cleanup delete objectId'
        if (-not $expected.Contains($objectId) -or
            -not $seenIds.Add($objectId)) {
            throw "Terminal cleanup delete objectId '$objectId' is unsupported or duplicate."
        }
        $definition = $expected[$objectId]
        $root = Copy-CommMonitorSchemaString `
            -Value $record.root `
            -Subject 'Terminal cleanup delete root'
        $relativePath = Copy-CommMonitorSchemaString `
            -Value $record.relativePath `
            -Subject 'Terminal cleanup delete relativePath'
        Assert-CommMonitorRelativeOrdinaryPath -Path $relativePath
        if (-not [string]::Equals(
                $root,
                [string]$definition.Root,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                $relativePath,
                [string]$definition.RelativePath,
                [StringComparison]::Ordinal) -or
            -not $seenPaths.Add("$root\$relativePath")) {
            throw "Terminal cleanup delete object '$objectId' has an invalid root or path."
        }
        $kind = Copy-CommMonitorSchemaString `
            -Value $record.kind `
            -Subject 'Terminal cleanup delete kind'
        $volumeSerialNumber = Copy-CommMonitorSchemaString `
            -Value $record.volumeSerialNumber `
            -Subject 'Terminal cleanup delete volumeSerialNumber'
        $fileId = Copy-CommMonitorSchemaString `
            -Value $record.fileId `
            -Subject 'Terminal cleanup delete fileId'
        $size = Copy-CommMonitorSchemaInt64 `
            -Value $record.size `
            -Subject 'Terminal cleanup delete size'
        $sha256 = Copy-CommMonitorSchemaString `
            -Value $record.sha256 `
            -Subject 'Terminal cleanup delete sha256'
        $deleteOrder = Copy-CommMonitorSchemaInt32 `
            -Value $record.deleteOrder `
            -Subject 'Terminal cleanup deleteOrder'
        if (-not [string]::Equals(
                $kind,
                'File',
                [StringComparison]::Ordinal) -or
            -not [regex]::IsMatch(
                $volumeSerialNumber,
                '^[0-9a-f]{16}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [regex]::IsMatch(
                $fileId,
                '^[0-9a-f]{32}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [regex]::IsMatch(
                $sha256,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            $size -lt 0 -or
            $deleteOrder -le $lastOrder) {
            throw "Terminal cleanup delete object '$objectId' has invalid identity or order."
        }
        $lastOrder = $deleteOrder
        $copy.Add([ordered]@{
                objectId = $objectId
                root = $root
                relativePath = $relativePath
                kind = $kind
                volumeSerialNumber = $volumeSerialNumber
                fileId = $fileId
                size = $size
                sha256 = $sha256
                deleteOrder = $deleteOrder
            })
    }
    foreach ($requiredId in @('anchor', 'manifest', 'manifest-key')) {
        if (-not $seenIds.Contains($requiredId)) {
            throw "Terminal cleanup deletePlan is missing '$requiredId'."
        }
    }
    $expectedSequence = if ($seenIds.Contains('continuation')) {
        'continuation,anchor,manifest,manifest-key'
    }
    else {
        'anchor,manifest,manifest-key'
    }
    $actualSequence = [string]::Join(
        ',',
        [string[]]@($copy | ForEach-Object { [string]$_.objectId }))
    if (-not [string]::Equals(
            $actualSequence,
            $expectedSequence,
            [StringComparison]::Ordinal)) {
        throw 'Terminal cleanup deletePlan order is not canonical.'
    }
    Write-Output -NoEnumerate ([object[]]$copy.ToArray())
}

function ConvertTo-CommMonitorCanonicalTerminalAuthorityDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $CleanupId,
        [Parameter(Mandatory)][object] $Nonce,
        [Parameter(Mandatory)][object] $TerminalKeyRecord,
        [Parameter(Mandatory)][object] $FinalizerRelativePath,
        [Parameter(Mandatory)][object] $FinalizerSha256,
        [Parameter(Mandatory)][object] $DeletePlan
    )

    $cleanupIdValue = Copy-CommMonitorCanonicalOperationGuid `
        -Value $CleanupId `
        -Subject 'Terminal cleanup cleanupId'
    $nonceValue = Copy-CommMonitorSchemaString `
        -Value $Nonce `
        -Subject 'Terminal cleanup nonce'
    if (-not [regex]::IsMatch(
            $nonceValue,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw 'Terminal cleanup nonce must contain 256 lowercase bits.'
    }
    $key = ConvertTo-CommMonitorCanonicalTerminalKeyRecord `
        -Record $TerminalKeyRecord
    $finalizer =
        ConvertTo-CommMonitorCanonicalContinuationFileBinding `
            -Value ([ordered]@{
                relativePath = $FinalizerRelativePath
                sha256 = $FinalizerSha256
            }) `
            -Subject 'Terminal cleanup finalizer'
    $plan = ConvertTo-CommMonitorCanonicalTerminalDeletePlan `
        -DeletePlan $DeletePlan
    return [ordered]@{
        cleanupId = $cleanupIdValue
        nonce = $nonceValue
        key = $key
        finalizer = $finalizer
        deletePlan = $plan
    }
}

function Get-CommMonitorTerminalCleanupAuthorityIdentity {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object] $CleanupId,
        [Parameter(Mandatory)][object] $Nonce,
        [Parameter(Mandatory)][object] $TerminalKeyRecord,
        [Parameter(Mandatory)][object] $FinalizerRelativePath,
        [Parameter(Mandatory)][object] $FinalizerSha256,
        [Parameter(Mandatory)][object] $DeletePlan
    )

    try {
        $descriptor =
            ConvertTo-CommMonitorCanonicalTerminalAuthorityDescriptor `
                -CleanupId $CleanupId `
                -Nonce $Nonce `
                -TerminalKeyRecord $TerminalKeyRecord `
                -FinalizerRelativePath $FinalizerRelativePath `
                -FinalizerSha256 $FinalizerSha256 `
                -DeletePlan $DeletePlan
        return Get-CommMonitorSha256Hex -Bytes (
            Get-CommMonitorCanonicalJsonBytes -InputObject $descriptor)
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Terminal cleanup schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Terminal cleanup semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorTerminalCleanupSchemaError `
            -Message $_.Exception.Message
    }
}

function ConvertTo-CommMonitorCanonicalTerminalManifestBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Value,
        [Parameter(Mandatory)][string] $Subject,
        [switch] $Successor
    )

    $binding = ConvertTo-CommMonitorSchemaObject `
        -Value $Value `
        -Subject $Subject
    $fields = if ($Successor) {
        @(
            'revision', 'previousPayloadSha256', 'payloadSha256',
            'state', 'operationState')
    }
    else {
        @('revision', 'payloadSha256', 'state', 'operationState')
    }
    Assert-CommMonitorExactFields `
        -Dictionary $binding `
        -Allowed $fields `
        -Required $fields `
        -Subject $Subject
    $revision = Copy-CommMonitorSchemaInt32 `
        -Value $binding.revision `
        -Subject "$Subject revision"
    $payloadSha256 = Copy-CommMonitorSchemaString `
        -Value $binding.payloadSha256 `
        -Subject "$Subject payloadSha256"
    $state = Copy-CommMonitorSchemaString `
        -Value $binding.state `
        -Subject "$Subject state"
    if ($revision -lt 1 -or
        -not [regex]::IsMatch(
            $payloadSha256,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw "$Subject revision or payload hash is invalid."
    }
    $operation = ConvertTo-CommMonitorCanonicalOperationState `
        -State $state `
        -OperationState $binding.operationState
    if (-not $Successor) {
        return [ordered]@{
            revision = $revision
            payloadSha256 = $payloadSha256
            state = $state
            operationState = $operation
        }
    }
    $previousPayloadSha256 = Copy-CommMonitorSchemaString `
        -Value $binding.previousPayloadSha256 `
        -Subject "$Subject previousPayloadSha256"
    if (-not [regex]::IsMatch(
            $previousPayloadSha256,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw "$Subject previous payload hash is invalid."
    }
    return [ordered]@{
        revision = $revision
        previousPayloadSha256 = $previousPayloadSha256
        payloadSha256 = $payloadSha256
        state = $state
        operationState = $operation
    }
}

function ConvertTo-CommMonitorCanonicalTerminalCleanupPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Payload)

    try {
        $data = ConvertTo-CommMonitorSchemaObject `
            -Value $Payload `
            -Subject 'Terminal cleanup payload'
        $fields = @(
            'installId', 'status', 'cleanupId', 'nonce', 'createdUtc', 'key',
            'authorityIdentity', 'finalizer', 'deletePlan',
            'predecessor', 'successor')
        Assert-CommMonitorExactFields `
            -Dictionary $data `
            -Allowed $fields `
            -Required $fields `
            -Subject 'Terminal cleanup payload'
        $installId = Copy-CommMonitorCanonicalOperationGuid `
            -Value $data.installId `
            -Subject 'Terminal cleanup installId'
        $status = Copy-CommMonitorSchemaString `
            -Value $data.status `
            -Subject 'Terminal cleanup status'
        if (-not (Test-CommMonitorOrdinalValue `
                -Value $status `
                -Allowed @('Prepared', 'Active'))) {
            throw 'Terminal cleanup status must be exactly Prepared or Active.'
        }
        $createdUtc = Copy-CommMonitorCanonicalOperationUtc `
            -Value $data.createdUtc `
            -Subject 'Terminal cleanup createdUtc'
        $descriptor =
            ConvertTo-CommMonitorCanonicalTerminalAuthorityDescriptor `
                -CleanupId $data.cleanupId `
                -Nonce $data.nonce `
                -TerminalKeyRecord $data.key `
                -FinalizerRelativePath $data.finalizer.relativePath `
                -FinalizerSha256 $data.finalizer.sha256 `
                -DeletePlan $data.deletePlan
        $authorityIdentity = Copy-CommMonitorSchemaString `
            -Value $data.authorityIdentity `
            -Subject 'Terminal cleanup authorityIdentity'
        $actualIdentity = Get-CommMonitorSha256Hex -Bytes (
            Get-CommMonitorCanonicalJsonBytes -InputObject $descriptor)
        if (-not [regex]::IsMatch(
                $authorityIdentity,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not (Test-CommMonitorFixedTimeEquals `
                -LeftHex $actualIdentity `
                -RightHex $authorityIdentity)) {
            throw 'Terminal cleanup authorityIdentity does not bind its descriptor.'
        }
        $predecessor =
            ConvertTo-CommMonitorCanonicalTerminalManifestBinding `
                -Value $data.predecessor `
                -Subject 'Terminal cleanup predecessor'
        $successor =
            ConvertTo-CommMonitorCanonicalTerminalManifestBinding `
                -Value $data.successor `
                -Subject 'Terminal cleanup successor' `
                -Successor
        if (-not [string]::Equals(
                [string]$predecessor.state,
                'UninstallPrepared',
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$successor.state,
                'FinalizingAbsent',
                [StringComparison]::Ordinal) -or
            $successor.revision -ne ($predecessor.revision + 1) -or
            -not [string]::Equals(
                [string]$successor.previousPayloadSha256,
                [string]$predecessor.payloadSha256,
                [StringComparison]::Ordinal)) {
            throw 'Terminal cleanup manifest bindings do not form the exact terminal edge.'
        }
        if (-not [string]::Equals(
                [string]$predecessor.operationState.operationId,
                [string]$successor.operationState.operationId,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$successor.operationState.terminalCleanupId,
                [string]$descriptor.cleanupId,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$successor.operationState.terminalKeyId,
                [string]$descriptor.key.keyId,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$successor.operationState.terminalEnvelopeSha256,
                $authorityIdentity,
                [StringComparison]::Ordinal)) {
            throw 'Terminal cleanup successor operation is not bound to the authority.'
        }
        return [ordered]@{
            installId = $installId
            status = $status
            cleanupId = $descriptor.cleanupId
            nonce = $descriptor.nonce
            createdUtc = $createdUtc
            key = $descriptor.key
            authorityIdentity = $authorityIdentity
            finalizer = $descriptor.finalizer
            deletePlan = $descriptor.deletePlan
            predecessor = $predecessor
            successor = $successor
        }
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Terminal cleanup schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Terminal cleanup semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorTerminalCleanupSchemaError `
            -Message $_.Exception.Message
    }
}

function New-CommMonitorTerminalCleanupSignedEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Payload,
        [Parameter(Mandatory)][byte[]] $Key
    )

    if ($Key.Length -ne 32) {
        Throw-CommMonitorTerminalCleanupSemanticError `
            -Message 'Terminal cleanup key must contain exactly 256 bits.'
    }
    $canonical = ConvertTo-CommMonitorCanonicalTerminalCleanupPayload `
        -Payload $Payload
    $keyRecord = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $canonical.key
    $actualKeyId = Get-CommMonitorSha256Hex -Bytes $Key
    if (-not (Test-CommMonitorFixedTimeEquals `
            -LeftHex $actualKeyId `
            -RightHex ([string]$keyRecord.keyId))) {
        Throw-CommMonitorTerminalCleanupSemanticError `
            -Message 'Terminal cleanup key does not match its embedded keyId.'
    }
    $bytes = Get-CommMonitorCanonicalJsonBytes -InputObject $canonical
    return [ordered]@{
        integrity = [ordered]@{
            algorithm = 'HMAC-SHA256'
            keyId = [string]$keyRecord.keyId
            payloadSha256 = Get-CommMonitorSha256Hex -Bytes $bytes
            tag = Get-CommMonitorHmacSha256Hex -Key $Key -Bytes $bytes
        }
        payload = $canonical
        schemaVersion = 1
    }
}

function New-CommMonitorTerminalCleanupEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object] $Status,
        [Parameter(Mandatory)][object] $PredecessorPayload,
        [Parameter(Mandatory)][AllowNull()][object] $PredecessorPayloadSha256,
        [Parameter(Mandatory)][object] $SuccessorPayload,
        [Parameter(Mandatory)][AllowNull()][object] $CleanupId,
        [Parameter(Mandatory)][AllowNull()][object] $Nonce,
        [Parameter(Mandatory)][AllowNull()][object] $FinalizerRelativePath,
        [Parameter(Mandatory)][AllowNull()][object] $FinalizerSha256,
        [Parameter(Mandatory)][object] $DeletePlan,
        [Parameter(Mandatory)][AllowNull()][object] $CreatedUtc,
        [Parameter(Mandatory)][object] $TerminalKeyRecord,
        [Parameter(Mandatory)][byte[]] $TerminalKey,
        [Parameter(Mandatory)][object] $TerminalPreparationCapability
    )

    try {
        $statusValue = Copy-CommMonitorSchemaString `
            -Value $Status `
            -Subject 'Terminal cleanup status'
        if (-not [string]::Equals(
                $statusValue,
                'Prepared',
                [StringComparison]::Ordinal)) {
            throw 'New terminal cleanup authority must start in Prepared state.'
        }
        $descriptor =
            ConvertTo-CommMonitorCanonicalTerminalAuthorityDescriptor `
                -CleanupId $CleanupId `
                -Nonce $Nonce `
                -TerminalKeyRecord $TerminalKeyRecord `
                -FinalizerRelativePath $FinalizerRelativePath `
                -FinalizerSha256 $FinalizerSha256 `
                -DeletePlan $DeletePlan
        if ($TerminalKey.Length -ne 32 -or
            -not (Test-CommMonitorFixedTimeEquals `
                -LeftHex (Get-CommMonitorSha256Hex -Bytes $TerminalKey) `
                -RightHex ([string]$descriptor.key.keyId))) {
            throw 'Terminal cleanup plaintext key does not match its embedded record.'
        }
        $predecessor = ConvertTo-CommMonitorCanonicalOwnershipPayload `
            -Payload $PredecessorPayload
        $successor = ConvertTo-CommMonitorCanonicalOwnershipPayload `
            -Payload $SuccessorPayload
        $predecessorHash = Copy-CommMonitorSchemaString `
            -Value $PredecessorPayloadSha256 `
            -Subject 'Terminal cleanup predecessor payloadSha256'
        $actualPredecessorHash =
            Get-CommMonitorCanonicalOwnershipPayloadSha256 `
                -Payload $predecessor
        if (-not [regex]::IsMatch(
                $predecessorHash,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not (Test-CommMonitorFixedTimeEquals `
                -LeftHex $actualPredecessorHash `
                -RightHex $predecessorHash)) {
            throw 'Terminal cleanup predecessor payload hash is invalid.'
        }
        Assert-CommMonitorOwnershipTransition `
            -CurrentPayload $predecessor `
            -NextPayload $successor `
            -Actor 'Task5'
        if ([int]$successor.revision -ne ([int]$predecessor.revision + 1) -or
            -not [string]::Equals(
                [string]$successor.previousPayloadSha256,
                $predecessorHash,
                [StringComparison]::Ordinal)) {
            throw 'Terminal cleanup successor revision chain is not exact.'
        }
        $authorityIdentity = Get-CommMonitorSha256Hex -Bytes (
            Get-CommMonitorCanonicalJsonBytes -InputObject $descriptor)
        $terminalOperation = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $successor.operationState
        if (-not [string]::Equals(
                [string]$terminalOperation.terminalCleanupId,
                [string]$descriptor.cleanupId,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$terminalOperation.terminalKeyId,
                [string]$descriptor.key.keyId,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$terminalOperation.terminalEnvelopeSha256,
                $authorityIdentity,
                [StringComparison]::Ordinal)) {
            throw 'FinalizingAbsent operation does not bind terminal cleanup authority.'
        }
        $createdUtcValue = if ($CreatedUtc -is [DateTimeOffset]) {
            ([DateTimeOffset]$CreatedUtc).ToUniversalTime().ToString(
                'yyyy-MM-ddTHH:mm:ss.fffffffZ',
                [Globalization.CultureInfo]::InvariantCulture)
        }
        else {
            Copy-CommMonitorCanonicalOperationUtc `
                -Value $CreatedUtc `
                -Subject 'Terminal cleanup createdUtc'
        }
        $successorHash =
            Get-CommMonitorCanonicalOwnershipPayloadSha256 `
                -Payload $successor
        $payload = [ordered]@{
            installId = [string]$successor.installId
            status = 'Prepared'
            cleanupId = [string]$descriptor.cleanupId
            nonce = [string]$descriptor.nonce
            createdUtc = $createdUtcValue
            key = $descriptor.key
            authorityIdentity = $authorityIdentity
            finalizer = $descriptor.finalizer
            deletePlan = $descriptor.deletePlan
            predecessor = [ordered]@{
                revision = [int]$predecessor.revision
                payloadSha256 = $predecessorHash
                state = [string]$predecessor.state
                operationState = $predecessor.operationState
            }
            successor = [ordered]@{
                revision = [int]$successor.revision
                previousPayloadSha256 =
                    [string]$successor.previousPayloadSha256
                payloadSha256 = $successorHash
                state = [string]$successor.state
                operationState = $successor.operationState
            }
        }
        $envelope = New-CommMonitorTerminalCleanupSignedEnvelope `
            -Payload $payload `
            -Key $TerminalKey
        $predecessorOperation = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $predecessor.operationState
        [void](Assert-CommMonitorTerminalPreparationCapabilityBinding `
            -Capability $TerminalPreparationCapability `
            -ExpectedInstallId ([string]$predecessor.installId) `
            -ExpectedOperationId (
                [string]$predecessorOperation.operationId) `
            -ExpectedManifestPayloadSha256 $predecessorHash `
            -AuthorityIdentity $authorityIdentity `
            -BindAuthority)
        return $envelope
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Terminal cleanup schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Terminal cleanup semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorTerminalCleanupSemanticError `
            -Message $_.Exception.Message
    }
}

function Get-CommMonitorValidatedTerminalCleanupEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Envelope,
        [scriptblock] $UnprotectScript
    )

    $data = ConvertTo-CommMonitorSchemaObject `
        -Value $Envelope `
        -Subject 'Terminal cleanup envelope'
    Assert-CommMonitorExactFields `
        -Dictionary $data `
        -Allowed @('integrity', 'payload', 'schemaVersion') `
        -Required @('integrity', 'payload', 'schemaVersion') `
        -Subject 'Terminal cleanup envelope'
    $schemaVersion = Copy-CommMonitorSchemaInt32 `
        -Value $data.schemaVersion `
        -Subject 'Terminal cleanup envelope schemaVersion'
    if ($schemaVersion -ne 1) {
        throw 'Terminal cleanup envelope schemaVersion must be 1.'
    }
    $integrity = ConvertTo-CommMonitorSchemaObject `
        -Value $data.integrity `
        -Subject 'Terminal cleanup integrity'
    $integrityFields = @(
        'algorithm', 'keyId', 'payloadSha256', 'tag')
    Assert-CommMonitorExactFields `
        -Dictionary $integrity `
        -Allowed $integrityFields `
        -Required $integrityFields `
        -Subject 'Terminal cleanup integrity'
    $algorithm = Copy-CommMonitorSchemaString `
        -Value $integrity.algorithm `
        -Subject 'Terminal cleanup integrity algorithm'
    $keyId = Copy-CommMonitorSchemaString `
        -Value $integrity.keyId `
        -Subject 'Terminal cleanup integrity keyId'
    $payloadSha256 = Copy-CommMonitorSchemaString `
        -Value $integrity.payloadSha256 `
        -Subject 'Terminal cleanup integrity payloadSha256'
    $tag = Copy-CommMonitorSchemaString `
        -Value $integrity.tag `
        -Subject 'Terminal cleanup integrity tag'
    if (-not [string]::Equals(
            $algorithm,
            'HMAC-SHA256',
            [StringComparison]::Ordinal) -or
        -not [regex]::IsMatch(
            $keyId,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
        -not [regex]::IsMatch(
            $payloadSha256,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
        -not [regex]::IsMatch(
            $tag,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw 'Terminal cleanup integrity metadata is invalid.'
    }
    $payload = ConvertTo-CommMonitorCanonicalTerminalCleanupPayload `
        -Payload $data.payload
    $terminalKey = Get-CommMonitorManifestKey `
        -Record $payload.key `
        -UnprotectScript $UnprotectScript
    if (-not (Test-CommMonitorFixedTimeEquals `
            -LeftHex (Get-CommMonitorSha256Hex -Bytes $terminalKey) `
            -RightHex $keyId)) {
        throw 'Terminal cleanup integrity keyId differs from the embedded key.'
    }
    $bytes = Get-CommMonitorCanonicalJsonBytes -InputObject $payload
    $actualHash = Get-CommMonitorSha256Hex -Bytes $bytes
    $actualTag = Get-CommMonitorHmacSha256Hex `
        -Key $terminalKey `
        -Bytes $bytes
    if (-not (Test-CommMonitorFixedTimeEquals `
            -LeftHex $actualHash `
            -RightHex $payloadSha256) -or
        -not (Test-CommMonitorFixedTimeEquals `
            -LeftHex $actualTag `
            -RightHex $tag)) {
        throw 'Terminal cleanup envelope authentication failed.'
    }
    return [pscustomobject]@{
        Payload = $payload
        Key = $terminalKey
    }
}

function Assert-CommMonitorTerminalCleanupEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Envelope,
        [scriptblock] $UnprotectScript
    )

    try {
        return (Get-CommMonitorValidatedTerminalCleanupEnvelope `
            -Envelope $Envelope `
            -UnprotectScript $UnprotectScript).Payload
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Terminal cleanup schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Terminal cleanup semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorTerminalCleanupSchemaError `
            -Message $_.Exception.Message
    }
}

function Test-CommMonitorTerminalManifestBindingMatches {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Binding,
        [Parameter(Mandatory)][Collections.IDictionary] $Payload,
        [Parameter(Mandatory)][string] $PayloadSha256,
        [switch] $Successor
    )

    if ([int]$Binding.revision -ne [int]$Payload.revision -or
        -not [string]::Equals(
            [string]$Binding.payloadSha256,
            $PayloadSha256,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$Binding.state,
            [string]$Payload.state,
            [StringComparison]::Ordinal) -or
        -not (Test-CommMonitorCanonicalSchemaValueEqual `
            -Left $Binding.operationState `
            -Right $Payload.operationState)) {
        return $false
    }
    if ($Successor -and
        -not [string]::Equals(
            [string]$Binding.previousPayloadSha256,
            [string]$Payload.previousPayloadSha256,
            [StringComparison]::Ordinal)) {
        return $false
    }
    return $true
}

function Resolve-CommMonitorTerminalCleanupAuthority {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Envelope,
        [scriptblock] $UnprotectScript,
        [AllowNull()][object] $Manifest,
        [AllowNull()][object] $Anchor,
        [AllowNull()][byte[]] $ManifestKey,
        [AllowNull()][string] $ExpectedManifestPath,
        [AllowNull()][string] $ExpectedAppId,
        [AllowNull()][string] $ExpectedInstallId
    )

    try {
        $validated = Get-CommMonitorValidatedTerminalCleanupEnvelope `
            -Envelope $Envelope `
            -UnprotectScript $UnprotectScript
        $terminal = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $validated.Payload
        $manifestInputNames = @(
            'Manifest', 'Anchor', 'ManifestKey',
            'ExpectedManifestPath', 'ExpectedAppId', 'ExpectedInstallId')
        $boundParameterNames = [string[]]@($PSBoundParameters.Keys)
        $presentCount = @($manifestInputNames | Where-Object {
                $boundParameterNames -contains $_
            }).Count
        if ($presentCount -eq 0) {
            if (-not [string]::Equals(
                    [string]$terminal.status,
                    'Active',
                    [StringComparison]::Ordinal)) {
                Throw-CommMonitorTerminalCleanupRecoverySemanticError `
                    -Message 'Prepared terminal authority is inert without its predecessor manifest.'
            }
            return [pscustomobject]@{
                Disposition = 'ExecuteCleanup'
                CanDeleteOwnedObjects = $true
                TerminalPayload = $validated.Payload
                DeletePlan = $terminal.deletePlan
            }
        }
        if ($presentCount -ne $manifestInputNames.Count) {
            Throw-CommMonitorTerminalCleanupRecoverySemanticError `
                -Message 'Manifest recovery inputs must be supplied as one complete set.'
        }
        $currentPayload = Assert-CommMonitorOwnershipManifestState `
            -Manifest $Manifest `
            -Anchor $Anchor `
            -Key $ManifestKey `
            -ExpectedManifestPath $ExpectedManifestPath `
            -ExpectedAppId $ExpectedAppId `
            -ExpectedInstallId $ExpectedInstallId
        $current = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $currentPayload
        if (-not [string]::Equals(
                [string]$terminal.installId,
                [string]$current.installId,
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorTerminalCleanupRecoverySemanticError `
                -Message 'Terminal authority belongs to another installation.'
        }
        $anchorData = ConvertTo-CommMonitorSchemaObject `
            -Value $Anchor `
            -Subject 'Ownership anchor'
        $anchorBinding = ConvertTo-CommMonitorSchemaObject `
            -Value $anchorData.binding `
            -Subject 'Ownership anchor binding'
        $currentHash = [string]$anchorBinding.payloadSha256
        $predecessor = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $terminal.predecessor
        $successor = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $terminal.successor
        $matchesPredecessor = Test-CommMonitorTerminalManifestBindingMatches `
            -Binding $predecessor `
            -Payload $current `
            -PayloadSha256 $currentHash
        $matchesSuccessor = Test-CommMonitorTerminalManifestBindingMatches `
            -Binding $successor `
            -Payload $current `
            -PayloadSha256 $currentHash `
            -Successor
        if ($matchesPredecessor -eq $matchesSuccessor) {
            Throw-CommMonitorTerminalCleanupRecoverySemanticError `
                -Message 'Terminal authority matches neither one exact recovery side nor only one side.'
        }
        if ([string]::Equals(
                [string]$terminal.status,
                'Prepared',
                [StringComparison]::Ordinal)) {
            return [pscustomobject]@{
                Disposition = if ($matchesPredecessor) {
                    'RemovePrepared'
                }
                else {
                    'PromoteActive'
                }
                CanDeleteOwnedObjects = $false
                TerminalPayload = $validated.Payload
                DeletePlan = $terminal.deletePlan
            }
        }
        if (-not $matchesSuccessor) {
            Throw-CommMonitorTerminalCleanupRecoverySemanticError `
                -Message 'Active terminal authority requires the exact FinalizingAbsent successor.'
        }
        return [pscustomobject]@{
            Disposition = 'ExecuteCleanup'
            CanDeleteOwnedObjects = $true
            TerminalPayload = $validated.Payload
            DeletePlan = $terminal.deletePlan
        }
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Terminal cleanup recovery semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorTerminalCleanupRecoverySemanticError `
            -Message $_.Exception.Message
    }
}

function ConvertTo-CommMonitorActiveTerminalCleanupEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $PreparedEnvelope,
        [Parameter(Mandatory)][object] $Manifest,
        [Parameter(Mandatory)][object] $Anchor,
        [Parameter(Mandatory)][byte[]] $ManifestKey,
        [Parameter(Mandatory)][string] $ExpectedManifestPath,
        [Parameter(Mandatory)][string] $ExpectedAppId,
        [Parameter(Mandatory)][string] $ExpectedInstallId,
        [scriptblock] $UnprotectScript
    )

    try {
        $validated = Get-CommMonitorValidatedTerminalCleanupEnvelope `
            -Envelope $PreparedEnvelope `
            -UnprotectScript $UnprotectScript
        if (-not [string]::Equals(
                [string]$validated.Payload.status,
                'Prepared',
                [StringComparison]::Ordinal)) {
            throw 'Only Prepared terminal authority can be promoted.'
        }
        $resolution = Resolve-CommMonitorTerminalCleanupAuthority `
            -Envelope $PreparedEnvelope `
            -UnprotectScript $UnprotectScript `
            -Manifest $Manifest `
            -Anchor $Anchor `
            -ManifestKey $ManifestKey `
            -ExpectedManifestPath $ExpectedManifestPath `
            -ExpectedAppId $ExpectedAppId `
            -ExpectedInstallId $ExpectedInstallId
        if (-not [string]::Equals(
                [string]$resolution.Disposition,
                'PromoteActive',
                [StringComparison]::Ordinal)) {
            throw 'Prepared terminal authority is not paired with its exact successor.'
        }
        $activePayload = Copy-CommMonitorManifestSchemaValue `
            -Value $validated.Payload
        $activePayload.status = 'Active'
        return New-CommMonitorTerminalCleanupSignedEnvelope `
            -Payload $activePayload `
            -Key $validated.Key
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Terminal cleanup schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Terminal cleanup semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorTerminalCleanupSemanticError `
            -Message $_.Exception.Message
    }
}

function Throw-CommMonitorTerminalCleanupPlanningSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Terminal cleanup planning semantics: $Message"
}

function Get-CommMonitorTerminalCleanupActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $ActiveEnvelope,
        [Parameter(Mandatory)][object] $LiveObjects,
        [scriptblock] $UnprotectScript
    )

    try {
        $validated = Get-CommMonitorValidatedTerminalCleanupEnvelope `
            -Envelope $ActiveEnvelope `
            -UnprotectScript $UnprotectScript
        $terminal = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $validated.Payload
        if (-not [string]::Equals(
                [string]$terminal.status,
                'Active',
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorTerminalCleanupPlanningSemanticError `
                -Message 'Only Active terminal authority can emit delete actions.'
        }
        Assert-CommMonitorRawSchemaArray `
            -Value $LiveObjects `
            -Subject 'Terminal cleanup live objects'
        $plan = [object[]]@($terminal.deletePlan)
        if (@($LiveObjects).Count -ne $plan.Count) {
            Throw-CommMonitorTerminalCleanupPlanningSemanticError `
                -Message 'Live object set does not exactly cover the authenticated delete plan.'
        }
        $planById = [Collections.Generic.Dictionary[string, object]]::new(
            [StringComparer]::Ordinal)
        foreach ($planRecordInput in $plan) {
            $planRecord = ConvertTo-CommMonitorOrderedDictionary `
                -InputObject $planRecordInput
            $planById.Add([string]$planRecord.objectId, $planRecord)
        }
        $liveById = [Collections.Generic.Dictionary[string, object]]::new(
            [StringComparer]::Ordinal)
        foreach ($liveInput in $LiveObjects) {
            $live = ConvertTo-CommMonitorSchemaObject `
                -Value $liveInput `
                -Subject 'Terminal cleanup live object'
            if (-not $live.Contains('status')) {
                throw "Terminal cleanup live object is missing required field 'status'."
            }
            $status = Copy-CommMonitorSchemaString `
                -Value $live.status `
                -Subject 'Terminal cleanup live object status'
            $fields = switch -CaseSensitive ($status) {
                'Absent' { @('objectId', 'status') }
                'Present' {
                    @(
                        'objectId', 'status', 'root', 'relativePath', 'kind',
                        'volumeSerialNumber', 'fileId', 'size', 'sha256')
                }
                default { throw "Terminal cleanup live status '$status' is unsupported." }
            }
            Assert-CommMonitorExactFields `
                -Dictionary $live `
                -Allowed $fields `
                -Required $fields `
                -Subject 'Terminal cleanup live object'
            $objectId = Copy-CommMonitorSchemaString `
                -Value $live.objectId `
                -Subject 'Terminal cleanup live objectId'
            if (-not $planById.ContainsKey($objectId) -or
                $liveById.ContainsKey($objectId)) {
                throw "Terminal cleanup live object '$objectId' is unknown or duplicate."
            }
            if ($status -eq 'Absent') {
                $liveById.Add($objectId, [ordered]@{
                        objectId = $objectId
                        status = 'Absent'
                    })
                continue
            }
            $canonical = [ordered]@{
                objectId = $objectId
                status = 'Present'
                root = Copy-CommMonitorSchemaString `
                    -Value $live.root `
                    -Subject 'Terminal cleanup live root'
                relativePath = Copy-CommMonitorSchemaString `
                    -Value $live.relativePath `
                    -Subject 'Terminal cleanup live relativePath'
                kind = Copy-CommMonitorSchemaString `
                    -Value $live.kind `
                    -Subject 'Terminal cleanup live kind'
                volumeSerialNumber = Copy-CommMonitorSchemaString `
                    -Value $live.volumeSerialNumber `
                    -Subject 'Terminal cleanup live volumeSerialNumber'
                fileId = Copy-CommMonitorSchemaString `
                    -Value $live.fileId `
                    -Subject 'Terminal cleanup live fileId'
                size = Copy-CommMonitorSchemaInt64 `
                    -Value $live.size `
                    -Subject 'Terminal cleanup live size'
                sha256 = Copy-CommMonitorSchemaString `
                    -Value $live.sha256 `
                    -Subject 'Terminal cleanup live sha256'
            }
            $planned = $planById[$objectId]
            foreach ($field in @(
                    'root', 'relativePath', 'kind', 'volumeSerialNumber',
                    'fileId', 'size', 'sha256')) {
                if (-not (Test-CommMonitorCanonicalSchemaValueEqual `
                        -Left $canonical[$field] `
                        -Right $planned[$field])) {
                    throw "Terminal cleanup live object '$objectId' identity differs at '$field'."
                }
            }
            $liveById.Add($objectId, $canonical)
        }
        if ($liveById.Count -ne $planById.Count) {
            Throw-CommMonitorTerminalCleanupPlanningSemanticError `
                -Message 'Live object set is incomplete.'
        }
        $actions = [Collections.Generic.List[object]]::new()
        foreach ($planRecordInput in $plan) {
            $planned = ConvertTo-CommMonitorOrderedDictionary `
                -InputObject $planRecordInput
            $live = $liveById[[string]$planned.objectId]
            if ([string]::Equals(
                    [string]$live.status,
                    'Present',
                    [StringComparison]::Ordinal)) {
                $actions.Add([pscustomobject][ordered]@{
                        objectId = [string]$planned.objectId
                        action = 'DeleteExactFile'
                        root = [string]$planned.root
                        relativePath = [string]$planned.relativePath
                        volumeSerialNumber =
                            [string]$planned.volumeSerialNumber
                        fileId = [string]$planned.fileId
                        size = [long]$planned.size
                        sha256 = [string]$planned.sha256
                        deleteOrder = [int]$planned.deleteOrder
                    })
            }
        }
        $actions.Add([pscustomobject][ordered]@{
                objectId = 'terminal-authority'
                action = 'DeleteAuthorityLast'
                authorityIdentity = [string]$terminal.authorityIdentity
                deleteOrder = [int]::MaxValue
            })
        Write-Output -NoEnumerate ([object[]]$actions.ToArray())
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Terminal cleanup planning semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorTerminalCleanupPlanningSemanticError `
            -Message $_.Exception.Message
    }
}

function Throw-CommMonitorPostTerminalCleanupSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Post-terminal cleanup semantics: $Message"
}

function Get-CommMonitorPostTerminalDirectoryCleanupActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object] $TerminalAuthorityPresent,
        [Parameter(Mandatory)][object] $Directories
    )

    try {
        $authorityPresent = Copy-CommMonitorSchemaBoolean `
            -Value $TerminalAuthorityPresent `
            -Subject 'Terminal authority presence'
        if ($authorityPresent) {
            Throw-CommMonitorPostTerminalCleanupSemanticError `
                -Message 'Container recovery starts only after terminal authority is absent.'
        }
        Assert-CommMonitorRawSchemaArray `
            -Value $Directories `
            -Subject 'Post-terminal directories'
        if (@($Directories).Count -ne 2) {
            throw 'Post-terminal cleanup requires exactly two directory observations.'
        }
        $expected = [ordered]@{
            StateDirectory =
                'C:\ProgramData\LemonSerialMonitor\Installer\state'
            InstallerRoot =
                'C:\ProgramData\LemonSerialMonitor\Installer'
        }
        $seen = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal)
        $observations = [Collections.Generic.List[object]]::new()
        foreach ($input in $Directories) {
            $directory = ConvertTo-CommMonitorSchemaObject `
                -Value $input `
                -Subject 'Post-terminal directory'
            foreach ($required in @('role', 'canonicalPath', 'exists')) {
                if (-not $directory.Contains($required)) {
                    throw "Post-terminal directory is missing '$required'."
                }
            }
            $exists = Copy-CommMonitorSchemaBoolean `
                -Value $directory.exists `
                -Subject 'Post-terminal directory exists'
            $fields = if ($exists) {
                @(
                    'role', 'canonicalPath', 'exists', 'empty',
                    'reparsePoint', 'localFixedVolume', 'aclTrusted')
            }
            else {
                @('role', 'canonicalPath', 'exists')
            }
            Assert-CommMonitorExactFields `
                -Dictionary $directory `
                -Allowed $fields `
                -Required $fields `
                -Subject 'Post-terminal directory'
            $role = Copy-CommMonitorSchemaString `
                -Value $directory.role `
                -Subject 'Post-terminal directory role'
            $path = Copy-CommMonitorSchemaString `
                -Value $directory.canonicalPath `
                -Subject 'Post-terminal directory canonicalPath'
            if (-not $expected.Contains($role) -or
                -not $seen.Add($role) -or
                -not [string]::Equals(
                    $path,
                    [string]$expected[$role],
                    [StringComparison]::Ordinal)) {
                throw "Post-terminal directory '$role' has an invalid identity or duplicate."
            }
            $copy = [ordered]@{
                role = $role
                canonicalPath = $path
                exists = $exists
            }
            if ($exists) {
                $copy['empty'] = Copy-CommMonitorSchemaBoolean `
                    -Value $directory.empty `
                    -Subject 'Post-terminal directory empty'
                $copy['reparsePoint'] = Copy-CommMonitorSchemaBoolean `
                    -Value $directory.reparsePoint `
                    -Subject 'Post-terminal directory reparsePoint'
                $copy['localFixedVolume'] = Copy-CommMonitorSchemaBoolean `
                    -Value $directory.localFixedVolume `
                    -Subject 'Post-terminal directory localFixedVolume'
                $copy['aclTrusted'] = Copy-CommMonitorSchemaBoolean `
                    -Value $directory.aclTrusted `
                    -Subject 'Post-terminal directory aclTrusted'
                if (-not $copy.empty -or
                    $copy.reparsePoint -or
                    -not $copy.localFixedVolume -or
                    -not $copy.aclTrusted) {
                    throw "Post-terminal directory '$role' is not an exact trusted empty container."
                }
            }
            $observations.Add($copy)
        }
        $sequence = [string]::Join(
            ',',
            [string[]]@($observations | ForEach-Object { $_.role }))
        if (-not [string]::Equals(
                $sequence,
                'StateDirectory,InstallerRoot',
                [StringComparison]::Ordinal)) {
            throw 'Post-terminal directories are not in child-before-parent order.'
        }
        if ($observations[0].exists -and -not $observations[1].exists) {
            throw 'StateDirectory cannot exist after InstallerRoot is absent.'
        }
        $actions = [Collections.Generic.List[object]]::new()
        foreach ($directory in $observations) {
            if ($directory.exists) {
                $actions.Add([pscustomobject][ordered]@{
                        role = [string]$directory.role
                        action = 'DeleteEmptyDirectory'
                        canonicalPath = [string]$directory.canonicalPath
                    })
            }
        }
        Write-Output -NoEnumerate ([object[]]$actions.ToArray())
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Post-terminal cleanup semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorPostTerminalCleanupSemanticError `
            -Message $_.Exception.Message
    }
}

function Throw-CommMonitorTerminalCompletionSchemaError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Terminal completion schema: $Message"
}

function Test-CommMonitorTerminalCleanupComplete {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][object] $Observation)

    try {
        $data = ConvertTo-CommMonitorSchemaObject `
            -Value $Observation `
            -Subject 'Terminal completion observation'
        $booleanFields = @(
            'terminalAuthorityPresent', 'stateDirectoryPresent',
            'installerRootPresent', 'manifestPresent', 'manifestKeyPresent',
            'anchorPresent', 'continuationPresent', 'continuationTaskPresent',
            'uninstallEntryPresent', 'appRootPresent', 'coreRootPresent',
            'dataRootPresent', 'aiRootPresent')
        $fields = [string[]]@($booleanFields + 'residualObjectIds')
        Assert-CommMonitorExactFields `
            -Dictionary $data `
            -Allowed $fields `
            -Required $fields `
            -Subject 'Terminal completion observation'
        foreach ($field in $booleanFields) {
            if (Copy-CommMonitorSchemaBoolean `
                    -Value $data[$field] `
                    -Subject "Terminal completion $field") {
                return $false
            }
        }
        $residuals = Copy-CommMonitorCanonicalStringSet `
            -Value $data.residualObjectIds `
            -Subject 'Terminal completion residualObjectIds'
        return @($residuals).Count -eq 0
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Terminal completion schema:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorTerminalCompletionSchemaError `
            -Message $_.Exception.Message
    }
}

function Throw-CommMonitorUninstallResultSchemaError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Uninstall result schema: $Message"
}

function Throw-CommMonitorUninstallResultSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Uninstall result semantics: $Message"
}

function ConvertTo-CommMonitorCanonicalUninstallOutcomes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object] $Outcomes,
        [Parameter(Mandatory)][string] $Status
    )

    Assert-CommMonitorRawSchemaArray `
        -Value $Outcomes `
        -Subject 'Uninstall result outcomes'
    if (@($Outcomes).Count -eq 0) {
        throw 'Uninstall result outcomes must not be empty.'
    }
    $ids = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $items = [Collections.Generic.List[object]]::new()
    foreach ($input in $Outcomes) {
        $outcome = ConvertTo-CommMonitorSchemaObject `
            -Value $input `
            -Subject 'Uninstall result outcome'
        $fields = @('objectId', 'outcome', 'win32Code')
        Assert-CommMonitorExactFields `
            -Dictionary $outcome `
            -Allowed $fields `
            -Required $fields `
            -Subject 'Uninstall result outcome'
        $objectId = Copy-CommMonitorSchemaString `
            -Value $outcome.objectId `
            -Subject 'Uninstall result outcome objectId'
        if (-not [regex]::IsMatch(
                $objectId,
                '^[a-z0-9][a-z0-9.-]*$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not $ids.Add($objectId)) {
            throw 'Uninstall result outcome object IDs are invalid or duplicate.'
        }
        $outcomeValue = Copy-CommMonitorSchemaString `
            -Value $outcome.outcome `
            -Subject 'Uninstall result outcome value'
        if (-not (Test-CommMonitorOrdinalValue `
                -Value $outcomeValue `
                -Allowed @(
                    'Deleted', 'AlreadyAbsent', 'PendingReboot',
                    'Failed', 'Preserved'))) {
            throw "Uninstall result outcome '$outcomeValue' is unsupported."
        }
        $win32Code = Copy-CommMonitorSchemaInt32 `
            -Value $outcome.win32Code `
            -Subject 'Uninstall result outcome win32Code'
        if ($win32Code -lt 0) {
            throw 'Uninstall result win32Code must not be negative.'
        }
        $items.Add([ordered]@{
                objectId = $objectId
                outcome = $outcomeValue
                win32Code = $win32Code
            })
    }
    $items.Sort([Comparison[object]] {
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string]$left.objectId,
                [string]$right.objectId)
        })
    $values = [object[]]$items.ToArray()
    $hasPending = @($values | Where-Object {
            $_.outcome -eq 'PendingReboot'
        }).Count -gt 0
    $hasFailure = @($values | Where-Object {
            $_.outcome -in @('Failed', 'Preserved')
        }).Count -gt 0
    switch -CaseSensitive ($Status) {
        'Completed' {
            if (@($values | Where-Object {
                        $_.outcome -notin @('Deleted', 'AlreadyAbsent') -or
                        ($_.outcome -eq 'Deleted' -and $_.win32Code -ne 0)
                    }).Count -gt 0) {
                throw 'Completed result contains a non-complete outcome.'
            }
        }
        'PendingReboot' {
            if (-not $hasPending -or $hasFailure -or
                @($values | Where-Object {
                        $_.outcome -eq 'PendingReboot' -and
                        $_.win32Code -notin @(5, 32, 33, 1224)
                    }).Count -gt 0) {
                throw 'PendingReboot result lacks one allowed held-identity lock outcome.'
            }
        }
        'Failed' {
            if (-not $hasFailure -or $hasPending -or
                @($values | Where-Object {
                        $_.outcome -in @('Failed', 'Preserved') -and
                        $_.win32Code -eq 0
                    }).Count -gt 0) {
                throw 'Failed result lacks one nonzero failure or preserved outcome.'
            }
        }
    }
    Write-Output -NoEnumerate $values
}

function ConvertTo-CommMonitorCanonicalUninstallResultPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Payload)

    try {
        $data = ConvertTo-CommMonitorSchemaObject `
            -Value $Payload `
            -Subject 'Uninstall result payload'
        $fields = @(
            'installId', 'operationId', 'resultId', 'resultRelativePath',
            'nonceSha256', 'manifest', 'status', 'exitCode',
            'rebootRequired', 'createdUtc', 'helper', 'outcomes')
        Assert-CommMonitorExactFields `
            -Dictionary $data `
            -Allowed $fields `
            -Required $fields `
            -Subject 'Uninstall result payload'
        $installId = Copy-CommMonitorCanonicalOperationGuid `
            -Value $data.installId `
            -Subject 'Uninstall result installId'
        $operationId = Copy-CommMonitorCanonicalOperationGuid `
            -Value $data.operationId `
            -Subject 'Uninstall result operationId'
        $resultId = Copy-CommMonitorCanonicalOperationGuid `
            -Value $data.resultId `
            -Subject 'Uninstall result resultId'
        $resultRelativePath = Copy-CommMonitorSchemaString `
            -Value $data.resultRelativePath `
            -Subject 'Uninstall result resultRelativePath'
        Assert-CommMonitorRelativeOrdinaryPath -Path $resultRelativePath
        $nonceSha256 = Copy-CommMonitorSchemaString `
            -Value $data.nonceSha256 `
            -Subject 'Uninstall result nonceSha256'
        if (-not [regex]::IsMatch(
                $nonceSha256,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            throw 'Uninstall result nonceSha256 must be lowercase SHA-256.'
        }
        $manifest = ConvertTo-CommMonitorSchemaObject `
            -Value $data.manifest `
            -Subject 'Uninstall result manifest binding'
        $manifestFields = @('revision', 'payloadSha256', 'state')
        Assert-CommMonitorExactFields `
            -Dictionary $manifest `
            -Allowed $manifestFields `
            -Required $manifestFields `
            -Subject 'Uninstall result manifest binding'
        $manifestRevision = Copy-CommMonitorSchemaInt32 `
            -Value $manifest.revision `
            -Subject 'Uninstall result manifest revision'
        $manifestHash = Copy-CommMonitorSchemaString `
            -Value $manifest.payloadSha256 `
            -Subject 'Uninstall result manifest payloadSha256'
        $manifestState = Copy-CommMonitorSchemaString `
            -Value $manifest.state `
            -Subject 'Uninstall result manifest state'
        if ($manifestRevision -lt 1 -or
            -not [regex]::IsMatch(
                $manifestHash,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [string]::Equals(
                $manifestState,
                'UninstallPrepared',
                [StringComparison]::Ordinal)) {
            throw 'Uninstall result manifest binding is not UninstallPrepared.'
        }
        $status = Copy-CommMonitorSchemaString `
            -Value $data.status `
            -Subject 'Uninstall result status'
        if (-not (Test-CommMonitorOrdinalValue `
                -Value $status `
                -Allowed @('Completed', 'PendingReboot', 'Failed'))) {
            throw 'Uninstall result status is unsupported.'
        }
        $exitCode = Copy-CommMonitorSchemaInt32 `
            -Value $data.exitCode `
            -Subject 'Uninstall result exitCode'
        $rebootRequired = Copy-CommMonitorSchemaBoolean `
            -Value $data.rebootRequired `
            -Subject 'Uninstall result rebootRequired'
        switch -CaseSensitive ($status) {
            'Completed' {
                if ($exitCode -ne 0 -or $rebootRequired) {
                    throw 'Completed requires exit 0 and rebootRequired false.'
                }
            }
            'PendingReboot' {
                if ($exitCode -ne 3010 -or -not $rebootRequired) {
                    throw 'PendingReboot requires exit 3010 and rebootRequired true.'
                }
            }
            'Failed' {
                if ($exitCode -le 0 -or $exitCode -eq 3010 -or
                    $rebootRequired) {
                    throw 'Failed requires nonzero non-3010 exit and rebootRequired false.'
                }
            }
        }
        $createdUtc = Copy-CommMonitorCanonicalOperationUtc `
            -Value $data.createdUtc `
            -Subject 'Uninstall result createdUtc'
        $helper = ConvertTo-CommMonitorSchemaObject `
            -Value $data.helper `
            -Subject 'Uninstall result helper'
        $helperFields = @('pid', 'creationUtc', 'imageSha256')
        Assert-CommMonitorExactFields `
            -Dictionary $helper `
            -Allowed $helperFields `
            -Required $helperFields `
            -Subject 'Uninstall result helper'
        $helperPid = Copy-CommMonitorSchemaInt64 `
            -Value $helper.pid `
            -Subject 'Uninstall result helper pid'
        $helperCreationUtc = Copy-CommMonitorCanonicalOperationUtc `
            -Value $helper.creationUtc `
            -Subject 'Uninstall result helper creationUtc'
        $helperImageSha256 = Copy-CommMonitorSchemaString `
            -Value $helper.imageSha256 `
            -Subject 'Uninstall result helper imageSha256'
        if ($helperPid -lt 1 -or $helperPid -gt [uint32]::MaxValue -or
            -not [regex]::IsMatch(
                $helperImageSha256,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            throw 'Uninstall result helper process identity is invalid.'
        }
        $outcomes = ConvertTo-CommMonitorCanonicalUninstallOutcomes `
            -Outcomes $data.outcomes `
            -Status $status
        return [ordered]@{
            installId = $installId
            operationId = $operationId
            resultId = $resultId
            resultRelativePath = $resultRelativePath
            nonceSha256 = $nonceSha256
            manifest = [ordered]@{
                revision = $manifestRevision
                payloadSha256 = $manifestHash
                state = $manifestState
            }
            status = $status
            exitCode = $exitCode
            rebootRequired = $rebootRequired
            createdUtc = $createdUtc
            helper = [ordered]@{
                pid = $helperPid
                creationUtc = $helperCreationUtc
                imageSha256 = $helperImageSha256
            }
            outcomes = $outcomes
        }
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Uninstall result schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Uninstall result semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorUninstallResultSchemaError `
            -Message $_.Exception.Message
    }
}

function Assert-CommMonitorUninstallResultManifestBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $ResultPayload,
        [Parameter(Mandatory)][object] $ManifestPayload,
        [Parameter(Mandatory)][string] $ManifestPayloadSha256
    )

    $result = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $ResultPayload
    $manifest = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $ManifestPayload
    $operation = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $manifest.operationState
    $nonceBytes = [byte[]]::new(32)
    try {
        for ($index = 0; $index -lt 32; $index++) {
            $nonceBytes[$index] = [Convert]::ToByte(
                ([string]$operation.nonce).Substring($index * 2, 2),
                16)
        }
    }
    catch {
        Throw-CommMonitorUninstallResultSemanticError `
            -Message 'Manifest operation nonce cannot be decoded.'
    }
    $expectedNonceHash = Get-CommMonitorSha256Hex -Bytes $nonceBytes
    $expectedOutcomeIds = [string[]]@($operation.pendingObjectIds)
    $actualOutcomeIds = [string[]]@(
        $result.outcomes | ForEach-Object { [string]$_.objectId })
    if (-not [string]::Equals(
            [string]$manifest.state,
            'UninstallPrepared',
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$result.installId,
            [string]$manifest.installId,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$result.operationId,
            [string]$operation.operationId,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$result.resultRelativePath,
            [string]$operation.resultRelativePath,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$result.nonceSha256,
            $expectedNonceHash,
            [StringComparison]::Ordinal) -or
        [int]$result.manifest.revision -ne [int]$manifest.revision -or
        -not [string]::Equals(
            [string]$result.manifest.payloadSha256,
            $ManifestPayloadSha256,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$result.manifest.state,
            [string]$manifest.state,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$result.helper.imageSha256,
            [string]$operation.helperSha256,
            [StringComparison]::Ordinal) -or
        -not (Test-CommMonitorCanonicalSchemaValueEqual `
            -Left $actualOutcomeIds `
            -Right $expectedOutcomeIds)) {
        Throw-CommMonitorUninstallResultSemanticError `
            -Message 'Result token is not bound to the exact prepared operation.'
    }
}

function New-CommMonitorUninstallResultEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $ManifestPayload,
        [Parameter(Mandatory)][object] $ManifestPayloadSha256,
        [Parameter(Mandatory)][object] $ResultId,
        [Parameter(Mandatory)][object] $Status,
        [Parameter(Mandatory)][object] $ExitCode,
        [Parameter(Mandatory)][object] $RebootRequired,
        [Parameter(Mandatory)][object] $CreatedUtc,
        [Parameter(Mandatory)][object] $HelperPid,
        [Parameter(Mandatory)][object] $HelperCreationUtc,
        [Parameter(Mandatory)][object] $HelperImageSha256,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object] $Outcomes,
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][object] $KeyId
    )

    try {
        if ($Key.Length -ne 32) {
            throw 'Uninstall result key must contain exactly 256 bits.'
        }
        $keyIdValue = Copy-CommMonitorSchemaString `
            -Value $KeyId `
            -Subject 'Uninstall result keyId'
        if (-not [regex]::IsMatch(
                $keyIdValue,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not (Test-CommMonitorFixedTimeEquals `
                -LeftHex (Get-CommMonitorSha256Hex -Bytes $Key) `
                -RightHex $keyIdValue)) {
            throw 'Uninstall result keyId does not match the supplied key.'
        }
        $manifest = ConvertTo-CommMonitorCanonicalOwnershipPayload `
            -Payload $ManifestPayload
        $manifestHash = Copy-CommMonitorSchemaString `
            -Value $ManifestPayloadSha256 `
            -Subject 'Uninstall result manifest payloadSha256'
        $actualManifestHash =
            Get-CommMonitorCanonicalOwnershipPayloadSha256 -Payload $manifest
        if (-not [regex]::IsMatch(
                $manifestHash,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not (Test-CommMonitorFixedTimeEquals `
                -LeftHex $actualManifestHash `
                -RightHex $manifestHash) -or
            -not [string]::Equals(
                [string]$manifest.state,
                'UninstallPrepared',
                [StringComparison]::Ordinal)) {
            throw 'Uninstall result requires the exact UninstallPrepared payload.'
        }
        $operation = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $manifest.operationState
        $nonceBytes = [byte[]]::new(32)
        for ($index = 0; $index -lt 32; $index++) {
            $nonceBytes[$index] = [Convert]::ToByte(
                ([string]$operation.nonce).Substring($index * 2, 2),
                16)
        }
        $createdUtcValue = if ($CreatedUtc -is [DateTimeOffset]) {
            ([DateTimeOffset]$CreatedUtc).ToUniversalTime().ToString(
                'yyyy-MM-ddTHH:mm:ss.fffffffZ',
                [Globalization.CultureInfo]::InvariantCulture)
        }
        else {
            Copy-CommMonitorCanonicalOperationUtc `
                -Value $CreatedUtc `
                -Subject 'Uninstall result createdUtc'
        }
        $payload = [ordered]@{
            installId = [string]$manifest.installId
            operationId = [string]$operation.operationId
            resultId = $ResultId
            resultRelativePath = [string]$operation.resultRelativePath
            nonceSha256 = Get-CommMonitorSha256Hex -Bytes $nonceBytes
            manifest = [ordered]@{
                revision = [int]$manifest.revision
                payloadSha256 = $manifestHash
                state = [string]$manifest.state
            }
            status = $Status
            exitCode = $ExitCode
            rebootRequired = $RebootRequired
            createdUtc = $createdUtcValue
            helper = [ordered]@{
                pid = $HelperPid
                creationUtc = $HelperCreationUtc
                imageSha256 = $HelperImageSha256
            }
            outcomes = $Outcomes
        }
        $canonical =
            ConvertTo-CommMonitorCanonicalUninstallResultPayload `
                -Payload $payload
        Assert-CommMonitorUninstallResultManifestBinding `
            -ResultPayload $canonical `
            -ManifestPayload $manifest `
            -ManifestPayloadSha256 $manifestHash
        $bytes = Get-CommMonitorCanonicalJsonBytes -InputObject $canonical
        return [ordered]@{
            integrity = [ordered]@{
                algorithm = 'HMAC-SHA256'
                keyId = $keyIdValue
                payloadSha256 = Get-CommMonitorSha256Hex -Bytes $bytes
                tag = Get-CommMonitorHmacSha256Hex -Key $Key -Bytes $bytes
            }
            payload = $canonical
            schemaVersion = 1
        }
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Uninstall result schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Uninstall result semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorUninstallResultSemanticError `
            -Message $_.Exception.Message
    }
}

function Assert-CommMonitorUninstallResultEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Envelope,
        [Parameter(Mandatory)][object] $ExpectedManifestPayload,
        [Parameter(Mandatory)][object] $ExpectedManifestPayloadSha256,
        [Parameter(Mandatory)][byte[]] $Key
    )

    try {
        if ($Key.Length -ne 32) {
            throw 'Uninstall result key must contain exactly 256 bits.'
        }
        $data = ConvertTo-CommMonitorSchemaObject `
            -Value $Envelope `
            -Subject 'Uninstall result envelope'
        Assert-CommMonitorExactFields `
            -Dictionary $data `
            -Allowed @('integrity', 'payload', 'schemaVersion') `
            -Required @('integrity', 'payload', 'schemaVersion') `
            -Subject 'Uninstall result envelope'
        $schemaVersion = Copy-CommMonitorSchemaInt32 `
            -Value $data.schemaVersion `
            -Subject 'Uninstall result envelope schemaVersion'
        if ($schemaVersion -ne 1) {
            throw 'Uninstall result envelope schemaVersion must be 1.'
        }
        $integrity = ConvertTo-CommMonitorSchemaObject `
            -Value $data.integrity `
            -Subject 'Uninstall result integrity'
        $integrityFields = @(
            'algorithm', 'keyId', 'payloadSha256', 'tag')
        Assert-CommMonitorExactFields `
            -Dictionary $integrity `
            -Allowed $integrityFields `
            -Required $integrityFields `
            -Subject 'Uninstall result integrity'
        $algorithm = Copy-CommMonitorSchemaString `
            -Value $integrity.algorithm `
            -Subject 'Uninstall result integrity algorithm'
        $keyId = Copy-CommMonitorSchemaString `
            -Value $integrity.keyId `
            -Subject 'Uninstall result integrity keyId'
        $payloadHash = Copy-CommMonitorSchemaString `
            -Value $integrity.payloadSha256 `
            -Subject 'Uninstall result integrity payloadSha256'
        $tag = Copy-CommMonitorSchemaString `
            -Value $integrity.tag `
            -Subject 'Uninstall result integrity tag'
        if (-not [string]::Equals(
                $algorithm,
                'HMAC-SHA256',
                [StringComparison]::Ordinal) -or
            -not [regex]::IsMatch(
                $keyId,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [regex]::IsMatch(
                $payloadHash,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [regex]::IsMatch(
                $tag,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not (Test-CommMonitorFixedTimeEquals `
                -LeftHex (Get-CommMonitorSha256Hex -Bytes $Key) `
                -RightHex $keyId)) {
            throw 'Uninstall result integrity metadata or key is invalid.'
        }
        $payload = ConvertTo-CommMonitorCanonicalUninstallResultPayload `
            -Payload $data.payload
        $bytes = Get-CommMonitorCanonicalJsonBytes -InputObject $payload
        if (-not (Test-CommMonitorFixedTimeEquals `
                -LeftHex (Get-CommMonitorSha256Hex -Bytes $bytes) `
                -RightHex $payloadHash) -or
            -not (Test-CommMonitorFixedTimeEquals `
                -LeftHex (Get-CommMonitorHmacSha256Hex `
                    -Key $Key `
                    -Bytes $bytes) `
                -RightHex $tag)) {
            throw 'Uninstall result envelope authentication failed.'
        }
        $manifest = ConvertTo-CommMonitorCanonicalOwnershipPayload `
            -Payload $ExpectedManifestPayload
        $manifestHash = Copy-CommMonitorSchemaString `
            -Value $ExpectedManifestPayloadSha256 `
            -Subject 'Expected uninstall result manifest payloadSha256'
        $actualManifestHash =
            Get-CommMonitorCanonicalOwnershipPayloadSha256 -Payload $manifest
        if (-not (Test-CommMonitorFixedTimeEquals `
                -LeftHex $actualManifestHash `
                -RightHex $manifestHash)) {
            throw 'Expected uninstall result manifest payload hash is invalid.'
        }
        Assert-CommMonitorUninstallResultManifestBinding `
            -ResultPayload $payload `
            -ManifestPayload $manifest `
            -ManifestPayloadSha256 $manifestHash
        return $payload
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Uninstall result schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Uninstall result semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorUninstallResultSchemaError `
            -Message $_.Exception.Message
    }
}

function Throw-CommMonitorTerminalPreparationSchemaError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Terminal preparation schema: $Message"
}

function Throw-CommMonitorTerminalPreparationSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Terminal preparation semantics: $Message"
}

function ConvertTo-CommMonitorCanonicalTerminalResidualObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Observation)

    try {
        $data = ConvertTo-CommMonitorSchemaObject `
            -Value $Observation `
            -Subject 'Terminal preparation residual observation'
        $booleanFields = [string[]]@(
            'uninstallEntryPresent', 'continuationTaskPresent',
            'appRootPresent', 'dataRootPresent', 'aiRootPresent',
            'coreNonAuthorityPresent', 'installerNonAuthorityPresent')
        $fields = [string[]]@(
            @('operationId', 'resultId', 'verifiedUtc',
                'productWriterCount', 'nonAuthorityResidualObjectIds') +
            $booleanFields)
        Assert-CommMonitorExactFields `
            -Dictionary $data `
            -Allowed $fields `
            -Required $fields `
            -Subject 'Terminal preparation residual observation'
        $operationId = Copy-CommMonitorCanonicalOperationGuid `
            -Value $data.operationId `
            -Subject 'Terminal preparation residual operationId'
        $resultId = Copy-CommMonitorCanonicalOperationGuid `
            -Value $data.resultId `
            -Subject 'Terminal preparation residual resultId'
        $verifiedUtc = Copy-CommMonitorCanonicalOperationUtc `
            -Value $data.verifiedUtc `
            -Subject 'Terminal preparation residual verifiedUtc'
        $productWriterCount = Copy-CommMonitorSchemaInt32 `
            -Value $data.productWriterCount `
            -Subject 'Terminal preparation residual productWriterCount'
        if ($productWriterCount -lt 0) {
            throw 'Terminal preparation productWriterCount cannot be negative.'
        }
        $residualObjectIds = Copy-CommMonitorCanonicalStringSet `
            -Value $data.nonAuthorityResidualObjectIds `
            -Subject (
                'Terminal preparation nonAuthorityResidualObjectIds')
        $canonical = [ordered]@{
            operationId = $operationId
            resultId = $resultId
            verifiedUtc = $verifiedUtc
            productWriterCount = $productWriterCount
            nonAuthorityResidualObjectIds = $residualObjectIds
        }
        foreach ($field in $booleanFields) {
            $canonical[$field] = Copy-CommMonitorSchemaBoolean `
                -Value $data[$field] `
                -Subject "Terminal preparation residual $field"
        }
        return $canonical
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Terminal preparation schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Terminal preparation semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorTerminalPreparationSchemaError `
            -Message $_.Exception.Message
    }
}

function Get-CommMonitorTerminalPreparationCapabilityRecord {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $Capability,
        [switch] $IncludeConsumed
    )

    if ($null -eq $Capability) { return $null }
    $record = $null
    if (-not $script:CommMonitorTerminalPreparationCapabilities.TryGetValue(
            $Capability,
            [ref]$record)) {
        return $null
    }
    try {
        $snapshot = ConvertTo-CommMonitorCanonicalJson `
            -InputObject $Capability
    }
    catch {
        return $null
    }
    if (-not [string]::Equals(
            [string]$record.Snapshot,
            $snapshot,
            [StringComparison]::Ordinal) -or
        (-not $IncludeConsumed -and [bool]$record.Consumed)) {
        return $null
    }
    return $record
}

function Test-CommMonitorTerminalPreparationCapability {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Capability)

    return $null -ne (
        Get-CommMonitorTerminalPreparationCapabilityRecord `
            -Capability $Capability)
}

function Assert-CommMonitorTerminalPreparationCapabilityBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Capability,
        [Parameter(Mandatory)][string] $ExpectedInstallId,
        [Parameter(Mandatory)][string] $ExpectedOperationId,
        [Parameter(Mandatory)][string] $ExpectedManifestPayloadSha256,
        [Parameter(Mandatory)][string] $AuthorityIdentity,
        [switch] $BindAuthority
    )

    $record = Get-CommMonitorTerminalPreparationCapabilityRecord `
        -Capability $Capability
    if ($null -eq $record) {
        Throw-CommMonitorTerminalPreparationSemanticError `
            -Message (
                'Terminal state requires the original unused preparation capability.')
    }
    if (-not [string]::Equals(
            [string]$record.InstallId,
            $ExpectedInstallId,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$record.OperationId,
            $ExpectedOperationId,
            [StringComparison]::Ordinal) -or
        -not (Test-CommMonitorFixedTimeEquals `
            -LeftHex ([string]$record.ManifestPayloadSha256) `
            -RightHex $ExpectedManifestPayloadSha256)) {
        Throw-CommMonitorTerminalPreparationSemanticError `
            -Message 'Preparation capability does not bind this manifest operation.'
    }
    if ($null -eq $record.BoundAuthorityIdentity) {
        if (-not $BindAuthority) {
            Throw-CommMonitorTerminalPreparationSemanticError `
                -Message 'Preparation capability is not bound to terminal authority.'
        }
        $record.BoundAuthorityIdentity = $AuthorityIdentity
    }
    elseif (-not (Test-CommMonitorFixedTimeEquals `
            -LeftHex ([string]$record.BoundAuthorityIdentity) `
            -RightHex $AuthorityIdentity)) {
        Throw-CommMonitorTerminalPreparationSemanticError `
            -Message 'Preparation capability is already bound to another authority.'
    }
    return $record
}

function New-CommMonitorTerminalPreparationCapability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $CompletedResultEnvelope,
        [Parameter(Mandatory)][object] $ManifestPayload,
        [Parameter(Mandatory)][object] $ManifestPayloadSha256,
        [Parameter(Mandatory)][byte[]] $ManifestKey,
        [Parameter(Mandatory)][object] $ResidualObservation
    )

    try {
        $manifestHash = Copy-CommMonitorSchemaString `
            -Value $ManifestPayloadSha256 `
            -Subject 'Terminal preparation manifest payloadSha256'
        $result = Assert-CommMonitorUninstallResultEnvelope `
            -Envelope $CompletedResultEnvelope `
            -ExpectedManifestPayload $ManifestPayload `
            -ExpectedManifestPayloadSha256 $manifestHash `
            -Key $ManifestKey
        if (-not [string]::Equals(
                [string]$result.status,
                'Completed',
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorTerminalPreparationSemanticError `
                -Message 'Terminal preparation requires a Completed result.'
        }
        $residual =
            ConvertTo-CommMonitorCanonicalTerminalResidualObservation `
                -Observation $ResidualObservation
        if (-not [string]::Equals(
                [string]$residual.operationId,
                [string]$result.operationId,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$residual.resultId,
                [string]$result.resultId,
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorTerminalPreparationSemanticError `
                -Message 'Residual verification does not bind the completed result.'
        }
        if ([string]::CompareOrdinal(
                [string]$residual.verifiedUtc,
                [string]$result.createdUtc) -lt 0) {
            Throw-CommMonitorTerminalPreparationSemanticError `
                -Message 'Residual verification predates the completed result.'
        }
        $presenceFields = [string[]]@(
            'uninstallEntryPresent', 'continuationTaskPresent',
            'appRootPresent', 'dataRootPresent', 'aiRootPresent',
            'coreNonAuthorityPresent', 'installerNonAuthorityPresent')
        $unsafePresence = $false
        foreach ($field in $presenceFields) {
            if ([bool]$residual[$field]) {
                $unsafePresence = $true
                break
            }
        }
        if ([int]$residual.productWriterCount -ne 0 -or
            @($residual.nonAuthorityResidualObjectIds).Count -ne 0 -or
            $unsafePresence) {
            Throw-CommMonitorTerminalPreparationSemanticError `
                -Message 'Non-authority product state remains after uninstall execution.'
        }
        $envelopeData = ConvertTo-CommMonitorSchemaObject `
            -Value $CompletedResultEnvelope `
            -Subject 'Terminal preparation completed result envelope'
        $integrity = ConvertTo-CommMonitorSchemaObject `
            -Value $envelopeData.integrity `
            -Subject 'Terminal preparation completed result integrity'
        $normalizedEnvelope = [ordered]@{
            integrity = [ordered]@{
                algorithm = [string]$integrity.algorithm
                keyId = [string]$integrity.keyId
                payloadSha256 = [string]$integrity.payloadSha256
                tag = [string]$integrity.tag
            }
            payload = $result
            schemaVersion = 1
        }
        $resultEnvelopeHash = Get-CommMonitorSha256Hex -Bytes (
            Get-CommMonitorCanonicalJsonBytes -InputObject $normalizedEnvelope)
        $residualHash = Get-CommMonitorSha256Hex -Bytes (
            Get-CommMonitorCanonicalJsonBytes -InputObject $residual)
        $capability = [pscustomobject][ordered]@{
            schemaVersion = 1
            capabilityId =
                [Guid]::NewGuid().ToString('D').ToLowerInvariant()
            installId = [string]$result.installId
            operationId = [string]$result.operationId
            resultId = [string]$result.resultId
            resultEnvelopeSha256 = $resultEnvelopeHash
            manifestPayloadSha256 = $manifestHash
            residualEvidenceSha256 = $residualHash
        }
        $record = [pscustomobject]@{
            Snapshot = ConvertTo-CommMonitorCanonicalJson `
                -InputObject $capability
            InstallId = [string]$capability.installId
            OperationId = [string]$capability.operationId
            ResultId = [string]$capability.resultId
            ResultEnvelopeSha256 = $resultEnvelopeHash
            ManifestPayloadSha256 = $manifestHash
            ResidualEvidenceSha256 = $residualHash
            BoundAuthorityIdentity = $null
            Consumed = $false
        }
        $script:CommMonitorTerminalPreparationCapabilities.Add(
            $capability,
            $record)
        return $capability
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Terminal preparation schema:',
                [StringComparison]::Ordinal) -or
            $_.Exception.Message.StartsWith(
                'Terminal preparation semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorTerminalPreparationSemanticError `
            -Message $_.Exception.Message
    }
}

function Update-CommMonitorOwnershipStateCas {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $CurrentEnvelope,
        [Parameter(Mandatory)][object] $CurrentAnchor,
        [Parameter(Mandatory)][AllowNull()][object] $ExpectedRevision,
        [Parameter(Mandatory)][AllowNull()][object] $ExpectedPayloadSha256,
        [Parameter(Mandatory)][object] $NextPayload,
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][string] $KeyId
    )

    $expectedRevisionValue = Copy-CommMonitorSchemaInt32 `
        -Value $ExpectedRevision `
        -Subject 'ExpectedRevision'
    $expectedPayloadSha256Value = Copy-CommMonitorSchemaString `
        -Value $ExpectedPayloadSha256 `
        -Subject 'ExpectedPayloadSha256'
    Assert-CommMonitorHash `
        -Value $expectedPayloadSha256Value `
        -Length 64 `
        -Name expectedPayloadSha256
    $currentEnvelopeData = ConvertTo-CommMonitorOrderedDictionary -InputObject $CurrentEnvelope
    $currentPayload = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $currentEnvelopeData.payload
    [void](Assert-CommMonitorOwnershipState `
            -Envelope $CurrentEnvelope `
            -Anchor $CurrentAnchor `
            -Key $Key `
            -ExpectedManifestPath $ManifestPath `
            -ExpectedAppId ([string]$currentPayload.appId) `
            -ExpectedInstallId ([string]$currentPayload.installId))
    $currentIntegrity = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $currentEnvelopeData.integrity
    if ([int]$currentPayload.revision -ne $expectedRevisionValue -or
        -not [string]::Equals(
            [string]$currentIntegrity.payloadSha256,
            $expectedPayloadSha256Value,
            [StringComparison]::Ordinal)) {
        throw 'Ownership CAS expected revision or payload hash is stale.'
    }

    $next = ConvertTo-CommMonitorCanonicalOwnershipPayload -Payload $NextPayload
    $next.revision = $expectedRevisionValue + 1
    $next.previousPayloadSha256 = $expectedPayloadSha256Value
    $newEnvelope = New-CommMonitorOwnershipEnvelope `
        -Payload $next `
        -Key $Key `
        -KeyId $KeyId
    $newAnchor = New-CommMonitorOwnershipAnchor `
        -Payload $next `
        -PayloadSha256 $newEnvelope.integrity.payloadSha256 `
        -ManifestPath $ManifestPath `
        -Key $Key `
        -KeyId $KeyId
    return [pscustomobject]@{
        Envelope = $newEnvelope
        Anchor = $newAnchor
    }
}

function Set-CommMonitorStateFileAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path
    )

    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetOwner($administrators)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($administrators, $system)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $identity,
                [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Write-CommMonitorAtomicStateFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $LiteralPath,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Value,
        [scriptblock] $SetStrictAclScript,
        [scriptblock] $VerifyScript,
        [ValidateSet(
            'None', 'AfterCreate', 'AfterFlush', 'BeforeReplace',
            'AfterReplace', 'Verify')]
        [string] $FaultStage = 'None'
    )

    $fullPath = [IO.Path]::GetFullPath($LiteralPath)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    Assert-CommMonitorTrustedDirectory -Path $directory
    $temporaryPath = Join-Path $directory (
        '.{0}.{1}.tmp' -f [IO.Path]::GetFileName($fullPath), [Guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $directory (
        '.{0}.{1}.bak' -f [IO.Path]::GetFileName($fullPath), [Guid]::NewGuid().ToString('N'))
    $restoreDiscardPath = Join-Path $directory (
        '.{0}.{1}.discard' -f [IO.Path]::GetFileName($fullPath), [Guid]::NewGuid().ToString('N'))
    $stream = $null
    $writer = $null
    $targetExisted = [IO.File]::Exists($fullPath)
    $replaced = $false
    try {
        $stream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough)
        if ($null -ne $SetStrictAclScript) {
            & $SetStrictAclScript $temporaryPath
        }
        else {
            Set-CommMonitorStateFileAcl -Path $temporaryPath
        }
        if ($FaultStage -eq 'AfterCreate') {
            throw 'Injected atomic state fault after create.'
        }
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer.Write($Value)
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose()
        $writer = $null
        $stream = $null
        if ($FaultStage -eq 'AfterFlush') {
            throw 'Injected atomic state fault after flush.'
        }
        if ($FaultStage -eq 'BeforeReplace') {
            throw 'Injected atomic state fault before replace.'
        }
        if ($targetExisted) {
            $target = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            if (Test-CommMonitorReparseAttributes -Attributes $target.Attributes) {
                throw "Refusing to replace reparse-point state file '$fullPath'."
            }
            [IO.File]::Replace($temporaryPath, $fullPath, $backupPath, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $fullPath)
        }
        $replaced = $true
        if ($FaultStage -eq 'AfterReplace') {
            throw 'Injected atomic state fault after replace.'
        }
        $actualBytes = [IO.File]::ReadAllBytes($fullPath)
        $expectedBytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
        $bytesMatch = $actualBytes.Length -eq $expectedBytes.Length
        if ($bytesMatch) {
            for ($byteIndex = 0; $byteIndex -lt $actualBytes.Length; $byteIndex++) {
                if ($actualBytes[$byteIndex] -ne $expectedBytes[$byteIndex]) {
                    $bytesMatch = $false
                    break
                }
            }
        }
        if (-not $bytesMatch) {
            throw 'Atomic state file reopen verification failed.'
        }
        if ($null -ne $VerifyScript) {
            & $VerifyScript $fullPath
        }
        if ($FaultStage -eq 'Verify') {
            throw 'Injected atomic state fault during verification.'
        }
        $replaced = $false
    }
    catch {
        if ($replaced) {
            if ($targetExisted -and [IO.File]::Exists($backupPath)) {
                [IO.File]::Replace(
                    $backupPath,
                    $fullPath,
                    $restoreDiscardPath,
                    $true)
            }
            elseif (-not $targetExisted -and [IO.File]::Exists($fullPath)) {
                [IO.File]::Delete($fullPath)
            }
        }
        throw
    }
    finally {
        if ($null -ne $writer) {
            $writer.Dispose()
        }
        elseif ($null -ne $stream) {
            $stream.Dispose()
        }
        foreach ($cleanupPath in @(
                $temporaryPath,
                $backupPath,
                $restoreDiscardPath)) {
            if ([IO.File]::Exists($cleanupPath)) {
                [IO.File]::Delete($cleanupPath)
            }
        }
    }
}

function ConvertTo-CommMonitorOrderedDictionary {
    [CmdletBinding()]
    [OutputType([Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object] $InputObject
    )

    $result = [Collections.Specialized.OrderedDictionary]::new(
        [StringComparer]::Ordinal)
    $exactNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $foldedNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    if ($InputObject -is [Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ($key -isnot [string]) {
                throw 'Dictionary field names must be raw strings.'
            }
            $name = [string]$key
            if (-not $exactNames.Add($name)) {
                throw "Dictionary contains duplicate field '$name'."
            }
            if (-not $foldedNames.Add($name)) {
                throw "Dictionary contains case-confused field '$name'."
            }
            $result.Add($name, $InputObject[$key])
        }
    }
    else {
        foreach ($property in $InputObject.PSObject.Properties) {
            if ($property.MemberType -in @('NoteProperty', 'Property')) {
                $name = [string]$property.Name
                if (-not $exactNames.Add($name)) {
                    throw "Object contains duplicate field '$name'."
                }
                if (-not $foldedNames.Add($name)) {
                    throw "Object contains case-confused field '$name'."
                }
                $result.Add($name, $property.Value)
            }
            else {
                throw (("Object contains unsupported property member type '{0}' " +
                    "for field '{1}'.") -f $property.MemberType, $property.Name)
            }
        }
    }
    return $result
}

function Assert-CommMonitorExactFields {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Dictionary,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Allowed,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Required,
        [Parameter(Mandatory)][string] $Subject
    )

    $allowedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $foldedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Allowed) {
        [void]$allowedSet.Add($name)
        [void]$foldedSet.Add($name)
    }
    foreach ($key in $Dictionary.Keys) {
        $name = [string]$key
        if (-not $allowedSet.Contains($name)) {
            if ($foldedSet.Contains($name)) {
                throw "$Subject contains case-confused field '$name'."
            }
            throw "$Subject contains unknown field '$name'."
        }
    }
    foreach ($name in $Required) {
        if (-not $Dictionary.Contains($name)) {
            throw "$Subject is missing required field '$name'."
        }
    }
}

function Test-CommMonitorOrdinalValue {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string[]] $Allowed
    )

    foreach ($candidate in $Allowed) {
        if ([string]::Equals(
                [string]$Value,
                $candidate,
                [StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function Test-CommMonitorRawSchemaObject {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object] $Value)

    return $Value -is [Collections.IDictionary] -or
        $Value -is [pscustomobject]
}

function ConvertTo-CommMonitorSchemaObject {
    [CmdletBinding()]
    [OutputType([Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Subject
    )

    if (-not (Test-CommMonitorRawSchemaObject -Value $Value)) {
        throw "$Subject must be a raw object."
    }
    return ConvertTo-CommMonitorOrderedDictionary -InputObject $Value
}

function Copy-CommMonitorSchemaString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Subject
    )

    if ($Value -isnot [string]) {
        throw "$Subject must be a raw string."
    }
    return [string]$Value
}

function Copy-CommMonitorNullableSchemaString {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Subject
    )

    if ($null -eq $Value) {
        return $null
    }
    return Copy-CommMonitorSchemaString -Value $Value -Subject $Subject
}

function Copy-CommMonitorSchemaBoolean {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Subject
    )

    if ($Value -isnot [bool]) {
        throw "$Subject must be a raw Boolean."
    }
    return [bool]$Value
}

function Copy-CommMonitorSchemaInt32 {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Subject
    )

    if ($Value -isnot [int]) {
        throw "$Subject must be a raw Int32."
    }
    return [int]$Value
}

function Copy-CommMonitorSchemaInt64 {
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Subject
    )

    if ($Value -isnot [int] -and $Value -isnot [long]) {
        throw "$Subject must be a raw Int32 or Int64."
    }
    return [long]$Value
}

function Assert-CommMonitorRawSchemaArray {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Subject
    )

    if ($Value -isnot [Array]) {
        throw "$Subject must be a raw System.Array."
    }
}

function Copy-CommMonitorSchemaStringArray {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Subject
    )

    Assert-CommMonitorRawSchemaArray -Value $Value -Subject $Subject
    $items = [Collections.Generic.List[string]]::new()
    foreach ($item in $Value) {
        if ($item -isnot [string]) {
            throw "$Subject members must be raw strings."
        }
        $items.Add([string]$item)
    }
    Write-Output -NoEnumerate ([string[]]$items.ToArray())
}

function Copy-CommMonitorCanonicalStringSet {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Subject
    )

    $items = Copy-CommMonitorSchemaStringArray `
        -Value $Value `
        -Subject $Subject
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($item in $items) {
        if (-not $seen.Add([string]$item)) {
            throw "$Subject canonical set contains duplicate '$item'."
        }
    }
    $copy = [string[]]@($items)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    Write-Output -NoEnumerate $copy
}

function Assert-CommMonitorRawByteArray {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Subject
    )

    if ($Value -isnot [byte[]]) {
        throw "$Subject must be a raw Byte array."
    }
}

function Copy-CommMonitorManifestSchemaValue {
    [CmdletBinding()]
    param([AllowNull()][object] $Value)

    if ($null -eq $Value -or
        $Value -is [string] -or
        $Value.GetType().IsValueType) {
        return $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        $source = ConvertTo-CommMonitorOrderedDictionary -InputObject $Value
        $copy = [Collections.Specialized.OrderedDictionary]::new(
            [StringComparer]::Ordinal)
        foreach ($key in $source.Keys) {
            $copy.Add(
                [string]$key,
                (Copy-CommMonitorManifestSchemaValue -Value $source[$key]))
        }
        return $copy
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((Copy-CommMonitorManifestSchemaValue -Value $item))
        }
        $array = [object[]]$items.ToArray()
        Write-Output -NoEnumerate $array
        return
    }

    $source = ConvertTo-CommMonitorOrderedDictionary -InputObject $Value
    $copy = [Collections.Specialized.OrderedDictionary]::new(
        [StringComparer]::Ordinal)
    foreach ($key in $source.Keys) {
        $copy.Add(
            [string]$key,
            (Copy-CommMonitorManifestSchemaValue -Value $source[$key]))
    }
    return $copy
}

function ConvertTo-CommMonitorCanonicalAclProfile {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $Profile,
        [Parameter(Mandatory)][string] $Subject,
        [Parameter(Mandatory)]
        [ValidateSet('Resolver', 'Canonical')]
        [string] $InputCasing,
        [bool] $AllowNull = $true
    )

    if ($null -eq $Profile) {
        if (-not $AllowNull) {
            throw "$Subject must be a raw object."
        }
        return $null
    }
    $data = ConvertTo-CommMonitorSchemaObject -Value $Profile -Subject $Subject
    $fields = if ($InputCasing -eq 'Resolver') {
        @(
            'OwnerSid', 'AreAccessRulesProtected', 'AllowedFullControlSids',
            'DenyRuleCount', 'UsersWritable')
    }
    else {
        @(
            'ownerSid', 'areAccessRulesProtected', 'allowedFullControlSids',
            'denyRuleCount', 'usersWritable')
    }
    Assert-CommMonitorExactFields `
        -Dictionary $data `
        -Allowed $fields `
        -Required $fields `
        -Subject $Subject
    $ownerField = if ($InputCasing -eq 'Resolver') { 'OwnerSid' } else { 'ownerSid' }
    $protectedField = if ($InputCasing -eq 'Resolver') {
        'AreAccessRulesProtected'
    }
    else {
        'areAccessRulesProtected'
    }
    $allowedField = if ($InputCasing -eq 'Resolver') {
        'AllowedFullControlSids'
    }
    else {
        'allowedFullControlSids'
    }
    $denyField = if ($InputCasing -eq 'Resolver') { 'DenyRuleCount' } else { 'denyRuleCount' }
    $writableField = if ($InputCasing -eq 'Resolver') { 'UsersWritable' } else { 'usersWritable' }
    return [ordered]@{
        ownerSid = Copy-CommMonitorSchemaString `
            -Value $data[$ownerField] `
            -Subject "$Subject ownerSid"
        areAccessRulesProtected = Copy-CommMonitorSchemaBoolean `
            -Value $data[$protectedField] `
            -Subject "$Subject areAccessRulesProtected"
        allowedFullControlSids = Copy-CommMonitorCanonicalStringSet `
            -Value $data[$allowedField] `
            -Subject "$Subject allowedFullControlSids"
        denyRuleCount = Copy-CommMonitorSchemaInt32 `
            -Value $data[$denyField] `
            -Subject "$Subject denyRuleCount"
        usersWritable = Copy-CommMonitorSchemaBoolean `
            -Value $data[$writableField] `
            -Subject "$Subject usersWritable"
    }
}

function ConvertTo-CommMonitorCanonicalAdoptionSource {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $Source,
        [Parameter(Mandatory)][string] $Subject,
        [bool] $AllowNull = $true
    )

    if ($null -eq $Source) {
        if (-not $AllowNull) {
            throw "$Subject must be a raw object."
        }
        return $null
    }
    $data = ConvertTo-CommMonitorSchemaObject -Value $Source -Subject $Subject
    if (-not $data.Contains('sourceKind')) {
        throw "$Subject is missing required field 'sourceKind'."
    }
    $sourceKind = Copy-CommMonitorSchemaString `
        -Value $data['sourceKind'] `
        -Subject "$Subject sourceKind"
    $fields = switch -CaseSensitive ($sourceKind) {
        'ValidatedLegacyMarker' {
            @(
                'schemaVersion', 'sourceKind', 'capabilityId', 'providerEpoch',
                'markerId', 'markerDigest', 'canonicalPath',
                'volumeSerialNumber', 'fileId', 'aclProfile', 'ownershipProof')
        }
        'AuthenticatedManifestV3' {
            @(
                'schemaVersion', 'sourceKind', 'sourceInstallId',
                'sourcePayloadSha256', 'canonicalPath', 'volumeSerialNumber',
                'fileId', 'aclProfile', 'ownershipProof')
        }
        default { throw "$Subject has an unknown sourceKind." }
    }
    $fields = [string[]]@($fields)
    Assert-CommMonitorExactFields `
        -Dictionary $data `
        -Allowed $fields `
        -Required $fields `
        -Subject $Subject
    $ownershipProof = Copy-CommMonitorSchemaString `
        -Value $data['ownershipProof'] `
        -Subject "$Subject ownershipProof"
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $ownershipProof `
            -Allowed @('VerifiedLegacyAdoption'))) {
        throw "$Subject has an invalid ownershipProof."
    }
    $copy = [ordered]@{}
    foreach ($field in $fields) {
        if ($field -eq 'aclProfile') {
            $copy[$field] = ConvertTo-CommMonitorCanonicalAclProfile `
                -Profile $data[$field] `
                -Subject "$Subject ACL profile" `
                -InputCasing Canonical `
                -AllowNull:$false
        }
        elseif ($field -eq 'schemaVersion') {
            $copy[$field] = Copy-CommMonitorSchemaInt32 `
                -Value $data[$field] `
                -Subject "$Subject schemaVersion"
        }
        else {
            $copy[$field] = Copy-CommMonitorSchemaString `
                -Value $data[$field] `
                -Subject "$Subject $field"
        }
    }
    return $copy
}

function ConvertTo-CommMonitorCanonicalRootRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Record,
        [Parameter(Mandatory)][string] $RoleName,
        [Parameter(Mandatory)]
        [ValidateSet('Resolver', 'Canonical')]
        [string] $InputCasing
    )

    $data = ConvertTo-CommMonitorSchemaObject `
        -Value $Record `
        -Subject "$RoleName record"
    $resolverFields = @(
        'Role', 'CanonicalPath', 'Active', 'Present', 'CreatedByInstall',
        'VolumeSerialNumber', 'FileId', 'AclProfile', 'PhysicalCandidatePath',
        'OwnershipProof', 'AdoptionSource', 'ContentPolicy')
    $canonicalFields = @(
        'role', 'canonicalPath', 'active', 'present', 'createdByInstall',
        'volumeSerialNumber', 'fileId', 'aclProfile', 'physicalCandidatePath',
        'ownershipProof', 'adoptionSource', 'contentPolicy')
    $fields = if ($InputCasing -eq 'Resolver') {
        $resolverFields
    }
    else {
        $canonicalFields
    }
    Assert-CommMonitorExactFields `
        -Dictionary $data `
        -Allowed $fields `
        -Required $fields `
        -Subject "$RoleName record"

    $roleField = if ($InputCasing -eq 'Resolver') { 'Role' } else { 'role' }
    $contentPolicyField = if ($InputCasing -eq 'Resolver') {
        'ContentPolicy'
    }
    else {
        'contentPolicy'
    }
    $ownershipProofField = if ($InputCasing -eq 'Resolver') {
        'OwnershipProof'
    }
    else {
        'ownershipProof'
    }
    $roleValue = Copy-CommMonitorSchemaString `
        -Value $data[$roleField] `
        -Subject "$RoleName record role"
    $contentPolicyValue = Copy-CommMonitorSchemaString `
        -Value $data[$contentPolicyField] `
        -Subject "$RoleName record contentPolicy"
    $ownershipProofValue = Copy-CommMonitorNullableSchemaString `
        -Value $data[$ownershipProofField] `
        -Subject "$RoleName record ownershipProof"
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $roleValue `
            -Allowed @(
                'AppRoot', 'CoreRoot', 'DataRoot',
                'InstallerRoot', 'AiStateRoot'))) {
        throw "$RoleName record has an invalid role."
    }
    if (-not [string]::Equals(
            $roleValue,
            $RoleName,
            [StringComparison]::Ordinal)) {
        throw "$RoleName record role must be exactly '$RoleName'."
    }
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $contentPolicyValue `
            -Allowed @('EmptyAfterOwnedChildren', 'ProtectedManagedTree'))) {
        throw "$RoleName record has an invalid contentPolicy."
    }
    if ($null -ne $ownershipProofValue -and
        -not (Test-CommMonitorOrdinalValue `
            -Value $ownershipProofValue `
            -Allowed @(
                'CreatedThisInstall',
                'VerifiedLegacyAdoption',
                'PreExistingShared'))) {
        throw "$RoleName record has an invalid ownershipProof."
    }

    $copy = [ordered]@{}
    for ($index = 0; $index -lt $canonicalFields.Count; $index++) {
        $sourceName = if ($InputCasing -eq 'Resolver') {
            $resolverFields[$index]
        }
        else {
            $canonicalFields[$index]
        }
        $targetName = $canonicalFields[$index]
        switch ($targetName) {
            'role' { $copy[$targetName] = $roleValue }
            'canonicalPath' {
                $copy[$targetName] = Copy-CommMonitorSchemaString `
                    -Value $data[$sourceName] `
                    -Subject "$RoleName record canonicalPath"
            }
            { $_ -in @('active', 'present', 'createdByInstall') } {
                $copy[$targetName] = Copy-CommMonitorSchemaBoolean `
                    -Value $data[$sourceName] `
                    -Subject "$RoleName record $targetName"
            }
            { $_ -in @('volumeSerialNumber', 'fileId', 'physicalCandidatePath') } {
                $copy[$targetName] = Copy-CommMonitorNullableSchemaString `
                    -Value $data[$sourceName] `
                    -Subject "$RoleName record $targetName"
            }
            'aclProfile' {
                $copy[$targetName] = ConvertTo-CommMonitorCanonicalAclProfile `
                    -Profile $data[$sourceName] `
                    -Subject "$RoleName ACL profile" `
                    -InputCasing $InputCasing
            }
            'ownershipProof' { $copy[$targetName] = $ownershipProofValue }
            'adoptionSource' {
                $copy[$targetName] = ConvertTo-CommMonitorCanonicalAdoptionSource `
                    -Source $data[$sourceName] `
                    -Subject "$RoleName adoption source"
            }
            'contentPolicy' { $copy[$targetName] = $contentPolicyValue }
        }
    }
    return $copy
}

function ConvertTo-CommMonitorCanonicalOwnershipRoots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Roots,
        [Parameter(Mandatory)]
        [ValidateSet('Resolver', 'Canonical')]
        [string] $InputCasing
    )

    $data = ConvertTo-CommMonitorSchemaObject `
        -Value $Roots `
        -Subject 'Ownership roots'
    $mappings = @(
        [pscustomobject]@{ Resolver = 'AppRoot'; Canonical = 'appRoot' },
        [pscustomobject]@{ Resolver = 'CoreRoot'; Canonical = 'coreRoot' },
        [pscustomobject]@{ Resolver = 'DataRoot'; Canonical = 'dataRoot' },
        [pscustomobject]@{ Resolver = 'InstallerRoot'; Canonical = 'installerRoot' },
        [pscustomobject]@{ Resolver = 'AiStateRoot'; Canonical = 'aiStateRoot' })
    $fields = [string[]]@($mappings | ForEach-Object {
            if ($InputCasing -eq 'Resolver') { $_.Resolver } else { $_.Canonical }
        })
    Assert-CommMonitorExactFields `
        -Dictionary $data `
        -Allowed $fields `
        -Required $fields `
        -Subject 'Ownership roots'
    $copy = [ordered]@{}
    foreach ($mapping in $mappings) {
        $sourceName = if ($InputCasing -eq 'Resolver') {
            $mapping.Resolver
        }
        else {
            $mapping.Canonical
        }
        $copy[$mapping.Canonical] = ConvertTo-CommMonitorCanonicalRootRecord `
            -Record $data[$sourceName] `
            -RoleName $mapping.Resolver `
            -InputCasing $InputCasing
    }
    return $copy
}

function Throw-CommMonitorOwnershipRootSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Ownership root semantics: $Message"
}

function Test-CommMonitorCanonicalAclProfileEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][object] $Left,
        [Parameter(Mandatory)][object] $Right
    )

    $leftAcl = ConvertTo-CommMonitorOrderedDictionary -InputObject $Left
    $rightAcl = ConvertTo-CommMonitorOrderedDictionary -InputObject $Right
    foreach ($field in @(
            'ownerSid', 'areAccessRulesProtected', 'denyRuleCount',
            'usersWritable')) {
        if (-not [object]::Equals($leftAcl[$field], $rightAcl[$field])) {
            return $false
        }
    }
    $leftSids = [object[]]@($leftAcl.allowedFullControlSids)
    $rightSids = [object[]]@($rightAcl.allowedFullControlSids)
    if ($leftSids.Count -ne $rightSids.Count) {
        return $false
    }
    for ($index = 0; $index -lt $leftSids.Count; $index++) {
        if (-not [string]::Equals(
                [string]$leftSids[$index],
                [string]$rightSids[$index],
                [StringComparison]::Ordinal)) {
            return $false
        }
    }
    return $true
}

function Assert-CommMonitorOwnershipRootSemantics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PlatformKind,
        [Parameter(Mandatory)][object] $Roots,
        [Parameter(Mandatory)][object] $AuthorizedUser
    )

    $rootData = ConvertTo-CommMonitorOrderedDictionary -InputObject $Roots
    $authorizedUserData = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $AuthorizedUser
    $rootSlots = @(
        [pscustomobject]@{ Slot = 'appRoot'; Role = 'AppRoot' },
        [pscustomobject]@{ Slot = 'coreRoot'; Role = 'CoreRoot' },
        [pscustomobject]@{ Slot = 'dataRoot'; Role = 'DataRoot' },
        [pscustomobject]@{ Slot = 'installerRoot'; Role = 'InstallerRoot' },
        [pscustomobject]@{ Slot = 'aiStateRoot'; Role = 'AiStateRoot' })
    $canonicalPaths = [Collections.Generic.List[object]]::new()
    $physicalPaths = [Collections.Generic.List[object]]::new()

    foreach ($slotRecord in $rootSlots) {
        $slot = [string]$slotRecord.Slot
        $role = [string]$slotRecord.Role
        $root = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $rootData[$slot]
        $expectedActive = -not (
            [string]::Equals(
                $PlatformKind,
                'ServerCore',
                [StringComparison]::Ordinal) -and
            [string]::Equals(
                $role,
                'AppRoot',
                [StringComparison]::Ordinal))
        if ([bool]$root.active -ne $expectedActive) {
            Throw-CommMonitorOwnershipRootSemanticError `
                -Message "$role active flag conflicts with platform '$PlatformKind'."
        }

        try {
            $canonicalPath = ConvertTo-CommMonitorCanonicalWindowsPath `
                -Path ([string]$root.canonicalPath) `
                -Role "$role canonical path"
        }
        catch {
            Throw-CommMonitorOwnershipRootSemanticError `
                -Message "$role canonical path is unsafe."
        }
        if (-not [string]::Equals(
                $canonicalPath,
                [string]$root.canonicalPath,
                [StringComparison]::OrdinalIgnoreCase)) {
            Throw-CommMonitorOwnershipRootSemanticError `
                -Message "$role canonical path is not canonical."
        }
        $canonicalPaths.Add([pscustomobject]@{
                Role = $role
                Path = $canonicalPath
            })

        if (-not $expectedActive) {
            if ([bool]$root.present -or
                [bool]$root.createdByInstall -or
                $null -ne $root.volumeSerialNumber -or
                $null -ne $root.fileId -or
                $null -ne $root.aclProfile -or
                $null -ne $root.physicalCandidatePath -or
                $null -ne $root.ownershipProof -or
                $null -ne $root.adoptionSource -or
                -not [string]::Equals(
                    [string]$root.contentPolicy,
                    'EmptyAfterOwnedChildren',
                    [StringComparison]::Ordinal)) {
                Throw-CommMonitorOwnershipRootSemanticError `
                    -Message "$role inactive tuple contains active evidence."
            }
            continue
        }

        if (-not [bool]$root.present -or
            $null -eq $root.aclProfile -or
            $null -eq $root.physicalCandidatePath -or
            $null -eq $root.ownershipProof) {
            Throw-CommMonitorOwnershipRootSemanticError `
                -Message "$role active tuple omits required identity evidence."
        }
        if (-not [regex]::IsMatch(
                [string]$root.volumeSerialNumber,
                '^[0-9a-f]{16}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [regex]::IsMatch(
                [string]$root.fileId,
                '^[0-9a-f]{32}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            Throw-CommMonitorOwnershipRootSemanticError `
                -Message "$role active tuple has a noncanonical volume or file identity."
        }

        try {
            $physicalPath = ConvertTo-CommMonitorCanonicalWindowsPath `
                -Path ([string]$root.physicalCandidatePath) `
                -Role "$role physical path"
        }
        catch {
            Throw-CommMonitorOwnershipRootSemanticError `
                -Message "$role physical path is unsafe."
        }
        if (-not [string]::Equals(
                $physicalPath,
                [string]$root.physicalCandidatePath,
                [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals(
                $physicalPath,
                $canonicalPath,
                [StringComparison]::OrdinalIgnoreCase)) {
            Throw-CommMonitorOwnershipRootSemanticError `
                -Message "$role canonical and physical identities differ."
        }
        $physicalPaths.Add([pscustomobject]@{
                Role = $role
                Path = $physicalPath
            })

        $acl = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $root.aclProfile
        if (-not [bool]$acl.areAccessRulesProtected -or
            [bool]$acl.usersWritable -or
            [int]$acl.denyRuleCount -ne 0) {
            Throw-CommMonitorOwnershipRootSemanticError `
                -Message "$role ACL is not protected."
        }
        $allowedSids = [string[]]@($acl.allowedFullControlSids)
        if ([string]::Equals(
                $role,
                'AiStateRoot',
                [StringComparison]::Ordinal)) {
            $requiredAiSids = @(
                'S-1-5-18',
                'S-1-5-32-544',
                [string]$authorizedUserData.sid)
            if ($allowedSids.Count -ne $requiredAiSids.Count) {
                Throw-CommMonitorOwnershipRootSemanticError `
                    -Message 'AiStateRoot ACL has an unexpected principal count.'
            }
            foreach ($requiredSid in $requiredAiSids) {
                if (-not ($allowedSids -ccontains $requiredSid)) {
                    Throw-CommMonitorOwnershipRootSemanticError `
                        -Message 'AiStateRoot ACL omits a required principal.'
                }
            }
        }
        else {
            if ($allowedSids.Count -ne 2 -or
                -not ($allowedSids -ccontains 'S-1-5-18') -or
                -not ($allowedSids -ccontains 'S-1-5-32-544') -or
                [string]$acl.ownerSid -notin @('S-1-5-18', 'S-1-5-32-544')) {
                Throw-CommMonitorOwnershipRootSemanticError `
                    -Message "$role ACL grants an unexpected principal."
            }
        }

        $proof = [string]$root.ownershipProof
        switch -CaseSensitive ($proof) {
            'CreatedThisInstall' {
                if (-not [bool]$root.createdByInstall -or
                    $null -ne $root.adoptionSource) {
                    Throw-CommMonitorOwnershipRootSemanticError `
                        -Message "$role CreatedThisInstall evidence is inconsistent."
                }
            }
            'PreExistingShared' {
                if ([bool]$root.createdByInstall -or
                    $null -ne $root.adoptionSource) {
                    Throw-CommMonitorOwnershipRootSemanticError `
                        -Message "$role PreExistingShared evidence is inconsistent."
                }
            }
            'VerifiedLegacyAdoption' {
                if (-not [string]::Equals(
                        $role,
                        'DataRoot',
                        [StringComparison]::Ordinal) -or
                    [bool]$root.createdByInstall -or
                    $null -eq $root.adoptionSource) {
                    Throw-CommMonitorOwnershipRootSemanticError `
                        -Message "$role VerifiedLegacyAdoption evidence is inconsistent."
                }
                $source = ConvertTo-CommMonitorOrderedDictionary `
                    -InputObject $root.adoptionSource
                if (-not [string]::Equals(
                        [string]$source.canonicalPath,
                        $canonicalPath,
                        [StringComparison]::OrdinalIgnoreCase) -or
                    -not [string]::Equals(
                        [string]$source.volumeSerialNumber,
                        [string]$root.volumeSerialNumber,
                        [StringComparison]::Ordinal) -or
                    -not [string]::Equals(
                        [string]$source.fileId,
                        [string]$root.fileId,
                        [StringComparison]::Ordinal) -or
                    -not [string]::Equals(
                        [string]$source.ownershipProof,
                        $proof,
                        [StringComparison]::Ordinal) -or
                    -not (Test-CommMonitorCanonicalAclProfileEqual `
                        -Left $root.aclProfile `
                        -Right $source.aclProfile)) {
                    Throw-CommMonitorOwnershipRootSemanticError `
                        -Message 'DataRoot adoption source does not match the active identity.'
                }
            }
            default {
                Throw-CommMonitorOwnershipRootSemanticError `
                    -Message "$role has an unsupported active ownership proof."
            }
        }

        $expectedContentPolicy = if ([string]::Equals(
                $role,
                'DataRoot',
                [StringComparison]::Ordinal)) {
            'ProtectedManagedTree'
        }
        else {
            'EmptyAfterOwnedChildren'
        }
        if (-not [string]::Equals(
                [string]$root.contentPolicy,
                $expectedContentPolicy,
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorOwnershipRootSemanticError `
                -Message "$role has an invalid content policy."
        }
    }

    try {
        $authorizedAiRoot = ConvertTo-CommMonitorCanonicalWindowsPath `
            -Path ([string]$authorizedUserData.aiRoot) `
            -Role 'Authorized user AI root'
    }
    catch {
        Throw-CommMonitorOwnershipRootSemanticError `
            -Message 'Authorized user AI root is unsafe.'
    }
    if (-not [string]::Equals(
            $authorizedAiRoot,
            [string]$authorizedUserData.aiRoot,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            $authorizedAiRoot,
            [string]$rootData.aiStateRoot.canonicalPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CommMonitorOwnershipRootSemanticError `
            -Message 'AiStateRoot is not bound to the authorized user.'
    }

    foreach ($pathSet in @($canonicalPaths, $physicalPaths)) {
        for ($leftIndex = 0; $leftIndex -lt $pathSet.Count; $leftIndex++) {
            for ($rightIndex = $leftIndex + 1;
                $rightIndex -lt $pathSet.Count;
                $rightIndex++) {
                if (Test-CommMonitorPathOverlap `
                        -First ([string]$pathSet[$leftIndex].Path) `
                        -Second ([string]$pathSet[$rightIndex].Path)) {
                    Throw-CommMonitorOwnershipRootSemanticError `
                        -Message ("{0} overlaps {1}." -f
                            [string]$pathSet[$leftIndex].Role,
                            [string]$pathSet[$rightIndex].Role)
                }
            }
        }
    }
}

function Throw-CommMonitorOwnershipLayoutSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Ownership layout semantics: $Message"
}

function Get-CommMonitorCanonicalRootForOwnedRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Roots,
        [Parameter(Mandatory)][string] $RootRole
    )

    $rootData = ConvertTo-CommMonitorOrderedDictionary -InputObject $Roots
    $slot = switch -CaseSensitive ($RootRole) {
        'AppRoot' { 'appRoot' }
        'CoreRoot' { 'coreRoot' }
        'DataRoot' { 'dataRoot' }
        'InstallerRoot' { 'installerRoot' }
        'AiStateRoot' { 'aiStateRoot' }
        default { return $null }
    }
    return ConvertTo-CommMonitorOrderedDictionary -InputObject $rootData[$slot]
}

function Assert-CommMonitorOwnershipLayoutSemantics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PlatformKind,
        [Parameter(Mandatory)][object] $PlatformComponents,
        [Parameter(Mandatory)][object] $Roots,
        [Parameter(Mandatory)][object[]] $OwnedObjects
    )

    try {
        Assert-CommMonitorOwnershipLayout `
            -PlatformKind $PlatformKind `
            -PlatformComponents $PlatformComponents `
            -OwnedObjects $OwnedObjects
    }
    catch {
        Throw-CommMonitorOwnershipLayoutSemanticError `
            -Message $_.Exception.Message
    }

    $objects = [Collections.Generic.List[object]]::new()
    $objectIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $ownedPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($ownedObjectInput in $OwnedObjects) {
        $ownedObject = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $ownedObjectInput
        if (-not $objectIds.Add([string]$ownedObject.objectId)) {
            Throw-CommMonitorOwnershipLayoutSemanticError `
                -Message "duplicate objectId '$($ownedObject.objectId)'."
        }
        if ($ownedObject.Contains('relativePath')) {
            $pathKey = '{0}|{1}' -f
                [string]$ownedObject.root,
                [string]$ownedObject.relativePath
            if (-not $ownedPaths.Add($pathKey)) {
                Throw-CommMonitorOwnershipLayoutSemanticError `
                    -Message "duplicate owned path '$pathKey'."
            }
        }
        $objects.Add($ownedObject)

        $boundRoot = Get-CommMonitorCanonicalRootForOwnedRole `
            -Roots $Roots `
            -RootRole ([string]$ownedObject.root)
        if ($null -ne $boundRoot -and -not [bool]$boundRoot.active) {
            Throw-CommMonitorOwnershipLayoutSemanticError `
                -Message ("object '{0}' targets inactive root '{1}'." -f
                    [string]$ownedObject.objectId,
                    [string]$ownedObject.root)
        }
    }

    $isDesktop = Test-CommMonitorOrdinalValue `
        -Value $PlatformKind `
        -Allowed @('Desktop', 'ServerDesktop')
    $requiredAiRoot = if ($isDesktop) { 'AppRoot' } else { 'CoreRoot' }
    $aiCliObjects = @(
        $objects | Where-Object {
            [string]::Equals(
                [string]$_.component,
                'AiCli',
                [StringComparison]::Ordinal)
        })
    if ($aiCliObjects.Count -ne 1 -or
        -not [string]::Equals(
            [string]$aiCliObjects[0].root,
            $requiredAiRoot,
            [StringComparison]::Ordinal)) {
        Throw-CommMonitorOwnershipLayoutSemanticError `
            -Message "$PlatformKind requires exactly one AiCli under $requiredAiRoot."
    }

    if ($isDesktop) {
        $desktopExecutables = @(
            $objects | Where-Object {
                [string]::Equals(
                    [string]$_.component,
                    'DesktopExecutable',
                    [StringComparison]::Ordinal)
            })
        if ($desktopExecutables.Count -ne 1 -or
            -not [string]::Equals(
                [string]$desktopExecutables[0].root,
                'AppRoot',
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorOwnershipLayoutSemanticError `
                -Message "$PlatformKind requires exactly one AppRoot desktop executable."
        }
    }
    else {
        $headlessObjects = @(
            $objects | Where-Object {
                [string]::Equals(
                    [string]$_.component,
                    'Headless',
                    [StringComparison]::Ordinal)
            })
        if ($headlessObjects.Count -ne 1 -or
            -not [string]::Equals(
                [string]$headlessObjects[0].root,
                'CoreRoot',
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorOwnershipLayoutSemanticError `
                -Message 'ServerCore requires exactly one CoreRoot headless executable.'
        }
    }

    $allShortcuts = @(
        $objects | Where-Object {
            [string]::Equals(
                [string]$_.type,
                'Shortcut',
                [StringComparison]::Ordinal)
        })
    $startMenuShortcuts = @(
        $allShortcuts | Where-Object {
            [string]::Equals(
                [string]$_.component,
                'StartMenuShortcut',
                [StringComparison]::Ordinal)
        })
    $desktopShortcuts = @(
        $allShortcuts | Where-Object {
            [string]::Equals(
                [string]$_.component,
                'DesktopShortcut',
                [StringComparison]::Ordinal)
        })
    if ($isDesktop) {
        if ($startMenuShortcuts.Count -ne 1 -or
            $desktopShortcuts.Count -gt 1) {
            Throw-CommMonitorOwnershipLayoutSemanticError `
                -Message "$PlatformKind requires one Start Menu and at most one desktop shortcut."
        }
    }
    elseif ($allShortcuts.Count -ne 0) {
        Throw-CommMonitorOwnershipLayoutSemanticError `
            -Message 'ServerCore rejects every Shortcut object.'
    }

    foreach ($docsObject in @(
            $objects | Where-Object {
                [string]::Equals(
                    [string]$_.component,
                    'Docs',
                    [StringComparison]::Ordinal)
            })) {
        $expectedDocsRoot = if ($isDesktop) { 'AppRoot' } else { 'CoreRoot' }
        if (-not [string]::Equals(
                [string]$docsObject.root,
                $expectedDocsRoot,
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorOwnershipLayoutSemanticError `
                -Message "$PlatformKind documentation must be under $expectedDocsRoot."
        }
    }

    $rootDirectories = @(
        $objects | Where-Object {
            [string]::Equals(
                [string]$_.type,
                'Directory',
                [StringComparison]::Ordinal) -and
            [string]::Equals(
                [string]$_.component,
                'RootDirectory',
                [StringComparison]::Ordinal)
        })
    foreach ($rootRole in @('AppRoot', 'CoreRoot')) {
        $matchingDirectories = @(
            $rootDirectories | Where-Object {
                [string]::Equals(
                    [string]$_.root,
                    $rootRole,
                    [StringComparison]::Ordinal)
            })
        $expectedCount = if ($rootRole -eq 'AppRoot' -and -not $isDesktop) {
            0
        }
        else {
            1
        }
        if ($matchingDirectories.Count -ne $expectedCount) {
            Throw-CommMonitorOwnershipLayoutSemanticError `
                -Message "$PlatformKind requires $expectedCount $rootRole root-directory object(s)."
        }
        if ($expectedCount -eq 0) { continue }

        $directory = $matchingDirectories[0]
        $identity = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $directory.identity
        $rootRecord = Get-CommMonitorCanonicalRootForOwnedRole `
            -Roots $Roots `
            -RootRole $rootRole
        $expectedRemove = -not [string]::Equals(
            [string]$rootRecord.ownershipProof,
            'PreExistingShared',
            [StringComparison]::Ordinal)
        if (-not [string]::IsNullOrEmpty([string]$directory.relativePath) -or
            -not [string]::Equals(
                [string]$directory.contentPolicy,
                'EmptyAfterOwnedChildren',
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$directory.ownershipProof,
                [string]$rootRecord.ownershipProof,
                [StringComparison]::Ordinal) -or
            [bool]$identity.created -ne [bool]$rootRecord.createdByInstall -or
            [bool]$directory.removeOnUninstall -ne $expectedRemove) {
            Throw-CommMonitorOwnershipLayoutSemanticError `
                -Message "$rootRole root-directory identity does not match its root record."
        }
        foreach ($child in @(
                $objects | Where-Object {
                    -not [string]::Equals(
                        [string]$_.objectId,
                        [string]$directory.objectId,
                        [StringComparison]::Ordinal) -and
                    [string]::Equals(
                        [string]$_.root,
                        $rootRole,
                        [StringComparison]::Ordinal)
                })) {
            if ([int]$directory.deletePhase -le [int]$child.deletePhase) {
                Throw-CommMonitorOwnershipLayoutSemanticError `
                    -Message "$rootRole root directory must delete after every owned child."
            }
        }
    }
}

function Throw-CommMonitorOwnershipCrossObjectSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Ownership cross-object semantics: $Message"
}

function Get-CommMonitorOwnedCanonicalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Roots,
        [Parameter(Mandatory)][Collections.IDictionary] $OwnedObject
    )

    $rootRecord = Get-CommMonitorCanonicalRootForOwnedRole `
        -Roots $Roots `
        -RootRole ([string]$OwnedObject.root)
    if ($null -eq $rootRecord -or -not [bool]$rootRecord.active) {
        return $null
    }
    $rootPath = [string]$rootRecord.canonicalPath
    $relativePath = [string]$OwnedObject.relativePath
    if ([string]::IsNullOrEmpty($relativePath)) {
        return $rootPath
    }
    return $rootPath.TrimEnd('\') + '\' + $relativePath
}

function Assert-CommMonitorOwnershipCrossObjectSemantics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ProductVersion,
        [Parameter(Mandatory)][string] $InstallId,
        [Parameter(Mandatory)][object] $Roots,
        [Parameter(Mandatory)][object] $KeyMetadata,
        [Parameter(Mandatory)][object[]] $OwnedObjects
    )

    $objects = [Collections.Generic.List[object]]::new()
    $objectsById = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $immutableByPath = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $expectedProductMarker = 'CommMonitor:' + $ProductVersion

    foreach ($ownedObjectInput in $OwnedObjects) {
        $ownedObject = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $ownedObjectInput
        $objects.Add($ownedObject)
        if ($objectsById.ContainsKey([string]$ownedObject.objectId)) {
            Throw-CommMonitorOwnershipCrossObjectSemanticError `
                -Message "duplicate objectId '$($ownedObject.objectId)'."
        }
        $objectsById.Add([string]$ownedObject.objectId, $ownedObject)

        if ([string]::Equals(
                [string]$ownedObject.type,
                'ImmutableFile',
                [StringComparison]::Ordinal)) {
            $identity = ConvertTo-CommMonitorOrderedDictionary `
                -InputObject $ownedObject.identity
            if (-not [string]::Equals(
                    [string]$identity.productMarker,
                    $expectedProductMarker,
                    [StringComparison]::Ordinal)) {
                Throw-CommMonitorOwnershipCrossObjectSemanticError `
                    -Message ("immutable object '{0}' has a product marker for another version." -f
                        [string]$ownedObject.objectId)
            }
            $absolutePath = Get-CommMonitorOwnedCanonicalPath `
                -Roots $Roots `
                -OwnedObject $ownedObject
            if ([string]::IsNullOrEmpty($absolutePath)) {
                Throw-CommMonitorOwnershipCrossObjectSemanticError `
                    -Message ("immutable object '{0}' is not under an active path root." -f
                        [string]$ownedObject.objectId)
            }
            if ($immutableByPath.ContainsKey($absolutePath)) {
                Throw-CommMonitorOwnershipCrossObjectSemanticError `
                    -Message "duplicate immutable path '$absolutePath'."
            }
            $immutableByPath.Add($absolutePath, $ownedObject)
        }
    }

    foreach ($shortcut in @(
            $objects | Where-Object {
                [string]::Equals(
                    [string]$_.type,
                    'Shortcut',
                    [StringComparison]::Ordinal)
            })) {
        $identity = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $shortcut.identity
        $targetPath = [string]$identity.target
        if (-not $immutableByPath.ContainsKey($targetPath)) {
            Throw-CommMonitorOwnershipCrossObjectSemanticError `
                -Message ("shortcut '{0}' does not target an owned immutable file." -f
                    [string]$shortcut.objectId)
        }
        $targetObject = $immutableByPath[$targetPath]
        $targetRoot = Get-CommMonitorCanonicalRootForOwnedRole `
            -Roots $Roots `
            -RootRole ([string]$targetObject.root)
        if ($null -eq $targetRoot -or
            -not [string]::Equals(
                [string]$identity.workingDirectory,
                [string]$targetRoot.canonicalPath,
                [StringComparison]::OrdinalIgnoreCase)) {
            Throw-CommMonitorOwnershipCrossObjectSemanticError `
                -Message ("shortcut '{0}' has a working directory outside its target root." -f
                    [string]$shortcut.objectId)
        }
    }

    $registryValues = @(
        $objects | Where-Object {
            [string]::Equals(
                [string]$_.type,
                'RegistryValue',
                [StringComparison]::Ordinal)
        })
    foreach ($registryKey in @(
            $objects | Where-Object {
                [string]::Equals(
                    [string]$_.type,
                    'RegistryKey',
                    [StringComparison]::Ordinal)
            })) {
        $keyIdentity = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $registryKey.identity
        foreach ($registryValue in $registryValues) {
            $valueIdentity = ConvertTo-CommMonitorOrderedDictionary `
                -InputObject $registryValue.identity
            $sameKey =
                [string]::Equals(
                    [string]$keyIdentity.hive,
                    [string]$valueIdentity.hive,
                    [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals(
                    [string]$keyIdentity.view,
                    [string]$valueIdentity.view,
                    [StringComparison]::Ordinal) -and
                [string]::Equals(
                    [string]$keyIdentity.key,
                    [string]$valueIdentity.key,
                    [StringComparison]::OrdinalIgnoreCase)
            if ($sameKey -and
                [int]$registryKey.deletePhase -le
                    [int]$registryValue.deletePhase) {
                Throw-CommMonitorOwnershipCrossObjectSemanticError `
                    -Message ("registry key '{0}' must delete after its values." -f
                        [string]$registryKey.objectId)
            }
        }
    }

    $servicesByName = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($service in @(
            $objects | Where-Object {
                [string]::Equals(
                    [string]$_.type,
                    'Service',
                    [StringComparison]::Ordinal)
            })) {
        $identity = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $service.identity
        $imagePath = [string]$identity.imagePath
        if (-not $immutableByPath.ContainsKey($imagePath)) {
            Throw-CommMonitorOwnershipCrossObjectSemanticError `
                -Message ("service '{0}' image is not owned." -f
                    [string]$identity.name)
        }
        $imageObject = $immutableByPath[$imagePath]
        if (-not [string]::Equals(
                [string]$imageObject.component,
                'Service',
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$imageObject.root,
                'CoreRoot',
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorOwnershipCrossObjectSemanticError `
                -Message ("service '{0}' image is not a CoreRoot Service immutable." -f
                    [string]$identity.name)
        }
        if ($servicesByName.ContainsKey([string]$identity.name)) {
            Throw-CommMonitorOwnershipCrossObjectSemanticError `
                -Message "duplicate service name '$($identity.name)'."
        }
        $servicesByName.Add([string]$identity.name, $service)
    }

    foreach ($eventSource in @(
            $objects | Where-Object {
                [string]::Equals(
                    [string]$_.type,
                    'EventSource',
                    [StringComparison]::Ordinal)
            })) {
        $identity = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $eventSource.identity
        if (-not $servicesByName.ContainsKey([string]$identity.source)) {
            Throw-CommMonitorOwnershipCrossObjectSemanticError `
                -Message ("event source '{0}' is not bound to an owned service." -f
                    [string]$identity.source)
        }
        $serviceIdentity = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $servicesByName[[string]$identity.source].identity
        if (-not [string]::Equals(
                [string]$identity.messageFile,
                [string]$serviceIdentity.imagePath,
                [StringComparison]::OrdinalIgnoreCase)) {
            Throw-CommMonitorOwnershipCrossObjectSemanticError `
                -Message ("event source '{0}' message file differs from its service image." -f
                    [string]$identity.source)
        }
    }

    $expectedTaskName = 'LemonSerialMonitor-' + $InstallId
    foreach ($scheduledTask in @(
            $objects | Where-Object {
                [string]::Equals(
                    [string]$_.type,
                    'ScheduledTask',
                    [StringComparison]::Ordinal)
            })) {
        $identity = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $scheduledTask.identity
        if (-not [string]::Equals(
                [string]$identity.name,
                $expectedTaskName,
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorOwnershipCrossObjectSemanticError `
                -Message 'continuation task belongs to another install identity.'
        }
        $finalizerPath = [string]$identity.finalizerPath
        if (-not $immutableByPath.ContainsKey($finalizerPath)) {
            Throw-CommMonitorOwnershipCrossObjectSemanticError `
                -Message 'continuation task finalizer is not an owned immutable file.'
        }
        $finalizerObject = $immutableByPath[$finalizerPath]
        if (-not [string]::Equals(
                [string]$finalizerObject.root,
                'InstallerRoot',
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$finalizerObject.component,
                'Uninstall',
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorOwnershipCrossObjectSemanticError `
                -Message 'continuation task finalizer is outside the owned installer root.'
        }
    }

    $keyData = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $KeyMetadata
    $manifestKey = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $keyData.manifest
    foreach ($ownedKeyMetadata in @(
            $objects | Where-Object {
                [string]::Equals(
                    [string]$_.type,
                    'KeyMetadata',
                    [StringComparison]::Ordinal)
            })) {
        $identity = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $ownedKeyMetadata.identity
        if (-not [string]::Equals(
                [string]$identity.state,
                [string]$manifestKey.state,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$identity.keyId,
                [string]$manifestKey.keyId,
                [StringComparison]::Ordinal)) {
            Throw-CommMonitorOwnershipCrossObjectSemanticError `
                -Message 'owned key metadata differs from payload key metadata.'
        }
    }

    foreach ($continuationMetadata in @(
            $objects | Where-Object {
                [string]::Equals(
                    [string]$_.type,
                    'ContinuationMetadata',
                    [StringComparison]::Ordinal)
            })) {
        $identity = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $continuationMetadata.identity
        foreach ($pendingObjectId in @($identity.pendingObjectIds)) {
            if (-not $objectsById.ContainsKey([string]$pendingObjectId)) {
                Throw-CommMonitorOwnershipCrossObjectSemanticError `
                    -Message "continuation references missing object '$pendingObjectId'."
            }
            $pendingObject = $objectsById[[string]$pendingObjectId]
            if ([string]::Equals(
                    [string]$pendingObject.objectId,
                    [string]$continuationMetadata.objectId,
                    [StringComparison]::OrdinalIgnoreCase) -or
                -not [bool]$pendingObject.removeOnUninstall) {
                Throw-CommMonitorOwnershipCrossObjectSemanticError `
                    -Message "continuation object '$pendingObjectId' is not independently removable."
            }
        }
    }
}

function Throw-CommMonitorOwnershipStateSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Ownership state semantics: $Message"
}

function Throw-CommMonitorOwnershipOperationSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Ownership operation semantics: $Message"
}

function Copy-CommMonitorCanonicalOperationGuid {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Subject
    )

    $text = Copy-CommMonitorSchemaString -Value $Value -Subject $Subject
    $guid = [Guid]::Empty
    if (-not [Guid]::TryParseExact($text, 'D', [ref]$guid) -or
        -not [string]::Equals(
            $text,
            $guid.ToString('D').ToLowerInvariant(),
            [StringComparison]::Ordinal)) {
        throw "$Subject must be a canonical lowercase GUID D value."
    }
    return $text
}

function Copy-CommMonitorCanonicalOperationUtc {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Subject,
        [bool] $AllowNull = $false
    )

    if ($null -eq $Value) {
        if ($AllowNull) { return $null }
        throw "$Subject must be a raw canonical UTC string."
    }
    $text = Copy-CommMonitorSchemaString -Value $Value -Subject $Subject
    $parsed = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor
        [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTimeOffset]::TryParseExact(
            $text,
            'yyyy-MM-ddTHH:mm:ss.fffffffZ',
            [Globalization.CultureInfo]::InvariantCulture,
            $styles,
            [ref]$parsed) -or
        -not [string]::Equals(
            $text,
            $parsed.ToUniversalTime().ToString(
                'yyyy-MM-ddTHH:mm:ss.fffffffZ',
                [Globalization.CultureInfo]::InvariantCulture),
            [StringComparison]::Ordinal)) {
        throw "$Subject must use yyyy-MM-ddTHH:mm:ss.fffffffZ UTC."
    }
    return $text
}

function ConvertTo-CommMonitorCanonicalPreparedTargets {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowNull()][object] $Targets)

    Assert-CommMonitorRawSchemaArray `
        -Value $Targets `
        -Subject 'Operation state preparedTargets'
    $items = [Collections.Generic.List[object]]::new()
    $objectIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($targetInput in $Targets) {
        $target = ConvertTo-CommMonitorSchemaObject `
            -Value $targetInput `
            -Subject 'Prepared target'
        $fields = @(
            'objectId', 'volumeSerialNumber', 'fileId', 'size', 'sha256')
        Assert-CommMonitorExactFields `
            -Dictionary $target `
            -Allowed $fields `
            -Required $fields `
            -Subject 'Prepared target'
        $objectId = Copy-CommMonitorSchemaString `
            -Value $target.objectId `
            -Subject 'Prepared target objectId'
        if (-not [regex]::IsMatch(
                $objectId,
                '^[a-z0-9][a-z0-9.-]*$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not $objectIds.Add($objectId)) {
            throw 'Prepared target objectId set is invalid or duplicate.'
        }
        $volumeSerialNumber = Copy-CommMonitorSchemaString `
            -Value $target.volumeSerialNumber `
            -Subject 'Prepared target volumeSerialNumber'
        $fileId = Copy-CommMonitorSchemaString `
            -Value $target.fileId `
            -Subject 'Prepared target fileId'
        $sha256 = Copy-CommMonitorSchemaString `
            -Value $target.sha256 `
            -Subject 'Prepared target sha256'
        $size = Copy-CommMonitorSchemaInt64 `
            -Value $target.size `
            -Subject 'Prepared target size'
        if (-not [regex]::IsMatch(
                $volumeSerialNumber,
                '^[0-9a-f]{16}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [regex]::IsMatch(
                $fileId,
                '^[0-9a-f]{32}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [regex]::IsMatch(
                $sha256,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            $size -lt 0) {
            throw 'Prepared target identity, size or digest is invalid.'
        }
        $items.Add([ordered]@{
                objectId = $objectId
                volumeSerialNumber = $volumeSerialNumber
                fileId = $fileId
                size = $size
                sha256 = $sha256
            })
    }
    $items.Sort([Comparison[object]] {
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string]$left.objectId,
                [string]$right.objectId)
        })
    Write-Output -NoEnumerate ([object[]]$items.ToArray())
}

function ConvertTo-CommMonitorCanonicalOperationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $State,
        [Parameter(Mandatory)][object] $OperationState
    )

    try {
        $operation = ConvertTo-CommMonitorSchemaObject `
            -Value $OperationState `
            -Subject 'Operation state'
        if ($State -eq 'Committed') {
            Assert-CommMonitorExactFields `
                -Dictionary $operation `
                -Allowed @() `
                -Required @() `
                -Subject 'Operation state'
            return [ordered]@{}
        }
        if ($State -eq 'FinalizingAbsent') {
            $terminalFields = @(
                'operationId', 'terminalCleanupId', 'terminalKeyId',
                'terminalEnvelopeSha256', 'finalizingUtc')
            Assert-CommMonitorExactFields `
                -Dictionary $operation `
                -Allowed $terminalFields `
                -Required $terminalFields `
                -Subject 'Operation state'
            $operationId = Copy-CommMonitorCanonicalOperationGuid `
                -Value $operation.operationId `
                -Subject 'Operation state operationId'
            $terminalCleanupId = Copy-CommMonitorCanonicalOperationGuid `
                -Value $operation.terminalCleanupId `
                -Subject 'Operation state terminalCleanupId'
            $terminalKeyId = Copy-CommMonitorSchemaString `
                -Value $operation.terminalKeyId `
                -Subject 'Operation state terminalKeyId'
            $terminalEnvelopeSha256 = Copy-CommMonitorSchemaString `
                -Value $operation.terminalEnvelopeSha256 `
                -Subject 'Operation state terminalEnvelopeSha256'
            if (-not [regex]::IsMatch(
                    $terminalKeyId,
                    '^[0-9a-f]{64}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
                -not [regex]::IsMatch(
                    $terminalEnvelopeSha256,
                    '^[0-9a-f]{64}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                throw 'Terminal cleanup hashes are not canonical.'
            }
            return [ordered]@{
                operationId = $operationId
                terminalCleanupId = $terminalCleanupId
                terminalKeyId = $terminalKeyId
                terminalEnvelopeSha256 = $terminalEnvelopeSha256
                finalizingUtc = Copy-CommMonitorCanonicalOperationUtc `
                    -Value $operation.finalizingUtc `
                    -Subject 'Operation state finalizingUtc'
            }
        }

        $baseFields = @(
            'operationId', 'nonce', 'resultRelativePath', 'helperSha256',
            'pendingObjectIds', 'requestedUtc')
        $extraFields = switch -CaseSensitive ($State) {
            'UninstallRequested' { @() }
            'UninstallPrepared' { @('preparedTargets', 'preparedUtc') }
            'PendingReboot' {
                @('preparedTargets', 'preparedUtc', 'pendingRebootUtc')
            }
            'Abandoned' {
                @(
                    'preparedTargets', 'preparedUtc',
                    'abandonedReason', 'abandonedUtc')
            }
            default { throw "Operation state does not support payload state '$State'." }
        }
        $fields = [string[]]@($baseFields + $extraFields)
        Assert-CommMonitorExactFields `
            -Dictionary $operation `
            -Allowed $fields `
            -Required $fields `
            -Subject 'Operation state'
        $operationId = Copy-CommMonitorCanonicalOperationGuid `
            -Value $operation.operationId `
            -Subject 'Operation state operationId'
        $nonce = Copy-CommMonitorSchemaString `
            -Value $operation.nonce `
            -Subject 'Operation state nonce'
        $resultRelativePath = Copy-CommMonitorSchemaString `
            -Value $operation.resultRelativePath `
            -Subject 'Operation state resultRelativePath'
        $helperSha256 = Copy-CommMonitorSchemaString `
            -Value $operation.helperSha256 `
            -Subject 'Operation state helperSha256'
        if (-not [regex]::IsMatch(
                $nonce,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [regex]::IsMatch(
                $helperSha256,
                '^[0-9a-f]{64}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            throw 'Operation nonce or helper hash is not canonical.'
        }
        $expectedResultPath =
            "state\results\$operationId.v1.json"
        if (-not [string]::Equals(
                $resultRelativePath,
                $expectedResultPath,
                [StringComparison]::Ordinal)) {
            throw 'Operation resultRelativePath is not bound to operationId.'
        }
        $copy = [ordered]@{
            operationId = $operationId
            nonce = $nonce
            resultRelativePath = $resultRelativePath
            helperSha256 = $helperSha256
            pendingObjectIds = Copy-CommMonitorCanonicalStringSet `
                -Value $operation.pendingObjectIds `
                -Subject 'Operation state pendingObjectIds'
            requestedUtc = Copy-CommMonitorCanonicalOperationUtc `
                -Value $operation.requestedUtc `
                -Subject 'Operation state requestedUtc'
        }
        if ($State -in @(
                'UninstallPrepared', 'PendingReboot', 'Abandoned')) {
            $copy['preparedTargets'] =
                ConvertTo-CommMonitorCanonicalPreparedTargets `
                    -Targets $operation.preparedTargets
            $copy['preparedUtc'] = Copy-CommMonitorCanonicalOperationUtc `
                -Value $operation.preparedUtc `
                -Subject 'Operation state preparedUtc' `
                -AllowNull ($State -eq 'Abandoned')
        }
        if ($State -eq 'PendingReboot') {
            $copy['pendingRebootUtc'] = Copy-CommMonitorCanonicalOperationUtc `
                -Value $operation.pendingRebootUtc `
                -Subject 'Operation state pendingRebootUtc'
        }
        if ($State -eq 'Abandoned') {
            $reason = Copy-CommMonitorSchemaString `
                -Value $operation.abandonedReason `
                -Subject 'Operation state abandonedReason'
            if (-not (Test-CommMonitorOrdinalValue `
                    -Value $reason `
                    -Allowed @('HelperFailed', 'HelperExited', 'ClaimInvalid'))) {
                throw 'Operation abandonedReason is invalid.'
            }
            $copy['abandonedReason'] = $reason
            $copy['abandonedUtc'] = Copy-CommMonitorCanonicalOperationUtc `
                -Value $operation.abandonedUtc `
                -Subject 'Operation state abandonedUtc'
        }
        return $copy
    }
    catch {
        if ($_.Exception.Message.StartsWith(
                'Ownership operation semantics:',
                [StringComparison]::Ordinal)) {
            throw
        }
        Throw-CommMonitorOwnershipOperationSemanticError `
            -Message $_.Exception.Message
    }
}

function Assert-CommMonitorOwnershipOperationStateSemantics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $State,
        [Parameter(Mandatory)][object] $OperationState,
        [Parameter(Mandatory)][object[]] $OwnedObjects
    )

    if ($State -in @('Committed', 'FinalizingAbsent')) { return }
    $operation = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $OperationState
    $objectsById = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal)
    foreach ($ownedObjectInput in $OwnedObjects) {
        $ownedObject = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $ownedObjectInput
        $objectsById[[string]$ownedObject.objectId] = $ownedObject
    }
    $dynamicPending = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($pendingObjectId in @($operation.pendingObjectIds)) {
        if (-not $objectsById.ContainsKey([string]$pendingObjectId)) {
            Throw-CommMonitorOwnershipOperationSemanticError `
                -Message "pending object '$pendingObjectId' does not exist."
        }
        $pendingObject = $objectsById[[string]$pendingObjectId]
        if (-not [bool]$pendingObject.removeOnUninstall) {
            Throw-CommMonitorOwnershipOperationSemanticError `
                -Message "pending object '$pendingObjectId' is not removable."
        }
        if ([string]::Equals(
                [string]$pendingObject.type,
                'DynamicFile',
                [StringComparison]::Ordinal)) {
            [void]$dynamicPending.Add([string]$pendingObjectId)
        }
    }
    if ($State -in @('UninstallPrepared', 'PendingReboot')) {
        $preparedIds = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal)
        foreach ($target in @($operation.preparedTargets)) {
            [void]$preparedIds.Add([string]$target.objectId)
        }
        if (-not $preparedIds.SetEquals($dynamicPending)) {
            Throw-CommMonitorOwnershipOperationSemanticError `
                -Message 'preparedTargets must exactly snapshot every pending DynamicFile.'
        }
    }
    elseif ($State -eq 'Abandoned') {
        $targets = @($operation.preparedTargets)
        if ($null -eq $operation.preparedUtc) {
            if ($targets.Count -ne 0) {
                Throw-CommMonitorOwnershipOperationSemanticError `
                    -Message 'an unprepared Abandoned attempt cannot claim prepared targets.'
            }
        }
        else {
            $preparedIds = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::Ordinal)
            foreach ($target in $targets) {
                [void]$preparedIds.Add([string]$target.objectId)
            }
            if (-not $preparedIds.SetEquals($dynamicPending)) {
                Throw-CommMonitorOwnershipOperationSemanticError `
                    -Message 'prepared Abandoned targets do not match pending DynamicFiles.'
            }
        }
    }
}

function Assert-CommMonitorOwnershipCommittedStateSemantics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $State,
        [Parameter(Mandatory)][object] $ContinuationState,
        [Parameter(Mandatory)][object] $OperationState,
        [Parameter(Mandatory)][object] $KeyMetadata,
        [Parameter(Mandatory)][object[]] $OwnedObjects
    )

    $keyData = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $KeyMetadata
    $manifestKey = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $keyData.manifest
    if (-not [string]::Equals(
            [string]$manifestKey.state,
            'Active',
            [StringComparison]::Ordinal) -or
        -not [regex]::IsMatch(
            [string]$manifestKey.keyId,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        Throw-CommMonitorOwnershipStateSemanticError `
            -Message 'manifest key metadata is not an exact Active key binding.'
    }

    if (-not [string]::Equals(
            $State,
            'Committed',
            [StringComparison]::Ordinal)) {
        return
    }

    $continuationData = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $ContinuationState
    if (-not [string]::Equals(
            [string]$continuationData.status,
            'None',
            [StringComparison]::Ordinal)) {
        Throw-CommMonitorOwnershipStateSemanticError `
            -Message 'Committed requires continuation status None.'
    }

    $operationData = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $OperationState
    if ($operationData.Count -ne 0) {
        Throw-CommMonitorOwnershipStateSemanticError `
            -Message 'Committed rejects every active operation field.'
    }

    foreach ($ownedObjectInput in $OwnedObjects) {
        $ownedObject = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $ownedObjectInput
        if (Test-CommMonitorOrdinalValue `
                -Value $ownedObject.type `
                -Allowed @('ScheduledTask', 'ContinuationMetadata')) {
            Throw-CommMonitorOwnershipStateSemanticError `
                -Message ("Committed rejects continuation object '{0}'." -f
                    [string]$ownedObject.objectId)
        }
    }
}

function ConvertTo-CommMonitorCanonicalAuthorizedUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $AuthorizedUser,
        [Parameter(Mandatory)]
        [ValidateSet('Resolver', 'Canonical')]
        [string] $InputCasing
    )

    $data = ConvertTo-CommMonitorSchemaObject `
        -Value $AuthorizedUser `
        -Subject 'Authorized user'
    $resolverFields = @(
        'Sid', 'ProfileListKeyPath', 'ProfileImagePathRaw',
        'ProfileImagePathValueKind', 'ProfileExpansionSource',
        'ProfileExpansionSid', 'ProfileImagePath', 'KnownFolderId',
        'KnownFolderSid', 'LocalAppDataPath', 'AiRoot')
    $canonicalFields = @(
        'sid', 'profileListKeyPath', 'profileImagePathRaw',
        'profileImagePathValueKind', 'profileExpansionSource',
        'profileExpansionSid', 'profileImagePath', 'knownFolderId',
        'knownFolderSid', 'localAppDataPath', 'aiRoot')
    $fields = if ($InputCasing -eq 'Resolver') {
        $resolverFields
    }
    else {
        $canonicalFields
    }
    Assert-CommMonitorExactFields `
        -Dictionary $data `
        -Allowed $fields `
        -Required $fields `
        -Subject 'Authorized user'
    $profileKindField = if ($InputCasing -eq 'Resolver') {
        'ProfileImagePathValueKind'
    }
    else {
        'profileImagePathValueKind'
    }
    $profileKind = Copy-CommMonitorSchemaString `
        -Value $data[$profileKindField] `
        -Subject 'Authorized user profileImagePathValueKind'
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $profileKind `
            -Allowed @('String', 'ExpandString'))) {
        throw 'Authorized user has an invalid profileImagePathValueKind.'
    }
    $copy = [ordered]@{}
    for ($index = 0; $index -lt $canonicalFields.Count; $index++) {
        $sourceName = if ($InputCasing -eq 'Resolver') {
            $resolverFields[$index]
        }
        else {
            $canonicalFields[$index]
        }
        $targetName = $canonicalFields[$index]
        $copy[$targetName] = if ($targetName -eq 'profileImagePathValueKind') {
            $profileKind
        }
        else {
            Copy-CommMonitorSchemaString `
                -Value $data[$sourceName] `
                -Subject "Authorized user $targetName"
        }
    }
    return $copy
}

function Get-CommMonitorOwnedIdentityFields {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object] $Type)

    switch -CaseSensitive ([string]$Type) {
        'ImmutableFile' { return @('size', 'sha256', 'productMarker') }
        'DynamicFile' { return }
        'Directory' { return ,@('created') }
        'Shortcut' {
            return @('target', 'arguments', 'workingDirectory', 'fileSha256', 'created')
        }
        'RegistryValue' {
            return @('hive', 'view', 'key', 'name', 'kind', 'value', 'created')
        }
        'RegistryKey' { return @('hive', 'view', 'key', 'created') }
        'Service' {
            return @(
                'name', 'serviceType', 'imagePath', 'arguments',
                'accountSid', 'creationProof')
        }
        'DriverPackage' {
            return @(
                'publishedName', 'originalInfPath', 'originalInfSha256',
                'creationProof')
        }
        'Certificate' { return @('store', 'thumbprint', 'derSha256', 'added') }
        'EventSource' {
            return @('log', 'source', 'registrationPath', 'messageFile', 'creationProof')
        }
        'ScheduledTask' {
            return @(
                'name', 'identitySid', 'trigger', 'finalizerPath',
                'arguments', 'xmlSha256')
        }
        'FilterMetadata' { return @('classKey', 'valueName', 'entry', 'added') }
        'KeyMetadata' { return @('kind', 'state', 'relativePath', 'keyId') }
        'ContinuationMetadata' {
            return @(
                'relativePath', 'pendingObjectIds', 'helperSha256',
                'finalizerSha256')
        }
        default { throw "Owned object has an unknown type '$Type'." }
    }
}

function Throw-CommMonitorOwnedObjectSemanticError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    throw "Owned object semantics: $Message"
}

function Assert-CommMonitorOwnedAbsolutePathSemantic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Subject
    )

    try {
        $canonical = ConvertTo-CommMonitorCanonicalWindowsPath `
            -Path $Path `
            -Role $Subject
    }
    catch {
        Throw-CommMonitorOwnedObjectSemanticError `
            -Message "$Subject is not a safe absolute path."
    }
    if (-not [string]::Equals(
            $canonical,
            $Path,
            [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CommMonitorOwnedObjectSemanticError `
            -Message "$Subject is not canonical."
    }
}

function Assert-CommMonitorOwnedRegistryKeySemantic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)][string] $Subject
    )

    if ([string]::IsNullOrWhiteSpace($Key) -or
        $Key.Contains('/') -or
        $Key.Contains(':') -or
        $Key.StartsWith('\', [StringComparison]::Ordinal) -or
        $Key.EndsWith('\', [StringComparison]::Ordinal) -or
        $Key.Contains('\\')) {
        Throw-CommMonitorOwnedObjectSemanticError `
            -Message "$Subject is not an exact relative registry key."
    }
}

function Assert-CommMonitorOwnedCreationFlagSemantic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $OwnershipProof,
        [Parameter(Mandatory)][bool] $Flag,
        [Parameter(Mandatory)][string] $Subject
    )

    $expected = [string]::Equals(
        $OwnershipProof,
        'CreatedThisInstall',
        [StringComparison]::Ordinal)
    if ($Flag -ne $expected) {
        Throw-CommMonitorOwnedObjectSemanticError `
            -Message "$Subject does not match ownershipProof."
    }
}

function Assert-CommMonitorOwnedCreationProofSemantic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $OwnershipProof,
        [Parameter(Mandatory)][string] $CreationProof,
        [Parameter(Mandatory)][string] $Subject
    )

    if (-not (Test-CommMonitorOrdinalValue `
            -Value $CreationProof `
            -Allowed @(
                'CreatedThisInstall',
                'VerifiedLegacyAdoption',
                'PreExistingShared')) -or
        -not [string]::Equals(
            $CreationProof,
            $OwnershipProof,
            [StringComparison]::Ordinal)) {
        Throw-CommMonitorOwnedObjectSemanticError `
            -Message "$Subject does not match ownershipProof."
    }
}

function Assert-CommMonitorOwnedObjectSemantics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary] $OwnedObject
    )

    if (-not [regex]::IsMatch(
            [string]$OwnedObject.objectId,
            '^[a-z0-9][a-z0-9.-]*$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        Throw-CommMonitorOwnedObjectSemanticError `
            -Message 'objectId is not canonical.'
    }
    if ([int]$OwnedObject.deletePhase -lt 0) {
        Throw-CommMonitorOwnedObjectSemanticError `
            -Message 'deletePhase must be non-negative.'
    }
    if ([string]::Equals(
            [string]$OwnedObject.ownershipProof,
            'PreExistingShared',
            [StringComparison]::Ordinal) -and
        [bool]$OwnedObject.removeOnUninstall) {
        Throw-CommMonitorOwnedObjectSemanticError `
            -Message 'PreExistingShared objects cannot enter a delete plan.'
    }

    $pathTypes = @('ImmutableFile', 'DynamicFile', 'Directory', 'Shortcut')
    if (Test-CommMonitorOrdinalValue `
            -Value $OwnedObject.type `
            -Allowed $pathTypes) {
        try {
            Assert-CommMonitorRelativeOrdinaryPath `
                -Path ([string]$OwnedObject.relativePath) `
                -AllowEmpty ([string]::Equals(
                    [string]$OwnedObject.type,
                    'Directory',
                    [StringComparison]::Ordinal))
        }
        catch {
            Throw-CommMonitorOwnedObjectSemanticError `
                -Message 'relativePath is unsafe.'
        }
    }

    $identity = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $OwnedObject.identity
    switch -CaseSensitive ([string]$OwnedObject.type) {
        'ImmutableFile' {
            if ([long]$identity.size -lt 0 -or
                -not [regex]::IsMatch(
                    [string]$identity.sha256,
                    '^[0-9a-f]{64}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
                -not [regex]::IsMatch(
                    [string]$identity.productMarker,
                    '^[A-Za-z0-9._-]+:[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'ImmutableFile identity is invalid.'
            }
        }
        'DynamicFile' { }
        'Directory' {
            Assert-CommMonitorOwnedCreationFlagSemantic `
                -OwnershipProof ([string]$OwnedObject.ownershipProof) `
                -Flag ([bool]$identity.created) `
                -Subject 'Directory created flag'
            if ([string]::Equals(
                    [string]$OwnedObject.contentPolicy,
                    'ProtectedManagedTree',
                    [StringComparison]::Ordinal) -and
                (-not [string]::Equals(
                        [string]$OwnedObject.root,
                        'DataRoot',
                        [StringComparison]::Ordinal) -or
                    -not [string]::IsNullOrEmpty(
                        [string]$OwnedObject.relativePath))) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'ProtectedManagedTree is allowed only for the DataRoot root object.'
            }
        }
        'Shortcut' {
            Assert-CommMonitorOwnedCreationFlagSemantic `
                -OwnershipProof ([string]$OwnedObject.ownershipProof) `
                -Flag ([bool]$identity.created) `
                -Subject 'Shortcut created flag'
            Assert-CommMonitorOwnedAbsolutePathSemantic `
                -Path ([string]$identity.target) `
                -Subject 'Shortcut target'
            Assert-CommMonitorOwnedAbsolutePathSemantic `
                -Path ([string]$identity.workingDirectory) `
                -Subject 'Shortcut workingDirectory'
            if (-not [regex]::IsMatch(
                    [string]$identity.fileSha256,
                    '^[0-9a-f]{64}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'Shortcut fileSha256 is not canonical.'
            }
        }
        'RegistryValue' {
            Assert-CommMonitorOwnedCreationFlagSemantic `
                -OwnershipProof ([string]$OwnedObject.ownershipProof) `
                -Flag ([bool]$identity.created) `
                -Subject 'RegistryValue created flag'
            if (-not [string]::Equals(
                    [string]$identity.hive,
                    'HKLM',
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$identity.view,
                    'Registry64',
                    [StringComparison]::Ordinal)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'RegistryValue requires HKLM Registry64.'
            }
            Assert-CommMonitorOwnedRegistryKeySemantic `
                -Key ([string]$identity.key) `
                -Subject 'RegistryValue key'
            if ([string]::IsNullOrEmpty([string]$identity.name)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'RegistryValue name must not be empty.'
            }
            switch -CaseSensitive ([string]$identity.kind) {
                'String' {
                    if ($identity.value -isnot [string]) {
                        Throw-CommMonitorOwnedObjectSemanticError `
                            -Message 'RegistryValue String requires a string value.'
                    }
                }
                'ExpandString' {
                    if ($identity.value -isnot [string]) {
                        Throw-CommMonitorOwnedObjectSemanticError `
                            -Message 'RegistryValue ExpandString requires a string value.'
                    }
                }
                'DWord' {
                    if ($identity.value -isnot [int]) {
                        Throw-CommMonitorOwnedObjectSemanticError `
                            -Message 'RegistryValue DWord requires an Int32 value.'
                    }
                }
                'QWord' {
                    if ($identity.value -isnot [int] -and
                        $identity.value -isnot [long]) {
                        Throw-CommMonitorOwnedObjectSemanticError `
                            -Message 'RegistryValue QWord requires an Int32 or Int64 value.'
                    }
                    $identity.value = [long]$identity.value
                }
                'MultiString' {
                    if ($identity.value -isnot [string[]]) {
                        Throw-CommMonitorOwnedObjectSemanticError `
                            -Message 'RegistryValue MultiString requires a string array.'
                    }
                }
                { $_ -in @('Binary', 'None') } {
                    if ($identity.value -isnot [string] -or
                        -not [regex]::IsMatch(
                            [string]$identity.value,
                            '^(?:[0-9a-f]{2})*$',
                            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                        Throw-CommMonitorOwnedObjectSemanticError `
                            -Message "RegistryValue $($_) requires lowercase even-length hex."
                    }
                }
                default {
                    Throw-CommMonitorOwnedObjectSemanticError `
                        -Message 'RegistryValue kind is unsupported.'
                }
            }
        }
        'RegistryKey' {
            Assert-CommMonitorOwnedCreationFlagSemantic `
                -OwnershipProof ([string]$OwnedObject.ownershipProof) `
                -Flag ([bool]$identity.created) `
                -Subject 'RegistryKey created flag'
            if (-not [string]::Equals(
                    [string]$identity.hive,
                    'HKLM',
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$identity.view,
                    'Registry64',
                    [StringComparison]::Ordinal)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'RegistryKey requires HKLM Registry64.'
            }
            Assert-CommMonitorOwnedRegistryKeySemantic `
                -Key ([string]$identity.key) `
                -Subject 'RegistryKey key'
        }
        'Service' {
            Assert-CommMonitorOwnedCreationProofSemantic `
                -OwnershipProof ([string]$OwnedObject.ownershipProof) `
                -CreationProof ([string]$identity.creationProof) `
                -Subject 'Service creationProof'
            if (-not [regex]::IsMatch(
                    [string]$identity.name,
                    '^[A-Za-z0-9._-]+$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
                -not [string]::Equals(
                    [string]$identity.serviceType,
                    'Win32OwnProcess',
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$identity.accountSid,
                    'S-1-5-18',
                    [StringComparison]::Ordinal)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'Service identity is invalid.'
            }
            Assert-CommMonitorOwnedAbsolutePathSemantic `
                -Path ([string]$identity.imagePath) `
                -Subject 'Service imagePath'
        }
        'DriverPackage' {
            Assert-CommMonitorOwnedCreationProofSemantic `
                -OwnershipProof ([string]$OwnedObject.ownershipProof) `
                -CreationProof ([string]$identity.creationProof) `
                -Subject 'DriverPackage creationProof'
            if (-not [regex]::IsMatch(
                    [string]$identity.publishedName,
                    '^oem[0-9]+\.inf$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
                -not [regex]::IsMatch(
                    [string]$identity.originalInfSha256,
                    '^[0-9a-f]{64}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'DriverPackage identity is invalid.'
            }
            Assert-CommMonitorOwnedAbsolutePathSemantic `
                -Path ([string]$identity.originalInfPath) `
                -Subject 'DriverPackage originalInfPath'
        }
        'Certificate' {
            Assert-CommMonitorOwnedCreationFlagSemantic `
                -OwnershipProof ([string]$OwnedObject.ownershipProof) `
                -Flag ([bool]$identity.added) `
                -Subject 'Certificate added flag'
            if (-not (Test-CommMonitorOrdinalValue `
                    -Value $identity.store `
                    -Allowed @(
                        'LocalMachine\TrustedPublisher',
                        'LocalMachine\Root')) -or
                -not [regex]::IsMatch(
                    [string]$identity.thumbprint,
                    '^[0-9a-f]{40}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
                -not [regex]::IsMatch(
                    [string]$identity.derSha256,
                    '^[0-9a-f]{64}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'Certificate identity is invalid.'
            }
        }
        'EventSource' {
            Assert-CommMonitorOwnedCreationProofSemantic `
                -OwnershipProof ([string]$OwnedObject.ownershipProof) `
                -CreationProof ([string]$identity.creationProof) `
                -Subject 'EventSource creationProof'
            if (-not [string]::Equals(
                    [string]$identity.log,
                    'Application',
                    [StringComparison]::Ordinal) -or
                -not [regex]::IsMatch(
                    [string]$identity.source,
                    '^[A-Za-z0-9._-]+$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'EventSource log or source is invalid.'
            }
            $expectedRegistration =
                'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\' +
                [string]$identity.log + '\' + [string]$identity.source
            if (-not [string]::Equals(
                    [string]$identity.registrationPath,
                    $expectedRegistration,
                    [StringComparison]::Ordinal)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'EventSource registrationPath is not bound to log and source.'
            }
            Assert-CommMonitorOwnedAbsolutePathSemantic `
                -Path ([string]$identity.messageFile) `
                -Subject 'EventSource messageFile'
        }
        'ScheduledTask' {
            $taskPrefix = 'LemonSerialMonitor-'
            $taskId = [Guid]::Empty
            if (-not ([string]$identity.name).StartsWith(
                    $taskPrefix,
                    [StringComparison]::Ordinal) -or
                -not [Guid]::TryParseExact(
                    ([string]$identity.name).Substring($taskPrefix.Length),
                    'D',
                    [ref]$taskId) -or
                -not [string]::Equals(
                    [string]$identity.name,
                    $taskPrefix + $taskId.ToString('D').ToLowerInvariant(),
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$identity.identitySid,
                    'S-1-5-18',
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$identity.trigger,
                    'AtStartup',
                    [StringComparison]::Ordinal) -or
                [string]::IsNullOrEmpty([string]$identity.arguments) -or
                -not [regex]::IsMatch(
                    [string]$identity.xmlSha256,
                    '^[0-9a-f]{64}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
                -not [string]::Equals(
                    [string]$OwnedObject.ownershipProof,
                    'CreatedThisInstall',
                    [StringComparison]::Ordinal)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'ScheduledTask identity is invalid.'
            }
            Assert-CommMonitorOwnedAbsolutePathSemantic `
                -Path ([string]$identity.finalizerPath) `
                -Subject 'ScheduledTask finalizerPath'
        }
        'FilterMetadata' {
            Assert-CommMonitorOwnedCreationFlagSemantic `
                -OwnershipProof ([string]$OwnedObject.ownershipProof) `
                -Flag ([bool]$identity.added) `
                -Subject 'FilterMetadata added flag'
            $classId = [Guid]::Empty
            if (-not [Guid]::TryParseExact(
                    [string]$identity.classKey,
                    'B',
                    [ref]$classId) -or
                -not [string]::Equals(
                    [string]$identity.classKey,
                    $classId.ToString('B').ToUpperInvariant(),
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$identity.valueName,
                    'UpperFilters',
                    [StringComparison]::Ordinal) -or
                [string]::IsNullOrWhiteSpace([string]$identity.entry)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'FilterMetadata identity is invalid.'
            }
        }
        'KeyMetadata' {
            if (-not [string]::Equals(
                    [string]$OwnedObject.ownershipProof,
                    'CreatedThisInstall',
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$identity.kind,
                    'ManifestHmacKey',
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$identity.state,
                    'Active',
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$identity.relativePath,
                    'state\manifest.key.v1.json',
                    [StringComparison]::Ordinal) -or
                -not [regex]::IsMatch(
                    [string]$identity.keyId,
                    '^[0-9a-f]{64}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'KeyMetadata identity is invalid.'
            }
        }
        'ContinuationMetadata' {
            if (-not [string]::Equals(
                    [string]$OwnedObject.ownershipProof,
                    'CreatedThisInstall',
                    [StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string]$identity.relativePath,
                    'state\continuation.v1.json',
                    [StringComparison]::Ordinal) -or
                -not [regex]::IsMatch(
                    [string]$identity.helperSha256,
                    '^[0-9a-f]{64}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
                -not [regex]::IsMatch(
                    [string]$identity.finalizerSha256,
                    '^[0-9a-f]{64}$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                Throw-CommMonitorOwnedObjectSemanticError `
                    -Message 'ContinuationMetadata identity is invalid.'
            }
            foreach ($pendingObjectId in @($identity.pendingObjectIds)) {
                if (-not [regex]::IsMatch(
                        [string]$pendingObjectId,
                        '^[a-z0-9][a-z0-9.-]*$',
                        [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                    Throw-CommMonitorOwnedObjectSemanticError `
                        -Message 'ContinuationMetadata pendingObjectIds are not canonical.'
                }
            }
        }
    }
    $OwnedObject.identity = $identity
}

function Copy-CommMonitorCanonicalOwnedObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $OwnedObject,
        [switch] $UseCentralPolicyErrors
    )

    $data = ConvertTo-CommMonitorSchemaObject `
        -Value $OwnedObject `
        -Subject 'Owned object'
    if (-not $data.Contains('type')) {
        throw "Owned object is missing required field 'type'."
    }
    $type = Copy-CommMonitorSchemaString `
        -Value $data['type'] `
        -Subject 'Owned object type'
    $identityFields = [string[]]@(Get-CommMonitorOwnedIdentityFields -Type $type)
    $pathTypes = @('ImmutableFile', 'DynamicFile', 'Directory', 'Shortcut')
    $allowed = [Collections.Generic.List[string]]::new()
    foreach ($field in @(
            'objectId', 'type', 'component', 'root', 'ownershipProof',
            'removeOnUninstall', 'deletePhase', 'identity')) {
        $allowed.Add($field)
    }
    if (Test-CommMonitorOrdinalValue -Value $type -Allowed $pathTypes) {
        $allowed.Add('relativePath')
    }
    if (Test-CommMonitorOrdinalValue -Value $type -Allowed @('Directory')) {
        $allowed.Add('contentPolicy')
    }
    Assert-CommMonitorExactFields `
        -Dictionary $data `
        -Allowed $allowed.ToArray() `
        -Required $allowed.ToArray() `
        -Subject 'Owned object'
    $objectId = Copy-CommMonitorSchemaString `
        -Value $data['objectId'] `
        -Subject 'Owned object objectId'
    $component = Copy-CommMonitorSchemaString `
        -Value $data['component'] `
        -Subject 'Owned object component'
    $root = Copy-CommMonitorSchemaString `
        -Value $data['root'] `
        -Subject 'Owned object root'
    $ownershipProof = Copy-CommMonitorSchemaString `
        -Value $data['ownershipProof'] `
        -Subject 'Owned object ownershipProof'
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $ownershipProof `
            -Allowed @(
                'CreatedThisInstall',
                'VerifiedLegacyAdoption',
                'PreExistingShared'))) {
        throw "Invalid ownership proof '$ownershipProof'."
    }
    $policy = Get-CommMonitorOwnedObjectPolicy
    if (-not $UseCentralPolicyErrors -and
        -not $policy.ComponentRules.ContainsKey($component)) {
        throw "Owned object has an unknown component '$component'."
    }
    $knownRoots = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($typeRoots in $policy.TypeRoots.Values) {
        foreach ($knownRoot in @($typeRoots)) {
            [void]$knownRoots.Add([string]$knownRoot)
        }
    }
    if (-not $UseCentralPolicyErrors -and -not $knownRoots.Contains($root)) {
        throw "Owned object has an unknown root '$root'."
    }
    $contentPolicy = $null
    if (Test-CommMonitorOrdinalValue -Value $type -Allowed @('Directory')) {
        $contentPolicy = Copy-CommMonitorSchemaString `
            -Value $data['contentPolicy'] `
            -Subject 'Owned object contentPolicy'
        if (-not (Test-CommMonitorOrdinalValue `
                -Value $contentPolicy `
                -Allowed @('EmptyAfterOwnedChildren', 'ProtectedManagedTree'))) {
            throw 'Directory requires a supported contentPolicy.'
        }
    }
    $identity = ConvertTo-CommMonitorSchemaObject `
        -Value $data['identity'] `
        -Subject "$type identity"
    Assert-CommMonitorExactFields `
        -Dictionary $identity `
        -Allowed $identityFields `
        -Required $identityFields `
        -Subject "$type identity"

    $identityCopy = [ordered]@{}
    foreach ($identityField in $identityFields) {
        if ($identityField -eq 'size') {
            $identityCopy[$identityField] = Copy-CommMonitorSchemaInt64 `
                -Value $identity[$identityField] `
                -Subject 'ImmutableFile identity size'
        }
        elseif ($identityField -eq 'pendingObjectIds') {
            $identityCopy[$identityField] = Copy-CommMonitorCanonicalStringSet `
                -Value $identity[$identityField] `
                -Subject 'ContinuationMetadata identity pendingObjectIds'
        }
        elseif ($identityField -eq 'value' -and $type -eq 'RegistryValue') {
            $value = $identity[$identityField]
            if ($value -is [string]) {
                $identityCopy[$identityField] = [string]$value
            }
            elseif ($value -is [int]) {
                $identityCopy[$identityField] = [int]$value
            }
            elseif ($value -is [long]) {
                $identityCopy[$identityField] = [long]$value
            }
            elseif ($value -is [byte[]] -or
                ($value -is [Array] -and
                    $value.Count -gt 0 -and
                    @($value | Where-Object { $_ -isnot [byte] }).Count -eq 0)) {
                throw ('RegistryValue identity value must be a raw string, ' +
                    'raw System.Array of strings, raw Int32 or raw Int64.')
            }
            elseif ($value -is [Array]) {
                $identityCopy[$identityField] = Copy-CommMonitorSchemaStringArray `
                    -Value $value `
                    -Subject 'RegistryValue identity value'
            }
            else {
                throw ('RegistryValue identity value must be a raw string, ' +
                    'raw System.Array of strings, raw Int32 or raw Int64.')
            }
        }
        elseif ($identityField -in @('created', 'added')) {
            $identityCopy[$identityField] = Copy-CommMonitorSchemaBoolean `
                -Value $identity[$identityField] `
                -Subject "$type identity $identityField"
        }
        else {
            $identityCopy[$identityField] = Copy-CommMonitorSchemaString `
                -Value $identity[$identityField] `
                -Subject "$type identity $identityField"
        }
    }

    $copy = [ordered]@{}
    foreach ($field in $allowed) {
        switch ($field) {
            'objectId' { $copy[$field] = $objectId }
            'type' { $copy[$field] = $type }
            'component' { $copy[$field] = $component }
            'root' { $copy[$field] = $root }
            'ownershipProof' { $copy[$field] = $ownershipProof }
            'removeOnUninstall' {
                $copy[$field] = Copy-CommMonitorSchemaBoolean `
                    -Value $data[$field] `
                    -Subject 'Owned object removeOnUninstall'
            }
            'deletePhase' {
                $copy[$field] = Copy-CommMonitorSchemaInt32 `
                    -Value $data[$field] `
                    -Subject 'Owned object deletePhase'
            }
            'identity' { $copy[$field] = $identityCopy }
            'relativePath' {
                $copy[$field] = Copy-CommMonitorSchemaString `
                    -Value $data[$field] `
                    -Subject 'Owned object relativePath'
            }
            'contentPolicy' { $copy[$field] = $contentPolicy }
        }
    }
    [void](Assert-CommMonitorOwnedObjectPolicy -OwnedObject $copy)
    Assert-CommMonitorOwnedObjectSemantics -OwnedObject $copy
    return $copy
}

function ConvertTo-CommMonitorCanonicalOwnershipPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Payload)

    $data = ConvertTo-CommMonitorSchemaObject `
        -Value $Payload `
        -Subject 'Ownership payload'
    $fields = @(
        'appId', 'installId', 'revision', 'previousPayloadSha256',
        'productVersion', 'createdUtc', 'platform', 'roots', 'authorizedUser',
        'ownedObjects', 'upperFiltersRollback', 'keyMetadata',
        'continuationState', 'state', 'operationState')
    Assert-CommMonitorExactFields `
        -Dictionary $data `
        -Allowed $fields `
        -Required $fields `
        -Subject 'Ownership payload'
    $appId = Copy-CommMonitorSchemaString `
        -Value $data['appId'] `
        -Subject 'Ownership payload appId'
    $installId = Copy-CommMonitorSchemaString `
        -Value $data['installId'] `
        -Subject 'Ownership payload installId'
    $revision = Copy-CommMonitorSchemaInt32 `
        -Value $data['revision'] `
        -Subject 'Ownership payload revision'
    $previousPayloadSha256 = Copy-CommMonitorNullableSchemaString `
        -Value $data['previousPayloadSha256'] `
        -Subject 'Ownership payload previousPayloadSha256'
    $productVersion = Copy-CommMonitorSchemaString `
        -Value $data['productVersion'] `
        -Subject 'Ownership payload productVersion'
    $createdUtc = Copy-CommMonitorSchemaString `
        -Value $data['createdUtc'] `
        -Subject 'Ownership payload createdUtc'
    $state = Copy-CommMonitorSchemaString `
        -Value $data['state'] `
        -Subject 'Ownership payload state'
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $state `
            -Allowed @(
                'Committed',
                'UninstallRequested',
                'UninstallPrepared',
                'PendingReboot',
                'Abandoned',
                'FinalizingAbsent'))) {
        throw 'Ownership state must be an exact supported value.'
    }

    $platform = ConvertTo-CommMonitorSchemaObject `
        -Value $data['platform'] `
        -Subject 'Platform signature'
    $platformFields = @('kind', 'build', 'components')
    Assert-CommMonitorExactFields `
        -Dictionary $platform `
        -Allowed $platformFields `
        -Required $platformFields `
        -Subject 'Platform signature'
    $platformKind = Copy-CommMonitorSchemaString `
        -Value $platform['kind'] `
        -Subject 'Platform kind'
    if ($platform['build'] -isnot [int]) {
        throw 'Platform build must be a raw Int32. Platform build must be a raw integer.'
    }
    $platformBuild = [int]$platform['build']
    if ($platform['components'] -isnot [Array]) {
        throw ('Platform components must be a raw System.Array. ' +
            'Platform components must be a raw array of exact strings.')
    }
    foreach ($component in $platform['components']) {
        if ($component -isnot [string]) {
            throw ('Platform components members must be raw strings. ' +
                'Platform components must be a raw array of exact strings.')
        }
    }
    $platformComponents = Copy-CommMonitorCanonicalStringSet `
        -Value $platform['components'] `
        -Subject 'Platform components'
    $expectedComponents = [string[]]@(
        Get-CommMonitorExpectedPlatformComponents -PlatformKind $platformKind)
    foreach ($component in $platformComponents) {
        if (-not (Test-CommMonitorOrdinalValue `
                -Value $component `
                -Allowed $expectedComponents)) {
            throw "Platform components contain an unknown component '$component'."
        }
    }
    $platformCopy = [ordered]@{
        kind = $platformKind
        build = $platformBuild
        components = $platformComponents
    }

    $upperFilters = ConvertTo-CommMonitorSchemaObject `
        -Value $data['upperFiltersRollback'] `
        -Subject 'UpperFilters rollback'
    $upperFields = @('present', 'value')
    Assert-CommMonitorExactFields `
        -Dictionary $upperFilters `
        -Allowed $upperFields `
        -Required $upperFields `
        -Subject 'UpperFilters rollback'
    $upperValue = if ($null -eq $upperFilters['value']) {
        $null
    }
    else {
        Copy-CommMonitorSchemaStringArray `
            -Value $upperFilters['value'] `
            -Subject 'UpperFilters rollback value'
    }
    $upperCopy = [ordered]@{
        present = Copy-CommMonitorSchemaBoolean `
            -Value $upperFilters['present'] `
            -Subject 'UpperFilters rollback present'
        value = $upperValue
    }

    $keyMetadata = ConvertTo-CommMonitorSchemaObject `
        -Value $data['keyMetadata'] `
        -Subject 'Key metadata'
    Assert-CommMonitorExactFields `
        -Dictionary $keyMetadata `
        -Allowed @('manifest') `
        -Required @('manifest') `
        -Subject 'Key metadata'
    $manifestKey = ConvertTo-CommMonitorSchemaObject `
        -Value $keyMetadata['manifest'] `
        -Subject 'Manifest key metadata'
    Assert-CommMonitorExactFields `
        -Dictionary $manifestKey `
        -Allowed @('state', 'keyId') `
        -Required @('state', 'keyId') `
        -Subject 'Manifest key metadata'
    $keyCopy = [ordered]@{
        manifest = [ordered]@{
            state = Copy-CommMonitorSchemaString `
                -Value $manifestKey['state'] `
                -Subject 'Manifest key metadata state'
            keyId = Copy-CommMonitorSchemaString `
                -Value $manifestKey['keyId'] `
                -Subject 'Manifest key metadata keyId'
        }
    }

    $continuation = ConvertTo-CommMonitorSchemaObject `
        -Value $data['continuationState'] `
        -Subject 'Continuation state'
    Assert-CommMonitorExactFields `
        -Dictionary $continuation `
        -Allowed @('status') `
        -Required @('status') `
        -Subject 'Continuation state'
    $continuationCopy = [ordered]@{
        status = Copy-CommMonitorSchemaString `
            -Value $continuation['status'] `
            -Subject 'Continuation state status'
    }

    $operationCopy = ConvertTo-CommMonitorCanonicalOperationState `
        -State $state `
        -OperationState $data['operationState']

    Assert-CommMonitorRawSchemaArray `
        -Value $data['ownedObjects'] `
        -Subject 'Ownership payload ownedObjects'
    $owned = [Collections.Generic.List[object]]::new()
    foreach ($ownedObject in $data['ownedObjects']) {
        if (-not (Test-CommMonitorRawSchemaObject -Value $ownedObject)) {
            throw 'Ownership payload ownedObjects members must be raw objects.'
        }
        $owned.Add((Copy-CommMonitorCanonicalOwnedObject -OwnedObject $ownedObject))
    }
    $owned.Sort([Comparison[object]] {
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string]$left.objectId,
                [string]$right.objectId)
        })

    $rootsCopy = ConvertTo-CommMonitorCanonicalOwnershipRoots `
        -Roots $data['roots'] `
        -InputCasing Canonical
    $authorizedUserCopy = ConvertTo-CommMonitorCanonicalAuthorizedUser `
        -AuthorizedUser $data['authorizedUser'] `
        -InputCasing Canonical
    $canonicalPayload = [pscustomobject][ordered]@{
        appId = $appId
        installId = $installId
        revision = $revision
        previousPayloadSha256 = $previousPayloadSha256
        productVersion = $productVersion
        createdUtc = $createdUtc
        platform = $platformCopy
        roots = $rootsCopy
        authorizedUser = $authorizedUserCopy
        ownedObjects = $owned.ToArray()
        upperFiltersRollback = $upperCopy
        keyMetadata = $keyCopy
        continuationState = $continuationCopy
        state = $state
        operationState = $operationCopy
    }
    Assert-CommMonitorOwnershipRootSemantics `
        -PlatformKind ([string]$platformCopy.kind) `
        -Roots $rootsCopy `
        -AuthorizedUser $authorizedUserCopy
    Assert-CommMonitorOwnershipLayoutSemantics `
        -PlatformKind ([string]$platformCopy.kind) `
        -PlatformComponents $platformCopy.components `
        -Roots $rootsCopy `
        -OwnedObjects $owned.ToArray()
    Assert-CommMonitorOwnershipCrossObjectSemantics `
        -ProductVersion $productVersion `
        -InstallId $installId `
        -Roots $rootsCopy `
        -KeyMetadata $keyCopy `
        -OwnedObjects $owned.ToArray()
    Assert-CommMonitorOwnershipOperationStateSemantics `
        -State $state `
        -OperationState $operationCopy `
        -OwnedObjects $owned.ToArray()
    Assert-CommMonitorOwnershipCommittedStateSemantics `
        -State $state `
        -ContinuationState $continuationCopy `
        -OperationState $operationCopy `
        -KeyMetadata $keyCopy `
        -OwnedObjects $owned.ToArray()
    return $canonicalPayload
}

function Assert-CommMonitorRelativeOrdinaryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Path,
        [bool] $AllowEmpty = $false
    )

    if ([string]::IsNullOrEmpty($Path)) {
        if ($AllowEmpty) { return }
        throw 'Owned relative path must not be empty.'
    }
    if ($Path.Contains('/') -or
        $Path.Contains(':') -or
        $Path.Contains('*') -or
        $Path.Contains('?') -or
        $Path.StartsWith('\', [StringComparison]::Ordinal) -or
        [regex]::IsMatch($Path, '^[A-Za-z]:')) {
        throw "Owned path is not an ordinary relative path: '$Path'."
    }
    foreach ($segment in @($Path -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or
            $segment -in @('.', '..') -or
            $segment.EndsWith('.', [StringComparison]::Ordinal) -or
            $segment.EndsWith(' ', [StringComparison]::Ordinal) -or
            [regex]::IsMatch($segment, '[<>"|]') -or
            [regex]::IsMatch(
                $segment,
                '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$')) {
            throw "Owned path contains unsafe segment '$segment'."
        }
    }
}

function Assert-CommMonitorHash {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][int] $Length,
        [Parameter(Mandatory)][string] $Name
    )

    if (-not [regex]::IsMatch(
            [string]$Value,
            ('^[0-9a-f]{{{0}}}$' -f $Length),
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw "$Name must be a lowercase $Length-character hexadecimal value."
    }
}

function ConvertTo-CommMonitorCanonicalProfileUserSid {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object] $Sid)

    if ($Sid -isnot [string]) {
        throw 'Authorized user SID must be a raw canonical Windows SecurityIdentifier.'
    }
    try {
        $parsed = [Security.Principal.SecurityIdentifier]::new([string]$Sid)
    }
    catch {
        throw 'Authorized user SID must be a raw canonical Windows SecurityIdentifier.'
    }
    $canonical = $parsed.Value
    if (-not [string]::Equals(
            [string]$Sid,
            $canonical,
            [StringComparison]::Ordinal) -or
        $canonical -in @(
            'S-1-0-0', 'S-1-1-0', 'S-1-2-0', 'S-1-3-0', 'S-1-3-1',
            'S-1-5-18', 'S-1-5-19', 'S-1-5-20') -or
        $canonical.StartsWith('S-1-5-5-', [StringComparison]::Ordinal) -or
        $canonical.StartsWith('S-1-5-32-', [StringComparison]::Ordinal) -or
        $canonical.StartsWith('S-1-5-80-', [StringComparison]::Ordinal) -or
        $canonical.StartsWith('S-1-5-90-', [StringComparison]::Ordinal) -or
        $canonical.StartsWith('S-1-15-', [StringComparison]::Ordinal) -or
        $canonical.StartsWith('S-1-16-', [StringComparison]::Ordinal)) {
        throw 'Authorized user SID must be a raw canonical Windows SecurityIdentifier for a profile user.'
    }
    return $canonical
}

function Get-CommMonitorExpectedPlatformComponents {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][object] $PlatformKind)

    if ($PlatformKind -isnot [string]) {
        throw 'Platform kind must be an exact supported value.'
    }
    if ([string]::Equals(
            [string]$PlatformKind,
            'Desktop',
            [StringComparison]::Ordinal) -or
        [string]::Equals(
            [string]$PlatformKind,
            'ServerDesktop',
            [StringComparison]::Ordinal)) {
        return [string[]]@(
            'WPF',
            'Service',
            'Driver',
            'AI',
            'StartMenuShortcut')
    }
    if ([string]::Equals(
            [string]$PlatformKind,
            'ServerCore',
            [StringComparison]::Ordinal)) {
        return [string[]]@('Headless', 'Service', 'Driver', 'AI')
    }
    throw 'Platform kind must be an exact supported value.'
}

function Assert-CommMonitorExactPlatformComponents {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][object] $PlatformKind,
        [Parameter(Mandatory)][AllowEmptyCollection()][object] $PlatformComponents
    )

    $expected = [string[]]@(Get-CommMonitorExpectedPlatformComponents `
            -PlatformKind $PlatformKind)
    $expectedSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($component in $expected) {
        [void]$expectedSet.Add($component)
    }

    $valid = $PlatformComponents -is [Array]
    $actual = [Collections.Generic.List[string]]::new()
    $actualSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    if ($valid) {
        foreach ($component in @($PlatformComponents)) {
            if ($component -isnot [string]) {
                $valid = $false
                continue
            }
            $componentName = [string]$component
            $actual.Add($componentName)
            if (-not $actualSet.Add($componentName) -or
                -not $expectedSet.Contains($componentName)) {
                $valid = $false
            }
        }
        if ($actual.Count -ne $expected.Count) {
            $valid = $false
        }
        foreach ($component in $expected) {
            if (-not $actualSet.Contains($component)) {
                $valid = $false
            }
        }
    }
    if (-not $valid) {
        throw ("{0} requires the exact component set {{{1}}}." -f
            [string]$PlatformKind,
            [string]::Join(', ', $expected))
    }
    return [string[]]$actual.ToArray()
}

function Assert-CommMonitorSupportedPlatformBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $PlatformKind,
        [Parameter(Mandatory)][object] $PlatformBuild
    )

    if ($PlatformBuild -isnot [int]) {
        throw 'Platform build must be a raw integer.'
    }
    $supportedBuilds = if ([string]::Equals(
            [string]$PlatformKind,
            'Desktop',
            [StringComparison]::Ordinal)) {
        @(19045, 22000, 22621, 22631, 26100)
    }
    elseif ([string]::Equals(
            [string]$PlatformKind,
            'ServerDesktop',
            [StringComparison]::Ordinal) -or
        [string]::Equals(
            [string]$PlatformKind,
            'ServerCore',
            [StringComparison]::Ordinal)) {
        @(17763, 20348, 26100)
    }
    else {
        [void](Get-CommMonitorExpectedPlatformComponents -PlatformKind $PlatformKind)
        @()
    }
    if ([int]$PlatformBuild -notin $supportedBuilds) {
        $displayKind = if ([string]::Equals(
                [string]$PlatformKind,
                'ServerCore',
                [StringComparison]::Ordinal)) {
            'Server Core'
        }
        else {
            [string]$PlatformKind
        }
        throw "Unsupported $displayKind build '$PlatformBuild'."
    }
}

function Get-CommMonitorOwnedObjectPolicy {
    [CmdletBinding()]
    param()

    $typeRoots = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal)
    $typeRoots.Add('ImmutableFile', [string[]]@('AppRoot', 'CoreRoot', 'InstallerRoot'))
    $typeRoots.Add('DynamicFile', [string[]]@('AiStateRoot', 'DataRoot', 'InstallerRoot'))
    $typeRoots.Add(
        'Directory',
        [string[]]@(
            'AppRoot', 'CoreRoot', 'AiStateRoot', 'DataRoot', 'InstallerRoot'))
    $typeRoots.Add('Shortcut', [string[]]@('StartMenu', 'Desktop'))
    $typeRoots.Add('RegistryValue', [string[]]@('Registry'))
    $typeRoots.Add('RegistryKey', [string[]]@('Registry'))
    $typeRoots.Add('Service', [string[]]@('System'))
    $typeRoots.Add('DriverPackage', [string[]]@('System'))
    $typeRoots.Add('Certificate', [string[]]@('System'))
    $typeRoots.Add('EventSource', [string[]]@('System'))
    $typeRoots.Add('ScheduledTask', [string[]]@('System'))
    $typeRoots.Add('FilterMetadata', [string[]]@('Registry'))
    $typeRoots.Add('KeyMetadata', [string[]]@('InstallerRoot'))
    $typeRoots.Add('ContinuationMetadata', [string[]]@('InstallerRoot'))

    $componentRules = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal)
    $componentRules.Add('DesktopExecutable', [pscustomobject]@{
            PlatformComponent = 'WPF'
            Pairs = [string[]]@('ImmutableFile|AppRoot')
        })
    $componentRules.Add('AiCli', [pscustomobject]@{
            PlatformComponent = 'AI'
            Pairs = [string[]]@(
                'ImmutableFile|AppRoot',
                'ImmutableFile|CoreRoot')
        })
    $componentRules.Add('Headless', [pscustomobject]@{
            PlatformComponent = 'Headless'
            Pairs = [string[]]@('ImmutableFile|CoreRoot')
        })
    $componentRules.Add('AiState', [pscustomobject]@{
            PlatformComponent = 'AI'
            Pairs = [string[]]@('DynamicFile|AiStateRoot', 'Directory|AiStateRoot')
        })
    $componentRules.Add('StartMenuShortcut', [pscustomobject]@{
            PlatformComponent = 'StartMenuShortcut'
            Pairs = [string[]]@('Shortcut|StartMenu')
        })
    $componentRules.Add('Service', [pscustomobject]@{
            PlatformComponent = 'Service'
            Pairs = [string[]]@(
                'ImmutableFile|CoreRoot',
                'Service|System',
                'EventSource|System')
        })
    $componentRules.Add('Driver', [pscustomobject]@{
            PlatformComponent = 'Driver'
            Pairs = [string[]]@(
                'ImmutableFile|CoreRoot',
                'DriverPackage|System',
                'Certificate|System',
                'FilterMetadata|Registry',
                'RegistryValue|Registry',
                'RegistryKey|Registry')
        })
    $componentRules.Add('Data', [pscustomobject]@{
            PlatformComponent = $null
            Pairs = [string[]]@('DynamicFile|DataRoot', 'Directory|DataRoot')
        })
    $componentRules.Add('Uninstall', [pscustomobject]@{
            PlatformComponent = $null
            Pairs = [string[]]@(
                'RegistryValue|Registry',
                'RegistryKey|Registry',
                'ImmutableFile|InstallerRoot',
                'DynamicFile|InstallerRoot',
                'Directory|InstallerRoot',
                'KeyMetadata|InstallerRoot')
        })
    $componentRules.Add('Continuation', [pscustomobject]@{
            PlatformComponent = $null
            Pairs = [string[]]@(
                'ScheduledTask|System',
                'ContinuationMetadata|InstallerRoot')
        })
    $componentRules.Add('RootDirectory', [pscustomobject]@{
            PlatformComponent = $null
            Pairs = [string[]]@(
                'Directory|AppRoot',
                'Directory|CoreRoot')
        })
    $componentRules.Add('DesktopShortcut', [pscustomobject]@{
            PlatformComponent = $null
            Pairs = [string[]]@('Shortcut|Desktop')
        })
    $componentRules.Add('Docs', [pscustomobject]@{
            PlatformComponent = $null
            Pairs = [string[]]@(
                'ImmutableFile|AppRoot',
                'ImmutableFile|CoreRoot',
                'Directory|AppRoot',
                'Directory|CoreRoot')
        })

    return [pscustomobject]@{
        TypeRoots = $typeRoots
        ComponentRules = $componentRules
    }
}

function Assert-CommMonitorOwnedObjectPolicy {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary] $OwnedObject
    )

    $type = $OwnedObject.type
    $root = $OwnedObject.root
    $component = $OwnedObject.component
    $policy = Get-CommMonitorOwnedObjectPolicy
    if ($type -isnot [string] -or
        $root -isnot [string] -or
        -not $policy.TypeRoots.ContainsKey([string]$type)) {
        throw ("Owned-object type/root policy rejects type '{0}' under root '{1}'." -f
            [string]$type,
            [string]$root)
    }
    $allowedRoots = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($allowedRoot in @($policy.TypeRoots[[string]$type])) {
        [void]$allowedRoots.Add([string]$allowedRoot)
    }
    if (-not $allowedRoots.Contains([string]$root)) {
        throw ("Owned-object type/root policy rejects type '{0}' under root '{1}'." -f
            [string]$type,
            [string]$root)
    }
    if ($component -isnot [string] -or
        -not $policy.ComponentRules.ContainsKey([string]$component)) {
        throw ("Owned-object component policy rejects component '{0}' for type '{1}' under root '{2}'." -f
            [string]$component,
            [string]$type,
            [string]$root)
    }
    $componentRule = $policy.ComponentRules[[string]$component]
    $allowedPairs = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($allowedPair in @($componentRule.Pairs)) {
        [void]$allowedPairs.Add([string]$allowedPair)
    }
    $pair = '{0}|{1}' -f [string]$type, [string]$root
    if (-not $allowedPairs.Contains($pair)) {
        throw ("Owned-object component policy rejects component '{0}' for type '{1}' under root '{2}'." -f
            [string]$component,
            [string]$type,
            [string]$root)
    }
    return [string]$componentRule.PlatformComponent
}

function New-CommMonitorOwnedObject {
    [CmdletBinding()]
    [OutputType([Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object] $Definition
    )

    $object = Copy-CommMonitorCanonicalOwnedObject `
        -OwnedObject $Definition `
        -UseCentralPolicyErrors
    $pathTypes = @('ImmutableFile', 'DynamicFile', 'Directory', 'Shortcut')
    $allowedCommon = @(
        'objectId', 'type', 'component', 'root',
        'ownershipProof', 'removeOnUninstall', 'deletePhase', 'identity')
    if (Test-CommMonitorOrdinalValue -Value $object.type -Allowed $pathTypes) {
        $allowedCommon += 'relativePath'
    }
    if (Test-CommMonitorOrdinalValue -Value $object.type -Allowed @('Directory')) {
        $allowedCommon += 'contentPolicy'
    }
    Assert-CommMonitorExactFields `
        -Dictionary $object `
        -Allowed $allowedCommon `
        -Required @(
            'objectId', 'type', 'component', 'root', 'ownershipProof',
            'removeOnUninstall', 'deletePhase', 'identity') `
        -Subject 'Owned object'

    if (-not [regex]::IsMatch(
            [string]$object.objectId,
            '^[a-z0-9][a-z0-9.-]*$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw "Invalid objectId '$($object.objectId)'."
    }
    [void](Assert-CommMonitorOwnedObjectPolicy -OwnedObject $object)
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $object.ownershipProof `
            -Allowed @(
                'CreatedThisInstall',
                'VerifiedLegacyAdoption',
                'PreExistingShared'))) {
        throw "Invalid ownership proof '$($object.ownershipProof)'."
    }
    if ((Test-CommMonitorOrdinalValue `
            -Value $object.ownershipProof `
            -Allowed @('PreExistingShared')) -and
        [bool]$object.removeOnUninstall) {
        throw 'PreExistingShared objects cannot enter a delete plan.'
    }
    if ([int]$object.deletePhase -lt 0) {
        throw 'deletePhase must be non-negative.'
    }

    $identity = ConvertTo-CommMonitorOrderedDictionary -InputObject $object.identity
    $object.identity = $identity
    if (Test-CommMonitorOrdinalValue -Value $object.type -Allowed $pathTypes) {
        if (-not $object.Contains('relativePath')) {
            throw "$($object.type) requires relativePath."
        }
        Assert-CommMonitorRelativeOrdinaryPath `
            -Path ([string]$object.relativePath) `
            -AllowEmpty (Test-CommMonitorOrdinalValue `
                -Value $object.type `
                -Allowed @('Directory'))
    }
    elseif ($object.Contains('relativePath')) {
        throw "$($object.type) does not accept relativePath."
    }

    $allowedIdentity = @()
    $requiredIdentity = @()
    switch -CaseSensitive ($object.type) {
        'ImmutableFile' {
            $allowedIdentity = $requiredIdentity = @('size', 'sha256', 'productMarker')
            if ([long]$identity.size -lt 0) { throw 'ImmutableFile size must be non-negative.' }
            Assert-CommMonitorHash -Value $identity.sha256 -Length 64 -Name sha256
        }
        'DynamicFile' {
            $allowedIdentity = $requiredIdentity = @()
        }
        'Directory' {
            $allowedIdentity = $requiredIdentity = @('created')
            if (-not $object.Contains('contentPolicy') -or
                -not (Test-CommMonitorOrdinalValue `
                    -Value $object.contentPolicy `
                    -Allowed @(
                        'EmptyAfterOwnedChildren',
                        'ProtectedManagedTree'))) {
                throw 'Directory requires a supported contentPolicy.'
            }
            if ((Test-CommMonitorOrdinalValue `
                    -Value $object.contentPolicy `
                    -Allowed @('ProtectedManagedTree')) -and
                -not (Test-CommMonitorOrdinalValue `
                    -Value $object.root `
                    -Allowed @('DataRoot'))) {
                throw 'ProtectedManagedTree is allowed only under DataRoot.'
            }
        }
        'Shortcut' {
            $allowedIdentity = $requiredIdentity = @(
                'target', 'arguments', 'workingDirectory', 'fileSha256', 'created')
            Assert-CommMonitorHash -Value $identity.fileSha256 -Length 64 -Name fileSha256
        }
        'RegistryValue' {
            $allowedIdentity = $requiredIdentity = @(
                'hive', 'view', 'key', 'name', 'kind', 'value', 'created')
            if (-not (Test-CommMonitorOrdinalValue `
                    -Value $identity.hive `
                    -Allowed @('HKLM', 'HKCU')) -or
                -not (Test-CommMonitorOrdinalValue `
                    -Value $identity.view `
                    -Allowed @('Registry64'))) {
                throw 'RegistryValue requires an exact supported hive and 64-bit view.'
            }
        }
        'RegistryKey' {
            $allowedIdentity = $requiredIdentity = @('hive', 'view', 'key', 'created')
        }
        'Service' {
            $allowedIdentity = $requiredIdentity = @(
                'name', 'serviceType', 'imagePath', 'arguments',
                'accountSid', 'creationProof')
        }
        'DriverPackage' {
            $allowedIdentity = $requiredIdentity = @(
                'publishedName', 'originalInfPath', 'originalInfSha256', 'creationProof')
            if (-not [regex]::IsMatch(
                    [string]$identity.publishedName,
                    '^oem[0-9]+\.inf$',
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                throw 'DriverPackage publishedName must be an exact lowercase oem#.inf.'
            }
            Assert-CommMonitorHash `
                -Value $identity.originalInfSha256 `
                -Length 64 `
                -Name originalInfSha256
        }
        'Certificate' {
            $allowedIdentity = $requiredIdentity = @(
                'store', 'thumbprint', 'derSha256', 'added')
            if (-not ([string]$identity.store).StartsWith(
                    'LocalMachine\',
                    [StringComparison]::Ordinal)) {
                throw 'Certificate store must be under LocalMachine.'
            }
            Assert-CommMonitorHash -Value $identity.thumbprint -Length 40 -Name thumbprint
            Assert-CommMonitorHash -Value $identity.derSha256 -Length 64 -Name derSha256
        }
        'EventSource' {
            $allowedIdentity = $requiredIdentity = @(
                'log', 'source', 'registrationPath', 'messageFile', 'creationProof')
        }
        'ScheduledTask' {
            $allowedIdentity = $requiredIdentity = @(
                'name', 'identitySid', 'trigger', 'finalizerPath',
                'arguments', 'xmlSha256')
            if ($identity.identitySid -ne 'S-1-5-18') {
                throw 'Continuation ScheduledTask must run as SYSTEM.'
            }
            Assert-CommMonitorHash -Value $identity.xmlSha256 -Length 64 -Name xmlSha256
        }
        'FilterMetadata' {
            $allowedIdentity = $requiredIdentity = @(
                'classKey', 'valueName', 'entry', 'added')
        }
        'KeyMetadata' {
            $allowedIdentity = $requiredIdentity = @('kind', 'state', 'relativePath', 'keyId')
        }
        'ContinuationMetadata' {
            $allowedIdentity = $requiredIdentity = @(
                'relativePath', 'pendingObjectIds', 'helperSha256', 'finalizerSha256')
            Assert-CommMonitorHash -Value $identity.helperSha256 -Length 64 -Name helperSha256
            Assert-CommMonitorHash -Value $identity.finalizerSha256 -Length 64 -Name finalizerSha256
        }
    }
    Assert-CommMonitorExactFields `
        -Dictionary $identity `
        -Allowed $allowedIdentity `
        -Required $requiredIdentity `
        -Subject "$($object.type) identity"

    $identitySnapshot = [ordered]@{}
    foreach ($identityField in $allowedIdentity) {
        $identitySnapshot[$identityField] = Copy-CommMonitorManifestSchemaValue `
            -Value $identity[$identityField]
    }
    $object.identity = $identitySnapshot

    return $object
}

function Assert-CommMonitorOwnershipLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $PlatformKind,
        [Parameter(Mandatory)][AllowEmptyCollection()][object] $PlatformComponents,
        [Parameter(Mandatory)][object[]] $OwnedObjects
    )

    $validatedPlatformComponents = [string[]]@(
        Assert-CommMonitorExactPlatformComponents `
            -PlatformKind $PlatformKind `
            -PlatformComponents $PlatformComponents)
    $platformComponentSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($platformComponent in $validatedPlatformComponents) {
        [void]$platformComponentSet.Add($platformComponent)
    }

    $ownedComponents = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($ownedObjectInput in @($OwnedObjects)) {
        $ownedObject = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $ownedObjectInput
        $requiredPlatformComponent = Assert-CommMonitorOwnedObjectPolicy `
            -OwnedObject $ownedObject
        if (-not [string]::IsNullOrEmpty($requiredPlatformComponent) -and
            -not $platformComponentSet.Contains($requiredPlatformComponent)) {
            throw ("Owned object '{0}' component '{1}' requires platform component '{2}'." -f
                [string]$ownedObject.objectId,
                [string]$ownedObject.component,
                $requiredPlatformComponent)
        }
        [void]$ownedComponents.Add([string]$ownedObject.component)
        if ([string]::Equals(
                [string]$PlatformKind,
                'ServerCore',
                [StringComparison]::Ordinal) -and
            (Test-CommMonitorOrdinalValue `
                -Value $ownedObject.type `
                -Allowed @(
                    'ImmutableFile',
                    'DynamicFile',
                    'Directory',
                    'Shortcut')) -and
            [string]::Equals(
                [string]$ownedObject.root,
                'AppRoot',
                [StringComparison]::Ordinal)) {
            throw 'Server Core rejects every AppRoot owned object.'
        }
    }
    if (Test-CommMonitorOrdinalValue `
            -Value $PlatformKind `
            -Allowed @('Desktop', 'ServerDesktop')) {
        foreach ($required in @('DesktopExecutable', 'AiCli', 'StartMenuShortcut')) {
            if (-not $ownedComponents.Contains($required)) {
                throw "$PlatformKind ownership layout is missing '$required'."
            }
        }
    }
}

function New-CommMonitorOwnershipPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $AppId,
        [Parameter(Mandatory)][object] $InstallId,
        [Parameter(Mandatory)][object] $Revision,
        [AllowNull()][object] $PreviousPayloadSha256,
        [Parameter(Mandatory)][object] $ProductVersion,
        [Parameter(Mandatory)][object] $CreatedUtc,
        [Parameter(Mandatory)][object] $Platform,
        [Parameter(Mandatory)][object] $Roots,
        [Parameter(Mandatory)][object] $AuthorizedUser,
        [Parameter(Mandatory)][object] $OwnedObjects,
        [Parameter(Mandatory)][object] $UpperFiltersRollback,
        [Parameter(Mandatory)][object] $KeyMetadata,
        [object] $ContinuationState = ([ordered]@{ status = 'None' }),
        [object] $State = 'Committed',
        [object] $OperationState = ([ordered]@{})
    )

    $appIdValue = Copy-CommMonitorSchemaString -Value $AppId -Subject 'AppId'
    $installIdValue = Copy-CommMonitorSchemaString -Value $InstallId -Subject 'InstallId'
    $revisionValue = Copy-CommMonitorSchemaInt32 -Value $Revision -Subject 'Revision'
    $previousPayloadValue = Copy-CommMonitorNullableSchemaString `
        -Value $PreviousPayloadSha256 `
        -Subject 'PreviousPayloadSha256'
    $productVersionValue = Copy-CommMonitorSchemaString `
        -Value $ProductVersion `
        -Subject 'ProductVersion'
    if ($CreatedUtc -isnot [DateTimeOffset]) {
        throw 'CreatedUtc must be a raw DateTimeOffset.'
    }
    $createdUtcValue = [DateTimeOffset]$CreatedUtc
    $stateValue = Copy-CommMonitorSchemaString -Value $State -Subject 'State'
    $parsedAppId = [Guid]::Empty
    $parsedInstallId = [Guid]::Empty
    if (-not [Guid]::TryParseExact($appIdValue, 'D', [ref]$parsedAppId) -or
        -not [Guid]::TryParseExact($installIdValue, 'D', [ref]$parsedInstallId)) {
        throw 'AppId and InstallId must be canonical GUID D values.'
    }
    if ($revisionValue -lt 1) {
        throw 'Manifest revision must be positive.'
    }
    if ($revisionValue -eq 1) {
        if (-not [string]::IsNullOrEmpty($previousPayloadValue)) {
            throw 'Revision 1 must not have previousPayloadSha256.'
        }
    }
    else {
        Assert-CommMonitorHash `
            -Value $previousPayloadValue `
            -Length 64 `
            -Name previousPayloadSha256
    }
    if (-not [regex]::IsMatch(
            $productVersionValue,
            '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$')) {
        throw "Invalid product version '$productVersionValue'."
    }

    $platformDictionary = ConvertTo-CommMonitorSchemaObject `
        -Value $Platform `
        -Subject 'Platform signature'
    Assert-CommMonitorExactFields `
        -Dictionary $platformDictionary `
        -Allowed @('kind', 'build', 'components') `
        -Required @('kind', 'build', 'components') `
        -Subject 'Platform signature'
    $platformDictionary.kind = Copy-CommMonitorSchemaString `
        -Value $platformDictionary.kind `
        -Subject 'Platform kind'
    [void](Get-CommMonitorExpectedPlatformComponents `
            -PlatformKind $platformDictionary.kind)
    if ($platformDictionary.build -isnot [int]) {
        throw 'Platform build must be a raw Int32. Platform build must be a raw integer.'
    }
    if ($platformDictionary.components -isnot [Array]) {
        throw ('Platform components must be a raw System.Array. ' +
            'Platform components must be a raw array of exact strings.')
    }
    foreach ($component in $platformDictionary.components) {
        if ($component -isnot [string]) {
            throw ('Platform components members must be raw strings. ' +
                'Platform components must be a raw array of exact strings.')
        }
    }
    $validatedPlatformComponents = [string[]]@(
        Assert-CommMonitorExactPlatformComponents `
            -PlatformKind $platformDictionary.kind `
            -PlatformComponents $platformDictionary.components)
    $platformDictionary.components = $validatedPlatformComponents
    [void](Assert-CommMonitorSupportedPlatformBuild `
            -PlatformKind $platformDictionary.kind `
            -PlatformBuild $platformDictionary.build)
    Assert-CommMonitorRawSchemaArray `
        -Value $OwnedObjects `
        -Subject 'OwnedObjects'
    $normalizedObjects = [Collections.Generic.List[object]]::new()
    $objectIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($ownedObjectInput in $OwnedObjects) {
        if (-not (Test-CommMonitorRawSchemaObject -Value $ownedObjectInput)) {
            throw 'OwnedObjects members must be raw objects.'
        }
        $ownedObject = New-CommMonitorOwnedObject -Definition $ownedObjectInput
        if (-not $objectIds.Add([string]$ownedObject.objectId)) {
            throw "Duplicate owned objectId '$($ownedObject.objectId)'."
        }
        if ($ownedObject.Contains('relativePath')) {
            $pathIdentity = '{0}|{1}' -f $ownedObject.root, $ownedObject.relativePath
            if (-not $paths.Add($pathIdentity)) {
                throw "Case-insensitive duplicate owned path '$pathIdentity'."
            }
        }
        $normalizedObjects.Add($ownedObject)
    }
    $normalizedObjects.Sort([Comparison[object]] {
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string]$left.objectId,
                [string]$right.objectId)
        })
    $draft = [pscustomobject][ordered]@{
        appId = $parsedAppId.ToString('D').ToLowerInvariant()
        installId = $parsedInstallId.ToString('D').ToLowerInvariant()
        revision = $revisionValue
        previousPayloadSha256 = if ($revisionValue -eq 1) {
            $null
        }
        else {
            $previousPayloadValue
        }
        productVersion = $productVersionValue
        createdUtc = $createdUtcValue.ToUniversalTime().ToString(
            'yyyy-MM-ddTHH:mm:ss.fffffffZ',
            [Globalization.CultureInfo]::InvariantCulture)
        platform = $platformDictionary
        roots = ConvertTo-CommMonitorCanonicalOwnershipRoots `
            -Roots $Roots `
            -InputCasing Resolver
        authorizedUser = ConvertTo-CommMonitorCanonicalAuthorizedUser `
            -AuthorizedUser $AuthorizedUser `
            -InputCasing Resolver
        ownedObjects = $normalizedObjects.ToArray()
        upperFiltersRollback = $UpperFiltersRollback
        keyMetadata = $KeyMetadata
        continuationState = $ContinuationState
        state = $stateValue
        operationState = $OperationState
    }
    return ConvertTo-CommMonitorCanonicalOwnershipPayload -Payload $draft
}

function ConvertTo-CommMonitorCanonicalWindowsPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Role
    )

    if ($Path.Contains('/') -or
        -not [regex]::IsMatch(
            $Path,
            '^[A-Za-z]:\\',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
        $Path.StartsWith('\\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('\\.\', [StringComparison]::Ordinal) -or
        $Path.Substring(2).Contains(':')) {
        throw "$Role must be an absolute ordinary local drive path: '$Path'."
    }

    foreach ($rawSegment in @($Path.Substring(3) -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($rawSegment) -or
            $rawSegment -in @('.', '..') -or
            $rawSegment.EndsWith('.', [StringComparison]::Ordinal) -or
            $rawSegment.EndsWith(' ', [StringComparison]::Ordinal) -or
            [regex]::IsMatch(
                $rawSegment,
                '[<>"|?*]',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            [regex]::IsMatch(
                $rawSegment,
                '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            throw "$Role contains an unsafe path segment: '$rawSegment'."
        }
    }

    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $volumeRoot = [IO.Path]::GetPathRoot($canonicalPath).TrimEnd('\', '/')
    if ([string]::Equals(
            $canonicalPath,
            $volumeRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Role must not be a volume root: '$canonicalPath'."
    }

    $segments = @($canonicalPath.Substring(3) -split '\\')
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or
            $segment -in @('.', '..') -or
            $segment.EndsWith('.', [StringComparison]::Ordinal) -or
            $segment.EndsWith(' ', [StringComparison]::Ordinal) -or
            [regex]::IsMatch(
                $segment,
                '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            throw "$Role contains an unsafe path segment: '$segment'."
        }
    }

    return $canonicalPath
}

function Test-CommMonitorPathOverlap {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $First,
        [Parameter(Mandatory)][string] $Second
    )

    if ([string]::Equals($First, $Second, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $firstPrefix = $First.TrimEnd('\') + '\'
    $secondPrefix = $Second.TrimEnd('\') + '\'
    return $First.StartsWith(
            $secondPrefix,
            [StringComparison]::OrdinalIgnoreCase) -or
        $Second.StartsWith(
            $firstPrefix,
            [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-CommMonitorHandleCanonicalPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Path,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Role
    )

    if ($Path.Contains('/') -or
        -not [regex]::IsMatch(
            $Path,
            '^[A-Za-z]:\\',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
        $Path.StartsWith('\\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('\\.\', [StringComparison]::Ordinal) -or
        $Path.Substring(2).Contains(':')) {
        throw "$Role is not an ordinary handle-canonical local path: '$Path'."
    }
    $canonical = [IO.Path]::GetFullPath($Path)
    $volumeRoot = [IO.Path]::GetPathRoot($canonical)
    if ([string]::Equals(
            $canonical.TrimEnd('\'),
            $volumeRoot.TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase)) {
        return $volumeRoot
    }
    return ConvertTo-CommMonitorCanonicalWindowsPath -Path $canonical -Role $Role
}

function Get-CommMonitorRequestedAncestorPaths {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string] $Path)

    $canonical = ConvertTo-CommMonitorHandleCanonicalPath `
        -Path $Path `
        -Role RequestedAncestorPath
    $volumeRoot = [IO.Path]::GetPathRoot($canonical)
    $result = [Collections.Generic.List[string]]::new()
    $result.Add($volumeRoot)
    $relative = $canonical.Substring($volumeRoot.Length)
    $cursor = $volumeRoot.TrimEnd('\')
    foreach ($segment in @($relative -split '\\')) {
        if ([string]::IsNullOrEmpty($segment)) { continue }
        $cursor = $cursor + '\' + $segment
        $result.Add($cursor)
    }
    return $result.ToArray()
}

function ConvertTo-CommMonitorProtectedAclProfile {
    [CmdletBinding()]
    [OutputType([Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object] $Profile,
        [Parameter(Mandatory)][string] $Role
    )

    $acl = ConvertTo-CommMonitorOrderedDictionary -InputObject $Profile
    $fields = @(
        'OwnerSid', 'AreAccessRulesProtected', 'AllowedFullControlSids',
        'DenyRuleCount', 'UsersWritable')
    Assert-CommMonitorExactFields `
        -Dictionary $acl `
        -Allowed $fields `
        -Required $fields `
        -Subject "$Role ACL profile"
    if ($acl.OwnerSid -isnot [string] -or
        $acl.AllowedFullControlSids -isnot [Array]) {
        throw "$Role ACL profile uses coerced evidence types."
    }
    foreach ($allowedSid in $acl.AllowedFullControlSids) {
        if ($allowedSid -isnot [string]) {
            throw "$Role ACL profile uses coerced evidence types."
        }
    }
    if ($acl.AreAccessRulesProtected -isnot [bool] -or
        -not [bool]$acl.AreAccessRulesProtected -or
        $acl.UsersWritable -isnot [bool] -or
        [bool]$acl.UsersWritable -or
        $acl.DenyRuleCount -isnot [int] -or
        [int]$acl.DenyRuleCount -ne 0 -or
        [string]$acl.OwnerSid -notin @('S-1-5-18', 'S-1-5-32-544')) {
        throw "$Role ACL profile is not protected against ordinary-user writes."
    }
    $allowedSids = [string[]]$acl.AllowedFullControlSids
    if ($allowedSids.Count -ne 2 -or
        -not [string]::Equals(
            $allowedSids[0],
            'S-1-5-18',
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            $allowedSids[1],
            'S-1-5-32-544',
            [StringComparison]::Ordinal)) {
        throw "$Role ACL profile grants an unexpected full-control principal."
    }
    return [ordered]@{
        OwnerSid = [string]$acl.OwnerSid
        AreAccessRulesProtected = [bool]$acl.AreAccessRulesProtected
        AllowedFullControlSids = $allowedSids
        DenyRuleCount = [int]$acl.DenyRuleCount
        UsersWritable = [bool]$acl.UsersWritable
    }
}

function ConvertTo-CommMonitorValidatedRootProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Probe,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Role,
        [bool] $RequireEmpty,
        [bool] $RequireProtectedAcl
    )

    $probeData = ConvertTo-CommMonitorOrderedDictionary -InputObject $Probe
    $fields = @(
        'Provider', 'VolumeKind', 'VolumeSerialNumber', 'RequestedPath',
        'FinalPath', 'Exists', 'IsDirectory', 'IsEmpty', 'IsReparse',
        'FileId', 'ExistingParentFileId', 'AclProfile', 'InstallIdMarker',
        'NearestExistingAncestor', 'UnresolvedSuffix', 'Ancestors')
    Assert-CommMonitorExactFields `
        -Dictionary $probeData `
        -Allowed $fields `
        -Required $fields `
        -Subject "$Role path probe"

    if ($probeData.Provider -isnot [string] -or
        $probeData.VolumeKind -isnot [string] -or
        $probeData.VolumeSerialNumber -isnot [string] -or
        $probeData.RequestedPath -isnot [string] -or
        ($null -ne $probeData.FinalPath -and $probeData.FinalPath -isnot [string]) -or
        ($null -ne $probeData.FileId -and $probeData.FileId -isnot [string]) -or
        ($null -ne $probeData.ExistingParentFileId -and
            $probeData.ExistingParentFileId -isnot [string]) -or
        ($null -ne $probeData.InstallIdMarker -and
            $probeData.InstallIdMarker -isnot [string]) -or
        $probeData.UnresolvedSuffix -isnot [string]) {
        throw "$Role path probe uses coerced evidence types."
    }
    if (-not [string]::Equals(
            [string]$probeData.Provider,
            'FileSystem',
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$probeData.VolumeKind,
            'Fixed',
            [StringComparison]::Ordinal) -or
        $probeData.Exists -isnot [bool] -or
        $probeData.IsDirectory -isnot [bool] -or
        $probeData.IsEmpty -isnot [bool] -or
        $probeData.IsReparse -isnot [bool] -or
        [bool]$probeData.IsReparse -or
        ([bool]$probeData.Exists -and -not [bool]$probeData.IsDirectory) -or
        ($RequireEmpty -and [bool]$probeData.Exists -and -not [bool]$probeData.IsEmpty)) {
        throw "$Role path probe rejected unsafe target '$Path'."
    }
    if (-not [regex]::IsMatch(
            [string]$probeData.VolumeSerialNumber,
            '^[0-9a-f]{16}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw "$Role path probe returned incomplete identity evidence for '$Path'."
    }

    $requestedPath = ConvertTo-CommMonitorHandleCanonicalPath `
        -Path ([string]$probeData.RequestedPath) `
        -Role "$Role requested path"
    if (-not [string]::Equals(
            $requestedPath,
            $Path,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Role path probe was not bound to the requested path '$Path'."
    }

    $nearest = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject $probeData.NearestExistingAncestor
    $nearestFields = @('RequestedPath', 'FinalPath', 'VolumeSerial', 'FileId')
    Assert-CommMonitorExactFields `
        -Dictionary $nearest `
        -Allowed $nearestFields `
        -Required $nearestFields `
        -Subject "$Role nearest-existing-ancestor evidence"
    if ($nearest.RequestedPath -isnot [string] -or
        $nearest.FinalPath -isnot [string] -or
        $nearest.VolumeSerial -isnot [string] -or
        $nearest.FileId -isnot [string]) {
        throw "$Role nearest-existing-ancestor uses coerced evidence types."
    }
    $nearestRequested = ConvertTo-CommMonitorHandleCanonicalPath `
        -Path ([string]$nearest.RequestedPath) `
        -Role "$Role nearest requested path"
    $nearestFinal = ConvertTo-CommMonitorHandleCanonicalPath `
        -Path ([string]$nearest.FinalPath) `
        -Role "$Role nearest final path"
    if (-not [string]::Equals(
            [string]$nearest.VolumeSerial,
            [string]$probeData.VolumeSerialNumber,
            [StringComparison]::Ordinal) -or
        -not [regex]::IsMatch(
            [string]$nearest.FileId,
            '^[0-9a-f]{32}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw "$Role path probe returned incomplete identity evidence for the nearest existing ancestor."
    }

    $unresolvedSuffix = [string]$probeData.UnresolvedSuffix
    if ([bool]$probeData.Exists) {
        if ($null -ne $probeData.ExistingParentFileId) {
            throw "$Role existing target must not carry ExistingParentFileId."
        }
        if (-not [string]::IsNullOrEmpty($unresolvedSuffix) -or
            [string]::IsNullOrWhiteSpace([string]$probeData.FinalPath) -or
            -not [regex]::IsMatch(
                [string]$probeData.FileId,
                '^[0-9a-f]{32}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            throw "$Role existing-target identity evidence is incomplete."
        }
        $finalPath = ConvertTo-CommMonitorHandleCanonicalPath `
            -Path ([string]$probeData.FinalPath) `
            -Role "$Role final path"
        if (-not [string]::Equals(
                $finalPath,
                $nearestFinal,
                [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals(
                $requestedPath,
                $nearestRequested,
                [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals(
                [string]$probeData.FileId,
                [string]$nearest.FileId,
                [StringComparison]::Ordinal)) {
            throw "$Role target and nearest-existing-ancestor identities disagree."
        }
        $physicalCandidatePath = $finalPath
    }
    else {
        if ($null -ne $probeData.FileId) {
            throw "$Role nonexistent target must not carry FileId."
        }
        if ($null -ne $probeData.FinalPath -and
            -not [string]::IsNullOrEmpty([string]$probeData.FinalPath)) {
            throw "$Role nonexistent target must not claim a final path."
        }
        Assert-CommMonitorRelativeOrdinaryPath -Path $unresolvedSuffix
        $reconstructed = ConvertTo-CommMonitorHandleCanonicalPath `
            -Path (Join-Path $nearestRequested $unresolvedSuffix) `
            -Role "$Role reconstructed requested path"
        if (-not [string]::Equals(
                $reconstructed,
                $Path,
                [StringComparison]::OrdinalIgnoreCase) -or
            -not [regex]::IsMatch(
                [string]$probeData.ExistingParentFileId,
                '^[0-9a-f]{32}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [string]::Equals(
                [string]$probeData.ExistingParentFileId,
                [string]$nearest.FileId,
                [StringComparison]::Ordinal)) {
            throw "$Role nonexistent-target parent identity evidence is incomplete."
        }
        $physicalCandidatePath = ConvertTo-CommMonitorHandleCanonicalPath `
            -Path (Join-Path $nearestFinal $unresolvedSuffix) `
            -Role "$Role physical candidate path"
        $finalPath = $null
    }

    $expectedAncestors = @(
        Get-CommMonitorRequestedAncestorPaths -Path $nearestRequested)
    if ($probeData.Ancestors -isnot [Array]) {
        throw "$Role ancestor-chain evidence container must be an array."
    }
    $ancestorInputs = [object[]]$probeData.Ancestors
    if ($ancestorInputs.Count -ne $expectedAncestors.Count -or
        $ancestorInputs.Count -eq 0) {
        throw "$Role path probe returned incomplete ancestor-chain evidence."
    }
    $ancestors = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $ancestorInputs.Count; $index++) {
        $ancestor = ConvertTo-CommMonitorOrderedDictionary `
            -InputObject $ancestorInputs[$index]
        $ancestorFields = @(
            'RequestedPath', 'FinalPath', 'VolumeSerial', 'FileId', 'ReparseTag')
        Assert-CommMonitorExactFields `
            -Dictionary $ancestor `
            -Allowed $ancestorFields `
            -Required $ancestorFields `
            -Subject "$Role ancestor-chain evidence"
        if ($ancestor.RequestedPath -isnot [string] -or
            $ancestor.FinalPath -isnot [string] -or
            $ancestor.VolumeSerial -isnot [string] -or
            $ancestor.FileId -isnot [string] -or
            ($ancestor.ReparseTag -isnot [int] -and
                $ancestor.ReparseTag -isnot [uint32] -and
                $ancestor.ReparseTag -isnot [long] -and
                $ancestor.ReparseTag -isnot [uint64])) {
            throw "$Role ancestor-chain uses coerced evidence types."
        }
        $ancestorRequested = ConvertTo-CommMonitorHandleCanonicalPath `
            -Path ([string]$ancestor.RequestedPath) `
            -Role "$Role ancestor requested path"
        $ancestorFinal = ConvertTo-CommMonitorHandleCanonicalPath `
            -Path ([string]$ancestor.FinalPath) `
            -Role "$Role ancestor final path"
        if (-not [string]::Equals(
                $ancestorRequested,
                $expectedAncestors[$index],
                [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals(
                [string]$ancestor.VolumeSerial,
                [string]$probeData.VolumeSerialNumber,
                [StringComparison]::Ordinal) -or
            -not [regex]::IsMatch(
                [string]$ancestor.FileId,
                '^[0-9a-f]{32}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            [long]$ancestor.ReparseTag -ne 0) {
            throw "$Role ancestor-chain evidence is incomplete or contains a reparse point."
        }
        if ($index -gt 0 -and
            -not $ancestorFinal.StartsWith(
                ([string]$ancestors[$index - 1].FinalPath).TrimEnd('\') + '\',
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Role ancestor-chain final paths are not physically nested."
        }
        $ancestors.Add([pscustomobject][ordered]@{
                RequestedPath = $ancestorRequested
                FinalPath = $ancestorFinal
                VolumeSerial = [string]$ancestor.VolumeSerial
                FileId = [string]$ancestor.FileId
                ReparseTag = [long]$ancestor.ReparseTag
            })
    }
    $lastAncestor = $ancestors[$ancestors.Count - 1]
    if (-not [string]::Equals(
            [string]$lastAncestor.FinalPath,
            $nearestFinal,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            [string]$lastAncestor.FileId,
            [string]$nearest.FileId,
            [StringComparison]::Ordinal)) {
        throw "$Role nearest-existing-ancestor and chain terminus disagree."
    }

    $aclProfile = if ($RequireProtectedAcl -and [bool]$probeData.Exists) {
        ConvertTo-CommMonitorProtectedAclProfile `
            -Profile $probeData.AclProfile `
            -Role $Role
    }
    else {
        ConvertTo-CommMonitorOrderedDictionary -InputObject $probeData.AclProfile
    }
    return [pscustomobject][ordered]@{
        Provider = 'FileSystem'
        VolumeKind = 'Fixed'
        VolumeSerialNumber = [string]$probeData.VolumeSerialNumber
        RequestedPath = $requestedPath
        FinalPath = $finalPath
        Exists = [bool]$probeData.Exists
        IsDirectory = [bool]$probeData.IsDirectory
        IsEmpty = [bool]$probeData.IsEmpty
        IsReparse = [bool]$probeData.IsReparse
        FileId = if ([bool]$probeData.Exists) { [string]$probeData.FileId } else { $null }
        ExistingParentFileId = if ([bool]$probeData.Exists) {
            $null
        }
        else {
            [string]$probeData.ExistingParentFileId
        }
        AclProfile = $aclProfile
        InstallIdMarker = $probeData.InstallIdMarker
        NearestExistingAncestor = [pscustomobject][ordered]@{
            RequestedPath = $nearestRequested
            FinalPath = $nearestFinal
            VolumeSerial = [string]$nearest.VolumeSerial
            FileId = [string]$nearest.FileId
        }
        UnresolvedSuffix = $unresolvedSuffix
        Ancestors = $ancestors.ToArray()
        PhysicalCandidatePath = $physicalCandidatePath
    }
}

function Get-CommMonitorValidatedRootProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Role,
        [bool] $RequireEmpty = $true,
        [bool] $RequireProtectedAcl = $false
    )

    $firstRaw = Invoke-CommMonitorWindowsPathProbe -Path $Path -Pass 1
    if ($null -eq $firstRaw) {
        throw "$Role path probe returned no identity evidence for '$Path'."
    }
    $first = ConvertTo-CommMonitorValidatedRootProbe `
        -Probe $firstRaw `
        -Path $Path `
        -Role $Role `
        -RequireEmpty $RequireEmpty `
        -RequireProtectedAcl $RequireProtectedAcl
    $firstSnapshot = ConvertTo-CommMonitorCanonicalJson -InputObject $first

    $secondRaw = Invoke-CommMonitorWindowsPathProbe -Path $Path -Pass 2
    if ($null -eq $secondRaw) {
        throw "$Role path probe returned no identity evidence for '$Path'."
    }
    $second = ConvertTo-CommMonitorValidatedRootProbe `
        -Probe $secondRaw `
        -Path $Path `
        -Role $Role `
        -RequireEmpty $RequireEmpty `
        -RequireProtectedAcl $RequireProtectedAcl
    $secondSnapshot = ConvertTo-CommMonitorCanonicalJson -InputObject $second
    if (-not [string]::Equals(
            $firstSnapshot,
            $secondSnapshot,
            [StringComparison]::Ordinal)) {
        throw "$Role identity changed between probes for '$Path'."
    }
    return $second
}

function Assert-CommMonitorDistinctPhysicalRoots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $ValidatedRoots
    )

    $roles = [string[]]@($ValidatedRoots.Keys)
    for ($firstIndex = 0; $firstIndex -lt $roles.Count; $firstIndex++) {
        for ($secondIndex = $firstIndex + 1; $secondIndex -lt $roles.Count; $secondIndex++) {
            $firstRole = $roles[$firstIndex]
            $secondRole = $roles[$secondIndex]
            $first = $ValidatedRoots[$firstRole]
            $second = $ValidatedRoots[$secondRole]
            if (Test-CommMonitorPathOverlap `
                    -First ([string]$first.PhysicalCandidatePath) `
                    -Second ([string]$second.PhysicalCandidatePath)) {
                throw "Physical root alias: $firstRole and $secondRole candidates overlap."
            }
            if ([bool]$first.Exists -and [bool]$second.Exists -and
                [string]::Equals(
                    [string]$first.VolumeSerialNumber,
                    [string]$second.VolumeSerialNumber,
                    [StringComparison]::Ordinal) -and
                [string]::Equals(
                    [string]$first.FileId,
                    [string]$second.FileId,
                    [StringComparison]::Ordinal)) {
                throw "Physical root alias: $firstRole and $secondRole share one file identity."
            }
            foreach ($firstAncestor in @($first.Ancestors)) {
                foreach ($secondAncestor in @($second.Ancestors)) {
                    if ([string]::Equals(
                            [string]$firstAncestor.RequestedPath,
                            [string]$secondAncestor.RequestedPath,
                            [StringComparison]::OrdinalIgnoreCase)) {
                        if (-not [string]::Equals(
                                [string]$firstAncestor.FinalPath,
                                [string]$secondAncestor.FinalPath,
                                [StringComparison]::OrdinalIgnoreCase) -or
                            -not [string]::Equals(
                                [string]$firstAncestor.VolumeSerial,
                                [string]$secondAncestor.VolumeSerial,
                                [StringComparison]::Ordinal) -or
                            -not [string]::Equals(
                                [string]$firstAncestor.FileId,
                                [string]$secondAncestor.FileId,
                                [StringComparison]::Ordinal)) {
                            throw "Physical root alias: shared ancestor evidence is inconsistent."
                        }
                        continue
                    }
                    if ([string]::Equals(
                            [string]$firstAncestor.VolumeSerial,
                            [string]$secondAncestor.VolumeSerial,
                            [StringComparison]::Ordinal) -and
                        [string]::Equals(
                            [string]$firstAncestor.FileId,
                            [string]$secondAncestor.FileId,
                            [StringComparison]::Ordinal) -and
                        -not [string]::Equals(
                            [string]$firstAncestor.RequestedPath,
                            [string]$secondAncestor.RequestedPath,
                            [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Physical root alias: $firstRole and $secondRole use different names for one ancestor."
                    }
                }
            }
        }
    }
}

function Assert-CommMonitorLegacyDataRootMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedDataRootPath,
        [Parameter(Mandatory)][object] $AuthorizedUserBinding
    )

    $bindingRecord = Get-CommMonitorAuthorizedUserBindingRecord `
        -Binding $AuthorizedUserBinding
    if ($null -eq $bindingRecord) {
        throw 'A registered authorized-user binding is required for legacy-marker validation.'
    }
    $expectedPath = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path $ExpectedDataRootPath `
        -Role ExpectedLegacyDataRootPath
    $probe = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject (Invoke-CommMonitorWindowsLegacyMarkerProbe `
            -ExpectedDataRootPath $expectedPath)
    $probeFields = @(
        'Source', 'IdentityVerified', 'Marker', 'ProtectedExpectedDigest')
    Assert-CommMonitorExactFields `
        -Dictionary $probe `
        -Allowed $probeFields `
        -Required $probeFields `
        -Subject 'Protected legacy-marker probe'
    if (-not [string]::Equals(
            [string]$probe.Source,
            'ProtectedLegacyMarkerProbe',
            [StringComparison]::Ordinal) -or
        $probe.IdentityVerified -isnot [bool] -or
        -not [bool]$probe.IdentityVerified) {
        throw 'The protected legacy-marker probe did not verify its source identity.'
    }

    $marker = ConvertTo-CommMonitorOrderedDictionary -InputObject $probe.Marker
    $markerFields = @(
        'schemaVersion', 'markerId', 'canonicalPath',
        'volumeSerialNumber', 'fileId', 'aclProfile', 'ownershipProof')
    Assert-CommMonitorExactFields `
        -Dictionary $marker `
        -Allowed $markerFields `
        -Required $markerFields `
        -Subject 'Legacy DataRoot marker'
    $parsedMarkerId = [Guid]::Empty
    if ($marker.schemaVersion -isnot [int] -or
        [int]$marker.schemaVersion -ne 1 -or
        -not [Guid]::TryParseExact(
            [string]$marker.markerId,
            'D',
            [ref]$parsedMarkerId) -or
        -not [string]::Equals(
            [string]$marker.markerId,
            $parsedMarkerId.ToString('D').ToLowerInvariant(),
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$marker.ownershipProof,
            'VerifiedLegacyAdoption',
            [StringComparison]::Ordinal) -or
        -not [regex]::IsMatch(
            [string]$marker.volumeSerialNumber,
            '^[0-9a-f]{16}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
        -not [regex]::IsMatch(
            [string]$marker.fileId,
            '^[0-9a-f]{32}$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw 'Legacy DataRoot marker metadata is invalid.'
    }
    $canonicalPath = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path ([string]$marker.canonicalPath) `
        -Role LegacyDataRootPath
    if (-not [string]::Equals(
            $canonicalPath,
            $expectedPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Legacy DataRoot marker is bound to a different canonical path.'
    }
    Assert-CommMonitorHash `
        -Value $probe.ProtectedExpectedDigest `
        -Length 64 `
        -Name ProtectedExpectedDigest
    $actualDigest = Get-CommMonitorSha256Hex -Bytes (
        [Text.UTF8Encoding]::new($false).GetBytes(
            (ConvertTo-CommMonitorCanonicalJson -InputObject $marker)))
    if (-not (Test-CommMonitorFixedTimeEquals `
            -LeftHex $actualDigest `
            -RightHex ([string]$probe.ProtectedExpectedDigest))) {
        throw 'Legacy DataRoot marker digest does not match the protected expectation.'
    }
    $validated = [pscustomobject][ordered]@{
        schemaVersion = 1
        source = 'ProtectedLegacyMarkerProbe'
        capabilityId = [string]$bindingRecord.CapabilityId
        providerEpoch = [string]$bindingRecord.Epoch
        markerId = $parsedMarkerId.ToString('D').ToLowerInvariant()
        markerDigest = $actualDigest
        canonicalPath = $canonicalPath
        volumeSerialNumber = [string]$marker.volumeSerialNumber
        fileId = [string]$marker.fileId
        aclProfile = ConvertTo-CommMonitorProtectedAclProfile `
            -Profile $marker.aclProfile `
            -Role DataRootAdoption
        ownershipProof = 'VerifiedLegacyAdoption'
    }
    return Register-CommMonitorEvidence `
        -Registry $script:CommMonitorValidatedLegacyDataRootMarkers `
        -Evidence $validated
}

function New-CommMonitorDataRootAdoptionEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('AuthenticatedManifestV3', 'ValidatedLegacyMarker')]
        [string] $SourceKind,

        [AllowNull()][object] $AuthenticatedPayload,
        [AllowNull()][object] $ValidatedLegacyMarker
    )

    if (-not (Test-CommMonitorOrdinalValue `
            -Value $SourceKind `
            -Allowed @('AuthenticatedManifestV3', 'ValidatedLegacyMarker'))) {
        throw 'DataRoot adoption source kind must be an exact supported value.'
    }
    if (Test-CommMonitorOrdinalValue `
            -Value $SourceKind `
            -Allowed @('ValidatedLegacyMarker')) {
        $markerRecord = Get-CommMonitorRegisteredEvidenceRecord `
            -Registry $script:CommMonitorValidatedLegacyDataRootMarkers `
            -Evidence $ValidatedLegacyMarker
        if ($null -eq $ValidatedLegacyMarker -or $null -ne $AuthenticatedPayload -or
            $null -eq $markerRecord) {
            throw 'ValidatedLegacyMarker adoption requires a registered protected-probe result.'
        }
        $marker = $markerRecord.Value
        $evidence = [pscustomobject][ordered]@{
            schemaVersion = 1
            sourceKind = 'ValidatedLegacyMarker'
            capabilityId = [string]$marker.capabilityId
            providerEpoch = [string]$marker.providerEpoch
            markerId = [string]$marker.markerId
            markerDigest = [string]$marker.markerDigest
            canonicalPath = [string]$marker.canonicalPath
            volumeSerialNumber = [string]$marker.volumeSerialNumber
            fileId = [string]$marker.fileId
            aclProfile = ConvertTo-CommMonitorCanonicalAclProfile `
                -Profile $marker.aclProfile `
                -Subject 'Legacy adoption ACL profile' `
                -InputCasing Resolver
            ownershipProof = 'VerifiedLegacyAdoption'
        }
    }
    else {
        if ($null -eq $AuthenticatedPayload -or
            $null -ne $ValidatedLegacyMarker) {
            throw 'AuthenticatedManifestV3 adoption requires only an authenticated payload source.'
        }
        $authenticatedRecord = Get-CommMonitorAuthenticatedOwnershipPayloadRecord `
            -Payload $AuthenticatedPayload
        if ($null -eq $authenticatedRecord) {
            throw 'The manifest payload was not authenticated in this session.'
        }
        $payload = ConvertTo-CommMonitorCanonicalOwnershipPayload `
            -Payload $authenticatedRecord.Value
        $installId = Copy-CommMonitorSchemaString `
            -Value $payload.installId `
            -Subject 'Authenticated manifest installId'
        $roots = $payload.roots
        $dataRoot = $roots['dataRoot']
        $parsedInstallId = [Guid]::Empty
        if (-not [Guid]::TryParseExact(
                $installId,
                'D',
                [ref]$parsedInstallId) -or
            -not (Test-CommMonitorOrdinalValue `
                -Value $dataRoot.ownershipProof `
                -Allowed @('CreatedThisInstall', 'VerifiedLegacyAdoption')) -or
            -not [regex]::IsMatch(
                [string]$dataRoot.volumeSerialNumber,
                '^[0-9a-f]{16}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
            -not [regex]::IsMatch(
                [string]$dataRoot.fileId,
                '^[0-9a-f]{32}$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            throw 'Authenticated manifest DataRoot identity is invalid.'
        }
        $canonicalAclProfile = ConvertTo-CommMonitorCanonicalAclProfile `
            -Profile $dataRoot.aclProfile `
            -Subject 'Authenticated manifest DataRoot ACL profile' `
            -InputCasing Canonical
        [void](ConvertTo-CommMonitorProtectedAclProfile `
                -Profile ([ordered]@{
                    OwnerSid = $canonicalAclProfile.ownerSid
                    AreAccessRulesProtected =
                        $canonicalAclProfile.areAccessRulesProtected
                    AllowedFullControlSids =
                        $canonicalAclProfile.allowedFullControlSids
                    DenyRuleCount = $canonicalAclProfile.denyRuleCount
                    UsersWritable = $canonicalAclProfile.usersWritable
                }) `
                -Role DataRootAdoption)
        $evidence = [pscustomobject][ordered]@{
            schemaVersion = 1
            sourceKind = 'AuthenticatedManifestV3'
            sourceInstallId = $parsedInstallId.ToString('D').ToLowerInvariant()
            sourcePayloadSha256 = [string]$authenticatedRecord.PayloadSha256
            canonicalPath = ConvertTo-CommMonitorCanonicalWindowsPath `
                -Path ([string]$dataRoot.canonicalPath) `
                -Role ManifestDataRootPath
            volumeSerialNumber = [string]$dataRoot.volumeSerialNumber
            fileId = [string]$dataRoot.fileId
            aclProfile = $canonicalAclProfile
            ownershipProof = 'VerifiedLegacyAdoption'
        }
    }

    return Register-CommMonitorEvidence `
        -Registry $script:CommMonitorDataRootAdoptionEvidence `
        -Evidence $evidence
}

function Resolve-CommMonitorAuthorizedUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $AuthorizedUserSid,

        [Parameter(Mandatory)]
        [object] $OwnershipProbeCapability,

        [Parameter(Mandatory)]
        [object] $AiRelativePath
    )

    if ($AuthorizedUserSid -isnot [string] -or
        $AiRelativePath -isnot [string]) {
        throw 'Authorized user SID and AI relative path must be raw strings.'
    }
    $capabilityRecord = Get-CommMonitorOwnershipProbeCapabilityRecord `
        -Capability $OwnershipProbeCapability
    if ($null -eq $capabilityRecord) {
        throw 'A registered ownership-probe capability is required.'
    }
    $AuthorizedUserSid = ConvertTo-CommMonitorCanonicalProfileUserSid `
        -Sid $AuthorizedUserSid
    if (-not [string]::Equals(
            $AiRelativePath,
            'LemonSerialMonitor\AI',
            [StringComparison]::Ordinal)) {
        throw "The AI state relative path must be exactly 'LemonSerialMonitor\AI'."
    }

    $profileListRecords = @(
        Invoke-CommMonitorWindowsProfileListProbe `
            -AuthorizedUserSid $AuthorizedUserSid)
    $matchingRecords = [Collections.Generic.List[object]]::new()
    foreach ($record in @($ProfileListRecords)) {
        $recordData = ConvertTo-CommMonitorOrderedDictionary -InputObject $record
        Assert-CommMonitorExactFields `
            -Dictionary $recordData `
            -Allowed @(
                'Sid', 'ProfileListKeyPath', 'ProfileImagePath',
                'ProfileImagePathValueKind') `
            -Required @(
                'Sid', 'ProfileListKeyPath', 'ProfileImagePath',
                'ProfileImagePathValueKind') `
            -Subject 'ProfileList record'
        if ($recordData.Sid -isnot [string] -or
            $recordData.ProfileListKeyPath -isnot [string] -or
            $recordData.ProfileImagePath -isnot [string] -or
            $recordData.ProfileImagePathValueKind -isnot [string]) {
            throw 'ProfileList record values must be raw strings.'
        }
        if ([string]::Equals(
                [string]$recordData.Sid,
                $AuthorizedUserSid,
                [StringComparison]::Ordinal)) {
            $matchingRecords.Add($recordData)
        }
    }
    if ($matchingRecords.Count -ne 1) {
        throw "ProfileList must contain exactly one record for '$AuthorizedUserSid'."
    }

    $expectedProfileListKeyPath =
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' +
        $AuthorizedUserSid
    if (-not [string]::Equals(
            [string]$matchingRecords[0].ProfileListKeyPath,
            $expectedProfileListKeyPath,
            [StringComparison]::Ordinal)) {
        throw 'The ProfileList record is not bound to the exact authorized SID registry key.'
    }
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $matchingRecords[0].ProfileImagePathValueKind `
            -Allowed @('String', 'ExpandString'))) {
        throw 'ProfileImagePath has an unsupported Registry64 value kind.'
    }

    $rawProfilePath = [string]$matchingRecords[0].ProfileImagePath
    $profileExpansion = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject (Invoke-CommMonitorWindowsProfilePathExpansionProbe `
            -AuthorizedUserSid $AuthorizedUserSid `
            -RawProfileImagePath $rawProfilePath)
    $profileExpansionFields = @(
        'Source', 'Sid', 'RawValue', 'Path', 'IdentityVerified')
    Assert-CommMonitorExactFields `
        -Dictionary $profileExpansion `
        -Allowed $profileExpansionFields `
        -Required $profileExpansionFields `
        -Subject 'Profile path expansion evidence'
    if ($profileExpansion.Source -isnot [string] -or
        $profileExpansion.Sid -isnot [string] -or
        $profileExpansion.RawValue -isnot [string] -or
        $profileExpansion.Path -isnot [string] -or
        $profileExpansion.IdentityVerified -isnot [bool] -or
        -not [bool]$profileExpansion.IdentityVerified -or
        -not [string]::Equals(
            [string]$profileExpansion.Source,
            'ExpandEnvironmentStringsForUserW',
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$profileExpansion.Sid,
            $AuthorizedUserSid,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$profileExpansion.RawValue,
            $rawProfilePath,
            [StringComparison]::Ordinal)) {
        throw 'Profile path expansion evidence is not bound to the authorized user token.'
    }
    $profilePath = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path ([string]$profileExpansion.Path) `
        -Role ProfileImagePath
    $sessionEvidence = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject (Invoke-CommMonitorWindowsInteractiveSessionProbe)
    Assert-CommMonitorExactFields `
        -Dictionary $sessionEvidence `
        -Allowed @('Source', 'OriginalInteractiveSid', 'IdentityVerified') `
        -Required @('Source', 'OriginalInteractiveSid', 'IdentityVerified') `
        -Subject 'Interactive session evidence'
    if ($sessionEvidence.Source -isnot [string] -or
        $sessionEvidence.OriginalInteractiveSid -isnot [string] -or
        -not [string]::Equals(
            [string]$sessionEvidence.Source,
            'WindowsTokenSessionProbe',
            [StringComparison]::Ordinal) -or
        $sessionEvidence.IdentityVerified -isnot [bool] -or
        -not [bool]$sessionEvidence.IdentityVerified -or
        -not [string]::Equals(
            [string]$sessionEvidence.OriginalInteractiveSid,
            $AuthorizedUserSid,
            [StringComparison]::Ordinal)) {
        throw 'The authorized SID is not the independently verified original interactive SID.'
    }

    $knownFolderEvidence = ConvertTo-CommMonitorOrderedDictionary `
        -InputObject (Invoke-CommMonitorWindowsKnownFolderProbe `
            -AuthorizedUserSid $AuthorizedUserSid `
            -KnownFolder 'LocalAppData')
    if ($null -eq $knownFolderEvidence) {
        throw 'The trusted Known Folder probe returned no LocalAppData evidence.'
    }
    Assert-CommMonitorExactFields `
        -Dictionary $knownFolderEvidence `
        -Allowed @(
            'Sid', 'KnownFolder', 'KnownFolderId', 'Path',
            'IdentityVerified') `
        -Required @(
            'Sid', 'KnownFolder', 'KnownFolderId', 'Path',
            'IdentityVerified') `
        -Subject 'Known Folder evidence'
    if ($knownFolderEvidence.Sid -isnot [string] -or
        $knownFolderEvidence.KnownFolder -isnot [string] -or
        $knownFolderEvidence.KnownFolderId -isnot [string] -or
        $knownFolderEvidence.Path -isnot [string] -or
        -not [string]::Equals(
            [string]$knownFolderEvidence.Sid,
            $AuthorizedUserSid,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$knownFolderEvidence.KnownFolder,
            'LocalAppData',
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$knownFolderEvidence.KnownFolderId,
            '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}',
            [StringComparison]::Ordinal) -or
        $knownFolderEvidence.IdentityVerified -isnot [bool] -or
        -not [bool]$knownFolderEvidence.IdentityVerified) {
        throw 'The trusted Known Folder evidence is not bound to the authorized SID.'
    }

    $localAppDataPath = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path ([string]$knownFolderEvidence.Path) `
        -Role LocalAppDataPath

    $aiRoot = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path (Join-Path $localAppDataPath $AiRelativePath) `
        -Role AiRoot
    $binding = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Source = 'ProfileList+WindowsTokenSession+KnownFolder'
        IdentityVerified = $true
        CapabilityId = [string]$capabilityRecord.CapabilityId
        ProviderEpoch = [string]$capabilityRecord.Epoch
        OriginalInteractiveSid = $AuthorizedUserSid
        Sid = $AuthorizedUserSid
        ProfileListKeyPath = $expectedProfileListKeyPath
        ProfileImagePathRaw = $rawProfilePath
        ProfileImagePathValueKind =
            [string]$matchingRecords[0].ProfileImagePathValueKind
        ProfileExpansionSource = [string]$profileExpansion.Source
        ProfileExpansionSid = [string]$profileExpansion.Sid
        ProfileImagePath = $profilePath
        KnownFolderId = [string]$knownFolderEvidence.KnownFolderId
        KnownFolderSid = [string]$knownFolderEvidence.Sid
        LocalAppDataPath = $localAppDataPath
        AiRoot = $aiRoot
    }
    return Register-CommMonitorAuthorizedUserBinding `
        -Binding $binding `
        -Capability $OwnershipProbeCapability `
        -CapabilityRecord $capabilityRecord
}

function Get-CommMonitorValidatedDataRootAdoptionEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Fresh', 'Migrate')][string] $InstallMode,
        [AllowNull()][object] $Evidence,
        [Parameter(Mandatory)][object] $DataRootProbe,
        [Parameter(Mandatory)][string] $ExpectedCanonicalPath,
        [Parameter(Mandatory)][string] $ExpectedCapabilityId,
        [Parameter(Mandatory)][string] $ExpectedProviderEpoch
    )

    if ($null -eq $Evidence) {
        if ([bool]$DataRootProbe.Exists -and -not [bool]$DataRootProbe.IsEmpty) {
            throw 'A nonempty DataRoot is preserved because no authenticated adoption evidence exists.'
        }
        return $null
    }
    $evidenceRecord = Get-CommMonitorRegisteredEvidenceRecord `
        -Registry $script:CommMonitorDataRootAdoptionEvidence `
        -Evidence $Evidence
    if (-not (Test-CommMonitorOrdinalValue `
            -Value $InstallMode `
            -Allowed @('Migrate')) -or
        $null -eq $evidenceRecord) {
        throw 'DataRoot adoption evidence is not registered, immutable Migrate-mode evidence.'
    }
    if (-not [bool]$DataRootProbe.Exists -or [bool]$DataRootProbe.IsEmpty) {
        throw 'An empty or nonexistent DataRoot cannot be marked as a legacy adoption.'
    }

    $data = $evidenceRecord.Value
    if (-not $data.Contains('sourceKind')) {
        throw 'DataRoot adoption evidence omits sourceKind.'
    }
    $sourceFields = if ([string]::Equals(
            [string]$data.sourceKind,
            'ValidatedLegacyMarker',
            [StringComparison]::Ordinal)) {
        @(
            'schemaVersion', 'sourceKind', 'capabilityId', 'providerEpoch',
            'markerId', 'markerDigest',
            'canonicalPath', 'volumeSerialNumber', 'fileId',
            'aclProfile', 'ownershipProof')
    }
    elseif ([string]::Equals(
            [string]$data.sourceKind,
            'AuthenticatedManifestV3',
            [StringComparison]::Ordinal)) {
        @(
            'schemaVersion', 'sourceKind', 'sourceInstallId',
            'sourcePayloadSha256', 'canonicalPath', 'volumeSerialNumber',
            'fileId', 'aclProfile', 'ownershipProof')
    }
    else {
        throw 'DataRoot adoption evidence has an unknown sourceKind.'
    }
    Assert-CommMonitorExactFields `
        -Dictionary $data `
        -Allowed $sourceFields `
        -Required $sourceFields `
        -Subject 'DataRoot adoption evidence'
    if ($data.schemaVersion -isnot [int] -or
        [int]$data.schemaVersion -ne 1 -or
        -not [string]::Equals(
            [string]$data.ownershipProof,
            'VerifiedLegacyAdoption',
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$data.canonicalPath,
            $ExpectedCanonicalPath,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            [string]$data.volumeSerialNumber,
            [string]$DataRootProbe.VolumeSerialNumber,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$data.fileId,
            [string]$DataRootProbe.FileId,
            [StringComparison]::Ordinal)) {
        throw 'DataRoot adoption evidence does not match the live root identity.'
    }
    if ((Test-CommMonitorOrdinalValue `
            -Value $data.sourceKind `
            -Allowed @('ValidatedLegacyMarker')) -and
        (-not [string]::Equals(
                [string]$data.capabilityId,
                $ExpectedCapabilityId,
                [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$data.providerEpoch,
                $ExpectedProviderEpoch,
                [StringComparison]::Ordinal))) {
        throw 'Legacy DataRoot adoption evidence belongs to another probe capability epoch.'
    }
    $expectedAcl = ConvertTo-CommMonitorCanonicalJson -InputObject $data.aclProfile
    $liveAcl = ConvertTo-CommMonitorCanonicalJson -InputObject (
        ConvertTo-CommMonitorCanonicalAclProfile `
            -Profile $DataRootProbe.AclProfile `
            -Subject 'Live DataRoot ACL profile' `
            -InputCasing Resolver)
    if (-not [string]::Equals(
            $expectedAcl,
            $liveAcl,
            [StringComparison]::Ordinal)) {
        throw 'DataRoot adoption ACL evidence does not match the trusted live probe.'
    }

    $sourceInstallMarker = if (Test-CommMonitorOrdinalValue `
            -Value $data.sourceKind `
            -Allowed @('ValidatedLegacyMarker')) {
        Assert-CommMonitorHash -Value $data.markerDigest -Length 64 -Name markerDigest
        [string]$data.markerId
    }
    else {
        Assert-CommMonitorHash `
            -Value $data.sourcePayloadSha256 `
            -Length 64 `
            -Name sourcePayloadSha256
        [string]$data.sourceInstallId
    }
    $parsedSourceId = [Guid]::Empty
    if (-not [Guid]::TryParseExact($sourceInstallMarker, 'D', [ref]$parsedSourceId) -or
        -not [string]::Equals(
            $sourceInstallMarker,
            $parsedSourceId.ToString('D').ToLowerInvariant(),
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$DataRootProbe.InstallIdMarker,
            $sourceInstallMarker,
            [StringComparison]::Ordinal)) {
        throw 'DataRoot install marker does not match authenticated adoption evidence.'
    }
    return $data
}

function Resolve-CommMonitorOwnershipRoots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Desktop', 'ServerDesktop', 'ServerCore')]
        [string] $PlatformKind,

        [Parameter(Mandatory)]
        [int] $PlatformBuild,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $PlatformComponents,

        [string] $AppRoot,

        [Parameter(Mandatory)][string] $ProgramFilesPath,
        [Parameter(Mandatory)][string] $ProgramDataPath,
        [Parameter(Mandatory)][object] $AuthorizedUserBinding,

        [ValidateSet('Fresh', 'Migrate')]
        [string] $InstallMode = 'Fresh',

        [AllowNull()][object] $DataRootAdoptionEvidence
    )

    if (-not (Test-CommMonitorOrdinalValue `
            -Value $InstallMode `
            -Allowed @('Fresh', 'Migrate'))) {
        throw 'Install mode must be an exact supported value.'
    }
    $bindingRecord = Get-CommMonitorAuthorizedUserBindingRecord `
        -Binding $AuthorizedUserBinding
    if ($null -eq $bindingRecord) {
        throw 'AuthorizedUserBinding was not produced by the trusted resolver in this session.'
    }
    $authorizedUser = $bindingRecord.BindingData
    $authorizedFields = @(
        'SchemaVersion', 'Source', 'IdentityVerified',
        'CapabilityId', 'ProviderEpoch',
        'OriginalInteractiveSid', 'Sid', 'ProfileListKeyPath',
        'ProfileImagePathRaw', 'ProfileImagePathValueKind',
        'ProfileExpansionSource', 'ProfileExpansionSid',
        'ProfileImagePath', 'KnownFolderId', 'KnownFolderSid',
        'LocalAppDataPath', 'AiRoot')
    Assert-CommMonitorExactFields `
        -Dictionary $authorizedUser `
        -Allowed $authorizedFields `
        -Required $authorizedFields `
        -Subject 'Authorized user binding'
    $canonicalBindingSid = ConvertTo-CommMonitorCanonicalProfileUserSid `
        -Sid $authorizedUser.Sid
    if ($authorizedUser.SchemaVersion -isnot [int] -or
        [int]$authorizedUser.SchemaVersion -ne 1 -or
        -not [string]::Equals(
            [string]$authorizedUser.Source,
            'ProfileList+WindowsTokenSession+KnownFolder',
            [StringComparison]::Ordinal) -or
        $authorizedUser.IdentityVerified -isnot [bool] -or
        -not [bool]$authorizedUser.IdentityVerified -or
        -not [string]::Equals(
            [string]$authorizedUser.CapabilityId,
            [string]$bindingRecord.CapabilityId,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$authorizedUser.ProviderEpoch,
            [string]$bindingRecord.Epoch,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$authorizedUser.OriginalInteractiveSid,
            [string]$authorizedUser.Sid,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$authorizedUser.KnownFolderSid,
            [string]$authorizedUser.Sid,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$authorizedUser.ProfileExpansionSid,
            [string]$authorizedUser.Sid,
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$authorizedUser.ProfileExpansionSource,
            'ExpandEnvironmentStringsForUserW',
            [StringComparison]::Ordinal) -or
        -not (Test-CommMonitorOrdinalValue `
            -Value $authorizedUser.ProfileImagePathValueKind `
            -Allowed @('String', 'ExpandString')) -or
        -not [string]::Equals(
            [string]$authorizedUser.ProfileListKeyPath,
            ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' +
                [string]$authorizedUser.Sid),
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$authorizedUser.KnownFolderId,
            '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}',
            [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$authorizedUser.Sid,
            $canonicalBindingSid,
            [StringComparison]::Ordinal)) {
        throw 'AuthorizedUserBinding metadata is not exact or positively verified.'
    }

    $AuthorizedUserSid = [string]$authorizedUser.Sid
    $ProfileImagePath = [string]$authorizedUser.ProfileImagePath
    $LocalAppDataPath = [string]$authorizedUser.LocalAppDataPath
    $AiRoot = [string]$authorizedUser.AiRoot

    $canonicalProgramFiles = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path $ProgramFilesPath `
        -Role ProgramFilesPath
    $canonicalProgramData = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path $ProgramDataPath `
        -Role ProgramDataPath
    $canonicalProfile = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path $ProfileImagePath `
        -Role ProfileImagePath
    $canonicalLocalAppData = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path $LocalAppDataPath `
        -Role LocalAppDataPath
    $canonicalAiRoot = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path $AiRoot `
        -Role AiRoot

    $expectedAiRoot = ConvertTo-CommMonitorCanonicalWindowsPath `
        -Path (Join-Path $canonicalLocalAppData 'LemonSerialMonitor\AI') `
        -Role ExpectedAiRoot
    if (-not [string]::Equals(
            $canonicalAiRoot,
            $expectedAiRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The authorized ProfileImagePath, LocalAppData and AI root are not canonically bound.'
    }

    $validatedPlatformComponents = [string[]]@(
        Assert-CommMonitorExactPlatformComponents `
            -PlatformKind $PlatformKind `
            -PlatformComponents $PlatformComponents)
    [void](Assert-CommMonitorSupportedPlatformBuild `
            -PlatformKind $PlatformKind `
            -PlatformBuild $PlatformBuild)

    $appPathInput = if ([string]::IsNullOrWhiteSpace($AppRoot)) {
        $productDisplayName = 'Lemon' +
            [char]0x4e32 + [char]0x53e3 + [char]0x76d1 + [char]0x63a7
        Join-Path $canonicalProgramFiles $productDisplayName
    }
    else {
        $AppRoot
    }
    $paths = [ordered]@{
        AppRoot = ConvertTo-CommMonitorCanonicalWindowsPath `
            -Path $appPathInput `
            -Role AppRoot
        CoreRoot = ConvertTo-CommMonitorCanonicalWindowsPath `
            -Path (Join-Path $canonicalProgramFiles 'CommMonitor') `
            -Role CoreRoot
        DataRoot = ConvertTo-CommMonitorCanonicalWindowsPath `
            -Path (Join-Path $canonicalProgramData 'CommMonitor') `
            -Role DataRoot
        InstallerRoot = ConvertTo-CommMonitorCanonicalWindowsPath `
            -Path (Join-Path $canonicalProgramData 'LemonSerialMonitor\Installer') `
            -Role InstallerRoot
        AiStateRoot = $canonicalAiRoot
    }

    $pathNames = @($paths.Keys)
    for ($firstIndex = 0; $firstIndex -lt $pathNames.Count; $firstIndex++) {
        for ($secondIndex = $firstIndex + 1; $secondIndex -lt $pathNames.Count; $secondIndex++) {
            $firstName = $pathNames[$firstIndex]
            $secondName = $pathNames[$secondIndex]
            if (Test-CommMonitorPathOverlap `
                    -First $paths[$firstName] `
                    -Second $paths[$secondName]) {
                throw "$firstName and $secondName overlap: '$($paths[$firstName])' and '$($paths[$secondName])'."
            }
        }
    }

    $validated = [ordered]@{}
    foreach ($role in @('CoreRoot', 'DataRoot', 'InstallerRoot', 'AiStateRoot')) {
        $validated[$role] = Get-CommMonitorValidatedRootProbe `
            -Path $paths[$role] `
            -Role $role `
            -RequireEmpty ($role -ne 'DataRoot' -or $InstallMode -eq 'Fresh') `
            -RequireProtectedAcl ($role -in @('CoreRoot', 'DataRoot', 'InstallerRoot'))
    }
    if ($PlatformKind -in @('Desktop', 'ServerDesktop')) {
        $validated['AppRoot'] = Get-CommMonitorValidatedRootProbe `
            -Path $paths.AppRoot `
            -Role AppRoot `
            -RequireEmpty $true
    }
    Assert-CommMonitorDistinctPhysicalRoots -ValidatedRoots $validated
    $validatedAdoption = Get-CommMonitorValidatedDataRootAdoptionEvidence `
        -InstallMode $InstallMode `
        -Evidence $DataRootAdoptionEvidence `
        -DataRootProbe $validated.DataRoot `
        -ExpectedCanonicalPath $paths.DataRoot `
        -ExpectedCapabilityId ([string]$bindingRecord.CapabilityId) `
        -ExpectedProviderEpoch ([string]$bindingRecord.Epoch)

    $rootResult = [ordered]@{}
    foreach ($role in @('AppRoot', 'CoreRoot', 'DataRoot', 'InstallerRoot')) {
        if ($role -eq 'AppRoot' -and $PlatformKind -eq 'ServerCore') {
            $rootResult[$role] = [pscustomobject][ordered]@{
                Role = $role
                CanonicalPath = $paths[$role]
                Active = $false
                Present = $false
                CreatedByInstall = $false
                VolumeSerialNumber = $null
                FileId = $null
                AclProfile = $null
                PhysicalCandidatePath = $null
                OwnershipProof = $null
                AdoptionSource = $null
                ContentPolicy = 'EmptyAfterOwnedChildren'
            }
            continue
        }

        $probe = $validated[$role]
        $ownershipProof = if ($role -eq 'DataRoot' -and $null -ne $validatedAdoption) {
            'VerifiedLegacyAdoption'
        }
        elseif (-not [bool]$probe.Exists) {
            'CreatedThisInstall'
        }
        else {
            'PreExistingShared'
        }
        $rootResult[$role] = [pscustomobject][ordered]@{
            Role = $role
            CanonicalPath = $paths[$role]
            Active = $true
            Present = [bool]$probe.Exists
            CreatedByInstall = -not [bool]$probe.Exists
            VolumeSerialNumber = ([string]$probe.VolumeSerialNumber).ToLowerInvariant()
            FileId = if ([bool]$probe.Exists) {
                ([string]$probe.FileId).ToLowerInvariant()
            }
            else {
                $null
            }
            AclProfile = $probe.AclProfile
            PhysicalCandidatePath = [string]$probe.PhysicalCandidatePath
            OwnershipProof = $ownershipProof
            AdoptionSource = if ($role -eq 'DataRoot') {
                $validatedAdoption
            }
            else {
                $null
            }
            ContentPolicy = if ($role -eq 'DataRoot') {
                if ($ownershipProof -in @('CreatedThisInstall', 'VerifiedLegacyAdoption')) {
                    'ProtectedManagedTree'
                }
                else {
                    'EmptyAfterOwnedChildren'
                }
            }
            else {
                'EmptyAfterOwnedChildren'
            }
        }
    }

    return [pscustomobject][ordered]@{
        Platform = [pscustomobject][ordered]@{
            Kind = $PlatformKind
            Build = $PlatformBuild
            Components = [string[]]@($validatedPlatformComponents | Sort-Object)
        }
        AppRoot = $rootResult.AppRoot
        CoreRoot = $rootResult.CoreRoot
        DataRoot = $rootResult.DataRoot
        InstallerRoot = $rootResult.InstallerRoot
        AiStateRoot = [pscustomobject][ordered]@{
            Role = 'AiStateRoot'
            CanonicalPath = $canonicalAiRoot
            Active = $true
            Present = [bool]$validated.AiStateRoot.Exists
            CreatedByInstall = -not [bool]$validated.AiStateRoot.Exists
            VolumeSerialNumber = ([string]$validated.AiStateRoot.VolumeSerialNumber).ToLowerInvariant()
            FileId = if ([bool]$validated.AiStateRoot.Exists) {
                ([string]$validated.AiStateRoot.FileId).ToLowerInvariant()
            }
            else {
                $null
            }
            AclProfile = $validated.AiStateRoot.AclProfile
            PhysicalCandidatePath = [string]$validated.AiStateRoot.PhysicalCandidatePath
            OwnershipProof = if (-not [bool]$validated.AiStateRoot.Exists) {
                'CreatedThisInstall'
            }
            else {
                'PreExistingShared'
            }
            AdoptionSource = $null
            ContentPolicy = 'EmptyAfterOwnedChildren'
        }
        AuthorizedUser = [pscustomobject][ordered]@{
            Sid = $AuthorizedUserSid
            ProfileListKeyPath = [string]$authorizedUser.ProfileListKeyPath
            ProfileImagePathRaw = [string]$authorizedUser.ProfileImagePathRaw
            ProfileImagePathValueKind = [string]$authorizedUser.ProfileImagePathValueKind
            ProfileExpansionSource = [string]$authorizedUser.ProfileExpansionSource
            ProfileExpansionSid = [string]$authorizedUser.ProfileExpansionSid
            ProfileImagePath = $canonicalProfile
            KnownFolderId = [string]$authorizedUser.KnownFolderId
            KnownFolderSid = [string]$authorizedUser.KnownFolderSid
            LocalAppDataPath = $canonicalLocalAppData
            AiRoot = $canonicalAiRoot
        }
    }
}

function Test-CommMonitorReparseAttributes {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [IO.FileAttributes] $Attributes
    )

    return ($Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

function Assert-CommMonitorNoReparsePoint {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $pathRoot = [IO.Path]::GetPathRoot($resolvedPath)
    $ancestorPath = $pathRoot
    $relativePath = $resolvedPath.Substring($pathRoot.Length)
    foreach ($segment in @($relativePath -split '[\\/]' | Where-Object { $_ })) {
        $ancestorPath = Join-Path $ancestorPath $segment
        if (-not (Test-Path -LiteralPath $ancestorPath)) {
            break
        }
        $ancestorItem = Get-Item -LiteralPath $ancestorPath -Force -ErrorAction Stop
        if (Test-CommMonitorReparseAttributes -Attributes $ancestorItem.Attributes) {
            throw "Refusing reparse-point path '$($ancestorItem.FullName)'."
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        return $resolvedPath
    }

    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $rootItem = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    if (Test-CommMonitorReparseAttributes -Attributes $rootItem.Attributes) {
        throw "Refusing reparse-point path '$($rootItem.FullName)'."
    }
    if (-not $rootItem.PSIsContainer) {
        throw "Expected a directory at '$resolvedPath'."
    }
    $pending.Push([IO.DirectoryInfo]$rootItem)

    while ($pending.Count -ne 0) {
        $directory = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
            if (Test-CommMonitorReparseAttributes -Attributes $child.Attributes) {
                throw "Refusing reparse point inside the Lemon serial monitor tree: '$($child.FullName)'."
            }
            if ($child.PSIsContainer) {
                $pending.Push([IO.DirectoryInfo]$child)
            }
        }
    }

    return $resolvedPath
}

function Test-CommMonitorAclTrusted {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $OwnerSid,
        [AllowEmptyCollection()][object[]] $AccessRules,
        [string[]] $AdditionalTrustedSids = @()
    )

    $trustedOwners = @('S-1-5-18', 'S-1-5-32-544') +
        @($AdditionalTrustedSids)
    if ($trustedOwners -notcontains $OwnerSid) {
        return $false
    }

    $trustedWriters = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    ) + @($AdditionalTrustedSids)
    $writeRights = [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership

    foreach ($rule in @($AccessRules)) {
        $identitySid = if ($null -ne $rule.PSObject.Properties['IdentitySid']) {
            [string]$rule.IdentitySid
        }
        else {
            [string]$rule.IdentityReference
        }
        if ([string]::Equals(
                [string]$rule.AccessControlType,
                'Allow',
                [StringComparison]::OrdinalIgnoreCase) -and
            $trustedWriters -notcontains $identitySid -and
            (([Security.AccessControl.FileSystemRights]$rule.FileSystemRights -band
                    $writeRights) -ne 0)) {
            return $false
        }
    }

    return $true
}

function Assert-CommMonitorTrustedPackageTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path
    )

    $rootPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    [void](Assert-CommMonitorNoReparsePoint -Path $rootPath)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $currentSid = $identity.User.Value
    }
    finally {
        $identity.Dispose()
    }

    $items = @(Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop)
    $items += @(Get-ChildItem `
            -LiteralPath $rootPath `
            -Force `
            -Recurse `
            -ErrorAction Stop)
    foreach ($item in $items) {
        $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
        try {
            $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
                [Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            $ownerSid = [string]$acl.Owner
        }
        $rules = @(
            $acl.GetAccessRules(
                $true,
                $true,
                [Security.Principal.SecurityIdentifier]) |
                ForEach-Object {
                    [pscustomobject]@{
                        IdentitySid = $_.IdentityReference.Value
                        AccessControlType = $_.AccessControlType
                        FileSystemRights = $_.FileSystemRights
                    }
                }
        )
        if (-not (Test-CommMonitorAclTrusted `
                -OwnerSid $ownerSid `
                -AccessRules $rules `
                -AdditionalTrustedSids @($currentSid))) {
            throw "Refusing package item with an untrusted owner or writable ACL: '$($item.FullName)'."
        }
    }
}

function Get-CommMonitorFileManifest {
    [CmdletBinding()]
    [OutputType([Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $Root,
        [string[]] $IncludedDirectories
    )

    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    $searchRoots = if ($null -eq $IncludedDirectories -or
        $IncludedDirectories.Count -eq 0) {
        @($rootPath)
    }
    else {
        @($IncludedDirectories | ForEach-Object { Join-Path $rootPath $_ })
    }
    $manifest = [ordered]@{}
    foreach ($searchRoot in $searchRoots) {
        if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) {
            throw "Manifest directory not found: $searchRoot"
        }
        foreach ($file in @(
                Get-ChildItem `
                    -LiteralPath $searchRoot `
                    -File `
                    -Force `
                    -Recurse `
                    -ErrorAction Stop)) {
            $fullName = [IO.Path]::GetFullPath($file.FullName)
            if (-not $fullName.StartsWith(
                    $prefix,
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "Manifest entry escaped '$rootPath': $fullName"
            }
            $relativeName = $fullName.Substring($prefix.Length).Replace('\', '/')
            $manifest[$relativeName] = (Get-FileHash `
                    -LiteralPath $fullName `
                    -Algorithm SHA256).Hash
        }
    }
    return $manifest
}

function Test-CommMonitorFileManifestMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Expected,
        [Parameter(Mandatory)][Collections.IDictionary] $Actual
    )

    if ($Expected.Count -ne $Actual.Count) {
        return $false
    }
    foreach ($key in $Expected.Keys) {
        if (-not $Actual.Contains($key) -or
            -not [string]::Equals(
                [string]$Expected[$key],
                [string]$Actual[$key],
                [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Assert-CommMonitorTrustedDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [AllowEmptyCollection()][string[]] $AdditionalTrustedSids = @()
    )

    [void](Assert-CommMonitorNoReparsePoint -Path $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "Expected a trusted directory at '$Path'."
    }

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    try {
        $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
            [Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        $ownerSid = [string]$acl.Owner
    }
    $rules = @(
        $acl.GetAccessRules(
            $true,
            $true,
            [Security.Principal.SecurityIdentifier]) |
            ForEach-Object {
                [pscustomobject]@{
                    IdentitySid = $_.IdentityReference.Value
                    AccessControlType = $_.AccessControlType
                    FileSystemRights = $_.FileSystemRights
                }
            }
    )
    if (-not (Test-CommMonitorAclTrusted `
            -OwnerSid $ownerSid `
            -AccessRules $rules `
            -AdditionalTrustedSids $AdditionalTrustedSids)) {
        throw "Refusing pre-existing directory with an untrusted owner or writable ACL: '$Path'."
    }
}

function Write-CommMonitorAtomicTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $LiteralPath,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Value
    )

    $fullPath = [IO.Path]::GetFullPath($LiteralPath)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    Assert-CommMonitorTrustedDirectory -Path $directory
    $temporaryPath = Join-Path $directory (
        '.{0}.{1}.tmp' -f [IO.Path]::GetFileName($fullPath), [Guid]::NewGuid().ToString('N'))
    $replacementBackupPath = Join-Path $directory (
        '.{0}.{1}.bak' -f [IO.Path]::GetFileName($fullPath), [Guid]::NewGuid().ToString('N'))
    $stream = $null
    $writer = $null
    try {
        $stream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough)
        $writer = [IO.StreamWriter]::new(
            $stream,
            [Text.UTF8Encoding]::new($false))
        $writer.Write($Value)
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose()
        $writer = $null
        $stream = $null

        if ([IO.File]::Exists($fullPath)) {
            $target = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            if (Test-CommMonitorReparseAttributes -Attributes $target.Attributes) {
                throw "Refusing to replace reparse-point file '$fullPath'."
            }
            [IO.File]::Replace(
                $temporaryPath,
                $fullPath,
                $replacementBackupPath,
                $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $fullPath)
        }
    }
    finally {
        if ($null -ne $writer) {
            $writer.Dispose()
        }
        elseif ($null -ne $stream) {
            $stream.Dispose()
        }
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ([IO.File]::Exists($replacementBackupPath)) {
            [IO.File]::Delete($replacementBackupPath)
        }
    }
}

function Set-CommMonitorRestrictedAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $administrators = [Security.Principal.SecurityIdentifier]::new(
        'S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($administrators)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($administrators, $system)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $identity,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $propagation,
                $allow))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $users,
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance,
            $propagation,
            $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Test-CommMonitorNativeExitCode {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [int] $ExitCode,

        [Parameter(Mandatory)]
        [int[]] $SuccessExitCodes
    )

    return @($SuccessExitCodes) -contains $ExitCode
}

function Test-CommMonitorTestSigningOutput {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][string] $Output
    )

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $false
    }
    $localizedYes = [char]0x662F
    $enabledValues = 'Yes|On|True|{0}' -f
        [regex]::Escape([string]$localizedYes)
    return [regex]::IsMatch(
        $Output,
        '(?im)^\s*testsigning\s+(' + $enabledValues + ')\s*$',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Test-CommMonitorDriverPackageRecord {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][string] $PublishedName,
        [AllowNull()][string] $OriginalFileName,
        [AllowNull()][string] $InfSha256,
        [AllowNull()][string] $ExpectedPublishedName,
        [AllowNull()][string] $ExpectedOriginalFileName,
        [AllowNull()][string] $ExpectedInfSha256
    )

    if ([string]::IsNullOrWhiteSpace($PublishedName) -or
        [string]::IsNullOrWhiteSpace($OriginalFileName) -or
        [string]::IsNullOrWhiteSpace($InfSha256) -or
        -not [regex]::IsMatch(
            $PublishedName,
            '^oem[0-9]+\.inf$',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
        -not [regex]::IsMatch(
            $InfSha256,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        return $false
    }

    return [string]::Equals(
            $PublishedName,
            $ExpectedPublishedName,
            [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals(
            $OriginalFileName,
            $ExpectedOriginalFileName,
            [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals(
            $InfSha256,
            $ExpectedInfSha256,
            [StringComparison]::OrdinalIgnoreCase)
}

function Get-CommMonitorNewDriverPackageCandidates {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]] $DriverPackages,
        [AllowEmptyCollection()][string[]] $PublishedNamesBefore
    )

    $before = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($publishedName in @($PublishedNamesBefore)) {
        [void]$before.Add($publishedName)
    }
    return @(
        foreach ($driverPackage in @($DriverPackages)) {
            $publishedName = [string]$driverPackage.Driver
            if (-not [string]::IsNullOrWhiteSpace($publishedName) -and
                -not $before.Contains($publishedName)) {
                $driverPackage
            }
        }
    )
}

function ConvertTo-CommMonitorCanonicalServicePath {
    param([AllowNull()][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    $systemRootPrefix = '\SystemRoot\'
    if ($expanded.StartsWith(
            $systemRootPrefix,
            [StringComparison]::OrdinalIgnoreCase)) {
        $expanded = Join-Path `
            $env:SystemRoot `
            $expanded.Substring($systemRootPrefix.Length)
    }

    if (-not [regex]::IsMatch(
            $expanded,
            '^[A-Za-z]:[\\/]',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        return $null
    }
    try {
        return [IO.Path]::GetFullPath($expanded)
    }
    catch {
        return $null
    }
}

function Test-CommMonitorServiceImagePath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][string] $ImagePath,
        [AllowNull()][string] $ExpectedExecutable
    )

    if ([string]::IsNullOrWhiteSpace($ImagePath) -or
        [string]::IsNullOrWhiteSpace($ExpectedExecutable)) {
        return $false
    }

    $trimmed = $ImagePath.Trim()
    $expectedPath = ConvertTo-CommMonitorCanonicalServicePath `
        -Path $ExpectedExecutable
    if ($null -eq $expectedPath) {
        return $false
    }
    if ($trimmed.StartsWith('"', [StringComparison]::Ordinal)) {
        $closingQuote = $trimmed.IndexOf('"', 1)
        if ($closingQuote -le 1) {
            return $false
        }
        $executable = $trimmed.Substring(1, $closingQuote - 1)
    }
    else {
        $wholePath = ConvertTo-CommMonitorCanonicalServicePath -Path $trimmed
        if ($null -ne $wholePath -and
            [string]::Equals(
                $wholePath,
                $expectedPath,
                [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        $expectedLength = $ExpectedExecutable.Length
        if ($trimmed.Length -lt $expectedLength) {
            return $false
        }
        $executable = $trimmed.Substring(0, $expectedLength)
        if ($trimmed.Length -gt $expectedLength -and
            -not [char]::IsWhiteSpace($trimmed[$expectedLength])) {
            return $false
        }
    }

    $actualPath = ConvertTo-CommMonitorCanonicalServicePath -Path $executable
    return $null -ne $actualPath -and
        $null -ne $expectedPath -and
        [string]::Equals(
        $actualPath,
        $expectedPath,
        [StringComparison]::OrdinalIgnoreCase)
}

function New-CommMonitorInstallMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $InstallPath,
        [Parameter(Mandatory)][string] $BackupPath,
        [Parameter(Mandatory)][string] $BackupSha256,
        [string] $InstallId = ([Guid]::NewGuid().ToString('D'))
    )

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Product = 'CommMonitor'
        InstallId = $InstallId
        InstalledUtc = [DateTimeOffset]::UtcNow.ToString('o')
        InstallPath = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\', '/')
        BackupPath = [IO.Path]::GetFullPath($BackupPath).TrimEnd('\', '/')
        BackupSha256 = $BackupSha256
    }
}

function Test-CommMonitorInstallMarker {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][psobject] $Marker,
        [Parameter(Mandatory)][string] $ExpectedInstallPath,
        [Parameter(Mandatory)][string] $ExpectedBackupPath,
        [Parameter(Mandatory)][string] $ExpectedBackupSha256
    )

    foreach ($name in @(
            'SchemaVersion',
            'Product',
            'InstallId',
            'InstallPath',
            'BackupPath',
            'BackupSha256')) {
        if ($null -eq $Marker.PSObject.Properties[$name]) {
            return $false
        }
    }

    $parsedInstallId = [Guid]::Empty
    if ($Marker.SchemaVersion -ne 1 -or
        -not [string]::Equals(
            [string]$Marker.Product,
            'CommMonitor',
            [StringComparison]::Ordinal) -or
        -not [Guid]::TryParse([string]$Marker.InstallId, [ref]$parsedInstallId) -or
        -not [regex]::IsMatch(
            [string]$Marker.BackupSha256,
            '^[0-9a-f]{64}$',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        return $false
    }

    return [string]::Equals(
            [IO.Path]::GetFullPath([string]$Marker.InstallPath).TrimEnd('\', '/'),
            [IO.Path]::GetFullPath($ExpectedInstallPath).TrimEnd('\', '/'),
            [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals(
            [IO.Path]::GetFullPath([string]$Marker.BackupPath).TrimEnd('\', '/'),
            [IO.Path]::GetFullPath($ExpectedBackupPath).TrimEnd('\', '/'),
            [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals(
            [string]$Marker.BackupSha256,
            $ExpectedBackupSha256,
            [StringComparison]::OrdinalIgnoreCase)
}

function Test-CommMonitorAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [scriptblock] $RoleProbe
    )

    if ($null -ne $RoleProbe) {
        return [bool](& $RoleProbe)
    }

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return $false
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally {
        $identity.Dispose()
    }
}

function Invoke-CommMonitorAdminGuardedAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $AdministratorProbe,

        [Parameter(Mandatory)]
        [scriptblock] $WriteAction
    )

    if (-not [bool](& $AdministratorProbe)) {
        throw 'Lemon serial monitor installation requires an elevated administrator PowerShell.'
    }

    & $WriteAction
}

Export-ModuleMember -Function @(
    'Add-MultiStringValue',
    'Remove-MultiStringValue',
    'New-CommMonitorInstallBackup',
    'ConvertTo-CommMonitorInstallBackupJson',
    'ConvertFrom-CommMonitorInstallBackupJson',
    'Resolve-CommMonitorInstallRoot',
    'Initialize-CommMonitorWindowsOwnershipProvider',
    'New-CommMonitorWindowsOwnershipProbeCapability',
    'Resolve-CommMonitorOwnershipRoots',
    'Get-CommMonitorValidatedRootProbe',
    'Assert-CommMonitorDistinctPhysicalRoots',
    'Resolve-CommMonitorAuthorizedUser',
    'ConvertTo-CommMonitorCanonicalProfileUserSid',
    'Assert-CommMonitorLegacyDataRootMarker',
    'New-CommMonitorDataRootAdoptionEvidence',
    'ConvertTo-CommMonitorCanonicalJson',
    'Get-CommMonitorCanonicalJsonBytes',
    'Get-CommMonitorCanonicalStateFileBytes',
    'ConvertFrom-CommMonitorStrictJson',
    'New-CommMonitorOwnedObject',
    'Assert-CommMonitorOwnershipLayout',
    'New-CommMonitorOwnershipPayload',
    'Get-CommMonitorSha256Hex',
    'Get-CommMonitorHmacSha256Hex',
    'Test-CommMonitorFixedTimeEquals',
    'New-CommMonitorManifestKey',
    'Get-CommMonitorManifestKey',
    'Test-CommMonitorKeyFileAcl',
    'New-CommMonitorOwnershipEnvelope',
    'Assert-CommMonitorOwnershipEnvelope',
    'New-CommMonitorOwnershipManifest',
    'Assert-CommMonitorOwnershipManifest',
    'New-CommMonitorOwnershipAnchor',
    'Assert-CommMonitorOwnershipState',
    'Assert-CommMonitorOwnershipManifestState',
    'Update-CommMonitorOwnershipManifestCas',
    'New-CommMonitorContinuationEnvelope',
    'Assert-CommMonitorContinuationEnvelope',
    'Resolve-CommMonitorContinuationPair',
    'ConvertTo-CommMonitorActiveContinuationEnvelope',
    'Get-CommMonitorTerminalCleanupAuthorityIdentity',
    'New-CommMonitorTerminalCleanupEnvelope',
    'Assert-CommMonitorTerminalCleanupEnvelope',
    'Resolve-CommMonitorTerminalCleanupAuthority',
    'ConvertTo-CommMonitorActiveTerminalCleanupEnvelope',
    'Get-CommMonitorTerminalCleanupActions',
    'Get-CommMonitorPostTerminalDirectoryCleanupActions',
    'Test-CommMonitorTerminalCleanupComplete',
    'New-CommMonitorUninstallResultEnvelope',
    'Assert-CommMonitorUninstallResultEnvelope',
    'New-CommMonitorTerminalPreparationCapability',
    'Test-CommMonitorTerminalPreparationCapability',
    'Update-CommMonitorOwnershipStateCas',
    'Write-CommMonitorAtomicStateFile',
    'Test-CommMonitorReparseAttributes',
    'Assert-CommMonitorNoReparsePoint',
    'Test-CommMonitorAclTrusted',
    'Assert-CommMonitorTrustedDirectory',
    'Assert-CommMonitorTrustedPackageTree',
    'Get-CommMonitorFileManifest',
    'Test-CommMonitorFileManifestMatch',
    'Write-CommMonitorAtomicTextFile',
    'Set-CommMonitorRestrictedAcl',
    'Test-CommMonitorNativeExitCode',
    'Test-CommMonitorTestSigningOutput',
    'Test-CommMonitorDriverPackageRecord',
    'Get-CommMonitorNewDriverPackageCandidates',
    'Test-CommMonitorServiceImagePath',
    'New-CommMonitorInstallMarker',
    'Test-CommMonitorInstallMarker',
    'Test-CommMonitorAdministrator',
    'Invoke-CommMonitorAdminGuardedAction'
)
