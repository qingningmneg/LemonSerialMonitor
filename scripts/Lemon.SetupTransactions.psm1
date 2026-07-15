Set-StrictMode -Version Latest

function Assert-LemonPayloadManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $PackageRoot
    )

    $root = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Payload root was not found: '$root'."
    }
    $manifestPath = Join-Path $root 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The payload SHA256SUMS.txt file is missing.'
    }

    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    $expected = [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($rawLine in [IO.File]::ReadAllLines(
            $manifestPath,
            [Text.UTF8Encoding]::new($false, $true))) {
        $line = $rawLine.TrimStart([char]0xFEFF)
        $match = [regex]::Match(
            $line,
            '^(?<hash>[0-9A-Fa-f]{64})  (?<path>[^\r\n]+)$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if (-not $match.Success) {
            throw "Invalid SHA256SUMS.txt line: '$line'."
        }
        $relativePath = $match.Groups['path'].Value.Replace(
            '/',
            [IO.Path]::DirectorySeparatorChar)
        if ([IO.Path]::IsPathRooted($relativePath) -or
            $relativePath.StartsWith('\', [StringComparison]::Ordinal) -or
            $relativePath.StartsWith('/', [StringComparison]::Ordinal) -or
            $relativePath.Split([char[]]@('\', '/')) -contains '..' -or
            $relativePath.Split([char[]]@('\', '/')) -contains '.') {
            throw "Unsafe payload manifest path: '$relativePath'."
        }
        $fullPath = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
        if (-not $fullPath.StartsWith(
                $rootPrefix,
                [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals(
                $fullPath,
                $manifestPath,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Payload manifest path escaped its root: '$relativePath'."
        }
        if ($expected.ContainsKey($relativePath)) {
            throw "Duplicate payload manifest path: '$relativePath'."
        }
        $expected.Add(
            $relativePath,
            $match.Groups['hash'].Value.ToLowerInvariant())
    }
    if ($expected.Count -eq 0) {
        throw 'The payload manifest is empty.'
    }

    $actualFiles = @(
        Get-ChildItem -LiteralPath $root -File -Force -Recurse |
            Where-Object {
                -not [string]::Equals(
                    $_.FullName,
                    $manifestPath,
                    [StringComparison]::OrdinalIgnoreCase)
            })
    if ($actualFiles.Count -ne $expected.Count) {
        throw 'The payload file set does not match SHA256SUMS.txt.'
    }
    foreach ($file in $actualFiles) {
        $fullPath = [IO.Path]::GetFullPath($file.FullName)
        if (-not $fullPath.StartsWith(
                $rootPrefix,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Payload file escaped its root: '$fullPath'."
        }
        $relativePath = $fullPath.Substring($rootPrefix.Length)
        if (-not $expected.ContainsKey($relativePath)) {
            throw "Unlisted payload file: '$relativePath'."
        }
        $actualHash = (Get-FileHash `
                -LiteralPath $fullPath `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not [string]::Equals(
                $actualHash,
                $expected[$relativePath],
                [StringComparison]::Ordinal)) {
            throw "Payload SHA-256 mismatch: '$relativePath'."
        }
    }

    return [pscustomobject][ordered]@{
        ManifestPath = $manifestPath
        FileCount = $expected.Count
    }
}

function ConvertTo-LemonScNativeBinaryPathArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Value
    )

    if ($Value.IndexOf([char]0) -ge 0 -or
        $Value.IndexOf([char]10) -ge 0 -or
        $Value.IndexOf([char]13) -ge 0) {
        throw 'The sc.exe binary path value must not contain a null or line break.'
    }

    # Windows PowerShell 5.1 removes unescaped embedded quotes while binding
    # native arguments. sc.exe needs those quotes to preserve paths and service
    # options containing spaces, so escape only the embedded quote characters.
    return $Value.Replace('"', '\"')
}

function Invoke-LemonCheckedNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ArgumentList,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]] $SuccessExitCodes,
        [AllowEmptyCollection()][int[]] $RebootExitCodes = @(),
        [scriptblock] $NativeInvoker
    )

    $success = [Collections.Generic.HashSet[int]]::new()
    foreach ($code in @($SuccessExitCodes)) {
        if (-not $success.Add([int]$code)) {
            throw "Success exit codes contain duplicate value $code."
        }
    }
    if ($success.Count -eq 0) {
        throw 'At least one success exit code is required.'
    }
    $reboot = [Collections.Generic.HashSet[int]]::new()
    foreach ($code in @($RebootExitCodes)) {
        if (-not $success.Contains([int]$code)) {
            throw 'Reboot exit codes must be a subset of success exit codes.'
        }
        if (-not $reboot.Add([int]$code)) {
            throw "Reboot exit codes contain duplicate value $code."
        }
    }

    $nativeResult = if ($null -ne $NativeInvoker) {
        & $NativeInvoker $FilePath ([string[]]$ArgumentList)
    }
    else {
        $nativeOutput = & $FilePath @ArgumentList 2>&1 | Out-String
        [pscustomobject][ordered]@{
            ExitCode = [int]$LASTEXITCODE
            Output = [string]$nativeOutput
        }
    }
    if ($null -eq $nativeResult -or
        $null -eq $nativeResult.PSObject.Properties['ExitCode'] -or
        $null -eq $nativeResult.PSObject.Properties['Output'] -or
        $nativeResult.ExitCode -isnot [int] -or
        $nativeResult.Output -isnot [string]) {
        throw 'Native invoker must return raw ExitCode and Output fields.'
    }

    $exitCode = [int]$nativeResult.ExitCode
    if (-not $success.Contains($exitCode)) {
        throw "Native command '$FilePath' failed with exit code $exitCode. $($nativeResult.Output)"
    }
    return [pscustomobject][ordered]@{
        FilePath = $FilePath
        ArgumentList = [string[]]@($ArgumentList)
        ExitCode = $exitCode
        Output = [string]$nativeResult.Output
        Status = if ($reboot.Contains($exitCode)) {
            'PendingReboot'
        }
        else {
            'Completed'
        }
    }
}

function Invoke-LemonMutationTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Steps
    )

    $attempted = [Collections.Generic.List[object]]::new()
    foreach ($step in @($Steps)) {
        if ($null -eq $step -or
            $null -eq $step.PSObject.Properties['Name'] -or
            $null -eq $step.PSObject.Properties['Apply'] -or
            $null -eq $step.PSObject.Properties['Rollback'] -or
            $step.Name -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$step.Name) -or
            $step.Apply -isnot [scriptblock] -or
            $step.Rollback -isnot [scriptblock]) {
            throw 'Every transaction step requires raw Name, Apply, and Rollback fields.'
        }
        $attempt = [pscustomobject][ordered]@{
            Name = [string]$step.Name
            Apply = [scriptblock]$step.Apply
            Rollback = [scriptblock]$step.Rollback
            Result = $null
        }
        $attempted.Add($attempt)
        try {
            $attempt.Result = & $attempt.Apply
        }
        catch {
            $originalFailure = $_.Exception
            $rollbackFailures = [Collections.Generic.List[string]]::new()
            for ($index = $attempted.Count - 1; $index -ge 0; $index--) {
                $rollbackStep = $attempted[$index]
                try {
                    $null = & $rollbackStep.Rollback `
                        $rollbackStep.Result `
                        $originalFailure
                }
                catch {
                    $rollbackFailures.Add((
                            "{0}: {1}" -f
                                $rollbackStep.Name,
                                $_.Exception.Message))
                }
            }
            $message = "Transaction step '$($attempt.Name)' failed: $($originalFailure.Message)"
            if ($rollbackFailures.Count -ne 0) {
                $message += '; rollback failures: ' +
                    [string]::Join(' | ', $rollbackFailures.ToArray())
            }
            throw [InvalidOperationException]::new($message, $originalFailure)
        }
    }

    $results = @(
        foreach ($attempt in $attempted) {
            [pscustomobject][ordered]@{
                Name = $attempt.Name
                Result = $attempt.Result
            }
        }
    )
    return [pscustomobject][ordered]@{
        Status = 'Completed'
        StepResults = $results
    }
}

