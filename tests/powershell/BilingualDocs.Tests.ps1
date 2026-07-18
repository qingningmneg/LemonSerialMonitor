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
    'docs/RELEASE_NOTES_0.1.1.md' = 'docs/RELEASE_NOTES_0.1.1.en.md'
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

function Get-RepositoryDocumentText {
    param([Parameter(Mandatory)][string] $RelativePath)

    return [IO.File]::ReadAllText((Join-Path $script:repoRoot $RelativePath))
}

function Get-RepositoryDocumentLines {
    param([Parameter(Mandatory)][string] $RelativePath)

    $fullPath = Join-Path $script:repoRoot $RelativePath
    (Test-Path -LiteralPath $fullPath -PathType Leaf) | Should Be $true
    return @([IO.File]::ReadAllLines($fullPath))
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
    It 'defines exactly ten pairs including both release-note versions' {
        $docPairs.Count | Should Be 10
        $docPairs['docs/RELEASE_NOTES_0.1.0.md'] |
            Should Be 'docs/RELEASE_NOTES_0.1.0.en.md'
        $docPairs['docs/RELEASE_NOTES_0.1.1.md'] |
            Should Be 'docs/RELEASE_NOTES_0.1.1.en.md'
    }

    It 'accepts all ten complete bilingual document pairs' {
        $root = Join-Path $TestDrive 'complete'
        New-BilingualDocsFixture -Root $root

        $output = Invoke-TestBilingualGuard -Root $root

        ($output -join [Environment]::NewLine) |
            Should Be 'BILINGUAL_DOCS_OK=10'
    }

    It 'rejects a missing English mirror' {
        $root = Join-Path $TestDrive 'missing-mirror'
        New-BilingualDocsFixture -Root $root
        Remove-Item -LiteralPath (Join-Path $root 'README.en.md')

        $message = Get-BilingualGuardError -Root $root

        $message | Should Match 'README\.en\.md'
        $message | Should Match 'not found'
    }

    It 'rejects a missing 0.1.1 English release-note mirror by exact path' {
        $root = Join-Path $TestDrive 'missing-0-1-1-release-note-mirror'
        New-BilingualDocsFixture -Root $root
        Remove-Item -LiteralPath (
            Join-Path $root 'docs\RELEASE_NOTES_0.1.1.en.md')

        $message = Get-BilingualGuardError -Root $root

        $message | Should Match 'docs[\\/]RELEASE_NOTES_0\.1\.1\.en\.md'
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
            Should Be 'BILINGUAL_DOCS_OK=10'
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
            Should Be 'BILINGUAL_DOCS_OK=10'
    }
}

