[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [switch] $TestSignDriver,

    [string] $WdkPackagesDirectory = (
        Join-Path ([IO.Path]::GetTempPath()) 'CommMonitor-WdkPackages-BuildAll'),

    [switch] $SkipClean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$artifactsRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'artifacts'))
$manualSourceRoot = Join-Path $repoRoot 'manual'
$phaseRoot = [IO.Path]::GetFullPath((Join-Path $artifactsRoot 'phase1'))
$appOutput = [IO.Path]::GetFullPath((Join-Path $phaseRoot 'app'))
$serviceOutput = Join-Path $phaseRoot 'service'
$aiOutput = Join-Path $phaseRoot 'ai'
$helperOutput = Join-Path $phaseRoot 'helper'
$driverOutput = Join-Path $phaseRoot 'driver'
$scriptsOutput = Join-Path $phaseRoot 'scripts'
$docsOutput = Join-Path $phaseRoot 'docs'
$examplesOutput = Join-Path $phaseRoot 'examples\ai'
$manualOutput = Join-Path $phaseRoot 'manual'

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $ArgumentList
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
    }
}

function Test-PackagedMarkdownLinks {
    param([Parameter(Mandatory)][string] $PackageRoot)

    $packagePrefix = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\') + '\'
    $brokenLinks = [Collections.Generic.List[string]]::new()
    foreach ($markdownFile in Get-ChildItem `
            -LiteralPath $PackageRoot `
            -Filter '*.md' `
            -File `
            -Recurse) {
        $content = [IO.File]::ReadAllText(
            $markdownFile.FullName,
            [Text.Encoding]::UTF8)
        foreach ($match in [Text.RegularExpressions.Regex]::Matches(
                $content,
                '(?<!!)\[[^\]]+\]\((?<target>[^)]+)\)')) {
            $target = $match.Groups['target'].Value.Trim()
            if ($target.StartsWith('<') -and $target.EndsWith('>')) {
                $target = $target.Substring(1, $target.Length - 2)
            }
            elseif ($target -match '^([^\s]+)\s+["'']') {
                $target = $Matches[1]
            }
            if ([string]::IsNullOrWhiteSpace($target) -or
                $target.StartsWith('#') -or
                $target -match '^[a-z][a-z0-9+.-]*:') {
                continue
            }

            $pathOnly = ($target -split '[?#]', 2)[0]
            $decodedPath = [Uri]::UnescapeDataString($pathOnly).Replace(
                '/',
                [IO.Path]::DirectorySeparatorChar)
            $candidate = [IO.Path]::GetFullPath((Join-Path `
                $markdownFile.DirectoryName `
                $decodedPath))
            if (-not $candidate.StartsWith(
                    $packagePrefix,
                    [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $candidate)) {
                $relativeMarkdown = $markdownFile.FullName.Substring(
                    $packagePrefix.Length)
                $brokenLinks.Add("$relativeMarkdown -> $target")
            }
        }
    }

    if ($brokenLinks.Count -ne 0) {
        throw "Broken packaged Markdown link(s): $($brokenLinks -join '; ')"
    }
}

function Assert-NoReparsePointInPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RootPath,
        [Parameter(Mandatory)][string] $TargetPath
    )

    $trimCharacters = [char[]] @(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $normalizedRoot = [IO.Path]::GetFullPath($RootPath).TrimEnd(
        $trimCharacters)
    $normalizedTarget = [IO.Path]::GetFullPath($TargetPath).TrimEnd(
        $trimCharacters)
    $rootPrefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $normalizedTarget.StartsWith(
            $rootPrefix,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$normalizedTarget' is not a strict child of '$normalizedRoot'."
    }

    $pathsToInspect = [Collections.Generic.List[string]]::new()
    [void] $pathsToInspect.Add($normalizedRoot)
    $relativeTarget = $normalizedTarget.Substring($rootPrefix.Length)
    $currentPath = $normalizedRoot
    foreach ($segment in $relativeTarget.Split(
            $trimCharacters,
            [StringSplitOptions]::RemoveEmptyEntries)) {
        $currentPath = Join-Path $currentPath $segment
        [void] $pathsToInspect.Add($currentPath)
    }

    foreach ($pathToInspect in $pathsToInspect) {
        if (-not (Test-Path -LiteralPath $pathToInspect)) {
            continue
        }

        $pathItem = Get-Item -LiteralPath $pathToInspect -Force
        if (-not $pathItem.PSIsContainer) {
            throw "Expected a directory in the output path: '$pathToInspect'."
        }
        if (($pathItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne
            0) {
            throw "Refusing output path containing a reparse point: '$pathToInspect'."
        }
    }
}

function Assert-NoReparsePointInDirectoryTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $DirectoryPath)

    $normalizedDirectory = [IO.Path]::GetFullPath($DirectoryPath)
    if (-not (Test-Path `
            -LiteralPath $normalizedDirectory `
            -PathType Container)) {
        throw "Directory tree was not found: '$normalizedDirectory'."
    }

    $rootItem = Get-Item -LiteralPath $normalizedDirectory -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne
        0) {
        throw "Refusing directory tree rooted at a reparse point: '$normalizedDirectory'."
    }

    $directoriesToInspect = [Collections.Generic.Stack[string]]::new()
    $directoriesToInspect.Push($normalizedDirectory)
    while ($directoriesToInspect.Count -ne 0) {
        $currentDirectory = $directoriesToInspect.Pop()
        foreach ($entryPath in [IO.Directory]::EnumerateFileSystemEntries(
                $currentDirectory)) {
            $entryAttributes = [IO.File]::GetAttributes($entryPath)
            if (($entryAttributes -band [IO.FileAttributes]::ReparsePoint) -ne
                0) {
                throw "Refusing directory tree containing a reparse point: '$entryPath'."
            }
            if (($entryAttributes -band [IO.FileAttributes]::Directory) -ne
                0) {
                $directoriesToInspect.Push($entryPath)
            }
        }
    }
}

