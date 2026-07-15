$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'scripts\Lemon.SetupTransactions.psm1'
Import-Module $modulePath -Force

function Assert-LemonThrowsLike {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $MessagePattern
    )

    try {
        & $Action
    }
    catch {
        $_.Exception.Message | Should Match $MessagePattern
        return
    }
    throw 'Expected the action to throw.'
}

Describe 'Lemon checked native execution' {
    It 'escapes embedded quotes in an sc.exe binary path value for Windows PowerShell' {
        $raw = '"C:\Program Files\Lemon\service.exe" "--root=C:\Data Root"'

        ConvertTo-LemonScNativeBinaryPathArgument -Value $raw |
            Should Be '\"C:\Program Files\Lemon\service.exe\" \"--root=C:\Data Root\"'
    }

    It 'rejects line breaks in an sc.exe binary path value' {
        Assert-LemonThrowsLike -Action {
            ConvertTo-LemonScNativeBinaryPathArgument -Value "C:\service.exe`nstart= disabled"
        } -MessagePattern 'line break'
    }

    It 'accepts only declared success and reboot exit codes' {
        $completed = Invoke-LemonCheckedNativeCommand `
            -FilePath 'tool.exe' `
            -ArgumentList @('one', 'two') `
            -SuccessExitCodes @(0, 3010) `
            -RebootExitCodes @(3010) `
            -NativeInvoker {
                [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }
        $pending = Invoke-LemonCheckedNativeCommand `
            -FilePath 'tool.exe' `
            -ArgumentList @('one') `
            -SuccessExitCodes @(0, 3010) `
            -RebootExitCodes @(3010) `
            -NativeInvoker {
                [pscustomobject]@{ ExitCode = 3010; Output = 'restart' }
            }

        $completed.Status | Should Be 'Completed'
        $completed.ExitCode | Should Be 0
        $pending.Status | Should Be 'PendingReboot'
        $pending.ExitCode | Should Be 3010
    }

    It 'throws instead of masking an unexpected native failure' {
        Assert-LemonThrowsLike -Action { Invoke-LemonCheckedNativeCommand `
                -FilePath 'tool.exe' `
                -ArgumentList @('/dangerous') `
                -SuccessExitCodes @(0, 3010) `
                -RebootExitCodes @(3010) `
                -NativeInvoker {
                    [pscustomobject]@{ ExitCode = 5; Output = 'access denied' }
                } } -MessagePattern 'exit code 5'
    }

    It 'rejects reboot codes that are not also success codes' {
        Assert-LemonThrowsLike -Action { Invoke-LemonCheckedNativeCommand `
                -FilePath 'tool.exe' `
                -ArgumentList @() `
                -SuccessExitCodes @(0) `
                -RebootExitCodes @(3010) `
                -NativeInvoker {
                    [pscustomobject]@{ ExitCode = 0; Output = '' }
                } } -MessagePattern 'subset'
    }
}

Describe 'Lemon mutation transaction' {
    It 'rolls back the failed step and every completed step in exact reverse order' {
        $events = [Collections.Generic.List[string]]::new()
        $steps = @(
            [pscustomobject]@{
                Name = 'files'
                Apply = { $events.Add('apply-files'); return 'files-result' }.GetNewClosure()
                Rollback = {
                    param($result, $failure)
                    $events.Add("rollback-files:$result")
                }.GetNewClosure()
            },
            [pscustomobject]@{
                Name = 'service'
                Apply = { $events.Add('apply-service'); throw 'service failed' }.GetNewClosure()
                Rollback = {
                    param($result, $failure)
                    $events.Add('rollback-service')
                }.GetNewClosure()
            }
        )

        Assert-LemonThrowsLike `
            -Action { Invoke-LemonMutationTransaction -Steps $steps } `
            -MessagePattern 'service failed'
        ($events -join '|') |
            Should Be 'apply-files|apply-service|rollback-service|rollback-files:files-result'
    }

    It 'returns ordered apply results when every step succeeds' {
        $steps = @(
            [pscustomobject]@{
                Name = 'one'
                Apply = { return 11 }
                Rollback = { param($result, $failure) }
            },
            [pscustomobject]@{
                Name = 'two'
                Apply = { return 22 }
                Rollback = { param($result, $failure) }
            }
        )

        $result = Invoke-LemonMutationTransaction -Steps $steps

        (@($result.StepResults.Name) -join '|') | Should Be 'one|two'
        (@($result.StepResults.Result) -join '|') | Should Be '11|22'
    }

    It 'reports rollback failures without replacing the original failure' {
        $steps = @(
            [pscustomobject]@{
                Name = 'one'
                Apply = { return 'changed' }
                Rollback = { param($result, $failure); throw 'rollback failed' }
            },
            [pscustomobject]@{
                Name = 'two'
                Apply = { throw 'original failed' }
                Rollback = { param($result, $failure) }
            }
        )

        Assert-LemonThrowsLike `
            -Action { Invoke-LemonMutationTransaction -Steps $steps } `
            -MessagePattern 'original failed.*rollback failures.*one'
    }
}