Describe 'Version 0.1.1 bilingual release documentation contract' {
    It 'pins the exact 0.1.1 heading and reciprocal link in <RelativePath>' `
            -TestCases @(
        @{
            RelativePath = 'docs/RELEASE_NOTES_0.1.1.md'
            Heading = '# Lemon串口监控 0.1.1 发布说明'
        },
        @{
            RelativePath = 'docs/RELEASE_NOTES_0.1.1.en.md'
            Heading = '# Lemon Serial Monitor 0.1.1 Release Notes'
        }
    ) {
        param([string] $RelativePath, [string] $Heading)

        $lines = Get-RepositoryDocumentLines -RelativePath $RelativePath

        [string]::Equals($lines[0], $Heading, [StringComparison]::Ordinal) |
            Should Be $true
        [string]::Equals($lines[1], '', [StringComparison]::Ordinal) |
            Should Be $true
        [string]::Equals(
            $lines[2],
            '[简体中文](RELEASE_NOTES_0.1.1.md) | ' +
                '[English](RELEASE_NOTES_0.1.1.en.md)',
            [StringComparison]::Ordinal) | Should Be $true
    }

    It 'declares 0.1.1 current and links matching release notes in <RelativePath>' `
            -TestCases @(
        @{
            RelativePath = 'README.md'
            CurrentPattern = '当前版本为 `0\.1\.1`'
            LinkPattern = '\[0\.1\.1 发布说明\]\(docs/RELEASE_NOTES_0\.1\.1\.md\)'
        },
        @{
            RelativePath = 'README.en.md'
            CurrentPattern = 'The current version is `0\.1\.1`'
            LinkPattern = '\[0\.1\.1 release notes\]\(docs/RELEASE_NOTES_0\.1\.1\.en\.md\)'
        }
    ) {
        param(
            [string] $RelativePath,
            [string] $CurrentPattern,
            [string] $LinkPattern
        )

        $text = Get-RepositoryDocumentText -RelativePath $RelativePath

        $text | Should Match $CurrentPattern
        $text | Should Match $LinkPattern
    }

    It 'labels Windows 11 physical acceptance as historical 0.1.0 evidence in <RelativePath>' `
            -TestCases @(
        @{
            RelativePath = 'README.md'
            HistoricalPattern = '0\.1\.0 历史基线[^\r\n]*Windows 11 x64 实机'
            ForbiddenCurrentPattern = '0\.1\.1[^\r\n]*Windows 11 x64 实机[^\r\n]*(?:完成|验收)'
        },
        @{
            RelativePath = 'README.en.md'
            HistoricalPattern = '0\.1\.0 historical baseline[^\r\n]*physical Windows 11 x64'
            ForbiddenCurrentPattern = '0\.1\.1[^\r\n]*physical Windows 11 x64[^\r\n]*(?:completed|acceptance)'
        }
    ) {
        param(
            [string] $RelativePath,
            [string] $HistoricalPattern,
            [string] $ForbiddenCurrentPattern
        )

        $text = Get-RepositoryDocumentText -RelativePath $RelativePath

        $text | Should Match $HistoricalPattern
        $text | Should Not Match $ForbiddenCurrentPattern
    }

    It 'pins the 0.1.1 six-asset and five-hash build contract in <RelativePath>' `
            -TestCases @(
        @{
            RelativePath = 'docs/BUILD.md'
            SixAssetPattern = '只包含六个可以公开上传的文件'
            FiveHashPattern = 'SHA256SUMS\.txt[^\r\n]*覆盖[^\r\n]*另外五个资产'
        },
        @{
            RelativePath = 'docs/BUILD.en.md'
            SixAssetPattern = 'contains only six files that can be uploaded publicly'
            FiveHashPattern = 'SHA256SUMS\.txt[^\r\n]*covers[^\r\n]*other five assets'
        }
    ) {
        param(
            [string] $RelativePath,
            [string] $SixAssetPattern,
            [string] $FiveHashPattern
        )

        $text = Get-RepositoryDocumentText -RelativePath $RelativePath

        $text | Should Match ([regex]::Escape('artifacts\release\0.1.1'))
        $text | Should Match ([regex]::Escape('-Version 0.1.1'))
        $text | Should Match $SixAssetPattern
        $text | Should Match $FiveHashPattern
    }

    It 'identifies the current 0.1.1 local test-signed release in <RelativePath>' `
            -TestCases @(
        @{
            RelativePath = 'docs/INSTALL.md'
            Pattern = '0\.1\.1 的安装文件使用本地测试签名'
        },
        @{
            RelativePath = 'docs/INSTALL.en.md'
            Pattern = 'The 0\.1\.1 installation files use local test signing'
        },
        @{
            RelativePath = 'docs/SECURITY.md'
            Pattern = '0\.1\.1 使用本地测试证书'
        },
        @{
            RelativePath = 'docs/SECURITY.en.md'
            Pattern = 'Version 0\.1\.1 uses a local test certificate'
        }
    ) {
        param([string] $RelativePath, [string] $Pattern)

        Get-RepositoryDocumentText -RelativePath $RelativePath |
            Should Match $Pattern
    }

    It 'preserves the historical 0.1.0 Server evidence in <RelativePath>' `
            -TestCases @(
        @{
            RelativePath = 'docs/INSTALL.md'
            Pattern = '0\.1\.0 发布前[^\r\n]*没有任何 Server 实机或虚拟机'
        },
        @{
            RelativePath = 'docs/INSTALL.en.md'
            Pattern = 'Before the 0\.1\.0 release[^\r\n]*no physical or virtual Server system'
        }
    ) {
        param([string] $RelativePath, [string] $Pattern)

        Get-RepositoryDocumentText -RelativePath $RelativePath |
            Should Match $Pattern
    }

    It 'pins manual metadata, publication date, and 0.1.1 Server evidence boundary' {
        $builder = Get-RepositoryDocumentText `
            -RelativePath 'scripts/docs/build_commmonitor_manual.py'

        $builder | Should Match (
            [regex]::Escape(
                'doc.core_properties.comments = ' +
                    '"Lemon串口监控 0.1.1 完整操作手册"'))
        $builder | Should Match ([regex]::Escape('"AppVersion": "0.1.1"'))
        $builder | Should Match ([regex]::Escape('WINDOWS 串口被动监控  |  0.1.1'))
        $builder | Should Match ([regex]::Escape('文档版本：0.1.1  |  2026-07-18'))
        $builder | Should Match (
            [regex]::Escape(
                'doc.core_properties.modified = ' +
                    'datetime(2026, 7, 18, tzinfo=timezone.utc)'))
        $builder | Should Match (
            [regex]::Escape('doc.core_properties.revision = 2'))
        $builder | Should Match '0\.1\.1 驱动使用本地测试证书'
        $builder | Should Match '0\.1\.1 不支持在已有新式安装上原地覆盖'
        $builder | Should Match '0\.1\.1[^\r\n]*没有新增[^\r\n]*Server[^\r\n]*驱动[^\r\n]*端到端验收'
    }

    It 'prevents manual table data rows from splitting across pages' {
        $builder = Get-RepositoryDocumentText `
            -RelativePath 'scripts/docs/build_commmonitor_manual.py'

        $builder | Should Match 'def set_cant_split\(row\)'
        $builder | Should Match ([regex]::Escape('OxmlElement("w:cantSplit")'))
        $builder | Should Match ([regex]::Escape('set_cant_split(row)'))
    }

    It 'preserves the exact historical 0.1.0 heading and link in <RelativePath>' `
            -TestCases @(
        @{
            RelativePath = 'docs/RELEASE_NOTES_0.1.0.md'
            Heading = '# Lemon串口监控 0.1.0 发布说明'
        },
        @{
            RelativePath = 'docs/RELEASE_NOTES_0.1.0.en.md'
            Heading = '# Lemon Serial Monitor 0.1.0 Release Notes'
        }
    ) {
        param([string] $RelativePath, [string] $Heading)

        $lines = Get-RepositoryDocumentLines -RelativePath $RelativePath

        [string]::Equals($lines[0], $Heading, [StringComparison]::Ordinal) |
            Should Be $true
        [string]::Equals(
            $lines[2],
            '[简体中文](RELEASE_NOTES_0.1.0.md) | ' +
                '[English](RELEASE_NOTES_0.1.0.en.md)',
            [StringComparison]::Ordinal) | Should Be $true
    }
}
