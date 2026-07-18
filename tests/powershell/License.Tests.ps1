Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$licensePath = Join-Path $repoRoot 'LICENSE'
$buildAllPath = Join-Path $repoRoot 'scripts\Build-All.ps1'
$buildInstallerPath = Join-Path $repoRoot 'scripts\Build-Installer.ps1'
$chineseReadmePath = Join-Path $repoRoot 'README.md'
$englishReadmePath = Join-Path $repoRoot 'README.en.md'
$installerDisclosurePath = Join-Path $repoRoot `
    'installer\TEST_CERTIFICATE_AGREEMENT.zh-CN.txt'

function Get-RequiredUtf8Content {
    param([Parameter(Mandatory)][string] $Path)

    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $exists | Should Be $true
    if (-not $exists) {
        return $null
    }

    return Get-Content -Raw -LiteralPath $Path -Encoding UTF8
}

function Get-JoinedPathVariableName {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.ScriptBlockAst] $Ast,
        [Parameter(Mandatory)][string] $ParentVariable,
        [Parameter(Mandatory)][string] $ChildPath
    )

    $variableName = $null
    $assignments = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Operator -eq
                    [Management.Automation.Language.TokenKind]::Equals -and
                $node.Left -is
                    [Management.Automation.Language.VariableExpressionAst]
            }, $true))
    foreach ($assignment in $assignments) {
        $commands = @($assignment.Right.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Join-Path'
                }, $true))
        foreach ($command in $commands) {
            $binding = Get-StaticCommandBinding -Command $command
            $parent = Get-BoundCommandValue `
                -Binding $binding `
                -ParameterName @('Path')
            if ($null -eq $parent) {
                $parent = Get-BoundCommandValue -Binding $binding -Position 0
            }
            $child = Get-BoundCommandValue `
                -Binding $binding `
                -ParameterName @('ChildPath')
            if ($null -eq $child) {
                $child = Get-BoundCommandValue -Binding $binding -Position 1
            }
            $hasParent = $null -ne $parent -and
                (Test-AstReferencesVariable `
                    -Ast $parent `
                    -VariableName $ParentVariable)
            $childValue = if ($child -is
                [Management.Automation.Language.StringConstantExpressionAst]) {
                $child.Value
            }
            else {
                $null
            }
            $hasChild = [string]::Equals(
                $childValue,
                $ChildPath,
                [StringComparison]::OrdinalIgnoreCase)
            if ($hasParent -and $hasChild) {
                $variableName = $assignment.Left.VariablePath.UserPath
                break
            }
        }
        if ($null -ne $variableName) {
            break
        }
    }

    [string]::IsNullOrEmpty($variableName) | Should Be $false
    if ([string]::IsNullOrEmpty($variableName)) {
        return $null
    }

    return $variableName
}

function Get-PowerShellAst {
    param([Parameter(Mandatory)][string] $Content)

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $Content,
        [ref] $tokens,
        [ref] $parseErrors)
    @($parseErrors).Count | Should Be 0
    return $ast
}

function Test-AstReferencesVariable {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)][string] $VariableName
    )

    return @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.VariableExpressionAst] -and
                [string]::Equals(
                    $node.VariablePath.UserPath,
                    $VariableName,
                    [StringComparison]::OrdinalIgnoreCase)
            }, $true)).Count -gt 0
}

function Get-StaticCommandBinding {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.CommandAst] $Command
    )

    return [Management.Automation.Language.StaticParameterBinder]::BindCommand(
        $Command,
        $false)
}

function Get-BoundCommandValue {
    param(
        [Parameter(Mandatory)] $Binding,
        [string[]] $ParameterName = @(),
        [int] $Position = -1
    )

    foreach ($name in $ParameterName) {
        foreach ($key in $Binding.BoundParameters.Keys) {
            if ([string]::Equals(
                    [string]$key,
                    $name,
                    [StringComparison]::OrdinalIgnoreCase)) {
                return $Binding.BoundParameters[$key].Value
            }
        }
    }
    if ($Position -ge 0) {
        $positionKey = [string]$Position
        if ($Binding.BoundParameters.ContainsKey($positionKey)) {
            return $Binding.BoundParameters[$positionKey].Value
        }
    }

    return $null
}

function Test-BoundCommandParameter {
    param(
        [Parameter(Mandatory)] $Binding,
        [Parameter(Mandatory)][string] $ParameterName
    )

    return @($Binding.BoundParameters.Keys | Where-Object {
            [string]::Equals(
                [string]$_,
                $ParameterName,
                [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
}

function Test-GetContentLicenseRead {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.CommandAst] $Command,
        [Parameter(Mandatory)][string] $SourceVariable
    )

    $binding = Get-StaticCommandBinding -Command $Command
    $path = Get-BoundCommandValue `
        -Binding $binding `
        -ParameterName @('LiteralPath', 'Path')
    if ($null -eq $path) {
        $path = Get-BoundCommandValue -Binding $binding -Position 0
    }
    $encoding = Get-BoundCommandValue `
        -Binding $binding `
        -ParameterName @('Encoding')
    $encodingText = if ($null -eq $encoding) {
        $null
    }
    elseif ($encoding -is
        [Management.Automation.Language.StringConstantExpressionAst]) {
        $encoding.Value
    }
    else {
        $encoding.Extent.Text.Trim('''', '"')
    }

    return $null -ne $path -and
        (Test-AstReferencesVariable -Ast $path `
            -VariableName $SourceVariable) -and
        (Test-BoundCommandParameter -Binding $binding -ParameterName 'Raw') -and
        [string]::Equals(
            $encodingText,
            'UTF8',
            [StringComparison]::OrdinalIgnoreCase)
}

