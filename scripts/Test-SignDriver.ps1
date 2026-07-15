[CmdletBinding()]
param(
    [string] $DriverDirectory,

    [string] $WdkSearchRoot,

    [string] $TimestampUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$subject = 'CN=Lemon Serial Monitor Local Test Driver'
$certificateFileName = 'CommMonitor.LocalTestDriver.cer'
if ([string]::IsNullOrWhiteSpace($DriverDirectory)) {
    $scriptParent = Split-Path -Parent $PSScriptRoot
    $packagedDriverDirectory = Join-Path $scriptParent 'driver'
    $DriverDirectory = if (Test-Path -LiteralPath $packagedDriverDirectory) {
        $packagedDriverDirectory
    }
    else {
        Join-Path $scriptParent 'artifacts\phase1\driver'
    }
}
$resolvedDriverDirectory = [IO.Path]::GetFullPath($DriverDirectory)
$sysPath = Join-Path $resolvedDriverDirectory 'CommMonitor.Driver.sys'
$infPath = Join-Path $resolvedDriverDirectory 'CommMonitor.Driver.inf'
$catPath = Join-Path $resolvedDriverDirectory 'CommMonitor.Driver.cat'
$certificatePath = Join-Path $resolvedDriverDirectory $certificateFileName

foreach ($requiredFile in @($sysPath, $infPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Driver signing input not found: $requiredFile"
    }
}

function Find-WdkTool {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][bool] $RequireX64
    )

    $candidates = [Collections.Generic.List[string]]::new()
    if ($WdkSearchRoot) {
        $candidates.Add([IO.Path]::GetFullPath($WdkSearchRoot))
    }
    $candidates.Add((Join-Path (Split-Path -Parent $PSScriptRoot) `
        'artifacts\driver\packages'))
    $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'))

    foreach ($root in $candidates) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $matches = @(Get-ChildItem `
            -LiteralPath $root `
            -Filter $Name `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -match '10\.0\.26100(?:\.0|\.6584)' -and
                (-not $RequireX64 -or $_.FullName -match '[\\/]x64[\\/]')
            } |
            Sort-Object FullName)
        if ($matches.Count -gt 0) {
            return $matches[0].FullName
        }
    }

    throw "WDK 26100 tool '$Name' was not found."
}

function Invoke-SigningTool {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $ArgumentList
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Signing command failed ($LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
    }
}

$signTool = Find-WdkTool -Name 'signtool.exe' -RequireX64 $true
$inf2Cat = Find-WdkTool -Name 'Inf2Cat.exe' -RequireX64 $false

$certificate = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object {
        $_.Subject -eq $subject -and
        $_.HasPrivateKey -and
        $_.NotAfter -gt (Get-Date).AddDays(30)
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
if ($null -eq $certificate) {
    $certificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $subject `
        -CertStoreLocation Cert:\CurrentUser\My `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -HashAlgorithm SHA256 `
        -KeyExportPolicy NonExportable `
        -NotAfter (Get-Date).AddYears(5)
}

$privateKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey(
    $certificate)
if ($null -eq $privateKey) {
    throw 'The selected Lemon serial monitor signing certificate has no accessible RSA private key.'
}
try {
    if ($privateKey -is [Security.Cryptography.RSACng] -and
        $privateKey.Key.ExportPolicy -ne
            [Security.Cryptography.CngExportPolicies]::None) {
        throw 'The selected Lemon serial monitor signing certificate has an exportable private key.'
    }
    if ($privateKey -is [Security.Cryptography.RSACryptoServiceProvider] -and
        $privateKey.CspKeyContainerInfo.Exportable) {
        throw 'The selected Lemon serial monitor signing certificate has an exportable private key.'
    }
}
finally {
    $privateKey.Dispose()
}

Export-Certificate `
    -Cert $certificate `
    -FilePath $certificatePath `
    -Force | Out-Null

$signArguments = @(
    'sign',
    '/v',
    '/fd', 'SHA256',
    '/sha1', $certificate.Thumbprint,
    '/s', 'My'
)
if ($TimestampUrl) {
    $signArguments += @('/tr', $TimestampUrl, '/td', 'SHA256')
}

# Inf2Cat must hash the final signed SYS, so embedded signing comes first.
Invoke-SigningTool -FilePath $signTool -ArgumentList ($signArguments + $sysPath)
if (Test-Path -LiteralPath $catPath) {
    Remove-Item -LiteralPath $catPath -Force
}
Invoke-SigningTool -FilePath $inf2Cat -ArgumentList @(
    "/driver:$resolvedDriverDirectory",
    '/os:10_X64',
    '/verbose')
if (-not (Test-Path -LiteralPath $catPath -PathType Leaf)) {
    throw "Inf2Cat did not produce the expected catalog: $catPath"
}
Invoke-SigningTool -FilePath $signTool -ArgumentList ($signArguments + $catPath)

# Trust only in CurrentUser while verifying, then restore the prior trust state.
$rootWasPresent = Test-Path -LiteralPath (
    "Cert:\CurrentUser\Root\$($certificate.Thumbprint)")
$publisherWasPresent = Test-Path -LiteralPath (
    "Cert:\CurrentUser\TrustedPublisher\$($certificate.Thumbprint)")
try {
    if (-not $rootWasPresent) {
        Import-Certificate `
            -FilePath $certificatePath `
            -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    }
    if (-not $publisherWasPresent) {
        Import-Certificate `
            -FilePath $certificatePath `
            -CertStoreLocation Cert:\CurrentUser\TrustedPublisher | Out-Null
    }

    foreach ($file in @($sysPath, $catPath)) {
        Invoke-SigningTool -FilePath $signTool -ArgumentList @(
            'verify', '/pa', '/v', $file)
        $signature = Get-AuthenticodeSignature -LiteralPath $file
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            $null -eq $signature.SignerCertificate -or
            $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) {
            throw "Authenticode verification failed for '$file': $($signature.StatusMessage)"
        }
    }
    foreach ($catalogMember in @($infPath, $sysPath)) {
        Invoke-SigningTool -FilePath $signTool -ArgumentList @(
            'verify', '/pa', '/v', '/c', $catPath, $catalogMember)
    }
}
finally {
    if (-not $publisherWasPresent) {
        Remove-Item -LiteralPath (
            "Cert:\CurrentUser\TrustedPublisher\$($certificate.Thumbprint)") `
            -Force `
            -ErrorAction SilentlyContinue
    }
    if (-not $rootWasPresent) {
        Remove-Item -LiteralPath (
            "Cert:\CurrentUser\Root\$($certificate.Thumbprint)") `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

Write-Output "SIGNTOOL=$signTool"
Write-Output "INF2CAT=$inf2Cat"
Write-Output "CERTIFICATE_THUMBPRINT=$($certificate.Thumbprint)"
Write-Output "CERTIFICATE_PUBLIC_KEY=$certificatePath"
Write-Output "SIGNED_SYS=$sysPath"
Write-Output "SIGNED_CAT=$catPath"
Write-Output 'SIGNATURE_VERIFICATION=PASS'
