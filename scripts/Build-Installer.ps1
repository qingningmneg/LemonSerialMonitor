[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [switch] $SkipPayloadBuild,

    [switch] $SkipSigning,

    [string] $TimestampUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredInnoVersion = '6.7.3'
$wingetPackageId = 'JRSoftware.InnoSetup'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$productVersion = '0.1.1'
$releaseNotesPath = Join-Path $repoRoot `
    "docs\RELEASE_NOTES_$productVersion.md"
$payloadRoot = Join-Path $repoRoot 'artifacts\phase1'
$outputRoot = Join-Path $repoRoot 'artifacts\installer'
$innoScript = Join-Path $repoRoot 'installer\LemonSerialMonitor.iss'
$productName = 'Lemon' + (-join ([char[]]@(
            0x4e32, 0x53e3, 0x76d1, 0x63a7)))
$installerWord = -join ([char[]]@(
        0x5b89, 0x88c5, 0x7a0b, 0x5e8f))
# Keep the visible output name Unicode-safe under Windows PowerShell 5.1.
$installerFileName = $productName + '-' + $installerWord + '-x64.exe'
$installerPath = Join-Path $outputRoot $installerFileName

function Get-OfficialInnoCompiler {
    $uninstallKeys = @(
        'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
        'Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
        'Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1')
    $matchingInstall = $null
    foreach ($key in $uninstallKeys) {
        $record = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($null -ne $record -and
            [string]::Equals(
                [string]$record.DisplayVersion,
                $requiredInnoVersion,
                [StringComparison]::Ordinal) -and
            [string]::Equals(
                [string]$record.Publisher,
                'jrsoftware.org',
                [StringComparison]::OrdinalIgnoreCase)) {
            $matchingInstall = $record
            break
        }
    }
    if ($null -eq $matchingInstall) {
        throw ("Official Inno Setup $requiredInnoVersion was not found. " +
            "Install winget package $wingetPackageId at that exact version.")
    }

    $installLocation = [IO.Path]::GetFullPath(
        [string]$matchingInstall.InstallLocation).TrimEnd('\', '/')
    $compilerPath = Join-Path $installLocation 'ISCC.exe'
    if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) {
        throw "The registered Inno compiler is missing: $compilerPath"
    }
    $resolvedCompilerPath = [IO.Path]::GetFullPath($compilerPath)
    if (-not $resolvedCompilerPath.StartsWith(
            $installLocation + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Inno compiler is outside its registered install directory.'
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $resolvedCompilerPath
    if ($signature.Status -ne
            [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch
            '(^|,\s*)O=Pyrsys B\.V\.(,|$)') {
        throw 'The Inno compiler does not have the expected valid Pyrsys B.V. signature.'
    }
    return $resolvedCompilerPath
}

function Add-LemonBuildCertificateToStore {
    param(
        [Parameter(Mandatory)][string] $StoreName,
        [Parameter(Mandatory)]
        [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )

    $store = [Security.Cryptography.X509Certificates.X509Store]::new(
        $StoreName,
        [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    try {
        $store.Open(
            [Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($Certificate)
    }
    finally {
        $store.Dispose()
    }
}

function Remove-LemonBuildCertificateFromStore {
    param(
        [Parameter(Mandatory)][string] $StoreName,
        [Parameter(Mandatory)]
        [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )

    $store = [Security.Cryptography.X509Certificates.X509Store]::new(
        $StoreName,
        [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    try {
        $store.Open(
            [Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Remove($Certificate)
    }
    finally {
        $store.Dispose()
    }
}

function Get-LemonBuildGitValue {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $lines = @(& git -C $repoRoot @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed while preparing the release: $($Arguments -join ' ')"
    }
    return (($lines | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Assert-LemonBuildSourceRevision {
    param([Parameter(Mandatory)][string] $ExpectedRevision)

    $actualRevision = Get-LemonBuildGitValue -Arguments @(
        'rev-parse', '--verify', 'HEAD')
    if ($actualRevision -notmatch '^[0-9A-Fa-f]{40,64}$' -or
        $actualRevision.ToLowerInvariant() -cne
            $ExpectedRevision.ToLowerInvariant()) {
        throw 'The source revision changed during the installer build.'
    }
    $status = Get-LemonBuildGitValue -Arguments @(
        'status', '--porcelain=v1', '--untracked-files=all')
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw "The installer release source tree is not clean:`n$status"
    }
}

if (-not (Test-Path -LiteralPath $innoScript -PathType Leaf)) {
    throw "Inno installer source was not found: $innoScript"
}

$expectedSourceRevision = Get-LemonBuildGitValue -Arguments @(
    'rev-parse', '--verify', 'HEAD')
if ($expectedSourceRevision -notmatch '^[0-9A-Fa-f]{40,64}$') {
    throw 'Unable to capture a valid source revision before the installer build.'
}
$expectedSourceRevision = $expectedSourceRevision.ToLowerInvariant()
Assert-LemonBuildSourceRevision -ExpectedRevision $expectedSourceRevision

if (-not $SkipPayloadBuild) {
    & (Join-Path $PSScriptRoot 'Build-All.ps1') `
        -Configuration $Configuration `
        -TestSignDriver
    if ($LASTEXITCODE -ne 0) {
        throw "Build-All.ps1 failed with exit code $LASTEXITCODE."
    }
}

