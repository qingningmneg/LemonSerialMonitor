$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$guardPath = Join-Path $repoRoot 'scripts\Test-BilingualDocs.ps1'
$workflowPath = Join-Path $repoRoot '.github\workflows\brand-guard.yml'
$utf8NoBom = [Text.UTF8Encoding]::new($false)

$docPairs = [ordered]@{
    'README.md' = 'README.en.md'
    'docs/INSTALL.md' = 'docs/INSTALL.en.md'
    'docs/USER_GUIDE.md' = 'docs/USER_GUIDE.en.md'
    'docs/AI_INTEGRATION.md' = 'docs/AI_INTEGRATION.en.md'
    'docs/AI_API_REFERENCE.md' = 'docs/AI_API_REFERENCE.en.md'
    'docs/TROUBLESHOOTING.md' = 'docs/TROUBLESHOOTING.en.md'
    'docs/SECURITY.md' = 'docs/SECURITY.en.md'
    'docs/BUILD.md' = 'docs/BUILD.en.md'
    'docs/RELEASE_NOTES_0.1.0.md' = 'docs/RELEASE_NOTES_0.1.0.en.md'
}

$safetyTerms = @(
    'test certificate',
    'Secure Boot',
    'TESTSIGNING',
    'restart',
    'uninstall',
    'Windows Server',
    'not hardware certification'
)

$installerAssetName = 'LemonSerialMonitor-Setup-x64.exe'
$installerDownloadPaths = @(
    'README.md',
    'README.en.md',
    'docs/INSTALL.md',
    'docs/INSTALL.en.md'
)

function Write-TestUtf8File {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Content
    )

    $parent = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($parent)
    [IO.File]::WriteAllText($Path, $Content, $script:utf8NoBom)
}

function New-BilingualDocsFixture {
    param([Parameter(Mandatory)][string] $Root)

    foreach ($pair in $script:docPairs.GetEnumerator()) {
        $chinesePath = Join-Path $Root $pair.Key
        $englishPath = Join-Path $Root $pair.Value
        $chineseBaseName = [IO.Path]::GetFileName($pair.Key)
        $englishBaseName = [IO.Path]::GetFileName($pair.Value)

        $chineseLines = @(
            '# Chinese fixture',
            "[English]($englishBaseName)"
        )
        if ($script:installerDownloadPaths -contains $pair.Key) {
            $chineseLines += "Download $script:installerAssetName."
        }

        $englishLines = @(
            '# English fixture',
            "[Chinese]($chineseBaseName)"
        )
        if ($script:installerDownloadPaths -contains $pair.Value) {
            $englishLines += "Download $script:installerAssetName."
        }
        if ($pair.Value -eq 'README.en.md') {
            $englishLines += $script:safetyTerms
        }

        Write-TestUtf8File `
            -Path $chinesePath `
            -Content (($chineseLines -join "`n") + "`n")
        Write-TestUtf8File `
            -Path $englishPath `
            -Content (($englishLines -join "`n") + "`n")
    }
}

function Invoke-TestBilingualGuard {
    param([Parameter(Mandatory)][string] $Root)

    if (-not (Test-Path -LiteralPath $script:guardPath -PathType Leaf)) {
        throw "Guard script not found: $script:guardPath"
    }

    return @(& $script:guardPath -RepositoryRoot $Root)
}

function Get-BilingualGuardError {
    param([Parameter(Mandatory)][string] $Root)

    try {
        Invoke-TestBilingualGuard -Root $Root | Out-Null
    } catch {
        return $_.Exception.Message
    }

    return $null
}

$missingRealMirrors = @(
    foreach ($englishRelativePath in $docPairs.Values) {
        if (-not (Test-Path `
                -LiteralPath (Join-Path $repoRoot $englishRelativePath) `
                -PathType Leaf)) {
            $englishRelativePath
        }
    }
)