function Get-LemonUpperFiltersAfterUninstall {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]] $Values,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Entry
    )

    $result = [Collections.Generic.List[string]]::new()
    foreach ($value in @($Values)) {
        if (-not [string]::Equals(
                [string]$value,
                $Entry,
                [StringComparison]::OrdinalIgnoreCase)) {
            $result.Add([string]$value)
        }
    }
    Write-Output -NoEnumerate ([string[]]$result.ToArray())
}

function Test-LemonUpperFiltersRemoval {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]] $Before,
        [AllowNull()][AllowEmptyCollection()][string[]] $After,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Entry
    )

    $expected = [string[]](Get-LemonUpperFiltersAfterUninstall `
            -Values $Before `
            -Entry $Entry)
    [string[]] $actual = @()
    if ($null -ne $After) {
        $actual = [string[]]@($After)
    }
    if ($expected.Count -ne $actual.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if (-not [string]::Equals(
                $expected[$index],
                $actual[$index],
                [StringComparison]::Ordinal)) {
            return $false
        }
    }
    return $true
}

function Invoke-LemonEmptyDirectoryCleanup {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Path,
        [Parameter(Mandatory)][scriptblock] $TrustValidator,
        [scriptblock] $DeleteAction = {
            param($candidate)
            [IO.Directory]::Delete([string]$candidate, $false)
        }
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return 'Absent'
    }
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (-not [bool]$item.PSIsContainer) {
        throw "Expected an owned directory: '$fullPath'."
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing a reparse-point directory: '$fullPath'."
    }
    [void](& $TrustValidator $fullPath)
    if (@(Get-ChildItem -LiteralPath $fullPath -Force -ErrorAction Stop).Count -ne 0) {
        return 'NotEmpty'
    }
    try {
        [void](& $DeleteAction $fullPath)
    }
    catch [IO.DirectoryNotFoundException] {
        return 'Absent'
    }
    catch [IO.IOException] {
        if (-not (Test-Path -LiteralPath $fullPath)) {
            return 'Absent'
        }
        $afterFailure = Get-Item `
            -LiteralPath $fullPath `
            -Force `
            -ErrorAction Stop
        if (-not [bool]$afterFailure.PSIsContainer -or
            (($afterFailure.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Owned directory identity changed during cleanup: '$fullPath'."
        }
        [void](& $TrustValidator $fullPath)
        if (@(Get-ChildItem `
                    -LiteralPath $fullPath `
                    -Force `
                    -ErrorAction Stop).Count -ne 0) {
            return 'NotEmpty'
        }
        return 'PendingReboot'
    }
    if (Test-Path -LiteralPath $fullPath) {
        return 'PendingReboot'
    }
    return 'Removed'
}