$requiredPayload = @(
    'app\Lemon.SerialMonitor.exe',
    'service\CommMonitor.Service.exe',
    'ai\Lemon.SerialMonitor.AI.exe',
    'helper\Lemon.UninstallHelper.exe',
    'driver\CommMonitor.Driver.sys',
    'driver\CommMonitor.Driver.inf',
    'driver\CommMonitor.Driver.cat',
    'driver\CommMonitor.LocalTestDriver.cer',
    'scripts\Install-CommMonitor.ps1',
    'scripts\Uninstall-CommMonitor.ps1',
    'scripts\Resolve-LemonInteractiveUserSid.ps1',
    'docs\LICENSE.txt',
    'docs\third-party\SOURCE.md',
    'docs\third-party\Inno-Setup-Chinese-Simplified-Translation.LICENSE.txt',
    'docs\AI_INTEGRATION.md',
    'docs\AI_API_REFERENCE.md',
    'examples\ai\mcp-config.json',
    'manual\Lemon串口监控-完整操作手册.docx',
    'manual\Lemon串口监控-完整操作手册.pdf',
    'SHA256SUMS.txt')
foreach ($relativePath in $requiredPayload) {
    $path = Join-Path $payloadRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required installer payload is missing: $relativePath"
    }
}

[void][IO.Directory]::CreateDirectory($outputRoot)
$compiler = Get-OfficialInnoCompiler
$compilerLines = @(& $compiler $innoScript 2>&1)
$compilerExitCode = $LASTEXITCODE
$compilerOutput = $compilerLines -join [Environment]::NewLine
$compilerLines | ForEach-Object { Write-Host ([string]$_) }
if ($compilerExitCode -ne 0) {
    throw "ISCC failed with exit code $compilerExitCode."
}
if (-not $compilerOutput.Contains(
        'Compiler engine version: Inno Setup 6.7.3')) {
    throw 'ISCC did not report the pinned compiler engine version.'
}
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "The expected single-file installer was not produced: $installerPath"
}

$releaseBundlePath = $null
if (-not $SkipSigning) {
    $certificatePath = Join-Path $payloadRoot `
        'driver\CommMonitor.LocalTestDriver.cer'
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $certificatePath)
    try {
        $thumbprint = $certificate.Thumbprint
        $rootStorePath = "Cert:\CurrentUser\Root\$thumbprint"
        $publisherStorePath =
            "Cert:\CurrentUser\TrustedPublisher\$thumbprint"
        $rootWasPresent = Test-Path -LiteralPath $rootStorePath
        $publisherWasPresent = Test-Path -LiteralPath $publisherStorePath
        $rootAdded = $false
        $publisherAdded = $false
        try {
            if (-not $rootWasPresent) {
                Add-LemonBuildCertificateToStore `
                    -StoreName Root `
                    -Certificate $certificate
                $rootAdded = $true
            }
            if (-not $publisherWasPresent) {
                Add-LemonBuildCertificateToStore `
                    -StoreName TrustedPublisher `
                    -Certificate $certificate
                $publisherAdded = $true
            }

            & (Join-Path $PSScriptRoot 'Sign-Release.ps1') `
                -FilePath $installerPath `
                -CertificateThumbprint $thumbprint `
                -TimestampUrl $TimestampUrl
            if ($LASTEXITCODE -ne 0) {
                throw "Sign-Release.ps1 failed with exit code $LASTEXITCODE."
            }

            & (Join-Path $PSScriptRoot 'Test-ReleaseBundle.ps1') `
                -Version $productVersion `
                -Create `
                -InstallerPath $installerPath `
                -ManualPath (Join-Path $payloadRoot `
                    'manual\Lemon串口监控-完整操作手册.pdf') `
                -ReleaseNotesPath $releaseNotesPath `
                -InnoCompilerPath $compiler `
                -ExpectedSignerThumbprint $thumbprint `
                -ExpectedSourceRevision $expectedSourceRevision
            if ($LASTEXITCODE -ne 0) {
                throw "Test-ReleaseBundle.ps1 failed with exit code $LASTEXITCODE."
            }
            $releaseBundlePath = Join-Path `
                (Join-Path $repoRoot 'artifacts\release') `
                $productVersion
        }
        finally {
            if ($publisherAdded) {
                Remove-LemonBuildCertificateFromStore `
                    -StoreName TrustedPublisher `
                    -Certificate $certificate
            }
            if ($rootAdded) {
                Remove-LemonBuildCertificateFromStore `
                    -StoreName Root `
                    -Certificate $certificate
            }
        }
    }
    finally {
        $certificate.Dispose()
    }
}

Assert-LemonBuildSourceRevision -ExpectedRevision $expectedSourceRevision
$hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "INNO_COMPILER=$compiler"
Write-Output "INNO_VERSION=$requiredInnoVersion"
Write-Output "INSTALLER=$installerPath"
Write-Output "INSTALLER_SHA256=$hash"
Write-Output "SIGNED=$(-not $SkipSigning)"
if ($null -ne $releaseBundlePath) {
    Write-Output "RELEASE_BUNDLE=$releaseBundlePath"
}
