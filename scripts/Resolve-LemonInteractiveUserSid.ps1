[CmdletBinding()]
param(
    [AllowEmptyString()][string] $AccountName,
    [Parameter(Mandatory)][string] $ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-LemonAccountSid {
    param([Parameter(Mandatory)][string] $Name)

    try {
        $account = [Security.Principal.NTAccount]::new($Name)
        $sid = $account.Translate(
            [Security.Principal.SecurityIdentifier])
        if ($sid.Value -notmatch '^S-1-5-21-(?:\d+-){3}\d+$') {
            return $null
        }
        $profileKey = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' +
            $sid.Value
        $profile = Get-ItemProperty `
            -LiteralPath $profileKey `
            -Name ProfileImagePath `
            -ErrorAction SilentlyContinue
        if ($null -eq $profile -or
            [string]::IsNullOrWhiteSpace([string]$profile.ProfileImagePath)) {
            return $null
        }
        return $sid.Value
    }
    catch {
        return $null
    }
}

$candidateNames = [Collections.Generic.List[string]]::new()
if (-not [string]::IsNullOrWhiteSpace($AccountName)) {
    $candidateNames.Add($AccountName.Trim())
}
try {
    $interactiveName = [string](Get-CimInstance `
            -ClassName Win32_ComputerSystem `
            -ErrorAction Stop).UserName
    if (-not [string]::IsNullOrWhiteSpace($interactiveName) -and
        -not $candidateNames.Contains($interactiveName)) {
        $candidateNames.Add($interactiveName)
    }
}
catch {
    # A minimal Server Core image can lack the CIM provider during servicing.
}
$currentName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if (-not [string]::IsNullOrWhiteSpace($currentName) -and
    -not $candidateNames.Contains($currentName)) {
    $candidateNames.Add($currentName)
}

$resolvedSid = $null
foreach ($candidateName in $candidateNames) {
    $resolvedSid = Resolve-LemonAccountSid -Name $candidateName
    if (-not [string]::IsNullOrWhiteSpace($resolvedSid)) {
        break
    }
}
if ([string]::IsNullOrWhiteSpace($resolvedSid)) {
    throw 'No interactive Windows user with a local profile could be resolved.'
}

$fullResultPath = [IO.Path]::GetFullPath($ResultPath)
$parent = Split-Path -Parent $fullResultPath
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($parent)
}
$temporaryPath = $fullResultPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
try {
    [IO.File]::WriteAllText(
        $temporaryPath,
        $resolvedSid,
        [Text.UTF8Encoding]::new($false))
    Move-Item `
        -LiteralPath $temporaryPath `
        -Destination $fullResultPath `
        -Force
}
finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}
