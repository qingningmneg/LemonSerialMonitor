Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$innoPath = Join-Path $repoRoot 'installer\LemonSerialMonitor.iss'
$licensePath = Join-Path $repoRoot `
    'installer\TEST_CERTIFICATE_AGREEMENT.zh-CN.txt'
$buildPath = Join-Path $repoRoot 'scripts\Build-Installer.ps1'
$resolverPath = Join-Path $repoRoot `
    'scripts\Resolve-LemonInteractiveUserSid.ps1'
$chineseLanguagePath = Join-Path $repoRoot `
    'installer\third-party\ChineseSimplified.isl'
$chineseLanguageLicensePath = Join-Path $repoRoot `
    'installer\third-party\Inno-Setup-Chinese-Simplified-Translation.LICENSE.txt'

function ConvertFrom-TestCodePoints {
    param([Parameter(Mandatory)][int[]] $CodePoints)

    return -join @($CodePoints | ForEach-Object { [char]$_ })
}

$productName = 'Lemon' + (ConvertFrom-TestCodePoints `
        @(0x4e32, 0x53e3, 0x76d1, 0x63a7))
$installerWord = ConvertFrom-TestCodePoints `
    @(0x5b89, 0x88c5, 0x7a0b, 0x5e8f)

Describe 'Lemon graphical installer contract' {
    It 'has parseable source build and user-resolution files' {
        foreach ($path in @(
                $innoPath,
                $licensePath,
                $buildPath,
                $resolverPath,
                $chineseLanguagePath,
                $chineseLanguageLicensePath)) {
            Test-Path -LiteralPath $path -PathType Leaf | Should Be $true
        }

        foreach ($path in @($buildPath, $resolverPath)) {
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref]$tokens,
                [ref]$errors)
            @($errors).Count | Should Be 0
        }
    }

    It 'vendors the pinned MIT-licensed Simplified Chinese translation' {
        Test-Path -LiteralPath $chineseLanguagePath -PathType Leaf |
            Should Be $true
        Test-Path -LiteralPath $chineseLanguageLicensePath -PathType Leaf |
            Should Be $true
        if (-not (Test-Path -LiteralPath $chineseLanguagePath -PathType Leaf) -or
            -not (Test-Path `
                -LiteralPath $chineseLanguageLicensePath `
                -PathType Leaf)) {
            return
        }
        (Get-FileHash `
                -LiteralPath $chineseLanguagePath `
                -Algorithm SHA256).Hash | Should Be `
            '6753BE2C5E2740D859900FD902824DB2EC568DA5C5B52486524C9762D778B0B0'
        $licenseText = Get-Content `
            -Raw `
            -LiteralPath $chineseLanguageLicensePath `
            -Encoding UTF8
        $licenseText.Contains('MIT License') | Should Be $true
        $innoText = Get-Content -Raw -LiteralPath $innoPath -Encoding UTF8
        $innoText.Contains(
            'MessagesFile: "third-party\ChineseSimplified.isl"') |
            Should Be $true
    }

    It 'uses the exact product identity x64 mode and selectable application directory' {
        $text = Get-Content -Raw -LiteralPath $innoPath -Encoding UTF8
        foreach ($required in @(
                'AppId={{F5B0783F-74F4-4058-90D1-5A4ACC4254A7}',
                ('AppName=' + $productName),
                'AppVersion={#ProductVersion}',
                'PrivilegesRequired=admin',
                'ArchitecturesAllowed=x64compatible',
                'ArchitecturesInstallIn64BitMode=x64compatible',
                ('DefaultDirName={autopf}\' + $productName),
                'DisableDirPage=no',
                ('OutputBaseFilename=' + $productName + '-' +
                    $installerWord + '-x64'),
                'UninstallFilesDir={commonappdata}\LemonSerialMonitor\Installer',
                'ChineseSimplified.isl',
                'LicenseFile=')) {
            $text.Contains($required) | Should Be $true
        }
    }

    It 'extracts the complete payload and runs only absolute hidden PowerShell file entrypoints' {
        $text = Get-Content -Raw -LiteralPath $innoPath -Encoding UTF8
        foreach ($directory in @(
                'app',
                'service',
                'ai',
                'helper',
                'driver',
                'scripts',
                'docs',
                'examples',
                'manual')) {
            $text | Should Match ([regex]::Escape((
                        'DestDir: "LemonPayload\{0}"' -f $directory)))
        }
        $text | Should Not Match 'LemonPayload\\tests'
        $text | Should Not Match '\{#PayloadRoot\}\\tests\\\*'
        $text | Should Match 'Flags: dontcopy noencryption recursesubdirs'
        $text | Should Match 'ExtractTemporaryFiles\(''LemonPayload\\\*''\)'
        $text | Should Match '\{sys\}\\WindowsPowerShell\\v1\.0\\powershell\.exe'
        $text | Should Match '-NoProfile'
        $text | Should Match '-NonInteractive'
        $text | Should Match '-File'
        $text | Should Match 'SW_HIDE'
        $text | Should Match 'ewWaitUntilTerminated'
        $text | Should Not Match '(?i)(^|[\s''"])powershell\.exe'
        $text | Should Not Match '(?i)-Command'
    }

    It 'keeps pending uninstall retryable through a SYSTEM startup continuation' {
        $text = Get-Content -Raw -LiteralPath $innoPath -Encoding UTF8
        foreach ($required in @(
                '/resume=',
                'schtasks.exe',
                '/SC ONSTART',
                '/RU SYSTEM',
                'PendingReboot',
                'UninstallNeedRestart',
                'ExitProcess(3010)')) {
            $text.Contains($required) | Should Be $true
        }
    }

    It 'explains pending restart as Windows driver or device-stack cleanup' {
        $text = Get-Content -Raw -LiteralPath $innoPath -Encoding UTF8
        $accurateNotice = 'Windows ' + (ConvertFrom-TestCodePoints @(
                0x6b63, 0x5728, 0x5b8c, 0x6210, 0x9a71, 0x52a8,
                0x6216, 0x8bbe, 0x5907, 0x6808, 0x7684, 0x5b89,
                0x5168, 0x6e05, 0x7406, 0x3002, 0x8bf7, 0x91cd,
                0x65b0, 0x542f, 0x52a8, 0x8ba1, 0x7b97, 0x673a,
                0xff0c, 0x5378, 0x8f7d, 0x4f1a, 0x81ea, 0x52a8,
                0x7ee7, 0x7eed, 0x3002))
        $misleadingNotice = ConvertFrom-TestCodePoints @(
            0x90e8, 0x5206, 0x6587, 0x4ef6, 0x4ecd, 0x88ab,
            0x0020, 0x0057, 0x0069, 0x006e, 0x0064, 0x006f,
            0x0077, 0x0073, 0x0020, 0x5360, 0x7528)

        $text.Contains($accurateNotice) | Should Be $true
        $text.Contains($misleadingNotice) | Should Be $false
    }

    It 'removes only empty protected installer directories after final uninstall' {
        $text = Get-Content -Raw -LiteralPath $innoPath -Encoding UTF8
        $expected = @(
                'Type: dirifempty; Name: "{commonappdata}\LemonSerialMonitor\Installer\bin"',
                'Type: dirifempty; Name: "{commonappdata}\LemonSerialMonitor\Installer\scripts"',
                'Type: dirifempty; Name: "{commonappdata}\LemonSerialMonitor\Installer"',
                'Type: dirifempty; Name: "{commonappdata}\LemonSerialMonitor"')
        $match = [regex]::Match(
            $text,
            '(?ms)^\[UninstallDelete\]\s*\r?\n(?<body>.*?)(?=^\[[^\r\n]+\]|\z)')
        $match.Success | Should Be $true
        if (-not $match.Success) {
            return
        }
        $actual = @(
            $match.Groups['body'].Value -split '\r?\n' |
                Where-Object {
                    $_.Trim() -ne '' -and
                    -not $_.TrimStart().StartsWith(';')
                } |
                ForEach-Object { $_.Trim() })
        $actual.Count | Should Be $expected.Count
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $actual[$index] | Should Be $expected[$index]
        }
        $match.Groups['body'].Value |
            Should Not Match '(?i)\b(files|filesandordirs)\b|[*?]'
    }

    It 'deletes the empty Task Scheduler folder only after deleting its task' {
        $text = Get-Content -Raw -LiteralPath $innoPath -Encoding UTF8
        foreach ($required in @(
                'CreateOleObject(''Schedule.Service'')',
                'TaskEnumHidden = 1;',
                'GetFolder(''\'')',
                'RootFolder.GetFolders(0)',
                'RootFolders.Item(Index)',
                'CompareText(ProductFolder.Name, ''LemonSerialMonitor'')',
                'FolderTasks := ProductFolder.GetTasks(TaskEnumHidden)',
                'FolderChildren := ProductFolder.GetFolders(0)',
                'FolderTasks.Count = 0',
                'FolderChildren.Count = 0',
                'DeleteFolder(''LemonSerialMonitor'', 0)')) {
            $text.Contains($required) | Should Be $true
        }
        $deleteTask = $text.IndexOf(
            '  DeleteUninstallContinuation;',
            [StringComparison]::Ordinal)
        $deleteFolder = $text.IndexOf(
            '  if not DeleteEmptyUninstallTaskFolder then',
            [StringComparison]::Ordinal)
        $deleteTask | Should BeGreaterThan -1
        $deleteFolder | Should BeGreaterThan $deleteTask
    }

    It 'surfaces the protected install transaction failure message' {
        $text = Get-Content -Raw -LiteralPath $innoPath -Encoding UTF8
        $functionMatch = [regex]::Match(
            $text,
            '(?s)function RunInstallTransaction\b.*?\r?\nend;')
        $functionMatch.Success | Should Be $true
        if (-not $functionMatch.Success) {
            return
        }

        $body = $functionMatch.Value
        $deletePosition = $body.IndexOf(
            'DeleteFile(ResultPath)',
            [StringComparison]::Ordinal)
        $executePosition = $body.IndexOf(
            'ExecutePowerShellFile(ScriptPath, Arguments, ResultCode)',
            [StringComparison]::Ordinal)
        $loadPosition = $body.IndexOf(
            'LoadTextFile(ResultPath, ResultJson)',
            [StringComparison]::Ordinal)
        $exitCodePosition = $body.IndexOf(
            'if (ResultCode <> 0) and (ResultCode <> 3010) then',
            [StringComparison]::Ordinal)
        $deletePosition | Should BeGreaterThan -1
        $executePosition | Should BeGreaterThan $deletePosition
        $loadPosition | Should BeGreaterThan $executePosition
        $exitCodePosition | Should BeGreaterThan $loadPosition
        $body.Contains(
            "JsonStringValue(ResultJson, 'Message')") | Should Be $true
        $failurePrefix = ConvertFrom-TestCodePoints @(
            0x5e95, 0x5c42, 0x5b89, 0x88c5, 0x4e8b,
            0x52a1, 0x5931, 0x8d25, 0xff1a)
        $genericFailure = ConvertFrom-TestCodePoints @(
            0x5e95, 0x5c42, 0x5b89, 0x88c5, 0x4e8b,
            0x52a1, 0x5931, 0x8d25, 0x3002, 0x8bf7,
            0x67e5, 0x770b, 0x5b89, 0x88c5, 0x65e5,
            0x5fd7, 0x540e, 0x91cd, 0x8bd5, 0x3002)
        $body.Contains(
            ("ErrorText := '{0}' + TransactionMessage" -f $failurePrefix)) |
            Should Be $true
        $body.Contains(
            ("ErrorText := '{0}';" -f $genericFailure)) |
            Should Be $true
    }

    It 'discloses certificate trust test-signing reboot and complete data deletion' {
        $text = Get-Content -Raw -LiteralPath $licensePath -Encoding UTF8
        foreach ($required in @(
                (ConvertFrom-TestCodePoints `
                    @(0x672c, 0x5730, 0x6d4b, 0x8bd5, 0x8bc1, 0x4e66)),
                (ConvertFrom-TestCodePoints @(
                        0x53d7, 0x4fe1, 0x4efb, 0x7684, 0x6839,
                        0x8bc1, 0x4e66, 0x9881, 0x53d1, 0x673a, 0x6784)),
                (ConvertFrom-TestCodePoints `
                    @(0x53d7, 0x4fe1, 0x4efb, 0x7684, 0x53d1, 0x5e03, 0x8005)),
                'TESTSIGNING',
                (ConvertFrom-TestCodePoints `
                    @(0x5b89, 0x5168, 0x542f, 0x52a8)),
                (ConvertFrom-TestCodePoints `
                    @(0x91cd, 0x65b0, 0x542f, 0x52a8)),
                (ConvertFrom-TestCodePoints `
                    @(0x4f1a, 0x8bdd, 0x6570, 0x636e)),
                (ConvertFrom-TestCodePoints `
                    @(0x5bfc, 0x51fa, 0x6587, 0x4ef6)),
                (ConvertFrom-TestCodePoints `
                    @(0x4e0d, 0x53ef, 0x6062, 0x590d)))) {
            $text.Contains($required) | Should Be $true
        }
    }

    It 'pins and verifies the official 6.7.3 compiler before accepting output' {
        $text = Get-Content -Raw -LiteralPath $buildPath -Encoding UTF8
        foreach ($required in @(
                "'6.7.3'",
                'JRSoftware.InnoSetup',
                'Get-AuthenticodeSignature',
                'Pyrsys B.V.',
                'jrsoftware.org',
                'Compiler engine version: Inno Setup 6.7.3',
                '$installerFileName = $productName +',
                '0x4e32',
                '0x5b89')) {
            $text.Contains($required) | Should Be $true
        }
    }
}
