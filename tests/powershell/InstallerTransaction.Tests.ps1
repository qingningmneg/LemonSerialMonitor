$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'scripts\CommMonitor.InstallHelpers.psm1'
Import-Module $modulePath -Force

if (-not ('CommMonitorInstallerTestCodeProperty' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Management.Automation;

public static class CommMonitorInstallerTestCodeProperty
{
    public static object GetInjected(PSObject instance)
    {
        return "injected";
    }
}
'@
}

function Get-CommMonitorTestFileId {
    param([Parameter(Mandatory)][string] $Identity)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Identity.ToLowerInvariant())
        return ([BitConverter]::ToString(
                $sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 32).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-CommMonitorTestSha256Hex {
    param([Parameter(Mandatory)][string] $Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
                $sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text)))).Replace(
                    '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Assert-CommMonitorTestThrowsLike {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $MessagePattern
    )

    $didThrow = $false
    $message = $null
    try {
        & $Action
    }
    catch {
        $didThrow = $true
        $message = $_.Exception.Message
    }
    $didThrow | Should Be $true
    $message | Should Match $MessagePattern
}

function Assert-CommMonitorTestThrowsExactly {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $Message
    )

    $errorRecord = $null
    try {
        & $Action
    }
    catch {
        $errorRecord = $_
    }
    ($null -ne $errorRecord) | Should Be $true
    [string]::Equals(
        [string]$errorRecord.Exception.Message,
        $Message,
        [StringComparison]::Ordinal) | Should Be $true
}

function Assert-CommMonitorTestNamedParameterNotFound {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $ParameterName,
        [Parameter(Mandatory)][string] $CommandName
    )

    $errorRecord = $null
    try {
        & $Action
    }
    catch {
        $errorRecord = $_
    }
    ($null -ne $errorRecord) | Should Be $true
    [string]::Equals(
        [string]$errorRecord.FullyQualifiedErrorId,
        "NamedParameterNotFound,$CommandName",
        [StringComparison]::Ordinal) | Should Be $true
    $errorRecord.Exception.GetType().FullName |
        Should Be 'System.Management.Automation.ParameterBindingException'
    [string]::Equals(
        [string]$errorRecord.Exception.ParameterName,
        $ParameterName,
        [StringComparison]::Ordinal) | Should Be $true
    $errorRecord.CategoryInfo.Category |
        Should Be ([Management.Automation.ErrorCategory]::InvalidArgument)
}

function Add-CommMonitorTestCodeProperty {
    param(
        [Parameter(Mandatory)][object] $InputObject,
        [string] $Name = 'injectedCode'
    )

    $InputObject | Add-Member `
        -MemberType CodeProperty `
        -Name $Name `
        -Value ([CommMonitorInstallerTestCodeProperty].GetMethod('GetInjected'))
}

function Copy-CommMonitorTestOrdinalDictionary {
    param([Parameter(Mandatory)][object] $InputObject)

    $copy = [Collections.Specialized.OrderedDictionary]::new(
        [StringComparer]::Ordinal)
    if ($InputObject -is [Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $copy.Add([string]$key, $InputObject[$key])
        }
    }
    else {
        foreach ($property in $InputObject.PSObject.Properties) {
            $copy.Add([string]$property.Name, $property.Value)
        }
    }
    return $copy
}

function New-CommMonitorTestExactSchemaMutations {
    param(
        [Parameter(Mandatory)][object] $InputObject,
        [Parameter(Mandatory)][string] $RequiredField,
        [Parameter(Mandatory)][string] $WrongCaseField
    )

    $unknown = Copy-CommMonitorTestOrdinalDictionary -InputObject $InputObject
    $unknown.Add('unexpected', $true)

    $missing = Copy-CommMonitorTestOrdinalDictionary -InputObject $InputObject
    $missing.Remove($RequiredField)

    $caseConfused = Copy-CommMonitorTestOrdinalDictionary -InputObject $InputObject
    $value = $caseConfused[$RequiredField]
    $caseConfused.Remove($RequiredField)
    $caseConfused.Add($WrongCaseField, $value)

    return @(
        [pscustomobject]@{ Kind = 'unknown'; Value = $unknown },
        [pscustomobject]@{ Kind = 'missing'; Value = $missing },
        [pscustomobject]@{ Kind = 'case-confused'; Value = $caseConfused })
}

function New-CommMonitorTestSignedEnvelopeUnchecked {
    param(
        [Parameter(Mandatory)][object] $Payload,
        [Parameter(Mandatory)][byte[]] $Key
    )

    $keyId = Get-CommMonitorSha256Hex -Bytes $Key
    $payloadJson = ConvertTo-CommMonitorCanonicalJson -InputObject $Payload
    $payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes($payloadJson)
    return [ordered]@{
        integrity = [ordered]@{
            algorithm = 'HMAC-SHA256'
            keyId = $keyId
            payloadSha256 = Get-CommMonitorSha256Hex -Bytes $payloadBytes
            tag = Get-CommMonitorHmacSha256Hex -Key $Key -Bytes $payloadBytes
        }
        payload = $Payload
        schemaVersion = 3
    }
}

function New-CommMonitorTestRawStringCoercions {
    param([Parameter(Mandatory)][string] $ValidValue)

    return @(
        [pscustomobject]@{
            Name = 'one-element array'
            Value = [object[]]@($ValidValue)
        },
        [pscustomobject]@{
            Name = 'StringBuilder'
            Value = [Text.StringBuilder]::new($ValidValue)
        },
        [pscustomobject]@{ Name = 'explicit null'; Value = $null },
        [pscustomobject]@{ Name = 'Double'; Value = [double]1 },
        [pscustomobject]@{ Name = 'Int64'; Value = [long]1 })
}

function New-CommMonitorTestRawInt32Coercions {
    param([Parameter(Mandatory)][int] $ValidValue)

    return @(
        [pscustomobject]@{
            Name = 'one-element array'
            Value = [object[]]@($ValidValue)
        },
        [pscustomobject]@{ Name = 'string'; Value = [string]$ValidValue },
        [pscustomobject]@{ Name = 'Boolean'; Value = $true },
        [pscustomobject]@{ Name = 'Double'; Value = [double]$ValidValue },
        [pscustomobject]@{ Name = 'Int64'; Value = [long]$ValidValue })
}

function New-CommMonitorTestProtectedAclProfile {
    return [pscustomobject][ordered]@{
        OwnerSid = 'S-1-5-18'
        AreAccessRulesProtected = $true
        AllowedFullControlSids = @('S-1-5-18', 'S-1-5-32-544')
        DenyRuleCount = 0
        UsersWritable = $false
    }
}

function New-CommMonitorTestProbeRecord {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Collections.IDictionary] $Overrides = @{},
        [Parameter(Mandatory)][scriptblock] $FileIdBuilder,
        [Parameter(Mandatory)][scriptblock] $AclBuilder
    )

    $parent = Split-Path -Parent $Path
    $values = [ordered]@{
        Provider = 'FileSystem'
        VolumeKind = 'Fixed'
        VolumeSerialNumber = '0011223344556677'
        RequestedPath = $Path
        FinalPath = $Path
        Exists = $true
        IsDirectory = $true
        IsEmpty = $true
        IsReparse = $false
        FileId = & $FileIdBuilder -Identity $Path
        ExistingParentFileId = $null
        AclProfile = & $AclBuilder
        InstallIdMarker = $null
    }
    foreach ($key in @($Overrides.Keys)) {
        $values[$key] = $Overrides[$key]
    }

    if (-not $values.Exists -and -not $Overrides.Contains('FinalPath')) {
        $values.FinalPath = $null
    }
    if (-not $values.Exists -and -not $Overrides.Contains('FileId')) {
        $values.FileId = $null
    }
    if (-not $values.Exists -and -not $Overrides.Contains('ExistingParentFileId')) {
        $values.ExistingParentFileId = & $FileIdBuilder -Identity $parent
    }

    $nearestRequestedPath = if ($values.Exists) {
        [string]$values.RequestedPath
    }
    else {
        Split-Path -Parent ([string]$values.RequestedPath)
    }
    $nearestFinalPath = if ($values.Exists) {
        [string]$values.FinalPath
    }
    else {
        $nearestRequestedPath
    }
    $nearestFileId = if ($values.Exists) {
        [string]$values.FileId
    }
    else {
        [string]$values.ExistingParentFileId
    }
    $unresolvedSuffix = if ($values.Exists) {
        ''
    }
    else {
        Split-Path -Leaf ([string]$values.RequestedPath)
    }

    if ($Overrides.Contains('NearestExistingAncestor')) {
        $nearest = $Overrides.NearestExistingAncestor
    }
    else {
        $nearest = [pscustomobject][ordered]@{
            RequestedPath = $nearestRequestedPath
            FinalPath = $nearestFinalPath
            VolumeSerial = [string]$values.VolumeSerialNumber
            FileId = $nearestFileId
        }
    }
    if ($Overrides.Contains('UnresolvedSuffix')) {
        $unresolvedSuffix = $Overrides.UnresolvedSuffix
    }

    if ($Overrides.Contains('Ancestors')) {
        $ancestors = $Overrides.Ancestors
    }
    else {
        $volumeRoot = [IO.Path]::GetPathRoot($nearestRequestedPath)
        $relative = $nearestRequestedPath.Substring($volumeRoot.Length)
        $requestedAncestors = [Collections.Generic.List[string]]::new()
        $requestedAncestors.Add($volumeRoot)
        $cursor = $volumeRoot.TrimEnd('\')
        foreach ($segment in @($relative -split '\\')) {
            if ([string]::IsNullOrEmpty($segment)) { continue }
            $cursor = $cursor + '\' + $segment
            $requestedAncestors.Add($cursor)
        }
        $ancestors = @(
            for ($index = 0; $index -lt $requestedAncestors.Count; $index++) {
                $requestedAncestor = $requestedAncestors[$index]
                $isNearest = $index -eq ($requestedAncestors.Count - 1)
                $finalAncestor = if ($isNearest) {
                    [string]$nearest.FinalPath
                }
                else {
                    $requestedAncestor
                }
                [pscustomobject][ordered]@{
                    RequestedPath = $requestedAncestor
                    FinalPath = $finalAncestor
                    VolumeSerial = [string]$values.VolumeSerialNumber
                    FileId = if ($isNearest) {
                        [string]$nearest.FileId
                    }
                    else {
                        & $FileIdBuilder -Identity $finalAncestor
                    }
                    ReparseTag = 0
                }
            })
    }

    return [pscustomobject][ordered]@{
        Provider = $values.Provider
        VolumeKind = $values.VolumeKind
        VolumeSerialNumber = $values.VolumeSerialNumber
        RequestedPath = $values.RequestedPath
        FinalPath = $values.FinalPath
        Exists = $values.Exists
        IsDirectory = $values.IsDirectory
        IsEmpty = $values.IsEmpty
        IsReparse = $values.IsReparse
        FileId = $values.FileId
        ExistingParentFileId = $values.ExistingParentFileId
        AclProfile = $values.AclProfile
        InstallIdMarker = $values.InstallIdMarker
        NearestExistingAncestor = $nearest
        UnresolvedSuffix = $unresolvedSuffix
        Ancestors = $ancestors
    }
}

function New-CommMonitorTestPathProbe {
    param([Collections.IDictionary] $Overrides = @{})

    $capturedOverrides = $Overrides
    $capturedProbeBuilder = ${function:New-CommMonitorTestProbeRecord}
    $capturedFileIdBuilder = ${function:Get-CommMonitorTestFileId}
    $capturedAclBuilder = ${function:New-CommMonitorTestProtectedAclProfile}
    return {
        param([string] $Path, [int] $Pass)

        $values = @{}
        if ($capturedOverrides.Contains($Path)) {
            $override = $capturedOverrides[$Path]
            $override = if ($override -is [scriptblock]) {
                & $override $Path $Pass
            }
            else {
                $override
            }
            foreach ($property in @($override.PSObject.Properties)) {
                $values[$property.Name] = $property.Value
            }
        }
        return & $capturedProbeBuilder `
            -Path $Path `
            -Overrides $values `
            -FileIdBuilder $capturedFileIdBuilder `
            -AclBuilder $capturedAclBuilder
    }.GetNewClosure()
}

function New-CommMonitorRegisteredTestProbeCapability {
    param(
        [Parameter(Mandatory)][scriptblock] $InteractiveSessionProbe,
        [Parameter(Mandatory)][object[]] $ProfileListRecords,
        [Parameter(Mandatory)][scriptblock] $KnownFolderProbe,
        [scriptblock] $PathProbe = (New-CommMonitorTestPathProbe),
        [scriptblock] $ProfilePathExpansionProbe = {
            param($AuthorizedUserSid, $RawProfileImagePath)
            [pscustomobject][ordered]@{
                Source = 'ExpandEnvironmentStringsForUserW'
                Sid = $AuthorizedUserSid
                RawValue = $RawProfileImagePath
                Path = $RawProfileImagePath
                IdentityVerified = $true
            }
        },
        [scriptblock] $LegacyMarkerProbe = {
            throw 'No TestOnly legacy-marker probe was registered.'
        }
    )

    $capturedRecords = $ProfileListRecords
    $capturedSessionProbe = $InteractiveSessionProbe
    $capturedKnownFolderProbe = $KnownFolderProbe
    $capturedPathProbe = $PathProbe
    $capturedProfilePathExpansionProbe = $ProfilePathExpansionProbe
    $capturedLegacyMarkerProbe = $LegacyMarkerProbe
    $sessionProbe = {
        & $capturedSessionProbe
    }.GetNewClosure()
    $profileListProbe = {
        param($AuthorizedUserSid)
        return $capturedRecords
    }.GetNewClosure()
    $profilePathExpansionProbeAdapter = {
        param($AuthorizedUserSid, $RawProfileImagePath)
        & $capturedProfilePathExpansionProbe `
            $AuthorizedUserSid `
            $RawProfileImagePath
    }.GetNewClosure()
    $knownFolderProbeAdapter = {
        param($AuthorizedUserSid, $KnownFolder)
        & $capturedKnownFolderProbe $AuthorizedUserSid $KnownFolder
    }.GetNewClosure()
    $pathProbeAdapter = {
        param($Path, $Pass)
        & $capturedPathProbe $Path $Pass
    }.GetNewClosure()
    $legacyMarkerProbeAdapter = {
        param($ExpectedDataRootPath)
        & $capturedLegacyMarkerProbe $ExpectedDataRootPath
    }.GetNewClosure()
    Mock `
        -CommandName Invoke-CommMonitorWindowsInteractiveSessionProbe `
        -ModuleName CommMonitor.InstallHelpers `
        -MockWith $sessionProbe
    Mock `
        -CommandName Invoke-CommMonitorWindowsProfileListProbe `
        -ModuleName CommMonitor.InstallHelpers `
        -MockWith $profileListProbe
    Mock `
        -CommandName Invoke-CommMonitorWindowsProfilePathExpansionProbe `
        -ModuleName CommMonitor.InstallHelpers `
        -MockWith $profilePathExpansionProbeAdapter
    Mock `
        -CommandName Invoke-CommMonitorWindowsKnownFolderProbe `
        -ModuleName CommMonitor.InstallHelpers `
        -MockWith $knownFolderProbeAdapter
    Mock `
        -CommandName Invoke-CommMonitorWindowsPathProbe `
        -ModuleName CommMonitor.InstallHelpers `
        -MockWith $pathProbeAdapter
    Mock `
        -CommandName Invoke-CommMonitorWindowsLegacyMarkerProbe `
        -ModuleName CommMonitor.InstallHelpers `
        -MockWith $legacyMarkerProbeAdapter
    return New-CommMonitorWindowsOwnershipProbeCapability
}

function Resolve-CommMonitorAuthorizedUserForTest {
    param(
        [Parameter(Mandatory)][object] $AuthorizedUserSid,
        [Parameter(Mandatory)][object[]] $ProfileListRecords,
        [Parameter(Mandatory)][scriptblock] $KnownFolderProbe,
        [Parameter(Mandatory)][scriptblock] $InteractiveSessionProbe,
        [Parameter(Mandatory)][object] $AiRelativePath,
        [scriptblock] $PathProbe = (New-CommMonitorTestPathProbe),
        [scriptblock] $ProfilePathExpansionProbe = {
            param($AuthorizedUserSid, $RawProfileImagePath)
            [pscustomobject][ordered]@{
                Source = 'ExpandEnvironmentStringsForUserW'
                Sid = $AuthorizedUserSid
                RawValue = $RawProfileImagePath
                Path = $RawProfileImagePath
                IdentityVerified = $true
            }
        },
        [scriptblock] $LegacyMarkerProbe = {
            throw 'No TestOnly legacy-marker probe was registered.'
        }
    )

    $capability = New-CommMonitorRegisteredTestProbeCapability `
        -InteractiveSessionProbe $InteractiveSessionProbe `
        -ProfileListRecords $ProfileListRecords `
        -KnownFolderProbe $KnownFolderProbe `
        -PathProbe $PathProbe `
        -ProfilePathExpansionProbe $ProfilePathExpansionProbe `
        -LegacyMarkerProbe $LegacyMarkerProbe
    return Resolve-CommMonitorAuthorizedUser `
        -AuthorizedUserSid $AuthorizedUserSid `
        -OwnershipProbeCapability $capability `
        -AiRelativePath $AiRelativePath
}

function Resolve-CommMonitorTestOwnershipRoots {
    param(
        [Parameter(Mandatory)][string] $PlatformKind,
        [Parameter(Mandatory)][int] $PlatformBuild,
        [Parameter(Mandatory)][string[]] $PlatformComponents,
        [AllowNull()][string] $AppRoot,
        [Parameter(Mandatory)][string] $ProgramFilesPath,
        [Parameter(Mandatory)][string] $ProgramDataPath,
        [Parameter(Mandatory)][object] $AuthorizedUserBinding,
        [Parameter(Mandatory)][scriptblock] $PathProbe,
        [string] $InstallMode = 'Fresh',
        [AllowNull()][object] $DataRootAdoptionEvidence
    )

    $capturedPathProbe = $PathProbe
    $pathProbeAdapter = {
        param($Path, $Pass)
        & $capturedPathProbe $Path $Pass
    }.GetNewClosure()
    Mock `
        -CommandName Invoke-CommMonitorWindowsPathProbe `
        -ModuleName CommMonitor.InstallHelpers `
        -MockWith $pathProbeAdapter
    return Resolve-CommMonitorOwnershipRoots `
        -PlatformKind $PlatformKind `
        -PlatformBuild $PlatformBuild `
        -PlatformComponents $PlatformComponents `
        -AppRoot $AppRoot `
        -ProgramFilesPath $ProgramFilesPath `
        -ProgramDataPath $ProgramDataPath `
        -AuthorizedUserBinding $AuthorizedUserBinding `
        -InstallMode $InstallMode `
        -DataRootAdoptionEvidence $DataRootAdoptionEvidence
}

function New-CommMonitorTestDesktopOwnedObjects {
    return @(
        (New-CommMonitorOwnedObject -Definition ([ordered]@{
            objectId = 'desktop-exe'
            type = 'ImmutableFile'
            component = 'DesktopExecutable'
            root = 'AppRoot'
            relativePath = 'CommMonitor.App.exe'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{
                size = 1
                sha256 = ('a' * 64)
                productMarker = 'CommMonitor:0.1.0'
            }
        })),
        (New-CommMonitorOwnedObject -Definition ([ordered]@{
            objectId = 'ai-cli'
            type = 'ImmutableFile'
            component = 'AiCli'
            root = 'AppRoot'
            relativePath = 'ai\CommMonitor.AI.exe'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{
                size = 1
                sha256 = ('b' * 64)
                productMarker = 'CommMonitor:0.1.0'
            }
        })),
        (New-CommMonitorOwnedObject -Definition ([ordered]@{
            objectId = 'start-menu'
            type = 'Shortcut'
            component = 'StartMenuShortcut'
            root = 'StartMenu'
            relativePath = 'Lemon串口监控.lnk'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 10
            identity = [ordered]@{
                target = 'C:\Program Files\Lemon串口监控\CommMonitor.App.exe'
                arguments = ''
                workingDirectory = 'C:\Program Files\Lemon串口监控'
                fileSha256 = ('c' * 64)
                created = $true
            }
        })),
        (New-CommMonitorOwnedObject -Definition ([ordered]@{
            objectId = 'app-root-directory'
            type = 'Directory'
            component = 'RootDirectory'
            root = 'AppRoot'
            relativePath = ''
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 90
            contentPolicy = 'EmptyAfterOwnedChildren'
            identity = [ordered]@{ created = $true }
        })),
        (New-CommMonitorOwnedObject -Definition ([ordered]@{
            objectId = 'core-root-directory'
            type = 'Directory'
            component = 'RootDirectory'
            root = 'CoreRoot'
            relativePath = ''
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 90
            contentPolicy = 'EmptyAfterOwnedChildren'
            identity = [ordered]@{ created = $true }
        }))
    )
}

function New-CommMonitorTestOwnershipRootRecord {
    param(
        [Parameter(Mandatory)][string] $Role,
        [Parameter(Mandatory)][string] $CanonicalPath,
        [string] $ContentPolicy = 'EmptyAfterOwnedChildren'
    )

    return [ordered]@{
        Role = $Role
        CanonicalPath = $CanonicalPath
        Active = $true
        Present = $true
        CreatedByInstall = $true
        VolumeSerialNumber = '0011223344556677'
        FileId = ('b' * 32)
        AclProfile = New-CommMonitorTestProtectedAclProfile
        PhysicalCandidatePath = $CanonicalPath
        OwnershipProof = 'CreatedThisInstall'
        AdoptionSource = $null
        ContentPolicy = $ContentPolicy
    }
}

function New-CommMonitorTestOwnershipRoots {
    $roots = [ordered]@{
        AppRoot = New-CommMonitorTestOwnershipRootRecord `
            -Role AppRoot `
            -CanonicalPath 'C:\Program Files\Lemon串口监控'
        CoreRoot = New-CommMonitorTestOwnershipRootRecord `
            -Role CoreRoot `
            -CanonicalPath 'C:\Program Files\CommMonitor'
        DataRoot = New-CommMonitorTestOwnershipRootRecord `
            -Role DataRoot `
            -CanonicalPath 'C:\ProgramData\CommMonitor' `
            -ContentPolicy ProtectedManagedTree
        InstallerRoot = New-CommMonitorTestOwnershipRootRecord `
            -Role InstallerRoot `
            -CanonicalPath 'C:\ProgramData\LemonSerialMonitor\Installer'
        AiStateRoot = New-CommMonitorTestOwnershipRootRecord `
            -Role AiStateRoot `
            -CanonicalPath 'C:\Users\测试 用户\AppData\Local\LemonSerialMonitor\AI'
    }
    $roots.AiStateRoot.AclProfile.AllowedFullControlSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-21-111-222-333-1001')
    return $roots
}

function New-CommMonitorTestManifestAuthorizedUser {
    return [ordered]@{
        Sid = 'S-1-5-21-111-222-333-1001'
        ProfileListKeyPath =
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\S-1-5-21-111-222-333-1001'
        ProfileImagePathRaw = 'C:\Users\测试 用户'
        ProfileImagePathValueKind = 'String'
        ProfileExpansionSource = 'ExpandEnvironmentStringsForUserW'
        ProfileExpansionSid = 'S-1-5-21-111-222-333-1001'
        ProfileImagePath = 'C:\Users\测试 用户'
        KnownFolderId = '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}'
        KnownFolderSid = 'S-1-5-21-111-222-333-1001'
        LocalAppDataPath = 'C:\Users\测试 用户\AppData\Local'
        AiRoot = 'C:\Users\测试 用户\AppData\Local\LemonSerialMonitor\AI'
    }
}

function New-CommMonitorTestManifestAclProfile {
    return [ordered]@{
        ownerSid = 'S-1-5-18'
        areAccessRulesProtected = $true
        allowedFullControlSids = @('S-1-5-18', 'S-1-5-32-544')
        denyRuleCount = 0
        usersWritable = $false
    }
}

function New-CommMonitorTestLegacyAdoptionSource {
    return [ordered]@{
        schemaVersion = 1
        sourceKind = 'ValidatedLegacyMarker'
        capabilityId = '11111111-1111-1111-1111-111111111111'
        providerEpoch = '22222222-2222-2222-2222-222222222222'
        markerId = '33333333-3333-3333-3333-333333333333'
        markerDigest = ('a' * 64)
        canonicalPath = 'C:\ProgramData\CommMonitor'
        volumeSerialNumber = '0011223344556677'
        fileId = ('b' * 32)
        aclProfile = New-CommMonitorTestManifestAclProfile
        ownershipProof = 'VerifiedLegacyAdoption'
    }
}

function New-CommMonitorTestManifestAdoptionSource {
    return [ordered]@{
        schemaVersion = 1
        sourceKind = 'AuthenticatedManifestV3'
        sourceInstallId = '33333333-3333-3333-3333-333333333333'
        sourcePayloadSha256 = ('c' * 64)
        canonicalPath = 'C:\ProgramData\CommMonitor'
        volumeSerialNumber = '0011223344556677'
        fileId = ('b' * 32)
        aclProfile = New-CommMonitorTestManifestAclProfile
        ownershipProof = 'VerifiedLegacyAdoption'
    }
}

function New-CommMonitorTestOwnershipPayloadArguments {
    return @{
        AppId = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA'
        InstallId = 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB'
        Revision = 1
        ProductVersion = '0.1.0'
        CreatedUtc = [DateTimeOffset]::Parse('2026-07-14T01:02:03Z')
        Platform = [ordered]@{
            kind = 'Desktop'
            build = 22631
            components = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
        }
        Roots = New-CommMonitorTestOwnershipRoots
        AuthorizedUser = New-CommMonitorTestManifestAuthorizedUser
        OwnedObjects = New-CommMonitorTestDesktopOwnedObjects
        UpperFiltersRollback = [ordered]@{ present = $false; value = $null }
        KeyMetadata = [ordered]@{
            manifest = [ordered]@{ state = 'Active'; keyId = ('d' * 64) }
        }
    }
}

function New-CommMonitorTestInactiveAppRootRecord {
    return [ordered]@{
        Role = 'AppRoot'
        CanonicalPath = 'C:\Program Files\Lemon串口监控'
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
}

function New-CommMonitorTestServerCoreOwnedObjects {
    return ,([object[]]@(
        (New-CommMonitorOwnedObject -Definition ([ordered]@{
            objectId = 'headless-exe'
            type = 'ImmutableFile'
            component = 'Headless'
            root = 'CoreRoot'
            relativePath = 'CommMonitor.Headless.exe'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{
                size = 1
                sha256 = ('a' * 64)
                productMarker = 'CommMonitor:0.1.0'
            }
        })),
        (New-CommMonitorOwnedObject -Definition ([ordered]@{
            objectId = 'server-core-ai-cli'
            type = 'ImmutableFile'
            component = 'AiCli'
            root = 'CoreRoot'
            relativePath = 'ai\CommMonitor.AI.exe'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{
                size = 1
                sha256 = ('b' * 64)
                productMarker = 'CommMonitor:0.1.0'
            }
        })),
        (New-CommMonitorOwnedObject -Definition ([ordered]@{
            objectId = 'core-root-directory'
            type = 'Directory'
            component = 'RootDirectory'
            root = 'CoreRoot'
            relativePath = ''
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 90
            contentPolicy = 'EmptyAfterOwnedChildren'
            identity = [ordered]@{ created = $true }
        }))))
}

function New-CommMonitorTestOwnershipPayloadForPlatform {
    param(
        [ValidateSet('Desktop', 'ServerDesktop', 'ServerCore')]
        [string] $PlatformKind = 'Desktop',

        [ValidateSet('Created', 'PreExistingCore', 'VerifiedData')]
        [string] $RootMode = 'Created'
    )

    $arguments = New-CommMonitorTestOwnershipPayloadArguments
    switch ($PlatformKind) {
        'ServerDesktop' {
            $arguments.Platform.kind = 'ServerDesktop'
            $arguments.Platform.build = 20348
        }
        'ServerCore' {
            $arguments.Platform = [ordered]@{
                kind = 'ServerCore'
                build = 20348
                components = @('Headless', 'Service', 'Driver', 'AI')
            }
            $arguments.Roots.AppRoot = New-CommMonitorTestInactiveAppRootRecord
            $arguments.OwnedObjects = New-CommMonitorTestServerCoreOwnedObjects
        }
    }

    switch ($RootMode) {
        'PreExistingCore' {
            $arguments.Roots.CoreRoot.CreatedByInstall = $false
            $arguments.Roots.CoreRoot.OwnershipProof = 'PreExistingShared'
            $coreDirectory = @(
                $arguments.OwnedObjects |
                    Where-Object objectId -eq 'core-root-directory')[0]
            $coreDirectory.ownershipProof = 'PreExistingShared'
            $coreDirectory.removeOnUninstall = $false
            $coreDirectory.identity.created = $false
        }
        'VerifiedData' {
            $arguments.Roots.DataRoot.CreatedByInstall = $false
            $arguments.Roots.DataRoot.OwnershipProof = 'VerifiedLegacyAdoption'
            $arguments.Roots.DataRoot.AdoptionSource =
                New-CommMonitorTestLegacyAdoptionSource
        }
    }

    return New-CommMonitorOwnershipPayload @arguments
}

function Add-CommMonitorTestContinuationMetadataObject {
    param([Parameter(Mandatory)][object] $Payload)

    $ownedObject = [ordered]@{
        objectId = 'continuation-metadata-i5a'
        type = 'ContinuationMetadata'
        component = 'Continuation'
        root = 'InstallerRoot'
        ownershipProof = 'CreatedThisInstall'
        removeOnUninstall = $true
        deletePhase = 97
        identity = [ordered]@{
            relativePath = 'state\continuation-i5a.v1.json'
            pendingObjectIds = @('desktop-exe')
            helperSha256 = ('2' * 64)
            finalizerSha256 = ('3' * 64)
        }
    }
    $Payload.ownedObjects = [object[]]@($Payload.ownedObjects + $ownedObject)
    return $ownedObject
}

function Add-CommMonitorTestRegistryValueObject {
    param(
        [Parameter(Mandatory)][object] $Payload,
        [AllowNull()][object] $Value
    )

    $ownedObject = [ordered]@{
        objectId = 'registry-value-i5a'
        type = 'RegistryValue'
        component = 'Uninstall'
        root = 'Registry'
        ownershipProof = 'CreatedThisInstall'
        removeOnUninstall = $true
        deletePhase = 40
        identity = [ordered]@{
            hive = 'HKLM'
            view = 'Registry64'
            key = 'Software\LemonSerialMonitor'
            name = 'I5AValue'
            kind = 'String'
            value = $Value
            created = $true
        }
    }
    $Payload.ownedObjects = [object[]]@($Payload.ownedObjects + $ownedObject)
    return $ownedObject
}

function New-CommMonitorTestOwnedSemanticDefinition {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'ImmutableFile', 'DynamicFile', 'Directory', 'Shortcut',
            'RegistryValue', 'RegistryKey', 'Service', 'DriverPackage',
            'Certificate', 'EventSource', 'ScheduledTask', 'FilterMetadata',
            'KeyMetadata', 'ContinuationMetadata')]
        [string] $Type
    )

    switch ($Type) {
        'ImmutableFile' {
            return [ordered]@{
                objectId = 'semantic-immutable'
                type = 'ImmutableFile'
                component = 'Service'
                root = 'CoreRoot'
                relativePath = 'semantic\service.exe'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 20
                identity = [ordered]@{
                    size = [long]7
                    sha256 = ('4' * 64)
                    productMarker = 'CommMonitor:0.1.0'
                }
            }
        }
        'DynamicFile' {
            return [ordered]@{
                objectId = 'semantic-dynamic'
                type = 'DynamicFile'
                component = 'AiState'
                root = 'AiStateRoot'
                relativePath = 'state\semantic.json'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 21
                identity = [ordered]@{}
            }
        }
        'Directory' {
            return [ordered]@{
                objectId = 'semantic-directory'
                type = 'Directory'
                component = 'Data'
                root = 'DataRoot'
                relativePath = ''
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 90
                contentPolicy = 'ProtectedManagedTree'
                identity = [ordered]@{ created = $true }
            }
        }
        'Shortcut' {
            return [ordered]@{
                objectId = 'semantic-shortcut'
                type = 'Shortcut'
                component = 'StartMenuShortcut'
                root = 'StartMenu'
                relativePath = 'Lemon串口监控-语义.lnk'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 10
                identity = [ordered]@{
                    target = 'C:\Program Files\Lemon串口监控\CommMonitor.App.exe'
                    arguments = ''
                    workingDirectory = 'C:\Program Files\Lemon串口监控'
                    fileSha256 = ('5' * 64)
                    created = $true
                }
            }
        }
        'RegistryValue' {
            return [ordered]@{
                objectId = 'semantic-registry-value'
                type = 'RegistryValue'
                component = 'Uninstall'
                root = 'Registry'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 40
                identity = [ordered]@{
                    hive = 'HKLM'
                    view = 'Registry64'
                    key = 'Software\LemonSerialMonitor\Semantic'
                    name = 'Value'
                    kind = 'String'
                    value = 'data'
                    created = $true
                }
            }
        }
        'RegistryKey' {
            return [ordered]@{
                objectId = 'semantic-registry-key'
                type = 'RegistryKey'
                component = 'Uninstall'
                root = 'Registry'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 41
                identity = [ordered]@{
                    hive = 'HKLM'
                    view = 'Registry64'
                    key = 'Software\LemonSerialMonitor\Semantic'
                    created = $true
                }
            }
        }
        'Service' {
            return [ordered]@{
                objectId = 'semantic-service'
                type = 'Service'
                component = 'Service'
                root = 'System'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 50
                identity = [ordered]@{
                    name = 'CommMonitorService'
                    serviceType = 'Win32OwnProcess'
                    imagePath = 'C:\Program Files\CommMonitor\service\CommMonitor.Service.exe'
                    arguments = '--service'
                    accountSid = 'S-1-5-18'
                    creationProof = 'CreatedThisInstall'
                }
            }
        }
        'DriverPackage' {
            return [ordered]@{
                objectId = 'semantic-driver-package'
                type = 'DriverPackage'
                component = 'Driver'
                root = 'System'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 60
                identity = [ordered]@{
                    publishedName = 'oem42.inf'
                    originalInfPath = 'C:\Windows\INF\CommMonitor.Driver.inf'
                    originalInfSha256 = ('6' * 64)
                    creationProof = 'CreatedThisInstall'
                }
            }
        }
        'Certificate' {
            return [ordered]@{
                objectId = 'semantic-certificate'
                type = 'Certificate'
                component = 'Driver'
                root = 'System'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 70
                identity = [ordered]@{
                    store = 'LocalMachine\TrustedPublisher'
                    thumbprint = ('7' * 40)
                    derSha256 = ('8' * 64)
                    added = $true
                }
            }
        }
        'EventSource' {
            return [ordered]@{
                objectId = 'semantic-event-source'
                type = 'EventSource'
                component = 'Service'
                root = 'System'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 45
                identity = [ordered]@{
                    log = 'Application'
                    source = 'CommMonitorService'
                    registrationPath =
                        'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\CommMonitorService'
                    messageFile =
                        'C:\Program Files\CommMonitor\service\CommMonitor.Service.exe'
                    creationProof = 'CreatedThisInstall'
                }
            }
        }
        'ScheduledTask' {
            return [ordered]@{
                objectId = 'semantic-scheduled-task'
                type = 'ScheduledTask'
                component = 'Continuation'
                root = 'System'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 95
                identity = [ordered]@{
                    name = 'LemonSerialMonitor-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                    identitySid = 'S-1-5-18'
                    trigger = 'AtStartup'
                    finalizerPath =
                        'C:\ProgramData\LemonSerialMonitor\Installer\finalizer.exe'
                    arguments = '--continue'
                    xmlSha256 = ('9' * 64)
                }
            }
        }
        'FilterMetadata' {
            return [ordered]@{
                objectId = 'semantic-filter'
                type = 'FilterMetadata'
                component = 'Driver'
                root = 'Registry'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 65
                identity = [ordered]@{
                    classKey = '{4D36E978-E325-11CE-BFC1-08002BE10318}'
                    valueName = 'UpperFilters'
                    entry = 'CommMonitorFilter'
                    added = $true
                }
            }
        }
        'KeyMetadata' {
            return [ordered]@{
                objectId = 'semantic-key-metadata'
                type = 'KeyMetadata'
                component = 'Uninstall'
                root = 'InstallerRoot'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 96
                identity = [ordered]@{
                    kind = 'ManifestHmacKey'
                    state = 'Active'
                    relativePath = 'state\manifest.key.v1.json'
                    keyId = ('a' * 64)
                }
            }
        }
        'ContinuationMetadata' {
            return [ordered]@{
                objectId = 'semantic-continuation-metadata'
                type = 'ContinuationMetadata'
                component = 'Continuation'
                root = 'InstallerRoot'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 97
                identity = [ordered]@{
                    relativePath = 'state\continuation.v1.json'
                    pendingObjectIds = [string[]]@('desktop-exe')
                    helperSha256 = ('b' * 64)
                    finalizerSha256 = ('c' * 64)
                }
            }
        }
    }
}

function Add-CommMonitorTestOwnedSemanticDefinition {
    param(
        [Parameter(Mandatory)][object] $Payload,
        [Parameter(Mandatory)][object] $Definition
    )

    $Payload.ownedObjects = [object[]]@($Payload.ownedObjects + $Definition)
}

function Add-CommMonitorTestRegistrySemanticBundle {
    param([Parameter(Mandatory)][object] $Payload)

    $valueObject = New-CommMonitorTestOwnedSemanticDefinition -Type RegistryValue
    $keyObject = New-CommMonitorTestOwnedSemanticDefinition -Type RegistryKey
    $Payload.ownedObjects = [object[]]@(
        $Payload.ownedObjects + $valueObject + $keyObject)
    return [pscustomobject]@{
        ValueObject = $valueObject
        KeyObject = $keyObject
    }
}

function Add-CommMonitorTestServiceSemanticBundle {
    param([Parameter(Mandatory)][object] $Payload)

    $binaryObject = New-CommMonitorTestOwnedSemanticDefinition -Type ImmutableFile
    $binaryObject.objectId = 'semantic-service-binary'
    $binaryObject.component = 'Service'
    $binaryObject.relativePath = 'service\CommMonitor.Service.exe'
    $serviceObject = New-CommMonitorTestOwnedSemanticDefinition -Type Service
    $eventObject = New-CommMonitorTestOwnedSemanticDefinition -Type EventSource
    $Payload.ownedObjects = [object[]]@(
        $Payload.ownedObjects + $binaryObject + $serviceObject + $eventObject)
    return [pscustomobject]@{
        BinaryObject = $binaryObject
        ServiceObject = $serviceObject
        EventObject = $eventObject
    }
}

function Add-CommMonitorTestContinuationSemanticBundle {
    param([Parameter(Mandatory)][object] $Payload)

    $helperObject = New-CommMonitorTestOwnedSemanticDefinition -Type ImmutableFile
    $helperObject.objectId = 'semantic-continuation-helper'
    $helperObject.component = 'Uninstall'
    $helperObject.root = 'InstallerRoot'
    $helperObject.relativePath = 'helper.exe'
    $helperObject.identity.sha256 = ('b' * 64)

    $finalizerObject = New-CommMonitorTestOwnedSemanticDefinition -Type ImmutableFile
    $finalizerObject.objectId = 'semantic-continuation-finalizer'
    $finalizerObject.component = 'Uninstall'
    $finalizerObject.root = 'InstallerRoot'
    $finalizerObject.relativePath = 'finalizer.exe'
    $finalizerObject.identity.sha256 = ('c' * 64)

    $taskObject = New-CommMonitorTestOwnedSemanticDefinition -Type ScheduledTask
    $metadataObject =
        New-CommMonitorTestOwnedSemanticDefinition -Type ContinuationMetadata
    $Payload.ownedObjects = [object[]]@(
        $Payload.ownedObjects +
        $helperObject +
        $finalizerObject +
        $taskObject +
        $metadataObject)
    return [pscustomobject]@{
        HelperObject = $helperObject
        FinalizerObject = $finalizerObject
        TaskObject = $taskObject
        MetadataObject = $metadataObject
    }
}

function Add-CommMonitorTestKeyMetadataSemanticObject {
    param([Parameter(Mandatory)][object] $Payload)

    $keyObject = New-CommMonitorTestOwnedSemanticDefinition -Type KeyMetadata
    $keyObject.identity.keyId = ('d' * 64)
    $Payload.ownedObjects = [object[]]@($Payload.ownedObjects + $keyObject)
    return $keyObject
}

function New-CommMonitorTestCanonicalFixtureMaterial {
    $key = [byte[]](0..31)
    $keyId = Get-CommMonitorSha256Hex -Bytes $key
    $arguments = New-CommMonitorTestOwnershipPayloadArguments
    $payload = New-CommMonitorOwnershipPayload @arguments
    $manifest = New-CommMonitorOwnershipManifest `
        -Payload $payload `
        -Key $key `
        -KeyId $keyId `
        -ActiveSlot A
    $envelope = $manifest.slots.A
    $anchor = New-CommMonitorOwnershipAnchor `
        -Payload $payload `
        -PayloadSha256 $envelope.integrity.payloadSha256 `
        -ManifestPath (
            'C:\ProgramData\LemonSerialMonitor\Installer\state\' +
            'ownership-manifest.v3.json') `
        -Key $key `
        -KeyId $keyId
    return [pscustomobject]@{
        Key = $key
        KeyId = $keyId
        Payload = $payload
        Manifest = $manifest
        Envelope = $envelope
        Anchor = $anchor
        PayloadBytes = Get-CommMonitorCanonicalJsonBytes -InputObject $payload
        AnchorBindingBytes = Get-CommMonitorCanonicalJsonBytes `
            -InputObject $anchor.binding
        ManifestDiskBytes = Get-CommMonitorCanonicalStateFileBytes `
            -InputObject $manifest
        AnchorDiskBytes = Get-CommMonitorCanonicalStateFileBytes `
            -InputObject $anchor
    }
}

function New-CommMonitorTestRequestedOperationState {
    param(
        [string] $OperationId =
            '11111111-1111-1111-1111-111111111111',
        [string] $Nonce = ('1' * 64),
        [string] $HelperSha256 = ('2' * 64),
        [string[]] $PendingObjectIds =
            ([string[]]@('desktop-exe')),
        [string] $RequestedUtc = '2026-07-14T02:03:04.0000000Z'
    )

    return [ordered]@{
        operationId = $OperationId
        nonce = $Nonce
        resultRelativePath =
            "state\results\$OperationId.v1.json"
        helperSha256 = $HelperSha256
        pendingObjectIds = [string[]]@($PendingObjectIds)
        requestedUtc = $RequestedUtc
    }
}

function New-CommMonitorTestPreparedTarget {
    param([string] $ObjectId = 'semantic-dynamic')

    return [ordered]@{
        objectId = $ObjectId
        volumeSerialNumber = '0011223344556677'
        fileId = ('3' * 32)
        size = [long]7
        sha256 = ('4' * 64)
    }
}

function Add-CommMonitorTestDynamicOperationObject {
    param([Parameter(Mandatory)][object] $Payload)

    $dynamicObject =
        New-CommMonitorTestOwnedSemanticDefinition -Type DynamicFile
    Add-CommMonitorTestOwnedSemanticDefinition `
        -Payload $Payload `
        -Definition $dynamicObject
    return $dynamicObject
}

function New-CommMonitorTestOperationPayloadForState {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'Committed', 'UninstallRequested', 'UninstallPrepared',
            'PendingReboot', 'Abandoned', 'FinalizingAbsent')]
        [string] $State,
        [string] $OperationId =
            '11111111-1111-1111-1111-111111111111',
        [string] $Nonce = ('1' * 64),
        [string] $HelperSha256 = ('2' * 64),
        [string] $RequestedUtc = '2026-07-14T02:03:04.0000000Z',
        [switch] $AbandonedWithoutPreparation,
        [switch] $ActiveContinuation
    )

    $arguments = New-CommMonitorTestOwnershipPayloadArguments
    [void](Add-CommMonitorTestDynamicOperationObject -Payload $arguments)
    $arguments.State = $State
    $operation = New-CommMonitorTestRequestedOperationState `
        -OperationId $OperationId `
        -Nonce $Nonce `
        -HelperSha256 $HelperSha256 `
        -PendingObjectIds ([string[]]@('semantic-dynamic')) `
        -RequestedUtc $RequestedUtc
    switch -CaseSensitive ($State) {
        'Committed' {
            $arguments.OperationState = [ordered]@{}
        }
        'UninstallRequested' {
            $arguments.OperationState = $operation
        }
        'UninstallPrepared' {
            $operation['preparedTargets'] = [object[]]@(
                (New-CommMonitorTestPreparedTarget))
            $operation['preparedUtc'] = '2026-07-14T02:04:04.0000000Z'
            $arguments.OperationState = $operation
        }
        'PendingReboot' {
            $arguments.ContinuationState = [ordered]@{ status = 'Active' }
            $operation['preparedTargets'] = [object[]]@(
                (New-CommMonitorTestPreparedTarget))
            $operation['preparedUtc'] = '2026-07-14T02:04:04.0000000Z'
            $operation['pendingRebootUtc'] =
                '2026-07-14T02:06:04.0000000Z'
            $arguments.OperationState = $operation
        }
        'Abandoned' {
            if ($AbandonedWithoutPreparation) {
                $operation['preparedTargets'] = [object[]]@()
                $operation['preparedUtc'] = $null
            }
            else {
                $operation['preparedTargets'] = [object[]]@(
                    (New-CommMonitorTestPreparedTarget))
                $operation['preparedUtc'] =
                    '2026-07-14T02:04:04.0000000Z'
            }
            $operation['abandonedReason'] = 'HelperExited'
            $operation['abandonedUtc'] =
                '2026-07-14T02:05:04.0000000Z'
            $arguments.OperationState = $operation
        }
        'FinalizingAbsent' {
            $arguments.OperationState = [ordered]@{
                operationId = $OperationId
                terminalCleanupId =
                    '22222222-2222-2222-2222-222222222222'
                terminalKeyId = ('5' * 64)
                terminalEnvelopeSha256 = ('6' * 64)
                finalizingUtc = '2026-07-14T02:07:04.0000000Z'
            }
        }
    }
    if ($ActiveContinuation) {
        $arguments.ContinuationState = [ordered]@{ status = 'Active' }
    }
    return New-CommMonitorOwnershipPayload @arguments
}

function New-CommMonitorTestManifestTransitionContext {
    param([Parameter(Mandatory)][object] $CurrentPayload)

    $key = [byte[]](0..31)
    $keyId = Get-CommMonitorSha256Hex -Bytes $key
    $manifestPath =
        'C:\ProgramData\LemonSerialMonitor\Installer\state\ownership-manifest.v3.json'
    $manifest = New-CommMonitorOwnershipManifest `
        -Payload $CurrentPayload `
        -Key $key `
        -KeyId $keyId `
        -ActiveSlot A
    $envelope = $manifest.slots.A
    $anchor = New-CommMonitorOwnershipAnchor `
        -Payload $CurrentPayload `
        -PayloadSha256 $envelope.integrity.payloadSha256 `
        -ManifestPath $manifestPath `
        -Key $key `
        -KeyId $keyId `
        -ActiveSlot A
    return [pscustomobject]@{
        Key = $key
        KeyId = $keyId
        ManifestPath = $manifestPath
        Manifest = $manifest
        Envelope = $envelope
        Anchor = $anchor
    }
}

function Invoke-CommMonitorTestManifestTransition {
    param(
        [Parameter(Mandatory)][object] $CurrentPayload,
        [Parameter(Mandatory)][object] $NextPayload,
        [Parameter(Mandatory)][string] $Actor
    )

    $context = New-CommMonitorTestManifestTransitionContext `
        -CurrentPayload $CurrentPayload
    return Update-CommMonitorOwnershipManifestCas `
        -CurrentManifest $context.Manifest `
        -CurrentAnchor $context.Anchor `
        -ExpectedRevision $CurrentPayload.revision `
        -ExpectedPayloadSha256 $context.Envelope.integrity.payloadSha256 `
        -NextPayload $NextPayload `
        -ManifestPath $context.ManifestPath `
        -Key $context.Key `
        -KeyId $context.KeyId `
        -Actor $Actor
}

function New-CommMonitorTestContinuationRecoveryMaterial {
    $current = New-CommMonitorTestOperationPayloadForState `
        -State PendingReboot
    $currentContext = New-CommMonitorTestManifestTransitionContext `
        -CurrentPayload $current
    $successor = New-CommMonitorTestOperationPayloadForState `
        -State UninstallRequested `
        -OperationId '33333333-3333-3333-3333-333333333333' `
        -Nonce ('7' * 64) `
        -RequestedUtc '2026-07-14T02:08:04.0000000Z' `
        -ActiveContinuation
    $successor.revision = 2
    $successor.previousPayloadSha256 =
        $currentContext.Envelope.integrity.payloadSha256
    $successorContext = New-CommMonitorTestManifestTransitionContext `
        -CurrentPayload $successor
    return [pscustomobject]@{
        Key = $currentContext.Key
        KeyId = $currentContext.KeyId
        ManifestPath = $currentContext.ManifestPath
        CurrentPayload = $current
        CurrentManifest = $currentContext.Manifest
        CurrentAnchor = $currentContext.Anchor
        CurrentPayloadSha256 =
            $currentContext.Envelope.integrity.payloadSha256
        SuccessorPayload = $successor
        SuccessorManifest = $successorContext.Manifest
        SuccessorAnchor = $successorContext.Anchor
        SuccessorPayloadSha256 =
            $successorContext.Envelope.integrity.payloadSha256
        HelperRelativePath =
            'bin\LemonSerialMonitor.UninstallHelper.exe'
        HelperSha256 = ('2' * 64)
        FinalizerRelativePath =
            'bin\LemonSerialMonitor.UninstallFinalizer.exe'
        FinalizerSha256 = ('8' * 64)
        CreatedUtc = [DateTimeOffset]::Parse(
            '2026-07-14T02:06:30.0000000Z')
    }
}

function New-CommMonitorTestContinuationEnvelopeForMaterial {
    param(
        [Parameter(Mandatory)][object] $Material,
        [Parameter(Mandatory)][ValidateSet('Active', 'Prepared')]
        [string] $Status,
        [switch] $UseSuccessor
    )

    $arguments = @{
        Status = $Status
        HelperRelativePath = $Material.HelperRelativePath
        HelperSha256 = $Material.HelperSha256
        FinalizerRelativePath = $Material.FinalizerRelativePath
        FinalizerSha256 = $Material.FinalizerSha256
        CreatedUtc = $Material.CreatedUtc
        Key = $Material.Key
        KeyId = $Material.KeyId
    }
    if ($Status -eq 'Active') {
        if ($UseSuccessor) {
            $arguments.CurrentPayload = $Material.SuccessorPayload
            $arguments.CurrentPayloadSha256 =
                $Material.SuccessorPayloadSha256
        }
        else {
            $arguments.CurrentPayload = $Material.CurrentPayload
            $arguments.CurrentPayloadSha256 =
                $Material.CurrentPayloadSha256
        }
    }
    else {
        $arguments.PredecessorPayload = $Material.CurrentPayload
        $arguments.PredecessorPayloadSha256 =
            $Material.CurrentPayloadSha256
        $arguments.SuccessorPayload = $Material.SuccessorPayload
    }
    return New-CommMonitorContinuationEnvelope @arguments
}

function Resolve-CommMonitorTestContinuationPair {
    param(
        [Parameter(Mandatory)][object] $Material,
        [Parameter(Mandatory)][object] $Continuation,
        [switch] $UseSuccessor
    )

    $manifest = if ($UseSuccessor) {
        $Material.SuccessorManifest
    }
    else {
        $Material.CurrentManifest
    }
    $anchor = if ($UseSuccessor) {
        $Material.SuccessorAnchor
    }
    else {
        $Material.CurrentAnchor
    }
    return Resolve-CommMonitorContinuationPair `
        -Manifest $manifest `
        -Anchor $anchor `
        -Continuation $Continuation `
        -Key $Material.Key `
        -ExpectedManifestPath $Material.ManifestPath `
        -ExpectedAppId $Material.CurrentPayload.appId `
        -ExpectedInstallId $Material.CurrentPayload.installId
}

function Update-CommMonitorTestContinuationIntegrity {
    param(
        [Parameter(Mandatory)][object] $Envelope,
        [Parameter(Mandatory)][byte[]] $Key
    )

    $bytes = Get-CommMonitorCanonicalJsonBytes `
        -InputObject $Envelope.payload
    $Envelope.integrity.payloadSha256 =
        Get-CommMonitorSha256Hex -Bytes $bytes
    $Envelope.integrity.tag =
        Get-CommMonitorHmacSha256Hex -Key $Key -Bytes $bytes
}

function New-CommMonitorTestTerminalCleanupMaterial {
    $current = New-CommMonitorTestOperationPayloadForState `
        -State UninstallPrepared
    $currentContext = New-CommMonitorTestManifestTransitionContext `
        -CurrentPayload $current
    $resultMaterial = [pscustomobject]@{
        Payload = $current
        PayloadSha256 = $currentContext.Envelope.integrity.payloadSha256
        Key = $currentContext.Key
        KeyId = $currentContext.KeyId
        ResultId = '77777777-7777-7777-7777-777777777777'
        HelperPid = [long]4321
        HelperCreationUtc = '2026-07-14T02:03:30.0000000Z'
        CreatedUtc = '2026-07-14T02:11:04.0000000Z'
    }
    $completedResult = New-CommMonitorTestUninstallResultEnvelope `
        -Material $resultMaterial `
        -Status Completed
    $residualObservation =
        New-CommMonitorTestTerminalResidualObservation `
            -ResultEnvelope $completedResult
    $terminalPreparationCapability =
        New-CommMonitorTerminalPreparationCapability `
            -CompletedResultEnvelope $completedResult `
            -ManifestPayload $current `
            -ManifestPayloadSha256 (
                $currentContext.Envelope.integrity.payloadSha256) `
            -ManifestKey $currentContext.Key `
            -ResidualObservation $residualObservation
    $protect = {
        param([byte[]] $Bytes)
        $protected = [byte[]]::new($Bytes.Length)
        for ($index = 0; $index -lt $Bytes.Length; $index++) {
            $protected[$index] = $Bytes[$index] -bxor 0xa5
        }
        return $protected
    }
    $unprotect = {
        param([byte[]] $Bytes)
        $plain = [byte[]]::new($Bytes.Length)
        for ($index = 0; $index -lt $Bytes.Length; $index++) {
            $plain[$index] = $Bytes[$index] -bxor 0xa5
        }
        return $plain
    }
    $terminalKey = New-CommMonitorManifestKey `
        -KeyBytes ([byte[]](64..95)) `
        -ProtectScript $protect
    $cleanupId = '55555555-5555-5555-5555-555555555555'
    $nonce = ('a' * 64)
    $finalizer = [ordered]@{
        relativePath = 'bin\LemonSerialMonitor.UninstallFinalizer.exe'
        sha256 = ('8' * 64)
    }
    $deletePlan = [object[]]@(
        [ordered]@{
            objectId = 'continuation'
            root = 'InstallerRoot'
            relativePath = 'state\continuation.v1.json'
            kind = 'File'
            volumeSerialNumber = '0011223344556677'
            fileId = ('1' * 32)
            size = [long]101
            sha256 = ('1' * 64)
            deleteOrder = 10
        },
        [ordered]@{
            objectId = 'anchor'
            root = 'CoreRoot'
            relativePath = 'metadata\install-anchor.v3.json'
            kind = 'File'
            volumeSerialNumber = '0011223344556677'
            fileId = ('2' * 32)
            size = [long]102
            sha256 = ('2' * 64)
            deleteOrder = 20
        },
        [ordered]@{
            objectId = 'manifest'
            root = 'InstallerRoot'
            relativePath = 'state\ownership-manifest.v3.json'
            kind = 'File'
            volumeSerialNumber = '0011223344556677'
            fileId = ('3' * 32)
            size = [long]103
            sha256 = ('3' * 64)
            deleteOrder = 30
        },
        [ordered]@{
            objectId = 'manifest-key'
            root = 'InstallerRoot'
            relativePath = 'state\ownership-manifest-key.v1.json'
            kind = 'File'
            volumeSerialNumber = '0011223344556677'
            fileId = ('4' * 32)
            size = [long]104
            sha256 = ('4' * 64)
            deleteOrder = 40
        })
    $descriptor = [ordered]@{
        cleanupId = $cleanupId
        nonce = $nonce
        key = $terminalKey.Record
        finalizer = $finalizer
        deletePlan = $deletePlan
    }
    $authorityIdentity = Get-CommMonitorSha256Hex -Bytes (
        Get-CommMonitorCanonicalJsonBytes -InputObject $descriptor)
    $successor = New-CommMonitorTestOperationPayloadForState `
        -State FinalizingAbsent
    $successor.operationState.terminalCleanupId = $cleanupId
    $successor.operationState.terminalKeyId = $terminalKey.Record.keyId
    $successor.operationState.terminalEnvelopeSha256 = $authorityIdentity
    $successor.revision = 2
    $successor.previousPayloadSha256 =
        $currentContext.Envelope.integrity.payloadSha256
    $successorContext = New-CommMonitorTestManifestTransitionContext `
        -CurrentPayload $successor
    return [pscustomobject]@{
        CurrentPayload = $current
        CurrentManifest = $currentContext.Manifest
        CurrentAnchor = $currentContext.Anchor
        CurrentManifestKey = $currentContext.Key
        CurrentPayloadSha256 =
            $currentContext.Envelope.integrity.payloadSha256
        SuccessorPayload = $successor
        SuccessorManifest = $successorContext.Manifest
        SuccessorAnchor = $successorContext.Anchor
        SuccessorPayloadSha256 =
            $successorContext.Envelope.integrity.payloadSha256
        ManifestPath = $currentContext.ManifestPath
        TerminalKey = $terminalKey
        ProtectScript = $protect
        UnprotectScript = $unprotect
        CleanupId = $cleanupId
        Nonce = $nonce
        Finalizer = $finalizer
        DeletePlan = $deletePlan
        Descriptor = $descriptor
        AuthorityIdentity = $authorityIdentity
        CompletedResult = $completedResult
        ResidualObservation = $residualObservation
        TerminalPreparationCapability = $terminalPreparationCapability
    }
}

function New-CommMonitorTestTerminalCleanupEnvelopeForMaterial {
    param(
        [Parameter(Mandatory)][object] $Material,
        [ValidateSet('Prepared', 'Active')][string] $Status = 'Prepared',
        [AllowNull()][object] $TerminalPreparationCapability
    )

    if (-not $PSBoundParameters.ContainsKey(
            'TerminalPreparationCapability')) {
        $TerminalPreparationCapability =
            $Material.TerminalPreparationCapability
    }

    return New-CommMonitorTerminalCleanupEnvelope `
        -Status $Status `
        -PredecessorPayload $Material.CurrentPayload `
        -PredecessorPayloadSha256 $Material.CurrentPayloadSha256 `
        -SuccessorPayload $Material.SuccessorPayload `
        -CleanupId $Material.CleanupId `
        -Nonce $Material.Nonce `
        -FinalizerRelativePath $Material.Finalizer.relativePath `
        -FinalizerSha256 $Material.Finalizer.sha256 `
        -DeletePlan $Material.DeletePlan `
        -CreatedUtc ([DateTimeOffset]::Parse(
            '2026-07-14T02:10:04.0000000Z')) `
        -TerminalKeyRecord $Material.TerminalKey.Record `
        -TerminalKey $Material.TerminalKey.KeyBytes `
        -TerminalPreparationCapability $TerminalPreparationCapability
}

function Update-CommMonitorTestTerminalCleanupIntegrity {
    param(
        [Parameter(Mandatory)][object] $Envelope,
        [Parameter(Mandatory)][byte[]] $Key
    )

    $bytes = Get-CommMonitorCanonicalJsonBytes -InputObject $Envelope.payload
    $Envelope.integrity.payloadSha256 =
        Get-CommMonitorSha256Hex -Bytes $bytes
    $Envelope.integrity.tag =
        Get-CommMonitorHmacSha256Hex -Key $Key -Bytes $bytes
}

function Invoke-CommMonitorTestTerminalManifestCas {
    param(
        [Parameter(Mandatory)][object] $Material,
        [AllowNull()][object] $NextPayload,
        [object] $TerminalCleanupEnvelope,
        [scriptblock] $TerminalUnprotectScript,
        [AllowNull()][object] $TerminalPreparationCapability,
        [switch] $OmitTerminalAuthority
    )

    if ($null -eq $NextPayload) {
        $NextPayload = $Material.SuccessorPayload
    }
    if (-not $PSBoundParameters.ContainsKey(
            'TerminalPreparationCapability')) {
        $TerminalPreparationCapability =
            $Material.TerminalPreparationCapability
    }
    $arguments = @{
        CurrentManifest = $Material.CurrentManifest
        CurrentAnchor = $Material.CurrentAnchor
        ExpectedRevision = $Material.CurrentPayload.revision
        ExpectedPayloadSha256 = $Material.CurrentPayloadSha256
        NextPayload = $NextPayload
        ManifestPath = $Material.ManifestPath
        Key = $Material.CurrentManifestKey
        KeyId = Get-CommMonitorSha256Hex `
            -Bytes $Material.CurrentManifestKey
        Actor = 'Task5'
    }
    if (-not $OmitTerminalAuthority) {
        $arguments.TerminalCleanupEnvelope = $TerminalCleanupEnvelope
        $arguments.TerminalUnprotectScript = $TerminalUnprotectScript
        $arguments.TerminalPreparationCapability =
            $TerminalPreparationCapability
    }
    return Update-CommMonitorOwnershipManifestCas @arguments
}

function New-CommMonitorTestTerminalLiveObjects {
    param([Parameter(Mandatory)][object] $Material)

    $items = [Collections.Generic.List[object]]::new()
    foreach ($record in $Material.DeletePlan) {
        $items.Add([ordered]@{
                objectId = [string]$record.objectId
                status = 'Present'
                root = [string]$record.root
                relativePath = [string]$record.relativePath
                kind = [string]$record.kind
                volumeSerialNumber = [string]$record.volumeSerialNumber
                fileId = [string]$record.fileId
                size = [long]$record.size
                sha256 = [string]$record.sha256
            })
    }
    return ,([object[]]$items.ToArray())
}

function New-CommMonitorTestPostTerminalDirectoryObservations {
    return [object[]]@(
        [ordered]@{
            role = 'StateDirectory'
            canonicalPath =
                'C:\ProgramData\LemonSerialMonitor\Installer\state'
            exists = $true
            empty = $true
            reparsePoint = $false
            localFixedVolume = $true
            aclTrusted = $true
        },
        [ordered]@{
            role = 'InstallerRoot'
            canonicalPath =
                'C:\ProgramData\LemonSerialMonitor\Installer'
            exists = $true
            empty = $true
            reparsePoint = $false
            localFixedVolume = $true
            aclTrusted = $true
        })
}

function New-CommMonitorTestTerminalCompletionObservation {
    return [ordered]@{
        terminalAuthorityPresent = $false
        stateDirectoryPresent = $false
        installerRootPresent = $false
        manifestPresent = $false
        manifestKeyPresent = $false
        anchorPresent = $false
        continuationPresent = $false
        continuationTaskPresent = $false
        uninstallEntryPresent = $false
        appRootPresent = $false
        coreRootPresent = $false
        dataRootPresent = $false
        aiRootPresent = $false
        residualObjectIds = [object[]]@()
    }
}

function New-CommMonitorTestUninstallResultMaterial {
    $payload = New-CommMonitorTestOperationPayloadForState `
        -State UninstallPrepared
    $context = New-CommMonitorTestManifestTransitionContext `
        -CurrentPayload $payload
    return [pscustomobject]@{
        Payload = $payload
        PayloadSha256 = $context.Envelope.integrity.payloadSha256
        Key = $context.Key
        KeyId = $context.KeyId
        ResultId = '77777777-7777-7777-7777-777777777777'
        HelperPid = [long]4321
        HelperCreationUtc =
            '2026-07-14T02:03:30.0000000Z'
        CreatedUtc = '2026-07-14T02:11:04.0000000Z'
    }
}

function New-CommMonitorTestUninstallResultEnvelope {
    param(
        [Parameter(Mandatory)][object] $Material,
        [Parameter(Mandatory)]
        [ValidateSet('Completed', 'PendingReboot', 'Failed')]
        [string] $Status,
        [AllowNull()][object] $ExitCode,
        [AllowNull()][object] $RebootRequired,
        [AllowNull()][AllowEmptyCollection()][object] $Outcomes
    )

    if ($null -eq $ExitCode) {
        $ExitCode = switch ($Status) {
            'Completed' { 0 }
            'PendingReboot' { 3010 }
            'Failed' { 5 }
        }
    }
    if ($null -eq $RebootRequired) {
        $RebootRequired = $Status -eq 'PendingReboot'
    }
    if (-not $PSBoundParameters.ContainsKey('Outcomes')) {
        $outcome = switch ($Status) {
            'Completed' { 'Deleted' }
            'PendingReboot' { 'PendingReboot' }
            'Failed' { 'Failed' }
        }
        $win32Code = switch ($Status) {
            'Completed' { 0 }
            'PendingReboot' { 32 }
            'Failed' { 5 }
        }
        $Outcomes = [object[]]@([ordered]@{
                objectId = 'semantic-dynamic'
                outcome = $outcome
                win32Code = $win32Code
            })
    }
    return New-CommMonitorUninstallResultEnvelope `
        -ManifestPayload $Material.Payload `
        -ManifestPayloadSha256 $Material.PayloadSha256 `
        -ResultId $Material.ResultId `
        -Status $Status `
        -ExitCode $ExitCode `
        -RebootRequired $RebootRequired `
        -CreatedUtc $Material.CreatedUtc `
        -HelperPid $Material.HelperPid `
        -HelperCreationUtc $Material.HelperCreationUtc `
        -HelperImageSha256 $Material.Payload.operationState.helperSha256 `
        -Outcomes $Outcomes `
        -Key $Material.Key `
        -KeyId $Material.KeyId
}

function Update-CommMonitorTestUninstallResultIntegrity {
    param(
        [Parameter(Mandatory)][object] $Envelope,
        [Parameter(Mandatory)][byte[]] $Key
    )

    $bytes = Get-CommMonitorCanonicalJsonBytes -InputObject $Envelope.payload
    $Envelope.integrity.payloadSha256 =
        Get-CommMonitorSha256Hex -Bytes $bytes
    $Envelope.integrity.tag =
        Get-CommMonitorHmacSha256Hex -Key $Key -Bytes $bytes
}

function New-CommMonitorTestTerminalResidualObservation {
    param([Parameter(Mandatory)][object] $ResultEnvelope)

    return [ordered]@{
        operationId = [string]$ResultEnvelope.payload.operationId
        resultId = [string]$ResultEnvelope.payload.resultId
        verifiedUtc = '2026-07-14T02:12:04.0000000Z'
        productWriterCount = 0
        nonAuthorityResidualObjectIds = [object[]]@()
        uninstallEntryPresent = $false
        continuationTaskPresent = $false
        appRootPresent = $false
        dataRootPresent = $false
        aiRootPresent = $false
        coreNonAuthorityPresent = $false
        installerNonAuthorityPresent = $false
    }
}

function New-CommMonitorTestTerminalPreparationMaterial {
    $resultMaterial = New-CommMonitorTestUninstallResultMaterial
    $completedResult = New-CommMonitorTestUninstallResultEnvelope `
        -Material $resultMaterial `
        -Status Completed
    $residualObservation =
        New-CommMonitorTestTerminalResidualObservation `
            -ResultEnvelope $completedResult
    return [pscustomobject]@{
        ResultMaterial = $resultMaterial
        CompletedResult = $completedResult
        ResidualObservation = $residualObservation
    }
}

function New-CommMonitorTestRootDirectoryDefinition {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('AppRoot', 'CoreRoot')]
        [string] $Root,
        [string] $ObjectId = 'test-root-directory',
        [string] $OwnershipProof = 'CreatedThisInstall',
        [bool] $RemoveOnUninstall = $true,
        [bool] $Created = $true,
        [int] $DeletePhase = 90
    )

    return [ordered]@{
        objectId = $ObjectId
        type = 'Directory'
        component = 'RootDirectory'
        root = $Root
        relativePath = ''
        ownershipProof = $OwnershipProof
        removeOnUninstall = $RemoveOnUninstall
        deletePhase = $DeletePhase
        contentPolicy = 'EmptyAfterOwnedChildren'
        identity = [ordered]@{ created = $Created }
    }
}

function New-CommMonitorTestDesktopShortcutDefinition {
    param(
        [string] $ObjectId = 'desktop-shortcut-test',
        [string] $RelativePath = 'Lemon串口监控.lnk'
    )

    return [ordered]@{
        objectId = $ObjectId
        type = 'Shortcut'
        component = 'DesktopShortcut'
        root = 'Desktop'
        relativePath = $RelativePath
        ownershipProof = 'CreatedThisInstall'
        removeOnUninstall = $true
        deletePhase = 10
        identity = [ordered]@{
            target = 'C:\Program Files\Lemon串口监控\CommMonitor.App.exe'
            arguments = ''
            workingDirectory = 'C:\Program Files\Lemon串口监控'
            fileSha256 = ('d' * 64)
            created = $true
        }
    }
}

function New-CommMonitorTestDocsDefinition {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('AppRoot', 'CoreRoot')]
        [string] $Root,
        [string] $ObjectId = 'docs-test'
    )

    return [ordered]@{
        objectId = $ObjectId
        type = 'ImmutableFile'
        component = 'Docs'
        root = $Root
        relativePath = 'docs\guide.pdf'
        ownershipProof = 'CreatedThisInstall'
        removeOnUninstall = $true
        deletePhase = 20
        identity = [ordered]@{
            size = 1
            sha256 = ('e' * 64)
            productMarker = 'CommMonitor:0.1.0'
        }
    }
}

function New-CommMonitorTestAuthorizedUserBinding {
    param(
        [string] $Sid = 'S-1-5-21-111-222-333-1001',
        [string] $ProfileImagePath = 'C:\Users\测试 用户',
        [scriptblock] $LegacyMarkerProbe = {
            throw 'No TestOnly legacy-marker probe was registered.'
        }
    )

    $localAppDataPath = Join-Path $ProfileImagePath 'AppData\Local'
    $knownFolderProbe = {
        param($requestedSid, $knownFolder)
        [pscustomobject]@{
            Sid = $requestedSid
            KnownFolder = $knownFolder
            KnownFolderId = '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}'
            Path = $localAppDataPath
            IdentityVerified = $true
        }
    }.GetNewClosure()
    $interactiveSessionProbe = {
        [pscustomobject]@{
            Source = 'WindowsTokenSessionProbe'
            OriginalInteractiveSid = $Sid
            IdentityVerified = $true
        }
    }.GetNewClosure()
    return Resolve-CommMonitorAuthorizedUserForTest `
        -AuthorizedUserSid $Sid `
        -ProfileListRecords @([pscustomobject]@{
                Sid = $Sid
                ProfileListKeyPath =
                    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
                ProfileImagePath = $ProfileImagePath
                ProfileImagePathValueKind = 'String'
            }) `
        -KnownFolderProbe $knownFolderProbe `
        -InteractiveSessionProbe $interactiveSessionProbe `
        -AiRelativePath 'LemonSerialMonitor\AI' `
        -LegacyMarkerProbe $LegacyMarkerProbe
}

function New-CommMonitorTestAuthorizedUserArguments {
    param(
        [Collections.IDictionary] $ProfileOverrides = @{},
        [string[]] $RemoveProfileFields = @(),
        [Collections.IDictionary] $SessionOverrides = @{},
        [string[]] $RemoveSessionFields = @(),
        [Collections.IDictionary] $KnownFolderOverrides = @{},
        [string[]] $RemoveKnownFolderFields = @(),
        [scriptblock] $ProfilePathExpansionProbe = {
            param($AuthorizedUserSid, $RawProfileImagePath)
            [pscustomobject][ordered]@{
                Source = 'ExpandEnvironmentStringsForUserW'
                Sid = $AuthorizedUserSid
                RawValue = $RawProfileImagePath
                Path = $RawProfileImagePath
                IdentityVerified = $true
            }
        }
    )

    $sid = 'S-1-5-21-111-222-333-1001'
    $profile = [ordered]@{
        Sid = $sid
        ProfileListKeyPath =
            "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        ProfileImagePath = 'C:\Users\One'
        ProfileImagePathValueKind = 'String'
    }
    $session = [ordered]@{
        Source = 'WindowsTokenSessionProbe'
        OriginalInteractiveSid = $sid
        IdentityVerified = $true
    }
    $knownFolder = [ordered]@{
        Sid = $sid
        KnownFolder = 'LocalAppData'
        KnownFolderId = '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}'
        Path = 'C:\Users\One\AppData\Local'
        IdentityVerified = $true
    }
    foreach ($key in @($ProfileOverrides.Keys)) { $profile[$key] = $ProfileOverrides[$key] }
    foreach ($key in @($SessionOverrides.Keys)) { $session[$key] = $SessionOverrides[$key] }
    foreach ($key in @($KnownFolderOverrides.Keys)) {
        $knownFolder[$key] = $KnownFolderOverrides[$key]
    }
    foreach ($key in @($RemoveProfileFields)) { $profile.Remove($key) }
    foreach ($key in @($RemoveSessionFields)) { $session.Remove($key) }
    foreach ($key in @($RemoveKnownFolderFields)) { $knownFolder.Remove($key) }

    $capturedSession = [pscustomobject]$session
    $capturedKnownFolder = [pscustomobject]$knownFolder
    return @{
        AuthorizedUserSid = $sid
        ProfileListRecords = @([pscustomobject]$profile)
        InteractiveSessionProbe = { $capturedSession }.GetNewClosure()
        KnownFolderProbe = {
            param($requestedSid, $requestedKnownFolder)
            $capturedKnownFolder
        }.GetNewClosure()
        ProfilePathExpansionProbe = $ProfilePathExpansionProbe
        AiRelativePath = 'LemonSerialMonitor\AI'
    }
}

function New-CommMonitorTestLegacyAdoptionEvidence {
    param(
        [string] $DataRoot = 'C:\ProgramData\CommMonitor',
        [string] $MarkerId = 'cccccccc-cccc-cccc-cccc-cccccccccccc',
        [string] $VolumeSerialNumber = '0011223344556677',
        [string] $FileId,
        [object] $AclProfile
    )

    if ([string]::IsNullOrEmpty($FileId)) {
        $FileId = Get-CommMonitorTestFileId -Identity $DataRoot
    }
    if ($null -eq $AclProfile) {
        $AclProfile = New-CommMonitorTestProtectedAclProfile
    }
    $marker = [ordered]@{
        schemaVersion = 1
        markerId = $MarkerId
        canonicalPath = $DataRoot
        volumeSerialNumber = $VolumeSerialNumber
        fileId = $FileId
        aclProfile = $AclProfile
        ownershipProof = 'VerifiedLegacyAdoption'
    }
    $markerDigest = Get-CommMonitorTestSha256Hex -Text (
        ConvertTo-CommMonitorCanonicalJson -InputObject $marker)
    $protectedProbe = {
        param($expectedPath)
        [pscustomobject][ordered]@{
            Source = 'ProtectedLegacyMarkerProbe'
            IdentityVerified = $true
            Marker = $marker
            ProtectedExpectedDigest = $markerDigest
        }
    }.GetNewClosure()
    $binding = New-CommMonitorTestAuthorizedUserBinding `
        -LegacyMarkerProbe $protectedProbe
    $validatedMarker = Assert-CommMonitorLegacyDataRootMarker `
        -ExpectedDataRootPath $DataRoot `
        -AuthorizedUserBinding $binding
    $evidence = New-CommMonitorDataRootAdoptionEvidence `
        -SourceKind ValidatedLegacyMarker `
        -ValidatedLegacyMarker $validatedMarker
    return [pscustomobject]@{
        Marker = $marker
        MarkerDigest = $markerDigest
        Binding = $binding
        ValidatedMarker = $validatedMarker
        Evidence = $evidence
    }
}

Describe 'CommMonitor ownership probe capability boundary' {
    It 'does not publish a module-private callback capability registrar' {
        $module = Get-Module CommMonitor.InstallHelpers
        $present = & $module {
            $null -ne (Get-Command `
                    Register-CommMonitorOwnershipProbeCapability `
                    -ErrorAction SilentlyContinue)
        }
        $present | Should Be $false
    }

    It 'does not publish a module-private TestOnly callback capability factory' {
        $module = Get-Module CommMonitor.InstallHelpers
        $present = & $module {
            $null -ne (Get-Command `
                    New-CommMonitorTestOwnershipProbeCapability `
                    -ErrorAction SilentlyContinue)
        }
        $present | Should Be $false
    }

    It 'does not publish a module-private callback setter' {
        $module = Get-Module CommMonitor.InstallHelpers
        $present = & $module {
            $null -ne (Get-Command `
                    Set-CommMonitorTestOwnershipPathProbe `
                    -ErrorAction SilentlyContinue)
        }
        $present | Should Be $false
    }

    It 'does not publish a binding callback setter' {
        $module = Get-Module CommMonitor.InstallHelpers
        $present = & $module {
            $null -ne (Get-Command `
                    Set-CommMonitorTestOwnershipPathProbeForBinding `
                    -ErrorAction SilentlyContinue)
        }
        $present | Should Be $false
    }

    It 'exports an argument-free Windows ownership probe capability factory' {
        $command = Get-Command `
            -Name New-CommMonitorWindowsOwnershipProbeCapability `
            -ErrorAction SilentlyContinue
        $command | Should Not BeNullOrEmpty
        @($command.Parameters.Keys | Where-Object {
                $_ -notin @(
                    'Verbose', 'Debug', 'ErrorAction', 'WarningAction',
                    'InformationAction', 'ErrorVariable', 'WarningVariable',
                    'InformationVariable', 'OutVariable', 'OutBuffer',
                    'PipelineVariable')
            }).Count | Should Be 0
    }

    It 'issues only a registered fixed Windows provider capability' {
        $capability = New-CommMonitorWindowsOwnershipProbeCapability
        $capability.SchemaVersion | Should Be 1
        $capability.Provider | Should Be 'WindowsNativeOwnershipProbe'
        $capability.CapabilityId | Should Match '^[0-9a-f-]{36}$'
        $capability.Epoch | Should Match '^[0-9a-f-]{36}$'
    }

    It 'fails closed when the fixed pre-elevation broker contract is unavailable' {
        Assert-CommMonitorTestThrowsLike `
            -MessagePattern 'fixed pre-elevation interactive-session broker contract is unavailable' `
            -Action {
                $module = Get-Module CommMonitor.InstallHelpers
                & $module { Invoke-CommMonitorWindowsInteractiveSessionProbe }
            }
    }

    It 'reads ProfileList through the fixed Registry64 view' {
        $module = Get-Module CommMonitor.InstallHelpers
        $definition = & $module {
            (Get-Command Invoke-CommMonitorWindowsProfileListProbe).Definition
        }
        $definition | Should Match 'RegistryView\]::Registry64'
    }

    It 'reads the raw ProfileImagePath without expanding environment names' {
        $module = Get-Module CommMonitor.InstallHelpers
        $definition = & $module {
            (Get-Command Invoke-CommMonitorWindowsProfileListProbe).Definition
        }
        $definition | Should Match 'DoNotExpandEnvironmentNames'
    }

    It 'does not expand ProfileList values in the elevated process environment' {
        $module = Get-Module CommMonitor.InstallHelpers
        $definition = & $module {
            (Get-Command Invoke-CommMonitorWindowsProfileListProbe).Definition
        }
        $definition | Should Not Match 'ExpandEnvironmentVariables'
    }

    It 'closes the exported raw legacy-marker callback parameter' {
        $command = Get-Command Assert-CommMonitorLegacyDataRootMarker
        $command.Parameters.ContainsKey('LegacyMarkerProbe') | Should Be $false
    }

    It 'requires an authorized binding for legacy-marker validation' {
        $command = Get-Command Assert-CommMonitorLegacyDataRootMarker
        $command.Parameters.ContainsKey('AuthorizedUserBinding') | Should Be $true
    }

    It 'persists exact ProfileList session and Known Folder audit identity fields' {
        $sid = 'S-1-5-21-111-222-333-1001'
        $profile = 'C:\Users\Audited User'
        $profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        $knownFolderId = '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}'
        $knownFolderProbe = {
            param($requestedSid, $knownFolder)
            [pscustomobject][ordered]@{
                Sid = $requestedSid
                KnownFolder = $knownFolder
                KnownFolderId = $knownFolderId
                Path = 'C:\Users\Audited User\AppData\Local'
                IdentityVerified = $true
            }
        }.GetNewClosure()
        $binding = Resolve-CommMonitorAuthorizedUserForTest `
            -AuthorizedUserSid $sid `
            -ProfileListRecords @([pscustomobject][ordered]@{
                    Sid = $sid
                    ProfileListKeyPath = $profileKey
                    ProfileImagePath = $profile
                    ProfileImagePathValueKind = 'String'
                }) `
            -KnownFolderProbe $knownFolderProbe `
            -InteractiveSessionProbe {
                [pscustomobject][ordered]@{
                    Source = 'WindowsTokenSessionProbe'
                    OriginalInteractiveSid = $sid
                    IdentityVerified = $true
                }
            }.GetNewClosure() `
            -AiRelativePath 'LemonSerialMonitor\AI'

        $binding.Source | Should Be 'ProfileList+WindowsTokenSession+KnownFolder'
        $binding.ProfileListKeyPath | Should Be $profileKey
        $binding.ProfileImagePathRaw | Should Be $profile
        $binding.ProfileImagePathValueKind | Should Be 'String'
        $binding.ProfileExpansionSource | Should Be 'ExpandEnvironmentStringsForUserW'
        $binding.ProfileExpansionSid | Should Be $sid
        $binding.KnownFolderId | Should Be $knownFolderId
        $binding.KnownFolderSid | Should Be $sid
    }

    It 'rejects an exact property clone of a registered capability' {
        $capability = New-CommMonitorWindowsOwnershipProbeCapability
        $clone = $capability.PSObject.Copy()
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUser `
                    -AuthorizedUserSid 'S-1-5-21-111-222-333-1001' `
                    -OwnershipProbeCapability $clone `
                    -AiRelativePath 'LemonSerialMonitor\AI' } `
            -MessagePattern 'registered ownership-probe capability is required'
    }

    It 'rejects a serialized and reimported capability' {
        $capability = New-CommMonitorWindowsOwnershipProbeCapability
        $reimported = $capability | ConvertTo-Json | ConvertFrom-Json
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUser `
                    -AuthorizedUserSid 'S-1-5-21-111-222-333-1001' `
                    -OwnershipProbeCapability $reimported `
                    -AiRelativePath 'LemonSerialMonitor\AI' } `
            -MessagePattern 'registered ownership-probe capability is required'
    }

    It 'rejects a capability whose canonicalization surface gained executable code' {
        $capability = New-CommMonitorWindowsOwnershipProbeCapability
        $capability | Add-Member `
            -MemberType ScriptProperty `
            -Name CanonicalTrap `
            -Value { throw 'canonical capability trap executed' }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUser `
                    -AuthorizedUserSid 'S-1-5-21-111-222-333-1001' `
                    -OwnershipProbeCapability $capability `
                    -AiRelativePath 'LemonSerialMonitor\AI' } `
            -MessagePattern 'registered ownership-probe capability is required'
    }

    It 'rejects an exact property clone of a registered binding' {
        $binding = New-CommMonitorTestAuthorizedUserBinding
        $clone = $binding.PSObject.Copy()
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 `
                    -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                    -ProgramFilesPath 'C:\Program Files' `
                    -ProgramDataPath 'C:\ProgramData' `
                    -AuthorizedUserBinding $clone } `
            -MessagePattern 'not produced by the trusted resolver in this session'
    }

    It 'rejects a serialized and reimported binding' {
        $binding = New-CommMonitorTestAuthorizedUserBinding
        $reimported = $binding | ConvertTo-Json | ConvertFrom-Json
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 `
                    -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                    -ProgramFilesPath 'C:\Program Files' `
                    -ProgramDataPath 'C:\ProgramData' `
                    -AuthorizedUserBinding $reimported } `
            -MessagePattern 'not produced by the trusted resolver in this session'
    }

    It 'rejects a binding whose canonicalization surface gained executable code' {
        $binding = New-CommMonitorTestAuthorizedUserBinding
        $binding | Add-Member `
            -MemberType ScriptProperty `
            -Name CanonicalTrap `
            -Value { throw 'canonical binding trap executed' }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 `
                    -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                    -ProgramFilesPath 'C:\Program Files' `
                    -ProgramDataPath 'C:\ProgramData' `
                    -AuthorizedUserBinding $binding } `
            -MessagePattern 'not produced by the trusted resolver in this session'
    }

    It 'uses the frozen binding record across a deterministic post-check mutation barrier' {
        $binding = New-CommMonitorTestAuthorizedUserBinding
        $defaultProbe = New-CommMonitorTestPathProbe
        $barrierState = [pscustomobject]@{ Mutated = $false }
        $barrierProbe = {
            param($Path, $Pass)
            if (-not $barrierState.Mutated) {
                $binding.Source = 'MutatedAfterRegistryCheck'
                $binding.ProfileImagePath = 'D:\Attacker'
                $barrierState.Mutated = $true
            }
            & $defaultProbe $Path $Pass
        }.GetNewClosure()
        $roots = Resolve-CommMonitorTestOwnershipRoots `
            -PlatformKind Desktop -PlatformBuild 22631 `
            -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
            -ProgramFilesPath 'C:\Program Files' `
            -ProgramDataPath 'C:\ProgramData' `
            -AuthorizedUserBinding $binding `
            -PathProbe $barrierProbe

        $barrierState.Mutated | Should Be $true
        $roots.AuthorizedUser.ProfileImagePath | Should Be 'C:\Users\测试 用户'
    }
}

Describe 'CommMonitor ownership root resolution' {
    $programFiles = 'C:\Program Files'
    $programData = 'C:\ProgramData'
    $profile = 'C:\Users\测试 用户'
    $localAppData = 'C:\Users\测试 用户\AppData\Local'
    $aiRoot = 'C:\Users\测试 用户\AppData\Local\LemonSerialMonitor\AI'
    $authorizedSid = 'S-1-5-21-111-222-333-1001'
    $authorizedBinding = New-CommMonitorTestAuthorizedUserBinding

    It 'computes the four fixed roles and binds the original interactive user' {
        $roots = Resolve-CommMonitorTestOwnershipRoots `
            -PlatformKind Desktop `
            -PlatformBuild 26100 `
            -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
            -ProgramFilesPath $programFiles `
            -ProgramDataPath $programData `
            -AuthorizedUserBinding $authorizedBinding `
            -PathProbe (New-CommMonitorTestPathProbe)

        $roots.AppRoot.CanonicalPath | Should Be 'C:\Program Files\Lemon串口监控'
        $roots.CoreRoot.CanonicalPath | Should Be 'C:\Program Files\CommMonitor'
        $roots.DataRoot.CanonicalPath | Should Be 'C:\ProgramData\CommMonitor'
        $roots.InstallerRoot.CanonicalPath | Should Be 'C:\ProgramData\LemonSerialMonitor\Installer'
        $roots.AuthorizedUser.Sid | Should Be $authorizedSid
        $roots.AuthorizedUser.ProfileImagePath | Should Be $profile
        $roots.AuthorizedUser.LocalAppDataPath | Should Be $localAppData
        $roots.AuthorizedUser.AiRoot | Should Be $aiRoot
        $roots.AppRoot.Active | Should Be $true
        $roots.AppRoot.FileId.Length | Should Be 32
        $roots.Platform.Kind | Should Be 'Desktop'
    }

    It 'accepts a safe fixed D drive AppRoot with spaces' {
        $roots = Resolve-CommMonitorTestOwnershipRoots `
            -PlatformKind Desktop `
            -PlatformBuild 22631 `
            -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
            -AppRoot 'D:\Lemon Apps\串口监控' `
            -ProgramFilesPath $programFiles `
            -ProgramDataPath $programData `
            -AuthorizedUserBinding $authorizedBinding `
            -PathProbe (New-CommMonitorTestPathProbe)

        $roots.AppRoot.CanonicalPath | Should Be 'D:\Lemon Apps\串口监控'
        $roots.AppRoot.VolumeSerialNumber | Should Be '0011223344556677'
    }

    It 'allows a nonexistent protected root to inherit an ordinary parent before creation' {
        $ordinaryParentAcl = [pscustomobject][ordered]@{
            OwnerSid = 'S-1-5-21-111-222-333-1001'
            AreAccessRulesProtected = $false
            AllowedFullControlSids = @('S-1-5-21-111-222-333-1001')
            DenyRuleCount = 0
            UsersWritable = $true
        }
        $overrides = @{}
        foreach ($path in @(
                'C:\Program Files\CommMonitor',
                'C:\ProgramData\CommMonitor',
                'C:\ProgramData\LemonSerialMonitor\Installer')) {
            $overrides[$path] = [pscustomobject]@{
                Exists = $false
                AclProfile = $ordinaryParentAcl
            }
        }

        $roots = Resolve-CommMonitorTestOwnershipRoots `
            -PlatformKind Desktop `
            -PlatformBuild 22631 `
            -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
            -ProgramFilesPath $programFiles `
            -ProgramDataPath $programData `
            -AuthorizedUserBinding $authorizedBinding `
            -PathProbe (New-CommMonitorTestPathProbe $overrides)

        $roots.CoreRoot.CreatedByInstall | Should Be $true
        $roots.DataRoot.CreatedByInstall | Should Be $true
        $roots.InstallerRoot.CreatedByInstall | Should Be $true
    }

    It 'keeps AppRoot inactive and absent on Server Core' {
        $roots = Resolve-CommMonitorTestOwnershipRoots `
            -PlatformKind ServerCore `
            -PlatformBuild 20348 `
            -PlatformComponents @('Service', 'Driver', 'AI', 'Headless') `
            -ProgramFilesPath $programFiles `
            -ProgramDataPath $programData `
            -AuthorizedUserBinding $authorizedBinding `
            -PathProbe (New-CommMonitorTestPathProbe)

        $roots.AppRoot.Active | Should Be $false
        $roots.AppRoot.Present | Should Be $false
        $roots.AppRoot.FileId | Should BeNullOrEmpty
        $roots.Platform.Kind | Should Be 'ServerCore'
    }

    It 'rejects relative UNC device ADS root and overlap paths' {
        $common = @{
            PlatformKind = 'Desktop'
            PlatformBuild = 22631
            PlatformComponents = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
            ProgramFilesPath = $programFiles
            ProgramDataPath = $programData
            AuthorizedUserBinding = $authorizedBinding
            PathProbe = (New-CommMonitorTestPathProbe)
        }

        { Resolve-CommMonitorTestOwnershipRoots @common -AppRoot 'relative\app' } |
            Should Throw
        { Resolve-CommMonitorTestOwnershipRoots @common -AppRoot '\\server\share\app' } |
            Should Throw
        { Resolve-CommMonitorTestOwnershipRoots @common -AppRoot '\\?\C:\unsafe' } |
            Should Throw
        { Resolve-CommMonitorTestOwnershipRoots @common -AppRoot 'D:\safe:stream' } |
            Should Throw
        { Resolve-CommMonitorTestOwnershipRoots @common -AppRoot 'C:\Program Files\CommMonitor\child' } |
            Should Throw
    }

    It 'rejects removable reparse nonempty and identity-changing probes' {
        $appRoot = 'D:\Unsafe App'
        $baseProbe = [pscustomobject]@{
            Provider = 'FileSystem'
            VolumeKind = 'Fixed'
            VolumeSerialNumber = '8899aabbccddeeff'
            Exists = $true
            IsDirectory = $true
            IsEmpty = $true
            IsReparse = $false
            FileId = '0123456789abcdef0123456789abcdef'
            ExistingParentFileId = $null
            AclProfile = New-CommMonitorTestProtectedAclProfile
        }
        $common = @{
            PlatformKind = 'Desktop'
            PlatformBuild = 22631
            PlatformComponents = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
            AppRoot = $appRoot
            ProgramFilesPath = $programFiles
            ProgramDataPath = $programData
            AuthorizedUserBinding = $authorizedBinding
        }

        $removable = $baseProbe.PSObject.Copy()
        $removable.VolumeKind = 'Removable'
        { Resolve-CommMonitorTestOwnershipRoots @common `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $removable}) } |
            Should Throw

        $reparse = $baseProbe.PSObject.Copy()
        $reparse.IsReparse = $true
        { Resolve-CommMonitorTestOwnershipRoots @common `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $reparse}) } |
            Should Throw

        $nonempty = $baseProbe.PSObject.Copy()
        $nonempty.IsEmpty = $false
        { Resolve-CommMonitorTestOwnershipRoots @common `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $nonempty}) } |
            Should Throw

        $changing = {
            param($Path, $Pass)
            $result = $baseProbe.PSObject.Copy()
            if ($Pass -eq 2) {
                $result.FileId = 'ffffffffffffffffffffffffffffffff'
            }
            return $result
        }.GetNewClosure()
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots @common `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $changing}) } `
            -MessagePattern 'identity changed between probes'
    }

    It 'rejects a user AI root overlapping any product root' {
        $overlappingBinding = New-CommMonitorTestAuthorizedUserBinding `
            -ProfileImagePath 'C:\ProgramData\CommMonitor'
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop `
                -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath $programFiles `
                -ProgramDataPath $programData `
                -AuthorizedUserBinding $overlappingBinding `
                -PathProbe (New-CommMonitorTestPathProbe) } | Should Throw
    }

    It 'rejects raw traversal invalid and reserved path segments before canonicalization' {
        $common = @{
            PlatformKind = 'Desktop'
            PlatformBuild = 22631
            PlatformComponents = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
            ProgramFilesPath = $programFiles
            ProgramDataPath = $programData
            AuthorizedUserBinding = $authorizedBinding
            PathProbe = (New-CommMonitorTestPathProbe)
        }

        foreach ($unsafePath in @(
                'D:\safe\..\escaped',
                'D:\safe\.\child',
                'D:\safe\bad?name',
                'D:\safe\NUL.txt')) {
            $message = try {
                Resolve-CommMonitorTestOwnershipRoots @common -AppRoot $unsafePath
                $null
            }
            catch {
                $_.Exception.Message
            }
            $message | Should Match 'unsafe path segment'
        }
    }

    It 'requires canonical parent identity for a nonexistent target' {
        $appRoot = 'D:\New App'
        $missing = [pscustomobject]@{
            Provider = 'FileSystem'
            VolumeKind = 'Fixed'
            VolumeSerialNumber = '8899aabbccddeeff'
            Exists = $false
            IsDirectory = $true
            IsEmpty = $true
            IsReparse = $false
            FileId = $null
            ExistingParentFileId = 'not-a-file-id'
            AclProfile = New-CommMonitorTestProtectedAclProfile
        }

        $message = try {
            Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop `
                -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -AppRoot $appRoot `
                -ProgramFilesPath $programFiles `
                -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $missing})
            $null
        }
        catch {
            $_.Exception.Message
        }
        $message | Should Match 'incomplete identity evidence'
    }

    It 'rejects safety evidence drift between the two probes' {
        $appRoot = 'D:\Drifting App'
        $drifting = {
            param($Path, $Pass)
            [pscustomobject]@{
                Provider = 'FileSystem'
                VolumeKind = 'Fixed'
                VolumeSerialNumber = '8899aabbccddeeff'
                Exists = $true
                IsDirectory = $true
                IsEmpty = $true
                IsReparse = $false
                FileId = '0123456789abcdef0123456789abcdef'
                ExistingParentFileId = $null
                AclProfile = if ($Pass -eq 1) {
                    New-CommMonitorTestProtectedAclProfile
                }
                else {
                    [pscustomobject][ordered]@{
                        OwnerSid = 'S-1-5-32-545'
                        AreAccessRulesProtected = $false
                        AllowedFullControlSids = @('S-1-5-32-545')
                        DenyRuleCount = 0
                        UsersWritable = $true
                    }
                }
            }
        }

        $message = try {
            Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop `
                -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -AppRoot $appRoot `
                -ProgramFilesPath $programFiles `
                -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $drifting})
            $null
        }
        catch {
            $_.Exception.Message
        }
        $message | Should Match 'identity changed between probes'
    }

    It 'rejects a probe with missing ancestor-chain evidence' {
        $appRoot = 'D:\Evidence App'
        $record = & (New-CommMonitorTestPathProbe) $appRoot 1
        $record.Ancestors = $null
        $message = try {
            Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record})
            $null
        }
        catch {
            $_.Exception.Message
        }
        $message | Should Match 'ancestor-chain evidence'
    }

    It 'rejects an ancestor-chain array missing exactly one expected element' {
        $appRoot = 'D:\Short Evidence App'
        $record = & (New-CommMonitorTestPathProbe) $appRoot 1
        $record.Ancestors = @($record.Ancestors | Select-Object -Skip 1)
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 `
                    -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                    -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } `
            -MessagePattern 'incomplete ancestor-chain evidence'
    }

    It 'rejects an intermediate ancestor with a nonzero reparse tag' {
        $appRoot = 'D:\Reparse Evidence App'
        $record = & (New-CommMonitorTestPathProbe) $appRoot 1
        $ancestors = @($record.Ancestors | ForEach-Object { $_.PSObject.Copy() })
        $ancestors[1].ReparseTag = 0xA0000003
        $record.Ancestors = $ancestors
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } | Should Throw
    }

    It 'rejects ancestor-chain drift between the two probes' {
        $appRoot = 'D:\Drifting Evidence App'
        $capturedProbe = New-CommMonitorTestPathProbe
        $driftingChain = {
            param($Path, $Pass)
            $record = & $capturedProbe $Path $Pass
            if ($Pass -eq 2) {
                $differentFinalPath = 'D:\Different Final App'
                $changed = @($record.Ancestors | ForEach-Object { $_.PSObject.Copy() })
                $record.FinalPath = $differentFinalPath
                $record.NearestExistingAncestor.FinalPath = $differentFinalPath
                $changed[$changed.Count - 1].FinalPath = $differentFinalPath
                $record.Ancestors = $changed
            }
            return $record
        }.GetNewClosure()
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 `
                    -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                    -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $driftingChain}) } `
            -MessagePattern 'identity changed between probes'
    }

    It 'rejects an 8.3 spelling that resolves to another ownership root' {
        $appRoot = 'C:\PROGRA~9\CommMonitor'
        $coreRoot = 'C:\Program Files\CommMonitor'
        $record = & (New-CommMonitorTestPathProbe) $appRoot 1
        $record.FinalPath = $coreRoot
        $record.FileId = Get-CommMonitorTestFileId -Identity $coreRoot
        $record.NearestExistingAncestor = [pscustomobject][ordered]@{
            RequestedPath = $appRoot; FinalPath = $coreRoot
            VolumeSerial = $record.VolumeSerialNumber; FileId = $record.FileId
        }
        $record.Ancestors = @(
            [pscustomobject][ordered]@{
                RequestedPath = 'C:\'; FinalPath = 'C:\'; VolumeSerial = $record.VolumeSerialNumber
                FileId = Get-CommMonitorTestFileId -Identity 'C:\'; ReparseTag = 0
            },
            [pscustomobject][ordered]@{
                RequestedPath = 'C:\PROGRA~9'; FinalPath = 'C:\Program Files'
                VolumeSerial = $record.VolumeSerialNumber
                FileId = Get-CommMonitorTestFileId -Identity 'C:\Program Files'; ReparseTag = 0
            },
            [pscustomobject][ordered]@{
                RequestedPath = $appRoot; FinalPath = $coreRoot; VolumeSerial = $record.VolumeSerialNumber
                FileId = $record.FileId; ReparseTag = 0
            })
        $message = try {
            Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record})
            $null
        }
        catch {
            $_.Exception.Message
        }
        $message | Should Match 'physical root alias'
    }

    It 'rejects a handle-final candidate below another ownership root' {
        $appRoot = 'C:\Alias Application'
        $finalPath = 'C:\ProgramData\CommMonitor\NestedApp'
        $record = & (New-CommMonitorTestPathProbe) $appRoot 1
        $record.FinalPath = $finalPath
        $record.FileId = Get-CommMonitorTestFileId -Identity $finalPath
        $record.NearestExistingAncestor = [pscustomobject][ordered]@{
            RequestedPath = $appRoot; FinalPath = $finalPath
            VolumeSerial = $record.VolumeSerialNumber; FileId = $record.FileId
        }
        $record.Ancestors = @(
            $record.Ancestors[0],
            [pscustomobject][ordered]@{
                RequestedPath = $appRoot; FinalPath = $finalPath; VolumeSerial = $record.VolumeSerialNumber
                FileId = $record.FileId; ReparseTag = 0
            })
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } | Should Throw
    }

    It 'rejects two existing roots with the same volume and file ID' {
        $appRoot = 'C:\Different Root'
        $coreRoot = 'C:\Program Files\CommMonitor'
        $sameIdentity = [pscustomobject]@{
            FileId = Get-CommMonitorTestFileId -Identity $coreRoot
        }
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $sameIdentity}) } | Should Throw
    }

    It 'rejects a nonexistent root reached through an aliased nearest parent' {
        $appRoot = 'C:\AliasParent\New App'
        $programFilesId = Get-CommMonitorTestFileId -Identity 'C:\Program Files'
        $record = [pscustomobject]@{
            Exists = $false; FinalPath = $null; FileId = $null
            ExistingParentFileId = $programFilesId
            NearestExistingAncestor = [pscustomobject][ordered]@{
                RequestedPath = 'C:\AliasParent'; FinalPath = 'C:\Program Files'
                VolumeSerial = '0011223344556677'; FileId = $programFilesId
            }
            UnresolvedSuffix = 'New App'
            Ancestors = @(
                [pscustomobject][ordered]@{
                    RequestedPath = 'C:\'; FinalPath = 'C:\'; VolumeSerial = '0011223344556677'
                    FileId = Get-CommMonitorTestFileId -Identity 'C:\'; ReparseTag = 0
                },
                [pscustomobject][ordered]@{
                    RequestedPath = 'C:\AliasParent'; FinalPath = 'C:\Program Files'
                    VolumeSerial = '0011223344556677'; FileId = $programFilesId; ReparseTag = 0
                })
        }
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } | Should Throw
    }

    It 'accepts only validated client and server component matrices' {
        $clientCommon = @{
            ProgramFilesPath = $programFiles
            ProgramDataPath = $programData
            AuthorizedUserBinding = $authorizedBinding
            PathProbe = (New-CommMonitorTestPathProbe)
        }

        { Resolve-CommMonitorTestOwnershipRoots @clientCommon `
                -PlatformKind Desktop `
                -PlatformBuild 26200 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') } |
            Should Throw
        { Resolve-CommMonitorTestOwnershipRoots @clientCommon `
                -PlatformKind Desktop `
                -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver') } |
            Should Throw
        { Resolve-CommMonitorTestOwnershipRoots @clientCommon `
                -PlatformKind ServerDesktop `
                -PlatformBuild 20348 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') } |
            Should Not Throw
        { Resolve-CommMonitorTestOwnershipRoots @clientCommon `
                -PlatformKind ServerDesktop `
                -PlatformBuild 99999 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') } |
            Should Throw
    }

    It 'accepts the exact Desktop component set regardless of order' {
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('AI', 'WPF', 'StartMenuShortcut', 'Driver', 'Service') `
                -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe) } | Should Not Throw
    }

    It 'accepts the exact Server Desktop component set regardless of order' {
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind ServerDesktop -PlatformBuild 20348 `
                -PlatformComponents @('Driver', 'StartMenuShortcut', 'AI', 'Service', 'WPF') `
                -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe) } | Should Not Throw
    }

    It 'accepts the exact Server Core component set regardless of order' {
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind ServerCore -PlatformBuild 20348 `
                -PlatformComponents @('AI', 'Headless', 'Driver', 'Service') `
                -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe) } | Should Not Throw
    }

    It 'retains the validated platform component snapshot across root probes' {
        $components = [string[]]@(
            'WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
        $defaultProbe = New-CommMonitorTestPathProbe
        $state = [pscustomobject]@{ Mutated = $false }
        $mutatingProbe = {
            param($Path, $Pass)
            if (-not $state.Mutated) {
                $components[0] = 'Unknown'
                $state.Mutated = $true
            }
            & $defaultProbe $Path $Pass
        }.GetNewClosure()

        $roots = Resolve-CommMonitorTestOwnershipRoots `
            -PlatformKind Desktop -PlatformBuild 22631 `
            -PlatformComponents $components `
            -ProgramFilesPath $programFiles -ProgramDataPath $programData `
            -AuthorizedUserBinding $authorizedBinding `
            -PathProbe $mutatingProbe

        $state.Mutated | Should Be $true
        ($roots.Platform.Components -contains 'WPF') | Should Be $true
        ($roots.Platform.Components -contains 'Unknown') | Should Be $false
    }

    It 'rejects a Desktop component set with one member missing' {
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 `
                    -PlatformComponents @('WPF', 'Service', 'Driver', 'StartMenuShortcut') `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe) } `
            -MessagePattern 'Desktop requires the exact component set'
    }

    It 'rejects an unknown extra Desktop component' {
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 `
                    -PlatformComponents @(
                        'WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut', 'Unknown') `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe) } `
            -MessagePattern 'Desktop requires the exact component set'
    }

    It 'rejects a duplicate Desktop component' {
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 `
                    -PlatformComponents @(
                        'WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut', 'AI') `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe) } `
            -MessagePattern 'Desktop requires the exact component set'
    }

    It 'rejects a wrong-case Desktop component' {
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 `
                    -PlatformComponents @('wpf', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe) } `
            -MessagePattern 'Desktop requires the exact component set'
    }

    It 'rejects a Desktop set mixed with a Server Core component' {
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 `
                    -PlatformComponents @(
                        'WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut', 'Headless') `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe) } `
            -MessagePattern 'Desktop requires the exact component set'
    }

    It 'rejects a Server Desktop set mixed with a Server Core component' {
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind ServerDesktop -PlatformBuild 20348 `
                    -PlatformComponents @(
                        'WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut', 'Headless') `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe) } `
            -MessagePattern 'ServerDesktop requires the exact component set'
    }

    It 'rejects a Server Core component set with one member missing' {
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind ServerCore -PlatformBuild 20348 `
                    -PlatformComponents @('Headless', 'Service', 'Driver') `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe) } `
            -MessagePattern 'ServerCore requires the exact component set'
    }

    It 'rejects a duplicate Server Core component' {
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind ServerCore -PlatformBuild 20348 `
                    -PlatformComponents @('Headless', 'Service', 'Driver', 'AI', 'AI') `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe) } `
            -MessagePattern 'ServerCore requires the exact component set'
    }

    It 'rejects a wrong-case Server Core component' {
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind ServerCore -PlatformBuild 20348 `
                    -PlatformComponents @('headless', 'Service', 'Driver', 'AI') `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe) } `
            -MessagePattern 'ServerCore requires the exact component set'
    }

    It 'rejects a Server Core set mixed with Desktop components' {
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind ServerCore -PlatformBuild 20348 `
                    -PlatformComponents @('Headless', 'Service', 'Driver', 'AI', 'WPF') `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe) } `
            -MessagePattern 'ServerCore requires the exact component set'
    }

    It 'accepts only the exact registered authorized-user binding' {
        $rootArguments = @{
            PlatformKind = 'Desktop'
            PlatformBuild = 22631
            PlatformComponents = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
            ProgramFilesPath = $programFiles
            ProgramDataPath = $programData
            PathProbe = (New-CommMonitorTestPathProbe)
        }

        { Resolve-CommMonitorTestOwnershipRoots @rootArguments `
                -AuthorizedUserSid $authorizedSid `
                -ProfileImagePath $profile `
                -LocalAppDataPath $localAppData `
                -AiRoot $aiRoot } | Should Throw

        $tampered = New-CommMonitorTestAuthorizedUserBinding
        $tampered.AiRoot = 'C:\Users\测试 用户\AppData\Local\LemonSerialMonitor\Other'
        { Resolve-CommMonitorTestOwnershipRoots @rootArguments `
                -AuthorizedUserBinding $tampered } | Should Throw

        $falseBinding = New-CommMonitorTestAuthorizedUserBinding
        $falseBinding.IdentityVerified = $false
        { Resolve-CommMonitorTestOwnershipRoots @rootArguments `
                -AuthorizedUserBinding $falseBinding } | Should Throw

        $extraBinding = New-CommMonitorTestAuthorizedUserBinding
        $extraBinding | Add-Member -NotePropertyName ElevatedSid -NotePropertyValue 'S-1-5-18'
        { Resolve-CommMonitorTestOwnershipRoots @rootArguments `
                -AuthorizedUserBinding $extraBinding } | Should Throw

        $missingBinding = New-CommMonitorTestAuthorizedUserBinding
        $missingBinding.PSObject.Properties.Remove('Source')
        { Resolve-CommMonitorTestOwnershipRoots @rootArguments `
                -AuthorizedUserBinding $missingBinding } | Should Throw

    }

    It 'rejects a registered binding whose complete identity was rewritten consistently' {
        $binding = New-CommMonitorTestAuthorizedUserBinding
        $binding.Sid = 'S-1-5-21-111-222-333-1002'
        $binding.OriginalInteractiveSid = $binding.Sid
        $binding.ProfileImagePath = 'D:\Users\Other'
        $binding.LocalAppDataPath = 'D:\Users\Other\AppData\Local'
        $binding.AiRoot = 'D:\Users\Other\AppData\Local\LemonSerialMonitor\AI'
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $binding -PathProbe (New-CommMonitorTestPathProbe) } |
            Should Throw
    }

    It 'rejects a registered binding whose profile and dependent paths moved together' {
        $binding = New-CommMonitorTestAuthorizedUserBinding
        $binding.ProfileImagePath = 'D:\Users\Moved'
        $binding.LocalAppDataPath = 'D:\Users\Moved\AppData\Local'
        $binding.AiRoot = 'D:\Users\Moved\AppData\Local\LemonSerialMonitor\AI'
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $binding -PathProbe (New-CommMonitorTestPathProbe) } |
            Should Throw
    }

    It 'rejects a registered binding whose SID pair changed together' {
        $binding = New-CommMonitorTestAuthorizedUserBinding
        $binding.Sid = 'S-1-5-21-111-222-333-1002'
        $binding.OriginalInteractiveSid = $binding.Sid
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $binding -PathProbe (New-CommMonitorTestPathProbe) } |
            Should Throw
    }
}

Describe 'CommMonitor trusted probe invariants' {
    $programFiles = 'C:\Program Files'
    $programData = 'C:\ProgramData'
    $authorizedBinding = New-CommMonitorTestAuthorizedUserBinding
    $components = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')

    It 'rejects a handle-final volume root that contains the other ownership roots' {
        $appRoot = 'C:\AliasVolume'
        $record = & (New-CommMonitorTestPathProbe) $appRoot 1
        $record.FinalPath = 'C:\'
        $record.FileId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $record.NearestExistingAncestor = [pscustomobject][ordered]@{
            RequestedPath = $appRoot; FinalPath = 'C:\'
            VolumeSerial = $record.VolumeSerialNumber; FileId = $record.FileId
        }
        $record.Ancestors = @(
            [pscustomobject][ordered]@{
                RequestedPath = 'C:\'; FinalPath = 'C:\'; VolumeSerial = $record.VolumeSerialNumber
                FileId = Get-CommMonitorTestFileId -Identity 'C:\'; ReparseTag = 0
            },
            [pscustomobject][ordered]@{
                RequestedPath = $appRoot; FinalPath = 'C:\'; VolumeSerial = $record.VolumeSerialNumber
                FileId = $record.FileId; ReparseTag = 0
            })
        $message = try {
            Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record})
            $null
        }
        catch { $_.Exception.Message }
        $message | Should Match 'Physical root alias: CoreRoot and AppRoot candidates overlap'
    }

    It 'rejects a noncanonical uppercase volume serial before identity comparison' {
        $appRoot = 'D:\Uppercase Volume App'
        $record = [pscustomobject]@{ VolumeSerialNumber = '001122334455667A' }
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } | Should Throw
    }

    It 'rejects inconsistent physical identity for the same requested shared ancestor' {
        $appRoot = 'C:\IndependentApp'
        $record = & (New-CommMonitorTestPathProbe) $appRoot 1
        $finalPath = 'D:\IndependentApp'
        $record.FinalPath = $finalPath
        $record.FileId = Get-CommMonitorTestFileId -Identity $finalPath
        $record.NearestExistingAncestor = [pscustomobject][ordered]@{
            RequestedPath = $appRoot; FinalPath = $finalPath
            VolumeSerial = $record.VolumeSerialNumber; FileId = $record.FileId
        }
        $record.Ancestors = @(
            [pscustomobject][ordered]@{
                RequestedPath = 'C:\'; FinalPath = 'D:\'; VolumeSerial = $record.VolumeSerialNumber
                FileId = Get-CommMonitorTestFileId -Identity 'D:\'; ReparseTag = 0
            },
            [pscustomobject][ordered]@{
                RequestedPath = $appRoot; FinalPath = $finalPath; VolumeSerial = $record.VolumeSerialNumber
                FileId = $record.FileId; ReparseTag = 0
            })
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } | Should Throw
    }

    It 'requires an existing target to be its own nearest existing ancestor' {
        $appRoot = 'D:\TargetApp'
        $finalPath = 'D:\PhysicalTargetApp'
        $record = & (New-CommMonitorTestPathProbe) $appRoot 1
        $record.FinalPath = $finalPath
        $record.FileId = Get-CommMonitorTestFileId -Identity $finalPath
        $record.NearestExistingAncestor = [pscustomobject][ordered]@{
            RequestedPath = 'D:\OtherApp'; FinalPath = $finalPath
            VolumeSerial = $record.VolumeSerialNumber; FileId = $record.FileId
        }
        $record.Ancestors = @(
            [pscustomobject][ordered]@{
                RequestedPath = 'D:\'; FinalPath = 'D:\'; VolumeSerial = $record.VolumeSerialNumber
                FileId = Get-CommMonitorTestFileId -Identity 'D:\'; ReparseTag = 0
            },
            [pscustomobject][ordered]@{
                RequestedPath = 'D:\OtherApp'; FinalPath = $finalPath
                VolumeSerial = $record.VolumeSerialNumber; FileId = $record.FileId; ReparseTag = 0
            })
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } | Should Throw
    }

    It 'accepts a fixed-helper proof with a multi-segment unresolved suffix' {
        $appRoot = 'D:\Existing\Child\NewApp'
        $rootId = Get-CommMonitorTestFileId -Identity 'D:\'
        $record = [pscustomobject]@{
            Exists = $false; FinalPath = $null; FileId = $null
            ExistingParentFileId = $rootId
            NearestExistingAncestor = [pscustomobject][ordered]@{
                RequestedPath = 'D:\'; FinalPath = 'D:\'
                VolumeSerial = '0011223344556677'; FileId = $rootId
            }
            UnresolvedSuffix = 'Existing\Child\NewApp'
            Ancestors = @([pscustomobject][ordered]@{
                    RequestedPath = 'D:\'; FinalPath = 'D:\'
                    VolumeSerial = '0011223344556677'; FileId = $rootId; ReparseTag = 0
                })
        }
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } |
            Should Not Throw
    }

    It 'snapshots pass one before a shared probe object is mutated on pass two' {
        $appRoot = 'D:\Shared Probe App'
        $defaultProbe = New-CommMonitorTestPathProbe
        $shared = & $defaultProbe $appRoot 1
        $sharedProbe = {
            param($Path, $Pass)
            if (-not [string]::Equals($Path, $appRoot, [StringComparison]::OrdinalIgnoreCase)) {
                return & $defaultProbe $Path $Pass
            }
            if ($Pass -eq 2) {
                $shared.FileId = 'ffffffffffffffffffffffffffffffff'
                $shared.NearestExistingAncestor.FileId = $shared.FileId
                $shared.Ancestors[$shared.Ancestors.Count - 1].FileId = $shared.FileId
            }
            return $shared
        }.GetNewClosure()
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding -PathProbe $sharedProbe } | Should Throw
    }

    It 'rejects case-confused dictionary fields before ordered conversion can fold them' {
        $sid = 'S-1-5-21-111-222-333-1001'
        $record = [Collections.Generic.Dictionary[string, object]]::new(
            [StringComparer]::Ordinal)
        $record.Add('sid', $sid)
        $record.Add('Sid', $sid)
        $record.Add('ProfileImagePath', 'C:\Users\One')
        $knownFolderProbe = {
            param($requestedSid, $knownFolder)
            [pscustomobject]@{
                Sid = $requestedSid; KnownFolder = $knownFolder
                Path = 'C:\Users\One\AppData\Local'; IdentityVerified = $true
            }
        }
        $sessionProbe = {
            [pscustomobject]@{
                Source = 'WindowsTokenSessionProbe'; OriginalInteractiveSid = $sid
                IdentityVerified = $true
            }
        }.GetNewClosure()
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest `
                    -AuthorizedUserSid $sid -ProfileListRecords @($record) `
                    -KnownFolderProbe $knownFolderProbe -InteractiveSessionProbe $sessionProbe `
                    -AiRelativePath 'LemonSerialMonitor\AI' } `
            -MessagePattern 'case-confused field'
    }

    It 'rejects a coordinated caller-forged identity evidence set' {
        $sid = 'S-1-5-21-111-222-333-500'
        $profile = 'C:\Users\Administrator'
        $knownFolderProbe = {
            param($requestedSid, $knownFolder)
            [pscustomobject]@{
                Sid = $requestedSid; KnownFolder = $knownFolder
                Path = 'C:\Users\Administrator\AppData\Local'; IdentityVerified = $true
            }
        }
        $sessionProbe = {
            [pscustomobject]@{
                Source = 'WindowsTokenSessionProbe'; OriginalInteractiveSid = $sid
                IdentityVerified = $true
            }
        }.GetNewClosure()
        Assert-CommMonitorTestNamedParameterNotFound `
            -Action { Resolve-CommMonitorAuthorizedUser `
                    -AuthorizedUserSid $sid `
                    -ProfileListRecords @([pscustomobject]@{ Sid = $sid; ProfileImagePath = $profile }) `
                    -KnownFolderProbe $knownFolderProbe -InteractiveSessionProbe $sessionProbe `
                    -AiRelativePath 'LemonSerialMonitor\AI' } `
            -ParameterName 'ProfileListRecords' `
            -CommandName 'Resolve-CommMonitorAuthorizedUser'
    }

    It 'rejects a caller-supplied raw path probe without a trusted capability' {
        Assert-CommMonitorTestNamedParameterNotFound `
            -Action { Resolve-CommMonitorOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe) } `
            -ParameterName 'PathProbe' `
            -CommandName 'Resolve-CommMonitorOwnershipRoots'
    }

    It 'rejects a boolean ReparseTag instead of a raw integer tag' {
        $appRoot = 'D:\Boolean Tag App'
        $record = & (New-CommMonitorTestPathProbe) $appRoot 1
        $ancestors = @($record.Ancestors | ForEach-Object { $_.PSObject.Copy() })
        $ancestors[1].ReparseTag = $false
        $record.Ancestors = $ancestors
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } `
            -MessagePattern 'ancestor-chain uses coerced evidence types'
    }

    It 'rejects a non-string path-probe Provider field independently' {
        $appRoot = 'D:\String Provider App'
        $record = [pscustomobject]@{
            Provider = [Text.StringBuilder]::new('FileSystem')
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } `
            -MessagePattern 'AppRoot path probe uses coerced evidence types'
    }

    It 'rejects a non-string path-probe VolumeKind field independently' {
        $appRoot = 'D:\String Volume Kind App'
        $record = [pscustomobject]@{
            VolumeKind = [Text.StringBuilder]::new('Fixed')
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } `
            -MessagePattern 'AppRoot path probe uses coerced evidence types'
    }

    It 'rejects a non-string path-probe volume serial field independently' {
        $appRoot = 'D:\String Volume Serial App'
        $record = [pscustomobject]@{
            VolumeSerialNumber = [Text.StringBuilder]::new('0011223344556677')
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } `
            -MessagePattern 'AppRoot path probe uses coerced evidence types'
    }

    It 'rejects a non-string path-probe requested path field independently' {
        $appRoot = 'D:\String Requested Path App'
        $record = [pscustomobject]@{
            RequestedPath = [Text.StringBuilder]::new($appRoot)
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } `
            -MessagePattern 'AppRoot path probe uses coerced evidence types'
    }

    It 'rejects a non-string existing target FileId field independently' {
        $appRoot = 'D:\String File Id App'
        $record = [pscustomobject]@{
            FileId = [Text.StringBuilder]::new(
                (Get-CommMonitorTestFileId -Identity $appRoot))
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } `
            -MessagePattern 'AppRoot path probe uses coerced evidence types'
    }

    It 'accepts an existing target only with FileId and no parent FileId' {
        $appRoot = 'D:\Mutually Exclusive Existing Id'
        $record = [pscustomobject]@{ ExistingParentFileId = $null }
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                -AuthorizedUserBinding $authorizedBinding `
                -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } |
            Should Not Throw
    }

    It 'rejects an existing target that also carries a parent FileId' {
        $appRoot = 'D:\Ambiguous Existing Id'
        $record = [pscustomobject]@{
            ExistingParentFileId = 'ffeeddccbbaa99887766554433221100'
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } `
            -MessagePattern 'existing target must not carry ExistingParentFileId'
    }

    It 'rejects a nonexistent target that also carries a target FileId' {
        $appRoot = 'D:\Ambiguous Missing Id'
        $record = [pscustomobject]@{
            Exists = $false
            FileId = 'ffffffffffffffffffffffffffffffff'
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } `
            -MessagePattern 'nonexistent target must not carry FileId'
    }

    It 'rejects a non-array ancestor-chain container' {
        $appRoot = 'D:\List Ancestors App'
        $record = & (New-CommMonitorTestPathProbe) $appRoot 1
        $list = [Collections.Generic.List[object]]::new()
        foreach ($ancestor in @($record.Ancestors)) { $list.Add($ancestor) }
        $record.Ancestors = $list
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } `
            -MessagePattern 'ancestor-chain.*container must be an array'
    }

    It 'rejects a non-integer ancestor reparse tag independently' {
        $appRoot = 'D:\String Tag App'
        $record = & (New-CommMonitorTestPathProbe) $appRoot 1
        $record.Ancestors[1].ReparseTag = [Text.StringBuilder]::new('0')
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -AppRoot $appRoot -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{$appRoot = $record}) } `
            -MessagePattern 'ancestor-chain uses coerced evidence types'
    }

    It 'rejects a non-string protected ACL owner SID' {
        $coreRoot = 'C:\Program Files\CommMonitor'
        $acl = New-CommMonitorTestProtectedAclProfile
        $acl.OwnerSid = [Text.StringBuilder]::new('S-1-5-18')
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{
                            $coreRoot = [pscustomobject]@{ AclProfile = $acl }
                        }) } `
            -MessagePattern 'ACL profile uses coerced evidence types'
    }

    It 'rejects a non-string protected ACL allowed SID element' {
        $coreRoot = 'C:\Program Files\CommMonitor'
        $acl = New-CommMonitorTestProtectedAclProfile
        $acl.AllowedFullControlSids = @(
            [Text.StringBuilder]::new('S-1-5-18'),
            'S-1-5-32-544')
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{
                            $coreRoot = [pscustomobject]@{ AclProfile = $acl }
                        }) } `
            -MessagePattern 'ACL profile uses coerced evidence types'
    }

    It 'rejects a non-array protected ACL allowed SID container' {
        $coreRoot = 'C:\Program Files\CommMonitor'
        $acl = New-CommMonitorTestProtectedAclProfile
        $sidList = [Collections.Generic.List[string]]::new()
        $sidList.Add('S-1-5-18')
        $sidList.Add('S-1-5-32-544')
        $acl.AllowedFullControlSids = $sidList
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 -PlatformComponents $components `
                    -ProgramFilesPath $programFiles -ProgramDataPath $programData `
                    -AuthorizedUserBinding $authorizedBinding `
                    -PathProbe (New-CommMonitorTestPathProbe @{
                            $coreRoot = [pscustomobject]@{ AclProfile = $acl }
                        }) } `
            -MessagePattern 'ACL profile uses coerced evidence types'
    }
}

Describe 'CommMonitor DataRoot adoption gate' {
    It 'adopts a nonempty DataRoot only from a validated legacy marker in Migrate mode' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        $markerId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $aclProfile = New-CommMonitorTestProtectedAclProfile
        $marker = [ordered]@{
            schemaVersion = 1
            markerId = $markerId
            canonicalPath = $dataRoot
            volumeSerialNumber = '0011223344556677'
            fileId = Get-CommMonitorTestFileId -Identity $dataRoot
            aclProfile = $aclProfile
            ownershipProof = 'VerifiedLegacyAdoption'
        }
        $markerJson = ConvertTo-CommMonitorCanonicalJson -InputObject $marker
        $markerDigest = Get-CommMonitorTestSha256Hex -Text $markerJson
        $protectedProbe = {
            param($expectedPath)
            [pscustomobject][ordered]@{
                Source = 'ProtectedLegacyMarkerProbe'
                IdentityVerified = $true
                Marker = $marker
                ProtectedExpectedDigest = $markerDigest
            }
        }.GetNewClosure()
        $authorizedBinding = New-CommMonitorTestAuthorizedUserBinding `
            -LegacyMarkerProbe $protectedProbe
        $validatedMarker = Assert-CommMonitorLegacyDataRootMarker `
            -ExpectedDataRootPath $dataRoot `
            -AuthorizedUserBinding $authorizedBinding
        $evidence = New-CommMonitorDataRootAdoptionEvidence `
            -SourceKind ValidatedLegacyMarker `
            -ValidatedLegacyMarker $validatedMarker

        $dataProbe = [pscustomobject]@{
            IsEmpty = $false
            InstallIdMarker = $markerId
        }
        $roots = Resolve-CommMonitorTestOwnershipRoots `
            -PlatformKind Desktop `
            -PlatformBuild 22631 `
            -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
            -ProgramFilesPath 'C:\Program Files' `
            -ProgramDataPath 'C:\ProgramData' `
            -AuthorizedUserBinding $authorizedBinding `
            -PathProbe (New-CommMonitorTestPathProbe @{$dataRoot = $dataProbe}) `
            -InstallMode Migrate `
            -DataRootAdoptionEvidence $evidence

        $roots.DataRoot.OwnershipProof | Should Be 'VerifiedLegacyAdoption'
        $roots.DataRoot.AdoptionSource.sourceKind | Should Be 'ValidatedLegacyMarker'
        $roots.DataRoot.AdoptionSource.markerId | Should Be $markerId
    }

    It 'rejects a nonempty DataRoot in Fresh mode' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding (New-CommMonitorTestAuthorizedUserBinding) `
                -PathProbe (New-CommMonitorTestPathProbe @{
                        $dataRoot = [pscustomobject]@{ IsEmpty = $false }
                    }) `
                -InstallMode Fresh } | Should Throw
    }

    It 'rejects a nonempty DataRoot in Migrate mode without evidence' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding (New-CommMonitorTestAuthorizedUserBinding) `
                -PathProbe (New-CommMonitorTestPathProbe @{
                        $dataRoot = [pscustomobject]@{ IsEmpty = $false }
                    }) `
                -InstallMode Migrate } | Should Throw
    }

    It 'rejects a boolean verified flag in place of registered adoption evidence' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding (New-CommMonitorTestAuthorizedUserBinding) `
                -PathProbe (New-CommMonitorTestPathProbe @{
                        $dataRoot = [pscustomobject]@{ IsEmpty = $false }
                    }) `
                -InstallMode Migrate `
                -DataRootAdoptionEvidence $true } | Should Throw
    }

    It 'rejects adoption evidence bound to a different canonical path' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        $bundle = New-CommMonitorTestLegacyAdoptionEvidence `
            -DataRoot 'D:\Legacy\CommMonitor'
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding $bundle.Binding `
                -PathProbe (New-CommMonitorTestPathProbe @{
                        $dataRoot = [pscustomobject]@{
                            IsEmpty = $false
                            InstallIdMarker = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
                        }
                    }) -InstallMode Migrate -DataRootAdoptionEvidence $bundle.Evidence } | Should Throw
    }

    It 'rejects adoption evidence whose volume differs from the live DataRoot' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        $bundle = New-CommMonitorTestLegacyAdoptionEvidence `
            -VolumeSerialNumber '8899aabbccddeeff'
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorTestOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 `
                    -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                    -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                    -AuthorizedUserBinding $bundle.Binding `
                    -PathProbe (New-CommMonitorTestPathProbe @{
                            $dataRoot = [pscustomobject]@{
                                IsEmpty = $false
                                InstallIdMarker = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
                            }
                        }) -InstallMode Migrate `
                    -DataRootAdoptionEvidence $bundle.Evidence } `
            -MessagePattern 'does not match the live root identity'
    }

    It 'rejects adoption evidence whose file ID differs from the live DataRoot' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        $bundle = New-CommMonitorTestLegacyAdoptionEvidence
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding $bundle.Binding `
                -PathProbe (New-CommMonitorTestPathProbe @{
                        $dataRoot = [pscustomobject]@{
                            IsEmpty = $false
                            FileId = 'ffffffffffffffffffffffffffffffff'
                            InstallIdMarker = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
                        }
                    }) -InstallMode Migrate -DataRootAdoptionEvidence $bundle.Evidence } | Should Throw
    }

    It 'rejects adoption evidence whose ACL differs from the trusted live DataRoot ACL' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        $bundle = New-CommMonitorTestLegacyAdoptionEvidence
        $alternateProtectedAcl = [pscustomobject][ordered]@{
            OwnerSid = 'S-1-5-32-544'
            AreAccessRulesProtected = $true
            AllowedFullControlSids = @('S-1-5-18', 'S-1-5-32-544')
            DenyRuleCount = 0
            UsersWritable = $false
        }
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding $bundle.Binding `
                -PathProbe (New-CommMonitorTestPathProbe @{
                        $dataRoot = [pscustomobject]@{
                            IsEmpty = $false
                            AclProfile = $alternateProtectedAcl
                            InstallIdMarker = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
                        }
                    }) -InstallMode Migrate -DataRootAdoptionEvidence $bundle.Evidence } | Should Throw
    }

    It 'rejects adoption evidence whose install marker differs from the live DataRoot' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        $bundle = New-CommMonitorTestLegacyAdoptionEvidence
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding $bundle.Binding `
                -PathProbe (New-CommMonitorTestPathProbe @{
                        $dataRoot = [pscustomobject]@{
                            IsEmpty = $false
                            InstallIdMarker = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
                        }
                    }) -InstallMode Migrate -DataRootAdoptionEvidence $bundle.Evidence } | Should Throw
    }

    It 'rejects valid DataRoot proof when another ownership root is nonempty' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        $appRoot = 'C:\Program Files\Lemon串口监控'
        $bundle = New-CommMonitorTestLegacyAdoptionEvidence
        $overrides = @{
            $dataRoot = [pscustomobject]@{
                IsEmpty = $false
                InstallIdMarker = $bundle.Marker.markerId
            }
            $appRoot = [pscustomobject]@{ IsEmpty = $false }
        }
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding $bundle.Binding `
                -PathProbe (New-CommMonitorTestPathProbe $overrides) `
                -InstallMode Migrate -DataRootAdoptionEvidence $bundle.Evidence } | Should Throw
    }

    It 'rejects fake adoption evidence for an empty DataRoot' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        $bundle = New-CommMonitorTestLegacyAdoptionEvidence
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding $bundle.Binding `
                -PathProbe (New-CommMonitorTestPathProbe @{
                        $dataRoot = [pscustomobject]@{
                            IsEmpty = $true
                            InstallIdMarker = $bundle.Marker.markerId
                        }
                    }) -InstallMode Migrate -DataRootAdoptionEvidence $bundle.Evidence } |
            Should Throw
    }

    It 'rejects a caller-forged marker and matching digest that bypassed the trusted probe' {
        $bundle = New-CommMonitorTestLegacyAdoptionEvidence
        $forged = $bundle.ValidatedMarker.PSObject.Copy()
        { New-CommMonitorDataRootAdoptionEvidence `
                -SourceKind ValidatedLegacyMarker `
                -ValidatedLegacyMarker $forged } | Should Throw
    }

    It 'rejects a registered legacy-marker result after self-consistent mutation' {
        $bundle = New-CommMonitorTestLegacyAdoptionEvidence
        $bundle.ValidatedMarker.markerId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        $bundle.ValidatedMarker.canonicalPath = 'D:\Other\CommMonitor'
        $bundle.ValidatedMarker.volumeSerialNumber = '8899aabbccddeeff'
        $bundle.ValidatedMarker.fileId = 'ffffffffffffffffffffffffffffffff'
        { New-CommMonitorDataRootAdoptionEvidence `
                -SourceKind ValidatedLegacyMarker `
                -ValidatedLegacyMarker $bundle.ValidatedMarker } | Should Throw
    }

    It 'rejects registered adoption evidence after self-consistent mutation' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        $bundle = New-CommMonitorTestLegacyAdoptionEvidence
        $bundle.Evidence.markerId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        $bundle.Evidence.markerDigest = ('a' * 64)
        $bundle.Evidence.canonicalPath = 'D:\Other\CommMonitor'
        $bundle.Evidence.volumeSerialNumber = '8899aabbccddeeff'
        $bundle.Evidence.fileId = 'ffffffffffffffffffffffffffffffff'
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding $bundle.Binding `
                -PathProbe (New-CommMonitorTestPathProbe @{
                        $dataRoot = [pscustomobject]@{
                            IsEmpty = $false
                            VolumeSerialNumber = '8899aabbccddeeff'
                            FileId = 'ffffffffffffffffffffffffffffffff'
                            InstallIdMarker = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
                        }
                    }) -InstallMode Migrate -DataRootAdoptionEvidence $bundle.Evidence } |
            Should Throw
    }

    It 'rejects a stable users-writable DataRoot even with otherwise valid adoption proof' {
        $dataRoot = 'C:\ProgramData\CommMonitor'
        $bundle = New-CommMonitorTestLegacyAdoptionEvidence
        $usersWritableAcl = [pscustomobject][ordered]@{
            OwnerSid = 'S-1-5-32-545'
            AreAccessRulesProtected = $false
            AllowedFullControlSids = @('S-1-5-32-545')
            DenyRuleCount = 0
            UsersWritable = $true
        }
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding $bundle.Binding `
                -PathProbe (New-CommMonitorTestPathProbe @{
                        $dataRoot = [pscustomobject]@{
                            IsEmpty = $false; AclProfile = $usersWritableAcl
                            InstallIdMarker = $bundle.Marker.markerId
                        }
                    }) -InstallMode Migrate -DataRootAdoptionEvidence $bundle.Evidence } |
            Should Throw
    }

    It 'rejects a users-writable CoreRoot ACL even when the root is empty' {
        $coreRoot = 'C:\Program Files\CommMonitor'
        $usersWritableAcl = [pscustomobject][ordered]@{
            OwnerSid = 'S-1-5-32-545'; AreAccessRulesProtected = $false
            AllowedFullControlSids = @('S-1-5-32-545'); DenyRuleCount = 0
            UsersWritable = $true
        }
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding (New-CommMonitorTestAuthorizedUserBinding) `
                -PathProbe (New-CommMonitorTestPathProbe @{
                        $coreRoot = [pscustomobject]@{ AclProfile = $usersWritableAcl }
                    }) } | Should Throw
    }

    It 'rejects a users-writable InstallerRoot ACL even when the root is empty' {
        $installerRoot = 'C:\ProgramData\LemonSerialMonitor\Installer'
        $usersWritableAcl = [pscustomobject][ordered]@{
            OwnerSid = 'S-1-5-32-545'; AreAccessRulesProtected = $false
            AllowedFullControlSids = @('S-1-5-32-545'); DenyRuleCount = 0
            UsersWritable = $true
        }
        { Resolve-CommMonitorTestOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding (New-CommMonitorTestAuthorizedUserBinding) `
                -PathProbe (New-CommMonitorTestPathProbe @{
                        $installerRoot = [pscustomobject]@{ AclProfile = $usersWritableAcl }
                    }) } | Should Throw
    }

    It 'does not expose the former global AllowExistingContent bypass' {
        { Resolve-CommMonitorOwnershipRoots `
                -PlatformKind Desktop -PlatformBuild 22631 `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -ProgramFilesPath 'C:\Program Files' -ProgramDataPath 'C:\ProgramData' `
                -AuthorizedUserBinding (New-CommMonitorTestAuthorizedUserBinding) `
                -PathProbe (New-CommMonitorTestPathProbe) `
                -AllowExistingContent } | Should Throw
    }
}

Describe 'CommMonitor authorized interactive user binding' {
    It 'binds ProfileList data for the original SID instead of the elevated administrator' {
        $originalSid = 'S-1-5-21-111-222-333-1001'
        $administratorSid = 'S-1-5-21-111-222-333-500'
        $records = @(
            [pscustomobject]@{
                Sid = $administratorSid
                ProfileListKeyPath =
                    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$administratorSid"
                ProfileImagePath = 'C:\Users\Administrator'
                ProfileImagePathValueKind = 'String'
            },
            [pscustomobject]@{
                Sid = $originalSid
                ProfileListKeyPath =
                    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$originalSid"
                ProfileImagePath = 'C:\Users\测试 用户'
                ProfileImagePathValueKind = 'String'
            })
        $knownFolderProbe = {
            param($sid, $knownFolder)
            if ($sid -ne $originalSid -or $knownFolder -ne 'LocalAppData') {
                throw 'The resolver probed the wrong user or Known Folder.'
            }
            [pscustomobject]@{
                Sid = $sid
                KnownFolder = $knownFolder
                KnownFolderId = '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}'
                Path = 'C:\Users\测试 用户\AppData\Local'
                IdentityVerified = $true
            }
        }.GetNewClosure()
        $interactiveSessionProbe = {
            [pscustomobject]@{
                Source = 'WindowsTokenSessionProbe'
                OriginalInteractiveSid = $originalSid
                IdentityVerified = $true
            }
        }.GetNewClosure()

        $bound = Resolve-CommMonitorAuthorizedUserForTest `
            -AuthorizedUserSid $originalSid `
            -ProfileListRecords $records `
            -KnownFolderProbe $knownFolderProbe `
            -InteractiveSessionProbe $interactiveSessionProbe `
            -AiRelativePath 'LemonSerialMonitor\AI'

        $bound.Sid | Should Be $originalSid
        $bound.ProfileImagePath | Should Be 'C:\Users\测试 用户'
        $bound.LocalAppDataPath | Should Be 'C:\Users\测试 用户\AppData\Local'
        $bound.AiRoot | Should Be 'C:\Users\测试 用户\AppData\Local\LemonSerialMonitor\AI'
    }

    It 'rejects a missing ProfileListKeyPath audit field' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -RemoveProfileFields ProfileListKeyPath
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern "ProfileList record is missing required field 'ProfileListKeyPath'"
    }

    It 'rejects an extra ProfileList audit field' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -ProfileOverrides @{ ProfileHive = 'HKU' }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern "ProfileList record contains unknown field 'ProfileHive'"
    }

    It 'rejects a ProfileListKeyPath for another registry key' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -ProfileOverrides @{
                ProfileListKeyPath =
                    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\S-1-5-21-111-222-333-1002'
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'exact authorized SID registry key'
    }

    It 'rejects a missing KnownFolderId audit field' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -RemoveKnownFolderFields KnownFolderId
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern "Known Folder evidence is missing required field 'KnownFolderId'"
    }

    It 'rejects an extra Known Folder audit field' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -KnownFolderOverrides @{ Api = 'SHGetKnownFolderPath' }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern "Known Folder evidence contains unknown field 'Api'"
    }

    It 'rejects a noncanonical LocalAppData KnownFolderId' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -KnownFolderOverrides @{
                KnownFolderId = '{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}'
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'Known Folder evidence is not bound to the authorized SID'
    }

    It 'rejects a Known Folder audit SID different from the authorized SID' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -KnownFolderOverrides @{
                Sid = 'S-1-5-21-111-222-333-1002'
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'Known Folder evidence is not bound to the authorized SID'
    }

    It 'accepts a token-verified redirected LocalAppData Known Folder path' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -KnownFolderOverrides @{ Path = 'D:\Redirected Local App Data' }
        $binding = Resolve-CommMonitorAuthorizedUserForTest @arguments
        $binding.LocalAppDataPath | Should Be 'D:\Redirected Local App Data'
        $binding.AiRoot | Should Be 'D:\Redirected Local App Data\LemonSerialMonitor\AI'
    }

    It 'rejects an unverified redirected LocalAppData Known Folder path' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -KnownFolderOverrides @{
                Path = 'D:\Unverified Local App Data'
                IdentityVerified = $false
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'Known Folder evidence is not bound to the authorized SID'
    }

    It 'rejects a non-string ProfileList Sid evidence value' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -ProfileOverrides @{
                Sid = [Text.StringBuilder]::new('S-1-5-21-111-222-333-1001')
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'ProfileList record values must be raw strings'
    }

    It 'rejects a non-string ProfileListKeyPath evidence value' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -ProfileOverrides @{
                ProfileListKeyPath = [Text.StringBuilder]::new(
                    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\S-1-5-21-111-222-333-1001')
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'ProfileList record values must be raw strings'
    }

    It 'rejects a non-string ProfileImagePath evidence value' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -ProfileOverrides @{
                ProfileImagePath = [Text.StringBuilder]::new('C:\Users\One')
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'ProfileList record values must be raw strings'
    }

    It 'rejects a missing ProfileImagePath Registry64 value kind' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -RemoveProfileFields ProfileImagePathValueKind
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern "ProfileList record is missing required field 'ProfileImagePathValueKind'"
    }

    It 'rejects a non-string ProfileImagePath Registry64 value kind' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -ProfileOverrides @{ ProfileImagePathValueKind = [int]1 }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'ProfileList record values must be raw strings'
    }

    It 'rejects an unsupported ProfileImagePath Registry64 value kind' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -ProfileOverrides @{ ProfileImagePathValueKind = 'DWord' }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'unsupported Registry64 value kind'
    }

    It 'preserves raw ExpandString metadata and accepts only token-bound expansion evidence' {
        $sid = 'S-1-5-21-111-222-333-1001'
        $rawPath = '%SystemDrive%\Users\One'
        $expansionProbe = {
            param($requestedSid, $requestedRawPath)
            [pscustomobject][ordered]@{
                Source = 'ExpandEnvironmentStringsForUserW'
                Sid = $requestedSid
                RawValue = $requestedRawPath
                Path = 'C:\Users\One'
                IdentityVerified = $true
            }
        }
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -ProfileOverrides @{
                ProfileImagePath = $rawPath
                ProfileImagePathValueKind = 'ExpandString'
            } `
            -ProfilePathExpansionProbe $expansionProbe
        $binding = Resolve-CommMonitorAuthorizedUserForTest @arguments
        $binding.ProfileImagePathRaw | Should Be $rawPath
        $binding.ProfileImagePathValueKind | Should Be 'ExpandString'
        $binding.ProfileImagePath | Should Be 'C:\Users\One'
        $binding.ProfileExpansionSid | Should Be $sid
    }

    It 'rejects profile expansion evidence from another API source' {
        $expansionProbe = {
            param($requestedSid, $requestedRawPath)
            [pscustomobject][ordered]@{
                Source = 'Environment.ExpandEnvironmentVariables'
                Sid = $requestedSid; RawValue = $requestedRawPath
                Path = 'C:\Users\One'; IdentityVerified = $true
            }
        }
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -ProfilePathExpansionProbe $expansionProbe
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'expansion evidence is not bound to the authorized user token'
    }

    It 'rejects profile expansion evidence for another SID' {
        $expansionProbe = {
            param($requestedSid, $requestedRawPath)
            [pscustomobject][ordered]@{
                Source = 'ExpandEnvironmentStringsForUserW'
                Sid = 'S-1-5-21-111-222-333-1002'; RawValue = $requestedRawPath
                Path = 'C:\Users\One'; IdentityVerified = $true
            }
        }
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -ProfilePathExpansionProbe $expansionProbe
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'expansion evidence is not bound to the authorized user token'
    }

    It 'rejects profile expansion evidence for another raw registry value' {
        $expansionProbe = {
            param($requestedSid, $requestedRawPath)
            [pscustomobject][ordered]@{
                Source = 'ExpandEnvironmentStringsForUserW'
                Sid = $requestedSid; RawValue = 'C:\Attacker'
                Path = 'C:\Users\One'; IdentityVerified = $true
            }
        }
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -ProfilePathExpansionProbe $expansionProbe
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'expansion evidence is not bound to the authorized user token'
    }

    It 'rejects profile expansion evidence without positive token verification' {
        $expansionProbe = {
            param($requestedSid, $requestedRawPath)
            [pscustomobject][ordered]@{
                Source = 'ExpandEnvironmentStringsForUserW'
                Sid = $requestedSid; RawValue = $requestedRawPath
                Path = 'C:\Users\One'; IdentityVerified = $false
            }
        }
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -ProfilePathExpansionProbe $expansionProbe
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'expansion evidence is not bound to the authorized user token'
    }

    It 'accepts a canonical Azure AD ProfileList user SID' {
        $sid = 'S-1-12-1-111-222-333-444'
        $profile = 'C:\Users\AzureUser'
        $knownFolderProbe = {
            param($requestedSid, $knownFolder)
            [pscustomobject][ordered]@{
                Sid = $requestedSid; KnownFolder = $knownFolder
                KnownFolderId = '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}'
                Path = 'D:\Azure LocalAppData'; IdentityVerified = $true
            }
        }
        $sessionProbe = {
            [pscustomobject][ordered]@{
                Source = 'WindowsTokenSessionProbe'; OriginalInteractiveSid = $sid
                IdentityVerified = $true
            }
        }.GetNewClosure()
        $binding = Resolve-CommMonitorAuthorizedUserForTest `
            -AuthorizedUserSid $sid `
            -ProfileListRecords @([pscustomobject][ordered]@{
                    Sid = $sid
                    ProfileListKeyPath =
                        "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
                    ProfileImagePath = $profile
                    ProfileImagePathValueKind = 'String'
                }) `
            -KnownFolderProbe $knownFolderProbe `
            -InteractiveSessionProbe $sessionProbe `
            -AiRelativePath 'LemonSerialMonitor\AI'
        $binding.Sid | Should Be $sid
        $binding.LocalAppDataPath | Should Be 'D:\Azure LocalAppData'
    }

    It 'rejects the LocalSystem well-known SID as a profile user' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments
        $arguments.AuthorizedUserSid = 'S-1-5-18'
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'profile user'
    }

    It 'rejects a service SID as a profile user' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments
        $arguments.AuthorizedUserSid = 'S-1-5-80-1-2-3-4-5'
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'profile user'
    }

    It 'rejects a logon SID as a profile user' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments
        $arguments.AuthorizedUserSid = 'S-1-5-5-1-2'
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'profile user'
    }

    It 'rejects a non-string session Source evidence value' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -SessionOverrides @{
                Source = [Text.StringBuilder]::new('WindowsTokenSessionProbe')
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'not the independently verified original interactive SID'
    }

    It 'rejects a non-string session SID evidence value' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -SessionOverrides @{
                OriginalInteractiveSid =
                    [Text.StringBuilder]::new('S-1-5-21-111-222-333-1001')
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'not the independently verified original interactive SID'
    }

    It 'rejects a non-string Known Folder Sid evidence value' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -KnownFolderOverrides @{
                Sid = [Text.StringBuilder]::new('S-1-5-21-111-222-333-1001')
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'Known Folder evidence is not bound to the authorized SID'
    }

    It 'rejects a non-string Known Folder name evidence value' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -KnownFolderOverrides @{
                KnownFolder = [Text.StringBuilder]::new('LocalAppData')
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'Known Folder evidence is not bound to the authorized SID'
    }

    It 'rejects a non-string KnownFolderId evidence value' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -KnownFolderOverrides @{
                KnownFolderId = [Text.StringBuilder]::new(
                    '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}')
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'Known Folder evidence is not bound to the authorized SID'
    }

    It 'rejects a non-string Known Folder Path evidence value' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments `
            -KnownFolderOverrides @{
                Path = [Text.StringBuilder]::new('C:\Users\One\AppData\Local')
            }
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'Known Folder evidence is not bound to the authorized SID'
    }

    It 'rejects a regex-shaped SID that is not in canonical SecurityIdentifier form' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments
        $noncanonicalSid = 'S-1-5-21-000000111-222-333-1001'
        $arguments.AuthorizedUserSid = $noncanonicalSid
        $arguments.ProfileListRecords[0].Sid = $noncanonicalSid
        $arguments.ProfileListRecords[0].ProfileListKeyPath =
            "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$noncanonicalSid"
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'canonical Windows SecurityIdentifier'
    }

    It 'rejects a regex-shaped SID with an out-of-range subauthority' {
        $arguments = New-CommMonitorTestAuthorizedUserArguments
        $invalidSid = 'S-1-5-21-4294967296-222-333-1001'
        $arguments.AuthorizedUserSid = $invalidSid
        $arguments.ProfileListRecords[0].Sid = $invalidSid
        $arguments.ProfileListRecords[0].ProfileListKeyPath =
            "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$invalidSid"
        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUserForTest @arguments } `
            -MessagePattern 'canonical Windows SecurityIdentifier'
    }

    It 'rejects UAC-other-admin missing duplicate and untrusted bindings' {
        $sid = 'S-1-5-21-111-222-333-1001'
        $adminSid = 'S-1-5-21-111-222-333-500'
        $record = [pscustomobject]@{
            Sid = $sid
            ProfileListKeyPath =
                "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
            ProfileImagePath = 'C:\Users\One'
            ProfileImagePathValueKind = 'String'
        }
        $trustedProbe = {
            param($requestedSid, $knownFolder)
            [pscustomobject]@{
                Sid = $requestedSid
                KnownFolder = $knownFolder
                KnownFolderId = '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}'
                Path = 'C:\Users\One\AppData\Local'
                IdentityVerified = $true
            }
        }
        $sessionProbe = {
            [pscustomobject]@{
                Source = 'WindowsTokenSessionProbe'
                OriginalInteractiveSid = $sid
                IdentityVerified = $true
            }
        }.GetNewClosure()

        $cases = @(
            @{
                Name = 'elevated administrator substituted for original user'
                Arguments = @{
                    AuthorizedUserSid = $adminSid
                    ProfileListRecords = @(
                        $record,
                        [pscustomobject]@{
                            Sid = $adminSid
                            ProfileListKeyPath =
                                "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$adminSid"
                            ProfileImagePath = 'C:\Users\Administrator'
                            ProfileImagePathValueKind = 'String'
                        })
                    KnownFolderProbe = $trustedProbe
                    InteractiveSessionProbe = $sessionProbe
                    AiRelativePath = 'LemonSerialMonitor\AI'
                }
            },
            @{
                Name = 'missing ProfileList record'
                Arguments = @{
                    AuthorizedUserSid = $sid
                    ProfileListRecords = @()
                    KnownFolderProbe = $trustedProbe
                    InteractiveSessionProbe = $sessionProbe
                    AiRelativePath = 'LemonSerialMonitor\AI'
                }
            },
            @{
                Name = 'duplicate ProfileList record'
                Arguments = @{
                    AuthorizedUserSid = $sid
                    ProfileListRecords = @($record, $record.PSObject.Copy())
                    KnownFolderProbe = $trustedProbe
                    InteractiveSessionProbe = $sessionProbe
                    AiRelativePath = 'LemonSerialMonitor\AI'
                }
            },
            @{
                Name = 'redirected LocalAppData is not token verified'
                Arguments = @{
                    AuthorizedUserSid = $sid
                    ProfileListRecords = @($record)
                    KnownFolderProbe = {
                        param($requestedSid, $knownFolder)
                        [pscustomobject]@{
                            Sid = $requestedSid
                            KnownFolder = $knownFolder
                            KnownFolderId = '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}'
                            Path = 'C:\Users\One\Other'
                            IdentityVerified = $false
                        }
                    }
                    InteractiveSessionProbe = $sessionProbe
                    AiRelativePath = 'LemonSerialMonitor\AI'
                }
            },
            @{
                Name = 'Known Folder identity does not match requested SID'
                Arguments = @{
                    AuthorizedUserSid = $sid
                    ProfileListRecords = @($record)
                    KnownFolderProbe = {
                        param($requestedSid, $knownFolder)
                        [pscustomobject]@{
                            Sid = 'S-1-5-21-111-222-333-1002'
                            KnownFolder = $knownFolder
                            KnownFolderId = '{f1b32785-6fba-4fcf-9d55-7b8e7f157091}'
                            Path = 'C:\Users\One\AppData\Local'
                            IdentityVerified = $true
                        }
                    }
                    InteractiveSessionProbe = $sessionProbe
                    AiRelativePath = 'LemonSerialMonitor\AI'
                }
            },
            @{
                Name = 'wrong AI subpath'
                Arguments = @{
                    AuthorizedUserSid = $sid
                    ProfileListRecords = @($record)
                    KnownFolderProbe = $trustedProbe
                    InteractiveSessionProbe = $sessionProbe
                    AiRelativePath = 'LemonSerialMonitor\AI\Other'
                }
            },
            @{
                Name = 'session probe is not positively verified'
                Arguments = @{
                    AuthorizedUserSid = $sid
                    ProfileListRecords = @($record)
                    KnownFolderProbe = $trustedProbe
                    InteractiveSessionProbe = {
                        [pscustomobject]@{
                            Source = 'WindowsTokenSessionProbe'
                            OriginalInteractiveSid = $sid
                            IdentityVerified = $false
                        }
                    }.GetNewClosure()
                    AiRelativePath = 'LemonSerialMonitor\AI'
                }
            },
            @{
                Name = 'session probe has extra evidence fields'
                Arguments = @{
                    AuthorizedUserSid = $sid
                    ProfileListRecords = @($record)
                    KnownFolderProbe = $trustedProbe
                    InteractiveSessionProbe = {
                        [pscustomobject]@{
                            Source = 'WindowsTokenSessionProbe'
                            OriginalInteractiveSid = $sid
                            IdentityVerified = $true
                            ElevatedSid = 'S-1-5-21-111-222-333-500'
                        }
                    }.GetNewClosure()
                    AiRelativePath = 'LemonSerialMonitor\AI'
                }
            })

        foreach ($case in $cases) {
            $message = try {
                $arguments = $case.Arguments
                Resolve-CommMonitorAuthorizedUserForTest @arguments
                $null
            }
            catch {
                $_.Exception.Message
            }
            $message | Should Not BeNullOrEmpty
            $message | Should Not Match 'is not recognized as the name of a cmdlet'
        }
    }
}

Describe 'CommMonitor canonical ownership schema' {
    It 'serializes dictionaries deterministically with ordinal keys and exact escapes' {
        $first = [ordered]@{
            z = 2
            text = "串口`n监控"
            nested = [ordered]@{ b = $null; a = $true }
            a = 'first'
        }
        $second = [ordered]@{
            a = 'first'
            nested = [ordered]@{ a = $true; b = $null }
            text = "串口`n监控"
            z = 2
        }

        $firstJson = ConvertTo-CommMonitorCanonicalJson -InputObject $first
        $secondJson = ConvertTo-CommMonitorCanonicalJson -InputObject $second

        $firstJson | Should Be '{"a":"first","nested":{"a":true,"b":null},"text":"串口\n监控","z":2}'
        $secondJson | Should Be $firstJson
        $firstJson.Contains("`r") | Should Be $false
        ([Text.UTF8Encoding]::new($false).GetPreamble().Length) | Should Be 0
    }

    It 'round-trips strict JSON and rejects duplicate case-confused and unknown fields' {
        $parsed = ConvertFrom-CommMonitorStrictJson `
            -Json '{"integrity":{"algorithm":"HMAC-SHA256"},"payload":{"revision":1},"schemaVersion":3}' `
            -AllowedRootFields @('integrity', 'payload', 'schemaVersion')

        $parsed.schemaVersion | Should Be 3
        $parsed.payload.revision | Should Be 1

        foreach ($badJson in @(
                '{"schemaVersion":3,"schemaVersion":3}',
                '{"schemaVersion":3,"SchemaVersion":3}',
                '{"schemaVersion":3,"unknown":true}')) {
            { ConvertFrom-CommMonitorStrictJson `
                    -Json $badJson `
                    -AllowedRootFields @('schemaVersion') } | Should Throw
        }
    }

    It 'accepts only the four RFC 8259 whitespace code points outside strings' {
        foreach ($codePoint in @(0x20, 0x09, 0x0a, 0x0d)) {
            $whitespace = [string][char]$codePoint
            $json = $whitespace + '{' + $whitespace + '"value"' +
                $whitespace + ':' + $whitespace + '1' + $whitespace + '}' +
                $whitespace
            $parsed = ConvertFrom-CommMonitorStrictJson `
                -Json $json `
                -AllowedRootFields @('value')
            $parsed.value | Should Be 1

            $primitiveDelimiter = '{"value":1' + $whitespace + '}'
            $parsedDelimiter = ConvertFrom-CommMonitorStrictJson `
                -Json $primitiveDelimiter `
                -AllowedRootFields @('value')
            $parsedDelimiter.value | Should Be 1
        }
    }

    It 'rejects non-RFC whitespace before an authoritative JSON object' {
        foreach ($codePoint in @(0x000b, 0x000c, 0x0085, 0x00a0, 0xfeff)) {
            $invalid = [string][char]$codePoint
            Assert-CommMonitorTestThrowsExactly `
                -Action {
                    ConvertFrom-CommMonitorStrictJson `
                        -Json ($invalid + '{"value":1}') `
                        -AllowedRootFields @('value')
                } `
                -Message 'Strict JSON requires an object root.'
        }
    }

    It 'rejects non-RFC whitespace between authoritative JSON tokens' {
        foreach ($codePoint in @(0x000b, 0x000c, 0x0085, 0x00a0, 0xfeff)) {
            $invalid = [string][char]$codePoint
            Assert-CommMonitorTestThrowsExactly `
                -Action {
                    ConvertFrom-CommMonitorStrictJson `
                        -Json ('{"value"' + $invalid + ':1}') `
                        -AllowedRootFields @('value')
                } `
                -Message "JSON field 'value' is missing a colon."
        }
    }

    It 'rejects non-RFC whitespace after an authoritative JSON object' {
        foreach ($codePoint in @(0x000b, 0x000c, 0x0085, 0x00a0, 0xfeff)) {
            $invalid = [string][char]$codePoint
            Assert-CommMonitorTestThrowsExactly `
                -Action {
                    ConvertFrom-CommMonitorStrictJson `
                        -Json ('{"value":1}' + $invalid) `
                        -AllowedRootFields @('value')
                } `
                -Message 'Unexpected JSON content at offset 11.'
        }
    }

    It 'rejects non-RFC whitespace used as a primitive delimiter' {
        foreach ($codePoint in @(0x000b, 0x000c, 0x0085, 0x00a0, 0xfeff)) {
            $invalid = [string][char]$codePoint
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    ConvertFrom-CommMonitorStrictJson `
                        -Json ('{"value":1' + $invalid + '}') `
                        -AllowedRootFields @('value')
                } `
                -MessagePattern '^Invalid JSON primitive'
        }
    }

    It 'allows non-RFC whitespace code points inside JSON strings' {
        $value = -join @([char]0x0085, [char]0x00a0, [char]0xfeff)
        $parsed = ConvertFrom-CommMonitorStrictJson `
            -Json ('{"value":"' + $value + '"}') `
            -AllowedRootFields @('value')
        [string]::Equals(
            [string]$parsed.value,
            $value,
            [StringComparison]::Ordinal) | Should Be $true
    }

    It 'allows JSON escaped controls and rejects every raw string control' {
        $parsed = ConvertFrom-CommMonitorStrictJson `
            -Json '{"value":"\b\f\n\r\t\u0000\u001f"}' `
            -AllowedRootFields @('value')
        $expected = -join @(
            [char]0x08, [char]0x0c, [char]0x0a, [char]0x0d,
            [char]0x09, [char]0x00, [char]0x1f)
        [string]::Equals(
            [string]$parsed.value,
            $expected,
            [StringComparison]::Ordinal) | Should Be $true

        foreach ($codePoint in 0x00..0x1f) {
            $control = [string][char]$codePoint
            Assert-CommMonitorTestThrowsExactly `
                -Action {
                    ConvertFrom-CommMonitorStrictJson `
                        -Json ('{"value":"' + $control + '"}') `
                        -AllowedRootFields @('value')
                } `
                -Message 'Invalid unescaped JSON control character.'
        }
    }

    It 'requires an object at the authoritative JSON root' {
        foreach ($json in @('[]', '"value"', 'true', 'false', 'null', '0')) {
            Assert-CommMonitorTestThrowsExactly `
                -Action {
                    ConvertFrom-CommMonitorStrictJson `
                        -Json $json `
                        -AllowedRootFields @()
                } `
                -Message 'Strict JSON requires an object root.'
        }
    }

    It 'requires every AllowedRootFields entry to be a raw string' {
        foreach ($invalidField in @(
                3,
                [char]'x',
                [Text.StringBuilder]::new('value'),
                $null)) {
            $allowed = [object[]]@('value', $invalidField)
            Assert-CommMonitorTestThrowsExactly `
                -Action {
                    ConvertFrom-CommMonitorStrictJson `
                        -Json '{"value":1}' `
                        -AllowedRootFields $allowed
                } `
                -Message 'AllowedRootFields entries must be raw strings.'
        }

        Assert-CommMonitorTestThrowsExactly `
            -Action {
                ConvertFrom-CommMonitorStrictJson `
                    -Json '{}' `
                    -AllowedRootFields $null
            } `
            -Message 'AllowedRootFields must not be null.'

        $empty = ConvertFrom-CommMonitorStrictJson `
            -Json '{}' `
            -AllowedRootFields ([object[]]@())
        $empty.Count | Should Be 0
    }

    It 'rejects duplicate AllowedRootFields using Ordinal equality' {
        Assert-CommMonitorTestThrowsExactly `
            -Action {
                ConvertFrom-CommMonitorStrictJson `
                    -Json '{"value":1}' `
                    -AllowedRootFields @('value', 'value')
            } `
            -Message "AllowedRootFields contains duplicate field 'value'."
    }

    It 'rejects case-confused AllowedRootFields while retaining Ordinal admission' {
        Assert-CommMonitorTestThrowsExactly `
            -Action {
                ConvertFrom-CommMonitorStrictJson `
                    -Json '{"value":1}' `
                    -AllowedRootFields @('value', 'Value')
            } `
            -Message "AllowedRootFields contains case-confused field 'Value'."
        Assert-CommMonitorTestThrowsExactly `
            -Action {
                ConvertFrom-CommMonitorStrictJson `
                    -Json '{"value":1}' `
                    -AllowedRootFields @('Value')
            } `
            -Message "Unknown JSON field 'value'."
    }

    It 'rejects escaped-equivalent duplicate and case-confused JSON field names' {
        Assert-CommMonitorTestThrowsExactly `
            -Action {
                ConvertFrom-CommMonitorStrictJson `
                    -Json '{"schemaVersion":3,"schema\u0056ersion":3}' `
                    -AllowedRootFields @('schemaVersion')
            } `
            -Message "Duplicate JSON field 'schemaVersion'."
        Assert-CommMonitorTestThrowsExactly `
            -Action {
                ConvertFrom-CommMonitorStrictJson `
                    -Json '{"schemaVersion":3,"\u0053chemaVersion":3}' `
                    -AllowedRootFields @('schemaVersion')
            } `
            -Message "Case-confused JSON field 'SchemaVersion'."
    }

    It 'rejects an AliasProperty instead of silently dropping it from an exact schema' {
        $definition = [pscustomobject][ordered]@{
            objectId = 'dynamic-alias'
            type = 'DynamicFile'
            component = 'AiState'
            root = 'AiStateRoot'
            relativePath = 'state\alias.json'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{}
        }
        $definition | Add-Member `
            -MemberType AliasProperty `
            -Name injectedAlias `
            -Value objectId
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $definition } `
            -MessagePattern 'unsupported property member type.*AliasProperty'
    }

    It 'rejects a ScriptProperty instead of invoking or dropping dynamic schema code' {
        $definition = [pscustomobject][ordered]@{
            objectId = 'dynamic-script'
            type = 'DynamicFile'
            component = 'AiState'
            root = 'AiStateRoot'
            relativePath = 'state\script.json'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{}
        }
        $definition | Add-Member `
            -MemberType ScriptProperty `
            -Name injectedScript `
            -Value { throw 'dynamic schema code executed' }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $definition } `
            -MessagePattern 'unsupported property member type.*ScriptProperty'
    }

    It 'validates every typed ownership identity without wildcard ownership' {
        $definitions = @(
            [ordered]@{
                objectId = 'core-exe'
                type = 'ImmutableFile'
                component = 'Headless'
                root = 'CoreRoot'
                relativePath = 'bin\CommMonitor.Headless.exe'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 30
                identity = [ordered]@{
                    size = 1024
                    sha256 = ('a' * 64)
                    productMarker = 'CommMonitor:0.1.0'
                }
            },
            [ordered]@{
                objectId = 'dynamic-state'
                type = 'DynamicFile'
                component = 'AiState'
                root = 'AiStateRoot'
                relativePath = 'state\session.json'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 20
                identity = [ordered]@{}
            },
            [ordered]@{
                objectId = 'data-root'
                type = 'Directory'
                component = 'Data'
                root = 'DataRoot'
                relativePath = ''
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 90
                contentPolicy = 'ProtectedManagedTree'
                identity = [ordered]@{ created = $true }
            },
            [ordered]@{
                objectId = 'start-menu'
                type = 'Shortcut'
                component = 'StartMenuShortcut'
                root = 'StartMenu'
                relativePath = 'Lemon串口监控.lnk'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 10
                identity = [ordered]@{
                    target = 'C:\Program Files\Lemon串口监控\CommMonitor.App.exe'
                    arguments = ''
                    workingDirectory = 'C:\Program Files\Lemon串口监控'
                    fileSha256 = ('b' * 64)
                    created = $true
                }
            },
            [ordered]@{
                objectId = 'uninstall-value'
                type = 'RegistryValue'
                component = 'Uninstall'
                root = 'Registry'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 40
                identity = [ordered]@{
                    hive = 'HKLM'
                    view = 'Registry64'
                    key = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\LemonSerialMonitor'
                    name = 'DisplayName'
                    kind = 'String'
                    value = 'Lemon串口监控'
                    created = $true
                }
            },
            [ordered]@{
                objectId = 'uninstall-key'
                type = 'RegistryKey'
                component = 'Uninstall'
                root = 'Registry'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 41
                identity = [ordered]@{
                    hive = 'HKLM'
                    view = 'Registry64'
                    key = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\LemonSerialMonitor'
                    created = $true
                }
            },
            [ordered]@{
                objectId = 'service'
                type = 'Service'
                component = 'Service'
                root = 'System'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 50
                identity = [ordered]@{
                    name = 'CommMonitorService'
                    serviceType = 'Win32OwnProcess'
                    imagePath = 'C:\Program Files\CommMonitor\service\CommMonitor.Service.exe'
                    arguments = '--service'
                    accountSid = 'S-1-5-18'
                    creationProof = 'CreatedThisInstall'
                }
            },
            [ordered]@{
                objectId = 'driver-package'
                type = 'DriverPackage'
                component = 'Driver'
                root = 'System'
                ownershipProof = 'VerifiedLegacyAdoption'
                removeOnUninstall = $true
                deletePhase = 60
                identity = [ordered]@{
                    publishedName = 'oem42.inf'
                    originalInfPath = 'C:\Windows\INF\CommMonitor.Driver.inf'
                    originalInfSha256 = ('c' * 64)
                    creationProof = 'VerifiedLegacyAdoption'
                }
            },
            [ordered]@{
                objectId = 'certificate'
                type = 'Certificate'
                component = 'Driver'
                root = 'System'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 70
                identity = [ordered]@{
                    store = 'LocalMachine\TrustedPublisher'
                    thumbprint = ('d' * 40)
                    derSha256 = ('e' * 64)
                    added = $true
                }
            },
            [ordered]@{
                objectId = 'event-source'
                type = 'EventSource'
                component = 'Service'
                root = 'System'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 45
                identity = [ordered]@{
                    log = 'Application'
                    source = 'CommMonitorService'
                    registrationPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\CommMonitorService'
                    messageFile = 'C:\Program Files\CommMonitor\service\CommMonitor.Service.exe'
                    creationProof = 'CreatedThisInstall'
                }
            },
            [ordered]@{
                objectId = 'continuation-task'
                type = 'ScheduledTask'
                component = 'Continuation'
                root = 'System'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 95
                identity = [ordered]@{
                    name = 'LemonSerialMonitor-11111111-1111-1111-1111-111111111111'
                    identitySid = 'S-1-5-18'
                    trigger = 'AtStartup'
                    finalizerPath = 'C:\ProgramData\LemonSerialMonitor\Installer\finalizer.exe'
                    arguments = '--continue'
                    xmlSha256 = ('f' * 64)
                }
            },
            [ordered]@{
                objectId = 'upper-filter'
                type = 'FilterMetadata'
                component = 'Driver'
                root = 'Registry'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 65
                identity = [ordered]@{
                    classKey = '{4D36E978-E325-11CE-BFC1-08002BE10318}'
                    valueName = 'UpperFilters'
                    entry = 'CommMonitorFilter'
                    added = $true
                }
            },
            [ordered]@{
                objectId = 'manifest-key-metadata'
                type = 'KeyMetadata'
                component = 'Uninstall'
                root = 'InstallerRoot'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 96
                identity = [ordered]@{
                    kind = 'ManifestHmacKey'
                    state = 'Active'
                    relativePath = 'state\manifest.key.v1.json'
                    keyId = ('1' * 64)
                }
            },
            [ordered]@{
                objectId = 'continuation-metadata'
                type = 'ContinuationMetadata'
                component = 'Continuation'
                root = 'InstallerRoot'
                ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true
                deletePhase = 97
                identity = [ordered]@{
                    relativePath = 'state\continuation.v1.json'
                    pendingObjectIds = @('driver-package')
                    helperSha256 = ('2' * 64)
                    finalizerSha256 = ('3' * 64)
                }
            }
        )

        foreach ($definition in $definitions) {
            $ownedObject = New-CommMonitorOwnedObject -Definition $definition
            $ownedObject.objectId | Should Be $definition.objectId
            $ownedObject.type | Should Be $definition.type
        }
    }

    It 'rejects an owned object type under a root outside the central type-root policy' {
        $definition = [ordered]@{
            objectId = 'bad-type-root'
            type = 'DynamicFile'
            component = 'AiState'
            root = 'System'
            relativePath = 'state\session.json'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{}
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $definition } `
            -MessagePattern 'owned-object type/root policy'
    }

    It 'rejects a wrong-case owned object root' {
        $definition = [ordered]@{
            objectId = 'wrong-case-root'
            type = 'DynamicFile'
            component = 'AiState'
            root = 'aistateroot'
            relativePath = 'state\session.json'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{}
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $definition } `
            -MessagePattern 'owned-object type/root policy'
    }

    It 'rejects a valid type-root pair assigned to the wrong owned component' {
        $definition = [ordered]@{
            objectId = 'bad-component-pair'
            type = 'DynamicFile'
            component = 'Driver'
            root = 'AiStateRoot'
            relativePath = 'state\session.json'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{}
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $definition } `
            -MessagePattern 'owned-object component policy'
    }

    It 'rejects a component pair even when both the type and root are otherwise allowed' {
        $definition = [ordered]@{
            objectId = 'bad-component-root-tuple'
            type = 'DynamicFile'
            component = 'Uninstall'
            root = 'DataRoot'
            relativePath = 'state\session.json'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{}
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $definition } `
            -MessagePattern 'owned-object component policy'
    }

    It 'rejects a wrong-case owned object component' {
        $definition = [ordered]@{
            objectId = 'wrong-case-component'
            type = 'DynamicFile'
            component = 'aistate'
            root = 'AiStateRoot'
            relativePath = 'state\session.json'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{}
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $definition } `
            -MessagePattern 'owned-object component policy'
    }

    It 'rejects an unknown owned object component' {
        $definition = [ordered]@{
            objectId = 'unknown-component'
            type = 'DynamicFile'
            component = 'Unknown'
            root = 'AiStateRoot'
            relativePath = 'state\session.json'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{}
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $definition } `
            -MessagePattern 'owned-object component policy'
    }

    It 'revalidates the central type-root policy at the ownership layout boundary' {
        $ownedObject = New-CommMonitorOwnedObject -Definition ([ordered]@{
            objectId = 'headless-exe'
            type = 'ImmutableFile'
            component = 'Headless'
            root = 'CoreRoot'
            relativePath = 'CommMonitor.Headless.exe'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{
                size = 1
                sha256 = ('a' * 64)
                productMarker = 'CommMonitor:0.1.0'
            }
        })
        $ownedObject.root = 'System'
        Assert-CommMonitorTestThrowsLike `
            -Action { Assert-CommMonitorOwnershipLayout `
                    -PlatformKind ServerCore `
                    -PlatformComponents @('Headless', 'Service', 'Driver', 'AI') `
                    -OwnedObjects @($ownedObject) } `
            -MessagePattern 'owned-object type/root policy'
    }

    It 'revalidates the central component policy at the ownership layout boundary' {
        $ownedObject = New-CommMonitorOwnedObject -Definition ([ordered]@{
            objectId = 'headless-exe'
            type = 'ImmutableFile'
            component = 'Headless'
            root = 'CoreRoot'
            relativePath = 'CommMonitor.Headless.exe'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{
                size = 1
                sha256 = ('a' * 64)
                productMarker = 'CommMonitor:0.1.0'
            }
        })
        $ownedObject.component = 'AiState'
        Assert-CommMonitorTestThrowsLike `
            -Action { Assert-CommMonitorOwnershipLayout `
                    -PlatformKind ServerCore `
                    -PlatformComponents @('Headless', 'Service', 'Driver', 'AI') `
                    -OwnedObjects @($ownedObject) } `
            -MessagePattern 'owned-object component policy'
    }

    It 'rejects traversal absolute ADS wildcard and shared-delete object definitions' {
        $base = [ordered]@{
            objectId = 'dynamic-state'
            type = 'DynamicFile'
            component = 'AiState'
            root = 'AiStateRoot'
            relativePath = 'state\session.json'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{}
        }

        foreach ($badPath in @(
                '..\outside.txt',
                'C:\absolute.txt',
                'state\file.txt:evil',
                'state\*.json',
                'state/mixed\file.json')) {
            $bad = [ordered]@{}
            foreach ($key in $base.Keys) { $bad[$key] = $base[$key] }
            $bad.relativePath = $badPath
            { New-CommMonitorOwnedObject -Definition $bad } | Should Throw
        }

        $shared = [ordered]@{}
        foreach ($key in $base.Keys) { $shared[$key] = $base[$key] }
        $shared.ownershipProof = 'PreExistingShared'
        { New-CommMonitorOwnedObject -Definition $shared } | Should Throw
    }

    It 'enforces protected tree and Desktop Server Core layout boundaries' {
        $desktopObjects = @(
            (New-CommMonitorOwnedObject -Definition ([ordered]@{
                objectId = 'desktop-exe'; type = 'ImmutableFile'; component = 'DesktopExecutable'
                root = 'AppRoot'; relativePath = 'CommMonitor.App.exe'
                ownershipProof = 'CreatedThisInstall'; removeOnUninstall = $true; deletePhase = 20
                identity = [ordered]@{ size = 1; sha256 = ('a' * 64); productMarker = 'CommMonitor:0.1.0' }
            })),
            (New-CommMonitorOwnedObject -Definition ([ordered]@{
                objectId = 'ai-cli'; type = 'ImmutableFile'; component = 'AiCli'
                root = 'AppRoot'; relativePath = 'ai\CommMonitor.AI.exe'
                ownershipProof = 'CreatedThisInstall'; removeOnUninstall = $true; deletePhase = 20
                identity = [ordered]@{ size = 1; sha256 = ('b' * 64); productMarker = 'CommMonitor:0.1.0' }
            })),
            (New-CommMonitorOwnedObject -Definition ([ordered]@{
                objectId = 'start-menu'; type = 'Shortcut'; component = 'StartMenuShortcut'
                root = 'StartMenu'; relativePath = 'Lemon串口监控.lnk'
                ownershipProof = 'CreatedThisInstall'; removeOnUninstall = $true; deletePhase = 10
                identity = [ordered]@{
                    target = 'C:\Program Files\Lemon串口监控\CommMonitor.App.exe'; arguments = ''
                    workingDirectory = 'C:\Program Files\Lemon串口监控'; fileSha256 = ('c' * 64); created = $true
                }
            }))
        )
        { Assert-CommMonitorOwnershipLayout `
                -PlatformKind Desktop `
                -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                -OwnedObjects $desktopObjects } | Should Not Throw

        { Assert-CommMonitorOwnershipLayout `
                -PlatformKind ServerCore `
                -PlatformComponents @('Headless', 'Service', 'Driver', 'AI') `
                -OwnedObjects $desktopObjects } | Should Throw

        $protectedApp = [ordered]@{
            objectId = 'bad-tree'; type = 'Directory'; component = 'Data'; root = 'AppRoot'
            relativePath = 'data'; ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true; deletePhase = 90
            contentPolicy = 'ProtectedManagedTree'; identity = [ordered]@{ created = $true }
        }
        { New-CommMonitorOwnedObject -Definition $protectedApp } | Should Throw
    }

    It 'builds a canonical revision-one payload and rejects duplicate paths and IDs' {
        $desktopObjects = New-CommMonitorTestDesktopOwnedObjects
        $payloadArguments = @{
            AppId = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA'
            InstallId = 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB'
            Revision = 1
            ProductVersion = '0.1.0'
            CreatedUtc = [DateTimeOffset]::Parse('2026-07-14T01:02:03Z')
            Platform = [ordered]@{
                kind = 'Desktop'
                build = 22631
                components = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
            }
            Roots = New-CommMonitorTestOwnershipRoots
            AuthorizedUser = New-CommMonitorTestManifestAuthorizedUser
            OwnedObjects = $desktopObjects
            UpperFiltersRollback = [ordered]@{ present = $false; value = $null }
            KeyMetadata = [ordered]@{ manifest = [ordered]@{ state = 'Active'; keyId = ('d' * 64) } }
        }

        $payload = New-CommMonitorOwnershipPayload @payloadArguments
        $payload.appId | Should Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $payload.installId | Should Be 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $payload.createdUtc | Should Be '2026-07-14T01:02:03.0000000Z'
        $payload.revision | Should Be 1
        $payload.previousPayloadSha256 | Should BeNullOrEmpty
        $payload.state | Should Be 'Committed'
        $payload.ownedObjects[0].objectId | Should Be 'ai-cli'

        $duplicateIdArguments = @{}
        foreach ($key in $payloadArguments.Keys) {
            $duplicateIdArguments[$key] = $payloadArguments[$key]
        }
        $duplicateIdArguments.OwnedObjects = @($desktopObjects + $desktopObjects[0])
        { New-CommMonitorOwnershipPayload @duplicateIdArguments } | Should Throw

        $caseDuplicate = [ordered]@{}
        foreach ($key in $desktopObjects[0].Keys) { $caseDuplicate[$key] = $desktopObjects[0][$key] }
        $caseDuplicate.objectId = 'desktop-exe-copy'
        $caseDuplicate.relativePath = 'commmonitor.app.EXE'
        $duplicatePathArguments = @{}
        foreach ($key in $payloadArguments.Keys) {
            $duplicatePathArguments[$key] = $payloadArguments[$key]
        }
        $duplicatePathArguments.OwnedObjects = @(
            $desktopObjects + ([pscustomobject]$caseDuplicate))
        { New-CommMonitorOwnershipPayload @duplicatePathArguments } | Should Throw
    }

    It 'rejects an unknown Platform signature field in an ownership payload' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.Platform = [ordered]@{
            kind = 'Desktop'
            build = 22631
            components = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
            edition = 'Professional'
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern "Platform signature contains unknown field 'edition'"
    }

    It 'rejects a Platform signature missing kind' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.Platform = [ordered]@{
            build = 22631
            components = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern "Platform signature is missing required field 'kind'"
    }

    It 'rejects a Platform signature missing build' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.Platform = [ordered]@{
            kind = 'Desktop'
            components = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern "Platform signature is missing required field 'build'"
    }

    It 'rejects a Platform signature missing components' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.Platform = [ordered]@{
            kind = 'Desktop'
            build = 22631
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern "Platform signature is missing required field 'components'"
    }

    It 'rejects a wrong-case Platform kind in an ownership payload' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.Platform = [ordered]@{
            kind = 'desktop'
            build = 22631
            components = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Platform kind must be an exact supported value'
    }

    It 'rejects a non-integer Platform build in an ownership payload' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.Platform = [ordered]@{
            kind = 'Desktop'
            build = '22631'
            components = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut')
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Platform build must be a raw integer'
    }

    It 'rejects a scalar Platform components value in an ownership payload' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.Platform = [ordered]@{
            kind = 'Desktop'
            build = 22631
            components = 'WPF'
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Platform components must be a raw array of exact strings'
    }

    It 'rejects a non-string member of Platform components in an ownership payload' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.Platform = [ordered]@{
            kind = 'Desktop'
            build = 22631
            components = @('WPF', 'Service', 'Driver', 'AI', 7)
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Platform components must be a raw array of exact strings'
    }

    It 'revalidates duplicate Platform components in an ownership payload' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.Platform = [ordered]@{
            kind = 'Desktop'
            build = 22631
            components = @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut', 'AI')
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Desktop requires the exact component set'
    }

    It 'rejects an owned object whose required component is absent from the payload platform' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $headless = New-CommMonitorOwnedObject -Definition ([ordered]@{
            objectId = 'headless-exe'
            type = 'ImmutableFile'
            component = 'Headless'
            root = 'CoreRoot'
            relativePath = 'CommMonitor.Headless.exe'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{
                size = 1
                sha256 = ('e' * 64)
                productMarker = 'CommMonitor:0.1.0'
            }
        })
        $arguments.OwnedObjects = @($arguments.OwnedObjects + $headless)
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern "requires platform component 'Headless'"
    }

    It 'returns a payload bound to a validated platform component snapshot' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $payload = New-CommMonitorOwnershipPayload @arguments

        $arguments.Platform.components[0] = 'Unknown'

        ($payload.platform.components -contains 'WPF') | Should Be $true
        ($payload.platform.components -contains 'Unknown') | Should Be $false
    }

    It 'rebuilds the resolver-rich ownership hierarchy as a fresh lower-camel snapshot' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.State = 'UninstallRequested'
        $arguments.OperationState =
            New-CommMonitorTestRequestedOperationState
        $payload = New-CommMonitorOwnershipPayload @arguments

        [string]::Join(',', [string[]]$payload.roots.Keys) |
            Should Be 'appRoot,coreRoot,dataRoot,installerRoot,aiStateRoot'
        [string]::Join(',', [string[]]$payload.roots.appRoot.Keys) | Should Be (
            'role,canonicalPath,active,present,createdByInstall,' +
            'volumeSerialNumber,fileId,aclProfile,physicalCandidatePath,' +
            'ownershipProof,adoptionSource,contentPolicy')
        [string]::Join(',', [string[]]$payload.roots.appRoot.aclProfile.Keys) |
            Should Be (
                'ownerSid,areAccessRulesProtected,allowedFullControlSids,' +
                'denyRuleCount,usersWritable')
        [string]::Join(',', [string[]]$payload.authorizedUser.Keys) | Should Be (
            'sid,profileListKeyPath,profileImagePathRaw,profileImagePathValueKind,' +
            'profileExpansionSource,profileExpansionSid,profileImagePath,' +
            'knownFolderId,knownFolderSid,localAppDataPath,aiRoot')

        $arguments.Roots.AppRoot.CanonicalPath = 'C:\mutated'
        $arguments.Roots.AppRoot.AclProfile.AllowedFullControlSids[0] = 'S-1-1-0'
        $arguments.AuthorizedUser.Sid = 'S-1-1-0'
        $arguments.UpperFiltersRollback.present = $true
        $arguments.KeyMetadata.manifest.state = 'Mutated'
        $arguments.OperationState.operationId = '22222222-2222-2222-2222-222222222222'

        $payload.roots.appRoot.canonicalPath |
            Should Be 'C:\Program Files\Lemon串口监控'
        $payload.roots.appRoot.aclProfile.allowedFullControlSids[0] |
            Should Be 'S-1-5-18'
        $payload.authorizedUser.sid | Should Be 'S-1-5-21-111-222-333-1001'
        $payload.upperFiltersRollback.present | Should Be $false
        $payload.keyMetadata.manifest.state | Should Be 'Active'
        $payload.operationState.operationId |
            Should Be '11111111-1111-1111-1111-111111111111'
    }

    It 'requires the exact five-field ownership roots container' {
        $baseline = New-CommMonitorTestOwnershipRoots
        foreach ($case in @(New-CommMonitorTestExactSchemaMutations `
                -InputObject $baseline `
                -RequiredField AiStateRoot `
                -WrongCaseField aiStateRoot)) {
            $arguments = New-CommMonitorTestOwnershipPayloadArguments
            $arguments.Roots = $case.Value
            Assert-CommMonitorTestThrowsLike `
                -Action { New-CommMonitorOwnershipPayload @arguments } `
                -MessagePattern 'Ownership roots (contains|is missing)'
        }
    }

    It 'requires every resolver-rich root record to use one exact field set' {
        $baseline = (New-CommMonitorTestOwnershipRoots).AppRoot
        foreach ($case in @(New-CommMonitorTestExactSchemaMutations `
                -InputObject $baseline `
                -RequiredField CanonicalPath `
                -WrongCaseField canonicalPath)) {
            $arguments = New-CommMonitorTestOwnershipPayloadArguments
            $arguments.Roots.AppRoot = $case.Value
            Assert-CommMonitorTestThrowsLike `
                -Action { New-CommMonitorOwnershipPayload @arguments } `
                -MessagePattern 'AppRoot record (contains|is missing)'
        }
    }

    It 'requires an exact ACL profile nested in every non-null root ACL' {
        $baseline = New-CommMonitorTestProtectedAclProfile
        foreach ($case in @(New-CommMonitorTestExactSchemaMutations `
                -InputObject $baseline `
                -RequiredField OwnerSid `
                -WrongCaseField ownerSid)) {
            $arguments = New-CommMonitorTestOwnershipPayloadArguments
            $arguments.Roots.AppRoot.AclProfile = $case.Value
            Assert-CommMonitorTestThrowsLike `
                -Action { New-CommMonitorOwnershipPayload @arguments } `
                -MessagePattern 'AppRoot ACL profile (contains|is missing)'
        }
    }

    It 'requires the exact resolver authorized-user evidence fields' {
        $baseline = New-CommMonitorTestManifestAuthorizedUser
        foreach ($case in @(New-CommMonitorTestExactSchemaMutations `
                -InputObject $baseline `
                -RequiredField Sid `
                -WrongCaseField sid)) {
            $arguments = New-CommMonitorTestOwnershipPayloadArguments
            $arguments.AuthorizedUser = $case.Value
            Assert-CommMonitorTestThrowsLike `
                -Action { New-CommMonitorOwnershipPayload @arguments } `
                -MessagePattern 'Authorized user (contains|is missing)'
        }
    }

    It 'requires exact UpperFilters rollback metadata' {
        $baseline = [ordered]@{ present = $false; value = $null }
        foreach ($case in @(New-CommMonitorTestExactSchemaMutations `
                -InputObject $baseline `
                -RequiredField present `
                -WrongCaseField Present)) {
            $arguments = New-CommMonitorTestOwnershipPayloadArguments
            $arguments.UpperFiltersRollback = $case.Value
            Assert-CommMonitorTestThrowsLike `
                -Action { New-CommMonitorOwnershipPayload @arguments } `
                -MessagePattern 'UpperFilters rollback (contains|is missing)'
        }
    }

    It 'requires exact top-level and manifest key metadata' {
        $outer = [ordered]@{
            manifest = [ordered]@{ state = 'Active'; keyId = ('d' * 64) }
        }
        foreach ($case in @(New-CommMonitorTestExactSchemaMutations `
                -InputObject $outer `
                -RequiredField manifest `
                -WrongCaseField Manifest)) {
            $arguments = New-CommMonitorTestOwnershipPayloadArguments
            $arguments.KeyMetadata = $case.Value
            Assert-CommMonitorTestThrowsLike `
                -Action { New-CommMonitorOwnershipPayload @arguments } `
                -MessagePattern 'Key metadata (contains|is missing)'
        }

        $inner = [ordered]@{ state = 'Active'; keyId = ('d' * 64) }
        foreach ($case in @(New-CommMonitorTestExactSchemaMutations `
                -InputObject $inner `
                -RequiredField state `
                -WrongCaseField State)) {
            $arguments = New-CommMonitorTestOwnershipPayloadArguments
            $arguments.KeyMetadata.manifest = $case.Value
            Assert-CommMonitorTestThrowsLike `
                -Action { New-CommMonitorOwnershipPayload @arguments } `
                -MessagePattern 'Manifest key metadata (contains|is missing)'
        }
    }

    It 'requires exact continuation and operation state records' {
        $continuation = [ordered]@{ status = 'None' }
        foreach ($case in @(New-CommMonitorTestExactSchemaMutations `
                -InputObject $continuation `
                -RequiredField status `
                -WrongCaseField Status)) {
            $arguments = New-CommMonitorTestOwnershipPayloadArguments
            $arguments.ContinuationState = $case.Value
            Assert-CommMonitorTestThrowsLike `
                -Action { New-CommMonitorOwnershipPayload @arguments } `
                -MessagePattern 'Continuation state (contains|is missing)'
        }

        foreach ($operation in @(
                [ordered]@{ unexpected = $true },
                [ordered]@{ OperationId = '11111111-1111-1111-1111-111111111111' })) {
            $arguments = New-CommMonitorTestOwnershipPayloadArguments
            $arguments.OperationState = $operation
            Assert-CommMonitorTestThrowsLike `
                -Action { New-CommMonitorOwnershipPayload @arguments } `
                -MessagePattern 'Operation state contains'
        }
    }

    It 'requires exact lower-camel legacy and manifest adoption-source unions' {
        foreach ($sourceCase in @(
                [pscustomobject]@{
                    Source = New-CommMonitorTestLegacyAdoptionSource
                    RequiredField = 'markerId'
                    WrongCaseField = 'MarkerId'
                },
                [pscustomobject]@{
                    Source = New-CommMonitorTestManifestAdoptionSource
                    RequiredField = 'sourceInstallId'
                    WrongCaseField = 'SourceInstallId'
                })) {
            foreach ($case in @(New-CommMonitorTestExactSchemaMutations `
                    -InputObject $sourceCase.Source `
                    -RequiredField $sourceCase.RequiredField `
                    -WrongCaseField $sourceCase.WrongCaseField)) {
                $arguments = New-CommMonitorTestOwnershipPayloadArguments
                $arguments.Roots.DataRoot.AdoptionSource = $case.Value
                Assert-CommMonitorTestThrowsLike `
                    -Action { New-CommMonitorOwnershipPayload @arguments } `
                    -MessagePattern 'adoption source (contains|is missing)'
            }
        }
    }

    It 'rejects wrong-case recursive schema discriminators without normalizing them' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.Roots.DataRoot.AdoptionSource =
            New-CommMonitorTestLegacyAdoptionSource
        $arguments.Roots.DataRoot.AdoptionSource.sourceKind =
            'validatedlegacymarker'
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'adoption source has an unknown sourceKind'

        $validArguments = New-CommMonitorTestOwnershipPayloadArguments
        $payload = New-CommMonitorOwnershipPayload @validArguments
        $payload.ownedObjects[0].type =
            ([string]$payload.ownedObjects[0].type).ToLowerInvariant()
        $key = [byte[]](0..31)
        $keyId = Get-CommMonitorSha256Hex -Bytes $key
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $key `
                    -KeyId $keyId
            } `
            -MessagePattern 'Owned object has an unknown type'

        $proof = [ordered]@{
            objectId = 'wrong-proof'
            type = 'DynamicFile'
            component = 'AiState'
            root = 'AiStateRoot'
            relativePath = 'state\wrong-proof.json'
            ownershipProof = 'createdthisinstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{}
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $proof } `
            -MessagePattern 'Invalid ownership proof'

        $contentPolicy = [ordered]@{
            objectId = 'wrong-content-policy'
            type = 'Directory'
            component = 'Data'
            root = 'DataRoot'
            relativePath = 'state'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            contentPolicy = 'protectedmanagedtree'
            identity = [ordered]@{ created = $true }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $contentPolicy } `
            -MessagePattern 'Directory requires a supported contentPolicy'

        $stateArguments = New-CommMonitorTestOwnershipPayloadArguments
        $stateArguments.State = 'committed'
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @stateArguments } `
            -MessagePattern 'Ownership state must be an exact supported value'

        $platformArguments = New-CommMonitorTestOwnershipPayloadArguments
        $platformPayload = New-CommMonitorOwnershipPayload @platformArguments
        $platformPayload.platform.kind = 'desktop'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $platformPayload `
                    -Key $key `
                    -KeyId $keyId
            } `
            -MessagePattern 'Platform kind must be an exact supported value'

        $componentArguments = New-CommMonitorTestOwnershipPayloadArguments
        $componentPayload = New-CommMonitorOwnershipPayload @componentArguments
        $componentPayload.ownedObjects[0].component =
            ([string]$componentPayload.ownedObjects[0].component).ToLowerInvariant()
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $componentPayload `
                    -Key $key `
                    -KeyId $keyId
            } `
            -MessagePattern 'Owned object has an unknown component'
    }

    It 'preserves a valid DynamicFile empty identity through canonical authentication' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $dynamicFile = [ordered]@{
            objectId = 'dynamic-authenticated'
            type = 'DynamicFile'
            component = 'AiState'
            root = 'AiStateRoot'
            relativePath = 'state\authenticated.json'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [ordered]@{}
        }
        $arguments.OwnedObjects = @($arguments.OwnedObjects + $dynamicFile)
        $payload = New-CommMonitorOwnershipPayload @arguments
        $key = [byte[]](0..31)
        $keyId = Get-CommMonitorSha256Hex -Bytes $key

        $envelope = New-CommMonitorOwnershipEnvelope `
            -Payload $payload `
            -Key $key `
            -KeyId $keyId
        $validated = Assert-CommMonitorOwnershipEnvelope `
            -Envelope $envelope `
            -Key $key

        $dynamic = @($validated.ownedObjects | Where-Object {
                $_.objectId -eq 'dynamic-authenticated'
            })
        $dynamic.Count | Should Be 1
        $dynamic[0].identity.Count | Should Be 0
    }

    It 'rejects role-slot and owned tuple mismatches at every canonical authority' {
        $roleArguments = New-CommMonitorTestOwnershipPayloadArguments
        $roleArguments.Roots.AppRoot.Role = 'CoreRoot'
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @roleArguments } `
            -MessagePattern "AppRoot record role must be exactly 'AppRoot'"

        $invalidCases = @(
            [pscustomobject]@{
                Name = 'role-slot'
                Pattern = "AppRoot record role must be exactly 'AppRoot'"
                Mutate = {
                    param($Payload)
                    $Payload.roots.appRoot.role = 'CoreRoot'
                }
            },
            [pscustomobject]@{
                Name = 'owned-tuple'
                Pattern = 'Owned-object component policy rejects'
                Mutate = {
                    param($Payload)
                    $owned = @($Payload.ownedObjects | Where-Object {
                            $_.objectId -eq 'ai-cli'
                        })[0]
                    $owned.root = 'InstallerRoot'
                }
            })
        $key = [byte[]](0..31)
        $keyId = Get-CommMonitorSha256Hex -Bytes $key
        $manifestPath =
            'C:\ProgramData\LemonSerialMonitor\Installer\state\ownership-manifest.v3.json'

        foreach ($case in $invalidCases) {
            $arguments = New-CommMonitorTestOwnershipPayloadArguments
            $invalidPayload = New-CommMonitorOwnershipPayload @arguments
            & $case.Mutate $invalidPayload

            Assert-CommMonitorTestThrowsLike `
                -Action {
                    New-CommMonitorOwnershipEnvelope `
                        -Payload $invalidPayload `
                        -Key $key `
                        -KeyId $keyId
                } `
                -MessagePattern $case.Pattern

            $uncheckedEnvelope = New-CommMonitorTestSignedEnvelopeUnchecked `
                -Payload $invalidPayload `
                -Key $key
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    Assert-CommMonitorOwnershipEnvelope `
                        -Envelope $uncheckedEnvelope `
                        -Key $key
                } `
                -MessagePattern $case.Pattern

            $anchor = New-CommMonitorOwnershipAnchor `
                -Payload $invalidPayload `
                -PayloadSha256 $uncheckedEnvelope.integrity.payloadSha256 `
                -ManifestPath $manifestPath `
                -Key $key `
                -KeyId $keyId
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    Assert-CommMonitorOwnershipState `
                        -Envelope $uncheckedEnvelope `
                        -Anchor $anchor `
                        -Key $key `
                        -ExpectedManifestPath $manifestPath `
                        -ExpectedAppId $invalidPayload.appId `
                        -ExpectedInstallId $invalidPayload.installId
                } `
                -MessagePattern $case.Pattern

            $currentArguments = New-CommMonitorTestOwnershipPayloadArguments
            $currentPayload = New-CommMonitorOwnershipPayload @currentArguments
            $currentEnvelope = New-CommMonitorOwnershipEnvelope `
                -Payload $currentPayload `
                -Key $key `
                -KeyId $keyId
            $currentAnchor = New-CommMonitorOwnershipAnchor `
                -Payload $currentPayload `
                -PayloadSha256 $currentEnvelope.integrity.payloadSha256 `
                -ManifestPath $manifestPath `
                -Key $key `
                -KeyId $keyId
            $nextArguments = New-CommMonitorTestOwnershipPayloadArguments
            $nextPayload = New-CommMonitorOwnershipPayload @nextArguments
            & $case.Mutate $nextPayload
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    Update-CommMonitorOwnershipStateCas `
                        -CurrentEnvelope $currentEnvelope `
                        -CurrentAnchor $currentAnchor `
                        -ExpectedRevision 1 `
                        -ExpectedPayloadSha256 `
                            $currentEnvelope.integrity.payloadSha256 `
                        -NextPayload $nextPayload `
                        -ManifestPath $manifestPath `
                        -Key $key `
                        -KeyId $keyId
                } `
                -MessagePattern $case.Pattern
        }
    }

    $scalarContainerAuthorityCases = @()
    foreach ($fieldName in @(
            'platform.components',
            'root ACL allowedFullControlSids',
            'ownedObjects')) {
        foreach ($authorityName in @(
                'NewEnvelope',
                'AssertEnvelope',
                'AssertState',
                'CAS')) {
            $scalarContainerAuthorityCases += @{
                Field = $fieldName
                Authority = $authorityName
            }
        }
    }

    It 'rejects scalar <Field> at the <Authority> canonical authority' `
        -TestCases $scalarContainerAuthorityCases {
        param($Field, $Authority)

        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $payload = New-CommMonitorOwnershipPayload @arguments
        switch ($Field) {
            'platform.components' {
                $payload.platform.components = 'WPF'
            }
            'root ACL allowedFullControlSids' {
                $payload.roots.appRoot.aclProfile.allowedFullControlSids =
                    'S-1-5-18'
            }
            'ownedObjects' {
                $payload.ownedObjects = $payload.ownedObjects[0]
            }
        }

        $key = [byte[]](0..31)
        $keyId = Get-CommMonitorSha256Hex -Bytes $key
        $manifestPath =
            'C:\ProgramData\LemonSerialMonitor\Installer\state\ownership-manifest.v3.json'

        switch ($Authority) {
            'NewEnvelope' {
                Assert-CommMonitorTestThrowsLike `
                    -Action {
                        New-CommMonitorOwnershipEnvelope `
                            -Payload $payload `
                            -Key $key `
                            -KeyId $keyId
                    } `
                    -MessagePattern 'must be a raw System.Array'
            }
            'AssertEnvelope' {
                $uncheckedEnvelope = New-CommMonitorTestSignedEnvelopeUnchecked `
                    -Payload $payload `
                    -Key $key
                Assert-CommMonitorTestThrowsLike `
                    -Action {
                        Assert-CommMonitorOwnershipEnvelope `
                            -Envelope $uncheckedEnvelope `
                            -Key $key
                    } `
                    -MessagePattern 'must be a raw System.Array'
            }
            'AssertState' {
                $uncheckedEnvelope = New-CommMonitorTestSignedEnvelopeUnchecked `
                    -Payload $payload `
                    -Key $key
                $anchor = New-CommMonitorOwnershipAnchor `
                    -Payload $payload `
                    -PayloadSha256 $uncheckedEnvelope.integrity.payloadSha256 `
                    -ManifestPath $manifestPath `
                    -Key $key `
                    -KeyId $keyId
                Assert-CommMonitorTestThrowsLike `
                    -Action {
                        Assert-CommMonitorOwnershipState `
                            -Envelope $uncheckedEnvelope `
                            -Anchor $anchor `
                            -Key $key `
                            -ExpectedManifestPath $manifestPath `
                            -ExpectedAppId $payload.appId `
                            -ExpectedInstallId $payload.installId
                    } `
                    -MessagePattern 'must be a raw System.Array'
            }
            'CAS' {
                $currentArguments = New-CommMonitorTestOwnershipPayloadArguments
                $currentPayload = New-CommMonitorOwnershipPayload @currentArguments
                $currentEnvelope = New-CommMonitorOwnershipEnvelope `
                    -Payload $currentPayload `
                    -Key $key `
                    -KeyId $keyId
                $currentAnchor = New-CommMonitorOwnershipAnchor `
                    -Payload $currentPayload `
                    -PayloadSha256 $currentEnvelope.integrity.payloadSha256 `
                    -ManifestPath $manifestPath `
                    -Key $key `
                    -KeyId $keyId
                Assert-CommMonitorTestThrowsLike `
                    -Action {
                        Update-CommMonitorOwnershipStateCas `
                            -CurrentEnvelope $currentEnvelope `
                            -CurrentAnchor $currentAnchor `
                            -ExpectedRevision 1 `
                            -ExpectedPayloadSha256 `
                                $currentEnvelope.integrity.payloadSha256 `
                            -NextPayload $payload `
                            -ManifestPath $manifestPath `
                            -Key $key `
                            -KeyId $keyId
                    } `
                    -MessagePattern 'must be a raw System.Array'
            }
        }
    }

    $rawArrayShapeCases = @(
        @{ Name = 'components ArrayList'; Target = 'components-arraylist'; Pattern = 'raw System.Array' },
        @{ Name = 'components generic List'; Target = 'components-list'; Pattern = 'raw System.Array' },
        @{ Name = 'components non-string member'; Target = 'components-member'; Pattern = 'raw strings' },
        @{ Name = 'ownedObjects ArrayList'; Target = 'owned-arraylist'; Pattern = 'raw System.Array' },
        @{ Name = 'ownedObjects generic List'; Target = 'owned-list'; Pattern = 'raw System.Array' },
        @{ Name = 'ownedObjects primitive member'; Target = 'owned-member'; Pattern = 'raw objects' },
        @{ Name = 'root ACL ArrayList'; Target = 'root-acl-arraylist'; Pattern = 'raw System.Array' },
        @{ Name = 'root ACL non-string member'; Target = 'root-acl-member'; Pattern = 'raw strings' },
        @{ Name = 'adoption ACL scalar'; Target = 'adoption-acl-scalar'; Pattern = 'raw System.Array' },
        @{ Name = 'adoption ACL non-string member'; Target = 'adoption-acl-member'; Pattern = 'raw strings' },
        @{ Name = 'UpperFilters scalar'; Target = 'upper-scalar'; Pattern = 'raw System.Array' },
        @{ Name = 'UpperFilters ArrayList'; Target = 'upper-arraylist'; Pattern = 'raw System.Array' },
        @{ Name = 'UpperFilters non-string member'; Target = 'upper-member'; Pattern = 'raw strings' },
        @{ Name = 'pending object IDs scalar'; Target = 'pending-scalar'; Pattern = 'raw System.Array' },
        @{ Name = 'pending object IDs ArrayList'; Target = 'pending-arraylist'; Pattern = 'raw System.Array' },
        @{ Name = 'pending object IDs non-string member'; Target = 'pending-member'; Pattern = 'raw strings' },
        @{ Name = 'RegistryValue ArrayList'; Target = 'registry-arraylist'; Pattern = 'raw System.Array' },
        @{ Name = 'RegistryValue array non-string member'; Target = 'registry-member'; Pattern = 'raw strings' }
    )

    It 'rejects non-raw array shape <Name> at canonical admission' `
        -TestCases $rawArrayShapeCases {
        param($Name, $Target, $Pattern)

        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $payload = New-CommMonitorOwnershipPayload @arguments
        switch ($Target) {
            'components-arraylist' {
                $list = [Collections.ArrayList]::new()
                foreach ($item in @($payload.platform.components)) {
                    [void]$list.Add($item)
                }
                $payload.platform.components = $list
            }
            'components-list' {
                $list = [Collections.Generic.List[string]]::new()
                foreach ($item in @($payload.platform.components)) {
                    $list.Add($item)
                }
                $payload.platform.components = $list
            }
            'components-member' {
                $payload.platform.components = [object[]]@(
                    'WPF', 'Service', 'Driver', 'AI',
                    [Text.StringBuilder]::new('StartMenuShortcut'))
            }
            'owned-arraylist' {
                $list = [Collections.ArrayList]::new()
                foreach ($item in @($payload.ownedObjects)) {
                    [void]$list.Add($item)
                }
                $payload.ownedObjects = $list
            }
            'owned-list' {
                $list = [Collections.Generic.List[object]]::new()
                foreach ($item in @($payload.ownedObjects)) {
                    $list.Add($item)
                }
                $payload.ownedObjects = $list
            }
            'owned-member' {
                $payload.ownedObjects = [object[]]@($payload.ownedObjects + 7)
            }
            'root-acl-arraylist' {
                $list = [Collections.ArrayList]::new()
                [void]$list.Add('S-1-5-18')
                [void]$list.Add('S-1-5-32-544')
                $payload.roots.appRoot.aclProfile.allowedFullControlSids = $list
            }
            'root-acl-member' {
                $payload.roots.appRoot.aclProfile.allowedFullControlSids =
                    [object[]]@('S-1-5-18', [Text.StringBuilder]::new('S-1-5-32-544'))
            }
            'adoption-acl-scalar' {
                $payload.roots.dataRoot.adoptionSource =
                    New-CommMonitorTestLegacyAdoptionSource
                $payload.roots.dataRoot.adoptionSource.aclProfile.allowedFullControlSids =
                    'S-1-5-18'
            }
            'adoption-acl-member' {
                $payload.roots.dataRoot.adoptionSource =
                    New-CommMonitorTestLegacyAdoptionSource
                $payload.roots.dataRoot.adoptionSource.aclProfile.allowedFullControlSids =
                    [object[]]@('S-1-5-18', [Text.StringBuilder]::new('S-1-5-32-544'))
            }
            'upper-scalar' {
                $payload.upperFiltersRollback.value = 'serenum'
            }
            'upper-arraylist' {
                $list = [Collections.ArrayList]::new()
                [void]$list.Add('serenum')
                $payload.upperFiltersRollback.value = $list
            }
            'upper-member' {
                $payload.upperFiltersRollback.value =
                    [object[]]@([Text.StringBuilder]::new('serenum'))
            }
            'pending-scalar' {
                $owned = Add-CommMonitorTestContinuationMetadataObject -Payload $payload
                $owned.identity.pendingObjectIds = 'desktop-exe'
            }
            'pending-arraylist' {
                $owned = Add-CommMonitorTestContinuationMetadataObject -Payload $payload
                $list = [Collections.ArrayList]::new()
                [void]$list.Add('desktop-exe')
                $owned.identity.pendingObjectIds = $list
            }
            'pending-member' {
                $owned = Add-CommMonitorTestContinuationMetadataObject -Payload $payload
                $owned.identity.pendingObjectIds =
                    [object[]]@([Text.StringBuilder]::new('desktop-exe'))
            }
            'registry-arraylist' {
                $list = [Collections.ArrayList]::new()
                [void]$list.Add('one')
                [void](Add-CommMonitorTestRegistryValueObject `
                        -Payload $payload `
                        -Value $list)
            }
            'registry-member' {
                [void](Add-CommMonitorTestRegistryValueObject `
                        -Payload $payload `
                        -Value ([object[]]@([Text.StringBuilder]::new('one'))))
            }
        }

        $key = [byte[]](0..31)
        $keyId = Get-CommMonitorSha256Hex -Bytes $key
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $key `
                    -KeyId $keyId
            } `
            -MessagePattern $Pattern
    }

    $rawObjectContainerCases = @(
        @{ Name = 'payload string'; Target = 'payload' },
        @{ Name = 'platform string'; Target = 'platform' },
        @{ Name = 'roots integer'; Target = 'roots' },
        @{ Name = 'root record string'; Target = 'root' },
        @{ Name = 'ACL profile string'; Target = 'acl' },
        @{ Name = 'adoption source integer'; Target = 'adoption' },
        @{ Name = 'authorized user string'; Target = 'authorized' },
        @{ Name = 'owned identity null'; Target = 'identity' },
        @{ Name = 'UpperFilters Boolean'; Target = 'upper' },
        @{ Name = 'key metadata string'; Target = 'key' },
        @{ Name = 'manifest key integer'; Target = 'manifest-key' },
        @{ Name = 'continuation state string'; Target = 'continuation' },
        @{ Name = 'operation state integer'; Target = 'operation' }
    )

    It 'rejects non-object <Name> at canonical admission' `
        -TestCases $rawObjectContainerCases {
        param($Name, $Target)

        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $payload = New-CommMonitorOwnershipPayload @arguments
        switch ($Target) {
            'platform' { $payload.platform = 'Desktop' }
            'roots' { $payload.roots = 7 }
            'root' { $payload.roots.appRoot = 'AppRoot' }
            'acl' { $payload.roots.appRoot.aclProfile = 'S-1-5-18' }
            'adoption' { $payload.roots.dataRoot.adoptionSource = 1 }
            'authorized' { $payload.authorizedUser = 'S-1-5-18' }
            'identity' { $payload.ownedObjects[0].identity = $null }
            'upper' { $payload.upperFiltersRollback = $true }
            'key' { $payload.keyMetadata = 'Active' }
            'manifest-key' { $payload.keyMetadata.manifest = 1 }
            'continuation' { $payload.continuationState = 'None' }
            'operation' { $payload.operationState = 0 }
        }
        $candidatePayload = if ($Target -eq 'payload') { 'payload' } else { $payload }
        $key = [byte[]](0..31)
        $keyId = Get-CommMonitorSha256Hex -Bytes $key
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $candidatePayload `
                    -Key $key `
                    -KeyId $keyId
            } `
            -MessagePattern 'must be a raw object'
    }

    $rawPrimitiveCases = @(
        @{ Name = 'payload appId StringBuilder'; Target = 'app-id'; Pattern = 'raw string' },
        @{ Name = 'payload productVersion character'; Target = 'product-version'; Pattern = 'raw string' },
        @{ Name = 'payload createdUtc StringBuilder'; Target = 'created-utc'; Pattern = 'raw string' },
        @{ Name = 'platform kind StringBuilder'; Target = 'platform-kind'; Pattern = 'raw string' },
        @{ Name = 'root role StringBuilder'; Target = 'root-role'; Pattern = 'raw string' },
        @{ Name = 'root path StringBuilder'; Target = 'root-path'; Pattern = 'raw string' },
        @{ Name = 'ACL ownerSid StringBuilder'; Target = 'acl-owner'; Pattern = 'raw string' },
        @{ Name = 'adoption sourceKind StringBuilder'; Target = 'adoption-source'; Pattern = 'raw string' },
        @{ Name = 'authorized SID StringBuilder'; Target = 'authorized-sid'; Pattern = 'raw string' },
        @{ Name = 'owned objectId StringBuilder'; Target = 'owned-id'; Pattern = 'raw string' },
        @{ Name = 'owned hash StringBuilder'; Target = 'owned-hash'; Pattern = 'raw string' },
        @{ Name = 'key state StringBuilder'; Target = 'key-state'; Pattern = 'raw string' },
        @{ Name = 'continuation status StringBuilder'; Target = 'continuation-status'; Pattern = 'raw string' },
        @{ Name = 'operation ID StringBuilder'; Target = 'operation-id'; Pattern = 'raw string' },
        @{ Name = 'root active string'; Target = 'root-active'; Pattern = 'raw Boolean' },
        @{ Name = 'ACL protected integer'; Target = 'acl-protected'; Pattern = 'raw Boolean' },
        @{ Name = 'owned remove string'; Target = 'owned-remove'; Pattern = 'raw Boolean' },
        @{ Name = 'owned created string'; Target = 'owned-created'; Pattern = 'raw Boolean' },
        @{ Name = 'UpperFilters present integer'; Target = 'upper-present'; Pattern = 'raw Boolean' },
        @{ Name = 'revision string'; Target = 'revision'; Pattern = 'raw Int32' },
        @{ Name = 'platform build Double'; Target = 'platform-build'; Pattern = 'raw Int32' },
        @{ Name = 'ACL deny count Decimal'; Target = 'acl-deny'; Pattern = 'raw Int32' },
        @{ Name = 'adoption schema Boolean'; Target = 'adoption-schema'; Pattern = 'raw Int32' },
        @{ Name = 'owned delete phase string'; Target = 'owned-delete'; Pattern = 'raw Int32' },
        @{ Name = 'ImmutableFile size Double'; Target = 'owned-size'; Pattern = 'raw Int32 or Int64' }
    )

    It 'rejects coerced primitive <Name> at canonical admission' `
        -TestCases $rawPrimitiveCases {
        param($Name, $Target, $Pattern)

        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $payload = New-CommMonitorOwnershipPayload @arguments
        switch ($Target) {
            'app-id' {
                $payload.appId = [Text.StringBuilder]::new($payload.appId)
            }
            'product-version' { $payload.productVersion = [char]'1' }
            'created-utc' {
                $payload.createdUtc = [Text.StringBuilder]::new($payload.createdUtc)
            }
            'platform-kind' {
                $payload.platform.kind = [Text.StringBuilder]::new('Desktop')
            }
            'root-role' {
                $payload.roots.appRoot.role = [Text.StringBuilder]::new('AppRoot')
            }
            'root-path' {
                $payload.roots.appRoot.canonicalPath =
                    [Text.StringBuilder]::new($payload.roots.appRoot.canonicalPath)
            }
            'acl-owner' {
                $payload.roots.appRoot.aclProfile.ownerSid =
                    [Text.StringBuilder]::new('S-1-5-18')
            }
            'adoption-source' {
                $payload.roots.dataRoot.adoptionSource =
                    New-CommMonitorTestLegacyAdoptionSource
                $payload.roots.dataRoot.adoptionSource.sourceKind =
                    [Text.StringBuilder]::new('ValidatedLegacyMarker')
            }
            'authorized-sid' {
                $payload.authorizedUser.sid =
                    [Text.StringBuilder]::new($payload.authorizedUser.sid)
            }
            'owned-id' {
                $payload.ownedObjects[0].objectId =
                    [Text.StringBuilder]::new($payload.ownedObjects[0].objectId)
            }
            'owned-hash' {
                $payload.ownedObjects[0].identity.sha256 =
                    [Text.StringBuilder]::new($payload.ownedObjects[0].identity.sha256)
            }
            'key-state' {
                $payload.keyMetadata.manifest.state =
                    [Text.StringBuilder]::new('Active')
            }
            'continuation-status' {
                $payload.continuationState.status =
                    [Text.StringBuilder]::new('None')
            }
            'operation-id' {
                $payload.state = 'UninstallRequested'
                $payload.operationState =
                    New-CommMonitorTestRequestedOperationState
                $payload.operationState.operationId =
                    [Text.StringBuilder]::new(
                        '11111111-1111-1111-1111-111111111111')
            }
            'root-active' { $payload.roots.appRoot.active = 'true' }
            'acl-protected' {
                $payload.roots.appRoot.aclProfile.areAccessRulesProtected = 1
            }
            'owned-remove' { $payload.ownedObjects[0].removeOnUninstall = 'true' }
            'owned-created' { $payload.ownedObjects[2].identity.created = 'true' }
            'upper-present' { $payload.upperFiltersRollback.present = 0 }
            'revision' { $payload.revision = '1' }
            'platform-build' { $payload.platform.build = [double]22631 }
            'acl-deny' {
                $payload.roots.appRoot.aclProfile.denyRuleCount = [decimal]0
            }
            'adoption-schema' {
                $payload.roots.dataRoot.adoptionSource =
                    New-CommMonitorTestLegacyAdoptionSource
                $payload.roots.dataRoot.adoptionSource.schemaVersion = $true
            }
            'owned-delete' { $payload.ownedObjects[0].deletePhase = '20' }
            'owned-size' { $payload.ownedObjects[0].identity.size = [double]1 }
        }

        $key = [byte[]](0..31)
        $keyId = Get-CommMonitorSha256Hex -Bytes $key
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $key `
                    -KeyId $keyId
            } `
            -MessagePattern $Pattern
    }

    $publicPayloadBinderCases = @(
        @{ Name = 'AppId StringBuilder'; Target = 'app-id'; Pattern = 'AppId.*raw string' },
        @{ Name = 'revision string'; Target = 'revision'; Pattern = 'Revision.*raw Int32' },
        @{ Name = 'productVersion StringBuilder'; Target = 'product-version'; Pattern = 'ProductVersion.*raw string' },
        @{ Name = 'createdUtc string'; Target = 'created-utc'; Pattern = 'CreatedUtc.*raw DateTimeOffset' },
        @{ Name = 'ownedObjects scalar record'; Target = 'owned'; Pattern = 'OwnedObjects.*raw System.Array' },
        @{ Name = 'state StringBuilder'; Target = 'state'; Pattern = 'State.*raw string' }
    )

    It 'rejects public NewPayload binder coercion of <Name>' `
        -TestCases $publicPayloadBinderCases {
        param($Name, $Target, $Pattern)

        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        switch ($Target) {
            'app-id' {
                $arguments.AppId = [Text.StringBuilder]::new($arguments.AppId)
            }
            'revision' { $arguments.Revision = '1' }
            'product-version' {
                $arguments.ProductVersion =
                    [Text.StringBuilder]::new($arguments.ProductVersion)
            }
            'created-utc' { $arguments.CreatedUtc = '2026-07-14T01:02:03Z' }
            'owned' { $arguments.OwnedObjects = $arguments.OwnedObjects[0] }
            'state' {
                $arguments.State = [Text.StringBuilder]::new('Committed')
            }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern $Pattern
    }

    $registryValueUnionRejectCases = @(
        @{ Name = 'Boolean'; Target = 'bool' },
        @{ Name = 'Double'; Target = 'double' },
        @{ Name = 'Decimal'; Target = 'decimal' },
        @{ Name = 'object'; Target = 'object' },
        @{ Name = 'byte array'; Target = 'bytes' },
        @{ Name = 'explicit null'; Target = 'null' },
        @{ Name = 'StringBuilder'; Target = 'builder' }
    )

    It 'rejects RegistryValue identity value <Name> outside the I5A raw union' `
        -TestCases $registryValueUnionRejectCases {
        param($Name, $Target)

        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $payload = New-CommMonitorOwnershipPayload @arguments
        $value = switch ($Target) {
            'bool' { $true }
            'double' { [double]7 }
            'decimal' { [decimal]7 }
            'object' { [ordered]@{ unexpected = 'object' } }
            'bytes' { [byte[]]@(1, 2, 3) }
            'null' { $null }
            'builder' { [Text.StringBuilder]::new('value') }
        }
        [void](Add-CommMonitorTestRegistryValueObject `
                -Payload $payload `
                -Value $value)
        $key = [byte[]](0..31)
        $keyId = Get-CommMonitorSha256Hex -Bytes $key
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $key `
                    -KeyId $keyId
            } `
            -MessagePattern 'RegistryValue identity value must be'
    }

    It 'rejects contentPolicy on every non-Directory owned object' {
        $definition = [ordered]@{
            objectId = 'dynamic-policy'
            type = 'DynamicFile'
            component = 'AiState'
            root = 'AiStateRoot'
            relativePath = 'state\policy.json'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            contentPolicy = 'EmptyAfterOwnedChildren'
            identity = [ordered]@{}
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $definition } `
            -MessagePattern "Owned object contains unknown field 'contentPolicy'"
    }

    It 'rejects AliasProperty at a newly authoritative nested record' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $record = [pscustomobject]$arguments.Roots.AppRoot
        $record | Add-Member -MemberType AliasProperty -Name injectedAlias -Value Role
        $arguments.Roots.AppRoot = $record
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'unsupported property member type.*AliasProperty'
    }

    It 'rejects ScriptProperty at a newly authoritative nested record without invoking it' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $record = [pscustomobject]$arguments.Roots.AppRoot
        $record | Add-Member `
            -MemberType ScriptProperty `
            -Name injectedScript `
            -Value { throw 'dynamic schema code executed' }
        $arguments.Roots.AppRoot = $record
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'unsupported property member type.*ScriptProperty'
    }

    It 'rejects CodeProperty at newly authoritative records and owned identities' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $record = [pscustomobject]$arguments.Roots.AppRoot
        Add-CommMonitorTestCodeProperty -InputObject $record
        $arguments.Roots.AppRoot = $record
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'unsupported property member type.*CodeProperty'

        $definition = [ordered]@{
            objectId = 'dynamic-code'
            type = 'DynamicFile'
            component = 'AiState'
            root = 'AiStateRoot'
            relativePath = 'state\code.json'
            ownershipProof = 'CreatedThisInstall'
            removeOnUninstall = $true
            deletePhase = 20
            identity = [pscustomobject]@{}
        }
        Add-CommMonitorTestCodeProperty -InputObject $definition.identity
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $definition } `
            -MessagePattern 'unsupported property member type.*CodeProperty'
    }
}

Describe 'CommMonitor extended platform ownership policy' {
    $extendedPolicyPositiveCases = @(
        @{
            Name = 'AppRoot root directory'
            Type = 'Directory'; Component = 'RootDirectory'; Root = 'AppRoot'
        },
        @{
            Name = 'CoreRoot root directory'
            Type = 'Directory'; Component = 'RootDirectory'; Root = 'CoreRoot'
        },
        @{
            Name = 'Server Core AI CLI'
            Type = 'ImmutableFile'; Component = 'AiCli'; Root = 'CoreRoot'
        },
        @{
            Name = 'optional desktop shortcut'
            Type = 'Shortcut'; Component = 'DesktopShortcut'; Root = 'Desktop'
        },
        @{
            Name = 'desktop AppRoot documentation'
            Type = 'ImmutableFile'; Component = 'Docs'; Root = 'AppRoot'
        },
        @{
            Name = 'Server Core documentation file'
            Type = 'ImmutableFile'; Component = 'Docs'; Root = 'CoreRoot'
        },
        @{
            Name = 'desktop documentation directory'
            Type = 'Directory'; Component = 'Docs'; Root = 'AppRoot'
        },
        @{
            Name = 'Server Core documentation directory'
            Type = 'Directory'; Component = 'Docs'; Root = 'CoreRoot'
        })

    It 'accepts the extended policy pair for <Name>' `
        -TestCases $extendedPolicyPositiveCases {
        param($Name, $Type, $Component, $Root)

        $definition = switch ($Type) {
            'ImmutableFile' {
                [ordered]@{
                    objectId = 'policy-immutable'
                    type = 'ImmutableFile'; component = $Component; root = $Root
                    relativePath = 'docs\guide.pdf'
                    ownershipProof = 'CreatedThisInstall'
                    removeOnUninstall = $true; deletePhase = 20
                    identity = [ordered]@{
                        size = 1; sha256 = ('1' * 64)
                        productMarker = 'CommMonitor:0.1.0'
                    }
                }
            }
            'Directory' {
                [ordered]@{
                    objectId = 'policy-directory'
                    type = 'Directory'; component = $Component; root = $Root
                    relativePath = if ($Component -eq 'RootDirectory') { '' } else { 'docs' }
                    ownershipProof = 'CreatedThisInstall'
                    removeOnUninstall = $true; deletePhase = 90
                    contentPolicy = 'EmptyAfterOwnedChildren'
                    identity = [ordered]@{ created = $true }
                }
            }
            'Shortcut' {
                [ordered]@{
                    objectId = 'policy-shortcut'
                    type = 'Shortcut'; component = $Component; root = $Root
                    relativePath = 'Lemon串口监控.lnk'
                    ownershipProof = 'CreatedThisInstall'
                    removeOnUninstall = $true; deletePhase = 10
                    identity = [ordered]@{
                        target = 'C:\Program Files\Lemon串口监控\CommMonitor.App.exe'
                        arguments = ''
                        workingDirectory = 'C:\Program Files\Lemon串口监控'
                        fileSha256 = ('2' * 64); created = $true
                    }
                }
            }
        }
        { New-CommMonitorOwnedObject -Definition $definition } | Should Not Throw
    }

    It 'rejects the extended policy mismatch <Name>' `
        -TestCases @(
            @{
                Name = 'RootDirectory under DataRoot'
                Type = 'Directory'; Component = 'RootDirectory'; Root = 'DataRoot'
            },
            @{
                Name = 'DesktopShortcut in StartMenu'
                Type = 'Shortcut'; Component = 'DesktopShortcut'; Root = 'StartMenu'
            },
            @{
                Name = 'AiCli in InstallerRoot'
                Type = 'ImmutableFile'; Component = 'AiCli'; Root = 'InstallerRoot'
            },
            @{
                Name = 'DesktopShortcut under AppRoot'
                Type = 'Shortcut'; Component = 'DesktopShortcut'; Root = 'AppRoot'
            },
            @{
                Name = 'Docs in InstallerRoot'
                Type = 'ImmutableFile'; Component = 'Docs'; Root = 'InstallerRoot'
            }) {
        param($Name, $Type, $Component, $Root)

        $definition = if ($Type -eq 'Shortcut') {
            [ordered]@{
                objectId = 'bad-policy-shortcut'
                type = $Type; component = $Component; root = $Root
                relativePath = 'bad.lnk'; ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true; deletePhase = 10
                identity = [ordered]@{
                    target = 'C:\Program Files\Lemon串口监控\CommMonitor.App.exe'
                    arguments = ''; workingDirectory = 'C:\Program Files\Lemon串口监控'
                    fileSha256 = ('3' * 64); created = $true
                }
            }
        }
        elseif ($Type -eq 'Directory') {
            [ordered]@{
                objectId = 'bad-policy-directory'
                type = $Type; component = $Component; root = $Root
                relativePath = ''; ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true; deletePhase = 90
                contentPolicy = 'EmptyAfterOwnedChildren'
                identity = [ordered]@{ created = $true }
            }
        }
        else {
            [ordered]@{
                objectId = 'bad-policy-immutable'
                type = $Type; component = $Component; root = $Root
                relativePath = 'bad.exe'; ownershipProof = 'CreatedThisInstall'
                removeOnUninstall = $true; deletePhase = 20
                identity = [ordered]@{
                    size = 1; sha256 = ('4' * 64)
                    productMarker = 'CommMonitor:0.1.0'
                }
            }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnedObject -Definition $definition } `
            -MessagePattern 'owned-object (?:type/root|component) policy'
    }
}

Describe 'CommMonitor closed platform ownership layout semantics' {
    BeforeEach {
        $layoutSemanticKey = [byte[]](0..31)
        $layoutSemanticKeyId = Get-CommMonitorSha256Hex -Bytes $layoutSemanticKey
    }

    $layoutPositiveCases = @(
        @{ Name = 'Desktop'; PlatformKind = 'Desktop'; RootMode = 'Created'; DesktopShortcut = $false },
        @{
            Name = 'ServerDesktop'
            PlatformKind = 'ServerDesktop'
            RootMode = 'Created'
            DesktopShortcut = $false
        },
        @{
            Name = 'ServerCore'
            PlatformKind = 'ServerCore'
            RootMode = 'Created'
            DesktopShortcut = $false
        },
        @{
            Name = 'pre-existing CoreRoot'
            PlatformKind = 'Desktop'
            RootMode = 'PreExistingCore'
            DesktopShortcut = $false
        },
        @{
            Name = 'Desktop with optional shortcut'
            PlatformKind = 'Desktop'
            RootMode = 'Created'
            DesktopShortcut = $true
        })

    It 'accepts the complete <Name> ownership layout' -TestCases $layoutPositiveCases {
        param($Name, $PlatformKind, $RootMode, $DesktopShortcut)

        $payload = New-CommMonitorTestOwnershipPayloadForPlatform `
            -PlatformKind $PlatformKind `
            -RootMode $RootMode
        if ($DesktopShortcut) {
            Add-CommMonitorTestOwnedSemanticDefinition `
                -Payload $payload `
                -Definition (New-CommMonitorTestDesktopShortcutDefinition)
        }
        {
            New-CommMonitorOwnershipEnvelope `
                -Payload $payload `
                -Key $layoutSemanticKey `
                -KeyId $layoutSemanticKeyId
        } | Should Not Throw
    }

    $layoutNegativeCases = @(
        @{ Name = 'missing AppRoot directory'; Scenario = 'missing-app-root' },
        @{ Name = 'missing CoreRoot directory'; Scenario = 'missing-core-root' },
        @{ Name = 'duplicate AppRoot directory'; Scenario = 'duplicate-app-root' },
        @{ Name = 'ServerCore AppRoot directory'; Scenario = 'server-app-root' },
        @{ Name = 'non-root RootDirectory path'; Scenario = 'root-relative' },
        @{ Name = 'root-directory proof mismatch'; Scenario = 'root-proof' },
        @{ Name = 'root-directory removal mismatch'; Scenario = 'root-remove' },
        @{ Name = 'root-directory early delete phase'; Scenario = 'root-phase' },
        @{ Name = 'Desktop AI CLI under CoreRoot'; Scenario = 'desktop-ai-core' },
        @{ Name = 'ServerCore AI CLI under AppRoot'; Scenario = 'server-ai-app' },
        @{ Name = 'Desktop missing AI CLI'; Scenario = 'desktop-missing-ai' },
        @{ Name = 'ServerCore missing AI CLI'; Scenario = 'server-missing-ai' },
        @{ Name = 'ServerCore missing headless executable'; Scenario = 'server-missing-headless' },
        @{ Name = 'Desktop missing executable'; Scenario = 'desktop-missing-exe' },
        @{ Name = 'duplicate optional desktop shortcut'; Scenario = 'desktop-shortcut-duplicate' },
        @{ Name = 'ServerCore shortcut'; Scenario = 'server-shortcut' },
        @{ Name = 'Desktop missing Start Menu shortcut'; Scenario = 'start-missing' },
        @{ Name = 'duplicate Start Menu shortcut'; Scenario = 'start-duplicate' },
        @{ Name = 'Desktop docs under CoreRoot'; Scenario = 'desktop-docs-core' },
        @{ Name = 'ServerCore docs under AppRoot'; Scenario = 'server-docs-app' },
        @{ Name = 'ServerCore arbitrary AppRoot file'; Scenario = 'server-app-file' })

    It 'rejects <Name> at the shared layout semantic gate' `
        -TestCases $layoutNegativeCases {
        param($Name, $Scenario)

        $serverCore = $Scenario -like 'server-*'
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform `
            -PlatformKind $(if ($serverCore) { 'ServerCore' } else { 'Desktop' })
        switch ($Scenario) {
            'missing-app-root' {
                $payload.ownedObjects = [object[]]@(
                    $payload.ownedObjects |
                        Where-Object objectId -ne 'app-root-directory')
            }
            'missing-core-root' {
                $payload.ownedObjects = [object[]]@(
                    $payload.ownedObjects |
                        Where-Object objectId -ne 'core-root-directory')
            }
            'duplicate-app-root' {
                Add-CommMonitorTestOwnedSemanticDefinition `
                    -Payload $payload `
                    -Definition (New-CommMonitorTestRootDirectoryDefinition `
                        -Root AppRoot `
                        -ObjectId 'duplicate-app-root-directory')
            }
            'server-app-root' {
                Add-CommMonitorTestOwnedSemanticDefinition `
                    -Payload $payload `
                    -Definition (New-CommMonitorTestRootDirectoryDefinition `
                        -Root AppRoot `
                        -ObjectId 'server-app-root-directory')
            }
            'root-relative' {
                $rootDirectory = @(
                    $payload.ownedObjects |
                        Where-Object objectId -eq 'app-root-directory')[0]
                $rootDirectory.relativePath = 'shell'
            }
            'root-proof' {
                $rootDirectory = @(
                    $payload.ownedObjects |
                        Where-Object objectId -eq 'app-root-directory')[0]
                $rootDirectory.ownershipProof = 'VerifiedLegacyAdoption'
                $rootDirectory.identity.created = $false
            }
            'root-remove' {
                $rootDirectory = @(
                    $payload.ownedObjects |
                        Where-Object objectId -eq 'app-root-directory')[0]
                $rootDirectory.removeOnUninstall = $false
            }
            'root-phase' {
                $rootDirectory = @(
                    $payload.ownedObjects |
                        Where-Object objectId -eq 'app-root-directory')[0]
                $rootDirectory.deletePhase = 20
            }
            'desktop-ai-core' {
                $aiCli = @(
                    $payload.ownedObjects | Where-Object objectId -eq 'ai-cli')[0]
                $aiCli.root = 'CoreRoot'
            }
            'server-ai-app' {
                $aiCli = @(
                    $payload.ownedObjects |
                        Where-Object objectId -eq 'server-core-ai-cli')[0]
                $aiCli.root = 'AppRoot'
            }
            'desktop-missing-ai' {
                $payload.ownedObjects = [object[]]@(
                    $payload.ownedObjects | Where-Object component -ne 'AiCli')
            }
            'server-missing-ai' {
                $payload.ownedObjects = [object[]]@(
                    $payload.ownedObjects | Where-Object component -ne 'AiCli')
            }
            'server-missing-headless' {
                $payload.ownedObjects = [object[]]@(
                    $payload.ownedObjects | Where-Object component -ne 'Headless')
            }
            'desktop-missing-exe' {
                $payload.ownedObjects = [object[]]@(
                    $payload.ownedObjects |
                        Where-Object component -ne 'DesktopExecutable')
            }
            'desktop-shortcut-duplicate' {
                Add-CommMonitorTestOwnedSemanticDefinition `
                    -Payload $payload `
                    -Definition (New-CommMonitorTestDesktopShortcutDefinition `
                        -ObjectId 'desktop-shortcut-one' `
                        -RelativePath 'One.lnk')
                Add-CommMonitorTestOwnedSemanticDefinition `
                    -Payload $payload `
                    -Definition (New-CommMonitorTestDesktopShortcutDefinition `
                        -ObjectId 'desktop-shortcut-two' `
                        -RelativePath 'Two.lnk')
            }
            'server-shortcut' {
                Add-CommMonitorTestOwnedSemanticDefinition `
                    -Payload $payload `
                    -Definition (New-CommMonitorTestDesktopShortcutDefinition)
            }
            'start-missing' {
                $payload.ownedObjects = [object[]]@(
                    $payload.ownedObjects |
                        Where-Object component -ne 'StartMenuShortcut')
            }
            'start-duplicate' {
                $duplicate = Copy-CommMonitorTestOrdinalDictionary -InputObject @(
                    $payload.ownedObjects | Where-Object objectId -eq 'start-menu')[0]
                $duplicate.objectId = 'start-menu-duplicate'
                $duplicate.relativePath = 'Lemon串口监控-重复.lnk'
                Add-CommMonitorTestOwnedSemanticDefinition `
                    -Payload $payload `
                    -Definition $duplicate
            }
            'desktop-docs-core' {
                Add-CommMonitorTestOwnedSemanticDefinition `
                    -Payload $payload `
                    -Definition (New-CommMonitorTestDocsDefinition -Root CoreRoot)
            }
            'server-docs-app' {
                Add-CommMonitorTestOwnedSemanticDefinition `
                    -Payload $payload `
                    -Definition (New-CommMonitorTestDocsDefinition -Root AppRoot)
            }
            'server-app-file' {
                $definition = New-CommMonitorTestDocsDefinition `
                    -Root AppRoot `
                    -ObjectId 'server-app-file'
                $definition.component = 'Docs'
                Add-CommMonitorTestOwnedSemanticDefinition `
                    -Payload $payload `
                    -Definition $definition
            }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $layoutSemanticKey `
                    -KeyId $layoutSemanticKeyId
            } `
            -MessagePattern 'Ownership layout semantics'
    }

    It 'wires layout semantics through <Authority>' `
        -TestCases @(
            @{ Authority = 'NewPayload' },
            @{ Authority = 'NewEnvelope' }) {
        param($Authority)

        if ($Authority -eq 'NewPayload') {
            $arguments = New-CommMonitorTestOwnershipPayloadArguments
            $arguments.OwnedObjects = [object[]]@(
                $arguments.OwnedObjects |
                    Where-Object objectId -ne 'app-root-directory')
            Assert-CommMonitorTestThrowsLike `
                -Action { New-CommMonitorOwnershipPayload @arguments } `
                -MessagePattern 'Ownership layout semantics'
        }
        else {
            $payload = New-CommMonitorTestOwnershipPayloadForPlatform
            $payload.ownedObjects = [object[]]@(
                $payload.ownedObjects |
                    Where-Object objectId -ne 'app-root-directory')
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    New-CommMonitorOwnershipEnvelope `
                        -Payload $payload `
                        -Key $layoutSemanticKey `
                        -KeyId $layoutSemanticKeyId
                } `
                -MessagePattern 'Ownership layout semantics'
        }
    }
}

Describe 'CommMonitor committed ownership state semantics' {
    BeforeEach {
        $committedStateKey = [byte[]](0..31)
        $committedStateKeyId = Get-CommMonitorSha256Hex -Bytes $committedStateKey
    }

    It 'accepts the closed Committed baseline through both constructors' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $payload = New-CommMonitorOwnershipPayload @arguments
        {
            New-CommMonitorOwnershipEnvelope `
                -Payload $payload `
                -Key $committedStateKey `
                -KeyId $committedStateKeyId
        } | Should Not Throw
    }

    It 'does not apply Committed-only closure to an uninstall request' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $payload.state = 'UninstallRequested'
        $payload.operationState =
            New-CommMonitorTestRequestedOperationState
        {
            New-CommMonitorOwnershipEnvelope `
                -Payload $payload `
                -Key $committedStateKey `
                -KeyId $committedStateKeyId
        } | Should Not Throw
    }

    It 'rejects a Committed payload with an active continuation status' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.ContinuationState = [ordered]@{ status = 'Prepared' }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Ownership state semantics'
    }

    It 'rejects a Committed payload with an operation identity' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.OperationState = [ordered]@{
            operationId = '11111111-1111-1111-1111-111111111111'
        }
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Ownership operation semantics'
    }

    It 'rejects continuation metadata in a Committed snapshot' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $metadata =
            New-CommMonitorTestOwnedSemanticDefinition -Type ContinuationMetadata
        Add-CommMonitorTestOwnedSemanticDefinition `
            -Payload $arguments `
            -Definition $metadata
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Ownership state semantics'
    }

    It 'rejects a continuation task in a Committed snapshot' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        [void](Add-CommMonitorTestContinuationSemanticBundle `
                -Payload $arguments)
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Ownership state semantics'
    }

    It 'rejects a non-Active manifest key state' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.KeyMetadata.manifest.state = 'Retired'
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Ownership state semantics'
    }

    It 'rejects a noncanonical manifest key identifier' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.KeyMetadata.manifest.keyId = ('D' * 64)
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Ownership state semantics'
    }

    It 'wires Committed closure through NewEnvelope' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $payload.continuationState.status = 'Prepared'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $committedStateKey `
                    -KeyId $committedStateKeyId
            } `
            -MessagePattern 'Ownership state semantics'
    }
}

Describe 'CommMonitor authenticated uninstall operation schema' {
    It 'accepts a fully bound UninstallRequested operation' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.State = 'UninstallRequested'
        $arguments.OperationState =
            New-CommMonitorTestRequestedOperationState
        { New-CommMonitorOwnershipPayload @arguments } | Should Not Throw
    }

    It 'accepts a fully bound UninstallPrepared dynamic snapshot' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.State = 'UninstallPrepared'
        [void](Add-CommMonitorTestDynamicOperationObject -Payload $arguments)
        $operation = New-CommMonitorTestRequestedOperationState `
            -PendingObjectIds ([string[]]@('semantic-dynamic'))
        $operation['preparedTargets'] = [object[]]@(
            (New-CommMonitorTestPreparedTarget))
        $operation['preparedUtc'] = '2026-07-14T02:04:04.0000000Z'
        $arguments.OperationState = $operation
        { New-CommMonitorOwnershipPayload @arguments } | Should Not Throw
    }

    It 'accepts an Abandoned attempt without prepared targets' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.State = 'Abandoned'
        $operation = New-CommMonitorTestRequestedOperationState
        $operation['preparedTargets'] = [object[]]@()
        $operation['preparedUtc'] = $null
        $operation['abandonedReason'] = 'HelperExited'
        $operation['abandonedUtc'] = '2026-07-14T02:05:04.0000000Z'
        $arguments.OperationState = $operation
        { New-CommMonitorOwnershipPayload @arguments } | Should Not Throw
    }

    It 'accepts a PendingReboot operation with held identity evidence' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.State = 'PendingReboot'
        $arguments.ContinuationState = [ordered]@{ status = 'Active' }
        [void](Add-CommMonitorTestDynamicOperationObject -Payload $arguments)
        $operation = New-CommMonitorTestRequestedOperationState `
            -PendingObjectIds ([string[]]@('semantic-dynamic'))
        $operation['preparedTargets'] = [object[]]@(
            (New-CommMonitorTestPreparedTarget))
        $operation['preparedUtc'] = '2026-07-14T02:04:04.0000000Z'
        $operation['pendingRebootUtc'] = '2026-07-14T02:06:04.0000000Z'
        $arguments.OperationState = $operation
        { New-CommMonitorOwnershipPayload @arguments } | Should Not Throw
    }

    It 'accepts a FinalizingAbsent terminal authority binding' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.State = 'FinalizingAbsent'
        $arguments.OperationState = [ordered]@{
            operationId = '11111111-1111-1111-1111-111111111111'
            terminalCleanupId = '22222222-2222-2222-2222-222222222222'
            terminalKeyId = ('5' * 64)
            terminalEnvelopeSha256 = ('6' * 64)
            finalizingUtc = '2026-07-14T02:07:04.0000000Z'
        }
        { New-CommMonitorOwnershipPayload @arguments } | Should Not Throw
    }

    $requestedOperationMutationCases = @(
        @{ Name = 'missing nonce'; Scenario = 'missing-nonce' },
        @{ Name = 'unknown field'; Scenario = 'unknown' },
        @{ Name = 'wrong-case helper hash'; Scenario = 'wrong-case' },
        @{ Name = 'uppercase operation GUID'; Scenario = 'operation-id' },
        @{ Name = 'short nonce'; Scenario = 'nonce' },
        @{ Name = 'unbound result path'; Scenario = 'result-path' },
        @{ Name = 'uppercase helper hash'; Scenario = 'helper-hash' },
        @{ Name = 'duplicate pending IDs'; Scenario = 'pending-duplicate' },
        @{ Name = 'non-UTC request time'; Scenario = 'requested-utc' })

    It 'rejects requested operation <Name>' `
        -TestCases $requestedOperationMutationCases {
        param($Name, $Scenario)

        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.State = 'UninstallRequested'
        $operation = New-CommMonitorTestRequestedOperationState
        switch ($Scenario) {
            'missing-nonce' { [void]$operation.Remove('nonce') }
            'unknown' { $operation['unexpected'] = $true }
            'wrong-case' {
                [void]$operation.Remove('helperSha256')
                $operation['HelperSha256'] = ('2' * 64)
            }
            'operation-id' {
                $operation.operationId =
                    'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA'
                $operation.resultRelativePath =
                    'state\results\AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.v1.json'
            }
            'nonce' { $operation.nonce = ('1' * 62) }
            'result-path' {
                $operation.resultRelativePath =
                    'state\results\other.v1.json'
            }
            'helper-hash' { $operation.helperSha256 = ('A' * 64) }
            'pending-duplicate' {
                $operation.pendingObjectIds =
                    [string[]]@('desktop-exe', 'desktop-exe')
            }
            'requested-utc' {
                $operation.requestedUtc =
                    '2026-07-14T10:03:04.0000000+08:00'
            }
        }
        $arguments.OperationState = $operation
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Ownership operation semantics'
    }

    It 'rejects an operation pending object that is absent' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.State = 'UninstallRequested'
        $arguments.OperationState =
            New-CommMonitorTestRequestedOperationState `
                -PendingObjectIds ([string[]]@('missing-object'))
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Ownership operation semantics'
    }

    It 'rejects an operation pending object that is not removable' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform `
            -RootMode PreExistingCore
        $payload.state = 'UninstallRequested'
        $payload.operationState =
            New-CommMonitorTestRequestedOperationState `
                -PendingObjectIds ([string[]]@('core-root-directory'))
        $key = [byte[]](0..31)
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $key `
                    -KeyId (Get-CommMonitorSha256Hex -Bytes $key)
            } `
            -MessagePattern 'Ownership operation semantics'
    }

    $preparedTargetMutationCases = @(
        @{ Name = 'missing target'; Scenario = 'missing' },
        @{ Name = 'extra target'; Scenario = 'extra' },
        @{ Name = 'duplicate target'; Scenario = 'duplicate' },
        @{ Name = 'short volume serial'; Scenario = 'volume' },
        @{ Name = 'short file ID'; Scenario = 'file-id' },
        @{ Name = 'negative size'; Scenario = 'size' },
        @{ Name = 'uppercase digest'; Scenario = 'sha' })

    It 'rejects prepared snapshot <Name>' `
        -TestCases $preparedTargetMutationCases {
        param($Name, $Scenario)

        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.State = 'UninstallPrepared'
        [void](Add-CommMonitorTestDynamicOperationObject -Payload $arguments)
        $operation = New-CommMonitorTestRequestedOperationState `
            -PendingObjectIds ([string[]]@('semantic-dynamic'))
        $target = New-CommMonitorTestPreparedTarget
        $operation['preparedTargets'] = [object[]]@($target)
        $operation['preparedUtc'] = '2026-07-14T02:04:04.0000000Z'
        switch ($Scenario) {
            'missing' { $operation.preparedTargets = [object[]]@() }
            'extra' {
                $operation.preparedTargets = [object[]]@(
                    (New-CommMonitorTestPreparedTarget `
                        -ObjectId 'desktop-exe'))
            }
            'duplicate' {
                $operation.preparedTargets = [object[]]@(
                    $target,
                    (New-CommMonitorTestPreparedTarget))
            }
            'volume' { $target.volumeSerialNumber = ('0' * 14) }
            'file-id' { $target.fileId = ('3' * 30) }
            'size' { $target.size = [long]-1 }
            'sha' { $target.sha256 = ('A' * 64) }
        }
        $arguments.OperationState = $operation
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Ownership operation semantics'
    }

    It 'wires operation semantics through NewEnvelope' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $payload = New-CommMonitorOwnershipPayload @arguments
        $payload.state = 'UninstallRequested'
        $payload.operationState = New-CommMonitorTestRequestedOperationState
        $payload.operationState.resultRelativePath =
            'state\results\wrong.v1.json'
        $key = [byte[]](0..31)
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $key `
                    -KeyId (Get-CommMonitorSha256Hex -Bytes $key)
            } `
            -MessagePattern 'Ownership operation semantics'
    }
}

Describe 'CommMonitor canonical ownership fixture vectors' {
    BeforeEach {
        $fixtureRoot = Join-Path `
            $repoRoot `
            'tests\fixtures\installer\ownership-manifest-v3'
    }

    It 'sorts schema set arrays and owned objects while preserving ordered arrays' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.Platform.components = [string[]]@(
            'StartMenuShortcut', 'WPF', 'AI', 'Driver', 'Service')
        $arguments.Roots.AppRoot.AclProfile.AllowedFullControlSids =
            [string[]]@('S-1-5-32-544', 'S-1-5-18')
        $reversedObjects = [object[]]@($arguments.OwnedObjects)
        [Array]::Reverse($reversedObjects)
        $arguments.OwnedObjects = $reversedObjects
        $arguments.UpperFiltersRollback = [ordered]@{
            present = $true
            value = [string[]]@('z-filter', 'a-filter', 'z-filter')
        }
        $registryValue =
            New-CommMonitorTestOwnedSemanticDefinition -Type RegistryValue
        $registryValue.identity.kind = 'MultiString'
        $registryValue.identity.value =
            [string[]]@('z-value', 'a-value', 'z-value')
        Add-CommMonitorTestOwnedSemanticDefinition `
            -Payload $arguments `
            -Definition $registryValue

        $payload = New-CommMonitorOwnershipPayload @arguments
        [string]::Join(',', $payload.platform.components) |
            Should Be 'AI,Driver,Service,StartMenuShortcut,WPF'
        [string]::Join(
            ',',
            $payload.roots.appRoot.aclProfile.allowedFullControlSids) |
            Should Be 'S-1-5-18,S-1-5-32-544'
        [string]::Join(',', $payload.upperFiltersRollback.value) |
            Should Be 'z-filter,a-filter,z-filter'
        $registeredValue = @(
            $payload.ownedObjects |
                Where-Object objectId -eq 'semantic-registry-value')[0]
        [string]::Join(',', $registeredValue.identity.value) |
            Should Be 'z-value,a-value,z-value'

        $objectIds = [string[]]@(
            $payload.ownedObjects | ForEach-Object { [string]$_.objectId })
        $expectedIds = [string[]]@($objectIds)
        [Array]::Sort($expectedIds, [StringComparer]::Ordinal)
        [string]::Join(',', $objectIds) |
            Should Be ([string]::Join(',', $expectedIds))
    }

    It 'rejects duplicate ACL set members before authentication' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.Roots.AppRoot.AclProfile.AllowedFullControlSids =
            [string[]]@('S-1-5-18', 'S-1-5-18')
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'canonical set.*duplicate'
    }

    It 'rejects duplicate continuation pending-object set members' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.State = 'UninstallPrepared'
        $arguments.OperationState =
            New-CommMonitorTestRequestedOperationState
        $arguments.OperationState['preparedTargets'] = [object[]]@()
        $arguments.OperationState['preparedUtc'] =
            '2026-07-14T02:04:04.0000000Z'
        $metadata =
            New-CommMonitorTestOwnedSemanticDefinition -Type ContinuationMetadata
        $metadata.identity.pendingObjectIds =
            [string[]]@('desktop-exe', 'desktop-exe')
        Add-CommMonitorTestOwnedSemanticDefinition `
            -Payload $arguments `
            -Definition $metadata
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'canonical set.*duplicate'
    }

    It 'emits no-newline authentication bytes and single-LF state-file bytes' {
        $sample = [ordered]@{ z = "串口`n监控"; a = 1 }
        $authenticationBytes =
            Get-CommMonitorCanonicalJsonBytes -InputObject $sample
        $diskBytes =
            Get-CommMonitorCanonicalStateFileBytes -InputObject $sample
        $expectedBody = '{"a":1,"z":"串口\n监控"}'

        [Text.Encoding]::UTF8.GetString($authenticationBytes) |
            Should Be $expectedBody
        $authenticationBytes[0] | Should Not Be 0xef
        ($authenticationBytes -contains [byte]0x0d) | Should Be $false
        $diskBytes.Length | Should Be ($authenticationBytes.Length + 1)
        $diskBytes[$diskBytes.Length - 1] | Should Be 0x0a
        [Convert]::ToBase64String(
            $diskBytes[0..($diskBytes.Length - 2)]) |
            Should Be ([Convert]::ToBase64String($authenticationBytes))
    }

    It 'checks in exact auth disk and vector files protected from EOL conversion' {
        $expectedAttributes = [string[]]@(
            'auth/** -text',
            'disk/** -text',
            'vectors/** -text')
        $attributePath = Join-Path $fixtureRoot '.gitattributes'
        (Test-Path -LiteralPath $attributePath -PathType Leaf) | Should Be $true
        $attributeLines = [IO.File]::ReadAllLines(
            $attributePath,
            [Text.UTF8Encoding]::new($false))
        [string]::Join("`n", $attributeLines) |
            Should Be ([string]::Join("`n", $expectedAttributes))

        foreach ($relativePath in @(
                'auth\payload.json',
                'auth\anchor-binding.json',
                'disk\ownership-manifest.v3.json',
                'disk\install-anchor.v3.json',
                'vectors\desktop-v3.json')) {
            (Test-Path `
                    -LiteralPath (Join-Path $fixtureRoot $relativePath) `
                    -PathType Leaf) | Should Be $true
        }
    }

    It 'matches the exact fixture bytes and hashes under every contract culture' {
        $payloadFixture = [IO.File]::ReadAllBytes(
            (Join-Path $fixtureRoot 'auth\payload.json'))
        $bindingFixture = [IO.File]::ReadAllBytes(
            (Join-Path $fixtureRoot 'auth\anchor-binding.json'))
        $envelopeFixture = [IO.File]::ReadAllBytes(
            (Join-Path $fixtureRoot 'disk\ownership-manifest.v3.json'))
        $anchorFixture = [IO.File]::ReadAllBytes(
            (Join-Path $fixtureRoot 'disk\install-anchor.v3.json'))
        $vectorBytes = [IO.File]::ReadAllBytes(
            (Join-Path $fixtureRoot 'vectors\desktop-v3.json'))
        $vectorText = [Text.Encoding]::UTF8.GetString($vectorBytes)
        $vector = $vectorText.TrimEnd("`n") | ConvertFrom-Json

        $vector.schemaVersion | Should Be 3
        $vector.algorithm | Should Be 'HMAC-SHA256'
        $vector.keyLength | Should Be 32
        $vector.keyHex | Should Be (
            '000102030405060708090a0b0c0d0e0f' +
            '101112131415161718191a1b1c1d1e1f')
        [string]::Join(',', [string[]]$vector.cultures) |
            Should Be 'en-US,tr-TR,zh-CN'

        foreach ($diskFixture in @($envelopeFixture, $anchorFixture)) {
            $diskFixture[$diskFixture.Length - 1] | Should Be 0x0a
            $diskFixture[$diskFixture.Length - 2] | Should Not Be 0x0a
            ($diskFixture -contains [byte]0x0d) | Should Be $false
        }
        foreach ($authFixture in @($payloadFixture, $bindingFixture)) {
            $authFixture[$authFixture.Length - 1] | Should Not Be 0x0a
            ($authFixture -contains [byte]0x0d) | Should Be $false
        }

        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        $originalUiCulture = [Globalization.CultureInfo]::CurrentUICulture
        try {
            foreach ($cultureName in @('en-US', 'tr-TR', 'zh-CN')) {
                [Globalization.CultureInfo]::CurrentCulture =
                    [Globalization.CultureInfo]::GetCultureInfo($cultureName)
                [Globalization.CultureInfo]::CurrentUICulture =
                    [Globalization.CultureInfo]::GetCultureInfo($cultureName)
                $material = New-CommMonitorTestCanonicalFixtureMaterial

                [Convert]::ToBase64String($material.PayloadBytes) |
                    Should Be ([Convert]::ToBase64String($payloadFixture))
                [Convert]::ToBase64String($material.AnchorBindingBytes) |
                    Should Be ([Convert]::ToBase64String($bindingFixture))
                [Convert]::ToBase64String($material.ManifestDiskBytes) |
                    Should Be ([Convert]::ToBase64String($envelopeFixture))
                [Convert]::ToBase64String($material.AnchorDiskBytes) |
                    Should Be ([Convert]::ToBase64String($anchorFixture))

                $material.KeyId | Should Be $vector.keyId
                $material.PayloadBytes.Length | Should Be $vector.payload.authLength
                (Get-CommMonitorSha256Hex -Bytes $material.PayloadBytes) |
                    Should Be $vector.payload.authSha256
                (Get-CommMonitorHmacSha256Hex `
                        -Key $material.Key `
                        -Bytes $material.PayloadBytes) |
                    Should Be $vector.payload.tag
                $material.AnchorBindingBytes.Length |
                    Should Be $vector.anchor.authLength
                (Get-CommMonitorSha256Hex -Bytes $material.AnchorBindingBytes) |
                    Should Be $vector.anchor.authSha256
                (Get-CommMonitorHmacSha256Hex `
                        -Key $material.Key `
                        -Bytes $material.AnchorBindingBytes) |
                    Should Be $vector.anchor.tag
                $material.ManifestDiskBytes.Length |
                    Should Be $vector.manifest.diskLength
                (Get-CommMonitorSha256Hex -Bytes $material.ManifestDiskBytes) |
                    Should Be $vector.manifest.diskSha256
                $material.AnchorDiskBytes.Length |
                    Should Be $vector.anchor.diskLength
                (Get-CommMonitorSha256Hex -Bytes $material.AnchorDiskBytes) |
                    Should Be $vector.anchor.diskSha256
            }
        }
        finally {
            [Globalization.CultureInfo]::CurrentCulture = $originalCulture
            [Globalization.CultureInfo]::CurrentUICulture = $originalUiCulture
        }
    }
}

Describe 'CommMonitor cross-object ownership semantics' {
    BeforeEach {
        $crossSemanticKey = [byte[]](0..31)
        $crossSemanticKeyId = Get-CommMonitorSha256Hex -Bytes $crossSemanticKey
    }

    It 'accepts a fully bound object graph through NewPayload' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $arguments.State = 'PendingReboot'
        $arguments.ContinuationState = [ordered]@{ status = 'Active' }
        $arguments.OperationState =
            New-CommMonitorTestRequestedOperationState
        $arguments.OperationState['preparedTargets'] = [object[]]@()
        $arguments.OperationState['preparedUtc'] =
            '2026-07-14T02:04:04.0000000Z'
        $arguments.OperationState['pendingRebootUtc'] =
            '2026-07-14T02:06:04.0000000Z'
        [void](Add-CommMonitorTestRegistrySemanticBundle -Payload $arguments)
        [void](Add-CommMonitorTestServiceSemanticBundle -Payload $arguments)
        [void](Add-CommMonitorTestContinuationSemanticBundle -Payload $arguments)
        [void](Add-CommMonitorTestKeyMetadataSemanticObject -Payload $arguments)

        { New-CommMonitorOwnershipPayload @arguments } | Should Not Throw
    }

    It 'accepts a fully bound object graph through NewEnvelope' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $payload.state = 'PendingReboot'
        $payload.continuationState = [ordered]@{ status = 'Active' }
        $payload.operationState =
            New-CommMonitorTestRequestedOperationState
        $payload.operationState['preparedTargets'] = [object[]]@()
        $payload.operationState['preparedUtc'] =
            '2026-07-14T02:04:04.0000000Z'
        $payload.operationState['pendingRebootUtc'] =
            '2026-07-14T02:06:04.0000000Z'
        [void](Add-CommMonitorTestRegistrySemanticBundle -Payload $payload)
        [void](Add-CommMonitorTestServiceSemanticBundle -Payload $payload)
        [void](Add-CommMonitorTestContinuationSemanticBundle -Payload $payload)
        [void](Add-CommMonitorTestKeyMetadataSemanticObject -Payload $payload)

        {
            New-CommMonitorOwnershipEnvelope `
                -Payload $payload `
                -Key $crossSemanticKey `
                -KeyId $crossSemanticKeyId
        } | Should Not Throw
    }

    It 'accepts a fully bound ServerCore baseline' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform `
            -PlatformKind ServerCore
        {
            New-CommMonitorOwnershipEnvelope `
                -Payload $payload `
                -Key $crossSemanticKey `
                -KeyId $crossSemanticKeyId
        } | Should Not Throw
    }

    It 'rejects an immutable marker for another product version through NewPayload' {
        $arguments = New-CommMonitorTestOwnershipPayloadArguments
        $desktopExecutable = @(
            $arguments.OwnedObjects |
                Where-Object objectId -eq 'desktop-exe')[0]
        $desktopExecutable.identity.productMarker = 'CommMonitor:9.9.9'
        Assert-CommMonitorTestThrowsLike `
            -Action { New-CommMonitorOwnershipPayload @arguments } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects an immutable marker for another product version through NewEnvelope' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $desktopExecutable = @(
            $payload.ownedObjects |
                Where-Object objectId -eq 'desktop-exe')[0]
        $desktopExecutable.identity.productMarker = 'CommMonitor:9.9.9'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects a shortcut target that is not an owned immutable file' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $shortcut = @(
            $payload.ownedObjects |
                Where-Object type -eq 'Shortcut')[0]
        $shortcut.identity.target =
            'C:\Program Files\Lemon串口监控\missing.exe'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects a shortcut working directory outside its target root' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $shortcut = @(
            $payload.ownedObjects |
                Where-Object type -eq 'Shortcut')[0]
        $shortcut.identity.workingDirectory = 'C:\Program Files\CommMonitor'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects a registry key deleted before a value under that key' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $bundle = Add-CommMonitorTestRegistrySemanticBundle -Payload $payload
        $bundle.KeyObject.deletePhase = $bundle.ValueObject.deletePhase
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects a service image that is not an owned Service immutable file' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $bundle = Add-CommMonitorTestServiceSemanticBundle -Payload $payload
        $bundle.ServiceObject.identity.imagePath =
            'C:\Program Files\CommMonitor\service\missing.exe'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects an event source not bound to an owned service name' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $bundle = Add-CommMonitorTestServiceSemanticBundle -Payload $payload
        $bundle.EventObject.identity.source = 'AnotherService'
        $bundle.EventObject.identity.registrationPath =
            'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\AnotherService'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects an event message file not bound to its service image' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $bundle = Add-CommMonitorTestServiceSemanticBundle -Payload $payload
        $bundle.EventObject.identity.messageFile =
            'C:\Program Files\CommMonitor\service\missing.exe'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects a continuation task for another install identity' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $bundle = Add-CommMonitorTestContinuationSemanticBundle -Payload $payload
        $bundle.TaskObject.identity.name =
            'LemonSerialMonitor-cccccccc-cccc-cccc-cccc-cccccccccccc'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects a continuation task whose finalizer is not owned' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $bundle = Add-CommMonitorTestContinuationSemanticBundle -Payload $payload
        $bundle.TaskObject.identity.finalizerPath =
            'C:\ProgramData\LemonSerialMonitor\Installer\missing.exe'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects owned key metadata that differs from payload key metadata' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $keyObject = Add-CommMonitorTestKeyMetadataSemanticObject -Payload $payload
        $keyObject.identity.keyId = ('e' * 64)
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects a continuation pending object that does not exist' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $metadata =
            New-CommMonitorTestOwnedSemanticDefinition -Type ContinuationMetadata
        $metadata.identity.pendingObjectIds = [string[]]@('missing-object')
        Add-CommMonitorTestOwnedSemanticDefinition `
            -Payload $payload `
            -Definition $metadata
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects a continuation pending object that is not removable' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform `
            -RootMode PreExistingCore
        $metadata =
            New-CommMonitorTestOwnedSemanticDefinition -Type ContinuationMetadata
        $metadata.identity.pendingObjectIds =
            [string[]]@('core-root-directory')
        Add-CommMonitorTestOwnedSemanticDefinition `
            -Payload $payload `
            -Definition $metadata
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }

    It 'rejects continuation metadata that lists itself as pending' {
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        $metadata =
            New-CommMonitorTestOwnedSemanticDefinition -Type ContinuationMetadata
        $metadata.identity.pendingObjectIds =
            [string[]]@('semantic-continuation-metadata')
        Add-CommMonitorTestOwnedSemanticDefinition `
            -Payload $payload `
            -Definition $metadata
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $crossSemanticKey `
                    -KeyId $crossSemanticKeyId
            } `
            -MessagePattern 'Ownership cross-object semantics'
    }
}

Describe 'CommMonitor owned file and registry semantic identities' {
    BeforeEach {
        $ownedSemanticKey = [byte[]](0..31)
        $ownedSemanticKeyId = Get-CommMonitorSha256Hex -Bytes $ownedSemanticKey
    }

    $ownedSemanticPositiveTypes = @(
        @{ Type = 'ImmutableFile' },
        @{ Type = 'DynamicFile' },
        @{ Type = 'Directory' },
        @{ Type = 'Shortcut' },
        @{ Type = 'RegistryValue' },
        @{ Type = 'RegistryKey' })

    It 'accepts a valid <Type> intrinsic identity through both constructors' `
        -TestCases $ownedSemanticPositiveTypes {
        param($Type)

        $definition = New-CommMonitorTestOwnedSemanticDefinition -Type $Type
        { New-CommMonitorOwnedObject -Definition $definition } | Should Not Throw

        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        if ($Type -eq 'Shortcut') {
            $payload.ownedObjects = [object[]]@(
                $payload.ownedObjects |
                    Where-Object objectId -ne 'start-menu')
        }
        Add-CommMonitorTestOwnedSemanticDefinition `
            -Payload $payload `
            -Definition $definition
        {
            New-CommMonitorOwnershipEnvelope `
                -Payload $payload `
                -Key $ownedSemanticKey `
                -KeyId $ownedSemanticKeyId
        } | Should Not Throw
    }

    $registryKindCases = @(
        @{ Name = 'String'; Kind = 'String'; ValueCase = 'String'; ExpectedType = 'System.String' },
        @{
            Name = 'ExpandString'
            Kind = 'ExpandString'
            ValueCase = 'String'
            ExpectedType = 'System.String'
        },
        @{ Name = 'DWord'; Kind = 'DWord'; ValueCase = 'Int32'; ExpectedType = 'System.Int32' },
        @{
            Name = 'QWord from Int32'
            Kind = 'QWord'
            ValueCase = 'Int32'
            ExpectedType = 'System.Int64'
        },
        @{
            Name = 'QWord from Int64'
            Kind = 'QWord'
            ValueCase = 'Int64'
            ExpectedType = 'System.Int64'
        },
        @{
            Name = 'MultiString'
            Kind = 'MultiString'
            ValueCase = 'StringArray'
            ExpectedType = 'System.String[]'
        },
        @{ Name = 'Binary'; Kind = 'Binary'; ValueCase = 'Hex'; ExpectedType = 'System.String' },
        @{ Name = 'None'; Kind = 'None'; ValueCase = 'Hex'; ExpectedType = 'System.String' })

    It 'accepts and canonicalizes RegistryValue <Name>' `
        -TestCases $registryKindCases {
        param($Name, $Kind, $ValueCase, $ExpectedType)

        $definition = New-CommMonitorTestOwnedSemanticDefinition -Type RegistryValue
        $definition.identity.kind = $Kind
        $definition.identity.value = switch ($ValueCase) {
            'String' { 'value' }
            'Int32' { [int]7 }
            'Int64' { [long]7 }
            'StringArray' { [string[]]@('one', 'two', 'one') }
            'Hex' { '00ff10' }
        }
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        Add-CommMonitorTestOwnedSemanticDefinition `
            -Payload $payload `
            -Definition $definition
        $envelope = New-CommMonitorOwnershipEnvelope `
            -Payload $payload `
            -Key $ownedSemanticKey `
            -KeyId $ownedSemanticKeyId
        $registeredValue = @(
            $envelope.payload.ownedObjects |
                Where-Object objectId -eq 'semantic-registry-value')[0]
        $registeredValue.identity.value.GetType().FullName | Should Be $ExpectedType
    }

    $ownedSemanticNegativeCases = @(
        @{ Name = 'uppercase objectId'; Type = 'ImmutableFile'; Scenario = 'object-id' },
        @{ Name = 'negative deletePhase'; Type = 'ImmutableFile'; Scenario = 'delete-phase' },
        @{
            Name = 'PreExistingShared removal'
            Type = 'ImmutableFile'
            Scenario = 'preexisting-remove'
        },
        @{ Name = 'unsafe relative path'; Type = 'DynamicFile'; Scenario = 'relative-path' },
        @{
            Name = 'ProtectedManagedTree outside DataRoot'
            Type = 'Directory'
            Scenario = 'protected-ai'
        },
        @{ Name = 'negative ImmutableFile size'; Type = 'ImmutableFile'; Scenario = 'size' },
        @{ Name = 'noncanonical ImmutableFile hash'; Type = 'ImmutableFile'; Scenario = 'hash' },
        @{ Name = 'empty product marker'; Type = 'ImmutableFile'; Scenario = 'marker' },
        @{ Name = 'Directory created/proof mismatch'; Type = 'Directory'; Scenario = 'dir-created' },
        @{
            Name = 'pre-existing Directory marked created'
            Type = 'Directory'
            Scenario = 'dir-preexisting'
        },
        @{ Name = 'Shortcut created/proof mismatch'; Type = 'Shortcut'; Scenario = 'shortcut-created' },
        @{ Name = 'relative Shortcut target'; Type = 'Shortcut'; Scenario = 'shortcut-target' },
        @{
            Name = 'relative Shortcut working directory'
            Type = 'Shortcut'
            Scenario = 'shortcut-working'
        },
        @{ Name = 'noncanonical Shortcut hash'; Type = 'Shortcut'; Scenario = 'shortcut-hash' },
        @{ Name = 'RegistryValue HKCU hive'; Type = 'RegistryValue'; Scenario = 'rv-hive' },
        @{ Name = 'RegistryValue 32-bit view'; Type = 'RegistryValue'; Scenario = 'rv-view' },
        @{ Name = 'RegistryValue unknown kind'; Type = 'RegistryValue'; Scenario = 'rv-kind' },
        @{
            Name = 'RegistryValue String with Int32'
            Type = 'RegistryValue'
            Scenario = 'rv-string-int'
        },
        @{
            Name = 'RegistryValue DWord with string'
            Type = 'RegistryValue'
            Scenario = 'rv-dword-string'
        },
        @{
            Name = 'RegistryValue QWord with array'
            Type = 'RegistryValue'
            Scenario = 'rv-qword-array'
        },
        @{
            Name = 'RegistryValue MultiString with scalar'
            Type = 'RegistryValue'
            Scenario = 'rv-multistring-scalar'
        },
        @{
            Name = 'RegistryValue Binary uppercase hex'
            Type = 'RegistryValue'
            Scenario = 'rv-binary-uppercase'
        },
        @{
            Name = 'RegistryValue Binary odd hex'
            Type = 'RegistryValue'
            Scenario = 'rv-binary-odd'
        },
        @{
            Name = 'RegistryValue created/proof mismatch'
            Type = 'RegistryValue'
            Scenario = 'rv-created'
        },
        @{ Name = 'RegistryKey HKCU hive'; Type = 'RegistryKey'; Scenario = 'rk-hive' },
        @{ Name = 'RegistryKey 32-bit view'; Type = 'RegistryKey'; Scenario = 'rk-view' },
        @{
            Name = 'RegistryKey created/proof mismatch'
            Type = 'RegistryKey'
            Scenario = 'rk-created'
        })

    It 'rejects <Name> through the canonical owned-object authority' `
        -TestCases $ownedSemanticNegativeCases {
        param($Name, $Type, $Scenario)

        $definition = New-CommMonitorTestOwnedSemanticDefinition -Type $Type
        switch ($Scenario) {
            'object-id' { $definition.objectId = 'Semantic-Immutable' }
            'delete-phase' { $definition.deletePhase = -1 }
            'preexisting-remove' {
                $definition.ownershipProof = 'PreExistingShared'
                $definition.removeOnUninstall = $true
            }
            'relative-path' { $definition.relativePath = 'state\..\escape.json' }
            'protected-ai' {
                $definition.component = 'AiState'
                $definition.root = 'AiStateRoot'
                $definition.relativePath = 'state'
            }
            'size' { $definition.identity.size = [long]-1 }
            'hash' { $definition.identity.sha256 = ('A' * 64) }
            'marker' { $definition.identity.productMarker = '' }
            'dir-created' { $definition.identity.created = $false }
            'dir-preexisting' {
                $definition.ownershipProof = 'PreExistingShared'
                $definition.removeOnUninstall = $false
                $definition.identity.created = $true
            }
            'shortcut-created' { $definition.identity.created = $false }
            'shortcut-target' { $definition.identity.target = 'CommMonitor.App.exe' }
            'shortcut-working' { $definition.identity.workingDirectory = 'bin' }
            'shortcut-hash' { $definition.identity.fileSha256 = ('F' * 64) }
            'rv-hive' { $definition.identity.hive = 'HKCU' }
            'rv-view' { $definition.identity.view = 'Registry32' }
            'rv-kind' { $definition.identity.kind = 'Unknown' }
            'rv-string-int' { $definition.identity.value = [int]1 }
            'rv-dword-string' {
                $definition.identity.kind = 'DWord'
                $definition.identity.value = '1'
            }
            'rv-qword-array' {
                $definition.identity.kind = 'QWord'
                $definition.identity.value = [string[]]@('1')
            }
            'rv-multistring-scalar' {
                $definition.identity.kind = 'MultiString'
                $definition.identity.value = 'one'
            }
            'rv-binary-uppercase' {
                $definition.identity.kind = 'Binary'
                $definition.identity.value = 'AA'
            }
            'rv-binary-odd' {
                $definition.identity.kind = 'Binary'
                $definition.identity.value = 'abc'
            }
            'rv-created' { $definition.identity.created = $false }
            'rk-hive' { $definition.identity.hive = 'HKCU' }
            'rk-view' { $definition.identity.view = 'Registry32' }
            'rk-created' { $definition.identity.created = $false }
        }
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        Add-CommMonitorTestOwnedSemanticDefinition `
            -Payload $payload `
            -Definition $definition
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $ownedSemanticKey `
                    -KeyId $ownedSemanticKeyId
            } `
            -MessagePattern 'Owned object semantics'
    }

    $ownedSemanticAuthorityCases = @(
        @{ Name = 'NewOwnedObject'; Authority = 'NewOwnedObject' },
        @{ Name = 'NewEnvelope'; Authority = 'NewEnvelope' })

    It 'enforces shared owned semantics through <Name>' `
        -TestCases $ownedSemanticAuthorityCases {
        param($Name, $Authority)

        $definition = New-CommMonitorTestOwnedSemanticDefinition -Type ImmutableFile
        $definition.ownershipProof = 'PreExistingShared'
        $definition.removeOnUninstall = $true
        if ($Authority -eq 'NewOwnedObject') {
            Assert-CommMonitorTestThrowsLike `
                -Action { New-CommMonitorOwnedObject -Definition $definition } `
                -MessagePattern 'Owned object semantics'
        }
        else {
            $payload = New-CommMonitorTestOwnershipPayloadForPlatform
            Add-CommMonitorTestOwnedSemanticDefinition `
                -Payload $payload `
                -Definition $definition
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    New-CommMonitorOwnershipEnvelope `
                        -Payload $payload `
                        -Key $ownedSemanticKey `
                        -KeyId $ownedSemanticKeyId
                } `
                -MessagePattern 'Owned object semantics'
        }
    }
}

Describe 'CommMonitor owned system and metadata semantic identities' {
    BeforeEach {
        $systemSemanticKey = [byte[]](0..31)
        $systemSemanticKeyId = Get-CommMonitorSha256Hex -Bytes $systemSemanticKey
    }

    $systemSemanticPositiveTypes = @(
        @{ Type = 'Service' },
        @{ Type = 'DriverPackage' },
        @{ Type = 'Certificate' },
        @{ Type = 'EventSource' },
        @{ Type = 'ScheduledTask' },
        @{ Type = 'FilterMetadata' },
        @{ Type = 'KeyMetadata' },
        @{ Type = 'ContinuationMetadata' })

    It 'accepts a valid <Type> system identity through both constructors' `
        -TestCases $systemSemanticPositiveTypes {
        param($Type)

        $definition = New-CommMonitorTestOwnedSemanticDefinition -Type $Type
        { New-CommMonitorOwnedObject -Definition $definition } | Should Not Throw
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        if ($Type -in @('ScheduledTask', 'ContinuationMetadata')) {
            $payload.state = 'PendingReboot'
            $payload.continuationState = [ordered]@{ status = 'Active' }
            $payload.operationState =
                New-CommMonitorTestRequestedOperationState
            $payload.operationState['preparedTargets'] = [object[]]@()
            $payload.operationState['preparedUtc'] =
                '2026-07-14T02:04:04.0000000Z'
            $payload.operationState['pendingRebootUtc'] =
                '2026-07-14T02:06:04.0000000Z'
        }
        switch ($Type) {
            { $_ -in @('Service', 'EventSource') } {
                [void](Add-CommMonitorTestServiceSemanticBundle `
                        -Payload $payload)
                break
            }
            'ScheduledTask' {
                [void](Add-CommMonitorTestContinuationSemanticBundle `
                        -Payload $payload)
                break
            }
            'KeyMetadata' {
                [void](Add-CommMonitorTestKeyMetadataSemanticObject `
                        -Payload $payload)
                break
            }
            default {
                Add-CommMonitorTestOwnedSemanticDefinition `
                    -Payload $payload `
                    -Definition $definition
            }
        }
        {
            New-CommMonitorOwnershipEnvelope `
                -Payload $payload `
                -Key $systemSemanticKey `
                -KeyId $systemSemanticKeyId
        } | Should Not Throw
    }

    It 'accepts the exact LocalMachine certificate store <Store>' `
        -TestCases @(
            @{ Store = 'LocalMachine\TrustedPublisher' },
            @{ Store = 'LocalMachine\Root' }) {
        param($Store)

        $definition = New-CommMonitorTestOwnedSemanticDefinition -Type Certificate
        $definition.identity.store = $Store
        { New-CommMonitorOwnedObject -Definition $definition } | Should Not Throw
    }

    $systemSemanticNegativeCases = @(
        @{ Name = 'Service type'; Type = 'Service'; Scenario = 'service-type' },
        @{ Name = 'Service account'; Type = 'Service'; Scenario = 'service-account' },
        @{ Name = 'Service proof mismatch'; Type = 'Service'; Scenario = 'service-proof' },
        @{ Name = 'Service relative image'; Type = 'Service'; Scenario = 'service-image' },
        @{ Name = 'Service empty name'; Type = 'Service'; Scenario = 'service-name' },
        @{
            Name = 'DriverPackage published name'
            Type = 'DriverPackage'
            Scenario = 'driver-published'
        },
        @{
            Name = 'DriverPackage relative original path'
            Type = 'DriverPackage'
            Scenario = 'driver-path'
        },
        @{
            Name = 'DriverPackage noncanonical hash'
            Type = 'DriverPackage'
            Scenario = 'driver-hash'
        },
        @{
            Name = 'DriverPackage proof mismatch'
            Type = 'DriverPackage'
            Scenario = 'driver-proof'
        },
        @{ Name = 'Certificate CurrentUser store'; Type = 'Certificate'; Scenario = 'cert-store' },
        @{ Name = 'Certificate parent store'; Type = 'Certificate'; Scenario = 'cert-parent' },
        @{ Name = 'Certificate thumbprint'; Type = 'Certificate'; Scenario = 'cert-thumb' },
        @{ Name = 'Certificate DER hash'; Type = 'Certificate'; Scenario = 'cert-der' },
        @{ Name = 'Certificate added flag'; Type = 'Certificate'; Scenario = 'cert-added' },
        @{
            Name = 'adopted Certificate marked added'
            Type = 'Certificate'
            Scenario = 'cert-adopted-added'
        },
        @{ Name = 'EventSource log'; Type = 'EventSource'; Scenario = 'event-log' },
        @{ Name = 'EventSource empty source'; Type = 'EventSource'; Scenario = 'event-source' },
        @{
            Name = 'EventSource registration binding'
            Type = 'EventSource'
            Scenario = 'event-registration'
        },
        @{
            Name = 'EventSource relative message file'
            Type = 'EventSource'
            Scenario = 'event-message'
        },
        @{ Name = 'EventSource proof mismatch'; Type = 'EventSource'; Scenario = 'event-proof' },
        @{ Name = 'ScheduledTask name'; Type = 'ScheduledTask'; Scenario = 'task-name' },
        @{ Name = 'ScheduledTask identity'; Type = 'ScheduledTask'; Scenario = 'task-sid' },
        @{ Name = 'ScheduledTask trigger'; Type = 'ScheduledTask'; Scenario = 'task-trigger' },
        @{
            Name = 'ScheduledTask relative finalizer'
            Type = 'ScheduledTask'
            Scenario = 'task-path'
        },
        @{ Name = 'ScheduledTask empty arguments'; Type = 'ScheduledTask'; Scenario = 'task-args' },
        @{ Name = 'ScheduledTask XML hash'; Type = 'ScheduledTask'; Scenario = 'task-hash' },
        @{ Name = 'Filter class GUID'; Type = 'FilterMetadata'; Scenario = 'filter-class' },
        @{ Name = 'Filter value name'; Type = 'FilterMetadata'; Scenario = 'filter-value' },
        @{ Name = 'Filter empty entry'; Type = 'FilterMetadata'; Scenario = 'filter-entry' },
        @{ Name = 'Filter added flag'; Type = 'FilterMetadata'; Scenario = 'filter-added' },
        @{
            Name = 'adopted Filter marked added'
            Type = 'FilterMetadata'
            Scenario = 'filter-adopted-added'
        },
        @{ Name = 'KeyMetadata kind'; Type = 'KeyMetadata'; Scenario = 'key-kind' },
        @{ Name = 'KeyMetadata state'; Type = 'KeyMetadata'; Scenario = 'key-state' },
        @{ Name = 'KeyMetadata path'; Type = 'KeyMetadata'; Scenario = 'key-path' },
        @{ Name = 'KeyMetadata hash'; Type = 'KeyMetadata'; Scenario = 'key-hash' },
        @{ Name = 'KeyMetadata proof'; Type = 'KeyMetadata'; Scenario = 'key-proof' },
        @{
            Name = 'ContinuationMetadata path'
            Type = 'ContinuationMetadata'
            Scenario = 'continuation-path'
        },
        @{
            Name = 'ContinuationMetadata pending ID'
            Type = 'ContinuationMetadata'
            Scenario = 'continuation-pending'
        },
        @{
            Name = 'ContinuationMetadata helper hash'
            Type = 'ContinuationMetadata'
            Scenario = 'continuation-helper'
        },
        @{
            Name = 'ContinuationMetadata finalizer hash'
            Type = 'ContinuationMetadata'
            Scenario = 'continuation-finalizer'
        },
        @{
            Name = 'ContinuationMetadata proof'
            Type = 'ContinuationMetadata'
            Scenario = 'continuation-proof'
        })

    It 'rejects invalid <Name> through the canonical system authority' `
        -TestCases $systemSemanticNegativeCases {
        param($Name, $Type, $Scenario)

        $definition = New-CommMonitorTestOwnedSemanticDefinition -Type $Type
        switch ($Scenario) {
            'service-type' { $definition.identity.serviceType = 'KernelDriver' }
            'service-account' { $definition.identity.accountSid = 'S-1-5-19' }
            'service-proof' { $definition.identity.creationProof = 'PreExistingShared' }
            'service-image' { $definition.identity.imagePath = 'service.exe' }
            'service-name' { $definition.identity.name = '' }
            'driver-published' { $definition.identity.publishedName = 'OEM42.inf' }
            'driver-path' { $definition.identity.originalInfPath = 'driver.inf' }
            'driver-hash' { $definition.identity.originalInfSha256 = ('A' * 64) }
            'driver-proof' { $definition.identity.creationProof = 'VerifiedLegacyAdoption' }
            'cert-store' { $definition.identity.store = 'CurrentUser\Root' }
            'cert-parent' { $definition.identity.store = 'LocalMachine' }
            'cert-thumb' { $definition.identity.thumbprint = ('D' * 40) }
            'cert-der' { $definition.identity.derSha256 = ('E' * 64) }
            'cert-added' { $definition.identity.added = $false }
            'cert-adopted-added' {
                $definition.ownershipProof = 'VerifiedLegacyAdoption'
                $definition.identity.added = $true
            }
            'event-log' { $definition.identity.log = 'System' }
            'event-source' { $definition.identity.source = '' }
            'event-registration' {
                $definition.identity.registrationPath =
                    'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\Other'
            }
            'event-message' { $definition.identity.messageFile = 'service.exe' }
            'event-proof' { $definition.identity.creationProof = 'PreExistingShared' }
            'task-name' { $definition.identity.name = 'LemonSerialMonitor' }
            'task-sid' { $definition.identity.identitySid = 'S-1-5-19' }
            'task-trigger' { $definition.identity.trigger = 'AtLogon' }
            'task-path' { $definition.identity.finalizerPath = 'finalizer.exe' }
            'task-args' { $definition.identity.arguments = '' }
            'task-hash' { $definition.identity.xmlSha256 = ('F' * 64) }
            'filter-class' {
                $definition.identity.classKey =
                    $definition.identity.classKey.ToLowerInvariant()
            }
            'filter-value' { $definition.identity.valueName = 'upperfilters' }
            'filter-entry' { $definition.identity.entry = '' }
            'filter-added' { $definition.identity.added = $false }
            'filter-adopted-added' {
                $definition.ownershipProof = 'VerifiedLegacyAdoption'
                $definition.identity.added = $true
            }
            'key-kind' { $definition.identity.kind = 'CompletionKey' }
            'key-state' { $definition.identity.state = 'Retired' }
            'key-path' { $definition.identity.relativePath = 'state\other.key' }
            'key-hash' { $definition.identity.keyId = ('B' * 64) }
            'key-proof' { $definition.ownershipProof = 'VerifiedLegacyAdoption' }
            'continuation-path' {
                $definition.identity.relativePath = 'state\other.json'
            }
            'continuation-pending' {
                $definition.identity.pendingObjectIds = [string[]]@('Desktop-Exe')
            }
            'continuation-helper' {
                $definition.identity.helperSha256 = ('C' * 64)
            }
            'continuation-finalizer' {
                $definition.identity.finalizerSha256 = ('D' * 64)
            }
            'continuation-proof' {
                $definition.ownershipProof = 'VerifiedLegacyAdoption'
            }
        }
        $payload = New-CommMonitorTestOwnershipPayloadForPlatform
        Add-CommMonitorTestOwnedSemanticDefinition `
            -Payload $payload `
            -Definition $definition
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorOwnershipEnvelope `
                    -Payload $payload `
                    -Key $systemSemanticKey `
                    -KeyId $systemSemanticKeyId
            } `
            -MessagePattern 'Owned object semantics'
    }

    It 'shares system semantics through <Authority>' `
        -TestCases @(
            @{ Authority = 'NewOwnedObject' },
            @{ Authority = 'NewEnvelope' }) {
        param($Authority)

        $definition = New-CommMonitorTestOwnedSemanticDefinition -Type Service
        $definition.identity.creationProof = 'PreExistingShared'
        if ($Authority -eq 'NewOwnedObject') {
            Assert-CommMonitorTestThrowsLike `
                -Action { New-CommMonitorOwnedObject -Definition $definition } `
                -MessagePattern 'Owned object semantics'
        }
        else {
            $payload = New-CommMonitorTestOwnershipPayloadForPlatform
            Add-CommMonitorTestOwnedSemanticDefinition `
                -Payload $payload `
                -Definition $definition
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    New-CommMonitorOwnershipEnvelope `
                        -Payload $payload `
                        -Key $systemSemanticKey `
                        -KeyId $systemSemanticKeyId
                } `
                -MessagePattern 'Owned object semantics'
        }
    }
}

Describe 'CommMonitor ownership root semantic truth table' {
    BeforeEach {
        $rootTestKey = [byte[]](0..31)
        $rootKeyId = Get-CommMonitorSha256Hex -Bytes $rootTestKey
        $rootManifestPath =
            'C:\ProgramData\LemonSerialMonitor\Installer\state\ownership-manifest.v3.json'
    }

    $positiveRootSemanticCases = @(
        @{ Name = 'Desktop five active roots'; PlatformKind = 'Desktop'; RootMode = 'Created' },
        @{
            Name = 'ServerDesktop five active roots'
            PlatformKind = 'ServerDesktop'
            RootMode = 'Created'
        },
        @{
            Name = 'ServerCore exact inactive AppRoot'
            PlatformKind = 'ServerCore'
            RootMode = 'Created'
        },
        @{
            Name = 'PreExistingShared active CoreRoot'
            PlatformKind = 'Desktop'
            RootMode = 'PreExistingCore'
        },
        @{
            Name = 'VerifiedLegacyAdoption DataRoot'
            PlatformKind = 'Desktop'
            RootMode = 'VerifiedData'
        })

    It 'accepts the <Name> truth-table row' -TestCases $positiveRootSemanticCases {
        param($Name, $PlatformKind, $RootMode)

        $candidate = New-CommMonitorTestOwnershipPayloadForPlatform `
            -PlatformKind $PlatformKind `
            -RootMode $RootMode
        $envelope = New-CommMonitorOwnershipEnvelope `
            -Payload $candidate `
            -Key $rootTestKey `
            -KeyId $rootKeyId

        if ($PlatformKind -eq 'ServerCore') {
            @($envelope.payload.roots.Values | Where-Object active).Count |
                Should Be 4
            $appRoot = $envelope.payload.roots.appRoot
            $appRoot.active | Should Be $false
            $appRoot.present | Should Be $false
            $appRoot.createdByInstall | Should Be $false
            foreach ($field in @(
                    'volumeSerialNumber', 'fileId', 'aclProfile',
                    'physicalCandidatePath', 'ownershipProof', 'adoptionSource')) {
                $appRoot[$field] | Should BeNullOrEmpty
            }
            $appRoot.contentPolicy | Should Be 'EmptyAfterOwnedChildren'
        }
        else {
            @($envelope.payload.roots.Values | Where-Object active).Count |
                Should Be 5
        }

        if ($RootMode -eq 'PreExistingCore') {
            $envelope.payload.roots.coreRoot.createdByInstall | Should Be $false
            $envelope.payload.roots.coreRoot.ownershipProof |
                Should Be 'PreExistingShared'
        }
        elseif ($RootMode -eq 'VerifiedData') {
            $envelope.payload.roots.dataRoot.createdByInstall | Should Be $false
            $envelope.payload.roots.dataRoot.ownershipProof |
                Should Be 'VerifiedLegacyAdoption'
            $envelope.payload.roots.dataRoot.adoptionSource |
                Should Not BeNullOrEmpty
        }
    }

    $negativeRootSemanticCases = @(
        @{ Name = 'Desktop inactive AppRoot'; Scenario = 'desktop-inactive' },
        @{ Name = 'ServerCore active AppRoot'; Scenario = 'server-core-active' },
        @{ Name = 'inactive AppRoot present'; Scenario = 'inactive-present' },
        @{ Name = 'inactive AppRoot created'; Scenario = 'inactive-created' },
        @{
            Name = 'inactive AppRoot nullable evidence'
            Scenario = 'inactive-nullable-bundle'
        },
        @{ Name = 'inactive AppRoot protected policy'; Scenario = 'inactive-policy' },
        @{ Name = 'active root absent'; Scenario = 'active-not-present' },
        @{ Name = 'active root noncanonical volume'; Scenario = 'active-volume' },
        @{ Name = 'active root noncanonical file ID'; Scenario = 'active-file' },
        @{
            Name = 'active root missing required evidence'
            Scenario = 'active-evidence-bundle'
        },
        @{ Name = 'CreatedThisInstall false created flag'; Scenario = 'created-flag' },
        @{
            Name = 'PreExistingShared true created flag'
            Scenario = 'preexisting-created'
        },
        @{
            Name = 'PreExistingShared adoption source'
            Scenario = 'preexisting-adoption'
        },
        @{
            Name = 'VerifiedLegacyAdoption on CoreRoot'
            Scenario = 'verified-nondata'
        },
        @{
            Name = 'VerifiedLegacyAdoption true created flag'
            Scenario = 'verified-created'
        },
        @{
            Name = 'VerifiedLegacyAdoption missing source'
            Scenario = 'verified-missing'
        },
        @{
            Name = 'VerifiedLegacyAdoption path mismatch'
            Scenario = 'verified-path'
        },
        @{
            Name = 'VerifiedLegacyAdoption volume mismatch'
            Scenario = 'verified-volume'
        },
        @{
            Name = 'VerifiedLegacyAdoption file ID mismatch'
            Scenario = 'verified-file'
        },
        @{
            Name = 'VerifiedLegacyAdoption ACL mismatch'
            Scenario = 'verified-acl'
        },
        @{
            Name = 'VerifiedLegacyAdoption proof mismatch'
            Scenario = 'verified-proof'
        },
        @{ Name = 'ProtectedManagedTree on CoreRoot'; Scenario = 'nondata-protected' },
        @{
            Name = 'protected product-root ACL violations'
            Scenario = 'root-acl-bundle'
        },
        @{ Name = 'AI ACL missing authorized SID'; Scenario = 'ai-acl' },
        @{ Name = 'unsafe canonical or physical path'; Scenario = 'unsafe-path-bundle' })

    It 'rejects <Name> at the canonical root semantic gate' `
        -TestCases $negativeRootSemanticCases {
        param($Name, $Scenario)

        $assertRejected = {
            param($Candidate)
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    New-CommMonitorOwnershipEnvelope `
                        -Payload $Candidate `
                        -Key $rootTestKey `
                        -KeyId $rootKeyId
                } `
                -MessagePattern 'Ownership root semantics'
        }

        if ($Scenario -eq 'inactive-nullable-bundle') {
            foreach ($field in @(
                    'volumeSerialNumber', 'fileId', 'aclProfile',
                    'physicalCandidatePath', 'ownershipProof', 'adoptionSource')) {
                $variant = New-CommMonitorTestOwnershipPayloadForPlatform `
                    -PlatformKind ServerCore
                switch ($field) {
                    'volumeSerialNumber' {
                        $variant.roots.appRoot[$field] = '0011223344556677'
                    }
                    'fileId' { $variant.roots.appRoot[$field] = ('b' * 32) }
                    'aclProfile' {
                        $variant.roots.appRoot[$field] =
                            New-CommMonitorTestManifestAclProfile
                    }
                    'physicalCandidatePath' {
                        $variant.roots.appRoot[$field] =
                            $variant.roots.appRoot.canonicalPath
                    }
                    'ownershipProof' {
                        $variant.roots.appRoot[$field] = 'CreatedThisInstall'
                    }
                    'adoptionSource' {
                        $variant.roots.appRoot[$field] =
                            New-CommMonitorTestLegacyAdoptionSource
                    }
                }
                & $assertRejected $variant
            }
            return
        }

        if ($Scenario -eq 'active-evidence-bundle') {
            foreach ($field in @('aclProfile', 'physicalCandidatePath', 'ownershipProof')) {
                $variant = New-CommMonitorTestOwnershipPayloadForPlatform
                $variant.roots.coreRoot[$field] = $null
                & $assertRejected $variant
            }
            return
        }

        if ($Scenario -eq 'root-acl-bundle') {
            $unprotected = New-CommMonitorTestOwnershipPayloadForPlatform
            $unprotected.roots.appRoot.aclProfile.areAccessRulesProtected = $false
            & $assertRejected $unprotected

            $writable = New-CommMonitorTestOwnershipPayloadForPlatform
            $writable.roots.coreRoot.aclProfile.usersWritable = $true
            & $assertRejected $writable
            return
        }

        if ($Scenario -eq 'unsafe-path-bundle') {
            $unsafeCanonical = New-CommMonitorTestOwnershipPayloadForPlatform
            $unsafeCanonical.roots.coreRoot.canonicalPath =
                'C:\Program Files\..\CommMonitor'
            & $assertRejected $unsafeCanonical

            $unsafePhysical = New-CommMonitorTestOwnershipPayloadForPlatform
            $unsafePhysical.roots.coreRoot.physicalCandidatePath =
                'C:\Program Files\CommMonitor\..\Else'
            & $assertRejected $unsafePhysical
            return
        }

        $candidate = if ($Scenario -like 'inactive-*' -or
            $Scenario -eq 'server-core-active') {
            New-CommMonitorTestOwnershipPayloadForPlatform -PlatformKind ServerCore
        }
        elseif ($Scenario -like 'preexisting-*') {
            New-CommMonitorTestOwnershipPayloadForPlatform -RootMode PreExistingCore
        }
        elseif ($Scenario -like 'verified-*' -and
            $Scenario -ne 'verified-nondata') {
            New-CommMonitorTestOwnershipPayloadForPlatform -RootMode VerifiedData
        }
        else {
            New-CommMonitorTestOwnershipPayloadForPlatform
        }

        switch ($Scenario) {
            'desktop-inactive' { $candidate.roots.appRoot.active = $false }
            'server-core-active' { $candidate.roots.appRoot.active = $true }
            'inactive-present' { $candidate.roots.appRoot.present = $true }
            'inactive-created' { $candidate.roots.appRoot.createdByInstall = $true }
            'inactive-policy' {
                $candidate.roots.appRoot.contentPolicy = 'ProtectedManagedTree'
            }
            'active-not-present' { $candidate.roots.coreRoot.present = $false }
            'active-volume' {
                $candidate.roots.coreRoot.volumeSerialNumber = '001122334455667A'
            }
            'active-file' { $candidate.roots.coreRoot.fileId = ('B' * 32) }
            'created-flag' {
                $candidate.roots.coreRoot.createdByInstall = $false
            }
            'preexisting-created' {
                $candidate.roots.coreRoot.createdByInstall = $true
            }
            'preexisting-adoption' {
                $candidate.roots.coreRoot.adoptionSource =
                    New-CommMonitorTestLegacyAdoptionSource
            }
            'verified-nondata' {
                $root = $candidate.roots.coreRoot
                $root.createdByInstall = $false
                $root.ownershipProof = 'VerifiedLegacyAdoption'
                $source = New-CommMonitorTestLegacyAdoptionSource
                $source.canonicalPath = $root.canonicalPath
                $source.volumeSerialNumber = $root.volumeSerialNumber
                $source.fileId = $root.fileId
                $source.aclProfile = $root.aclProfile
                $root.adoptionSource = $source
            }
            'verified-created' {
                $candidate.roots.dataRoot.createdByInstall = $true
            }
            'verified-missing' { $candidate.roots.dataRoot.adoptionSource = $null }
            'verified-path' {
                $candidate.roots.dataRoot.adoptionSource.canonicalPath =
                    'C:\ProgramData\Elsewhere'
            }
            'verified-volume' {
                $candidate.roots.dataRoot.adoptionSource.volumeSerialNumber =
                    '8899aabbccddeeff'
            }
            'verified-file' {
                $candidate.roots.dataRoot.adoptionSource.fileId = ('c' * 32)
            }
            'verified-acl' {
                $candidate.roots.dataRoot.adoptionSource.aclProfile.ownerSid =
                    'S-1-5-32-544'
            }
            'verified-proof' {
                $candidate.roots.dataRoot.createdByInstall = $true
                $candidate.roots.dataRoot.ownershipProof = 'CreatedThisInstall'
            }
            'nondata-protected' {
                $candidate.roots.coreRoot.contentPolicy = 'ProtectedManagedTree'
            }
            'ai-acl' {
                $candidate.roots.aiStateRoot.aclProfile.allowedFullControlSids =
                    @('S-1-5-18', 'S-1-5-32-544')
            }
        }
        & $assertRejected $candidate
    }

    $rootSemanticAuthorityCases = @(
        @{ Name = 'NewPayload'; Authority = 'NewPayload' },
        @{ Name = 'NewEnvelope'; Authority = 'NewEnvelope' },
        @{ Name = 'AssertEnvelope'; Authority = 'AssertEnvelope' },
        @{ Name = 'AssertState'; Authority = 'AssertState' },
        @{ Name = 'CAS'; Authority = 'CAS' },
        @{ Name = 'DataRoot consumer'; Authority = 'DataRootConsumer' })

    It 'does not bypass root semantics through <Name>' `
        -TestCases $rootSemanticAuthorityCases {
        param($Name, $Authority)

        switch ($Authority) {
            'NewPayload' {
                $arguments = New-CommMonitorTestOwnershipPayloadArguments
                $arguments.Roots.DataRoot.ContentPolicy = 'EmptyAfterOwnedChildren'
                Assert-CommMonitorTestThrowsLike `
                    -Action { New-CommMonitorOwnershipPayload @arguments } `
                    -MessagePattern 'Ownership root semantics'
            }
            'NewEnvelope' {
                $candidate = New-CommMonitorTestOwnershipPayloadForPlatform
                $candidate.roots.installerRoot.aclProfile.usersWritable = $true
                Assert-CommMonitorTestThrowsLike `
                    -Action {
                        New-CommMonitorOwnershipEnvelope `
                            -Payload $candidate `
                            -Key $rootTestKey `
                            -KeyId $rootKeyId
                    } `
                    -MessagePattern 'Ownership root semantics'
            }
            'AssertEnvelope' {
                $candidate = New-CommMonitorTestOwnershipPayloadForPlatform
                $candidate.roots.aiStateRoot.canonicalPath =
                    'C:\Users\测试 用户\AppData\Local\LemonSerialMonitor\AI-Other'
                $unchecked = New-CommMonitorTestSignedEnvelopeUnchecked `
                    -Payload $candidate `
                    -Key $rootTestKey
                Assert-CommMonitorTestThrowsLike `
                    -Action {
                        Assert-CommMonitorOwnershipEnvelope `
                            -Envelope $unchecked `
                            -Key $rootTestKey
                    } `
                    -MessagePattern 'Ownership root semantics'
            }
            'AssertState' {
                $candidate = New-CommMonitorTestOwnershipPayloadForPlatform
                $candidate.roots.coreRoot.canonicalPath =
                    $candidate.roots.appRoot.canonicalPath + '\Nested'
                $unchecked = New-CommMonitorTestSignedEnvelopeUnchecked `
                    -Payload $candidate `
                    -Key $rootTestKey
                $anchor = New-CommMonitorOwnershipAnchor `
                    -Payload $candidate `
                    -PayloadSha256 $unchecked.integrity.payloadSha256 `
                    -ManifestPath $rootManifestPath `
                    -Key $rootTestKey `
                    -KeyId $rootKeyId
                Assert-CommMonitorTestThrowsLike `
                    -Action {
                        Assert-CommMonitorOwnershipState `
                            -Envelope $unchecked `
                            -Anchor $anchor `
                            -Key $rootTestKey `
                            -ExpectedManifestPath $rootManifestPath `
                            -ExpectedAppId $candidate.appId `
                            -ExpectedInstallId $candidate.installId
                    } `
                    -MessagePattern 'Ownership root semantics'
            }
            'CAS' {
                $current = New-CommMonitorTestOwnershipPayloadForPlatform
                $envelope = New-CommMonitorOwnershipEnvelope `
                    -Payload $current `
                    -Key $rootTestKey `
                    -KeyId $rootKeyId
                $anchor = New-CommMonitorOwnershipAnchor `
                    -Payload $current `
                    -PayloadSha256 $envelope.integrity.payloadSha256 `
                    -ManifestPath $rootManifestPath `
                    -Key $rootTestKey `
                    -KeyId $rootKeyId
                $next = Copy-CommMonitorTestOrdinalDictionary -InputObject $current
                $next.roots.coreRoot.physicalCandidatePath =
                    $next.roots.appRoot.physicalCandidatePath + '\Nested'
                Assert-CommMonitorTestThrowsLike `
                    -Action {
                        Update-CommMonitorOwnershipStateCas `
                            -CurrentEnvelope $envelope `
                            -CurrentAnchor $anchor `
                            -ExpectedRevision 1 `
                            -ExpectedPayloadSha256 $envelope.integrity.payloadSha256 `
                            -NextPayload $next `
                            -ManifestPath $rootManifestPath `
                            -Key $rootTestKey `
                            -KeyId $rootKeyId
                    } `
                    -MessagePattern 'Ownership root semantics'
            }
            'DataRootConsumer' {
                $candidate = New-CommMonitorTestOwnershipPayloadForPlatform
                $candidate.roots.dataRoot.present = $false
                $module = Get-Module CommMonitor.InstallHelpers
                $registered = & $module {
                    param($Payload)
                    Register-CommMonitorAuthenticatedOwnershipPayload `
                        -Payload $Payload `
                        -PayloadSha256 ('a' * 64)
                } $candidate
                Assert-CommMonitorTestThrowsLike `
                    -Action {
                        New-CommMonitorDataRootAdoptionEvidence `
                            -SourceKind AuthenticatedManifestV3 `
                            -AuthenticatedPayload $registered
                    } `
                    -MessagePattern 'Ownership root semantics'
            }
        }
    }
}

Describe 'CommMonitor authenticated uninstall transition authority' {
    $legalTransitionCases = @(
        @{
            Name = 'Committed to Requested'; From = 'Committed'
            To = 'UninstallRequested'; Actor = 'Task5'
        },
        @{
            Name = 'Requested to Prepared'; From = 'UninstallRequested'
            To = 'UninstallPrepared'; Actor = 'Helper'
        },
        @{
            Name = 'Requested to Abandoned'; From = 'UninstallRequested'
            To = 'Abandoned'; Actor = 'Task5'; AbandonedWithoutPreparation = $true
        },
        @{
            Name = 'Prepared to Abandoned'; From = 'UninstallPrepared'
            To = 'Abandoned'; Actor = 'Task5'
        },
        @{
            Name = 'Prepared to PendingReboot'; From = 'UninstallPrepared'
            To = 'PendingReboot'; Actor = 'Helper'
        },
        @{
            Name = 'Abandoned to fresh Requested'; From = 'Abandoned'
            To = 'UninstallRequested'; Actor = 'Task5'; Fresh = $true
        },
        @{
            Name = 'PendingReboot to fresh Requested'; From = 'PendingReboot'
            To = 'UninstallRequested'; Actor = 'Task5'; Fresh = $true
        }
    )

    It 'accepts the sole actor for <Name>' -TestCases $legalTransitionCases {
        param(
            $Name, $From, $To, $Actor, $Fresh,
            $AbandonedWithoutPreparation
        )

        $currentArguments = @{ State = $From }
        if ($From -eq 'Abandoned' -and $AbandonedWithoutPreparation) {
            $currentArguments.AbandonedWithoutPreparation = $true
        }
        $current = New-CommMonitorTestOperationPayloadForState @currentArguments
        $nextArguments = @{ State = $To }
        if ($To -eq 'Abandoned' -and $AbandonedWithoutPreparation) {
            $nextArguments.AbandonedWithoutPreparation = $true
        }
        if ($Fresh) {
            $nextArguments.OperationId =
                '33333333-3333-3333-3333-333333333333'
            $nextArguments.Nonce = ('7' * 64)
            $nextArguments.RequestedUtc =
                '2026-07-14T02:08:04.0000000Z'
        }
        if ($From -eq 'PendingReboot' -and $To -eq 'UninstallRequested') {
            $nextArguments.ActiveContinuation = $true
        }
        $next = New-CommMonitorTestOperationPayloadForState @nextArguments

        {
            Invoke-CommMonitorTestManifestTransition `
                -CurrentPayload $current `
                -NextPayload $next `
                -Actor $Actor
        } | Should Not Throw
    }

    $wrongActorCases = @(
        @{
            Name = 'Helper cannot request uninstall'; From = 'Committed'
            To = 'UninstallRequested'; Actor = 'Helper'
        },
        @{
            Name = 'Task5 cannot prepare handles'; From = 'UninstallRequested'
            To = 'UninstallPrepared'; Actor = 'Task5'
        },
        @{
            Name = 'Helper cannot abandon Requested'; From = 'UninstallRequested'
            To = 'Abandoned'; Actor = 'Helper'; AbandonedWithoutPreparation = $true
        },
        @{
            Name = 'Helper cannot abandon Prepared'; From = 'UninstallPrepared'
            To = 'Abandoned'; Actor = 'Helper'
        },
        @{
            Name = 'Task5 cannot assert PendingReboot'; From = 'UninstallPrepared'
            To = 'PendingReboot'; Actor = 'Task5'
        },
        @{
            Name = 'Helper cannot retry Abandoned'; From = 'Abandoned'
            To = 'UninstallRequested'; Actor = 'Helper'; Fresh = $true
        },
        @{
            Name = 'Helper cannot retry PendingReboot'; From = 'PendingReboot'
            To = 'UninstallRequested'; Actor = 'Helper'; Fresh = $true
        },
        @{
            Name = 'Helper cannot start terminal cleanup'; From = 'UninstallPrepared'
            To = 'FinalizingAbsent'; Actor = 'Helper'
        }
    )

    It 'rejects the wrong sole actor for <Name>' -TestCases $wrongActorCases {
        param(
            $Name, $From, $To, $Actor, $Fresh,
            $AbandonedWithoutPreparation
        )

        $current = New-CommMonitorTestOperationPayloadForState -State $From
        $nextArguments = @{ State = $To }
        if ($To -eq 'Abandoned' -and $AbandonedWithoutPreparation) {
            $nextArguments.AbandonedWithoutPreparation = $true
        }
        if ($Fresh) {
            $nextArguments.OperationId =
                '33333333-3333-3333-3333-333333333333'
            $nextArguments.Nonce = ('7' * 64)
            $nextArguments.RequestedUtc =
                '2026-07-14T02:08:04.0000000Z'
        }
        if ($From -eq 'PendingReboot' -and $To -eq 'UninstallRequested') {
            $nextArguments.ActiveContinuation = $true
        }
        $next = New-CommMonitorTestOperationPayloadForState @nextArguments
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestManifestTransition `
                    -CurrentPayload $current `
                    -NextPayload $next `
                    -Actor $Actor
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    $illegalTransitionCases = @(
        @{ Name = 'Committed skips to Prepared'; From = 'Committed'; To = 'UninstallPrepared'; Actor = 'Task5' },
        @{ Name = 'Committed skips to Abandoned'; From = 'Committed'; To = 'Abandoned'; Actor = 'Task5' },
        @{ Name = 'Requested skips to PendingReboot'; From = 'UninstallRequested'; To = 'PendingReboot'; Actor = 'Helper' },
        @{ Name = 'Requested skips to FinalizingAbsent'; From = 'UninstallRequested'; To = 'FinalizingAbsent'; Actor = 'Task5' },
        @{ Name = 'Prepared rolls back to Requested'; From = 'UninstallPrepared'; To = 'UninstallRequested'; Actor = 'Task5' },
        @{ Name = 'PendingReboot rolls back to Prepared'; From = 'PendingReboot'; To = 'UninstallPrepared'; Actor = 'Helper' },
        @{ Name = 'PendingReboot skips to Abandoned'; From = 'PendingReboot'; To = 'Abandoned'; Actor = 'Task5' },
        @{ Name = 'Abandoned skips to Prepared'; From = 'Abandoned'; To = 'UninstallPrepared'; Actor = 'Helper' },
        @{ Name = 'Abandoned skips to PendingReboot'; From = 'Abandoned'; To = 'PendingReboot'; Actor = 'Helper' },
        @{ Name = 'FinalizingAbsent cannot return to Requested'; From = 'FinalizingAbsent'; To = 'UninstallRequested'; Actor = 'Task5' },
        @{ Name = 'Requested cannot write a same-state revision'; From = 'UninstallRequested'; To = 'UninstallRequested'; Actor = 'Task5' },
        @{ Name = 'Committed cannot write a same-state revision'; From = 'Committed'; To = 'Committed'; Actor = 'Task5' }
    )

    It 'rejects illegal edge <Name>' -TestCases $illegalTransitionCases {
        param($Name, $From, $To, $Actor)

        $current = New-CommMonitorTestOperationPayloadForState -State $From
        $next = New-CommMonitorTestOperationPayloadForState -State $To
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestManifestTransition `
                    -CurrentPayload $current `
                    -NextPayload $next `
                    -Actor $Actor
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    It 'requires an explicit actor at the public CAS boundary' {
        $current = New-CommMonitorTestOperationPayloadForState -State Committed
        $next = New-CommMonitorTestOperationPayloadForState `
            -State UninstallRequested
        $context = New-CommMonitorTestManifestTransitionContext `
            -CurrentPayload $current
        {
            Update-CommMonitorOwnershipManifestCas `
                -CurrentManifest $context.Manifest `
                -CurrentAnchor $context.Anchor `
                -ExpectedRevision $current.revision `
                -ExpectedPayloadSha256 (
                    $context.Envelope.integrity.payloadSha256) `
                -NextPayload $next `
                -ManifestPath $context.ManifestPath `
                -Key $context.Key `
                -KeyId $context.KeyId
        } | Should Throw
    }

    It 'rejects a case-confused actor label' {
        $current = New-CommMonitorTestOperationPayloadForState -State Committed
        $next = New-CommMonitorTestOperationPayloadForState `
            -State UninstallRequested
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestManifestTransition `
                    -CurrentPayload $current `
                    -NextPayload $next `
                    -Actor task5
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    It 'rejects a non-actor label' {
        $current = New-CommMonitorTestOperationPayloadForState -State Committed
        $next = New-CommMonitorTestOperationPayloadForState `
            -State UninstallRequested
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestManifestTransition `
                    -CurrentPayload $current `
                    -NextPayload $next `
                    -Actor Installer
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    $immutableOperationCases = @(
        @{ Name = 'operation identity and result path'; Scenario = 'operation' },
        @{ Name = 'nonce'; Scenario = 'nonce' },
        @{ Name = 'helper hash'; Scenario = 'helper' },
        @{ Name = 'pending object IDs'; Scenario = 'pending' },
        @{ Name = 'request audit UTC'; Scenario = 'requested-utc' }
    )

    It 'preserves immutable attempt field <Name>' `
        -TestCases $immutableOperationCases {
        param($Name, $Scenario)

        $current = New-CommMonitorTestOperationPayloadForState `
            -State UninstallRequested
        $next = New-CommMonitorTestOperationPayloadForState `
            -State UninstallPrepared
        switch ($Scenario) {
            'operation' {
                $next.operationState.operationId =
                    '33333333-3333-3333-3333-333333333333'
                $next.operationState.resultRelativePath =
                    'state\results\33333333-3333-3333-3333-333333333333.v1.json'
            }
            'nonce' { $next.operationState.nonce = ('7' * 64) }
            'helper' { $next.operationState.helperSha256 = ('8' * 64) }
            'pending' {
                $next.operationState.pendingObjectIds =
                    [object[]]@('desktop-exe')
                $next.operationState.preparedTargets = [object[]]@()
            }
            'requested-utc' {
                $next.operationState.requestedUtc =
                    '2026-07-14T02:03:05.0000000Z'
            }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestManifestTransition `
                    -CurrentPayload $current `
                    -NextPayload $next `
                    -Actor Helper
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    It 'preserves prepared target identity through PendingReboot' {
        $current = New-CommMonitorTestOperationPayloadForState `
            -State UninstallPrepared
        $next = New-CommMonitorTestOperationPayloadForState `
            -State PendingReboot
        $next.operationState.preparedTargets[0].sha256 = ('9' * 64)
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestManifestTransition `
                    -CurrentPayload $current `
                    -NextPayload $next `
                    -Actor Helper
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    It 'preserves prepared target identity when Task5 abandons an attempt' {
        $current = New-CommMonitorTestOperationPayloadForState `
            -State UninstallPrepared
        $next = New-CommMonitorTestOperationPayloadForState -State Abandoned
        $next.operationState.preparedUtc =
            '2026-07-14T02:04:05.0000000Z'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestManifestTransition `
                    -CurrentPayload $current `
                    -NextPayload $next `
                    -Actor Task5
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    $replayedRetryCases = @(
        @{ Name = 'Abandoned operation and nonce'; From = 'Abandoned' },
        @{ Name = 'PendingReboot operation and nonce'; From = 'PendingReboot' }
    )

    It 'rejects replayed retry identity from <Name>' `
        -TestCases $replayedRetryCases {
        param($Name, $From)

        $current = New-CommMonitorTestOperationPayloadForState -State $From
        $nextArguments = @{ State = 'UninstallRequested' }
        if ($From -eq 'PendingReboot') {
            $nextArguments.ActiveContinuation = $true
        }
        $next = New-CommMonitorTestOperationPayloadForState @nextArguments
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestManifestTransition `
                    -CurrentPayload $current `
                    -NextPayload $next `
                    -Actor Task5
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    $immutableInstallSnapshotCases = @(
        @{ Name = 'appId'; Scenario = 'app-id' },
        @{ Name = 'installId'; Scenario = 'install-id' },
        @{ Name = 'creation UTC'; Scenario = 'created-utc' },
        @{ Name = 'platform signature'; Scenario = 'platform' },
        @{ Name = 'manifest key metadata'; Scenario = 'key-metadata' },
        @{ Name = 'owned-object identity'; Scenario = 'owned-object' }
    )

    It 'preserves immutable installation snapshot field <Name>' `
        -TestCases $immutableInstallSnapshotCases {
        param($Name, $Scenario)

        $current = New-CommMonitorTestOperationPayloadForState `
            -State UninstallRequested
        $next = New-CommMonitorTestOperationPayloadForState `
            -State UninstallPrepared
        switch ($Scenario) {
            'app-id' {
                $next.appId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
            }
            'install-id' {
                $next.installId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
            }
            'created-utc' {
                $next.createdUtc = '2026-07-14T02:00:01.0000000Z'
            }
            'platform' { $next.platform.build = 22632 }
            'key-metadata' {
                $next.keyMetadata.manifest.keyId = ('9' * 64)
            }
            'owned-object' {
                $desktop = @($next.ownedObjects | Where-Object {
                        $_.objectId -eq 'desktop-exe'
                    })[0]
                $desktop.identity.sha256 = ('9' * 64)
            }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestManifestTransition `
                    -CurrentPayload $current `
                    -NextPayload $next `
                    -Actor Helper
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    It 'keeps an Active continuation bound across a PendingReboot retry CAS' {
        $current = New-CommMonitorTestOperationPayloadForState `
            -State PendingReboot
        $next = New-CommMonitorTestOperationPayloadForState `
            -State UninstallRequested `
            -OperationId '33333333-3333-3333-3333-333333333333' `
            -Nonce ('7' * 64) `
            -RequestedUtc '2026-07-14T02:08:04.0000000Z'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestManifestTransition `
                    -CurrentPayload $current `
                    -NextPayload $next `
                    -Actor Task5
            } `
            -MessagePattern 'Ownership transition semantics'
    }
}

Describe 'CommMonitor recoverable reboot continuation protocol' {
    BeforeEach {
        $continuationMaterial =
            New-CommMonitorTestContinuationRecoveryMaterial
    }

    It 'creates an exact authenticated Active envelope for PendingReboot' {
        $envelope = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Active

        [string]::Join(',', [string[]]$envelope.Keys) |
            Should Be 'integrity,payload,schemaVersion'
        $envelope.schemaVersion | Should Be 1
        [string]::Join(',', [string[]]$envelope.payload.Keys) | Should Be (
            'installId,status,createdUtc,pendingObjectIds,helper,' +
            'finalizer,task,current')
        $envelope.payload.status | Should Be 'Active'
        $envelope.payload.current.revision | Should Be 1
        $envelope.payload.current.payloadSha256 |
            Should Be $continuationMaterial.CurrentPayloadSha256
        $envelope.payload.current.state | Should Be 'PendingReboot'
        $envelope.payload.pendingObjectIds[0] | Should Be 'semantic-dynamic'
        $envelope.payload.task.runAsSid | Should Be 'S-1-5-18'
        $envelope.payload.task.trigger | Should Be 'AtStartup'
        $envelope.payload.task.name | Should Be (
            '\LemonSerialMonitor\Uninstall-' +
            $continuationMaterial.CurrentPayload.installId)
        (Assert-CommMonitorContinuationEnvelope `
                -Envelope $envelope `
                -Key $continuationMaterial.Key).status |
            Should Be 'Active'
    }

    It 'resolves an Active PendingReboot pair without admitting helper work' {
        $envelope = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Active
        $resolved = Resolve-CommMonitorTestContinuationPair `
            -Material $continuationMaterial `
            -Continuation $envelope

        $resolved.Disposition | Should Be 'ActiveCurrent'
        $resolved.HelperAdmission | Should Be $false
        $resolved.CurrentPayload.state | Should Be 'PendingReboot'
    }

    It 'admits helper work only for an exact Active fresh Requested pair' {
        $envelope = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Active `
            -UseSuccessor
        $resolved = Resolve-CommMonitorTestContinuationPair `
            -Material $continuationMaterial `
            -Continuation $envelope `
            -UseSuccessor

        $resolved.Disposition | Should Be 'ActiveCurrent'
        $resolved.HelperAdmission | Should Be $true
        $resolved.CurrentPayload.operationState.operationId |
            Should Be '33333333-3333-3333-3333-333333333333'
    }

    It 'creates Prepared authority binding predecessor and complete successor' {
        $envelope = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Prepared

        $envelope.payload.status | Should Be 'Prepared'
        [string]::Join(',', [string[]]$envelope.payload.Keys) | Should Be (
            'installId,status,createdUtc,pendingObjectIds,helper,' +
            'finalizer,task,predecessor,successor')
        $envelope.payload.predecessor.revision | Should Be 1
        $envelope.payload.predecessor.payloadSha256 |
            Should Be $continuationMaterial.CurrentPayloadSha256
        $envelope.payload.predecessor.state | Should Be 'PendingReboot'
        $envelope.payload.successor.revision | Should Be 2
        $envelope.payload.successor.previousPayloadSha256 |
            Should Be $continuationMaterial.CurrentPayloadSha256
        $envelope.payload.successor.payloadSha256 |
            Should Be $continuationMaterial.SuccessorPayloadSha256
        $envelope.payload.successor.state | Should Be 'UninstallRequested'
        (ConvertTo-CommMonitorCanonicalJson `
                -InputObject $envelope.payload.successor.operationState) |
            Should Be (ConvertTo-CommMonitorCanonicalJson `
                -InputObject $continuationMaterial.SuccessorPayload.operationState)
    }

    It 'recovers Prepared authority to the exact predecessor before manifest CAS' {
        $envelope = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Prepared
        $resolved = Resolve-CommMonitorTestContinuationPair `
            -Material $continuationMaterial `
            -Continuation $envelope

        $resolved.Disposition | Should Be 'RecoverPredecessor'
        $resolved.HelperAdmission | Should Be $false
    }

    It 'promotes Prepared authority only after the exact successor manifest CAS' {
        $envelope = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Prepared
        $resolved = Resolve-CommMonitorTestContinuationPair `
            -Material $continuationMaterial `
            -Continuation $envelope `
            -UseSuccessor

        $resolved.Disposition | Should Be 'PromoteSuccessor'
        $resolved.HelperAdmission | Should Be $false
    }

    It 'converts a matching Prepared successor into an Active envelope' {
        $prepared = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Prepared
        $active = ConvertTo-CommMonitorActiveContinuationEnvelope `
            -PreparedEnvelope $prepared `
            -Manifest $continuationMaterial.SuccessorManifest `
            -Anchor $continuationMaterial.SuccessorAnchor `
            -ManifestKey $continuationMaterial.Key `
            -ExpectedManifestPath $continuationMaterial.ManifestPath `
            -ExpectedAppId $continuationMaterial.CurrentPayload.appId `
            -ExpectedInstallId $continuationMaterial.CurrentPayload.installId

        $active.payload.status | Should Be 'Active'
        $active.payload.current.payloadSha256 |
            Should Be $continuationMaterial.SuccessorPayloadSha256
        (Resolve-CommMonitorTestContinuationPair `
                -Material $continuationMaterial `
                -Continuation $active `
                -UseSuccessor).HelperAdmission | Should Be $true
    }

    It 'does not promote Prepared authority while the predecessor is current' {
        $prepared = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Prepared
        Assert-CommMonitorTestThrowsLike `
            -Action {
                ConvertTo-CommMonitorActiveContinuationEnvelope `
                    -PreparedEnvelope $prepared `
                    -Manifest $continuationMaterial.CurrentManifest `
                    -Anchor $continuationMaterial.CurrentAnchor `
                    -ManifestKey $continuationMaterial.Key `
                    -ExpectedManifestPath $continuationMaterial.ManifestPath `
                    -ExpectedAppId $continuationMaterial.CurrentPayload.appId `
                    -ExpectedInstallId (
                        $continuationMaterial.CurrentPayload.installId)
            } `
            -MessagePattern 'Continuation semantics'
    }

    It 'does not expose caller-supplied payload as promotion authority' {
        (Get-Command ConvertTo-CommMonitorActiveContinuationEnvelope).
            Parameters.ContainsKey('CurrentPayload') | Should Be $false
        (Get-Command ConvertTo-CommMonitorActiveContinuationEnvelope).
            Parameters.ContainsKey('CurrentPayloadSha256') | Should Be $false
    }

    It 'rejects an Active continuation paired with another valid manifest' {
        $active = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Active
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Resolve-CommMonitorTestContinuationPair `
                    -Material $continuationMaterial `
                    -Continuation $active `
                    -UseSuccessor
            } `
            -MessagePattern 'Continuation recovery semantics'
    }

    It 'rejects a Prepared continuation paired with an unrelated manifest' {
        $prepared = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Prepared
        $unrelated = New-CommMonitorTestOperationPayloadForState `
            -State UninstallRequested `
            -OperationId '44444444-4444-4444-4444-444444444444' `
            -Nonce ('9' * 64) `
            -RequestedUtc '2026-07-14T02:09:04.0000000Z' `
            -ActiveContinuation
        $unrelated.revision = 2
        $unrelated.previousPayloadSha256 =
            $continuationMaterial.CurrentPayloadSha256
        $context = New-CommMonitorTestManifestTransitionContext `
            -CurrentPayload $unrelated
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Resolve-CommMonitorContinuationPair `
                    -Manifest $context.Manifest `
                    -Anchor $context.Anchor `
                    -Continuation $prepared `
                    -Key $continuationMaterial.Key `
                    -ExpectedManifestPath $continuationMaterial.ManifestPath `
                    -ExpectedAppId $unrelated.appId `
                    -ExpectedInstallId $unrelated.installId
            } `
            -MessagePattern 'Continuation recovery semantics'
    }

    $resignedContinuationMutationCases = @(
        @{ Name = 'unknown payload field'; Scenario = 'unknown' },
        @{ Name = 'case-confused status'; Scenario = 'case' },
        @{ Name = 'traversing helper path'; Scenario = 'helper-path' },
        @{ Name = 'unbound task name'; Scenario = 'task-name' },
        @{ Name = 'unbound pending object IDs'; Scenario = 'pending' },
        @{ Name = 'unbound current revision'; Scenario = 'revision' }
    )

    It 'rejects re-signed <Name>' `
        -TestCases $resignedContinuationMutationCases {
        param($Name, $Scenario)

        $envelope = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Active
        switch ($Scenario) {
            'unknown' { $envelope.payload['unexpected'] = $true }
            'case' {
                $value = $envelope.payload.status
                $envelope.payload.Remove('status')
                $envelope.payload['Status'] = $value
            }
            'helper-path' {
                $envelope.payload.helper.relativePath = '..\outside.exe'
            }
            'task-name' {
                $envelope.payload.task.name = '\Other\Task'
            }
            'pending' {
                $envelope.payload.pendingObjectIds =
                    [object[]]@('desktop-exe')
            }
            'revision' { $envelope.payload.current.revision = 2 }
        }
        Update-CommMonitorTestContinuationIntegrity `
            -Envelope $envelope `
            -Key $continuationMaterial.Key
        if ($Scenario -in @('pending', 'revision')) {
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    Resolve-CommMonitorTestContinuationPair `
                        -Material $continuationMaterial `
                        -Continuation $envelope
                } `
                -MessagePattern 'Continuation recovery semantics'
        }
        else {
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    Assert-CommMonitorContinuationEnvelope `
                        -Envelope $envelope `
                        -Key $continuationMaterial.Key
                } `
                -MessagePattern 'Continuation (schema|semantics)'
        }
    }

    It 'rejects continuation HMAC tamper' {
        $envelope = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Active
        $envelope.integrity.tag = ('0' * 64)
        { Assert-CommMonitorContinuationEnvelope `
                -Envelope $envelope `
                -Key $continuationMaterial.Key } | Should Throw
    }

    It 'rejects a continuation under another key' {
        $envelope = New-CommMonitorTestContinuationEnvelopeForMaterial `
            -Material $continuationMaterial `
            -Status Active
        { Assert-CommMonitorContinuationEnvelope `
                -Envelope $envelope `
                -Key ([byte[]](31..62)) } | Should Throw
    }

    $invalidPreparedSuccessorCases = @(
        @{ Name = 'same revision'; Scenario = 'revision' },
        @{ Name = 'wrong previous hash'; Scenario = 'previous' },
        @{ Name = 'non-Requested successor'; Scenario = 'state' },
        @{ Name = 'inactive successor continuation'; Scenario = 'continuation' },
        @{ Name = 'replayed operation identity'; Scenario = 'operation' }
    )

    It 'rejects Prepared authority with <Name>' `
        -TestCases $invalidPreparedSuccessorCases {
        param($Name, $Scenario)

        $successor = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $continuationMaterial.SuccessorPayload
        switch ($Scenario) {
            'revision' { $successor.revision = 1 }
            'previous' { $successor.previousPayloadSha256 = ('9' * 64) }
            'state' {
                $successor = New-CommMonitorTestOperationPayloadForState `
                    -State UninstallPrepared `
                    -ActiveContinuation
                $successor.revision = 2
                $successor.previousPayloadSha256 =
                    $continuationMaterial.CurrentPayloadSha256
            }
            'continuation' {
                $successor.continuationState = [ordered]@{ status = 'None' }
            }
            'operation' {
                $successor.operationState =
                    New-CommMonitorTestRequestedOperationState `
                        -PendingObjectIds ([string[]]@('semantic-dynamic'))
            }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorContinuationEnvelope `
                    -Status Prepared `
                    -PredecessorPayload $continuationMaterial.CurrentPayload `
                    -PredecessorPayloadSha256 (
                        $continuationMaterial.CurrentPayloadSha256) `
                    -SuccessorPayload $successor `
                    -HelperRelativePath (
                        $continuationMaterial.HelperRelativePath) `
                    -HelperSha256 $continuationMaterial.HelperSha256 `
                    -FinalizerRelativePath (
                        $continuationMaterial.FinalizerRelativePath) `
                    -FinalizerSha256 $continuationMaterial.FinalizerSha256 `
                    -CreatedUtc $continuationMaterial.CreatedUtc `
                    -Key $continuationMaterial.Key `
                    -KeyId $continuationMaterial.KeyId
            } `
            -MessagePattern 'Continuation (schema|semantics)'
    }

    It 'rejects Active authority when helper hash differs from the operation' {
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorContinuationEnvelope `
                    -Status Active `
                    -CurrentPayload $continuationMaterial.CurrentPayload `
                    -CurrentPayloadSha256 (
                        $continuationMaterial.CurrentPayloadSha256) `
                    -HelperRelativePath (
                        $continuationMaterial.HelperRelativePath) `
                    -HelperSha256 ('9' * 64) `
                    -FinalizerRelativePath (
                        $continuationMaterial.FinalizerRelativePath) `
                    -FinalizerSha256 $continuationMaterial.FinalizerSha256 `
                    -CreatedUtc $continuationMaterial.CreatedUtc `
                    -Key $continuationMaterial.Key `
                    -KeyId $continuationMaterial.KeyId
            } `
            -MessagePattern 'Continuation (schema|semantics)'
    }
}

Describe 'CommMonitor independent terminal cleanup authority' {
    BeforeEach {
        $terminalMaterial = New-CommMonitorTestTerminalCleanupMaterial
    }

    It 'derives the stable terminal authority identity from the exact descriptor' {
        Get-CommMonitorTerminalCleanupAuthorityIdentity `
            -CleanupId $terminalMaterial.CleanupId `
            -Nonce $terminalMaterial.Nonce `
            -TerminalKeyRecord $terminalMaterial.TerminalKey.Record `
            -FinalizerRelativePath $terminalMaterial.Finalizer.relativePath `
            -FinalizerSha256 $terminalMaterial.Finalizer.sha256 `
            -DeletePlan $terminalMaterial.DeletePlan |
            Should Be $terminalMaterial.AuthorityIdentity
    }

    It 'creates one exact self-contained Prepared terminal envelope' {
        $envelope = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial

        [string]::Join(',', [string[]]$envelope.Keys) |
            Should Be 'integrity,payload,schemaVersion'
        $envelope.schemaVersion | Should Be 1
        [string]::Join(',', [string[]]$envelope.payload.Keys) | Should Be (
            'installId,status,cleanupId,nonce,createdUtc,key,' +
            'authorityIdentity,finalizer,deletePlan,predecessor,successor')
        $envelope.payload.status | Should Be 'Prepared'
        $envelope.payload.authorityIdentity |
            Should Be $terminalMaterial.AuthorityIdentity
        $envelope.payload.predecessor.state | Should Be 'UninstallPrepared'
        $envelope.payload.successor.state | Should Be 'FinalizingAbsent'
        $envelope.payload.successor.payloadSha256 |
            Should Be $terminalMaterial.SuccessorPayloadSha256
        (Assert-CommMonitorTerminalCleanupEnvelope `
                -Envelope $envelope `
                -UnprotectScript $terminalMaterial.UnprotectScript).status |
            Should Be 'Prepared'
    }

    It 'never serializes the plaintext terminal cleanup key' {
        $envelope = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        $json = ConvertTo-CommMonitorCanonicalJson -InputObject $envelope
        $json.Contains([Convert]::ToBase64String(
                $terminalMaterial.TerminalKey.KeyBytes)) | Should Be $false
    }

    It 'treats Prepared authority as removable before manifest CAS' {
        $envelope = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        $resolved = Resolve-CommMonitorTerminalCleanupAuthority `
            -Envelope $envelope `
            -UnprotectScript $terminalMaterial.UnprotectScript `
            -Manifest $terminalMaterial.CurrentManifest `
            -Anchor $terminalMaterial.CurrentAnchor `
            -ManifestKey $terminalMaterial.CurrentManifestKey `
            -ExpectedManifestPath $terminalMaterial.ManifestPath `
            -ExpectedAppId $terminalMaterial.CurrentPayload.appId `
            -ExpectedInstallId $terminalMaterial.CurrentPayload.installId

        $resolved.Disposition | Should Be 'RemovePrepared'
        $resolved.CanDeleteOwnedObjects | Should Be $false
    }

    It 'recovers Prepared authority for promotion after manifest CAS' {
        $envelope = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        $resolved = Resolve-CommMonitorTerminalCleanupAuthority `
            -Envelope $envelope `
            -UnprotectScript $terminalMaterial.UnprotectScript `
            -Manifest $terminalMaterial.SuccessorManifest `
            -Anchor $terminalMaterial.SuccessorAnchor `
            -ManifestKey $terminalMaterial.CurrentManifestKey `
            -ExpectedManifestPath $terminalMaterial.ManifestPath `
            -ExpectedAppId $terminalMaterial.CurrentPayload.appId `
            -ExpectedInstallId $terminalMaterial.CurrentPayload.installId

        $resolved.Disposition | Should Be 'PromoteActive'
        $resolved.CanDeleteOwnedObjects | Should Be $false
    }

    It 'promotes the same authority to Active only for its exact successor' {
        $prepared = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        $active = ConvertTo-CommMonitorActiveTerminalCleanupEnvelope `
            -PreparedEnvelope $prepared `
            -Manifest $terminalMaterial.SuccessorManifest `
            -Anchor $terminalMaterial.SuccessorAnchor `
            -ManifestKey $terminalMaterial.CurrentManifestKey `
            -ExpectedManifestPath $terminalMaterial.ManifestPath `
            -ExpectedAppId $terminalMaterial.CurrentPayload.appId `
            -ExpectedInstallId $terminalMaterial.CurrentPayload.installId `
            -UnprotectScript $terminalMaterial.UnprotectScript

        $active.payload.status | Should Be 'Active'
        $active.payload.authorityIdentity |
            Should Be $prepared.payload.authorityIdentity
        $active.payload.key.protectedBlob |
            Should Be $prepared.payload.key.protectedBlob
        $resolved = Resolve-CommMonitorTerminalCleanupAuthority `
            -Envelope $active `
            -UnprotectScript $terminalMaterial.UnprotectScript `
            -Manifest $terminalMaterial.SuccessorManifest `
            -Anchor $terminalMaterial.SuccessorAnchor `
            -ManifestKey $terminalMaterial.CurrentManifestKey `
            -ExpectedManifestPath $terminalMaterial.ManifestPath `
            -ExpectedAppId $terminalMaterial.CurrentPayload.appId `
            -ExpectedInstallId $terminalMaterial.CurrentPayload.installId
        $resolved.Disposition | Should Be 'ExecuteCleanup'
        $resolved.CanDeleteOwnedObjects | Should Be $true
    }

    It 'keeps Active terminal authority valid after manifest state is absent' {
        $prepared = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        $active = ConvertTo-CommMonitorActiveTerminalCleanupEnvelope `
            -PreparedEnvelope $prepared `
            -Manifest $terminalMaterial.SuccessorManifest `
            -Anchor $terminalMaterial.SuccessorAnchor `
            -ManifestKey $terminalMaterial.CurrentManifestKey `
            -ExpectedManifestPath $terminalMaterial.ManifestPath `
            -ExpectedAppId $terminalMaterial.CurrentPayload.appId `
            -ExpectedInstallId $terminalMaterial.CurrentPayload.installId `
            -UnprotectScript $terminalMaterial.UnprotectScript
        $resolved = Resolve-CommMonitorTerminalCleanupAuthority `
            -Envelope $active `
            -UnprotectScript $terminalMaterial.UnprotectScript

        $resolved.Disposition | Should Be 'ExecuteCleanup'
        $resolved.CanDeleteOwnedObjects | Should Be $true
    }

    It 'does not treat Prepared authority as independent cleanup authority' {
        $prepared = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Resolve-CommMonitorTerminalCleanupAuthority `
                    -Envelope $prepared `
                    -UnprotectScript $terminalMaterial.UnprotectScript
            } `
            -MessagePattern 'Terminal cleanup recovery semantics'
    }

    It 'rejects Active authority while the predecessor manifest is current' {
        $prepared = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        $active = ConvertTo-CommMonitorActiveTerminalCleanupEnvelope `
            -PreparedEnvelope $prepared `
            -Manifest $terminalMaterial.SuccessorManifest `
            -Anchor $terminalMaterial.SuccessorAnchor `
            -ManifestKey $terminalMaterial.CurrentManifestKey `
            -ExpectedManifestPath $terminalMaterial.ManifestPath `
            -ExpectedAppId $terminalMaterial.CurrentPayload.appId `
            -ExpectedInstallId $terminalMaterial.CurrentPayload.installId `
            -UnprotectScript $terminalMaterial.UnprotectScript
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Resolve-CommMonitorTerminalCleanupAuthority `
                    -Envelope $active `
                    -UnprotectScript $terminalMaterial.UnprotectScript `
                    -Manifest $terminalMaterial.CurrentManifest `
                    -Anchor $terminalMaterial.CurrentAnchor `
                    -ManifestKey $terminalMaterial.CurrentManifestKey `
                    -ExpectedManifestPath $terminalMaterial.ManifestPath `
                    -ExpectedAppId $terminalMaterial.CurrentPayload.appId `
                    -ExpectedInstallId $terminalMaterial.CurrentPayload.installId
            } `
            -MessagePattern 'Terminal cleanup recovery semantics'
    }

    It 'rejects terminal authority paired with an unrelated manifest' {
        $prepared = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        $unrelated = New-CommMonitorTestOperationPayloadForState `
            -State UninstallPrepared
        $unrelated.operationState.preparedTargets[0].sha256 = ('9' * 64)
        $context = New-CommMonitorTestManifestTransitionContext `
            -CurrentPayload $unrelated
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Resolve-CommMonitorTerminalCleanupAuthority `
                    -Envelope $prepared `
                    -UnprotectScript $terminalMaterial.UnprotectScript `
                    -Manifest $context.Manifest `
                    -Anchor $context.Anchor `
                    -ManifestKey $context.Key `
                    -ExpectedManifestPath $context.ManifestPath `
                    -ExpectedAppId $unrelated.appId `
                    -ExpectedInstallId $unrelated.installId
            } `
            -MessagePattern 'Terminal cleanup recovery semantics'
    }

    $terminalIntegrityMutationCases = @(
        @{ Name = 'protected blob'; Scenario = 'blob' },
        @{ Name = 'protected blob digest'; Scenario = 'blob-digest' },
        @{ Name = 'terminal keyId'; Scenario = 'key-id' },
        @{ Name = 'HMAC'; Scenario = 'hmac' }
    )

    It 'rejects terminal <Name> tamper' `
        -TestCases $terminalIntegrityMutationCases {
        param($Name, $Scenario)

        $envelope = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        switch ($Scenario) {
            'blob' { $envelope.payload.key.protectedBlob = 'AA==' }
            'blob-digest' {
                $envelope.payload.key.protectedBlobSha256 = ('0' * 64)
            }
            'key-id' { $envelope.payload.key.keyId = ('0' * 64) }
            'hmac' { $envelope.integrity.tag = ('0' * 64) }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Assert-CommMonitorTerminalCleanupEnvelope `
                    -Envelope $envelope `
                    -UnprotectScript $terminalMaterial.UnprotectScript
            } `
            -MessagePattern 'Terminal cleanup (schema|semantics)'
    }

    It 'fails closed when DPAPI unprotect fails' {
        $envelope = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Assert-CommMonitorTerminalCleanupEnvelope `
                    -Envelope $envelope `
                    -UnprotectScript { throw 'DPAPI unavailable' }
            } `
            -MessagePattern 'Terminal cleanup (schema|semantics)'
    }

    $resignedTerminalMutationCases = @(
        @{ Name = 'unknown payload field'; Scenario = 'unknown' },
        @{ Name = 'case-confused status'; Scenario = 'case' },
        @{ Name = 'traversing finalizer path'; Scenario = 'path' },
        @{ Name = 'duplicate object ID'; Scenario = 'duplicate' },
        @{ Name = 'noncanonical delete order'; Scenario = 'order' },
        @{ Name = 'missing anchor record'; Scenario = 'missing-anchor' },
        @{ Name = 'authority identity mismatch'; Scenario = 'identity' }
    )

    It 'rejects re-signed terminal <Name>' `
        -TestCases $resignedTerminalMutationCases {
        param($Name, $Scenario)

        $envelope = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        switch ($Scenario) {
            'unknown' { $envelope.payload['unexpected'] = $true }
            'case' {
                $value = $envelope.payload.status
                $envelope.payload.Remove('status')
                $envelope.payload['Status'] = $value
            }
            'path' {
                $envelope.payload.finalizer.relativePath = '..\outside.exe'
            }
            'duplicate' {
                $envelope.payload.deletePlan[1].objectId = 'continuation'
            }
            'order' {
                $envelope.payload.deletePlan[1].deleteOrder = 35
            }
            'missing-anchor' {
                $envelope.payload.deletePlan = [object[]]@(
                    $envelope.payload.deletePlan | Where-Object {
                        $_.objectId -ne 'anchor'
                    })
            }
            'identity' {
                $envelope.payload.authorityIdentity = ('0' * 64)
            }
        }
        Update-CommMonitorTestTerminalCleanupIntegrity `
            -Envelope $envelope `
            -Key $terminalMaterial.TerminalKey.KeyBytes
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Assert-CommMonitorTerminalCleanupEnvelope `
                    -Envelope $envelope `
                    -UnprotectScript $terminalMaterial.UnprotectScript
            } `
            -MessagePattern 'Terminal cleanup (schema|semantics)'
    }

    $invalidTerminalSuccessorCases = @(
        @{ Name = 'same revision'; Scenario = 'revision' },
        @{ Name = 'wrong previous hash'; Scenario = 'previous' },
        @{ Name = 'wrong terminal cleanup ID'; Scenario = 'cleanup-id' },
        @{ Name = 'wrong terminal key ID'; Scenario = 'key-id' },
        @{ Name = 'wrong authority identity'; Scenario = 'identity' }
    )

    It 'rejects terminal successor with <Name>' `
        -TestCases $invalidTerminalSuccessorCases {
        param($Name, $Scenario)

        $successor = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $terminalMaterial.SuccessorPayload
        switch ($Scenario) {
            'revision' { $successor.revision = 1 }
            'previous' { $successor.previousPayloadSha256 = ('9' * 64) }
            'cleanup-id' {
                $successor.operationState.terminalCleanupId =
                    '66666666-6666-6666-6666-666666666666'
            }
            'key-id' {
                $successor.operationState.terminalKeyId = ('9' * 64)
            }
            'identity' {
                $successor.operationState.terminalEnvelopeSha256 = ('9' * 64)
            }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorTerminalCleanupEnvelope `
                    -Status Prepared `
                    -PredecessorPayload $terminalMaterial.CurrentPayload `
                    -PredecessorPayloadSha256 (
                        $terminalMaterial.CurrentPayloadSha256) `
                    -SuccessorPayload $successor `
                    -CleanupId $terminalMaterial.CleanupId `
                    -Nonce $terminalMaterial.Nonce `
                    -FinalizerRelativePath (
                        $terminalMaterial.Finalizer.relativePath) `
                    -FinalizerSha256 $terminalMaterial.Finalizer.sha256 `
                    -DeletePlan $terminalMaterial.DeletePlan `
                    -CreatedUtc '2026-07-14T02:10:04.0000000Z' `
                    -TerminalKeyRecord $terminalMaterial.TerminalKey.Record `
                    -TerminalKey $terminalMaterial.TerminalKey.KeyBytes `
                    -TerminalPreparationCapability (
                        $terminalMaterial.TerminalPreparationCapability)
            } `
            -MessagePattern 'Terminal cleanup (schema|semantics)'
    }

    It 'authorizes the terminal manifest CAS only with matching Prepared authority' {
        $prepared = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        Test-CommMonitorTerminalPreparationCapability `
            -Capability (
                $terminalMaterial.TerminalPreparationCapability) |
            Should Be $true
        $updated = Invoke-CommMonitorTestTerminalManifestCas `
            -Material $terminalMaterial `
            -TerminalCleanupEnvelope $prepared `
            -TerminalUnprotectScript $terminalMaterial.UnprotectScript

        $updated.ActiveEnvelope.payload.state | Should Be 'FinalizingAbsent'
        $updated.ActiveEnvelope.payload.operationState.terminalEnvelopeSha256 |
            Should Be $terminalMaterial.AuthorityIdentity
        Test-CommMonitorTerminalPreparationCapability `
            -Capability (
                $terminalMaterial.TerminalPreparationCapability) |
            Should Be $false
    }

    It 'rejects a copied preparation capability during envelope creation' {
        $copy = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject (
                $terminalMaterial.TerminalPreparationCapability)
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
                    -Material $terminalMaterial `
                    -TerminalPreparationCapability $copy
            } `
            -MessagePattern 'Terminal cleanup (schema|semantics)'
    }

    It 'rejects a copied preparation capability during terminal CAS' {
        $prepared = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        $copy = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject (
                $terminalMaterial.TerminalPreparationCapability)
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestTerminalManifestCas `
                    -Material $terminalMaterial `
                    -TerminalCleanupEnvelope $prepared `
                    -TerminalUnprotectScript (
                        $terminalMaterial.UnprotectScript) `
                    -TerminalPreparationCapability $copy
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    It 'rejects replay after the preparation capability is consumed' {
        $prepared = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        [void](Invoke-CommMonitorTestTerminalManifestCas `
            -Material $terminalMaterial `
            -TerminalCleanupEnvelope $prepared `
            -TerminalUnprotectScript $terminalMaterial.UnprotectScript)

        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestTerminalManifestCas `
                    -Material $terminalMaterial `
                    -TerminalCleanupEnvelope $prepared `
                    -TerminalUnprotectScript (
                        $terminalMaterial.UnprotectScript)
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    It 'rejects terminal manifest CAS without Prepared authority' {
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestTerminalManifestCas `
                    -Material $terminalMaterial `
                    -OmitTerminalAuthority
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    It 'rejects Prepared authority bound to another terminal successor' {
        $prepared = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        $next = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $terminalMaterial.SuccessorPayload
        $next.operationState = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $terminalMaterial.SuccessorPayload.operationState
        $next.operationState.finalizingUtc =
            '2026-07-14T02:07:05.0000000Z'
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestTerminalManifestCas `
                    -Material $terminalMaterial `
                    -NextPayload $next `
                    -TerminalCleanupEnvelope $prepared `
                    -TerminalUnprotectScript (
                        $terminalMaterial.UnprotectScript)
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    It 'rejects Active authority as input to terminal manifest CAS' {
        $prepared = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        $active = ConvertTo-CommMonitorActiveTerminalCleanupEnvelope `
            -PreparedEnvelope $prepared `
            -Manifest $terminalMaterial.SuccessorManifest `
            -Anchor $terminalMaterial.SuccessorAnchor `
            -ManifestKey $terminalMaterial.CurrentManifestKey `
            -ExpectedManifestPath $terminalMaterial.ManifestPath `
            -ExpectedAppId $terminalMaterial.CurrentPayload.appId `
            -ExpectedInstallId $terminalMaterial.CurrentPayload.installId `
            -UnprotectScript $terminalMaterial.UnprotectScript
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestTerminalManifestCas `
                    -Material $terminalMaterial `
                    -TerminalCleanupEnvelope $active `
                    -TerminalUnprotectScript (
                        $terminalMaterial.UnprotectScript)
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    It 'rejects terminal manifest CAS when cleanup key unprotect fails' {
        $prepared = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Invoke-CommMonitorTestTerminalManifestCas `
                    -Material $terminalMaterial `
                    -TerminalCleanupEnvelope $prepared `
                    -TerminalUnprotectScript { throw 'DPAPI unavailable' }
            } `
            -MessagePattern 'Ownership transition semantics'
    }

    It 'does not promote terminal authority against the predecessor payload' {
        $prepared = New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
            -Material $terminalMaterial
        Assert-CommMonitorTestThrowsLike `
            -Action {
                ConvertTo-CommMonitorActiveTerminalCleanupEnvelope `
                    -PreparedEnvelope $prepared `
                    -Manifest $terminalMaterial.CurrentManifest `
                    -Anchor $terminalMaterial.CurrentAnchor `
                    -ManifestKey $terminalMaterial.CurrentManifestKey `
                    -ExpectedManifestPath $terminalMaterial.ManifestPath `
                    -ExpectedAppId $terminalMaterial.CurrentPayload.appId `
                    -ExpectedInstallId (
                        $terminalMaterial.CurrentPayload.installId) `
                    -UnprotectScript $terminalMaterial.UnprotectScript
            } `
            -MessagePattern 'Terminal cleanup (schema|semantics)'
    }
}

Describe 'CommMonitor terminal cleanup execution planning' {
    BeforeEach {
        $cleanupMaterial = New-CommMonitorTestTerminalCleanupMaterial
        $cleanupPrepared =
            New-CommMonitorTestTerminalCleanupEnvelopeForMaterial `
                -Material $cleanupMaterial
        $cleanupActive = ConvertTo-CommMonitorActiveTerminalCleanupEnvelope `
            -PreparedEnvelope $cleanupPrepared `
            -Manifest $cleanupMaterial.SuccessorManifest `
            -Anchor $cleanupMaterial.SuccessorAnchor `
            -ManifestKey $cleanupMaterial.CurrentManifestKey `
            -ExpectedManifestPath $cleanupMaterial.ManifestPath `
            -ExpectedAppId $cleanupMaterial.CurrentPayload.appId `
            -ExpectedInstallId $cleanupMaterial.CurrentPayload.installId `
            -UnprotectScript $cleanupMaterial.UnprotectScript
        $liveTerminalObjects =
            New-CommMonitorTestTerminalLiveObjects -Material $cleanupMaterial
    }

    It 'emits exact identity-held deletes followed by terminal authority last' {
        $actions = Get-CommMonitorTerminalCleanupActions `
            -ActiveEnvelope $cleanupActive `
            -LiveObjects $liveTerminalObjects `
            -UnprotectScript $cleanupMaterial.UnprotectScript

        [string]::Join(',', [string[]]@($actions.objectId)) | Should Be (
            'continuation,anchor,manifest,manifest-key,terminal-authority')
        [string]::Join(',', [string[]]@($actions.action)) | Should Be (
            'DeleteExactFile,DeleteExactFile,DeleteExactFile,' +
            'DeleteExactFile,DeleteAuthorityLast')
        $actions[-1].deleteOrder | Should Be ([int]::MaxValue)
    }

    It 'skips already absent leading objects without changing remaining order' {
        $liveTerminalObjects[0] = [ordered]@{
            objectId = 'continuation'; status = 'Absent'
        }
        $liveTerminalObjects[1] = [ordered]@{
            objectId = 'anchor'; status = 'Absent'
        }
        $actions = Get-CommMonitorTerminalCleanupActions `
            -ActiveEnvelope $cleanupActive `
            -LiveObjects $liveTerminalObjects `
            -UnprotectScript $cleanupMaterial.UnprotectScript

        [string]::Join(',', [string[]]@($actions.objectId)) |
            Should Be 'manifest,manifest-key,terminal-authority'
    }

    It 'removes terminal authority alone after every planned file is absent' {
        for ($index = 0; $index -lt $liveTerminalObjects.Count; $index++) {
            $liveTerminalObjects[$index] = [ordered]@{
                objectId = [string]$cleanupMaterial.DeletePlan[$index].objectId
                status = 'Absent'
            }
        }
        $actions = Get-CommMonitorTerminalCleanupActions `
            -ActiveEnvelope $cleanupActive `
            -LiveObjects $liveTerminalObjects `
            -UnprotectScript $cleanupMaterial.UnprotectScript

        $actions.Count | Should Be 1
        $actions[0].objectId | Should Be 'terminal-authority'
        $actions[0].action | Should Be 'DeleteAuthorityLast'
    }

    It 'never emits cleanup actions from Prepared authority' {
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Get-CommMonitorTerminalCleanupActions `
                    -ActiveEnvelope $cleanupPrepared `
                    -LiveObjects $liveTerminalObjects `
                    -UnprotectScript $cleanupMaterial.UnprotectScript
            } `
            -MessagePattern 'Terminal cleanup planning semantics'
    }

    $invalidLiveTerminalCases = @(
        @{ Name = 'missing record'; Scenario = 'missing' },
        @{ Name = 'unknown record'; Scenario = 'unknown' },
        @{ Name = 'duplicate record'; Scenario = 'duplicate' },
        @{ Name = 'unknown status'; Scenario = 'status' },
        @{ Name = 'root change'; Scenario = 'root' },
        @{ Name = 'path change'; Scenario = 'path' },
        @{ Name = 'volume change'; Scenario = 'volume' },
        @{ Name = 'file ID change'; Scenario = 'file-id' },
        @{ Name = 'size change'; Scenario = 'size' },
        @{ Name = 'hash change'; Scenario = 'hash' }
    )

    It 'fails closed for live terminal <Name>' `
        -TestCases $invalidLiveTerminalCases {
        param($Name, $Scenario)

        switch ($Scenario) {
            'missing' {
                $liveTerminalObjects = [object[]]@(
                    $liveTerminalObjects | Select-Object -Skip 1)
            }
            'unknown' {
                $liveTerminalObjects += [ordered]@{
                    objectId = 'unknown'; status = 'Absent'
                }
            }
            'duplicate' {
                $liveTerminalObjects[-1].objectId = 'manifest'
            }
            'status' { $liveTerminalObjects[0].status = 'Unknown' }
            'root' { $liveTerminalObjects[0].root = 'CoreRoot' }
            'path' {
                $liveTerminalObjects[0].relativePath = 'state\other.json'
            }
            'volume' {
                $liveTerminalObjects[0].volumeSerialNumber =
                    '8899aabbccddeeff'
            }
            'file-id' { $liveTerminalObjects[0].fileId = ('9' * 32) }
            'size' { $liveTerminalObjects[0].size = [long]999 }
            'hash' { $liveTerminalObjects[0].sha256 = ('9' * 64) }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Get-CommMonitorTerminalCleanupActions `
                    -ActiveEnvelope $cleanupActive `
                    -LiveObjects $liveTerminalObjects `
                    -UnprotectScript $cleanupMaterial.UnprotectScript
            } `
            -MessagePattern 'Terminal cleanup planning semantics'
    }

    It 'removes only the exact empty state directory before InstallerRoot' {
        $directories =
            New-CommMonitorTestPostTerminalDirectoryObservations
        $actions = Get-CommMonitorPostTerminalDirectoryCleanupActions `
            -TerminalAuthorityPresent $false `
            -Directories $directories

        [string]::Join(',', [string[]]@($actions.role)) |
            Should Be 'StateDirectory,InstallerRoot'
        @($actions | Where-Object {
                $_.action -ne 'DeleteEmptyDirectory'
            }).Count | Should Be 0
    }

    It 'skips a fixed container directory that is already absent' {
        $directories =
            New-CommMonitorTestPostTerminalDirectoryObservations
        $directories[0] = [ordered]@{
            role = 'StateDirectory'
            canonicalPath =
                'C:\ProgramData\LemonSerialMonitor\Installer\state'
            exists = $false
        }
        $actions = Get-CommMonitorPostTerminalDirectoryCleanupActions `
            -TerminalAuthorityPresent $false `
            -Directories $directories

        @($actions).Count | Should Be 1
        $actions[0].role | Should Be 'InstallerRoot'
    }

    $unsafePostTerminalCases = @(
        @{ Name = 'authority still present'; Scenario = 'authority' },
        @{ Name = 'nonempty directory'; Scenario = 'nonempty' },
        @{ Name = 'reparse directory'; Scenario = 'reparse' },
        @{ Name = 'nonlocal directory'; Scenario = 'volume' },
        @{ Name = 'weak ACL directory'; Scenario = 'acl' },
        @{ Name = 'wrong directory path'; Scenario = 'path' },
        @{ Name = 'missing directory observation'; Scenario = 'missing' }
    )

    It 'rejects post-terminal cleanup with <Name>' `
        -TestCases $unsafePostTerminalCases {
        param($Name, $Scenario)

        $directories =
            New-CommMonitorTestPostTerminalDirectoryObservations
        $authorityPresent = $false
        switch ($Scenario) {
            'authority' { $authorityPresent = $true }
            'nonempty' { $directories[0].empty = $false }
            'reparse' { $directories[0].reparsePoint = $true }
            'volume' { $directories[0].localFixedVolume = $false }
            'acl' { $directories[0].aclTrusted = $false }
            'path' { $directories[0].canonicalPath = 'C:\Other\state' }
            'missing' { $directories = [object[]]@($directories[0]) }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Get-CommMonitorPostTerminalDirectoryCleanupActions `
                    -TerminalAuthorityPresent $authorityPresent `
                    -Directories $directories
            } `
            -MessagePattern 'Post-terminal cleanup semantics'
    }

    It 'reports complete only when every authority, product root and residual is absent' {
        Test-CommMonitorTerminalCleanupComplete `
            -Observation (New-CommMonitorTestTerminalCompletionObservation) |
            Should Be $true
    }

    $incompleteTerminalCases = @(
        @{ Name = 'terminal authority'; Field = 'terminalAuthorityPresent' },
        @{ Name = 'manifest'; Field = 'manifestPresent' },
        @{ Name = 'continuation task'; Field = 'continuationTaskPresent' },
        @{ Name = 'uninstall entry'; Field = 'uninstallEntryPresent' },
        @{ Name = 'CoreRoot'; Field = 'coreRootPresent' },
        @{ Name = 'AI root'; Field = 'aiRootPresent' },
        @{ Name = 'recorded residual'; Field = 'residualObjectIds' }
    )

    It 'does not report completion while <Name> remains' `
        -TestCases $incompleteTerminalCases {
        param($Name, $Field)

        $observation = New-CommMonitorTestTerminalCompletionObservation
        if ($Field -eq 'residualObjectIds') {
            $observation[$Field] = [object[]]@('helper-exe')
        }
        else {
            $observation[$Field] = $true
        }
        Test-CommMonitorTerminalCleanupComplete -Observation $observation |
            Should Be $false
    }

    It 'rejects unknown completion observation fields' {
        $observation = New-CommMonitorTestTerminalCompletionObservation
        $observation['unexpected'] = $true
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Test-CommMonitorTerminalCleanupComplete `
                    -Observation $observation
            } `
            -MessagePattern 'Terminal completion schema'
    }
}

Describe 'CommMonitor authenticated uninstall result protocol' {
    BeforeEach {
        $resultMaterial = New-CommMonitorTestUninstallResultMaterial
    }

    $validResultCases = @(
        @{ Status = 'Completed'; ExitCode = 0; RebootRequired = $false },
        @{ Status = 'PendingReboot'; ExitCode = 3010; RebootRequired = $true },
        @{ Status = 'Failed'; ExitCode = 5; RebootRequired = $false }
    )

    It 'accepts exact <Status> result matrix' -TestCases $validResultCases {
        param($Status, $ExitCode, $RebootRequired)

        $envelope = New-CommMonitorTestUninstallResultEnvelope `
            -Material $resultMaterial `
            -Status $Status
        $payload = Assert-CommMonitorUninstallResultEnvelope `
            -Envelope $envelope `
            -ExpectedManifestPayload $resultMaterial.Payload `
            -ExpectedManifestPayloadSha256 $resultMaterial.PayloadSha256 `
            -Key $resultMaterial.Key

        $payload.status | Should Be $Status
        $payload.exitCode | Should Be $ExitCode
        $payload.rebootRequired | Should Be $RebootRequired
        $payload.operationId |
            Should Be $resultMaterial.Payload.operationState.operationId
        $payload.resultRelativePath |
            Should Be $resultMaterial.Payload.operationState.resultRelativePath
    }

    It 'creates the exact result envelope and payload field sets' {
        $envelope = New-CommMonitorTestUninstallResultEnvelope `
            -Material $resultMaterial `
            -Status Completed

        [string]::Join(',', [string[]]$envelope.Keys) |
            Should Be 'integrity,payload,schemaVersion'
        $envelope.schemaVersion | Should Be 1
        [string]::Join(',', [string[]]$envelope.payload.Keys) | Should Be (
            'installId,operationId,resultId,resultRelativePath,nonceSha256,' +
            'manifest,status,exitCode,rebootRequired,createdUtc,helper,outcomes')
        [string]::Join(',', [string[]]$envelope.payload.manifest.Keys) |
            Should Be 'revision,payloadSha256,state'
        [string]::Join(',', [string[]]$envelope.payload.helper.Keys) |
            Should Be 'pid,creationUtc,imageSha256'
    }

    It 'hashes decoded operation nonce bytes instead of serializing the nonce' {
        $envelope = New-CommMonitorTestUninstallResultEnvelope `
            -Material $resultMaterial `
            -Status Completed
        $nonceBytes = [byte[]]::new(32)
        for ($index = 0; $index -lt 32; $index++) {
            $nonceBytes[$index] = 0x11
        }

        $envelope.payload.nonceSha256 |
            Should Be (Get-CommMonitorSha256Hex -Bytes $nonceBytes)
        (ConvertTo-CommMonitorCanonicalJson -InputObject $envelope).
            Contains(('1' * 64)) | Should Be $false
    }

    $invalidResultMatrixCases = @(
        @{ Name = 'Completed nonzero exit'; Status = 'Completed'; ExitCode = 1; Reboot = $false },
        @{ Name = 'Completed reboot flag'; Status = 'Completed'; ExitCode = 0; Reboot = $true },
        @{ Name = 'PendingReboot wrong exit'; Status = 'PendingReboot'; ExitCode = 0; Reboot = $true },
        @{ Name = 'PendingReboot missing reboot flag'; Status = 'PendingReboot'; ExitCode = 3010; Reboot = $false },
        @{ Name = 'Failed zero exit'; Status = 'Failed'; ExitCode = 0; Reboot = $false },
        @{ Name = 'Failed reboot exit'; Status = 'Failed'; ExitCode = 3010; Reboot = $false },
        @{ Name = 'Failed reboot flag'; Status = 'Failed'; ExitCode = 5; Reboot = $true }
    )

    It 'rejects result matrix <Name>' -TestCases $invalidResultMatrixCases {
        param($Name, $Status, $ExitCode, $Reboot)

        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorTestUninstallResultEnvelope `
                    -Material $resultMaterial `
                    -Status $Status `
                    -ExitCode $ExitCode `
                    -RebootRequired $Reboot
            } `
            -MessagePattern 'Uninstall result (schema|semantics)'
    }

    $invalidOutcomeCases = @(
        @{ Name = 'missing outcome'; Scenario = 'missing'; Status = 'Completed' },
        @{ Name = 'duplicate outcome'; Scenario = 'duplicate'; Status = 'Completed' },
        @{ Name = 'unknown object ID'; Scenario = 'unknown'; Status = 'Completed' },
        @{ Name = 'Completed pending outcome'; Scenario = 'completed-pending'; Status = 'Completed' },
        @{ Name = 'PendingReboot without pending outcome'; Scenario = 'pending-deleted'; Status = 'PendingReboot' },
        @{ Name = 'Failed without failure outcome'; Scenario = 'failed-deleted'; Status = 'Failed' }
    )

    It 'rejects outcome set <Name>' -TestCases $invalidOutcomeCases {
        param($Name, $Scenario, $Status)

        $outcomes = switch ($Scenario) {
            'missing' { [object[]]@() }
            'duplicate' {
                [object[]]@(
                    [ordered]@{
                        objectId = 'semantic-dynamic'; outcome = 'Deleted'
                        win32Code = 0
                    },
                    [ordered]@{
                        objectId = 'semantic-dynamic'; outcome = 'Deleted'
                        win32Code = 0
                    })
            }
            'unknown' {
                [object[]]@([ordered]@{
                        objectId = 'desktop-exe'; outcome = 'Deleted'
                        win32Code = 0
                    })
            }
            'completed-pending' {
                [object[]]@([ordered]@{
                        objectId = 'semantic-dynamic'; outcome = 'PendingReboot'
                        win32Code = 32
                    })
            }
            'pending-deleted' {
                [object[]]@([ordered]@{
                        objectId = 'semantic-dynamic'; outcome = 'Deleted'
                        win32Code = 0
                    })
            }
            'failed-deleted' {
                [object[]]@([ordered]@{
                        objectId = 'semantic-dynamic'; outcome = 'Deleted'
                        win32Code = 0
                    })
            }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorTestUninstallResultEnvelope `
                    -Material $resultMaterial `
                    -Status $Status `
                    -Outcomes $outcomes
            } `
            -MessagePattern 'Uninstall result (schema|semantics)'
    }

    It 'rejects helper image hash not bound to the operation' {
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorUninstallResultEnvelope `
                    -ManifestPayload $resultMaterial.Payload `
                    -ManifestPayloadSha256 $resultMaterial.PayloadSha256 `
                    -ResultId $resultMaterial.ResultId `
                    -Status Completed `
                    -ExitCode 0 `
                    -RebootRequired $false `
                    -CreatedUtc $resultMaterial.CreatedUtc `
                    -HelperPid $resultMaterial.HelperPid `
                    -HelperCreationUtc $resultMaterial.HelperCreationUtc `
                    -HelperImageSha256 ('9' * 64) `
                    -Outcomes ([object[]]@([ordered]@{
                            objectId = 'semantic-dynamic'
                            outcome = 'Deleted'; win32Code = 0
                        })) `
                    -Key $resultMaterial.Key `
                    -KeyId $resultMaterial.KeyId
            } `
            -MessagePattern 'Uninstall result (schema|semantics)'
    }

    It 'rejects result creation before UninstallPrepared' {
        $requested = New-CommMonitorTestOperationPayloadForState `
            -State UninstallRequested
        $context = New-CommMonitorTestManifestTransitionContext `
            -CurrentPayload $requested
        $copy = [pscustomobject]@{
            Payload = $requested
            PayloadSha256 = $context.Envelope.integrity.payloadSha256
            Key = $context.Key
            KeyId = $context.KeyId
            ResultId = $resultMaterial.ResultId
            HelperPid = $resultMaterial.HelperPid
            HelperCreationUtc = $resultMaterial.HelperCreationUtc
            CreatedUtc = $resultMaterial.CreatedUtc
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorTestUninstallResultEnvelope `
                    -Material $copy `
                    -Status Completed
            } `
            -MessagePattern 'Uninstall result (schema|semantics)'
    }

    $resignedResultMutationCases = @(
        @{ Name = 'unknown payload field'; Scenario = 'unknown' },
        @{ Name = 'case-confused status'; Scenario = 'case' },
        @{ Name = 'operation ID'; Scenario = 'operation' },
        @{ Name = 'result path'; Scenario = 'path' },
        @{ Name = 'manifest hash'; Scenario = 'manifest' },
        @{ Name = 'unknown outcome'; Scenario = 'outcome' }
    )

    It 'rejects re-signed result <Name>' `
        -TestCases $resignedResultMutationCases {
        param($Name, $Scenario)

        $envelope = New-CommMonitorTestUninstallResultEnvelope `
            -Material $resultMaterial `
            -Status Completed
        switch ($Scenario) {
            'unknown' { $envelope.payload['unexpected'] = $true }
            'case' {
                $value = $envelope.payload.status
                $envelope.payload.Remove('status')
                $envelope.payload['Status'] = $value
            }
            'operation' {
                $envelope.payload.operationId =
                    '88888888-8888-8888-8888-888888888888'
            }
            'path' {
                $envelope.payload.resultRelativePath =
                    'state\results\other.v1.json'
            }
            'manifest' {
                $envelope.payload.manifest.payloadSha256 = ('9' * 64)
            }
            'outcome' {
                $envelope.payload.outcomes[0].outcome = 'Unknown'
            }
        }
        Update-CommMonitorTestUninstallResultIntegrity `
            -Envelope $envelope `
            -Key $resultMaterial.Key
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Assert-CommMonitorUninstallResultEnvelope `
                    -Envelope $envelope `
                    -ExpectedManifestPayload $resultMaterial.Payload `
                    -ExpectedManifestPayloadSha256 (
                        $resultMaterial.PayloadSha256) `
                    -Key $resultMaterial.Key
            } `
            -MessagePattern 'Uninstall result (schema|semantics)'
    }

    It 'rejects result HMAC tamper and another manifest key' {
        $envelope = New-CommMonitorTestUninstallResultEnvelope `
            -Material $resultMaterial `
            -Status Completed
        $envelope.integrity.tag = ('0' * 64)
        { Assert-CommMonitorUninstallResultEnvelope `
                -Envelope $envelope `
                -ExpectedManifestPayload $resultMaterial.Payload `
                -ExpectedManifestPayloadSha256 $resultMaterial.PayloadSha256 `
                -Key $resultMaterial.Key } | Should Throw

        $envelope = New-CommMonitorTestUninstallResultEnvelope `
            -Material $resultMaterial `
            -Status Completed
        { Assert-CommMonitorUninstallResultEnvelope `
                -Envelope $envelope `
                -ExpectedManifestPayload $resultMaterial.Payload `
                -ExpectedManifestPayloadSha256 $resultMaterial.PayloadSha256 `
                -Key ([byte[]](31..62)) } | Should Throw
    }

    It 'emits deterministic UTF-8 result bytes with one final LF' {
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        $originalUiCulture = [Globalization.CultureInfo]::CurrentUICulture
        try {
            $expected = $null
            foreach ($cultureName in @('en-US', 'tr-TR', 'zh-CN')) {
                [Globalization.CultureInfo]::CurrentCulture =
                    [Globalization.CultureInfo]::GetCultureInfo($cultureName)
                [Globalization.CultureInfo]::CurrentUICulture =
                    [Globalization.CultureInfo]::GetCultureInfo($cultureName)
                $envelope = New-CommMonitorTestUninstallResultEnvelope `
                    -Material $resultMaterial `
                    -Status Completed
                $bytes = Get-CommMonitorCanonicalStateFileBytes `
                    -InputObject $envelope
                $bytes[-1] | Should Be 0x0a
                $bytes[-2] | Should Not Be 0x0a
                ($bytes -contains [byte]0x0d) | Should Be $false
                if ($null -eq $expected) {
                    $expected = [Convert]::ToBase64String($bytes)
                }
                else {
                    [Convert]::ToBase64String($bytes) | Should Be $expected
                }
            }
        }
        finally {
            [Globalization.CultureInfo]::CurrentCulture = $originalCulture
            [Globalization.CultureInfo]::CurrentUICulture = $originalUiCulture
        }
    }
}

Describe 'CommMonitor one-time terminal preparation capability' {
    BeforeEach {
        $preparationMaterial =
            New-CommMonitorTestTerminalPreparationMaterial
    }

    It 'creates an opaque registered capability from completed evidence' {
        $capability = New-CommMonitorTerminalPreparationCapability `
            -CompletedResultEnvelope (
                $preparationMaterial.CompletedResult) `
            -ManifestPayload (
                $preparationMaterial.ResultMaterial.Payload) `
            -ManifestPayloadSha256 (
                $preparationMaterial.ResultMaterial.PayloadSha256) `
            -ManifestKey $preparationMaterial.ResultMaterial.Key `
            -ResidualObservation (
                $preparationMaterial.ResidualObservation)

        [string]::Join(
            ',',
            [string[]]$capability.PSObject.Properties.Name) | Should Be (
            'schemaVersion,capabilityId,installId,operationId,resultId,' +
            'resultEnvelopeSha256,manifestPayloadSha256,' +
            'residualEvidenceSha256')
        $capability.schemaVersion | Should Be 1
        Test-CommMonitorTerminalPreparationCapability `
            -Capability $capability | Should Be $true
    }

    It 'rejects a copied or deserialized capability token' {
        $capability = New-CommMonitorTerminalPreparationCapability `
            -CompletedResultEnvelope (
                $preparationMaterial.CompletedResult) `
            -ManifestPayload (
                $preparationMaterial.ResultMaterial.Payload) `
            -ManifestPayloadSha256 (
                $preparationMaterial.ResultMaterial.PayloadSha256) `
            -ManifestKey $preparationMaterial.ResultMaterial.Key `
            -ResidualObservation (
                $preparationMaterial.ResidualObservation)
        $copy = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $capability

        Test-CommMonitorTerminalPreparationCapability `
            -Capability $copy | Should Be $false
    }

    It 'invalidates a registered capability when its token is mutated' {
        $capability = New-CommMonitorTerminalPreparationCapability `
            -CompletedResultEnvelope (
                $preparationMaterial.CompletedResult) `
            -ManifestPayload (
                $preparationMaterial.ResultMaterial.Payload) `
            -ManifestPayloadSha256 (
                $preparationMaterial.ResultMaterial.PayloadSha256) `
            -ManifestKey $preparationMaterial.ResultMaterial.Key `
            -ResidualObservation (
                $preparationMaterial.ResidualObservation)
        $capability.capabilityId =
            '99999999-9999-9999-9999-999999999999'

        Test-CommMonitorTerminalPreparationCapability `
            -Capability $capability | Should Be $false
    }

    $nonCompletedPreparationCases = @(
        @{ Status = 'PendingReboot' },
        @{ Status = 'Failed' }
    )

    It 'rejects <Status> result as terminal preparation evidence' `
        -TestCases $nonCompletedPreparationCases {
        param($Status)

        $result = New-CommMonitorTestUninstallResultEnvelope `
            -Material $preparationMaterial.ResultMaterial `
            -Status $Status
        $observation = New-CommMonitorTestTerminalResidualObservation `
            -ResultEnvelope $result
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorTerminalPreparationCapability `
                    -CompletedResultEnvelope $result `
                    -ManifestPayload (
                        $preparationMaterial.ResultMaterial.Payload) `
                    -ManifestPayloadSha256 (
                        $preparationMaterial.ResultMaterial.PayloadSha256) `
                    -ManifestKey $preparationMaterial.ResultMaterial.Key `
                    -ResidualObservation $observation
            } `
            -MessagePattern 'Terminal preparation (schema|semantics)'
    }

    $unsafeResidualCases = @(
        @{ Name = 'a live product writer'; Scenario = 'writer' },
        @{ Name = 'a non-authority residual object'; Scenario = 'residual' },
        @{ Name = 'the uninstall entry'; Scenario = 'uninstallEntryPresent' },
        @{ Name = 'the continuation task'; Scenario = 'continuationTaskPresent' },
        @{ Name = 'the app root'; Scenario = 'appRootPresent' },
        @{ Name = 'the data root'; Scenario = 'dataRootPresent' },
        @{ Name = 'the AI root'; Scenario = 'aiRootPresent' },
        @{ Name = 'core non-authority state'; Scenario = 'coreNonAuthorityPresent' },
        @{ Name = 'installer non-authority state'; Scenario = 'installerNonAuthorityPresent' },
        @{ Name = 'another operation ID'; Scenario = 'operation' },
        @{ Name = 'another result ID'; Scenario = 'result' },
        @{ Name = 'verification older than the result'; Scenario = 'stale' }
    )

    It 'rejects terminal preparation while residual verification reports <Name>' `
        -TestCases $unsafeResidualCases {
        param($Name, $Scenario)

        $observation = New-CommMonitorTestTerminalResidualObservation `
            -ResultEnvelope $preparationMaterial.CompletedResult
        switch ($Scenario) {
            'writer' { $observation.productWriterCount = 1 }
            'residual' {
                $observation.nonAuthorityResidualObjectIds =
                    [object[]]@('semantic-dynamic')
            }
            'operation' {
                $observation.operationId =
                    '88888888-8888-8888-8888-888888888888'
            }
            'result' {
                $observation.resultId =
                    '99999999-9999-9999-9999-999999999999'
            }
            'stale' {
                $observation.verifiedUtc =
                    '2026-07-14T02:10:04.0000000Z'
            }
            default { $observation[$Scenario] = $true }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorTerminalPreparationCapability `
                    -CompletedResultEnvelope (
                        $preparationMaterial.CompletedResult) `
                    -ManifestPayload (
                        $preparationMaterial.ResultMaterial.Payload) `
                    -ManifestPayloadSha256 (
                        $preparationMaterial.ResultMaterial.PayloadSha256) `
                    -ManifestKey $preparationMaterial.ResultMaterial.Key `
                    -ResidualObservation $observation
            } `
            -MessagePattern 'Terminal preparation (schema|semantics)'
    }

    $residualSchemaCases = @(
        @{ Name = 'an unknown field'; Scenario = 'unknown' },
        @{ Name = 'a missing field'; Scenario = 'missing' },
        @{ Name = 'a case-confused field'; Scenario = 'case' },
        @{ Name = 'a non-Int32 writer count'; Scenario = 'writer-type' },
        @{ Name = 'a non-Boolean presence flag'; Scenario = 'boolean-type' }
    )

    It 'rejects residual evidence with <Name>' `
        -TestCases $residualSchemaCases {
        param($Name, $Scenario)

        $observation = New-CommMonitorTestTerminalResidualObservation `
            -ResultEnvelope $preparationMaterial.CompletedResult
        switch ($Scenario) {
            'unknown' { $observation['unexpected'] = $false }
            'missing' { $observation.Remove('verifiedUtc') }
            'case' {
                $value = $observation.operationId
                $observation.Remove('operationId')
                $observation['OperationId'] = $value
            }
            'writer-type' {
                $observation.productWriterCount = [long]0
            }
            'boolean-type' {
                $observation.appRootPresent = 'false'
            }
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorTerminalPreparationCapability `
                    -CompletedResultEnvelope (
                        $preparationMaterial.CompletedResult) `
                    -ManifestPayload (
                        $preparationMaterial.ResultMaterial.Payload) `
                    -ManifestPayloadSha256 (
                        $preparationMaterial.ResultMaterial.PayloadSha256) `
                    -ManifestKey $preparationMaterial.ResultMaterial.Key `
                    -ResidualObservation $observation
            } `
            -MessagePattern 'Terminal preparation (schema|semantics)'
    }
}

Describe 'CommMonitor dual-slot ownership manifest recovery' {
    BeforeEach {
        $dualSlotKey = [byte[]](0..31)
        $dualSlotKeyId = Get-CommMonitorSha256Hex -Bytes $dualSlotKey
        $dualSlotManifestPath =
            'C:\ProgramData\LemonSerialMonitor\Installer\state\ownership-manifest.v3.json'
        $dualSlotPayload = New-CommMonitorTestOwnershipPayloadForPlatform
        $dualSlotManifest = New-CommMonitorOwnershipManifest `
            -Payload $dualSlotPayload `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -ActiveSlot A
        $dualSlotEnvelope = $dualSlotManifest.slots.A
        $dualSlotAnchor = New-CommMonitorOwnershipAnchor `
            -Payload $dualSlotPayload `
            -PayloadSha256 $dualSlotEnvelope.integrity.payloadSha256 `
            -ManifestPath $dualSlotManifestPath `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -ActiveSlot A
    }

    It 'creates one active authenticated slot and one empty inactive slot' {
        [string]::Join(',', [string[]]$dualSlotManifest.Keys) |
            Should Be 'slots,schemaVersion'
        [string]::Join(',', [string[]]$dualSlotManifest.slots.Keys) |
            Should Be 'A,B'
        $dualSlotManifest.schemaVersion | Should Be 3
        $dualSlotManifest.slots.A | Should Not BeNullOrEmpty
        $dualSlotManifest.slots.B | Should BeNullOrEmpty
        $dualSlotAnchor.binding.activeSlot | Should Be 'A'

        $resolved = Assert-CommMonitorOwnershipManifestState `
            -Manifest $dualSlotManifest `
            -Anchor $dualSlotAnchor `
            -Key $dualSlotKey `
            -ExpectedManifestPath $dualSlotManifestPath `
            -ExpectedAppId $dualSlotPayload.appId `
            -ExpectedInstallId $dualSlotPayload.installId
        $resolved.revision | Should Be 1
    }

    It 'can initialize slot B without changing the manifest contract' {
        $manifest = New-CommMonitorOwnershipManifest `
            -Payload $dualSlotPayload `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -ActiveSlot B
        $anchor = New-CommMonitorOwnershipAnchor `
            -Payload $dualSlotPayload `
            -PayloadSha256 $manifest.slots.B.integrity.payloadSha256 `
            -ManifestPath $dualSlotManifestPath `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -ActiveSlot B
        $manifest.slots.A | Should BeNullOrEmpty
        $manifest.slots.B | Should Not BeNullOrEmpty
        (Assert-CommMonitorOwnershipManifestState `
                -Manifest $manifest `
                -Anchor $anchor `
                -Key $dualSlotKey `
                -ExpectedManifestPath $dualSlotManifestPath `
                -ExpectedAppId $dualSlotPayload.appId `
                -ExpectedInstallId $dualSlotPayload.installId).revision |
            Should Be 1
    }

    It 'writes the inactive slot and flips the signed pointer on CAS' {
        $nextPayload = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $dualSlotPayload
        $nextPayload.state = 'UninstallRequested'
        $nextPayload.operationState =
            New-CommMonitorTestRequestedOperationState
        $updated = Update-CommMonitorOwnershipManifestCas `
            -CurrentManifest $dualSlotManifest `
            -CurrentAnchor $dualSlotAnchor `
            -ExpectedRevision 1 `
            -ExpectedPayloadSha256 $dualSlotEnvelope.integrity.payloadSha256 `
            -NextPayload $nextPayload `
            -ManifestPath $dualSlotManifestPath `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -Actor Task5

        $updated.ActiveSlot | Should Be 'B'
        $updated.Manifest.slots.A.integrity.payloadSha256 |
            Should Be $dualSlotEnvelope.integrity.payloadSha256
        $updated.Manifest.slots.B.payload.revision | Should Be 2
        $updated.Manifest.slots.B.payload.previousPayloadSha256 |
            Should Be $dualSlotEnvelope.integrity.payloadSha256
        $updated.Anchor.binding.activeSlot | Should Be 'B'
        $updated.Anchor.binding.payloadSha256 |
            Should Be $updated.Manifest.slots.B.integrity.payloadSha256
    }

    It 'resolves the predecessor before the anchor linearization point' {
        $nextPayload = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $dualSlotPayload
        $nextPayload.state = 'UninstallRequested'
        $nextPayload.operationState =
            New-CommMonitorTestRequestedOperationState
        $updated = Update-CommMonitorOwnershipManifestCas `
            -CurrentManifest $dualSlotManifest `
            -CurrentAnchor $dualSlotAnchor `
            -ExpectedRevision 1 `
            -ExpectedPayloadSha256 $dualSlotEnvelope.integrity.payloadSha256 `
            -NextPayload $nextPayload `
            -ManifestPath $dualSlotManifestPath `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -Actor Task5

        $resolved = Assert-CommMonitorOwnershipManifestState `
            -Manifest $updated.Manifest `
            -Anchor $dualSlotAnchor `
            -Key $dualSlotKey `
            -ExpectedManifestPath $dualSlotManifestPath `
            -ExpectedAppId $dualSlotPayload.appId `
            -ExpectedInstallId $dualSlotPayload.installId
        $resolved.revision | Should Be 1
        $resolved.state | Should Be 'Committed'
    }

    It 'resolves the successor after the anchor linearization point' {
        $nextPayload = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $dualSlotPayload
        $nextPayload.state = 'UninstallRequested'
        $nextPayload.operationState =
            New-CommMonitorTestRequestedOperationState
        $updated = Update-CommMonitorOwnershipManifestCas `
            -CurrentManifest $dualSlotManifest `
            -CurrentAnchor $dualSlotAnchor `
            -ExpectedRevision 1 `
            -ExpectedPayloadSha256 $dualSlotEnvelope.integrity.payloadSha256 `
            -NextPayload $nextPayload `
            -ManifestPath $dualSlotManifestPath `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -Actor Task5

        $resolved = Assert-CommMonitorOwnershipManifestState `
            -Manifest $updated.Manifest `
            -Anchor $updated.Anchor `
            -Key $dualSlotKey `
            -ExpectedManifestPath $dualSlotManifestPath `
            -ExpectedAppId $dualSlotPayload.appId `
            -ExpectedInstallId $dualSlotPayload.installId
        $resolved.revision | Should Be 2
        $resolved.state | Should Be 'UninstallRequested'
    }

    It 'rejects a new anchor paired with the predecessor manifest' {
        $nextPayload = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $dualSlotPayload
        $nextPayload.state = 'UninstallRequested'
        $nextPayload.operationState =
            New-CommMonitorTestRequestedOperationState
        $updated = Update-CommMonitorOwnershipManifestCas `
            -CurrentManifest $dualSlotManifest `
            -CurrentAnchor $dualSlotAnchor `
            -ExpectedRevision 1 `
            -ExpectedPayloadSha256 $dualSlotEnvelope.integrity.payloadSha256 `
            -NextPayload $nextPayload `
            -ManifestPath $dualSlotManifestPath `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -Actor Task5
        {
            Assert-CommMonitorOwnershipManifestState `
                -Manifest $dualSlotManifest `
                -Anchor $updated.Anchor `
                -Key $dualSlotKey `
                -ExpectedManifestPath $dualSlotManifestPath `
                -ExpectedAppId $dualSlotPayload.appId `
                -ExpectedInstallId $dualSlotPayload.installId
        } | Should Throw
    }

    It 'alternates back to slot A on the next successful CAS' {
        $requested = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $dualSlotPayload
        $requested.state = 'UninstallRequested'
        $requested.operationState =
            New-CommMonitorTestRequestedOperationState
        $first = Update-CommMonitorOwnershipManifestCas `
            -CurrentManifest $dualSlotManifest `
            -CurrentAnchor $dualSlotAnchor `
            -ExpectedRevision 1 `
            -ExpectedPayloadSha256 $dualSlotEnvelope.integrity.payloadSha256 `
            -NextPayload $requested `
            -ManifestPath $dualSlotManifestPath `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -Actor Task5
        $abandoned = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $first.Manifest.slots.B.payload
        $abandoned.state = 'Abandoned'
        $abandoned.operationState =
            New-CommMonitorTestRequestedOperationState
        $abandoned.operationState['preparedTargets'] = [object[]]@()
        $abandoned.operationState['preparedUtc'] = $null
        $abandoned.operationState['abandonedReason'] = 'HelperExited'
        $abandoned.operationState['abandonedUtc'] =
            '2026-07-14T02:05:04.0000000Z'
        $second = Update-CommMonitorOwnershipManifestCas `
            -CurrentManifest $first.Manifest `
            -CurrentAnchor $first.Anchor `
            -ExpectedRevision 2 `
            -ExpectedPayloadSha256 $first.Manifest.slots.B.integrity.payloadSha256 `
            -NextPayload $abandoned `
            -ManifestPath $dualSlotManifestPath `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -Actor Task5

        $second.ActiveSlot | Should Be 'A'
        $second.Manifest.slots.A.payload.revision | Should Be 3
        $second.Manifest.slots.B.payload.revision | Should Be 2
        (Assert-CommMonitorOwnershipManifestState `
                -Manifest $second.Manifest `
                -Anchor $second.Anchor `
                -Key $dualSlotKey `
                -ExpectedManifestPath $dualSlotManifestPath `
                -ExpectedAppId $dualSlotPayload.appId `
                -ExpectedInstallId $dualSlotPayload.installId).revision |
            Should Be 3
    }

    It 'rejects swapping the two authenticated slots under an unchanged anchor' {
        $nextPayload = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $dualSlotPayload
        $nextPayload.state = 'UninstallRequested'
        $nextPayload.operationState =
            New-CommMonitorTestRequestedOperationState
        $updated = Update-CommMonitorOwnershipManifestCas `
            -CurrentManifest $dualSlotManifest `
            -CurrentAnchor $dualSlotAnchor `
            -ExpectedRevision 1 `
            -ExpectedPayloadSha256 $dualSlotEnvelope.integrity.payloadSha256 `
            -NextPayload $nextPayload `
            -ManifestPath $dualSlotManifestPath `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -Actor Task5
        $swapped = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $updated.Manifest
        $temporary = $swapped.slots.A
        $swapped.slots.A = $swapped.slots.B
        $swapped.slots.B = $temporary
        {
            Assert-CommMonitorOwnershipManifestState `
                -Manifest $swapped `
                -Anchor $updated.Anchor `
                -Key $dualSlotKey `
                -ExpectedManifestPath $dualSlotManifestPath `
                -ExpectedAppId $dualSlotPayload.appId `
                -ExpectedInstallId $dualSlotPayload.installId
        } | Should Throw
    }

    It 'fails closed when a populated inactive slot is corrupted' {
        $nextPayload = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $dualSlotPayload
        $nextPayload.state = 'UninstallRequested'
        $nextPayload.operationState =
            New-CommMonitorTestRequestedOperationState
        $updated = Update-CommMonitorOwnershipManifestCas `
            -CurrentManifest $dualSlotManifest `
            -CurrentAnchor $dualSlotAnchor `
            -ExpectedRevision 1 `
            -ExpectedPayloadSha256 $dualSlotEnvelope.integrity.payloadSha256 `
            -NextPayload $nextPayload `
            -ManifestPath $dualSlotManifestPath `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -Actor Task5
        $updated.Manifest.slots.A.integrity.tag = ('0' * 64)
        {
            Assert-CommMonitorOwnershipManifestState `
                -Manifest $updated.Manifest `
                -Anchor $updated.Anchor `
                -Key $dualSlotKey `
                -ExpectedManifestPath $dualSlotManifestPath `
                -ExpectedAppId $dualSlotPayload.appId `
                -ExpectedInstallId $dualSlotPayload.installId
        } | Should Throw
    }

    It 'rejects an anchor active-slot mutation' {
        $dualSlotAnchor.binding.activeSlot = 'B'
        {
            Assert-CommMonitorOwnershipManifestState `
                -Manifest $dualSlotManifest `
                -Anchor $dualSlotAnchor `
                -Key $dualSlotKey `
                -ExpectedManifestPath $dualSlotManifestPath `
                -ExpectedAppId $dualSlotPayload.appId `
                -ExpectedInstallId $dualSlotPayload.installId
        } | Should Throw
    }

    It 'prevents two stale writers from advancing the same active slot' {
        $nextPayload = Copy-CommMonitorTestOrdinalDictionary `
            -InputObject $dualSlotPayload
        $nextPayload.state = 'UninstallRequested'
        $nextPayload.operationState =
            New-CommMonitorTestRequestedOperationState
        $updated = Update-CommMonitorOwnershipManifestCas `
            -CurrentManifest $dualSlotManifest `
            -CurrentAnchor $dualSlotAnchor `
            -ExpectedRevision 1 `
            -ExpectedPayloadSha256 $dualSlotEnvelope.integrity.payloadSha256 `
            -NextPayload $nextPayload `
            -ManifestPath $dualSlotManifestPath `
            -Key $dualSlotKey `
            -KeyId $dualSlotKeyId `
            -Actor Task5
        {
            Update-CommMonitorOwnershipManifestCas `
                -CurrentManifest $updated.Manifest `
                -CurrentAnchor $updated.Anchor `
                -ExpectedRevision 1 `
                -ExpectedPayloadSha256 $dualSlotEnvelope.integrity.payloadSha256 `
                -NextPayload $nextPayload `
                -ManifestPath $dualSlotManifestPath `
                -Key $dualSlotKey `
                -KeyId $dualSlotKeyId `
                -Actor Task5
        } | Should Throw
    }
}

Describe 'CommMonitor authenticated ownership state' {
    BeforeEach {
        $testKey = [byte[]](0..31)
        $keyId = '630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abC1b8581bd710dd'.ToLowerInvariant()
        $manifestPath = 'C:\ProgramData\LemonSerialMonitor\Installer\state\ownership-manifest.v3.json'
        $payloadArguments = New-CommMonitorTestOwnershipPayloadArguments
        $payload = New-CommMonitorOwnershipPayload @payloadArguments
    }

    $envelopeObjectCases = @(
        @{ Name = 'envelope'; Target = 'envelope' },
        @{ Name = 'envelope integrity'; Target = 'integrity' })

    It 'rejects a primitive <Name> container before authentication' `
        -TestCases $envelopeObjectCases {
        param($Name, $Target)

        $envelope = New-CommMonitorTestSignedEnvelopeUnchecked `
            -Payload $payload `
            -Key $testKey
        if ($Target -eq 'integrity') {
            $envelope.integrity = 'integrity'
        }
        else {
            $envelope = 'envelope'
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Assert-CommMonitorOwnershipEnvelope `
                    -Envelope $envelope `
                    -Key $testKey
            } `
            -MessagePattern 'must be a raw object'
    }

    It 'requires envelope schemaVersion to be a raw Int32' {
        foreach ($case in @(New-CommMonitorTestRawInt32Coercions -ValidValue 3)) {
            $envelope = New-CommMonitorTestSignedEnvelopeUnchecked `
                -Payload $payload `
                -Key $testKey
            $envelope.schemaVersion = $case.Value
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    Assert-CommMonitorOwnershipEnvelope `
                        -Envelope $envelope `
                        -Key $testKey
                } `
                -MessagePattern 'schemaVersion must be a raw Int32'
        }
    }

    $envelopeStringCases = @(
        @{ Name = 'algorithm'; Field = 'algorithm' },
        @{ Name = 'keyId'; Field = 'keyId' },
        @{ Name = 'payloadSha256'; Field = 'payloadSha256' },
        @{ Name = 'tag'; Field = 'tag' })

    It 'requires envelope integrity <Name> to be a raw string' `
        -TestCases $envelopeStringCases {
        param($Name, $Field)

        foreach ($case in @(New-CommMonitorTestRawStringCoercions `
                -ValidValue ([string](New-CommMonitorTestSignedEnvelopeUnchecked `
                        -Payload $payload `
                        -Key $testKey).integrity[$Field]))) {
            $envelope = New-CommMonitorTestSignedEnvelopeUnchecked `
                -Payload $payload `
                -Key $testKey
            $envelope.integrity[$Field] = $case.Value
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    Assert-CommMonitorOwnershipEnvelope `
                        -Envelope $envelope `
                        -Key $testKey
                } `
                -MessagePattern 'must be a raw string'
        }
    }

    $anchorObjectCases = @(
        @{ Name = 'anchor'; Target = 'anchor' },
        @{ Name = 'anchor binding'; Target = 'binding' },
        @{ Name = 'anchor integrity'; Target = 'integrity' })

    It 'rejects a primitive <Name> container before anchor authentication' `
        -TestCases $anchorObjectCases {
        param($Name, $Target)

        $envelope = New-CommMonitorOwnershipEnvelope `
            -Payload $payload `
            -Key $testKey `
            -KeyId $keyId
        $anchor = New-CommMonitorOwnershipAnchor `
            -Payload $payload `
            -PayloadSha256 $envelope.integrity.payloadSha256 `
            -ManifestPath $manifestPath `
            -Key $testKey `
            -KeyId $keyId
        if ($Target -eq 'binding') {
            $anchor.binding = 'binding'
        }
        elseif ($Target -eq 'integrity') {
            $anchor.integrity = 'integrity'
        }
        else {
            $anchor = 'anchor'
        }
        Assert-CommMonitorTestThrowsLike `
            -Action {
                Assert-CommMonitorOwnershipState `
                    -Envelope $envelope `
                    -Anchor $anchor `
                    -Key $testKey `
                    -ExpectedManifestPath $manifestPath `
                    -ExpectedAppId $payload.appId `
                    -ExpectedInstallId $payload.installId
            } `
            -MessagePattern 'must be a raw object'
    }

    $anchorInt32Cases = @(
        @{ Name = 'schemaVersion'; Target = 'schema' },
        @{ Name = 'binding revision'; Target = 'revision' })

    It 'requires anchor <Name> to be a raw Int32' `
        -TestCases $anchorInt32Cases {
        param($Name, $Target)

        foreach ($case in @(New-CommMonitorTestRawInt32Coercions `
                -ValidValue $(if ($Target -eq 'schema') { 3 } else { 1 }))) {
            $envelope = New-CommMonitorOwnershipEnvelope `
                -Payload $payload `
                -Key $testKey `
                -KeyId $keyId
            $anchor = New-CommMonitorOwnershipAnchor `
                -Payload $payload `
                -PayloadSha256 $envelope.integrity.payloadSha256 `
                -ManifestPath $manifestPath `
                -Key $testKey `
                -KeyId $keyId
            if ($Target -eq 'schema') {
                $anchor.schemaVersion = $case.Value
            }
            else {
                $anchor.binding.revision = $case.Value
                $bindingBytes = [Text.UTF8Encoding]::new($false).GetBytes(
                    (ConvertTo-CommMonitorCanonicalJson `
                            -InputObject $anchor.binding))
                $anchor.integrity.tag = Get-CommMonitorHmacSha256Hex `
                    -Key $testKey `
                    -Bytes $bindingBytes
            }
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    Assert-CommMonitorOwnershipState `
                        -Envelope $envelope `
                        -Anchor $anchor `
                        -Key $testKey `
                        -ExpectedManifestPath $manifestPath `
                        -ExpectedAppId $payload.appId `
                        -ExpectedInstallId $payload.installId
                } `
                -MessagePattern 'must be a raw Int32'
        }
    }

    $anchorStringCases = @(
        @{ Name = 'binding appId'; Container = 'binding'; Field = 'appId' },
        @{ Name = 'binding installId'; Container = 'binding'; Field = 'installId' },
        @{ Name = 'binding keyId'; Container = 'binding'; Field = 'keyId' },
        @{ Name = 'binding manifestPath'; Container = 'binding'; Field = 'manifestPath' },
        @{ Name = 'binding payloadSha256'; Container = 'binding'; Field = 'payloadSha256' },
        @{ Name = 'integrity algorithm'; Container = 'integrity'; Field = 'algorithm' },
        @{ Name = 'integrity keyId'; Container = 'integrity'; Field = 'keyId' },
        @{ Name = 'integrity tag'; Container = 'integrity'; Field = 'tag' })

    It 'requires anchor <Name> to be a raw string' `
        -TestCases $anchorStringCases {
        param($Name, $Container, $Field)

        $envelope = New-CommMonitorOwnershipEnvelope `
            -Payload $payload `
            -Key $testKey `
            -KeyId $keyId
        $baselineAnchor = New-CommMonitorOwnershipAnchor `
            -Payload $payload `
            -PayloadSha256 $envelope.integrity.payloadSha256 `
            -ManifestPath $manifestPath `
            -Key $testKey `
            -KeyId $keyId
        $validValue = [string]$baselineAnchor[$Container][$Field]
        foreach ($case in @(New-CommMonitorTestRawStringCoercions `
                -ValidValue $validValue)) {
            $anchor = New-CommMonitorOwnershipAnchor `
                -Payload $payload `
                -PayloadSha256 $envelope.integrity.payloadSha256 `
                -ManifestPath $manifestPath `
                -Key $testKey `
                -KeyId $keyId
            $anchor[$Container][$Field] = $case.Value
            if ($Container -eq 'binding') {
                $bindingBytes = [Text.UTF8Encoding]::new($false).GetBytes(
                    (ConvertTo-CommMonitorCanonicalJson `
                            -InputObject $anchor.binding))
                $anchor.integrity.tag = Get-CommMonitorHmacSha256Hex `
                    -Key $testKey `
                    -Bytes $bindingBytes
            }
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    Assert-CommMonitorOwnershipState `
                        -Envelope $envelope `
                        -Anchor $anchor `
                        -Key $testKey `
                        -ExpectedManifestPath $manifestPath `
                        -ExpectedAppId $payload.appId `
                        -ExpectedInstallId $payload.installId
                } `
                -MessagePattern 'must be a raw string'
        }
    }

    It 'rejects CAS ExpectedRevision binder coercions' {
        foreach ($case in @(
                [pscustomobject]@{ Name = 'string'; Value = '1' },
                [pscustomobject]@{ Name = 'Boolean'; Value = $true },
                [pscustomobject]@{ Name = 'Double'; Value = [double]1 },
                [pscustomobject]@{ Name = 'Int64'; Value = [long]1 })) {
            $envelope = New-CommMonitorOwnershipEnvelope `
                -Payload $payload `
                -Key $testKey `
                -KeyId $keyId
            $anchor = New-CommMonitorOwnershipAnchor `
                -Payload $payload `
                -PayloadSha256 $envelope.integrity.payloadSha256 `
                -ManifestPath $manifestPath `
                -Key $testKey `
                -KeyId $keyId
            $nextArguments = New-CommMonitorTestOwnershipPayloadArguments
            $next = New-CommMonitorOwnershipPayload @nextArguments
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    Update-CommMonitorOwnershipStateCas `
                        -CurrentEnvelope $envelope `
                        -CurrentAnchor $anchor `
                        -ExpectedRevision $case.Value `
                        -ExpectedPayloadSha256 $envelope.integrity.payloadSha256 `
                        -NextPayload $next `
                        -ManifestPath $manifestPath `
                        -Key $testKey `
                        -KeyId $keyId
                } `
                -MessagePattern 'ExpectedRevision must be a raw Int32'
        }
    }

    It 'rejects CAS ExpectedPayloadSha256 binder coercions' {
        $envelope = New-CommMonitorOwnershipEnvelope `
            -Payload $payload `
            -Key $testKey `
            -KeyId $keyId
        $anchor = New-CommMonitorOwnershipAnchor `
            -Payload $payload `
            -PayloadSha256 $envelope.integrity.payloadSha256 `
            -ManifestPath $manifestPath `
            -Key $testKey `
            -KeyId $keyId
        foreach ($case in @(New-CommMonitorTestRawStringCoercions `
                -ValidValue $envelope.integrity.payloadSha256)) {
            $nextArguments = New-CommMonitorTestOwnershipPayloadArguments
            $next = New-CommMonitorOwnershipPayload @nextArguments
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    Update-CommMonitorOwnershipStateCas `
                        -CurrentEnvelope $envelope `
                        -CurrentAnchor $anchor `
                        -ExpectedRevision 1 `
                        -ExpectedPayloadSha256 $case.Value `
                        -NextPayload $next `
                        -ManifestPath $manifestPath `
                        -Key $testKey `
                        -KeyId $keyId
                } `
                -MessagePattern 'ExpectedPayloadSha256 must be a raw string'
        }
    }

    $dataRootStringCases = @(
        @{ Name = 'installId'; Target = 'installId' },
        @{ Name = 'canonicalPath'; Target = 'canonicalPath' },
        @{ Name = 'volumeSerialNumber'; Target = 'volumeSerialNumber' },
        @{ Name = 'fileId'; Target = 'fileId' },
        @{ Name = 'ownershipProof'; Target = 'ownershipProof' })

    It 'rejects a one-element array impersonating authenticated DataRoot <Name>' `
        -TestCases $dataRootStringCases {
        param($Name, $Target)

        $payload.roots.dataRoot.volumeSerialNumber = '0011223344556677'
        $payload.roots.dataRoot.fileId = ('b' * 32)
        $payload.roots.dataRoot.ownershipProof = 'CreatedThisInstall'
        if ($Target -eq 'installId') {
            $payload.installId = [object[]]@($payload.installId)
        }
        else {
            $payload.roots.dataRoot[$Target] =
                [object[]]@($payload.roots.dataRoot[$Target])
        }
        $module = Get-Module CommMonitor.InstallHelpers
        $registeredPayload = & $module {
            param($Candidate)
            Register-CommMonitorAuthenticatedOwnershipPayload `
                -Payload $Candidate `
                -PayloadSha256 ('a' * 64)
        } $payload
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorDataRootAdoptionEvidence `
                    -SourceKind AuthenticatedManifestV3 `
                    -AuthenticatedPayload $registeredPayload
            } `
            -MessagePattern 'must be a raw string'
    }

    $dataRootAclPrimitiveCases = @(
        @{
            Name = 'areAccessRulesProtected'
            Field = 'areAccessRulesProtected'
            Value = [object[]]@($true)
            Pattern = 'must be a raw Boolean'
        },
        @{
            Name = 'denyRuleCount'
            Field = 'denyRuleCount'
            Value = [object[]]@([int]0)
            Pattern = 'must be a raw Int32'
        })

    It 'rejects a one-element array impersonating authenticated DataRoot ACL <Name>' `
        -TestCases $dataRootAclPrimitiveCases {
        param($Name, $Field, $Value, $Pattern)

        $candidateArguments = New-CommMonitorTestOwnershipPayloadArguments
        $candidate = New-CommMonitorOwnershipPayload @candidateArguments
        $candidate.roots.dataRoot.volumeSerialNumber = '0011223344556677'
        $candidate.roots.dataRoot.fileId = ('b' * 32)
        $candidate.roots.dataRoot.ownershipProof = 'CreatedThisInstall'
        $candidate.roots.dataRoot.aclProfile[$Field] = $Value
        $module = Get-Module CommMonitor.InstallHelpers
        $registeredPayload = & $module {
            param($Candidate)
            Register-CommMonitorAuthenticatedOwnershipPayload `
                -Payload $Candidate `
                -PayloadSha256 ('a' * 64)
        } $candidate
        Assert-CommMonitorTestThrowsLike `
            -Action {
                New-CommMonitorDataRootAdoptionEvidence `
                    -SourceKind AuthenticatedManifestV3 `
                    -AuthenticatedPayload $registeredPayload
            } `
            -MessagePattern $Pattern
    }

    It 'rejects a correctly signed payload with unknown missing or wrong-case fields' {
        foreach ($case in @(New-CommMonitorTestExactSchemaMutations `
                -InputObject $payload `
                -RequiredField appId `
                -WrongCaseField AppId)) {
            $invalidEnvelope = New-CommMonitorTestSignedEnvelopeUnchecked `
                -Payload $case.Value `
                -Key $testKey
            Assert-CommMonitorTestThrowsLike `
                -Action {
                    Assert-CommMonitorOwnershipEnvelope `
                        -Envelope $invalidEnvelope `
                        -Key $testKey
                } `
                -MessagePattern 'Ownership payload (contains|is missing)'
        }
    }

    It 'does not re-sign a CAS payload outside the exact ownership schema' {
        $envelope = New-CommMonitorOwnershipEnvelope `
            -Payload $payload `
            -Key $testKey `
            -KeyId $keyId
        $anchor = New-CommMonitorOwnershipAnchor `
            -Payload $payload `
            -PayloadSha256 $envelope.integrity.payloadSha256 `
            -ManifestPath $manifestPath `
            -Key $testKey `
            -KeyId $keyId
        $next = Copy-CommMonitorTestOrdinalDictionary -InputObject $payload
        $next.Add('unexpected', $true)

        Assert-CommMonitorTestThrowsLike `
            -Action {
                Update-CommMonitorOwnershipStateCas `
                    -CurrentEnvelope $envelope `
                    -CurrentAnchor $anchor `
                    -ExpectedRevision 1 `
                    -ExpectedPayloadSha256 $envelope.integrity.payloadSha256 `
                    -NextPayload $next `
                    -ManifestPath $manifestPath `
                    -Key $testKey `
                    -KeyId $keyId
            } `
            -MessagePattern "Ownership payload contains unknown field 'unexpected'"
    }

    It 'matches deterministic SHA-256 and HMAC-SHA256 vectors' {
        $vectorText = 'Lemon' +
            [char]0x4e32 + [char]0x53e3 + [char]0x76d1 + [char]0x63a7
        $bytes = [Text.Encoding]::UTF8.GetBytes($vectorText)
        (Get-CommMonitorSha256Hex -Bytes $bytes) |
            Should Be '89e3c42a7757300dff318ff3c9c0839ecb57a4e01219495bb449ee0e9da531eb'
        (Get-CommMonitorHmacSha256Hex -Key $testKey -Bytes $bytes) |
            Should Be '2aebdcf85350cdd815b24d07294a3e42fd7b1fdf336f52698c13b1a4609dc144'
        (Test-CommMonitorFixedTimeEquals `
            -LeftHex ('a' * 64) `
            -RightHex ('a' * 64)) | Should Be $true
        (Test-CommMonitorFixedTimeEquals `
            -LeftHex ('a' * 64) `
            -RightHex (('a' * 63) + 'b')) | Should Be $false
    }

    It 'creates a DPAPI key record without serializing the plaintext key' {
        $protected = New-CommMonitorManifestKey `
            -KeyBytes $testKey `
            -ProtectScript {
                param([byte[]] $Bytes)
                return [byte[]]@($Bytes | ForEach-Object { $_ -bxor 0x5a })
            }

        $protected.Record.state | Should Be 'Active'
        $protected.Record.keyId | Should Be $keyId
        $protected.Record.scope | Should Be 'LocalMachine'
        (ConvertTo-CommMonitorCanonicalJson $protected.Record).Contains(
            ([BitConverter]::ToString($testKey)).Replace('-', '')) | Should Be $false

        $unprotected = Get-CommMonitorManifestKey `
            -Record $protected.Record `
            -UnprotectScript {
                param([byte[]] $Bytes)
                return [byte[]]@($Bytes | ForEach-Object { $_ -bxor 0x5a })
            }
        ([BitConverter]::ToString($unprotected)) | Should Be ([BitConverter]::ToString($testKey))

        $tampered = ConvertFrom-CommMonitorStrictJson `
            -Json (ConvertTo-CommMonitorCanonicalJson $protected.Record) `
            -AllowedRootFields @(
                'algorithm', 'keyId', 'protectedBlob', 'protectedBlobSha256',
                'schemaVersion', 'scope', 'state')
        $tampered.protectedBlobSha256 = ('0' * 64)
        { Get-CommMonitorManifestKey `
                -Record $tampered `
                -UnprotectScript { param($Bytes) $Bytes } } | Should Throw
    }

    It 'requires a SYSTEM Administrators only protected key-file ACL' {
        $strictRules = @(
            [pscustomobject]@{
                IdentitySid = 'S-1-5-18'; AccessControlType = 'Allow'
                FileSystemRights = [Security.AccessControl.FileSystemRights]::FullControl
            },
            [pscustomobject]@{
                IdentitySid = 'S-1-5-32-544'; AccessControlType = 'Allow'
                FileSystemRights = [Security.AccessControl.FileSystemRights]::FullControl
            })
        (Test-CommMonitorKeyFileAcl `
            -OwnerSid 'S-1-5-32-544' `
            -AccessRules $strictRules `
            -AreAccessRulesProtected $true) | Should Be $true

        $usersRead = @($strictRules + [pscustomobject]@{
                IdentitySid = 'S-1-5-32-545'; AccessControlType = 'Allow'
                FileSystemRights = [Security.AccessControl.FileSystemRights]::Read
            })
        (Test-CommMonitorKeyFileAcl `
            -OwnerSid 'S-1-5-32-544' `
            -AccessRules $usersRead `
            -AreAccessRulesProtected $true) | Should Be $false
        (Test-CommMonitorKeyFileAcl `
            -OwnerSid 'S-1-5-32-544' `
            -AccessRules $strictRules `
            -AreAccessRulesProtected $false) | Should Be $false
    }

    It 'cross-binds manifest key payload and authoritative Core anchor' {
        $envelope = New-CommMonitorOwnershipEnvelope `
            -Payload $payload `
            -Key $testKey `
            -KeyId $keyId
        $anchor = New-CommMonitorOwnershipAnchor `
            -Payload $payload `
            -PayloadSha256 $envelope.integrity.payloadSha256 `
            -ManifestPath $manifestPath `
            -Key $testKey `
            -KeyId $keyId

        $validated = Assert-CommMonitorOwnershipState `
            -Envelope $envelope `
            -Anchor $anchor `
            -Key $testKey `
            -ExpectedManifestPath $manifestPath `
            -ExpectedAppId $payload.appId `
            -ExpectedInstallId $payload.installId

        $validated.revision | Should Be 1

        $tamperedPayload = ConvertFrom-CommMonitorStrictJson `
            -Json (ConvertTo-CommMonitorCanonicalJson $envelope) `
            -AllowedRootFields @('integrity', 'payload', 'schemaVersion')
        $tamperedPayload.payload.productVersion = '9.9.9'
        { Assert-CommMonitorOwnershipState `
                -Envelope $tamperedPayload `
                -Anchor $anchor `
                -Key $testKey `
                -ExpectedManifestPath $manifestPath `
                -ExpectedAppId $payload.appId `
                -ExpectedInstallId $payload.installId } | Should Throw

        { Assert-CommMonitorOwnershipState `
                -Envelope $envelope `
                -Anchor $anchor `
                -Key ([byte[]](32..63)) `
                -ExpectedManifestPath $manifestPath `
                -ExpectedAppId $payload.appId `
                -ExpectedInstallId $payload.installId } | Should Throw
        { Assert-CommMonitorOwnershipState `
                -Envelope $envelope `
                -Anchor $anchor `
                -Key $testKey `
                -ExpectedManifestPath 'C:\Program Files\Lemon串口监控\ownership-manifest.v3.json' `
                -ExpectedAppId $payload.appId `
                -ExpectedInstallId $payload.installId } | Should Throw
        { Assert-CommMonitorOwnershipState `
                -Envelope $envelope `
                -Anchor $anchor `
                -Key $testKey `
                -ExpectedManifestPath $manifestPath `
                -ExpectedAppId $payload.appId `
                -ExpectedInstallId 'cccccccc-cccc-cccc-cccc-cccccccccccc' } | Should Throw
    }

    It 'increments CAS revision chains and prevents two stale writers from succeeding' {
        $envelope = New-CommMonitorOwnershipEnvelope `
            -Payload $payload `
            -Key $testKey `
            -KeyId $keyId
        $anchor = New-CommMonitorOwnershipAnchor `
            -Payload $payload `
            -PayloadSha256 $envelope.integrity.payloadSha256 `
            -ManifestPath $manifestPath `
            -Key $testKey `
            -KeyId $keyId

        $nextPayload = Copy-CommMonitorTestOrdinalDictionary -InputObject $payload
        $nextPayload.state = 'UninstallRequested'
        $nextPayload.operationState =
            New-CommMonitorTestRequestedOperationState
        $updated = Update-CommMonitorOwnershipStateCas `
            -CurrentEnvelope $envelope `
            -CurrentAnchor $anchor `
            -ExpectedRevision 1 `
            -ExpectedPayloadSha256 $envelope.integrity.payloadSha256 `
            -NextPayload $nextPayload `
            -ManifestPath $manifestPath `
            -Key $testKey `
            -KeyId $keyId

        $updated.Envelope.payload.revision | Should Be 2
        $updated.Envelope.payload.previousPayloadSha256 |
            Should Be $envelope.integrity.payloadSha256
        $updated.Anchor.binding.revision | Should Be 2

        { Update-CommMonitorOwnershipStateCas `
                -CurrentEnvelope $updated.Envelope `
                -CurrentAnchor $updated.Anchor `
                -ExpectedRevision 1 `
                -ExpectedPayloadSha256 $envelope.integrity.payloadSha256 `
                -NextPayload $nextPayload `
                -ManifestPath $manifestPath `
                -Key $testKey `
                -KeyId $keyId } | Should Throw
    }

    It 'preserves the prior state and removes temporary files on atomic faults' {
        InModuleScope CommMonitor.InstallHelpers {
            Mock Assert-CommMonitorTrustedDirectory {}
            $stateRoot = Join-Path $TestDrive 'state-write'
            [void][IO.Directory]::CreateDirectory($stateRoot)
            $statePath = Join-Path $stateRoot 'ownership-manifest.v3.json'
            $aclPaths = [Collections.Generic.List[string]]::new()
            $setAcl = {
                param([string] $Path)
                $aclPaths.Add($Path)
            }.GetNewClosure()

            Write-CommMonitorAtomicStateFile `
                -LiteralPath $statePath `
                -Value 'old-valid-envelope' `
                -SetStrictAclScript $setAcl

            { Write-CommMonitorAtomicStateFile `
                    -LiteralPath $statePath `
                    -Value 'new-envelope' `
                    -SetStrictAclScript $setAcl `
                    -FaultStage BeforeReplace } | Should Throw

            [IO.File]::ReadAllText($statePath) | Should Be 'old-valid-envelope'
            @(Get-ChildItem -LiteralPath $stateRoot -Force).Count | Should Be 1
            $aclPaths.Count | Should Be 2
        }
    }
}

Describe 'CommMonitor ownership capability module epochs' {
    It 'invalidates a capability created by the previous module instance' {
        $oldCapability = New-CommMonitorWindowsOwnershipProbeCapability
        Remove-Module CommMonitor.InstallHelpers -Force
        Import-Module $modulePath -Force

        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorAuthorizedUser `
                    -AuthorizedUserSid 'S-1-5-21-111-222-333-1001' `
                    -OwnershipProbeCapability $oldCapability `
                    -AiRelativePath 'LemonSerialMonitor\AI' } `
            -MessagePattern 'registered ownership-probe capability is required'
    }

    It 'invalidates a binding created by the previous module instance' {
        $oldBinding = New-CommMonitorTestAuthorizedUserBinding
        Remove-Module CommMonitor.InstallHelpers -Force
        Import-Module $modulePath -Force

        Assert-CommMonitorTestThrowsLike `
            -Action { Resolve-CommMonitorOwnershipRoots `
                    -PlatformKind Desktop -PlatformBuild 22631 `
                    -PlatformComponents @('WPF', 'Service', 'Driver', 'AI', 'StartMenuShortcut') `
                    -ProgramFilesPath 'C:\Program Files' `
                    -ProgramDataPath 'C:\ProgramData' `
                    -AuthorizedUserBinding $oldBinding } `
            -MessagePattern 'not produced by the trusted resolver in this session'
    }

    It 'accepts fresh capabilities in the clean reloaded module instance' {
        $capability = New-CommMonitorWindowsOwnershipProbeCapability
        $module = Get-Module CommMonitor.InstallHelpers
        $registered = & $module {
            param($candidate)
            $null -ne (Get-CommMonitorOwnershipProbeCapabilityRecord `
                    -Capability $candidate)
        } $capability

        $registered | Should Be $true
    }
}
