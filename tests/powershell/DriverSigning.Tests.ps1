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
    $serviceProjectPath = Join-Path $repoRoot `
        'src\CommMonitor.Service\CommMonitor.Service.csproj'
    $coreProjectPath = Join-Path $repoRoot `
        'src\CommMonitor.Core\CommMonitor.Core.csproj'
    $appProjectPath = Join-Path $repoRoot `
        'src\CommMonitor.App\CommMonitor.App.csproj'
    $aiProjectPath = Join-Path $repoRoot `
        'src\Lemon.SerialMonitor.AI\Lemon.SerialMonitor.AI.csproj'
    $helperProjectPath = Join-Path $repoRoot `
        'src\Lemon.UninstallHelper\Lemon.UninstallHelper.csproj'

    $signingText = Get-Content -Raw -LiteralPath $signingPath -Encoding UTF8
    $driverInfText = Get-Content -Raw -LiteralPath $driverInfPath -Encoding UTF8
    $serviceProgramText = Get-Content -Raw -LiteralPath $serviceProgramPath -Encoding UTF8
    $serviceProjectText = Get-Content -Raw -LiteralPath $serviceProjectPath -Encoding UTF8
    $coreProjectText = Get-Content -Raw -LiteralPath $coreProjectPath -Encoding UTF8
    $appProjectText = Get-Content -Raw -LiteralPath $appProjectPath -Encoding UTF8
    $aiProjectText = Get-Content -Raw -LiteralPath $aiProjectPath -Encoding UTF8
    $helperProjectText = Get-Content -Raw -LiteralPath $helperProjectPath -Encoding UTF8
    $publicProductName = 'Lemon' + (-join @(
            [char]0x4E32,
            [char]0x53E3,
            [char]0x76D1,
            [char]0x63A7))
    $serviceProductName = $publicProductName + (-join @(
            [char]0x670D,
            [char]0x52A1))
    $serviceDescription = $publicProductName + (-join @(
            [char]0x540E,
            [char]0x53F0,
            [char]0x670D,
            [char]0x52A1))
    $coreTitle = $publicProductName + (-join @(
            [char]0x6838,
            [char]0x5FC3,
            [char]0x7EC4,
            [char]0x4EF6))
    $aiTitle = $publicProductName + ' AI ' + (-join @(
            [char]0x63A5,
            [char]0x53E3))
    $helperTitle = $publicProductName + (-join @(
            [char]0x5378,
            [char]0x8F7D,
            [char]0x7EC4,
            [char]0x4EF6))

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

    It 'uses Lemon product metadata for the service executable' {
        $serviceProjectText.Contains("<Product>$serviceProductName</Product>") |
            Should Be $true
        $serviceProjectText.Contains("<Title>$serviceProductName</Title>") |
            Should Be $true
        $serviceProjectText.Contains('<Company>Lemon Serial Monitor</Company>') |
            Should Be $true
        $serviceProjectText.Contains("<Description>$serviceDescription</Description>") |
            Should Be $true
    }

    It 'uses Lemon product metadata for every managed Windows component' {
        $coreProjectText.Contains("<Product>$publicProductName</Product>") |
            Should Be $true
        $coreProjectText.Contains("<AssemblyTitle>$coreTitle</AssemblyTitle>") |
            Should Be $true
        $coreProjectText.Contains('<Company>Lemon Serial Monitor</Company>') |
            Should Be $true
        $appProjectText.Contains('<Company>Lemon Serial Monitor</Company>') |
            Should Be $true
        $aiProjectText.Contains("<AssemblyTitle>$aiTitle</AssemblyTitle>") |
            Should Be $true
        $aiProjectText.Contains('<Company>Lemon Serial Monitor</Company>') |
            Should Be $true
        $aiProjectText.Contains('<FileVersion>0.1.0.0</FileVersion>') |
            Should Be $true
        $helperProjectText.Contains("<Product>$helperTitle</Product>") |
            Should Be $true
        $helperProjectText.Contains("<AssemblyTitle>$helperTitle</AssemblyTitle>") |
            Should Be $true
        $helperProjectText.Contains('<Company>Lemon Serial Monitor</Company>') |
            Should Be $true
        $helperProjectText.Contains('<FileVersion>0.1.0.0</FileVersion>') |
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
