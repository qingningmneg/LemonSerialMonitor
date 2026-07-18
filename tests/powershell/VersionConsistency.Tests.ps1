Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Get-LemonScriptAst {
    param([Parameter(Mandatory)][string] $LiteralPath)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $LiteralPath,
        [ref]$tokens,
        [ref]$errors)
    if (@($errors).Count -ne 0) {
        throw "PowerShell parse failed for '$LiteralPath': $($errors -join '; ')"
    }

    return $ast
}

function Get-LemonVariableAssignments {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)][string] $VariableName
    )

    return @($Ast.FindAll({
                param($node)

                $node -is
                    [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Operator -eq
                    [Management.Automation.Language.TokenKind]::Equals -and
                $node.Left -is
                    [Management.Automation.Language.VariableExpressionAst] -and
                [string]::Equals(
                    $node.Left.VariablePath.UserPath,
                    $VariableName,
                    [StringComparison]::OrdinalIgnoreCase)
            }, $true))
}

function Get-LemonFunctions {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)][string] $FunctionName
    )

    return @($Ast.FindAll({
                param($node)

                $node -is
                    [Management.Automation.Language.FunctionDefinitionAst] -and
                [string]::Equals(
                    $node.Name,
                    $FunctionName,
                    [StringComparison]::OrdinalIgnoreCase)
            }, $true))
}

function Get-LemonAssignmentStringValue {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.AssignmentStatementAst] $Assignment
    )

    if ($Assignment.Right -is
            [Management.Automation.Language.CommandExpressionAst] -and
        $Assignment.Right.Expression -is
            [Management.Automation.Language.StringConstantExpressionAst]) {
        return $Assignment.Right.Expression.Value
    }

    return $null
}

function Get-LemonCommandParameterArguments {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.Language.CommandAst] $Command,
        [Parameter(Mandatory)][string] $ParameterName
    )

    $arguments = @()
    for ($index = 0; $index -lt $Command.CommandElements.Count; $index++) {
        $element = $Command.CommandElements[$index]
        if ($element -is
                [Management.Automation.Language.CommandParameterAst] -and
            [string]::Equals(
                $element.ParameterName,
                $ParameterName,
                [StringComparison]::OrdinalIgnoreCase)) {
            if ($index + 1 -ge $Command.CommandElements.Count) {
                throw "Command parameter '$ParameterName' has no argument."
            }
            $arguments += $Command.CommandElements[$index + 1]
        }
    }

    return $arguments
}

