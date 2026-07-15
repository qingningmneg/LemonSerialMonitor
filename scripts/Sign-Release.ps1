[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $FilePath,
    [Parameter(Mandatory)][string] $CertificateThumbprint,
    [string] $TimestampUrl,
    [string] $WdkSearchRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedFilePath = [IO.Path]::GetFullPath($FilePath)
if (-not (Test-Path -LiteralPath $resolvedFilePath -PathType Leaf)) {
    throw "Signing input was not found: $resolvedFilePath"
}
$normalizedThumbprint = $CertificateThumbprint.Replace(' ', '').ToUpperInvariant()
if ($normalizedThumbprint -notmatch '^[0-9A-F]{40}$') {
    throw 'CertificateThumbprint must be one exact SHA-1 certificate thumbprint.'
}

function Find-LemonSignTool {
    $roots = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($WdkSearchRoot)) {
        $roots.Add([IO.Path]::GetFullPath($WdkSearchRoot))
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $roots.Add((Join-Path $repoRoot 'artifacts\driver\packages'))
    $roots.Add((Join-Path ([IO.Path]::GetTempPath()) `
        'CommMonitor-WdkPackages-BuildAll'))
    $roots.Add((Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'))

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        $candidate = Get-ChildItem `
            -LiteralPath $root `
            -Filter signtool.exe `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -match '10\.0\.26100(?:\.0|\.6584)' -and
                $_.FullName -match '[\\/]x64[\\/]'
            } |
            Sort-Object FullName |
            Select-Object -First 1
        if ($null -ne $candidate) {
            return $candidate.FullName
        }
    }
    throw 'WDK 10.0.26100 x64 signtool.exe was not found.'
}

function Test-LemonCertificateInStore {
    param(
        [Parameter(Mandatory)][string] $StoreName,
        [Parameter(Mandatory)][string] $Thumbprint
    )

    return Test-Path -LiteralPath (
        "Cert:\CurrentUser\$StoreName\$Thumbprint")
}

function Add-LemonCertificateToStore {
    param(
        [Parameter(Mandatory)][string] $StoreName,
        [Parameter(Mandatory)]
        [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )

    $store = [Security.Cryptography.X509Certificates.X509Store]::new(
        $StoreName,
        [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    try {
        $store.Open(
            [Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($Certificate)
    }
    finally {
        $store.Dispose()
    }
}

function Remove-LemonCertificateFromStore {
    param(
        [Parameter(Mandatory)][string] $StoreName,
        [Parameter(Mandatory)]
        [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )

    $store = [Security.Cryptography.X509Certificates.X509Store]::new(
        $StoreName,
        [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    try {
        $store.Open(
            [Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Remove($Certificate)
    }
    finally {
        $store.Dispose()
    }
}

$certificate = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object {
        $_.Thumbprint -eq $normalizedThumbprint -and
        $_.HasPrivateKey -and
        $_.NotBefore -le (Get-Date) -and
        $_.NotAfter -gt (Get-Date)
    } |
    Select-Object -First 1
if ($null -eq $certificate) {
    throw 'The requested current-user code-signing certificate is unavailable.'
}
$hasCodeSigningEku = @($certificate.Extensions | Where-Object {
        $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]
    } | ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value }) `
    -contains '1.3.6.1.5.5.7.3.3'
if (-not $hasCodeSigningEku) {
    throw 'The requested certificate is not valid for code signing.'
}

$privateKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey(
    $certificate)
if ($null -eq $privateKey) {
    throw 'The requested code-signing certificate has no accessible RSA key.'
}
try {
    if ($privateKey -is [Security.Cryptography.RSACng] -and
        $privateKey.Key.ExportPolicy -ne
            [Security.Cryptography.CngExportPolicies]::None) {
        throw 'Refusing a code-signing certificate with an exportable private key.'
    }
    if ($privateKey -is [Security.Cryptography.RSACryptoServiceProvider] -and
        $privateKey.CspKeyContainerInfo.Exportable) {
        throw 'Refusing a code-signing certificate with an exportable private key.'
    }
}
finally {
    $privateKey.Dispose()
}

$signTool = Find-LemonSignTool
$arguments = @(
    'sign',
    '/v',
    '/fd', 'SHA256',
    '/sha1', $normalizedThumbprint,
    '/s', 'My')
if (-not [string]::IsNullOrWhiteSpace($TimestampUrl)) {
    $timestampUri = $null
    if (-not [Uri]::TryCreate(
            $TimestampUrl,
            [UriKind]::Absolute,
            [ref]$timestampUri) -or
        $timestampUri.Scheme -ne 'https') {
        throw 'TimestampUrl must be an absolute HTTPS URL.'
    }
    $arguments += @('/tr', $timestampUri.AbsoluteUri, '/td', 'SHA256')
}

& $signTool @arguments $resolvedFilePath
if ($LASTEXITCODE -ne 0) {
    throw "signtool sign failed with exit code $LASTEXITCODE."
}

$rootWasPresent = Test-LemonCertificateInStore `
    -StoreName Root `
    -Thumbprint $normalizedThumbprint
$publisherWasPresent = Test-LemonCertificateInStore `
    -StoreName TrustedPublisher `
    -Thumbprint $normalizedThumbprint
try {
    if (-not $rootWasPresent) {
        Add-LemonCertificateToStore -StoreName Root -Certificate $certificate
    }
    if (-not $publisherWasPresent) {
        Add-LemonCertificateToStore `
            -StoreName TrustedPublisher `
            -Certificate $certificate
    }

    & $signTool verify /pa /v $resolvedFilePath
    if ($LASTEXITCODE -ne 0) {
        throw "signtool verification failed with exit code $LASTEXITCODE."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $resolvedFilePath
    if ($signature.Status -ne
            [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ne $normalizedThumbprint) {
        throw "Authenticode verification failed: $($signature.StatusMessage)"
    }
}
finally {
    if (-not $publisherWasPresent) {
        Remove-LemonCertificateFromStore `
            -StoreName TrustedPublisher `
            -Certificate $certificate
    }
    if (-not $rootWasPresent) {
        Remove-LemonCertificateFromStore `
            -StoreName Root `
            -Certificate $certificate
    }
}

Write-Output "SIGNED_FILE=$resolvedFilePath"
Write-Output "SIGNER_THUMBPRINT=$normalizedThumbprint"
Write-Output "SIGNTOOL=$signTool"
