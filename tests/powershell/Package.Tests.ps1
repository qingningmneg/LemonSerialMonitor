$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$buildText = Get-Content -Raw -LiteralPath (
    Join-Path $repoRoot 'scripts\Build-All.ps1')
$buildScriptPath = Join-Path $repoRoot 'scripts\Build-All.ps1'
$buildTokens = $null
$buildParseErrors = $null
$buildAst = [Management.Automation.Language.Parser]::ParseFile(
    $buildScriptPath,
    [ref] $buildTokens,
    [ref] $buildParseErrors)
$buildFunctionAsts = @{}
foreach ($functionAst in $buildAst.FindAll({
            param($node)

            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true)) {
    $buildFunctionAsts[$functionAst.Name] = $functionAst
}
foreach ($functionName in @(
        'Assert-NoReparsePointInPath',
        'Assert-NoReparsePointInDirectoryTree',
        'Remove-VerifiedDirectoryTree',
        'Reset-LemonAppPublishOutput',
        'Assert-LemonAppPublishOutput')) {
    if ($buildFunctionAsts.ContainsKey($functionName)) {
        . ([scriptblock]::Create(
                $buildFunctionAsts[$functionName].Extent.Text))
    }
}
$platformText = Get-Content -Raw -LiteralPath (
    Join-Path $repoRoot 'scripts\Lemon.Platform.psm1')
$statusText = Get-Content -Raw -LiteralPath (
    Join-Path $repoRoot 'scripts\Get-CommMonitorStatus.ps1')
$installDocText = Get-Content -Raw -LiteralPath (
    Join-Path $repoRoot 'docs\INSTALL.md')
$userGuideText = Get-Content -Raw -LiteralPath (
    Join-Path $repoRoot 'docs\USER_GUIDE.md')
$mainWindowText = Get-Content -Raw -LiteralPath (
    Join-Path $repoRoot 'src\CommMonitor.App\MainWindow.xaml')
$desktopExecutable = 'Lemon.SerialMonitor.exe'
$legacyBaseName = 'Comm' + 'Monitor.App'
$legacyPublishFileNames = @(
    $legacyBaseName + '.exe'
    $legacyBaseName + '.dll'
    $legacyBaseName + '.deps.json'
    $legacyBaseName + '.runtimeconfig.json'
    $legacyBaseName + '.pdb'
)
$gitIgnoreLines = @(Get-Content -LiteralPath (Join-Path $repoRoot '.gitignore'))
$requiredGitIgnorePatterns = @(
    'tmp/'
    '**/__pycache__/'
    '*.py[cod]'
    '*.user'
    '*.suo'
    '.env*'
    '*.pfx'
    '*.p12'
    '*.p8'
    '*.pem'
    '*.key'
    '*.pvk'
    '*.snk'
    '*.cer'
    '*.crt'
    '*.der'
    '*.db'
    '*.db-wal'
    '*.db-shm'
    '*.cmsession'
    '*.log'
)

function Test-GitIgnored {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RelativePath
    )

    & git -C $repoRoot check-ignore --quiet --no-index -- $RelativePath
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        return $true
    }

    if ($exitCode -eq 1) {
        return $false
    }

    throw "git check-ignore failed for '$RelativePath' with exit code $exitCode."
}