function Remove-VerifiedDirectoryTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RootPath,
        [Parameter(Mandatory)][string] $TargetPath
    )

    $normalizedTarget = [IO.Path]::GetFullPath($TargetPath)
    Assert-NoReparsePointInPath `
        -RootPath $RootPath `
        -TargetPath $normalizedTarget
    if (-not (Test-Path -LiteralPath $normalizedTarget)) {
        return
    }

    Assert-NoReparsePointInDirectoryTree -DirectoryPath $normalizedTarget
    Remove-Item -LiteralPath $normalizedTarget -Recurse -Force
}

function Reset-LemonAppPublishOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PhaseRoot,
        [Parameter(Mandatory)][string] $AppOutput
    )

    $trimCharacters = [char[]] @(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $normalizedPhaseRoot = [IO.Path]::GetFullPath($PhaseRoot).TrimEnd(
        $trimCharacters)
    $normalizedAppOutput = [IO.Path]::GetFullPath($AppOutput).TrimEnd(
        $trimCharacters)
    $phasePrefix = $normalizedPhaseRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $normalizedAppOutput.StartsWith(
            $phasePrefix,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Desktop output '$normalizedAppOutput' is outside '$normalizedPhaseRoot'."
    }

    [void] [IO.Directory]::CreateDirectory($normalizedPhaseRoot)
    Remove-VerifiedDirectoryTree `
        -RootPath $normalizedPhaseRoot `
        -TargetPath $normalizedAppOutput
    [void] [IO.Directory]::CreateDirectory($normalizedAppOutput)
}

function Assert-LemonAppPublishOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $AppOutput)

    $normalizedAppOutput = [IO.Path]::GetFullPath($AppOutput)
    if (-not (Test-Path `
            -LiteralPath $normalizedAppOutput `
            -PathType Container)) {
        throw "Desktop publish output was not created: '$normalizedAppOutput'."
    }

    $legacyDesktopBaseName = 'Comm' + 'Monitor.App'
    $unexpectedFiles = @(
        Get-ChildItem -LiteralPath $normalizedAppOutput -File -Recurse |
            Where-Object {
                $_.Extension.Equals(
                    '.pdb',
                    [StringComparison]::OrdinalIgnoreCase) -or
                $_.Name.Equals(
                    $legacyDesktopBaseName,
                    [StringComparison]::OrdinalIgnoreCase) -or
                $_.Name.StartsWith(
                    $legacyDesktopBaseName + '.',
                    [StringComparison]::OrdinalIgnoreCase)
            }
    )
    if ($unexpectedFiles.Count -ne 0) {
        $unexpectedRelativePaths = $unexpectedFiles |
            ForEach-Object {
                $_.FullName.Substring($normalizedAppOutput.Length + 1)
            }
        throw "Forbidden desktop publish file(s): $($unexpectedRelativePaths -join '; ')"
    }
}