Describe 'Lemon 0.1.1 version consistency' {
    It 'pins every product project to the exact current product and file versions' {
        $projects = @(
            'src\CommMonitor.App\CommMonitor.App.csproj',
            'src\CommMonitor.Core\CommMonitor.Core.csproj',
            'src\CommMonitor.Service\CommMonitor.Service.csproj',
            'src\Lemon.SerialMonitor.AI\Lemon.SerialMonitor.AI.csproj',
            'src\Lemon.UninstallHelper\Lemon.UninstallHelper.csproj')
        $expectedProperties = [ordered]@{
            Version = '0.1.1'
            FileVersion = '0.1.1.0'
            InformationalVersion = '0.1.1'
            IncludeSourceRevisionInInformationalVersion = 'false'
        }

        foreach ($relativePath in $projects) {
            $path = Join-Path $repoRoot $relativePath
            [xml]$project = Get-Content -Raw -LiteralPath $path -Encoding UTF8
            foreach ($propertyName in $expectedProperties.Keys) {
                $nodes = @($project.SelectNodes(
                        "/Project/PropertyGroup/$propertyName"))
                $nodes.Count | Should Be 1
                $nodes[0].InnerText | Should Be $expectedProperties[$propertyName]
            }
        }
    }

    It 'uses one Inno product-version define for every version directive' {
        $path = Join-Path $repoRoot 'installer\LemonSerialMonitor.iss'
        $text = Get-Content -Raw -LiteralPath $path -Encoding UTF8
        $defines = [regex]::Matches(
            $text,
            '(?m)^\s*#define\s+ProductVersion\s+"(?<value>[^"]+)"\s*$')
        $defines.Count | Should Be 1
        $defines[0].Groups['value'].Value | Should Be '0.1.1'

        $expectedDirectives = [ordered]@{
            AppVersion = '{#ProductVersion}'
            AppVerName = '{#ProductName} {#ProductVersion}'
            VersionInfoVersion = '{#ProductVersion}.0'
            VersionInfoProductVersion = '{#ProductVersion}'
        }
        foreach ($directiveName in $expectedDirectives.Keys) {
            $matches = [regex]::Matches(
                $text,
                ('(?m)^\s*{0}=(?<value>[^\r\n]+)\s*$' -f
                    [regex]::Escape($directiveName)))
            $matches.Count | Should Be 1
            $matches[0].Groups['value'].Value.Trim() |
                Should Be $expectedDirectives[$directiveName]
        }

        [regex]::Matches($text, '(?<!\d)0\.1\.1(?!\d)').Count | Should Be 1
        $text | Should Not Match '(?<!\d)0\.1\.0(?:\.0)?(?!\d)'
    }

    It 'records the current installer product version once' {
        $path = Join-Path $repoRoot 'scripts\Install-CommMonitor.ps1'
        $ast = Get-LemonScriptAst -LiteralPath $path
        $assignments = @(Get-LemonVariableAssignments `
                -Ast $ast `
                -VariableName 'productVersion')
        $assignments.Count | Should Be 1
        (Get-LemonAssignmentStringValue -Assignment $assignments[0]) |
            Should Be '0.1.1'
    }

    It 'uses the current immutable-file marker in uninstall work' {
        $path = Join-Path $repoRoot `
            'src\Lemon.UninstallHelper\Manifest\UninstallWorkBuilder.cs'
        $text = Get-Content -Raw -LiteralPath $path -Encoding UTF8
        $matches = [regex]::Matches(
            $text,
            '(?m)^\s*private\s+const\s+string\s+ProductMarker\s*=\s*' +
                '"(?<value>[^"]+)"\s*;\s*$')
        $matches.Count | Should Be 1
        $matches[0].Groups['value'].Value | Should Be 'CommMonitor:0.1.1'
        [regex]::Matches($text, '\bProductMarker\b').Count | Should Be 2
    }

    It 'checks current executable versions and release notes in Build-All' {
        $path = Join-Path $repoRoot 'scripts\Build-All.ps1'
        $ast = Get-LemonScriptAst -LiteralPath $path
        $functions = @(Get-LemonFunctions `
                -Ast $ast `
                -FunctionName 'Assert-LemonPublishedMetadata')
        $functions.Count | Should Be 1

        $expectedDefaults = [ordered]@{
            FileVersion = '0.1.1.0'
            ProductVersion = '0.1.1'
        }
        foreach ($parameterName in $expectedDefaults.Keys) {
            $parameters = @($functions[0].Body.ParamBlock.Parameters |
                Where-Object {
                    [string]::Equals(
                        $_.Name.VariablePath.UserPath,
                        $parameterName,
                        [StringComparison]::OrdinalIgnoreCase)
                })
            $parameters.Count | Should Be 1
            $parameters[0].DefaultValue -is
                [Management.Automation.Language.StringConstantExpressionAst] |
                Should Be $true
            $parameters[0].DefaultValue.Value |
                Should Be $expectedDefaults[$parameterName]
        }

        $releaseNotes = @($ast.FindAll({
                    param($node)

                    $node -is
                        [Management.Automation.Language.StringConstantExpressionAst] -and
                    $node.Value -ceq 'RELEASE_NOTES_0.1.1.md'
                }, $true))
        $releaseNotes.Count | Should Be 1
        (Get-Content -Raw -LiteralPath $path -Encoding UTF8) |
            Should Not Match 'RELEASE_NOTES_0\.1\.0\.md'
    }

    It 'derives Build-Installer release inputs and output from one current version' {
        $path = Join-Path $repoRoot 'scripts\Build-Installer.ps1'
        $ast = Get-LemonScriptAst -LiteralPath $path
        $text = Get-Content -Raw -LiteralPath $path -Encoding UTF8
        $versionAssignments = @(Get-LemonVariableAssignments `
                -Ast $ast `
                -VariableName 'productVersion')
        $versionAssignments.Count | Should Be 1
        (Get-LemonAssignmentStringValue `
                -Assignment $versionAssignments[0]) | Should Be '0.1.1'

        $releaseNotesAssignments = @(Get-LemonVariableAssignments `
                -Ast $ast `
                -VariableName 'releaseNotesPath')
        $releaseNotesAssignments.Count | Should Be 1
        $releaseNotesAssignments[0].Right.Extent.Text |
            Should Match 'docs\\RELEASE_NOTES_\$productVersion\.md'

        $bundleAssignments = @(Get-LemonVariableAssignments `
                -Ast $ast `
                -VariableName 'releaseBundlePath' |
            Where-Object { $_.Right.Extent.Text -match '\$productVersion\b' })
        $bundleAssignments.Count | Should Be 1
        $bundleAssignments[0].Right.Extent.Text |
            Should Match 'artifacts\\release'

        $bundleCommands = @($ast.FindAll({
                    param($node)

                    $node -is [Management.Automation.Language.CommandAst] -and
                    $node.Extent.Text -match 'Test-ReleaseBundle\.ps1' -and
                    @($node.CommandElements | Where-Object {
                            $_ -is
                                [Management.Automation.Language.CommandParameterAst] -and
                            $_.ParameterName -eq 'Version'
                        }).Count -eq 1
                }, $true))
        $bundleCommands.Count | Should Be 1
        $versionArguments = @(Get-LemonCommandParameterArguments `
                -Command $bundleCommands[0] `
                -ParameterName 'Version')
        $versionArguments.Count | Should Be 1
        $versionArguments[0] -is
            [Management.Automation.Language.VariableExpressionAst] |
            Should Be $true
        $versionArguments[0].VariablePath.UserPath | Should Be 'productVersion'
        $notesArguments = @(Get-LemonCommandParameterArguments `
                -Command $bundleCommands[0] `
                -ParameterName 'ReleaseNotesPath')
        $notesArguments.Count | Should Be 1
        $notesArguments[0] -is
            [Management.Automation.Language.VariableExpressionAst] |
            Should Be $true
        $notesArguments[0].VariablePath.UserPath | Should Be 'releaseNotesPath'

        $text | Should Not Match '(?<!\d)0\.1\.0(?:\.0)?(?!\d)'
    }

    It 'defaults release-bundle verification to current dynamically named notes' {
        $path = Join-Path $repoRoot 'scripts\Test-ReleaseBundle.ps1'
        $ast = Get-LemonScriptAst -LiteralPath $path
        $versionParameters = @($ast.ParamBlock.Parameters | Where-Object {
                [string]::Equals(
                    $_.Name.VariablePath.UserPath,
                    'Version',
                    [StringComparison]::OrdinalIgnoreCase)
            })
        $versionParameters.Count | Should Be 1
        $versionParameters[0].DefaultValue -is
            [Management.Automation.Language.StringConstantExpressionAst] |
            Should Be $true
        $versionParameters[0].DefaultValue.Value | Should Be '0.1.1'

        $notesAssignments = @(Get-LemonVariableAssignments `
                -Ast $ast `
                -VariableName 'ReleaseNotesPath')
        $notesAssignments.Count | Should Be 1
        $notesAssignments[0].Right.Extent.Text |
            Should Match 'docs\\RELEASE_NOTES_\$Version\.md'
        (Get-Content -Raw -LiteralPath $path -Encoding UTF8) |
            Should Not Match 'RELEASE_NOTES_\d+\.\d+\.\d+\.md'
    }

    It 'preserves both 0.1.0 ownership fixtures as historical records' {
        foreach ($relativePath in @(
                'tests\fixtures\installer\ownership-manifest-v3\auth\payload.json',
                'tests\fixtures\installer\ownership-manifest-v3\disk\ownership-manifest.v3.json')) {
            $path = Join-Path $repoRoot $relativePath
            Test-Path -LiteralPath $path -PathType Leaf | Should Be $true
            $text = Get-Content -Raw -LiteralPath $path -Encoding UTF8
            [regex]::Matches(
                $text,
                '"productVersion":"0\.1\.0"').Count | Should Be 1
            [regex]::Matches(
                $text,
                '"productMarker":"CommMonitor:0\.1\.0"').Count |
                Should BeGreaterThan 0
            $text | Should Not Match 'CommMonitor:0\.1\.1'
        }
    }

    It 'preserves both historical 0.1.0 release-note headings' {
        $chineseProductName = 'Lemon' + (-join @(
                [char]0x4e32,
                [char]0x53e3,
                [char]0x76d1,
                [char]0x63a7))
        $chineseHeadingSuffix = -join @(
            [char]0x53d1,
            [char]0x5e03,
            [char]0x8bf4,
            [char]0x660e)
        $expectedHeadings = [ordered]@{
            'docs\RELEASE_NOTES_0.1.0.md' =
                "# $chineseProductName 0.1.0 $chineseHeadingSuffix"
            'docs\RELEASE_NOTES_0.1.0.en.md' =
                '# Lemon Serial Monitor 0.1.0 Release Notes'
        }

        foreach ($relativePath in $expectedHeadings.Keys) {
            $path = Join-Path $repoRoot $relativePath
            Test-Path -LiteralPath $path -PathType Leaf | Should Be $true
            @(Get-Content -LiteralPath $path -Encoding UTF8)[0] |
                Should Be $expectedHeadings[$relativePath]
        }
    }
}
