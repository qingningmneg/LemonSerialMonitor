Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$releaseScriptPath = Join-Path $repoRoot 'scripts\Test-ReleaseBundle.ps1'
$buildInstallerPath = Join-Path $repoRoot 'scripts\Build-Installer.ps1'
$innoPath = Join-Path $repoRoot 'installer\LemonSerialMonitor.iss'

function ConvertFrom-TestCodePoints {
    param([Parameter(Mandatory)][int[]] $CodePoints)

    return -join @($CodePoints | ForEach-Object { [char]$_ })
}

$productName = 'Lemon' + (ConvertFrom-TestCodePoints `
        @(0x4e32, 0x53e3, 0x76d1, 0x63a7))
$installerWord = ConvertFrom-TestCodePoints `
    @(0x5b89, 0x88c5, 0x7a0b, 0x5e8f)
$manualWords = ConvertFrom-TestCodePoints `
    @(0x5b8c, 0x6574, 0x64cd, 0x4f5c, 0x624b, 0x518c)

Describe 'Lemon release bundle contract' {
    It 'has a parseable strict release verifier' {
        Test-Path -LiteralPath $releaseScriptPath -PathType Leaf |
            Should Be $true
        if (-not (Test-Path -LiteralPath $releaseScriptPath -PathType Leaf)) {
            return
        }

        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $releaseScriptPath,
            [ref]$tokens,
            [ref]$errors)
        @($errors).Count | Should Be 0
    }

    It 'allows only the exact five public release assets' {
        if (-not (Test-Path -LiteralPath $releaseScriptPath -PathType Leaf)) {
            return
        }
        $text = Get-Content -Raw -LiteralPath $releaseScriptPath -Encoding UTF8
        foreach ($required in @(
                ($productName + '-' + $installerWord + '-x64.exe'),
                ($productName + '-' + $manualWords + '.pdf'),
                'RELEASE-NOTES.md',
                'BUILD-INFO.json',
                'SHA256SUMS.txt',
                'Get-AuthenticodeSignature',
                'Get-FileHash',
                'ExpectedSignerThumbprint',
                'SignerCertificate',
                'ProductVersion',
                'InnoSetupVersion',
                'CompilerSignerSubject',
                'TestSigning')) {
            $text.Contains($required) | Should Be $true
        }
        foreach ($forbidden in @('*.pfx', '*.p12', '*.key')) {
            $text.Contains($forbidden) | Should Be $false
        }
    }

    It 'creates the bundle only after the installer is signed' {
        $text = Get-Content -Raw -LiteralPath $buildInstallerPath -Encoding UTF8
        $signIndex = $text.IndexOf("'Sign-Release.ps1'", [StringComparison]::Ordinal)
        $bundleIndex = $text.IndexOf("'Test-ReleaseBundle.ps1'", [StringComparison]::Ordinal)
        ($signIndex -ge 0) | Should Be $true
        ($bundleIndex -gt $signIndex) | Should Be $true
        $text.Contains('-Create') | Should Be $true
        $text.Contains('-ExpectedSignerThumbprint') | Should Be $true
        $text.Contains('-InnoCompilerPath') | Should Be $true
    }

    It 'keeps temporary current-user trust through independent bundle verification' {
        $text = Get-Content -Raw -LiteralPath $buildInstallerPath -Encoding UTF8
        foreach ($required in @(
                'Cert:\CurrentUser\Root',
                'Cert:\CurrentUser\TrustedPublisher',
                'Add-LemonBuildCertificateToStore',
                'Remove-LemonBuildCertificateFromStore',
                '$rootWasPresent',
                '$publisherWasPresent',
                'finally')) {
            $text.Contains($required) | Should Be $true
        }

        $addIndex = $text.IndexOf(
            'Add-LemonBuildCertificateToStore',
            [StringComparison]::Ordinal)
        $signIndex = $text.LastIndexOf(
            "'Sign-Release.ps1'",
            [StringComparison]::Ordinal)
        $bundleIndex = $text.LastIndexOf(
            "'Test-ReleaseBundle.ps1'",
            [StringComparison]::Ordinal)
        $removeIndex = $text.LastIndexOf(
            'Remove-LemonBuildCertificateFromStore',
            [StringComparison]::Ordinal)
        $signIndex | Should BeGreaterThan $addIndex
        $bundleIndex | Should BeGreaterThan $signIndex
        $removeIndex | Should BeGreaterThan $bundleIndex
    }

    It 'normalizes fixed-width installer version resource strings' {
        $text = Get-Content -Raw -LiteralPath $releaseScriptPath -Encoding UTF8
        $text.Contains('([string]$versionInfo.ProductName).Trim()') |
            Should Be $true
        $text.Contains('([string]$versionInfo.ProductVersion).Trim()') |
            Should Be $true
    }

    It 'embeds examples and the verified manual in setup and exposes the manual from Start' {
        $text = Get-Content -Raw -LiteralPath $innoPath -Encoding UTF8
        $text.Contains('Source: "{#PayloadRoot}\examples\*"') | Should Be $true
        $text.Contains('Source: "{#PayloadRoot}\manual\*"') | Should Be $true
        $text.Contains(($productName + '-' + $manualWords + '.pdf')) |
            Should Be $true
        $text.Contains('{commonprograms}') | Should Be $true
    }
}