function Get-LemonResidualAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Observation,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]
        $AllowedPendingObjectIds
    )

    $booleanMap = [ordered]@{
        UserServicePresent = 'user-service'
        KernelServicePresent = 'kernel-service'
        DriverPackagePresent = 'driver-package'
        OwnedRootCertificatePresent = 'root-certificate'
        OwnedPublisherCertificatePresent = 'publisher-certificate'
        OwnedEventSourcePresent = 'event-source'
        AppRootPresent = 'app-root'
        CoreRootPresent = 'core-root'
        DataRootPresent = 'data-root'
        InstallerNonAuthorityPresent = 'installer-non-authority'
        AiRootPresent = 'ai-root'
        AiParentPresent = 'ai-parent'
        StartMenuShortcutPresent = 'start-menu-shortcut'
        DesktopShortcutPresent = 'desktop-shortcut'
        UninstallEntryPresent = 'uninstall-entry'
        ContinuationTaskPresent = 'continuation-task'
        RunEntryPresent = 'run-entry'
        PendingRenamePresent = 'pending-file-rename'
        ControlPipePresent = 'control-pipe'
        AiPipePresent = 'ai-pipe'
        LegacyPipePresent = 'legacy-pipe'
    }
    $expectedFields = @($booleanMap.Keys) + @(
        'UpperFilterValues', 'CoexistenceBaselineUnchanged')
    $actualProperties = @($Observation.PSObject.Properties)
    $actualNames = @($actualProperties | ForEach-Object { [string]$_.Name })
    if ($actualNames.Count -ne $expectedFields.Count) {
        throw 'Residual observation must contain the exact fields.'
    }
    foreach ($expectedField in $expectedFields) {
        if ($actualNames -cnotcontains $expectedField) {
            throw 'Residual observation must contain the exact fields.'
        }
    }
    foreach ($actualName in $actualNames) {
        if ($expectedFields -cnotcontains $actualName) {
            throw 'Residual observation must contain the exact fields.'
        }
    }
    foreach ($field in $booleanMap.Keys) {
        if ($Observation.$field -isnot [bool]) {
            throw "Residual observation $field must be a raw Boolean."
        }
    }
    if ($Observation.CoexistenceBaselineUnchanged -isnot [bool]) {
        throw 'Residual observation CoexistenceBaselineUnchanged must be a raw Boolean.'
    }
    if ($Observation.UpperFilterValues -isnot [Array]) {
        throw 'Residual observation UpperFilterValues must be a raw array.'
    }
    foreach ($filterValue in $Observation.UpperFilterValues) {
        if ($filterValue -isnot [string]) {
            throw 'Residual observation UpperFilterValues members must be raw strings.'
        }
    }

    $residuals = [Collections.Generic.List[string]]::new()
    foreach ($field in $booleanMap.Keys) {
        if ([bool]$Observation.$field) {
            $residuals.Add([string]$booleanMap[$field])
        }
        if ($field -eq 'KernelServicePresent') {
            foreach ($filterValue in $Observation.UpperFilterValues) {
                if ([string]::Equals(
                        $filterValue,
                        'CommMonitorFilter',
                        [StringComparison]::OrdinalIgnoreCase)) {
                    $residuals.Add('upper-filter')
                    break
                }
            }
        }
    }
    if (-not [bool]$Observation.CoexistenceBaselineUnchanged) {
        $residuals.Add('coexistence-baseline')
    }

    $knownIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($id in @($booleanMap.Values) + @(
            'upper-filter', 'coexistence-baseline')) {
        [void]$knownIds.Add([string]$id)
    }
    $residualSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($id in $residuals) { [void]$residualSet.Add($id) }
    $pending = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($pendingId in @($AllowedPendingObjectIds)) {
        if ($pendingId -isnot [string] -or
            -not $knownIds.Contains([string]$pendingId)) {
            throw "Pending authority contains unknown object ID '$pendingId'."
        }
        if (-not $pending.Add([string]$pendingId)) {
            throw "Pending authority contains duplicate object ID '$pendingId'."
        }
        if (-not $residualSet.Contains([string]$pendingId)) {
            throw "Pending authority object '$pendingId' is not a current residual."
        }
    }

    $status = if ($residuals.Count -eq 0) {
        'Completed'
    }
    elseif ($pending.Count -eq $residualSet.Count) {
        'PendingReboot'
    }
    else {
        'Failed'
    }
    return [pscustomobject][ordered]@{
        Status = $status
        ResidualObjectIds = [string[]]$residuals.ToArray()
        PendingObjectIds = [string[]]@($pending | Sort-Object)
    }
}

Export-ModuleMember -Function @(
    'Assert-LemonPayloadManifest',
    'ConvertTo-LemonScNativeBinaryPathArgument',
    'Invoke-LemonCheckedNativeCommand',
    'Invoke-LemonMutationTransaction',
    'Get-LemonUpperFiltersAfterUninstall',
    'Test-LemonUpperFiltersRemoval',
    'Invoke-LemonEmptyDirectoryCleanup',
    'Get-LemonResidualAssessment'
)