function Test-LicenseTransfer {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.ScriptBlockAst] $Ast,
        [Parameter(Mandatory)][string] $SourceVariable,
        [Parameter(Mandatory)][string] $TargetVariable
    )

    $copyCommands = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Copy-Item'
            }, $true))
    foreach ($command in $copyCommands) {
        $binding = Get-StaticCommandBinding -Command $command
        $source = Get-BoundCommandValue `
            -Binding $binding `
            -ParameterName @('LiteralPath', 'Path')
        $sourceWasNamed = $null -ne $source
        if (-not $sourceWasNamed) {
            $source = Get-BoundCommandValue -Binding $binding -Position 0
        }
        $target = Get-BoundCommandValue `
            -Binding $binding `
            -ParameterName @('Destination')
        if ($null -eq $target) {
            $targetPosition = if ($sourceWasNamed) { 0 } else { 1 }
            $target = Get-BoundCommandValue `
                -Binding $binding `
                -Position $targetPosition
        }
        if ($null -ne $source -and $null -ne $target -and
            (Test-AstReferencesVariable -Ast $source `
                -VariableName $SourceVariable) -and
            (Test-AstReferencesVariable -Ast $target `
                -VariableName $TargetVariable)) {
            return $true
        }
    }

    $copyInvocations = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Member.Extent.Text -eq 'Copy' -and
                $node.Expression -is
                    [Management.Automation.Language.TypeExpressionAst] -and
                $node.Expression.TypeName.FullName -match '^(System\.)?IO\.File$'
            }, $true))
    foreach ($invocation in $copyInvocations) {
        if ($invocation.Arguments.Count -ge 2 -and
            (Test-AstReferencesVariable -Ast $invocation.Arguments[0] `
                -VariableName $SourceVariable) -and
            (Test-AstReferencesVariable -Ast $invocation.Arguments[1] `
                -VariableName $TargetVariable)) {
            return $true
        }
    }

    $licenseContentVariables = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Operator -eq
                    [Management.Automation.Language.TokenKind]::Equals -and
                $node.Left -is
                    [Management.Automation.Language.VariableExpressionAst]
            }, $true) | Where-Object {
                @($_.Right.FindAll({
                            param($node)
                            $node -is [Management.Automation.Language.CommandAst] -and
                            $node.GetCommandName() -eq 'Get-Content'
                        }, $true) | Where-Object {
                        Test-GetContentLicenseRead `
                            -Command $_ `
                            -SourceVariable $SourceVariable
                    }).Count -gt 0
            } | ForEach-Object { $_.Left.VariablePath.UserPath })
    if ($licenseContentVariables.Count -eq 0) {
        return $false
    }

    $setContentCommands = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Set-Content'
            }, $true))
    foreach ($command in $setContentCommands) {
        $binding = Get-StaticCommandBinding -Command $command
        $target = Get-BoundCommandValue `
            -Binding $binding `
            -ParameterName @('LiteralPath', 'Path')
        $targetWasNamed = $null -ne $target
        if (-not $targetWasNamed) {
            $target = Get-BoundCommandValue -Binding $binding -Position 0
        }
        $value = Get-BoundCommandValue `
            -Binding $binding `
            -ParameterName @('Value')
        if ($null -eq $value) {
            $valuePosition = if ($targetWasNamed) { 0 } else { 1 }
            $value = Get-BoundCommandValue `
                -Binding $binding `
                -Position $valuePosition
        }
        if ($null -eq $target -or $null -eq $value -or
            -not (Test-AstReferencesVariable -Ast $target `
                -VariableName $TargetVariable)) {
            continue
        }
        foreach ($contentVariable in $licenseContentVariables) {
            if (Test-AstReferencesVariable -Ast $value `
                    -VariableName $contentVariable) {
                return $true
            }
        }
    }

    return $false
}

