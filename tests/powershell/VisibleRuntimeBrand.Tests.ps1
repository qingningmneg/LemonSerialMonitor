$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$legacyToken = 'Comm' + 'Monitor'

Describe 'Lemon user-visible runtime branding' {
    It 'keeps the internal identifier out of service-facing messages' {
        $checks = @(
            @{
                Path = 'src\CommMonitor.Service\Driver\DriverCaptureSource.cs'
                OldPhrase = "The $legacyToken driver"
                NewPhrase = 'The Lemon serial monitor driver'
            },
            @{
                Path = 'src\CommMonitor.Service\Driver\WindowsDriverDevice.cs'
                OldPhrase = "the $legacyToken driver control device"
                NewPhrase = 'the Lemon serial monitor driver control device'
            },
            @{
                Path = 'src\CommMonitor.Service\Driver\NativeMethods.cs'
                OldPhrase = "The $legacyToken driver transport"
                NewPhrase = 'The Lemon serial monitor driver transport'
            },
            @{
                Path = 'src\CommMonitor.Service\Ipc\PipeServer.cs'
                OldPhrase = "The $legacyToken named-pipe server"
                NewPhrase = 'The Lemon serial monitor named-pipe server'
            },
            @{
                Path = 'src\CommMonitor.Service\Ipc\ServiceStorageBoundary.cs'
                OldPhrase = "$legacyToken service storage hardening"
                NewPhrase = 'Lemon serial monitor service storage hardening'
            },
            @{
                Path = 'src\CommMonitor.Service\Program.cs'
                OldPhrase = "`"$legacyToken.Service.Startup`""
                NewPhrase = '"Lemon.SerialMonitor.Service.Startup"'
            }
        )

        foreach ($check in $checks) {
            $text = Get-Content `
                -Raw `
                -LiteralPath (Join-Path $repoRoot $check.Path) `
                -Encoding UTF8
            $text.Contains($check.OldPhrase) | Should Be $false
            $text.Contains($check.NewPhrase) | Should Be $true
        }
    }

    It 'keeps the internal identifier out of installer-facing errors' {
        $installerText = Get-Content `
            -Raw `
            -LiteralPath (Join-Path $repoRoot 'scripts\CommMonitor.InstallHelpers.psm1') `
            -Encoding UTF8
        $signingText = Get-Content `
            -Raw `
            -LiteralPath (Join-Path $repoRoot 'scripts\Test-SignDriver.ps1') `
            -Encoding UTF8

        foreach ($phrases in @(
                @(
                    "Unsupported $legacyToken install backup schema",
                    'Unsupported Lemon serial monitor install backup schema'),
                @(
                    "inside the $legacyToken tree",
                    'inside the Lemon serial monitor tree'),
                @(
                    "$legacyToken installation requires",
                    'Lemon serial monitor installation requires'))) {
            $installerText.Contains($phrases[0]) | Should Be $false
            $installerText.Contains($phrases[1]) | Should Be $true
        }
        $signingText.Contains("selected $legacyToken signing certificate") |
            Should Be $false
        $signingText.Contains('selected Lemon serial monitor signing certificate') |
            Should Be $true
    }
}
