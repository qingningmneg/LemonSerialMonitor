[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug',

    [switch] $RunCodeAnalysis,

    [string] $PackagesDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repoRoot 'src\CommMonitor.Driver\CommMonitor.Driver.vcxproj'
$kernelGateProjectPath = Join-Path $repoRoot 'tests\driver\KernelProtocolCompileTests.vcxproj'
$outputDir = Join-Path $repoRoot "artifacts\driver\$Configuration\x64"
$kernelGateOutputDir = Join-Path $repoRoot "artifacts\driver\kernel-gate\$Configuration\x64"
$nativeOutputDir = Join-Path $repoRoot "artifacts\native-tests\$Configuration\x64"
$protocolLayoutTest = Join-Path $repoRoot 'tests\driver\ProtocolLayoutTests.cpp'
$ringModelTest = Join-Path $repoRoot 'tests\driver\RingModelTests.cpp'
$transportCoreTest = Join-Path $repoRoot 'tests\driver\TransportCoreTests.cpp'
$transportCoreSource = Join-Path $repoRoot 'src\CommMonitor.Driver\TransportCore.c'
$deviceIdHashTest = Join-Path $repoRoot 'tests\driver\DeviceIdHashTests.cpp'
$captureCoreTest = Join-Path $repoRoot 'tests\driver\CaptureCoreTests.cpp'
$captureCoreSource = Join-Path $repoRoot 'src\CommMonitor.Driver\CaptureCore.c'
$packagesDir = if ($PackagesDirectory) {
    [IO.Path]::GetFullPath($PackagesDirectory)
}
elseif ($RunCodeAnalysis) {
    Join-Path ([IO.Path]::GetTempPath()) 'CommMonitor-WdkPackages-CodeAnalysis'
}
else {
    Join-Path $repoRoot 'artifacts\driver\packages'
}

if ($RunCodeAnalysis -and $packagesDir -match '[^\x00-\x7F]') {
    throw 'MSVC code-analysis rulesets require an ASCII restore path in this environment. Pass -PackagesDirectory with a writable ASCII-only path.'
}

$buildLog = Join-Path $outputDir 'msbuild.log'
$binaryLog = Join-Path $outputDir 'msbuild.binlog'
$kernelGateBuildLog = Join-Path $kernelGateOutputDir 'msbuild.log'
$kernelGateBinaryLog = Join-Path $kernelGateOutputDir 'msbuild.binlog'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'

if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "Visual Studio locator not found: $vswhere"
}

$wdkComponentIds = @(
    'Microsoft.Windows.DriverKit',
    'Component.Microsoft.Windows.DriverKit',
    'Component.Microsoft.Windows.DriverKit.BuildTools'
)
$installationPath = $wdkComponentIds |
    ForEach-Object {
        & $vswhere `
            -latest `
            -products '*' `
            -version '[17.0,18.0)' `
            -requires $_ Microsoft.Component.MSBuild Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
    } |
    Where-Object { $_ } |
    Select-Object -First 1

if (-not $installationPath) {
    throw 'No Visual Studio 2022 installation with the required WDK component was found. Install Microsoft.Windows.DriverKit or Component.Microsoft.Windows.DriverKit (Visual Studio), or Component.Microsoft.Windows.DriverKit.BuildTools (Build Tools).'
}

$vsDevCmd = Join-Path $installationPath 'Common7\Tools\VsDevCmd.bat'
$msbuild = Join-Path $installationPath 'MSBuild\Current\Bin\amd64\MSBuild.exe'

foreach ($requiredPath in @(
    $vsDevCmd,
    $msbuild,
    $kernelGateProjectPath,
    $projectPath,
    $protocolLayoutTest,
    $ringModelTest,
    $transportCoreTest,
    $transportCoreSource,
    $deviceIdHashTest,
    $captureCoreTest,
    $captureCoreSource)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required build input not found: $requiredPath"
    }
}

New-Item -ItemType Directory -Force -Path `
    $outputDir, `
    $kernelGateOutputDir, `
    $nativeOutputDir, `
    $packagesDir | Out-Null

