$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$guardPath = Join-Path $repoRoot 'scripts\Test-LemonBrand.ps1'
$workflowPath = Join-Path $repoRoot '.github\workflows\brand-guard.yml'

function Get-ForbiddenBrandForTest {
    $tail = -join ([char[]]@(
            0x4E32,
            0x53E3,
            0x76D1,
            0x63A7,
            0x7CBE,
            0x7075))
    return 'Comm' + 'Monitor ' + $tail
}

Describe 'Lemon visible-brand guard' {
    It 'accepts clean UTF-8 content' {
        $cleanPath = Join-Path $TestDrive 'README.md'
        Set-Content `
            -LiteralPath $cleanPath `
            -Value '# Lemon serial monitor' `
            -Encoding UTF8

        { & $guardPath -RepositoryRoot $TestDrive -Paths @($cleanPath) } |
            Should Not Throw
    }

    It 'rejects the forbidden visible name in UTF-8 content' {
        $badPath = Join-Path $TestDrive 'legacy.md'
        Set-Content `
            -LiteralPath $badPath `
            -Value (Get-ForbiddenBrandForTest) `
            -Encoding UTF8

        { & $guardPath -RepositoryRoot $TestDrive -Paths @($badPath) } |
            Should Throw
    }

    It 'rejects the forbidden visible name in UTF-16 content' {
        $badPath = Join-Path $TestDrive 'legacy-utf16.txt'
        Set-Content `
            -LiteralPath $badPath `
            -Value (Get-ForbiddenBrandForTest) `
            -Encoding Unicode

        { & $guardPath -RepositoryRoot $TestDrive -Paths @($badPath) } |
            Should Throw
    }

    It 'rejects the forbidden visible name in a relative file path' {
        $badDirectory = Join-Path $TestDrive (Get-ForbiddenBrandForTest)
        [void][IO.Directory]::CreateDirectory($badDirectory)
        $cleanPath = Join-Path $badDirectory 'clean.txt'
        Set-Content -LiteralPath $cleanPath -Value 'clean' -Encoding ASCII

        { & $guardPath -RepositoryRoot $TestDrive -Paths @($cleanPath) } |
            Should Throw
    }

    It 'keeps the forbidden literal out of the guard and its tests' {
        $forbidden = Get-ForbiddenBrandForTest
        $guardText = Get-Content -Raw -LiteralPath $guardPath
        $testText = Get-Content -Raw -LiteralPath $PSCommandPath

        $guardText.Contains($forbidden) | Should Be $false
        $testText.Contains($forbidden) | Should Be $false
    }

    It 'uses the repository root when invoked without parameters' {
        $output = & powershell.exe `
            -NoLogo `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $guardPath 2>&1

        $LASTEXITCODE | Should Be 0
        ($output -join [Environment]::NewLine).Contains('BRAND_GUARD_OK=') |
            Should Be $true
    }

    It 'runs the guard for pushes and pull requests on GitHub' {
        $workflowText = Get-Content -Raw -LiteralPath $workflowPath

        $workflowText.Contains('push:') | Should Be $true
        $workflowText.Contains('pull_request:') | Should Be $true
        $workflowText.Contains('scripts/Test-LemonBrand.ps1') | Should Be $true
    }
}