Describe 'Lemon exact UpperFilters uninstall difference' {
    It 'removes every exact case-insensitive product entry and preserves all other order' {
        $before = @('VendorA', 'commmonitorfilter', 'VendorB', 'CommMonitorFilter')

        $after = Get-LemonUpperFiltersAfterUninstall `
            -Values $before `
            -Entry 'CommMonitorFilter'

        ($after -join '|') | Should Be 'VendorA|VendorB'
        Test-LemonUpperFiltersRemoval `
            -Before $before `
            -After $after `
            -Entry 'CommMonitorFilter' | Should Be $true
    }

    It 'rejects reordered removed or injected non-product entries' {
        $before = @('VendorA', 'CommMonitorFilter', 'VendorB')

        Test-LemonUpperFiltersRemoval `
            -Before $before `
            -After @('VendorB', 'VendorA') `
            -Entry 'CommMonitorFilter' | Should Be $false
        Test-LemonUpperFiltersRemoval `
            -Before $before `
            -After @('VendorA', 'VendorB', 'Injected') `
            -Entry 'CommMonitorFilter' | Should Be $false
    }

    It 'verifies removal when the missing registry value is represented as null' {
        $before = @('CommMonitorFilter')
        $after = Get-LemonUpperFiltersAfterUninstall `
            -Values $before `
            -Entry 'CommMonitorFilter'

        @($after).Count | Should Be 0
        Test-LemonUpperFiltersRemoval `
            -Before $before `
            -After $null `
            -Entry 'CommMonitorFilter' | Should Be $true
    }

    It 'treats an already-missing registry value as an idempotent retry' {
        Test-LemonUpperFiltersRemoval `
            -Before $null `
            -After $null `
            -Entry 'CommMonitorFilter' | Should Be $true
    }
}

Describe 'Lemon empty owned directory cleanup' {
    It 'removes an empty ordinary directory after validating its identity' {
        $path = Join-Path $TestDrive 'empty-ai-parent'
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $validated = [Collections.Generic.List[string]]::new()

        $result = Invoke-LemonEmptyDirectoryCleanup `
            -Path $path `
            -TrustValidator {
                param($candidate)
                $validated.Add([string]$candidate)
            }

        $result | Should Be 'Removed'
        $validated.Count | Should Be 1
        Test-Path -LiteralPath $path | Should Be $false
    }

    It 'preserves a non-empty directory and reports it as not empty' {
        $path = Join-Path $TestDrive 'non-empty-ai-parent'
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $path 'unknown.txt') -Value 'keep'

        $result = Invoke-LemonEmptyDirectoryCleanup `
            -Path $path `
            -TrustValidator { param($candidate) }

        $result | Should Be 'NotEmpty'
        Test-Path -LiteralPath (Join-Path $path 'unknown.txt') |
            Should Be $true
    }

    It 'treats an already-absent directory as an idempotent success' {
        $path = Join-Path $TestDrive 'absent-ai-parent'

        Invoke-LemonEmptyDirectoryCleanup `
            -Path $path `
            -TrustValidator { param($candidate) } | Should Be 'Absent'
    }

    It 'reports a locked empty directory as pending reboot' {
        $path = Join-Path $TestDrive 'locked-empty-ai-parent'
        New-Item -ItemType Directory -Path $path -Force | Out-Null

        $result = Invoke-LemonEmptyDirectoryCleanup `
            -Path $path `
            -TrustValidator { param($candidate) } `
            -DeleteAction {
                param($candidate)
                throw [IO.IOException]::new('directory is locked')
            }

        $result | Should Be 'PendingReboot'
        Test-Path -LiteralPath $path | Should Be $true
    }

    It 'reclassifies a raced non-empty directory instead of granting reboot authority' {
        $path = Join-Path $TestDrive 'raced-ai-parent'
        New-Item -ItemType Directory -Path $path -Force | Out-Null

        $result = Invoke-LemonEmptyDirectoryCleanup `
            -Path $path `
            -TrustValidator { param($candidate) } `
            -DeleteAction {
                param($candidate)
                Set-Content `
                    -LiteralPath (Join-Path $candidate 'unknown.txt') `
                    -Value 'keep'
                throw [IO.IOException]::new('directory changed')
            }

        $result | Should Be 'NotEmpty'
        Test-Path -LiteralPath (Join-Path $path 'unknown.txt') |
            Should Be $true
    }

    It 'does not claim that an access denial will be fixed by reboot' {
        $path = Join-Path $TestDrive 'denied-ai-parent'
        New-Item -ItemType Directory -Path $path -Force | Out-Null

        try {
            Invoke-LemonEmptyDirectoryCleanup `
                -Path $path `
                -TrustValidator { param($candidate) } `
                -DeleteAction {
                    param($candidate)
                    throw [UnauthorizedAccessException]::new('access denied')
                } | Out-Null
        }
        catch {
            $_.Exception.Message | Should Match 'access denied'
            return
        }
        throw 'Expected access denial to fail the cleanup.'
    }
}