function Invoke-NativeTests {
    $protocolObject = Join-Path $nativeOutputDir 'ProtocolLayoutTests.obj'
    $protocolExe = Join-Path $nativeOutputDir 'ProtocolLayoutTests.exe'
    $ringObject = Join-Path $nativeOutputDir 'RingModelTests.obj'
    $ringExe = Join-Path $nativeOutputDir 'RingModelTests.exe'
    $transportObject = Join-Path $nativeOutputDir 'TransportCore.obj'
    $transportTestObject = Join-Path $nativeOutputDir 'TransportCoreTests.obj'
    $transportExe = Join-Path $nativeOutputDir 'TransportCoreTests.exe'
    $captureObject = Join-Path $nativeOutputDir 'CaptureCore.obj'
    $deviceIdHashObject = Join-Path $nativeOutputDir 'DeviceIdHashTests.obj'
    $deviceIdHashExe = Join-Path $nativeOutputDir 'DeviceIdHashTests.exe'
    $captureTestObject = Join-Path $nativeOutputDir 'CaptureCoreTests.obj'
    $captureExe = Join-Path $nativeOutputDir 'CaptureCoreTests.exe'
    $nativeCommands = @(
        ('cl /nologo /std:c++17 /W4 /WX /EHsc "{0}" /Fo:"{1}" /Fe:"{2}"' -f `
            $protocolLayoutTest, $protocolObject, $protocolExe),
        ('"{0}"' -f $protocolExe),
        ('cl /nologo /std:c++17 /W4 /WX /EHsc "{0}" /Fo:"{1}" /Fe:"{2}"' -f `
            $ringModelTest, $ringObject, $ringExe),
        ('"{0}"' -f $ringExe),
        ('cl /nologo /TC /W4 /WX /c "{0}" /Fo:"{1}"' -f `
            $transportCoreSource, $transportObject),
        ('cl /nologo /std:c++17 /W4 /WX /EHsc "{0}" "{1}" /Fo:"{2}" /Fe:"{3}"' -f `
            $transportCoreTest, $transportObject, $transportTestObject, $transportExe),
        ('"{0}"' -f $transportExe),
        ('cl /nologo /TC /W4 /WX /c "{0}" /Fo:"{1}"' -f `
            $captureCoreSource, $captureObject),
        ('cl /nologo /std:c++17 /W4 /WX /EHsc "{0}" "{1}" /Fo:"{2}" /Fe:"{3}"' -f `
            $deviceIdHashTest, $captureObject, $deviceIdHashObject, $deviceIdHashExe),
        ('"{0}"' -f $deviceIdHashExe),
        ('cl /nologo /std:c++17 /W4 /WX /EHsc "{0}" "{1}" /Fo:"{2}" /Fe:"{3}"' -f `
            $captureCoreTest, $captureObject, $captureTestObject, $captureExe),
        ('"{0}"' -f $captureExe)
    )
    $commandLine = 'call "{0}" -arch=x64 -host_arch=x64 >nul && {1}' -f `
        $vsDevCmd,
        ($nativeCommands -join ' && ')

    Write-Output "Building and running portable native gates with /W4 /WX..."
    & $env:ComSpec /d /s /c $commandLine
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Portable native gates failed with exit code $exitCode."
    }

    Write-Output 'NATIVE_PROTOCOL_LAYOUT_EXIT_CODE=0'
    Write-Output 'NATIVE_RING_MODEL_EXIT_CODE=0'
    Write-Output 'NATIVE_TRANSPORT_CORE_EXIT_CODE=0'
    Write-Output 'NATIVE_DEVICE_ID_HASH_EXIT_CODE=0'
    Write-Output 'NATIVE_CAPTURE_CORE_EXIT_CODE=0'
}

function Invoke-WdkBuild {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Label,

        [Parameter(Mandatory)]
        [string] $LogPath,

        [Parameter(Mandatory)]
        [string] $BinaryLogPath,

        [switch] $EnableCodeAnalysis
    )

    $msbuildArguments = @(
        "`"$Path`"",
        '/restore',
        '/t:Rebuild',
        '/m:1',
        '/nr:false',
        '/verbosity:minimal',
        "/p:Configuration=$Configuration",
        '/p:Platform=x64',
        '/p:BuildInParallel=false',
        "/p:RestorePackagesPath=`"$packagesDir`"",
        "/flp:logfile=`"$LogPath`";verbosity=normal",
        "/bl:`"$BinaryLogPath`""
    )
    if ($EnableCodeAnalysis) {
        $msbuildArguments += '/p:RunCodeAnalysis=true'
    }
    $commandLine = 'call "{0}" -arch=x64 -host_arch=x64 >nul && "{1}" {2}' -f `
        $vsDevCmd,
        $msbuild,
        ($msbuildArguments -join ' ')

    Write-Output "Building '$Label' with amd64 MSBuild..."
    & $env:ComSpec /d /s /c $commandLine
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Label build failed with exit code $exitCode."
    }
}

Push-Location $repoRoot
try {
    Write-Output "RUN_CODE_ANALYSIS=$RunCodeAnalysis"
    Write-Output "RESTORE_PACKAGES_PATH=$packagesDir"
    Invoke-NativeTests
    Invoke-WdkBuild `
        -Path $kernelGateProjectPath `
        -Label 'kernel protocol compile gate' `
        -LogPath $kernelGateBuildLog `
        -BinaryLogPath $kernelGateBinaryLog
    Invoke-WdkBuild `
        -Path $projectPath `
        -Label 'CommMonitor.Driver' `
        -LogPath $buildLog `
        -BinaryLogPath $binaryLog `
        -EnableCodeAnalysis:$RunCodeAnalysis
}
finally {
    Pop-Location
}

