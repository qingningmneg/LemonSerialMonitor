$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'scripts\Lemon.SetupTransactions.psm1'
Import-Module $modulePath -Force

function Assert-LemonResidualThrowsLike {
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

function New-EmptyLemonResidualObservation {
    return [pscustomobject][ordered]@{
        UserServicePresent = $false
        KernelServicePresent = $false
        UpperFilterValues = @('VendorFilter')
        DriverPackagePresent = $false
        OwnedRootCertificatePresent = $false
        OwnedPublisherCertificatePresent = $false
        OwnedEventSourcePresent = $false
        AppRootPresent = $false
        CoreRootPresent = $false
        DataRootPresent = $false
        InstallerNonAuthorityPresent = $false
        AiRootPresent = $false
        AiParentPresent = $false
        StartMenuShortcutPresent = $false
        DesktopShortcutPresent = $false
        UninstallEntryPresent = $false
        ContinuationTaskPresent = $false
        RunEntryPresent = $false
        PendingRenamePresent = $false
        ControlPipePresent = $false
        AiPipePresent = $false
        LegacyPipePresent = $false
        CoexistenceBaselineUnchanged = $true
    }
}

Describe 'Lemon exact residual assessment' {
    It 'reports Completed only when every owned object is absent and coexistence is unchanged' {
        $assessment = Get-LemonResidualAssessment `
            -Observation (New-EmptyLemonResidualObservation) `
            -AllowedPendingObjectIds @()

        $assessment.Status | Should Be 'Completed'
        @($assessment.ResidualObjectIds).Count | Should Be 0
    }

    It 'lists exact residual IDs without treating unrelated filter entries as owned' {
        $observation = New-EmptyLemonResidualObservation
        $observation.UserServicePresent = $true
        $observation.UpperFilterValues = @('VendorA', 'CommMonitorFilter', 'VendorB')
        $observation.AppRootPresent = $true
        $observation.ControlPipePresent = $true
        $observation.CoexistenceBaselineUnchanged = $false

        $assessment = Get-LemonResidualAssessment `
            -Observation $observation `
            -AllowedPendingObjectIds @()

        $assessment.Status | Should Be 'Failed'
        (@($assessment.ResidualObjectIds) -join '|') |
            Should Be 'user-service|upper-filter|app-root|control-pipe|coexistence-baseline'
        @($assessment.ResidualObjectIds) -contains 'VendorA' | Should Be $false
        @($assessment.ResidualObjectIds) -contains 'VendorB' | Should Be $false
    }

    It 'reports the owned AI namespace parent as an exact residual' {
        $observation = New-EmptyLemonResidualObservation
        $observation.AiParentPresent = $true

        $assessment = Get-LemonResidualAssessment `
            -Observation $observation `
            -AllowedPendingObjectIds @()

        $assessment.Status | Should Be 'Failed'
        (@($assessment.ResidualObjectIds) -join '|') | Should Be 'ai-parent'
    }

    It 'reports PendingReboot only when every exact residual has authenticated pending authority' {
        $observation = New-EmptyLemonResidualObservation
        $observation.KernelServicePresent = $true
        $observation.DriverPackagePresent = $true
        $observation.PendingRenamePresent = $true

        $pending = Get-LemonResidualAssessment `
            -Observation $observation `
            -AllowedPendingObjectIds @(
                'kernel-service', 'driver-package', 'pending-file-rename')
        $failed = Get-LemonResidualAssessment `
            -Observation $observation `
            -AllowedPendingObjectIds @('kernel-service')

        $pending.Status | Should Be 'PendingReboot'
        $failed.Status | Should Be 'Failed'
    }

    It 'rejects stale duplicate unknown and case-confused pending authority IDs' {
        $observation = New-EmptyLemonResidualObservation
        $observation.KernelServicePresent = $true

        Assert-LemonResidualThrowsLike -Action {
            Get-LemonResidualAssessment `
                -Observation $observation `
                -AllowedPendingObjectIds @(
                    'kernel-service', 'kernel-service') | Out-Null
        } -MessagePattern 'duplicate'
        Assert-LemonResidualThrowsLike -Action {
            Get-LemonResidualAssessment `
                -Observation $observation `
                -AllowedPendingObjectIds @('Kernel-Service') | Out-Null
        } -MessagePattern 'unknown'
        Assert-LemonResidualThrowsLike -Action {
            Get-LemonResidualAssessment `
                -Observation $observation `
                -AllowedPendingObjectIds @('driver-package') | Out-Null
        } -MessagePattern 'not a current residual'
    }

    It 'rejects missing extra or non-boolean observation fields' {
        $missing = New-EmptyLemonResidualObservation
        $missing.PSObject.Properties.Remove('AppRootPresent')
        $extra = New-EmptyLemonResidualObservation
        $extra | Add-Member NoteProperty Unexpected $false
        $coerced = New-EmptyLemonResidualObservation
        $coerced.AppRootPresent = 'false'

        Assert-LemonResidualThrowsLike -Action {
            Get-LemonResidualAssessment `
                -Observation $missing `
                -AllowedPendingObjectIds @() | Out-Null
        } `
            -MessagePattern 'exact fields'
        Assert-LemonResidualThrowsLike -Action {
            Get-LemonResidualAssessment `
                -Observation $extra `
                -AllowedPendingObjectIds @() | Out-Null
        } `
            -MessagePattern 'exact fields'
        Assert-LemonResidualThrowsLike -Action {
            Get-LemonResidualAssessment `
                -Observation $coerced `
                -AllowedPendingObjectIds @() | Out-Null
        } `
            -MessagePattern 'raw Boolean'
    }
}
