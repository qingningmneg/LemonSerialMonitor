[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version = '0.1.1',

    [switch] $Create,

    [string] $InstallerPath,

    [string] $ManualPath,

    [string] $ReleaseNotesPath,

    [string] $LicensePath,

    [string] $InnoCompilerPath,

    [string] $ExpectedSignerThumbprint,

    [ValidatePattern('^[0-9A-Fa-f]{40,64}$')]
    [string] $ExpectedSourceRevision,

    [string] $OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$artifactsRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'artifacts'))
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $artifactsRoot 'release'
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)

$productName = 'Lemon' + (-join ([char[]]@(
            0x4e32, 0x53e3, 0x76d1, 0x63a7)))
$installerWord = -join ([char[]]@(
        0x5b89, 0x88c5, 0x7a0b, 0x5e8f))
$manualWords = -join ([char[]]@(
        0x5b8c, 0x6574, 0x64cd, 0x4f5c, 0x624b, 0x518c))

# Build-source names remain aligned with the existing installer/manual artifacts.
$installerSourceFileName = $productName + '-' + $installerWord + '-x64.exe'
$manualSourceFileName = $productName + '-' + $manualWords + '.pdf'

# Public asset names are stable ASCII names used by GitHub Release downloads.
$installerPublicFileName = 'LemonSerialMonitor-Setup-x64.exe'
$manualPublicFileName = 'LemonSerialMonitor-User-Manual-zh-CN.pdf'
$releaseNotesFileName = 'RELEASE-NOTES.md'
$buildInfoFileName = 'BUILD-INFO.json'
$licenseFileName = 'LICENSE.txt'
$manifestFileName = 'SHA256SUMS.txt'
$expectedAssetNames = [string[]]@(
    $installerPublicFileName,
    $manualPublicFileName,
    $releaseNotesFileName,
    $buildInfoFileName,
    $licenseFileName,
    $manifestFileName)
$bundleRoot = [IO.Path]::GetFullPath((Join-Path $OutputRoot $Version))

function Write-LemonUtf8NoBom {
    param(
        [Parameter(Mandatory)][string] $LiteralPath,
        [Parameter(Mandatory)][string] $Value
    )

    [IO.File]::WriteAllText(
        $LiteralPath,
        $Value,
        [Text.UTF8Encoding]::new($false))
}

function Get-LemonNormalizedThumbprint {
    param([Parameter(Mandatory)][string] $Thumbprint)

    $normalized = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{40,64}$') {
        throw 'The signer thumbprint is not a valid hexadecimal certificate identity.'
    }
    return $normalized
}

function Assert-LemonOrdinaryFile {
    param(
        [Parameter(Mandatory)][string] $LiteralPath,
        [Parameter(Mandatory)][string] $Role
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "$Role was not found: $LiteralPath"
    }
    $item = Get-Item -LiteralPath $LiteralPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Role must not be a reparse point: $LiteralPath"
    }
    return $item
}

function Assert-LemonMitLicense {
    param(
        [Parameter(Mandatory)][string] $LiteralPath,
        [Parameter(Mandatory)][string] $Role
    )

    $text = [IO.File]::ReadAllText($LiteralPath, [Text.Encoding]::UTF8)
    $normalizedText = [regex]::Replace($text, '\s+', ' ').Trim()
    foreach ($requiredText in @(
            'MIT License',
            'Copyright (c) 2026 qingningmneg',
            'The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.')) {
        if (-not $normalizedText.Contains($requiredText)) {
            throw "$Role does not contain the required MIT notice: $requiredText"
        }
    }
}

function Assert-LemonReleaseChildPath {
    param(
        [Parameter(Mandatory)][string] $ParentPath,
        [Parameter(Mandatory)][string] $ChildPath
    )

    $parent = [IO.Path]::GetFullPath($ParentPath).TrimEnd('\', '/')
    $child = [IO.Path]::GetFullPath($ChildPath).TrimEnd('\', '/')
    if (-not $child.StartsWith(
            $parent + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release path '$child' is outside '$parent'."
    }
}

function Assert-LemonNoReparseTree {
    param([Parameter(Mandatory)][string] $DirectoryPath)

    if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
        throw "Release directory was not found: $DirectoryPath"
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push([IO.Path]::GetFullPath($DirectoryPath))
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $directory = Get-Item -LiteralPath $current -Force
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Release directory contains a reparse point: $current"
        }
        foreach ($entry in Get-ChildItem -LiteralPath $current -Force) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Release directory contains a reparse point: $($entry.FullName)"
            }
            if ($entry.PSIsContainer) {
                $pending.Push($entry.FullName)
            }
        }
    }
}