Describe 'Bilingual documentation guard' {
    It 'accepts all nine complete bilingual document pairs' {
        $root = Join-Path $TestDrive 'complete'
        New-BilingualDocsFixture -Root $root

        $output = Invoke-TestBilingualGuard -Root $root

        ($output -join [Environment]::NewLine) |
            Should Be 'BILINGUAL_DOCS_OK=9'
    }

    It 'rejects a missing English mirror' {
        $root = Join-Path $TestDrive 'missing-mirror'
        New-BilingualDocsFixture -Root $root
        Remove-Item -LiteralPath (Join-Path $root 'README.en.md')

        $message = Get-BilingualGuardError -Root $root

        $message | Should Match 'README\.en\.md'
        $message | Should Match 'not found'
    }

    It 'rejects a Chinese document without its English link' {
        $root = Join-Path $TestDrive 'missing-english-link'
        New-BilingualDocsFixture -Root $root
        Write-TestUtf8File `
            -Path (Join-Path $root 'README.md') `
            -Content "# Chinese fixture`nLemonSerialMonitor-Setup-x64.exe`n"

        $message = Get-BilingualGuardError -Root $root

        $message | Should Match 'README\.md'
        $message | Should Match 'README\.en\.md'
    }

    It 'rejects an English document without its Chinese link' {
        $root = Join-Path $TestDrive 'missing-chinese-link'
        New-BilingualDocsFixture -Root $root
        Write-TestUtf8File `
            -Path (Join-Path $root 'README.en.md') `
            -Content (($safetyTerms -join "`n") + "`n")

        $message = Get-BilingualGuardError -Root $root

        $message | Should Match 'README\.en\.md'
        $message | Should Match 'README\.md'
    }

    It 'rejects invalid UTF-8' {
        $root = Join-Path $TestDrive 'invalid-utf8'
        New-BilingualDocsFixture -Root $root
        [IO.File]::WriteAllBytes(
            (Join-Path $root 'README.en.md'),
            [byte[]](0xC3, 0x28))

        $message = Get-BilingualGuardError -Root $root

        $message | Should Match 'README\.en\.md'
        $message | Should Match 'UTF-8'
    }

    It 'rejects the wrong installer asset name in <RelativePath>' -TestCases @(
        @{ RelativePath = 'README.md' },
        @{ RelativePath = 'README.en.md' },
        @{ RelativePath = 'docs/INSTALL.md' },
        @{ RelativePath = 'docs/INSTALL.en.md' }
    ) {
        param([string] $RelativePath)

        $fixtureName = $RelativePath -replace '[^A-Za-z0-9]', '-'
        $root = Join-Path $TestDrive ('wrong-installer-' + $fixtureName)
        New-BilingualDocsFixture -Root $root
        $documentPath = Join-Path $root $RelativePath
        $document = [IO.File]::ReadAllText($documentPath)
        Write-TestUtf8File `
            -Path $documentPath `
            -Content $document.Replace(
                $installerAssetName,
                'LemonSerialMonitor-Setup.exe')

        $message = Get-BilingualGuardError -Root $root

        $message | Should Match ([regex]::Escape($RelativePath))
        $message | Should Match 'LemonSerialMonitor-Setup-x64\.exe'
    }

    It 'rejects a missing English safety term: <Term>' -TestCases @(
        @{ Term = 'test certificate' },
        @{ Term = 'Secure Boot' },
        @{ Term = 'TESTSIGNING' },
        @{ Term = 'restart' },
        @{ Term = 'uninstall' },
        @{ Term = 'Windows Server' },
        @{ Term = 'not hardware certification' }
    ) {
        param([string] $Term)

        $root = Join-Path $TestDrive ('missing-term-' + ($Term -replace '\W', '-'))
        New-BilingualDocsFixture -Root $root
        $englishReadmePath = Join-Path $root 'README.en.md'
        $englishReadme = [IO.File]::ReadAllText($englishReadmePath)
        Write-TestUtf8File `
            -Path $englishReadmePath `
            -Content $englishReadme.Replace($Term, '[removed safety term]')

        $message = Get-BilingualGuardError -Root $root

        $message | Should Match ([regex]::Escape($Term))
    }

    It 'rejects a placeholder marker: <Marker>' -TestCases @(
        @{ Marker = 'TBD' },
        @{ Marker = 'TODO' },
        @{ Marker = 'FIXME' }
    ) {
        param([string] $Marker)

        $root = Join-Path $TestDrive ('placeholder-' + $Marker)
        New-BilingualDocsFixture -Root $root
        $installPath = Join-Path $root 'docs\INSTALL.en.md'
        $install = [IO.File]::ReadAllText($installPath)
        Write-TestUtf8File `
            -Path $installPath `
            -Content ($install + "`n$Marker`n")

        $message = Get-BilingualGuardError -Root $root

        $message | Should Match $Marker
        $message | Should Match 'docs[\\/]INSTALL\.en\.md'
    }

    It 'uses the parent of scripts as the default repository root' {
        $root = Join-Path $TestDrive 'default-root'
        New-BilingualDocsFixture -Root $root
        $fixtureScripts = Join-Path $root 'scripts'
        [void][IO.Directory]::CreateDirectory($fixtureScripts)
        $fixtureGuard = Join-Path $fixtureScripts 'Test-BilingualDocs.ps1'
        Copy-Item -LiteralPath $guardPath -Destination $fixtureGuard

        $output = @(& $fixtureGuard)

        ($output -join [Environment]::NewLine) |
            Should Be 'BILINGUAL_DOCS_OK=9'
    }

    It 'runs after the visible-brand step in the GitHub workflow' {
        $workflowText = Get-Content -Raw -LiteralPath $workflowPath
        $visibleBrandIndex = $workflowText.IndexOf(
            'run: ./scripts/Test-LemonBrand.ps1',
            [StringComparison]::Ordinal)
        $bilingualIndex = $workflowText.IndexOf(
            '- name: Check bilingual documentation',
            [StringComparison]::Ordinal)

        ($visibleBrandIndex -ge 0) | Should Be $true
        ($bilingualIndex -gt $visibleBrandIndex) | Should Be $true
        $workflowText | Should Match (
            '(?ms)- name: Check bilingual documentation\s+' +
            'shell: pwsh\s+' +
            'run: \./scripts/Test-BilingualDocs\.ps1')
    }

    It 'validates the real repository root once all mirrors exist' `
            -Skip:($missingRealMirrors.Count -ne 0) {
        $output = @(& $guardPath)

        ($output -join [Environment]::NewLine) |
            Should Be 'BILINGUAL_DOCS_OK=9'
    }
}
