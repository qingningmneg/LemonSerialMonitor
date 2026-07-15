$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Describe 'CommMonitor driver signing verification' {
    $signingPath = Join-Path $repoRoot 'scripts\Test-SignDriver.ps1'
    $signingText = Get-Content -Raw -LiteralPath $signingPath

    It 'uses the PnP Authenticode policy for test-signed SYS and CAT verification' {
        ($signingText -match '(?s)''verify'',\s*''/pa''.*?\$sysPath') |
            Should Be $true
        ($signingText -match '(?s)''verify'',\s*''/pa''.*?\$catPath') |
            Should Be $true
    }

    It 'does not apply release-signing kernel policy to a local test certificate' {
        ($signingText -match "(?s)'verify',\s*'/kp'") |
            Should Be $false
    }

    It 'verifies both INF and SYS membership in the generated catalog' {
        $signingText.Contains(
            'foreach ($catalogMember in @($infPath, $sysPath))') |
            Should Be $true
        ($signingText -match '(?s)''verify'',\s*''/pa''.*?''/c'',\s*\$catPath,\s*\$catalogMember') |
            Should Be $true
    }
}

Describe 'Lemon visible Windows metadata' {
    $signingPath = Join-Path $repoRoot 'scripts\Test-SignDriver.ps1'
    $driverInfPath = Join-Path $repoRoot `
        'src\CommMonitor.Driver\CommMonitor.Driver.inx'
    $serviceProgramPath = Join-Path $repoRoot `
        'src\CommMonitor.Service\Program.cs'

    $signingText = Get-Content -Raw -LiteralPath $signingPath
    $driverInfText = Get-Content -Raw -LiteralPath $driverInfPath
    $serviceProgramText = Get-Content -Raw -LiteralPath $serviceProgramPath

    It 'uses the Lemon name in the certificate confirmation dialog' {
        $signingText.Contains(
            "`$subject = 'CN=Lemon Serial Monitor Local Test Driver'") |
            Should Be $true
    }

    It 'uses the Lemon name in driver package descriptions' {
        $driverInfText.Contains(
            'ProviderName = "Lemon Serial Monitor"') |
            Should Be $true
        $driverInfText.Contains(
            'ServiceName = "Lemon Serial Monitor Port Filter"') |
            Should Be $true
        $driverInfText.Contains(
            'DiskName = "Lemon Serial Monitor Driver Installation Media"') |
            Should Be $true
    }

    It 'uses the Lemon name for the Windows service host' {
        $serviceProgramText.Contains(
            'options.ServiceName = "Lemon Serial Monitor Capture Service";') |
            Should Be $true
    }
}

Describe 'Windows PowerShell source encoding' {
    It 'keeps scripts ASCII or marks UTF-8 text with a BOM' {
        $invalidFiles = @()
        foreach ($file in Get-ChildItem -LiteralPath (
                Join-Path $repoRoot 'scripts') -File |
                Where-Object Extension -In @('.ps1', '.psm1')) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $hasNonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
            $hasUtf8Bom = $bytes.Length -ge 3 -and
                $bytes[0] -eq 0xEF -and
                $bytes[1] -eq 0xBB -and
                $bytes[2] -eq 0xBF
            if ($hasNonAscii -and -not $hasUtf8Bom) {
                $invalidFiles += $file.Name
            }
        }

        ($invalidFiles -join ', ') | Should Be ''
    }
}