if ($RunCodeAnalysis) {
    $analysisLogText = Get-Content -Raw -LiteralPath $buildLog
    $analysisLogLines = Get-Content -LiteralPath $buildLog
    $analysisDiagnostics = @(
        [regex]::Matches(
            $analysisLogText,
            '(?im)^.*\b(?:warning|error)\s+[A-Z]+\d+\b.*$') |
            ForEach-Object { $_.Value.Trim() } |
            Sort-Object -Unique
    )
    if ($analysisDiagnostics.Count -ne 0) {
        $analysisDiagnostics | ForEach-Object { Write-Output "CODE_ANALYSIS_DIAGNOSTIC=$_" }
        throw "Code analysis produced $($analysisDiagnostics.Count) unique warning/error diagnostic(s)."
    }

    $analysisCommandLines = @(
        $analysisLogLines |
            Where-Object {
                $_ -match '(?i)\bCL\.exe\b' -and
                $_ -match '(?i)(?:^|\s)/analyze(?:\s|$)'
            }
    )
    if ($analysisCommandLines.Count -ne 1) {
        throw "Expected exactly one production /analyze compiler command, found $($analysisCommandLines.Count)."
    }

    $analysisCommand = $analysisCommandLines[0]
    $requiredAnalysisMarkers = @(
        'DriverMinimumRules.ruleset',
        'EspXEngine.dll',
        'WindowsPrefast.dll',
        'drivers.dll',
        'Capture.c',
        'CaptureCore.c',
        'Control.c',
        'Device.c',
        'Driver.c',
        'Ring.c',
        'TransportCore.c'
    )
    $missingAnalysisMarkers = @(
        $requiredAnalysisMarkers |
            Where-Object {
                $analysisCommand -notmatch [regex]::Escape($_)
            }
    )
    if ($missingAnalysisMarkers.Count -ne 0) {
        throw "Code analysis command is missing: $($missingAnalysisMarkers -join ', ')."
    }

    $uncodedDiagnostics = @(
        $analysisLogLines |
            Where-Object {
                $_ -match '(?i)\b(?:warning|error)\b' -and
                $_ -notmatch '(?i)[\\/]warning\.h\b' -and
                $_ -notmatch '(?i)\b(?:warning|error)\s+[A-Z]+\d+\b' -and
                $_ -notmatch '(?i)\b0\s+(?:warning|error)\(s\)'
            } |
            ForEach-Object { $_.Trim() } |
            Sort-Object -Unique
    )
    if ($uncodedDiagnostics.Count -ne 0) {
        $uncodedDiagnostics |
            ForEach-Object { Write-Output "CODE_ANALYSIS_UNCODED_DIAGNOSTIC=$_" }
        throw "Code analysis produced $($uncodedDiagnostics.Count) uncoded warning/error line(s)."
    }

    Write-Output 'CODE_ANALYSIS_DIAGNOSTIC_COUNT=0'
    Write-Output 'CODE_ANALYSIS_UNCODED_DIAGNOSTIC_COUNT=0'
    Write-Output "CODE_ANALYSIS_COMMAND_COUNT=$($analysisCommandLines.Count)"
    Write-Output "CODE_ANALYSIS_REQUIRED_MARKER_COUNT=$($requiredAnalysisMarkers.Count)"
}

$sysPath = Join-Path $outputDir 'CommMonitor.Driver.sys'
$infPath = Join-Path $outputDir 'CommMonitor.Driver.inf'
foreach ($buildOutput in @($sysPath, $infPath)) {
    if (-not (Test-Path -LiteralPath $buildOutput)) {
        throw "Expected driver output was not produced: $buildOutput"
    }
}

$infVerif = Get-ChildItem -LiteralPath $packagesDir -Filter 'InfVerif.exe' -Recurse |
    Where-Object { $_.FullName -match '\\tools\\10\.0\.26100\.0\\x64\\InfVerif\.exe$' } |
    Select-Object -First 1
if (-not $infVerif) {
    throw "InfVerif.exe was not restored under $packagesDir."
}

Write-Output "DRIVER_SYS=$sysPath"
Write-Output "DRIVER_INF=$infPath"
Write-Output "INFVERIF_EXE=$($infVerif.FullName)"
& $infVerif.FullName /w $infPath
$infVerifExitCode = $LASTEXITCODE
Write-Output "INFVERIF_EXIT_CODE=$infVerifExitCode"
if ($infVerifExitCode -ne 0) {
    throw "InfVerif /w failed with exit code $infVerifExitCode."
}