function Test-RequiredPackageOutputReference {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.ScriptBlockAst] $Ast,
        [Parameter(Mandatory)][string] $TargetVariable
    )

    $requiredOutputAssignments = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq 'requiredPackageOutputs' -and
                $node.Operator -in @(
                    [Management.Automation.Language.TokenKind]::Equals,
                    [Management.Automation.Language.TokenKind]::PlusEquals)
            }, $true))

    return @($requiredOutputAssignments | Where-Object {
            Test-AstReferencesVariable `
                -Ast $_.Right `
                -VariableName $TargetVariable
        }).Count -gt 0
}

function Test-VariableAssignmentContainsExactString {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.ScriptBlockAst] $Ast,
        [Parameter(Mandatory)][string] $VariableName,
        [Parameter(Mandatory)][string] $ExpectedValue
    )

    $assignments = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                [string]::Equals(
                    $node.Left.VariablePath.UserPath,
                    $VariableName,
                    [StringComparison]::OrdinalIgnoreCase) -and
                $node.Operator -in @(
                    [Management.Automation.Language.TokenKind]::Equals,
                    [Management.Automation.Language.TokenKind]::PlusEquals)
            }, $true))
    foreach ($assignment in $assignments) {
        $stringValues = @($assignment.Right.FindAll({
                    param($node)
                    $node -is
                        [Management.Automation.Language.StringConstantExpressionAst]
                }, $true) | ForEach-Object Value)
        if (@($stringValues | Where-Object {
                    [string]::Equals(
                        $_,
                        $ExpectedValue,
                        [StringComparison]::Ordinal)
                }).Count -gt 0) {
            return $true
        }
    }

    return $false
}