Describe 'CommMonitor package completeness' {
    It 'keeps the internal acceptance checklist source-only' {
        Test-Path -LiteralPath (Join-Path $repoRoot `
                'tests\manual\lemon-installer-acceptance.md') -PathType Leaf |
            Should Be $true
        $buildText | Should Not Match 'acceptanceOutput'
        $buildText | Should Not Match 'tests\\manual'
    }

    It 'validates local Markdown links after packaging' {
        $buildText.Contains('function Test-PackagedMarkdownLinks') |
            Should Be $true
        $buildText.Contains('Test-PackagedMarkdownLinks -PackageRoot $phaseRoot') |
            Should Be $true
    }

    It 'publishes every executable required by graphical setup and AI access' {
        foreach ($project in @(
                'src\CommMonitor.App\CommMonitor.App.csproj',
                'src\CommMonitor.Service\CommMonitor.Service.csproj',
                'src\Lemon.SerialMonitor.AI\Lemon.SerialMonitor.AI.csproj',
                'src\Lemon.UninstallHelper\Lemon.UninstallHelper.csproj')) {
            $buildText.Contains("'publish', '$project'") | Should Be $true
        }
        foreach ($output in @(
                'Lemon.SerialMonitor.exe',
                'CommMonitor.Service.exe',
                'Lemon.SerialMonitor.AI.exe',
                'Lemon.UninstallHelper.exe')) {
            $buildText.Contains($output) | Should Be $true
        }
        $buildText.Contains('$aiOutput = Join-Path $phaseRoot ''ai''') |
            Should Be $true
        $buildText.Contains('$helperOutput = Join-Path $phaseRoot ''helper''') |
            Should Be $true
    }

    It 'packages every public guide AI example and complete manual' {
        $localBuildText = Get-Content `
            -Raw `
            -LiteralPath $buildScriptPath `
            -Encoding UTF8
        foreach ($documentName in @(
                'INSTALL.md',
                'USER_GUIDE.md',
                'TROUBLESHOOTING.md',
                'AI_INTEGRATION.md',
                'AI_API_REFERENCE.md',
                'BUILD.md',
                'SECURITY.md',
                'RELEASE_NOTES_0.1.0.md')) {
            $localBuildText.Contains("'$documentName'") | Should Be $true
        }
        $manualPrefix = 'Lemon' + (-join ([char[]]@(
                    0x4e32, 0x53e3, 0x76d1, 0x63a7))) + '-' +
            (-join ([char[]]@(
                    0x5b8c, 0x6574, 0x64cd, 0x4f5c,
                    0x624b, 0x518c)))
        foreach ($required in @(
                '$examplesOutput = Join-Path $phaseRoot ''examples\ai''',
                'examples\ai',
                ($manualPrefix + '.docx'),
                ($manualPrefix + '.pdf'))) {
            $localBuildText.Contains($required) | Should Be $true
        }
        $localBuildText.Contains(
            '$manualSourceRoot = Join-Path $repoRoot ''manual''') |
            Should Be $true
        $localBuildText | Should Not Match `
            "Join-Path\s+\`$artifactsRoot\s+'manual'"
        foreach ($extension in @('.docx', '.pdf')) {
            Test-Path -LiteralPath (Join-Path $repoRoot `
                    ('manual\' + $manualPrefix + $extension)) -PathType Leaf |
                Should Be $true
        }
    }
}

Describe 'Lemon desktop publish identity' {
    It 'uses the Lemon executable throughout build layout shortcut and status paths' {
        foreach ($text in @($buildText, $platformText, $statusText)) {
            $text.Contains($desktopExecutable) | Should Be $true
        }
    }

    It 'uses the Lemon executable in tracked install and user documentation' {
        $installDocText.Contains($desktopExecutable) | Should Be $true
        $userGuideText.Contains($desktopExecutable) | Should Be $true
    }

    It 'removes local source-path debug records from the release desktop payload' {
        $appProjectArgument = "'src\CommMonitor.App\CommMonitor.App.csproj'"
        $runtimeRestoreIndex = $buildText.IndexOf(
            "'restore', $appProjectArgument",
            [StringComparison]::Ordinal)
        $cleanIndex = $buildText.IndexOf(
            "'clean', $appProjectArgument",
            [StringComparison]::Ordinal)
        $publishIndex = $buildText.IndexOf(
            "'publish', $appProjectArgument",
            [StringComparison]::Ordinal)

        ($runtimeRestoreIndex -ge 0) | Should Be $true
        ($cleanIndex -gt $runtimeRestoreIndex) | Should Be $true
        ($publishIndex -gt $cleanIndex) | Should Be $true
        $runtimeRestoreText = $buildText.Substring(
            $runtimeRestoreIndex,
            $cleanIndex - $runtimeRestoreIndex)
        $runtimeRestoreText.Contains("'--runtime', 'win-x64'") |
            Should Be $true
        $buildText.Contains("'-p:DebugType=None'") | Should Be $true
        $buildText.Contains("'-p:DebugSymbols=false'") | Should Be $true
    }

    It 'clears only the desktop publish output even when stale files exist' {
        $buildFunctionAsts.ContainsKey('Reset-LemonAppPublishOutput') |
            Should Be $true
        if (-not $buildFunctionAsts.ContainsKey(
                'Reset-LemonAppPublishOutput')) {
            return
        }

        $phaseRoot = Join-Path $TestDrive 'phase-reset'
        $appOutput = Join-Path $phaseRoot 'app'
        $preservedPath = Join-Path $phaseRoot 'preserve.txt'
        New-Item -ItemType Directory -Path $appOutput -Force | Out-Null
        Set-Content -LiteralPath $preservedPath -Value 'preserve'
        foreach ($staleName in @(
                ($legacyBaseName + '.exe'),
                ($legacyBaseName + '.dll'),
                'dependency.pdb',
                'unrelated-stale.bin')) {
            Set-Content -LiteralPath (Join-Path $appOutput $staleName) `
                -Value 'stale'
        }

        Reset-LemonAppPublishOutput `
            -PhaseRoot $phaseRoot `
            -AppOutput $appOutput

        (Test-Path -LiteralPath $appOutput -PathType Container) |
            Should Be $true
        @(Get-ChildItem -LiteralPath $appOutput -Force).Count | Should Be 0
        (Test-Path -LiteralPath $preservedPath -PathType Leaf) |
            Should Be $true
    }

    It 'refuses to clear a desktop output outside the verified phase root' {
        $buildFunctionAsts.ContainsKey('Reset-LemonAppPublishOutput') |
            Should Be $true
        if (-not $buildFunctionAsts.ContainsKey(
                'Reset-LemonAppPublishOutput')) {
            return
        }

        $phaseRoot = Join-Path $TestDrive 'phase-boundary'
        $outsideOutput = Join-Path $TestDrive 'outside-app'
        $sentinelPath = Join-Path $outsideOutput 'sentinel.txt'
        New-Item -ItemType Directory -Path $phaseRoot, $outsideOutput -Force |
            Out-Null
        Set-Content -LiteralPath $sentinelPath -Value 'keep'

        {
            Reset-LemonAppPublishOutput `
                -PhaseRoot $phaseRoot `
                -AppOutput $outsideOutput
        } | Should Throw
        (Test-Path -LiteralPath $sentinelPath -PathType Leaf) |
            Should Be $true
    }

    It 'refuses to traverse a reparse-point ancestor before clearing output' {
        $buildFunctionAsts.ContainsKey('Reset-LemonAppPublishOutput') |
            Should Be $true
        if (-not $buildFunctionAsts.ContainsKey(
                'Reset-LemonAppPublishOutput')) {
            return
        }

        $phaseRoot = Join-Path $TestDrive 'phase-reparse'
        $outsideRoot = Join-Path $TestDrive 'outside-reparse-target'
        $junctionPath = Join-Path $phaseRoot 'redirect'
        $redirectedApp = Join-Path $junctionPath 'app'
        $outsideApp = Join-Path $outsideRoot 'app'
        $sentinelPath = Join-Path $outsideApp 'sentinel.txt'
        New-Item -ItemType Directory -Path $phaseRoot, $outsideApp -Force |
            Out-Null
        Set-Content -LiteralPath $sentinelPath -Value 'keep'
        New-Item `
            -ItemType Junction `
            -Path $junctionPath `
            -Target $outsideRoot `
            -Force |
            Out-Null
        try {
            {
                Reset-LemonAppPublishOutput `
                    -PhaseRoot $phaseRoot `
                    -AppOutput $redirectedApp
            } | Should Throw
            (Test-Path -LiteralPath $sentinelPath -PathType Leaf) |
                Should Be $true
        }
        finally {
            if (Test-Path -LiteralPath $junctionPath) {
                [IO.Directory]::Delete($junctionPath)
            }
        }
    }

    It 'refuses a nested reparse point before clearing the desktop output' {
        $buildFunctionAsts.ContainsKey(
            'Assert-NoReparsePointInDirectoryTree') | Should Be $true
        $buildFunctionAsts.ContainsKey('Reset-LemonAppPublishOutput') |
            Should Be $true
        if (-not $buildFunctionAsts.ContainsKey(
                'Assert-NoReparsePointInDirectoryTree') -or
            -not $buildFunctionAsts.ContainsKey(
                'Reset-LemonAppPublishOutput')) {
            return
        }

        $phaseRoot = Join-Path $TestDrive 'phase-nested-reparse'
        $appOutput = Join-Path $phaseRoot 'app'
        $outsideRoot = Join-Path $TestDrive 'outside-app-target'
        $junctionPath = Join-Path $appOutput 'redirect'
        $sentinelPath = Join-Path $outsideRoot 'sentinel.txt'
        New-Item -ItemType Directory -Path $appOutput, $outsideRoot -Force |
            Out-Null
        Set-Content -LiteralPath $sentinelPath -Value 'keep'
        New-Item `
            -ItemType Junction `
            -Path $junctionPath `
            -Target $outsideRoot |
            Out-Null
        try {
            {
                Reset-LemonAppPublishOutput `
                    -PhaseRoot $phaseRoot `
                    -AppOutput $appOutput
            } | Should Throw
            (Test-Path -LiteralPath $sentinelPath -PathType Leaf) |
                Should Be $true
            (Test-Path -LiteralPath $appOutput -PathType Container) |
                Should Be $true
        }
        finally {
            if (Test-Path -LiteralPath $junctionPath) {
                [IO.Directory]::Delete($junctionPath)
            }
        }
    }

    It 'refuses a nested reparse point before the default phase cleanup' {
        $buildFunctionAsts.ContainsKey('Remove-VerifiedDirectoryTree') |
            Should Be $true
        if (-not $buildFunctionAsts.ContainsKey(
                'Remove-VerifiedDirectoryTree')) {
            return
        }

        $artifactsRoot = Join-Path $TestDrive 'artifacts-reparse'
        $phaseRoot = Join-Path $artifactsRoot 'phase1'
        $payloadRoot = Join-Path $phaseRoot 'payload'
        $outsideRoot = Join-Path $TestDrive 'outside-phase-target'
        $junctionPath = Join-Path $payloadRoot 'redirect'
        $sentinelPath = Join-Path $outsideRoot 'sentinel.txt'
        New-Item `
            -ItemType Directory `
            -Path $payloadRoot, $outsideRoot `
            -Force |
            Out-Null
        Set-Content -LiteralPath $sentinelPath -Value 'keep'
        New-Item `
            -ItemType Junction `
            -Path $junctionPath `
            -Target $outsideRoot |
            Out-Null
        try {
            {
                Remove-VerifiedDirectoryTree `
                    -RootPath $artifactsRoot `
                    -TargetPath $phaseRoot
            } | Should Throw
            (Test-Path -LiteralPath $sentinelPath -PathType Leaf) |
                Should Be $true
            (Test-Path -LiteralPath $phaseRoot -PathType Container) |
                Should Be $true
        }
        finally {
            if (Test-Path -LiteralPath $junctionPath) {
                [IO.Directory]::Delete($junctionPath)
            }
        }
    }

    It 'rejects old desktop files and every PDB in the published payload' {
        $buildFunctionAsts.ContainsKey('Assert-LemonAppPublishOutput') |
            Should Be $true
        if (-not $buildFunctionAsts.ContainsKey(
                'Assert-LemonAppPublishOutput')) {
            return
        }

        $appOutput = Join-Path $TestDrive 'app-validation'
        New-Item -ItemType Directory -Path $appOutput -Force | Out-Null
        Set-Content `
            -LiteralPath (Join-Path $appOutput 'Lemon.SerialMonitor.exe') `
            -Value 'new'
        { Assert-LemonAppPublishOutput -AppOutput $appOutput } |
            Should Not Throw

        $legacyPath = Join-Path $appOutput ($legacyBaseName + '.exe')
        Set-Content -LiteralPath $legacyPath -Value 'old'
        { Assert-LemonAppPublishOutput -AppOutput $appOutput } |
            Should Throw
        Remove-Item -LiteralPath $legacyPath -Force

        Set-Content `
            -LiteralPath (Join-Path $appOutput 'dependency.PDB') `
            -Value 'debug'
        { Assert-LemonAppPublishOutput -AppOutput $appOutput } |
            Should Throw
    }

    It 'resets and validates the desktop payload around publish and manifest creation' {
        $resetCallIndex = $buildText.IndexOf(
            'Reset-LemonAppPublishOutput `',
            [StringComparison]::Ordinal)
        $publishIndex = $buildText.IndexOf(
            "'publish', 'src\CommMonitor.App\CommMonitor.App.csproj'",
            [StringComparison]::Ordinal)
        $assertCallIndex = $buildText.LastIndexOf(
            'Assert-LemonAppPublishOutput -AppOutput $appOutput',
            [StringComparison]::Ordinal)
        $manifestIndex = $buildText.IndexOf(
            '$manifestLines = Get-ChildItem',
            [StringComparison]::Ordinal)

        ($resetCallIndex -ge 0) | Should Be $true
        ($publishIndex -gt $resetCallIndex) | Should Be $true
        ($assertCallIndex -gt $publishIndex) | Should Be $true
        ($manifestIndex -gt $assertCallIndex) | Should Be $true
        $phaseCreateIndex = $buildText.IndexOf(
            '[void] [IO.Directory]::CreateDirectory($phaseRoot)',
            [StringComparison]::Ordinal)
        $phaseCleanupIndex = $buildText.LastIndexOf(
            'Remove-VerifiedDirectoryTree `',
            $phaseCreateIndex,
            [StringComparison]::Ordinal)
        $phaseTargetIndex = $buildText.IndexOf(
            '-TargetPath $phaseRoot',
            $phaseCleanupIndex,
            [StringComparison]::Ordinal)
        ($phaseCleanupIndex -ge 0) | Should Be $true
        ($phaseTargetIndex -gt $phaseCleanupIndex) | Should Be $true
        ($phaseCreateIndex -gt $phaseTargetIndex) | Should Be $true
    }

    It 'contains no old desktop publish file family in product deployment or user docs' {
        $scopedText = @(
            $buildText
            $platformText
            $statusText
            $installDocText
            $userGuideText
        ) -join [Environment]::NewLine

        foreach ($legacyFileName in $legacyPublishFileNames) {
            $scopedText.Contains($legacyFileName) | Should Be $false
        }
    }

    It 'retains the internal WPF namespace and project path' {
        $mainWindowText.Contains('x:Class="CommMonitor.App.MainWindow"') |
            Should Be $true
        Test-Path -LiteralPath (
            Join-Path $repoRoot 'src\CommMonitor.App\CommMonitor.App.csproj') |
            Should Be $true
    }
}

Describe 'Repository hygiene exclusions' {
    It 'contains the exact required ignore pattern <Pattern>' -TestCases @(
        $requiredGitIgnorePatterns | ForEach-Object { @{ Pattern = $_ } }
    ) {
        param([string] $Pattern)

        $gitIgnoreLines.Contains($Pattern) | Should Be $true
    }

    It 'ignores the local transient path <Path>' -TestCases @(
        @{ Path = 'src/CommMonitor.Driver/CommMonitor.Driver.vcxproj.user' }
        @{ Path = 'tmp/manual-render-final/page-01.png' }
        @{
            Path = 'scripts/docs/__pycache__/' +
                'build_commmonitor_manual.cpython-311.pyc'
        }
    ) {
        param([string] $Path)

        (Test-GitIgnored -RelativePath $Path) | Should Be $true
    }

    It 'does not ignore repository content <Path>' -TestCases @(
        @{ Path = 'README.md' }
        @{ Path = 'src/CommMonitor.Core/Ai/AiContracts.cs' }
    ) {
        param([string] $Path)

        (Test-GitIgnored -RelativePath $Path) | Should Be $false
    }
}
