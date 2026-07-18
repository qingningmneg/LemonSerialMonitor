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
$installerSourceFileName = $productName + '-' + $installerWord + '-x64.exe'
$manualSourceFileName = $productName + '-' + $manualWords + '.pdf'
$installerPublicFileName = 'LemonSerialMonitor-Setup-x64.exe'
$manualPublicFileName = 'LemonSerialMonitor-User-Manual-zh-CN.pdf'

function Get-ReleaseScriptAst {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $releaseScriptPath,
        [ref]$tokens,
        [ref]$errors)
    @($errors).Count | Should Be 0
    return $ast
}

function Get-ReleaseArrayAssignments {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.ScriptBlockAst] $Ast,
        [Parameter(Mandatory)][string] $VariableName
    )

    return @($Ast.FindAll({
                param($node)
                $node -is
                    [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Operator -eq
                    [Management.Automation.Language.TokenKind]::Equals -and
                $node.Left -is
                    [Management.Automation.Language.VariableExpressionAst] -and
                [string]::Equals(
                    $node.Left.VariablePath.UserPath,
                    $VariableName,
                    [StringComparison]::OrdinalIgnoreCase)
            }, $true))
}

function Get-ReleaseArrayMemberNames {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.AssignmentStatementAst] $Assignment
    )

    return @([regex]::Matches(
            $Assignment.Right.Extent.Text,
            '\$(?<name>[A-Za-z][A-Za-z0-9]*FileName)\b') |
        ForEach-Object { $_.Groups['name'].Value })
}

