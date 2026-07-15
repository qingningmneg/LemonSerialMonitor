Set-StrictMode -Version Latest

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installPath = Join-Path $root 'scripts\Install-CommMonitor.ps1'
$uninstallPath = Join-Path $root 'scripts\Uninstall-CommMonitor.ps1'
$statusPath = Join-Path $root 'scripts\Get-CommMonitorStatus.ps1'

function Get-TestScriptAst {
    param([Parameter(Mandatory)][string] $Path)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors)
    @($errors).Count | Should Be 0
    return $ast
}

function Get-TestParameterNames {
    param([Parameter(Mandatory)][string] $Path)

    $ast = Get-TestScriptAst -Path $Path
    return @($ast.ParamBlock.Parameters | ForEach-Object {
            $_.Name.VariablePath.UserPath
        })
}

Describe 'Lemon graphical setup script contracts' {
    It 'exposes the exact transactional install bridge parameters' {
        $names = Get-TestParameterNames -Path $installPath
        foreach ($required in @(
                'PackageRoot', 'AppRoot', 'AuthorizedUserSid',
                'ResultPath', 'Mode', 'AcceptTestCertificate')) {
            $names | Should Contain $required
        }
        $names | Should Not Contain 'InstallRoot'
        $names | Should Not Contain 'ImportTestCertificate'
        $names | Should Not Contain 'ReplaceBackup'
    }

    It 'exposes the exact protected uninstall continuation parameters' {
        $names = Get-TestParameterNames -Path $uninstallPath
        foreach ($required in @('InstallId', 'ResultPath', 'Resume')) {
            $names | Should Contain $required
        }
        $names | Should Not Contain 'KeepFiles'
        $names | Should Not Contain 'RestoreBackup'
    }

    It 'uses checked transaction execution and never best-effort native deletion' {
        $install = Get-Content -Raw -LiteralPath $installPath -Encoding UTF8
        $uninstall = Get-Content -Raw -LiteralPath $uninstallPath -Encoding UTF8
        $install | Should Match 'Lemon\.SetupTransactions\.psm1'
        $uninstall | Should Match 'Lemon\.SetupTransactions\.psm1'
        $install | Should Match 'Invoke-LemonCheckedNativeCommand'
        $uninstall | Should Match 'Invoke-LemonCheckedNativeCommand'
        $uninstall | Should Not Match 'BestEffort'
        $uninstall | Should Not Match 'MoveFileEx'
    }

    It 'counts residual IDs safely when PowerShell unwraps a single-item array' {
        $uninstall = Get-Content -Raw -LiteralPath $uninstallPath -Encoding UTF8

        $uninstall | Should Match '@\(\$firstAssessment\.ResidualObjectIds\)\.Count'
        $uninstall | Should Not Match '(?m)^\s*if \(\$firstAssessment\.ResidualObjectIds\.Count'
    }

    It 'preserves an empty UpperFilters snapshot as a raw string array' {
        $uninstall = Get-Content -Raw -LiteralPath $uninstallPath -Encoding UTF8

        $uninstall | Should Match 'UpperFilterValues\s*=\s*\[string\[\]\]@\(\$filters\)'
        $uninstall | Should Match 'if \(@\(\$Values\)\.Count -eq 0\)'
        $uninstall | Should Match '\$filtersAfter\s*=\s*\[string\[\]\]\(Get-LemonUpperFiltersAfterUninstall'
        $uninstall | Should Not Match '\$filtersAfter\s*=\s*\[string\[\]\]@\('
        $uninstall | Should Not Match 'if \(\$Values\.Count -eq 0\)'
    }

    It 'protects every native-helper state boundary with explicit ACLs' {
        $install = Get-Content -Raw -LiteralPath $installPath -Encoding UTF8
        $uninstall = Get-Content -Raw -LiteralPath $uninstallPath -Encoding UTF8

        $install | Should Match 'Set-LemonProtectedStateAcl\s+-Path \(Join-Path \$InstallerRoot ''state''\)'
        $install | Should Match 'Set-LemonProtectedStateAcl\s+-Path \(Join-Path \$InstallerRoot ''state\\results''\)'
        $install | Should Match 'Set-LemonProtectedStateAcl\s+-Path \$statePath'
        $uninstall | Should Match 'function Set-LemonProtectedStateAcl'
        $uninstall | Should Match 'Set-LemonProtectedStateAcl\s+-Path \$workPath'
        $uninstall | Should Match 'Set-LemonProtectedStateAcl\s+-Path \$resultDirectory'
    }

    It 'automatically imports the disclosed test certificate after explicit acceptance' {
        $install = Get-Content -Raw -LiteralPath $installPath -Encoding UTF8
        $install | Should Match 'AcceptTestCertificate'
        $install | Should Match 'Cert:\\LocalMachine\\Root'
        $install | Should Match 'Cert:\\LocalMachine\\TrustedPublisher'
        $install | Should Match 'Import-Certificate'
    }

    It 'migrates only an authenticated protected manual installation' {
        $install = Get-Content -Raw -LiteralPath $installPath -Encoding UTF8
        $inno = Get-Content -Raw -LiteralPath (
            Join-Path $root 'installer\LemonSerialMonitor.iss') -Encoding UTF8

        $install | Should Not Match 'Migration requires an authenticated prior installation state; none was supplied'
        $install | Should Match 'Get-LemonAuthenticatedMigrationState'
        $install | Should Match 'Test-CommMonitorInstallMarker'
        $install | Should Match 'ConvertFrom-CommMonitorInstallBackupJson'
        $install | Should Match 'Test-CommMonitorServiceImagePath'
        $install | Should Match 'Test-CommMonitorDriverPackageRecord'
        $install | Should Match 'migration-backup'
        $install.Contains('-InstallMode $Mode') | Should Be $true
        $inno | Should Match 'DetectInstallMode'
        $inno.Contains("' -Mode ' + InstallMode") | Should Be $true
    }

    It 'installs and cryptographically binds the exact AI client for each platform layout' {
        $install = Get-Content -Raw -LiteralPath $installPath -Encoding UTF8
        $uninstall = Get-Content -Raw -LiteralPath $uninstallPath -Encoding UTF8
        $status = Get-Content -Raw -LiteralPath $statusPath -Encoding UTF8

        $install | Should Match "'ai\\Lemon\.SerialMonitor\.AI\.exe'"
        $install | Should Match 'Join-Path \$resolvedAppRoot ''ai\\Lemon\.SerialMonitor\.AI\.exe'''
        $install | Should Match 'Join-Path \$CoreRoot ''ai\\Lemon\.SerialMonitor\.AI\.exe'''
        $install | Should Match 'AuthorizedClientImagePath'
        $install | Should Match 'AuthorizedClientSha256'
        $install | Should Match 'Storage:ManagedRoot'
        $install | Should Match 'Storage:SessionRoot'
        $install | Should Match 'Storage:ExportRoot'
        $install | Should Match 'InstallSecurity:CoreRootMetadataPath'
        $install | Should Match 'InstallSecurity:AuthorizedUserSid'
        $install | Should Match 'Get-FileHash.*?SHA256'

        $uninstall | Should Match 'AuthorizedClientImagePath'
        $status | Should Match 'AuthorizedClientImagePath'
    }

    It 'installs guides examples and the complete manual on desktop and Server Core' {
        $install = Get-Content -Raw -LiteralPath $installPath -Encoding UTF8
        foreach ($required in @(
                "Join-Path `$resolvedPackageRoot 'docs'",
                "Join-Path `$resolvedPackageRoot 'examples'",
                "Join-Path `$resolvedPackageRoot 'manual'",
                "Join-Path `$resolvedAppRoot 'docs'",
                "Join-Path `$resolvedAppRoot 'examples'",
                "Join-Path `$resolvedAppRoot 'manual'",
                "Join-Path `$CoreRoot 'docs'",
                "Join-Path `$CoreRoot 'examples'",
                "Join-Path `$CoreRoot 'manual'")) {
            $install.Contains($required) | Should Be $true
        }
    }

    It 'emits structured terminal states and uses all product roots' {
        $combined = (Get-Content -Raw -LiteralPath $installPath -Encoding UTF8) +
            (Get-Content -Raw -LiteralPath $uninstallPath -Encoding UTF8) +
            (Get-Content -Raw -LiteralPath $statusPath -Encoding UTF8)
        foreach ($state in @('Completed', 'PendingReboot', 'Failed')) {
            $combined | Should Match $state
        }
        foreach ($rootName in @(
                'AppRoot', 'CoreRoot', 'DataRoot', 'InstallerRoot', 'AiStateRoot')) {
            $combined | Should Match $rootName
        }
    }
}
