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
$simplifiedChineseLabel = ConvertFrom-TestCodePoints `
    @(0x7b80, 0x4f53, 0x4e2d, 0x6587)
$releaseNotesWords = ConvertFrom-TestCodePoints `
    @(0x53d1, 0x5e03, 0x8bf4, 0x660e)
$chineseBodyMarker = ConvertFrom-TestCodePoints `
    @(0x4e2d, 0x6587, 0x6b63, 0x6587)
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

function Get-NormalizedAstText {
    param([Parameter(Mandatory)][string] $Text)

    return ([regex]::Replace($Text, '\s+', ' ').Trim()).Replace('` ', '')
}

function Get-SingleReleaseAssignmentRightText {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.ScriptBlockAst] $Ast,
        [Parameter(Mandatory)][string] $VariableName
    )

    $assignments = @(Get-ReleaseArrayAssignments `
            -Ast $Ast `
            -VariableName $VariableName)
    $assignments.Count | Should Be 1
    if ($assignments.Count -ne 1) {
        return ''
    }
    return Get-NormalizedAstText $assignments[0].Right.Extent.Text
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

    It 'rewrites and verifies the exact flat-bundle MIT license link' {
        $ast = Get-ReleaseScriptAst
        $functions = @{}
        foreach ($functionName in @(
                'Convert-LemonReleaseNotesForBundle',
                'Assert-LemonBundleReleaseNotesLicenseLink')) {
            $matches = @($ast.FindAll({
                        param($node)

                        $node -is
                            [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -eq $functionName
                    }, $true))
            $matches.Count | Should Be 1
            if ($matches.Count -ne 1) {
                return
            }
            $functions[$functionName] = $matches[0]
            . ([scriptblock]::Create($matches[0].Extent.Text))
        }

        $utf8NoBomStrict = [Text.UTF8Encoding]::new($false, $true)
        $sourcePath = Join-Path $TestDrive 'source-notes.md'
        $englishSourcePath = Join-Path $TestDrive 'source-notes.en.md'
        $sourceNavigation = "[$simplifiedChineseLabel](source-notes.md) | " +
            '[English](source-notes.en.md)'
        $validChineseSource = "# $productName Notes`n`n" +
            "$sourceNavigation`n`n$chineseBodyMarker`n`n[MIT](../LICENSE)`n"
        $validEnglishSource = "# Lemon Serial Monitor Notes`n`n" +
            "$sourceNavigation`n`nVersion 0.1.1 is ready.`n`n" +
            '[MIT](../LICENSE)' + "`n"
        [IO.File]::WriteAllText(
            $sourcePath,
            $validChineseSource,
            $utf8NoBomStrict)
        [IO.File]::WriteAllText(
            $englishSourcePath,
            $validEnglishSource,
            $utf8NoBomStrict)
        $converted = Convert-LemonReleaseNotesForBundle `
            -LiteralPath $sourcePath `
            -EnglishLiteralPath $englishSourcePath
        [regex]::Matches($converted, '\]\(LICENSE\.txt\)').Count |
            Should Be 2
        $converted.Contains('](../LICENSE)') | Should Be $false

        $bundlePath = Join-Path $TestDrive 'RELEASE-NOTES.md'
        [IO.File]::WriteAllText($bundlePath, $converted, $utf8NoBomStrict)
        { Assert-LemonBundleReleaseNotesLicenseLink -LiteralPath $bundlePath } |
            Should Not Throw

        foreach ($invalidSource in @(
                '# no license link',
                '[one](../LICENSE) [two](../LICENSE)',
                '[already packaged](LICENSE.txt)')) {
            [IO.File]::WriteAllText(
                $sourcePath,
                "# $productName Notes`n`n$sourceNavigation`n`n$invalidSource`n",
                $utf8NoBomStrict)
            { Convert-LemonReleaseNotesForBundle `
                    -LiteralPath $sourcePath `
                    -EnglishLiteralPath $englishSourcePath } | Should Throw
        }
        [IO.File]::WriteAllText(
            $sourcePath,
            $validChineseSource,
            $utf8NoBomStrict)
        [IO.File]::WriteAllText(
            $englishSourcePath,
            "# Lemon Serial Monitor Notes`n`n$sourceNavigation`n`n" +
                "Version 0.1.1 is ready.`n`n# extra title`n`n" +
                '[MIT](../LICENSE)' + "`n",
            $utf8NoBomStrict)
        { Convert-LemonReleaseNotesForBundle `
                -LiteralPath $sourcePath `
                -EnglishLiteralPath $englishSourcePath } | Should Throw
        [IO.File]::WriteAllText(
            $englishSourcePath,
            $validEnglishSource,
            $utf8NoBomStrict)
        foreach ($invalidBundle in @(
                '# no license link',
                '[repository](../LICENSE)',
                '[only one](LICENSE.txt)',
                '[one](LICENSE.txt) [two](LICENSE.txt) [three](LICENSE.txt)')) {
            [IO.File]::WriteAllText($bundlePath, $invalidBundle, $utf8NoBomStrict)
            { Assert-LemonBundleReleaseNotesLicenseLink `
                    -LiteralPath $bundlePath } | Should Throw
        }

        $sourceWithBom = [byte[]](@(0xEF, 0xBB, 0xBF) + @(
                $utf8NoBomStrict.GetBytes('[MIT](../LICENSE)')))
        $bundleWithBom = [byte[]](@(0xEF, 0xBB, 0xBF) + @(
                $utf8NoBomStrict.GetBytes('[MIT](LICENSE.txt)')))
        $invalidUtf8 = [byte[]]@(0xC3, 0x28)
        $utf16Source = [byte[]](@([Text.Encoding]::Unicode.GetPreamble()) + @(
                [Text.Encoding]::Unicode.GetBytes('[MIT](../LICENSE)')))
        $utf16Bundle = [byte[]](@([Text.Encoding]::Unicode.GetPreamble()) + @(
                [Text.Encoding]::Unicode.GetBytes('[MIT](LICENSE.txt)')))
        foreach ($invalidBytes in @(
                $sourceWithBom,
                $invalidUtf8,
                $utf16Source)) {
            [IO.File]::WriteAllBytes($sourcePath, $invalidBytes)
            { Convert-LemonReleaseNotesForBundle `
                    -LiteralPath $sourcePath `
                    -EnglishLiteralPath $englishSourcePath } | Should Throw
        }
        [IO.File]::WriteAllText(
            $sourcePath,
            $validChineseSource,
            $utf8NoBomStrict)
        foreach ($invalidBytes in @(
                $sourceWithBom,
                $invalidUtf8,
                $utf16Source)) {
            [IO.File]::WriteAllBytes($englishSourcePath, $invalidBytes)
            { Convert-LemonReleaseNotesForBundle `
                    -LiteralPath $sourcePath `
                    -EnglishLiteralPath $englishSourcePath } | Should Throw
        }
        foreach ($invalidBytes in @(
                $bundleWithBom,
                $invalidUtf8,
                $utf16Bundle)) {
            [IO.File]::WriteAllBytes($bundlePath, $invalidBytes)
            { Assert-LemonBundleReleaseNotesLicenseLink `
                    -LiteralPath $bundlePath } | Should Throw
        }
    }

    It 'creates and validates release notes through the flat-bundle link contract' {
        $text = Get-Content -Raw -LiteralPath $releaseScriptPath -Encoding UTF8
        foreach ($required in @(
                'Convert-LemonReleaseNotesForBundle `',
                '-LiteralPath $notesSource.FullName',
                '-EnglishLiteralPath $englishNotesSource.FullName',
                'Assert-LemonBundleReleaseNotesLicenseLink `',
                'Assert-LemonBundleReleaseNotesBilingualContent `',
                '-LiteralPath $releaseNotes.FullName')) {
            $text.Contains($required) | Should Be $true
        }
        $text.Contains('Copy-Item -LiteralPath $notesSource.FullName') |
            Should Be $false
        $text | Should Match (
            'Assert-LemonBundleReleaseNotesBilingualContent\s+`?\s*' +
            '-LiteralPath \$releaseNotes\.FullName\s+`?\s*' +
            '-ExpectedVersion \$ExpectedVersion')
    }

    It 'builds one self-contained Chinese and English release-notes asset' {
        $ast = Get-ReleaseScriptAst
        $functions = @{}
        foreach ($functionName in @(
                'Convert-LemonReleaseNotesForBundle',
                'Assert-LemonBundleReleaseNotesLicenseLink',
                'Assert-LemonBundleReleaseNotesBilingualContent')) {
            $matches = @($ast.FindAll({
                        param($node)

                        $node -is
                            [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -eq $functionName
                    }, $true))
            $matches.Count | Should Be 1
            if ($matches.Count -ne 1) {
                return
            }
            $functions[$functionName] = $matches[0]
            . ([scriptblock]::Create($matches[0].Extent.Text))
        }

        $utf8NoBomStrict = [Text.UTF8Encoding]::new($false, $true)
        $chinesePath = Join-Path $TestDrive 'source-notes.md'
        $englishPath = Join-Path $TestDrive 'source-notes.en.md'
        $sourceNavigation = "[$simplifiedChineseLabel](source-notes.md) | " +
            '[English](source-notes.en.md)'
        $chineseText = "# $productName 0.1.1 $releaseNotesWords`n`n" +
            "$sourceNavigation`n`n0.1.1 $chineseBodyMarker`n`n" +
            "## $releaseNotesWords`n`n[MIT](../LICENSE)`n"
        $englishText = "# Lemon Serial Monitor 0.1.1 Release Notes`n`n" +
            "$sourceNavigation`n`n" +
            "Version 0.1.1 is a maintenance update.`n`n" +
            "## What Changed`n`n[MIT](../LICENSE)`n"
        [IO.File]::WriteAllText($chinesePath, $chineseText, $utf8NoBomStrict)
        [IO.File]::WriteAllText($englishPath, $englishText, $utf8NoBomStrict)

        $converted = Convert-LemonReleaseNotesForBundle `
            -LiteralPath $chinesePath `
            -EnglishLiteralPath $englishPath
        $internalNavigation = "[$simplifiedChineseLabel](#zh-cn) | " +
            '[English](#english)'
        $converted.Contains($internalNavigation) | Should Be $true
        $converted.Contains("## $simplifiedChineseLabel") | Should Be $true
        $converted.Contains('## English') | Should Be $true
        $converted.Contains($chineseBodyMarker) | Should Be $true
        $converted.Contains('Version 0.1.1 is a maintenance update.') |
            Should Be $true
        $converted.Contains('source-notes.md') | Should Be $false
        $converted.Contains('source-notes.en.md') | Should Be $false
        [regex]::Matches($converted, '\]\(LICENSE\.txt\)').Count |
            Should Be 2

        $bundlePath = Join-Path $TestDrive 'RELEASE-NOTES.md'
        [IO.File]::WriteAllText($bundlePath, $converted, $utf8NoBomStrict)
        { Assert-LemonBundleReleaseNotesLicenseLink `
                -LiteralPath $bundlePath } | Should Not Throw
        { Assert-LemonBundleReleaseNotesBilingualContent `
                -LiteralPath $bundlePath `
                -ExpectedVersion '0.1.1' } | Should Not Throw

        foreach ($unpackagedLink in @(
                '[unpackaged text](not-in-six-assets.txt)',
                '[unpackaged manual](not-in-six-assets.pdf)',
                "[guide][guide-ref]`n`n[guide-ref]: ../README.md")) {
            [IO.File]::WriteAllText(
                $bundlePath,
                $converted + "`n$unpackagedLink`n",
                $utf8NoBomStrict)
            { Assert-LemonBundleReleaseNotesBilingualContent `
                    -LiteralPath $bundlePath `
                    -ExpectedVersion '0.1.1' } | Should Throw
        }

        $genericTitle = [regex]::Replace(
            $converted,
            '(?m)^# .+$',
            '# Generic release notes',
            1) + "`n$productName / Lemon Serial Monitor`n"
        [IO.File]::WriteAllText(
            $bundlePath,
            $genericTitle,
            $utf8NoBomStrict)
        { Assert-LemonBundleReleaseNotesBilingualContent `
                -LiteralPath $bundlePath `
                -ExpectedVersion '0.1.1' } | Should Throw

        [IO.File]::WriteAllText(
            $bundlePath,
            $converted.Replace('0.1.1', '0.1.0'),
            $utf8NoBomStrict)
        { Assert-LemonBundleReleaseNotesBilingualContent `
                -LiteralPath $bundlePath `
                -ExpectedVersion '0.1.1' } | Should Throw
    }

    It 'binds each build source and public asset role to its exact name' {
        $ast = Get-ReleaseScriptAst
        (Get-SingleReleaseAssignmentRightText `
                -Ast $ast `
                -VariableName 'installerSourceFileName') | Should Be `
            '$productName + ''-'' + $installerWord + ''-x64.exe'''
        (Get-SingleReleaseAssignmentRightText `
                -Ast $ast `
                -VariableName 'manualSourceFileName') | Should Be `
            '$productName + ''-'' + $manualWords + ''.pdf'''
        (Get-SingleReleaseAssignmentRightText `
                -Ast $ast `
                -VariableName 'installerPublicFileName') | Should Be `
            "'LemonSerialMonitor-Setup-x64.exe'"
        (Get-SingleReleaseAssignmentRightText `
                -Ast $ast `
                -VariableName 'manualPublicFileName') | Should Be `
            "'LemonSerialMonitor-User-Manual-zh-CN.pdf'"
    }

    It 'binds installer and manual sources to the matching public destinations' {
        $ast = Get-ReleaseScriptAst
        (Get-SingleReleaseAssignmentRightText `
                -Ast $ast `
                -VariableName 'InstallerPath') | Should Be `
            "Join-Path (Join-Path `$artifactsRoot 'installer') `$installerSourceFileName"
        (Get-SingleReleaseAssignmentRightText `
                -Ast $ast `
                -VariableName 'ManualPath') | Should Be `
            "Join-Path (Join-Path `$artifactsRoot 'manual') `$manualSourceFileName"

        $copyCommands = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Copy-Item'
                }, $true))
        $installerCopy = @($copyCommands | Where-Object {
                $_.Extent.Text.Contains('$installerSource.FullName')
            })
        $manualCopy = @($copyCommands | Where-Object {
                $_.Extent.Text.Contains('$manualSource.FullName')
            })
        $installerCopy.Count | Should Be 1
        $manualCopy.Count | Should Be 1
        if ($installerCopy.Count -eq 1) {
            (Get-NormalizedAstText $installerCopy[0].Extent.Text) |
                Should Match ([regex]::Escape(
                        '-Destination (Join-Path $stagingRoot $installerPublicFileName)'))
        }
        if ($manualCopy.Count -eq 1) {
            (Get-NormalizedAstText $manualCopy[0].Extent.Text) |
                Should Match ([regex]::Escape(
                        '-Destination (Join-Path $stagingRoot $manualPublicFileName)'))
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
            $assetMatches = [regex]::Matches(
                $text,
                '(?m)^\s*(?<index>\d+)\.\s+`(?<name>[^`]+)`\s*$')
            $actualIndexes = @($assetMatches | ForEach-Object {
                    [int]$_.Groups['index'].Value
                })
            $actualAssets = @($assetMatches | ForEach-Object {
                    $_.Groups['name'].Value
                })
            ($actualIndexes -join "`n") | Should Be ((1..6) -join "`n")
            ($actualAssets -join "`n") | Should Be ($expectedAssets -join "`n")
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
        ($createPath.Count -ge 1) | Should Be $true
        if ($assignments.Count -eq 2 -and
            $verifier.Count -eq 1 -and
            $createPath.Count -ge 1) {
            @($assignments | Where-Object {
                    Test-AstContainsAssignment `
                        -Container $verifier[0] `
                        -Assignment $_
                }).Count | Should Be 1
            @($assignments | Where-Object {
                    $assignment = $_
                    @($createPath | Where-Object {
                            Test-AstContainsAssignment `
                                -Container $_ `
                                -Assignment $assignment
                        }).Count -gt 0
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

    It 'binds bundle metadata to an explicitly expected clean source revision' {
        $releaseText = Get-Content -Raw `
            -LiteralPath $releaseScriptPath `
            -Encoding UTF8
        $buildText = Get-Content -Raw `
            -LiteralPath $buildInstallerPath `
            -Encoding UTF8
        foreach ($required in @(
                '[string] $ExpectedSourceRevision',
                'SourceRevision = $ExpectedSourceRevision',
                'SourceTreeDirty = $false',
                '-ExpectedSourceRevision $ExpectedSourceRevision')) {
            $releaseText.Contains($required) | Should Be $true
        }
        foreach ($required in @(
                '$expectedSourceRevision',
                "'rev-parse'",
                "'status'",
                '-ExpectedSourceRevision $expectedSourceRevision')) {
            $buildText.Contains($required) | Should Be $true
        }
        $releaseText.Contains('SourceTreeDirty = -not') | Should Be $false
    }

    It 'requires exact installer product and file versions' {
        $text = Get-Content -Raw -LiteralPath $releaseScriptPath -Encoding UTF8
        $text.Contains('$installerProductVersion -cne $ExpectedVersion') |
            Should Be $true
        $text.Contains('$installerFileVersion -cne ($ExpectedVersion + ''.0'')') |
            Should Be $true
        $text.Contains('$installerProductVersion.StartsWith(') | Should Be $false
    }

    It 'verifies the public LICENSE is byte-identical to the canonical source' {
        $text = Get-Content -Raw -LiteralPath $releaseScriptPath -Encoding UTF8
        foreach ($required in @(
                'ExpectedLicenseSha256',
                'Get-FileHash',
                '$releaseLicenseSha256',
                'Release MIT license is not byte-identical to the canonical project LICENSE.')) {
            $text.Contains($required) | Should Be $true
        }
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