function Remove-LemonReleaseTree {
    param(
        [Parameter(Mandatory)][string] $ParentPath,
        [Parameter(Mandatory)][string] $TargetPath
    )

    Assert-LemonReleaseChildPath -ParentPath $ParentPath -ChildPath $TargetPath
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        return
    }
    Assert-LemonNoReparseTree -DirectoryPath $TargetPath
    Remove-Item -LiteralPath $TargetPath -Recurse -Force
}

function Get-LemonGitValue {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $lines = @(& git -C $repoRoot @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return (($lines | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Get-LemonRequiredSourceRevision {
    $revision = Get-LemonGitValue -Arguments @(
        'rev-parse', '--verify', 'HEAD')
    if ([string]::IsNullOrWhiteSpace($revision) -or
        $revision -notmatch '^[0-9A-Fa-f]{40,64}$') {
        throw 'Unable to resolve a valid source revision for the release bundle.'
    }
    return $revision.ToLowerInvariant()
}

function Assert-LemonCleanSourceRevision {
    param([Parameter(Mandatory)][string] $ExpectedRevision)

    $actualRevision = Get-LemonRequiredSourceRevision
    if ($actualRevision -cne $ExpectedRevision.ToLowerInvariant()) {
        throw 'The source revision changed during release bundle creation.'
    }
    $status = Get-LemonGitValue -Arguments @(
        'status', '--porcelain=v1', '--untracked-files=all')
    if ($null -eq $status) {
        throw 'Unable to determine whether the release source tree is clean.'
    }
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw "The release source tree is not clean:`n$status"
    }
}

function Test-LemonReleaseBundle {
    param(
        [Parameter(Mandatory)][string] $RootPath,
        [Parameter(Mandatory)][string] $ExpectedVersion,
        [AllowEmptyString()][string] $SignerThumbprint,
        [Parameter(Mandatory)][string] $ExpectedSourceRevision,
        [Parameter(Mandatory)][string] $ExpectedLicenseSha256
    )

    Assert-LemonReleaseChildPath -ParentPath $OutputRoot -ChildPath $RootPath
    Assert-LemonNoReparseTree -DirectoryPath $RootPath

    $entries = @(Get-ChildItem -LiteralPath $RootPath -Force)
    if (@($entries | Where-Object PSIsContainer).Count -ne 0) {
        throw 'The public release bundle must not contain subdirectories.'
    }
    $actualNames = [string[]]@($entries | ForEach-Object Name | Sort-Object)
    $sortedExpected = [string[]]@($expectedAssetNames | Sort-Object)
    if (($actualNames -join "`n") -cne ($sortedExpected -join "`n")) {
        throw "Release assets are not exact. Found: $($actualNames -join ', ')"
    }

    $installer = Assert-LemonOrdinaryFile `
        -LiteralPath (Join-Path $RootPath $installerPublicFileName) `
        -Role 'Installer'
    $manual = Assert-LemonOrdinaryFile `
        -LiteralPath (Join-Path $RootPath $manualPublicFileName) `
        -Role 'PDF manual'
    $releaseNotes = Assert-LemonOrdinaryFile `
        -LiteralPath (Join-Path $RootPath $releaseNotesFileName) `
        -Role 'Release notes'
    $releaseLicense = Assert-LemonOrdinaryFile `
        -LiteralPath (Join-Path $RootPath $licenseFileName) `
        -Role 'Release MIT license'
    Assert-LemonMitLicense -LiteralPath $releaseLicense.FullName `
        -Role 'Release MIT license'
    $releaseLicenseSha256 = (Get-FileHash `
            -LiteralPath $releaseLicense.FullName `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($releaseLicenseSha256 -cne $ExpectedLicenseSha256) {
        throw 'Release MIT license is not byte-identical to the canonical project LICENSE.'
    }
    $buildInfoPath = Join-Path $RootPath $buildInfoFileName
    $manifestPath = Join-Path $RootPath $manifestFileName
    [void](Assert-LemonOrdinaryFile -LiteralPath $buildInfoPath -Role 'Build information')
    [void](Assert-LemonOrdinaryFile -LiteralPath $manifestPath -Role 'SHA-256 manifest')

    if ($installer.Length -lt 1MB) {
        throw 'The installer is unexpectedly small.'
    }
    if ($manual.Length -lt 30KB) {
        throw 'The PDF manual is unexpectedly small.'
    }
    $pdfHeader = [IO.File]::ReadAllBytes($manual.FullName)[0..4]
    if ([Text.Encoding]::ASCII.GetString($pdfHeader) -ne '%PDF-') {
        throw 'The manual does not have a PDF header.'
    }

    $forbiddenPublicName = 'CommMonitor' + ' ' + (-join ([char[]]@(
                0x4e32, 0x53e3, 0x76d1, 0x63a7,
                0x7cbe, 0x7075)))
    $notesText = [IO.File]::ReadAllText($releaseNotes.FullName, [Text.Encoding]::UTF8)
    if ($notesText.Contains($forbiddenPublicName)) {
        throw 'Release notes contain the retired public product name.'
    }
    if (-not $notesText.Contains($productName)) {
        throw 'Release notes do not contain the product name.'
    }

    $buildInfo = [IO.File]::ReadAllText(
        $buildInfoPath,
        [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([int]$buildInfo.SchemaVersion -ne 1 -or
        [string]$buildInfo.ProductName -cne $productName -or
        [string]$buildInfo.ProductVersion -cne $ExpectedVersion -or
        [string]$buildInfo.InnoSetupVersion -cne '6.7.3' -or
        -not [bool]$buildInfo.TestSigning -or
        [string]::IsNullOrWhiteSpace([string]$buildInfo.CompilerSignerSubject)) {
        throw 'BUILD-INFO.json does not describe the expected release.'
    }
    if ([string]$buildInfo.SourceRevision -cne $ExpectedSourceRevision -or
        $null -eq $buildInfo.PSObject.Properties['SourceTreeDirty'] -or
        $buildInfo.SourceTreeDirty -isnot [bool] -or
        [bool]$buildInfo.SourceTreeDirty) {
        throw 'BUILD-INFO.json is not bound to the expected clean source revision.'
    }

    $expectedThumbprint = if (-not [string]::IsNullOrWhiteSpace(
            $SignerThumbprint)) {
        Get-LemonNormalizedThumbprint -Thumbprint $SignerThumbprint
    }
    else {
        Get-LemonNormalizedThumbprint `
            -Thumbprint ([string]$buildInfo.InstallerSignerThumbprint)
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $installer.FullName
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate) {
        throw "Installer Authenticode signature is not valid: $($signature.Status)"
    }
    $actualThumbprint = Get-LemonNormalizedThumbprint `
        -Thumbprint $signature.SignerCertificate.Thumbprint
    if ($actualThumbprint -cne $expectedThumbprint -or
        (Get-LemonNormalizedThumbprint `
            -Thumbprint ([string]$buildInfo.InstallerSignerThumbprint)) -cne
            $expectedThumbprint) {
        throw 'Installer signer thumbprint does not match BUILD-INFO.json.'
    }

    $versionInfo = $installer.VersionInfo
    $installerProductName = ([string]$versionInfo.ProductName).Trim()
    $installerProductVersion = ([string]$versionInfo.ProductVersion).Trim()
    $installerFileVersion = ([string]$versionInfo.FileVersion).Trim()
    if ($installerProductName -cne $productName -or
        $installerProductVersion -cne $ExpectedVersion -or
        $installerFileVersion -cne ($ExpectedVersion + '.0')) {
        throw 'Installer version resources do not match the release.'
    }

    $manifestEntries = [ordered]@{}
    foreach ($line in [IO.File]::ReadAllLines(
            $manifestPath,
            [Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line -notmatch '^(?<hash>[0-9a-f]{64})  (?<name>[^\\/]+)$') {
            throw "Invalid SHA256SUMS.txt line: $line"
        }
        if ($manifestEntries.Contains($Matches.name)) {
            throw "Duplicate SHA-256 entry: $($Matches.name)"
        }
        $manifestEntries[$Matches.name] = $Matches.hash
    }
    $hashedAssetNames = [string[]]@(
        $installerPublicFileName,
        $manualPublicFileName,
        $releaseNotesFileName,
        $buildInfoFileName,
        $licenseFileName)
    if (($manifestEntries.Keys -join "`n") -cne
        (($hashedAssetNames | Sort-Object) -join "`n")) {
        throw 'SHA256SUMS.txt does not list exactly the five hashed assets.'
    }
    foreach ($assetName in $hashedAssetNames) {
        $actualHash = (Get-FileHash `
                -LiteralPath (Join-Path $RootPath $assetName) `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -cne [string]$manifestEntries[$assetName]) {
            throw "SHA-256 mismatch for $assetName"
        }
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Status = 'Verified'
        ProductVersion = $ExpectedVersion
        BundleRoot = [IO.Path]::GetFullPath($RootPath)
        InstallerSha256 = [string]$manifestEntries[$installerPublicFileName]
        InstallerSignerThumbprint = $actualThumbprint
        AssetCount = $expectedAssetNames.Count
    }
}

$artifactsPrefix = $artifactsRoot.TrimEnd('\', '/') +
    [IO.Path]::DirectorySeparatorChar
if (-not $OutputRoot.StartsWith(
        $artifactsPrefix,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "Release output must remain under the repository artifacts root: $OutputRoot"
}

if ([string]::IsNullOrWhiteSpace($LicensePath)) {
    $LicensePath = Join-Path $repoRoot 'LICENSE'
}
$licenseSource = Assert-LemonOrdinaryFile `
    -LiteralPath ([IO.Path]::GetFullPath($LicensePath)) `
    -Role 'Project MIT license source'
Assert-LemonMitLicense -LiteralPath $licenseSource.FullName `
    -Role 'Project MIT license source'
$expectedLicenseSha256 = (Get-FileHash `
        -LiteralPath $licenseSource.FullName `
        -Algorithm SHA256).Hash.ToLowerInvariant()

if ($Create -and [string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    throw 'ExpectedSourceRevision is required when creating a release bundle.'
}
if ([string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    $ExpectedSourceRevision = Get-LemonRequiredSourceRevision
}
$ExpectedSourceRevision = $ExpectedSourceRevision.ToLowerInvariant()
if ($Create) {
    Assert-LemonCleanSourceRevision `
        -ExpectedRevision $ExpectedSourceRevision
}

[void][IO.Directory]::CreateDirectory($artifactsRoot)
[void][IO.Directory]::CreateDirectory($OutputRoot)

if ($Create) {
    if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
        $InstallerPath = Join-Path (Join-Path $artifactsRoot 'installer') `
            $installerSourceFileName
    }
    if ([string]::IsNullOrWhiteSpace($ManualPath)) {
        $ManualPath = Join-Path (Join-Path $artifactsRoot 'manual') `
            $manualSourceFileName
    }
    if ([string]::IsNullOrWhiteSpace($ReleaseNotesPath)) {
        $ReleaseNotesPath = Join-Path $repoRoot `
            "docs\RELEASE_NOTES_$Version.md"
    }
    if ([string]::IsNullOrWhiteSpace($InnoCompilerPath)) {
        throw 'InnoCompilerPath is required when creating a release bundle.'
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedSignerThumbprint)) {
        throw 'ExpectedSignerThumbprint is required when creating a release bundle.'
    }

    $installerSource = Assert-LemonOrdinaryFile `
        -LiteralPath ([IO.Path]::GetFullPath($InstallerPath)) `
        -Role 'Signed installer source'
    $manualSource = Assert-LemonOrdinaryFile `
        -LiteralPath ([IO.Path]::GetFullPath($ManualPath)) `
        -Role 'Verified PDF manual source'
    $notesSource = Assert-LemonOrdinaryFile `
        -LiteralPath ([IO.Path]::GetFullPath($ReleaseNotesPath)) `
        -Role 'Release notes source'
    $compiler = Assert-LemonOrdinaryFile `
        -LiteralPath ([IO.Path]::GetFullPath($InnoCompilerPath)) `
        -Role 'Inno Setup compiler'
    $compilerSignature = Get-AuthenticodeSignature -LiteralPath $compiler.FullName
    if ($compilerSignature.Status -ne
            [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $compilerSignature.SignerCertificate -or
        $compilerSignature.SignerCertificate.Subject -notmatch
            '(^|,\s*)O=Pyrsys B\.V\.(,|$)') {
        throw 'The release compiler does not have the expected valid Pyrsys B.V. signature.'
    }

    $sourceSignature = Get-AuthenticodeSignature -LiteralPath $installerSource.FullName
    $normalizedExpectedThumbprint = Get-LemonNormalizedThumbprint `
        -Thumbprint $ExpectedSignerThumbprint
    if ($sourceSignature.Status -ne
            [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $sourceSignature.SignerCertificate -or
        (Get-LemonNormalizedThumbprint `
            -Thumbprint $sourceSignature.SignerCertificate.Thumbprint) -cne
            $normalizedExpectedThumbprint) {
        throw 'The installer source is not validly signed by the expected certificate.'
    }

    $stagingRoot = Join-Path $OutputRoot (
        '.staging-' + [Guid]::NewGuid().ToString('N'))
    Assert-LemonReleaseChildPath `
        -ParentPath $OutputRoot `
        -ChildPath $stagingRoot
    [void][IO.Directory]::CreateDirectory($stagingRoot)
    try {
        Copy-Item -LiteralPath $installerSource.FullName `
            -Destination (Join-Path $stagingRoot $installerPublicFileName)
        Copy-Item -LiteralPath $manualSource.FullName `
            -Destination (Join-Path $stagingRoot $manualPublicFileName)
        Copy-Item -LiteralPath $notesSource.FullName `
            -Destination (Join-Path $stagingRoot $releaseNotesFileName)
        Copy-Item -LiteralPath $licenseSource.FullName `
            -Destination (Join-Path $stagingRoot $licenseFileName)

        $dotnetVersion = ((@(& dotnet --version 2>$null) |
                    ForEach-Object { [string]$_ }) -join '').Trim()
        $buildInfo = [pscustomobject][ordered]@{
            SchemaVersion = 1
            ProductName = $productName
            ProductVersion = $Version
            RuntimeIdentifier = 'win-x64'
            TestSigning = $true
            GeneratedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            SourceRevision = $ExpectedSourceRevision
            SourceTreeDirty = $false
            DotNetSdkVersion = $dotnetVersion
            InnoSetupVersion = '6.7.3'
            CompilerFileVersion = [string]$compiler.VersionInfo.FileVersion
            CompilerSignerSubject = [string]$compilerSignature.SignerCertificate.Subject
            InstallerSignerThumbprint = $normalizedExpectedThumbprint
            SupportedClients = [string[]]@('Windows 10 x64', 'Windows 11 x64')
            SupportedServers = [string[]]@(
                'Windows Server 2019 x64',
                'Windows Server 2022 x64',
                'Windows Server 2025 x64')
        }
        Write-LemonUtf8NoBom `
            -LiteralPath (Join-Path $stagingRoot $buildInfoFileName) `
            -Value (($buildInfo | ConvertTo-Json -Depth 6) + "`n")

        $hashedAssetNames = [string[]]@(
            $installerPublicFileName,
            $manualPublicFileName,
            $releaseNotesFileName,
            $buildInfoFileName,
            $licenseFileName)
        $manifestLines = @($hashedAssetNames | Sort-Object | ForEach-Object {
                $hash = (Get-FileHash `
                        -LiteralPath (Join-Path $stagingRoot $_) `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                "$hash  $_"
            })
        Write-LemonUtf8NoBom `
            -LiteralPath (Join-Path $stagingRoot $manifestFileName) `
            -Value (($manifestLines -join "`n") + "`n")

        [void](Test-LemonReleaseBundle `
                -RootPath $stagingRoot `
                -ExpectedVersion $Version `
                -SignerThumbprint $normalizedExpectedThumbprint `
                -ExpectedSourceRevision $ExpectedSourceRevision `
                -ExpectedLicenseSha256 $expectedLicenseSha256)
        Assert-LemonCleanSourceRevision `
            -ExpectedRevision $ExpectedSourceRevision
        Remove-LemonReleaseTree `
            -ParentPath $OutputRoot `
            -TargetPath $bundleRoot
        Move-Item -LiteralPath $stagingRoot -Destination $bundleRoot
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-LemonReleaseTree `
                -ParentPath $OutputRoot `
                -TargetPath $stagingRoot
        }
    }
}

$result = Test-LemonReleaseBundle `
    -RootPath $bundleRoot `
    -ExpectedVersion $Version `
    -SignerThumbprint $ExpectedSignerThumbprint `
    -ExpectedSourceRevision $ExpectedSourceRevision `
    -ExpectedLicenseSha256 $expectedLicenseSha256
$result | ConvertTo-Json -Depth 4
