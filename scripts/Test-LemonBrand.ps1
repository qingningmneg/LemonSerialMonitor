[CmdletBinding()]
param(
    [string] $RepositoryRoot,

    [string[]] $Paths
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}

function Get-ForbiddenVisibleBrand {
    $tail = -join ([char[]]@(
            0x4E32,
            0x53E3,
            0x76D1,
            0x63A7,
            0x7CBE,
            0x7075))
    return 'Comm' + 'Monitor ' + $tail
}

function Test-BytesContainText {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][string] $Text
    )

    foreach ($encoding in @(
            [Text.UTF8Encoding]::new($false, $false),
            [Text.UnicodeEncoding]::new($false, $true, $false),
            [Text.UnicodeEncoding]::new($true, $true, $false),
            [Text.UTF32Encoding]::new($false, $true, $false),
            [Text.UTF32Encoding]::new($true, $true, $false))) {
        $decoded = $encoding.GetString($Bytes)
        if ($decoded.IndexOf(
                $Text,
                [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}

$root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Repository root not found: $root"
}

if ($null -eq $Paths -or $Paths.Count -eq 0) {
    $relativePaths = @(
        & git `
            -C $root `
            -c core.quotepath=false `
            ls-files `
            --cached `
            --others `
            --exclude-standard
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to enumerate repository files (git exit $LASTEXITCODE)."
    }
    $Paths = @(
        $relativePaths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique |
            ForEach-Object { Join-Path $root $_ }
    )
}

$forbidden = Get-ForbiddenVisibleBrand
$rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
$violations = [Collections.Generic.List[string]]::new()
foreach ($candidatePath in @($Paths)) {
    $fullPath = [IO.Path]::GetFullPath($candidatePath)
    if (-not $fullPath.StartsWith(
            $rootPrefix,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to scan a path outside the repository: $fullPath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        continue
    }

    $relativePath = $fullPath.Substring($rootPrefix.Length)
    if ($relativePath.IndexOf(
            $forbidden,
            [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $violations.Add("path:$relativePath")
        continue
    }

    $item = Get-Item -LiteralPath $fullPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to follow a reparse point during brand scan: $relativePath"
    }

    $bytes = [IO.File]::ReadAllBytes($fullPath)
    if (Test-BytesContainText -Bytes $bytes -Text $forbidden) {
        $violations.Add("content:$relativePath")
    }
}

if ($violations.Count -ne 0) {
    throw "Forbidden legacy visible brand found in $($violations.Count) file(s): $($violations -join '; ')"
}

Write-Output "BRAND_GUARD_OK=$(@($Paths).Count)"