function Test-AstContainsAssignment {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast] $Container,
        [Parameter(Mandatory)]
        [Management.Automation.Language.AssignmentStatementAst] $Assignment
    )

    return $Assignment.Extent.StartOffset -ge $Container.Extent.StartOffset -and
        $Assignment.Extent.EndOffset -le $Container.Extent.EndOffset
}

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

    It 'allows only the exact six public release assets' {
        if (-not (Test-Path -LiteralPath $releaseScriptPath -PathType Leaf)) {
            return
        }
        $text = Get-Content -Raw -LiteralPath $releaseScriptPath -Encoding UTF8
        foreach ($required in @(
                $installerPublicFileName,
                $manualPublicFileName,
                'RELEASE-NOTES.md',
                'BUILD-INFO.json',
                'LICENSE.txt',
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

        $ast = Get-ReleaseScriptAst
        $assignments = @(Get-ReleaseArrayAssignments `
                -Ast $ast `
                -VariableName 'expectedAssetNames')
        $assignments.Count | Should Be 1
        if ($assignments.Count -eq 1) {
            $members = @(Get-ReleaseArrayMemberNames `
                    -Assignment $assignments[0])
            ($members -join "`n") | Should Be (@(
                    'installerPublicFileName',
                    'manualPublicFileName',
                    'releaseNotesFileName',
                    'buildInfoFileName',
                    'licenseFileName',
                    'manifestFileName') -join "`n")
        }
    }

    It 'separates Chinese build source names from English public asset names' {
        $text = Get-Content -Raw -LiteralPath $releaseScriptPath -Encoding UTF8

        foreach ($required in @(
                '$installerSourceFileName = $productName + ''-'' + $installerWord + ''-x64.exe''',
                '$manualSourceFileName = $productName + ''-'' + $manualWords + ''.pdf''',
                '$installerSourceFileName',
                '$manualSourceFileName',
                '$installerPublicFileName',
                '$manualPublicFileName',
                '$InstallerPath = Join-Path (Join-Path $artifactsRoot ''installer'')',
                '$installerSourceFileName',
                '$ManualPath = Join-Path (Join-Path $artifactsRoot ''manual'')',
                '$manualSourceFileName',
                '-Destination (Join-Path $stagingRoot $installerPublicFileName)',
                '-Destination (Join-Path $stagingRoot $manualPublicFileName)')) {
            if (-not $text.Contains($required)) {
                throw "Release script is missing a source/public name boundary: $required"
            }
        }
    }

    It 'keeps stable README download URLs aligned with the public installer name' {
        foreach ($relativePath in @('README.md', 'README.en.md')) {
            $readmePath = Join-Path $repoRoot $relativePath
            $text = Get-Content -Raw -LiteralPath $readmePath -Encoding UTF8
            $match = [regex]::Match(
                $text,
                'https://github\.com/qingningmneg/LemonSerialMonitor/' +
                    'releases/latest/download/(?<name>[^)\s]+)')

            $match.Success | Should Be $true
            $match.Groups['name'].Value | Should Be $installerPublicFileName
        }
    }

    It 'documents exact public asset names while retaining Chinese build sources' {
        $expectedAssets = [string[]]@(
            $installerPublicFileName,
            $manualPublicFileName,
            'RELEASE-NOTES.md',
            'BUILD-INFO.json',
            'LICENSE.txt',
            'SHA256SUMS.txt')
        foreach ($relativePath in @(
                'docs/BUILD.md',
                'docs/BUILD.en.md',
                'docs/RELEASE_NOTES_0.1.1.md',
                'docs/RELEASE_NOTES_0.1.1.en.md')) {
            $text = Get-Content -Raw `
                -LiteralPath (Join-Path $repoRoot $relativePath) `
                -Encoding UTF8
            foreach ($assetName in $expectedAssets) {
                if (-not $text.Contains($assetName)) {
                    throw "$relativePath does not document public asset: $assetName"
                }
            }
        }

        foreach ($relativePath in @(
                'docs/RELEASE_NOTES_0.1.1.md',
                'docs/RELEASE_NOTES_0.1.1.en.md')) {
            $text = Get-Content -Raw `
                -LiteralPath (Join-Path $repoRoot $relativePath) `
                -Encoding UTF8
            $text.Contains($installerSourceFileName) | Should Be $false
            $text.Contains($manualSourceFileName) | Should Be $false
        }

        $installerSourcePublicListPattern = '(?m)^\s*\d+\.\s+`' +
            [regex]::Escape($installerSourceFileName) + '`\s*$'
        $manualSourcePublicListPattern = '(?m)^\s*\d+\.\s+`' +
            [regex]::Escape($manualSourceFileName) + '`\s*$'

        foreach ($relativePath in @('docs/BUILD.md', 'docs/BUILD.en.md')) {
            $text = Get-Content -Raw `
                -LiteralPath (Join-Path $repoRoot $relativePath) `
                -Encoding UTF8
            $text.Contains("artifacts\installer\$installerSourceFileName") |
                Should Be $true
            $text.Contains("artifacts\manual\$manualSourceFileName") |
                Should Be $true
            $text | Should Not Match $installerSourcePublicListPattern
            $text | Should Not Match $manualSourcePublicListPattern
        }
    }

    It 'uses the ordinary root LICENSE as the byte-for-byte create input' {
        $text = Get-Content -Raw -LiteralPath $releaseScriptPath -Encoding UTF8
        foreach ($required in @(
                '[string] $LicensePath',
                '$LicensePath = Join-Path $repoRoot ''LICENSE''',
                '$licenseSource = Assert-LemonOrdinaryFile',
                '-LiteralPath ([IO.Path]::GetFullPath($LicensePath))',
                "-Role 'Project MIT license source'",
                'Copy-Item -LiteralPath $licenseSource.FullName',
                '-Destination (Join-Path $stagingRoot $licenseFileName)')) {
            $text.Contains($required) | Should Be $true
        }
    }

    It 'validates source and staged release licenses as UTF-8 MIT text' {
        $text = Get-Content -Raw -LiteralPath $releaseScriptPath -Encoding UTF8
        foreach ($required in @(
                'function Assert-LemonMitLicense',
                '[IO.File]::ReadAllText',
                '[Text.Encoding]::UTF8',
                'MIT License',
                'Copyright (c) 2026 qingningmneg',
                'The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.',
                'Assert-LemonMitLicense -LiteralPath $licenseSource.FullName',
                '$releaseLicense = Assert-LemonOrdinaryFile',
                '-LiteralPath (Join-Path $RootPath $licenseFileName)',
                'Assert-LemonMitLicense -LiteralPath $releaseLicense.FullName')) {
            $text.Contains($required) | Should Be $true
        }
    }

    It 'hashes exactly five assets including LICENSE in verify and create paths' {
        $ast = Get-ReleaseScriptAst
        $assignments = @(Get-ReleaseArrayAssignments `
                -Ast $ast `
                -VariableName 'hashedAssetNames')
        $assignments.Count | Should Be 2
        foreach ($assignment in $assignments) {
            $members = @(Get-ReleaseArrayMemberNames -Assignment $assignment)
            ($members -join "`n") | Should Be (@(
                    'installerPublicFileName',
                    'manualPublicFileName',
                    'releaseNotesFileName',
                    'buildInfoFileName',
                    'licenseFileName') -join "`n")
        }

        $verifier = @($ast.FindAll({
                    param($node)
                    $node -is
                        [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Test-LemonReleaseBundle'
                }, $true))
        $createPath = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses.Count -gt 0 -and
                    $node.Clauses[0].Item1.Extent.Text -eq '$Create'
                }, $true))
        $verifier.Count | Should Be 1
        $createPath.Count | Should Be 1
        if ($assignments.Count -eq 2 -and
            $verifier.Count -eq 1 -and
            $createPath.Count -eq 1) {
            @($assignments | Where-Object {
                    Test-AstContainsAssignment `
                        -Container $verifier[0] `
                        -Assignment $_
                }).Count | Should Be 1
            @($assignments | Where-Object {
                    Test-AstContainsAssignment `
                        -Container $createPath[0] `
                        -Assignment $_
                }).Count | Should Be 1
        }

        $text = Get-Content -Raw -LiteralPath $releaseScriptPath -Encoding UTF8
        $text.Contains(
            'SHA256SUMS.txt does not list exactly the five hashed assets.') |
            Should Be $true
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