function Assert-LemonPublishedMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string] $ProductName,
        [Parameter(Mandatory)][string] $FileDescription,
        [Parameter(Mandatory)][string] $CompanyName,
        [string] $FileVersion = '0.1.0.0',
        [string] $ProductVersion = '0.1.0'
    )

    $normalizedPath = [IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
        throw "Published metadata target was not found: '$normalizedPath'."
    }

    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo(
        $normalizedPath)
    $expected = [ordered]@{
        ProductName = $ProductName
        FileDescription = $FileDescription
        CompanyName = $CompanyName
        FileVersion = $FileVersion
        ProductVersion = $ProductVersion
    }
    foreach ($propertyName in $expected.Keys) {
        $actualValue = [string]$versionInfo.$propertyName
        $expectedValue = [string]$expected[$propertyName]
        if ($actualValue -cne $expectedValue) {
            throw "Published metadata mismatch for '$normalizedPath' " +
                "($propertyName): expected '$expectedValue', got '$actualValue'."
        }
    }
}

if (-not $phaseRoot.StartsWith(
        $artifactsRoot.TrimEnd('\') + '\',
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing unsafe artifact path '$phaseRoot'."
}
[void] [IO.Directory]::CreateDirectory($artifactsRoot)
Assert-NoReparsePointInPath `
    -RootPath $artifactsRoot `
    -TargetPath $phaseRoot
if (-not $SkipClean -and (Test-Path -LiteralPath $phaseRoot)) {
    Remove-VerifiedDirectoryTree `
        -RootPath $artifactsRoot `
        -TargetPath $phaseRoot
}
[void] [IO.Directory]::CreateDirectory($phaseRoot)
Reset-LemonAppPublishOutput `
    -PhaseRoot $phaseRoot `
    -AppOutput $appOutput
New-Item -ItemType Directory -Force -Path `
    $serviceOutput, $aiOutput, $helperOutput, $driverOutput,
    $scriptsOutput, $docsOutput, $examplesOutput, $manualOutput |
    Out-Null

Push-Location $repoRoot
try {
    Invoke-CheckedCommand -FilePath 'dotnet' -ArgumentList @(
        'restore', 'CommMonitor.sln', '--nologo')
    Invoke-CheckedCommand -FilePath 'dotnet' -ArgumentList @(
        'test', 'CommMonitor.sln',
        '--configuration', $Configuration,
        '--no-restore',
        '--nologo')

    $pester = Get-Module -ListAvailable Pester |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -eq $pester) {
        throw 'Pester is required to run the install-safety tests.'
    }
    Import-Module $pester.Path -Force
    $pesterResult = Invoke-Pester `
        -Script 'tests\powershell' `
        -PassThru
    if ($pesterResult.FailedCount -ne 0) {
        throw "$($pesterResult.FailedCount) install-safety test(s) failed."
    }

    Invoke-CheckedCommand -FilePath 'dotnet' -ArgumentList @(
        'restore', 'src\CommMonitor.App\CommMonitor.App.csproj',
        '--runtime', 'win-x64',
        '--nologo')
    Invoke-CheckedCommand -FilePath 'dotnet' -ArgumentList @(
        'clean', 'src\CommMonitor.App\CommMonitor.App.csproj',
        '--configuration', $Configuration,
        '--runtime', 'win-x64',
        '--nologo')
    Invoke-CheckedCommand -FilePath 'dotnet' -ArgumentList @(
        'publish', 'src\CommMonitor.App\CommMonitor.App.csproj',
        '--configuration', $Configuration,
        '--runtime', 'win-x64',
        '--self-contained', 'true',
        '-p:DebugType=None',
        '-p:DebugSymbols=false',
        '--nologo',
        '--output', $appOutput)
    Assert-LemonAppPublishOutput -AppOutput $appOutput
    Invoke-CheckedCommand -FilePath 'dotnet' -ArgumentList @(
        'publish', 'src\CommMonitor.Service\CommMonitor.Service.csproj',
        '--configuration', $Configuration,
        '--runtime', 'win-x64',
        '--self-contained', 'true',
        '-p:DebugType=None',
        '-p:DebugSymbols=false',
        '--nologo',
        '--output', $serviceOutput)
    Invoke-CheckedCommand -FilePath 'dotnet' -ArgumentList @(
        'publish', 'src\Lemon.SerialMonitor.AI\Lemon.SerialMonitor.AI.csproj',
        '--configuration', $Configuration,
        '--runtime', 'win-x64',
        '--self-contained', 'true',
        '-p:DebugType=None',
        '-p:DebugSymbols=false',
        '--nologo',
        '--output', $aiOutput)
    Invoke-CheckedCommand -FilePath 'dotnet' -ArgumentList @(
        'publish', 'src\Lemon.UninstallHelper\Lemon.UninstallHelper.csproj',
        '--configuration', $Configuration,
        '--runtime', 'win-x64',
        '--self-contained', 'true',
        '-p:DebugType=None',
        '-p:DebugSymbols=false',
        '--nologo',
        '--output', $helperOutput)

    $publicProductName = 'Lemon串口监控'
    $companyName = 'Lemon Serial Monitor'
    Assert-LemonPublishedMetadata `
        -FilePath (Join-Path $appOutput 'Lemon.SerialMonitor.exe') `
        -ProductName $publicProductName `
        -FileDescription $publicProductName `
        -CompanyName $companyName
    Assert-LemonPublishedMetadata `
        -FilePath (Join-Path $appOutput 'CommMonitor.Core.dll') `
        -ProductName $publicProductName `
        -FileDescription ($publicProductName + '核心组件') `
        -CompanyName $companyName
    Assert-LemonPublishedMetadata `
        -FilePath (Join-Path $serviceOutput 'CommMonitor.Service.exe') `
        -ProductName ($publicProductName + '服务') `
        -FileDescription ($publicProductName + '服务') `
        -CompanyName $companyName
    Assert-LemonPublishedMetadata `
        -FilePath (Join-Path $serviceOutput 'CommMonitor.Core.dll') `
        -ProductName $publicProductName `
        -FileDescription ($publicProductName + '核心组件') `
        -CompanyName $companyName
    Assert-LemonPublishedMetadata `
        -FilePath (Join-Path $aiOutput 'Lemon.SerialMonitor.AI.exe') `
        -ProductName ($publicProductName + ' AI 接口') `
        -FileDescription ($publicProductName + ' AI 接口') `
        -CompanyName $companyName
    Assert-LemonPublishedMetadata `
        -FilePath (Join-Path $helperOutput 'Lemon.UninstallHelper.exe') `
        -ProductName ($publicProductName + '卸载组件') `
        -FileDescription ($publicProductName + '卸载组件') `
        -CompanyName $companyName

    & (Join-Path $PSScriptRoot 'Build-Driver.ps1') `
        -Configuration $Configuration `
        -RunCodeAnalysis `
        -PackagesDirectory $WdkPackagesDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Build-Driver.ps1 failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$builtDriverDirectory = Join-Path $repoRoot `
    "artifacts\driver\$Configuration\x64"
foreach ($driverFileName in @(
        'CommMonitor.Driver.sys',
        'CommMonitor.Driver.inf')) {
    $driverFile = Join-Path $builtDriverDirectory $driverFileName
    if (-not (Test-Path -LiteralPath $driverFile -PathType Leaf)) {
        throw "Expected driver build output not found: $driverFile"
    }
    Copy-Item -LiteralPath $driverFile -Destination $driverOutput -Force
}

if ($TestSignDriver) {
    & (Join-Path $PSScriptRoot 'Test-SignDriver.ps1') `
        -DriverDirectory $driverOutput `
        -WdkSearchRoot $WdkPackagesDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Test-SignDriver.ps1 failed with exit code $LASTEXITCODE."
    }

    $certificatePath = Join-Path $driverOutput `
        'CommMonitor.LocalTestDriver.cer'
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $certificatePath)
    try { $certificateThumbprint = $certificate.Thumbprint }
    finally { $certificate.Dispose() }
    foreach ($executable in @(
            (Join-Path $appOutput 'Lemon.SerialMonitor.exe'),
            (Join-Path $serviceOutput 'CommMonitor.Service.exe'),
            (Join-Path $aiOutput 'Lemon.SerialMonitor.AI.exe'),
            (Join-Path $helperOutput 'Lemon.UninstallHelper.exe'))) {
        & (Join-Path $PSScriptRoot 'Sign-Release.ps1') `
            -FilePath $executable `
            -CertificateThumbprint $certificateThumbprint `
            -WdkSearchRoot $WdkPackagesDirectory
        if ($LASTEXITCODE -ne 0) {
            throw "Sign-Release.ps1 failed for '$executable'."
        }
    }
}

Copy-Item -Path (Join-Path $PSScriptRoot '*.ps1') -Destination $scriptsOutput -Force
Copy-Item -Path (Join-Path $PSScriptRoot '*.psm1') -Destination $scriptsOutput -Force
foreach ($documentName in @(
        'INSTALL.md',
        'USER_GUIDE.md',
        'TROUBLESHOOTING.md',
        'AI_INTEGRATION.md',
        'AI_API_REFERENCE.md',
        'BUILD.md',
        'SECURITY.md',
        'RELEASE_NOTES_0.1.0.md')) {
    $documentPath = Join-Path (Join-Path $repoRoot 'docs') $documentName
    if (-not (Test-Path -LiteralPath $documentPath -PathType Leaf)) {
        throw "Required public document was not found: $documentPath"
    }
    Copy-Item -LiteralPath $documentPath -Destination $docsOutput -Force
}
$examplesSource = Join-Path $repoRoot 'examples\ai'
if (-not (Test-Path -LiteralPath $examplesSource -PathType Container)) {
    throw "Required AI examples were not found: $examplesSource"
}
Copy-Item -Path (Join-Path $examplesSource '*') `
    -Destination $examplesOutput `
    -Recurse `
    -Force
foreach ($manualName in @(
        'Lemon串口监控-完整操作手册.docx',
        'Lemon串口监控-完整操作手册.pdf')) {
    $manualPath = Join-Path $manualSourceRoot $manualName
    if (-not (Test-Path -LiteralPath $manualPath -PathType Leaf)) {
        throw "Required complete manual was not found: $manualPath"
    }
    Copy-Item -LiteralPath $manualPath -Destination $manualOutput -Force
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') `
    -Destination $phaseRoot `
    -Force

Test-PackagedMarkdownLinks -PackageRoot $phaseRoot

$manifestLines = Get-ChildItem -LiteralPath $phaseRoot -File -Recurse |
    Where-Object Name -NE 'SHA256SUMS.txt' |
    Sort-Object FullName |
    ForEach-Object {
        $relativePath = $_.FullName.Substring($phaseRoot.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $relativePath"
    }
$manifestPath = Join-Path $phaseRoot 'SHA256SUMS.txt'
Set-Content -LiteralPath $manifestPath -Value $manifestLines -Encoding UTF8

$requiredPackageOutputs = @(
    (Join-Path $appOutput 'Lemon.SerialMonitor.exe'),
    (Join-Path $serviceOutput 'CommMonitor.Service.exe'),
    (Join-Path $aiOutput 'Lemon.SerialMonitor.AI.exe'),
    (Join-Path $helperOutput 'Lemon.UninstallHelper.exe'),
    (Join-Path $driverOutput 'CommMonitor.Driver.sys'),
    (Join-Path $driverOutput 'CommMonitor.Driver.inf'),
    (Join-Path $docsOutput 'AI_INTEGRATION.md'),
    (Join-Path $docsOutput 'AI_API_REFERENCE.md'),
    (Join-Path $docsOutput 'BUILD.md'),
    (Join-Path $docsOutput 'SECURITY.md'),
    (Join-Path $examplesOutput 'mcp-config.json'),
    (Join-Path $manualOutput 'Lemon串口监控-完整操作手册.docx'),
    (Join-Path $manualOutput 'Lemon串口监控-完整操作手册.pdf'),
    $manifestPath
)
if ($TestSignDriver) {
    $requiredPackageOutputs += @(
        (Join-Path $driverOutput 'CommMonitor.Driver.cat'),
        (Join-Path $driverOutput 'CommMonitor.LocalTestDriver.cer'))
}
foreach ($requiredOutput in $requiredPackageOutputs) {
    if (-not (Test-Path -LiteralPath $requiredOutput -PathType Leaf)) {
        throw "Phase-one package output not found: $requiredOutput"
    }
}

Write-Output "PHASE1_ARTIFACT_ROOT=$phaseRoot"
Write-Output "MANIFEST=$manifestPath"
Write-Output "TEST_SIGNED=$TestSignDriver"
if (-not $TestSignDriver) {
    Write-Warning 'The driver package is not yet installable. Rerun with -TestSignDriver after reviewing the local certificate behavior.'
}
