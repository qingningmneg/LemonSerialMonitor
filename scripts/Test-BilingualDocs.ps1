[CmdletBinding()]
param(
    [string] $RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}

$pairs = [ordered]@{
    'README.md' = 'README.en.md'
    'docs/INSTALL.md' = 'docs/INSTALL.en.md'
    'docs/USER_GUIDE.md' = 'docs/USER_GUIDE.en.md'
    'docs/AI_INTEGRATION.md' = 'docs/AI_INTEGRATION.en.md'
    'docs/AI_API_REFERENCE.md' = 'docs/AI_API_REFERENCE.en.md'
    'docs/TROUBLESHOOTING.md' = 'docs/TROUBLESHOOTING.en.md'
    'docs/SECURITY.md' = 'docs/SECURITY.en.md'
    'docs/BUILD.md' = 'docs/BUILD.en.md'
    'docs/RELEASE_NOTES_0.1.0.md' = 'docs/RELEASE_NOTES_0.1.0.en.md'
}

$requiredSafetyTerms = @(
    'test certificate',
    'Secure Boot',
    'TESTSIGNING',
    'restart',
    'uninstall',
    'Windows Server',
    'not hardware certification'
)

$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)

function Read-StrictUtf8Document {
    param(
        [Parameter(Mandatory)][string] $FullPath,
        [Parameter(Mandatory)][string] $RelativePath
    )

    try {
        $bytes = [IO.File]::ReadAllBytes($FullPath)
        return $script:strictUtf8.GetString($bytes)
    } catch [Text.DecoderFallbackException] {
        throw "Invalid UTF-8 in $RelativePath`: $($_.Exception.Message)"
    }
}

function Test-MarkdownLinkToBasename {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Content,
        [Parameter(Mandatory)][string] $TargetBaseName
    )

    $escapedTarget = [regex]::Escape($TargetBaseName)
    $pattern = (
        '\]\(\s*<?(?:\./)?' +
        $escapedTarget +
        '(?:#[^>\s)]*)?>?(?:\s+"[^"]*")?\s*\)')
    return [regex]::IsMatch(
        $Content,
        $pattern,
        [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

$root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Repository root not found: $root"
}

$documents = @{}
foreach ($pair in $pairs.GetEnumerator()) {
    foreach ($relativePath in @($pair.Key, $pair.Value)) {
        $fullPath = Join-Path $root $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Bilingual document not found: $relativePath"
        }

        $documents[$relativePath] = Read-StrictUtf8Document `
            -FullPath $fullPath `
            -RelativePath $relativePath
    }
}

foreach ($pair in $pairs.GetEnumerator()) {
    $chineseRelativePath = $pair.Key
    $englishRelativePath = $pair.Value
    $chineseBaseName = [IO.Path]::GetFileName($chineseRelativePath)
    $englishBaseName = [IO.Path]::GetFileName($englishRelativePath)

    if (-not (Test-MarkdownLinkToBasename `
            -Content $documents[$chineseRelativePath] `
            -TargetBaseName $englishBaseName)) {
        throw "$chineseRelativePath does not link to $englishBaseName"
    }
    if (-not (Test-MarkdownLinkToBasename `
            -Content $documents[$englishRelativePath] `
            -TargetBaseName $chineseBaseName)) {
        throw "$englishRelativePath does not link to $chineseBaseName"
    }
}

$placeholderPattern = '\b(?:TBD|TODO|FIXME)\b'
foreach ($relativePath in $documents.Keys) {
    $match = [regex]::Match(
        $documents[$relativePath],
        $placeholderPattern,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($match.Success) {
        throw "Placeholder marker $($match.Value) found in $relativePath"
    }
}

$installerAssetName = 'LemonSerialMonitor-Setup-x64.exe'
if ($documents['README.md'].IndexOf(
        $installerAssetName,
        [StringComparison]::Ordinal) -lt 0) {
    throw "README.md must contain installer asset name $installerAssetName"
}

$englishCorpus = @(
    foreach ($englishRelativePath in $pairs.Values) {
        $documents[$englishRelativePath]
    }
) -join "`n"
foreach ($term in $requiredSafetyTerms) {
    if ($englishCorpus.IndexOf($term, [StringComparison]::Ordinal) -lt 0) {
        throw "English documentation is missing required safety term: $term"
    }
}

Write-Output "BILINGUAL_DOCS_OK=$($pairs.Count)"