Describe 'MIT license distribution contract' {
    It 'provides the standard MIT license and attribution at repository root' {
        $license = Get-RequiredUtf8Content -Path $licensePath
        if ($null -eq $license) {
            return
        }

        foreach ($requiredText in @(
                'MIT License',
                'Copyright (c) 2026 qingningmneg',
                'to use, copy, modify, merge, publish, distribute, sublicense, and/or sell',
                'The above copyright notice and this permission notice shall be included')) {
            $license.Contains($requiredText) | Should Be $true
        }
    }

    It 'reads the root license as UTF-8 while building the package' {
        $buildAll = Get-RequiredUtf8Content -Path $buildAllPath
        if ($null -eq $buildAll) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildAll
        $sourceVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'repoRoot' `
            -ChildPath 'LICENSE'
        if ([string]::IsNullOrEmpty($sourceVariable)) {
            return
        }

        $readCommands = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Get-Content'
                }, $true) | Where-Object {
                Test-GetContentLicenseRead `
                    -Command $_ `
                    -SourceVariable $sourceVariable
            })

        ($readCommands.Count -gt 0) | Should Be $true
    }

    It 'targets LICENSE.txt in the package documentation directory' {
        $buildAll = Get-RequiredUtf8Content -Path $buildAllPath
        if ($null -eq $buildAll) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildAll
        $sourceVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'repoRoot' `
            -ChildPath 'LICENSE'
        $targetVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'docsOutput' `
            -ChildPath 'LICENSE.txt'

        if ([string]::IsNullOrEmpty($sourceVariable) -or
            [string]::IsNullOrEmpty($targetVariable)) {
            return
        }

        (Test-LicenseTransfer `
                -Ast $ast `
                -SourceVariable $sourceVariable `
                -TargetVariable $targetVariable) | Should Be $true
    }

    It 'copies the canonical license to the package root for Markdown links' {
        $buildAll = Get-RequiredUtf8Content -Path $buildAllPath
        if ($null -eq $buildAll) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildAll
        $sourceVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'repoRoot' `
            -ChildPath 'LICENSE'
        $targetVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'phaseRoot' `
            -ChildPath 'LICENSE'
        if ([string]::IsNullOrEmpty($sourceVariable) -or
            [string]::IsNullOrEmpty($targetVariable)) {
            return
        }

        (Test-LicenseTransfer `
                -Ast $ast `
                -SourceVariable $sourceVariable `
                -TargetVariable $targetVariable) | Should Be $true
    }

    It 'requires the package-root license output' {
        $buildAll = Get-RequiredUtf8Content -Path $buildAllPath
        if ($null -eq $buildAll) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildAll
        $targetVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'phaseRoot' `
            -ChildPath 'LICENSE'
        if ([string]::IsNullOrEmpty($targetVariable)) {
            return
        }

        (Test-RequiredPackageOutputReference `
                -Ast $ast `
                -TargetVariable $targetVariable) | Should Be $true
    }

    It 'requires the packaged license output' {
        $buildAll = Get-RequiredUtf8Content -Path $buildAllPath
        if ($null -eq $buildAll) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildAll
        $targetVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'docsOutput' `
            -ChildPath 'LICENSE.txt'
        if ([string]::IsNullOrEmpty($targetVariable)) {
            return
        }

        $requiredOutputAssignments = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.UserPath -eq 'requiredPackageOutputs' -and
                    $node.Operator -in @(
                        [Management.Automation.Language.TokenKind]::Equals,
                        [Management.Automation.Language.TokenKind]::PlusEquals)
                }, $true))

        $targetIsRequired = @($requiredOutputAssignments | Where-Object {
                Test-AstReferencesVariable `
                    -Ast $_.Right `
                    -VariableName $targetVariable
            }).Count -gt 0
        $targetIsRequired | Should Be $true
    }

    It 'copies the third-party source record into the package documentation tree' {
        $buildAll = Get-RequiredUtf8Content -Path $buildAllPath
        if ($null -eq $buildAll) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildAll
        $sourceVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'repoRoot' `
            -ChildPath 'installer\third-party\SOURCE.md'
        $targetVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'docsOutput' `
            -ChildPath 'third-party\SOURCE.md'
        if ([string]::IsNullOrEmpty($sourceVariable) -or
            [string]::IsNullOrEmpty($targetVariable)) {
            return
        }

        (Test-LicenseTransfer `
                -Ast $ast `
                -SourceVariable $sourceVariable `
                -TargetVariable $targetVariable) | Should Be $true
    }

    It 'copies the third-party translation license into the package documentation tree' {
        $buildAll = Get-RequiredUtf8Content -Path $buildAllPath
        if ($null -eq $buildAll) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildAll
        $sourceVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'repoRoot' `
            -ChildPath 'installer\third-party\Inno-Setup-Chinese-Simplified-Translation.LICENSE.txt'
        $targetVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'docsOutput' `
            -ChildPath 'third-party\Inno-Setup-Chinese-Simplified-Translation.LICENSE.txt'
        if ([string]::IsNullOrEmpty($sourceVariable) -or
            [string]::IsNullOrEmpty($targetVariable)) {
            return
        }

        (Test-LicenseTransfer `
                -Ast $ast `
                -SourceVariable $sourceVariable `
                -TargetVariable $targetVariable) | Should Be $true
    }

    It 'requires the packaged third-party source record output' {
        $buildAll = Get-RequiredUtf8Content -Path $buildAllPath
        if ($null -eq $buildAll) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildAll
        $targetVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'docsOutput' `
            -ChildPath 'third-party\SOURCE.md'
        if ([string]::IsNullOrEmpty($targetVariable)) {
            return
        }

        (Test-RequiredPackageOutputReference `
                -Ast $ast `
                -TargetVariable $targetVariable) | Should Be $true
    }

    It 'requires the packaged third-party translation license output' {
        $buildAll = Get-RequiredUtf8Content -Path $buildAllPath
        if ($null -eq $buildAll) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildAll
        $targetVariable = Get-JoinedPathVariableName `
            -Ast $ast `
            -ParentVariable 'docsOutput' `
            -ChildPath 'third-party\Inno-Setup-Chinese-Simplified-Translation.LICENSE.txt'
        if ([string]::IsNullOrEmpty($targetVariable)) {
            return
        }

        (Test-RequiredPackageOutputReference `
                -Ast $ast `
                -TargetVariable $targetVariable) | Should Be $true
    }

    It 'requires the project license in the installer payload' {
        $buildInstaller = Get-RequiredUtf8Content -Path $buildInstallerPath
        if ($null -eq $buildInstaller) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildInstaller
        (Test-VariableAssignmentContainsExactString `
                -Ast $ast `
                -VariableName 'requiredPayload' `
                -ExpectedValue 'docs\LICENSE.txt') | Should Be $true
    }

    It 'requires the package-root project license in the installer payload' {
        $buildInstaller = Get-RequiredUtf8Content -Path $buildInstallerPath
        if ($null -eq $buildInstaller) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildInstaller
        (Test-VariableAssignmentContainsExactString `
                -Ast $ast `
                -VariableName 'requiredPayload' `
                -ExpectedValue 'LICENSE') | Should Be $true
    }

    It 'requires the third-party source record in the installer payload' {
        $buildInstaller = Get-RequiredUtf8Content -Path $buildInstallerPath
        if ($null -eq $buildInstaller) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildInstaller
        (Test-VariableAssignmentContainsExactString `
                -Ast $ast `
                -VariableName 'requiredPayload' `
                -ExpectedValue 'docs\third-party\SOURCE.md') | Should Be $true
    }

    It 'requires the third-party translation license in the installer payload' {
        $buildInstaller = Get-RequiredUtf8Content -Path $buildInstallerPath
        if ($null -eq $buildInstaller) {
            return
        }

        $ast = Get-PowerShellAst -Content $buildInstaller
        (Test-VariableAssignmentContainsExactString `
                -Ast $ast `
                -VariableName 'requiredPayload' `
                -ExpectedValue 'docs\third-party\Inno-Setup-Chinese-Simplified-Translation.LICENSE.txt') |
            Should Be $true
    }

    It 'states the MIT commercial-use terms in the Chinese README' {
        $readme = Get-RequiredUtf8Content -Path $chineseReadmePath
        if ($null -eq $readme) {
            return
        }

        foreach ($requiredText in @(
                'MIT',
                '商业使用',
                '保留版权声明和许可证')) {
            $readme.Contains($requiredText) | Should Be $true
        }
    }

    It 'states the MIT commercial-use terms in the English README' {
        $readme = Get-RequiredUtf8Content -Path $englishReadmePath
        if ($null -eq $readme) {
            return
        }

        foreach ($requiredText in @(
                'MIT',
                'commercial use',
                'retain the copyright and license notice')) {
            $readme.Contains($requiredText) | Should Be $true
        }
    }

    It 'states the MIT attribution terms in the installer disclosure' {
        $disclosure = Get-RequiredUtf8Content -Path $installerDisclosurePath
        if ($null -eq $disclosure) {
            return
        }

        foreach ($requiredText in @(
                'MIT',
                'Copyright (c) 2026 qingningmneg',
                '保留版权声明和本许可声明')) {
            $disclosure.Contains($requiredText) | Should Be $true
        }
    }
}
