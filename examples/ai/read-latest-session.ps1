[CmdletBinding()]
param(
    [string] $ClientPath = 'C:\Program Files\Lemon串口监控\ai\Lemon.SerialMonitor.AI.exe',
    [string] $OutputPath = (Join-Path $PWD 'lemon-events.jsonl'),
    [ValidateRange(1, 1000)][int] $PageSize = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ClientPath -PathType Leaf)) {
    throw "AI client not found: $ClientPath"
}

function Invoke-LemonJson {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $text = (& $ClientPath @Arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Lemon AI client failed with exit code $LASTEXITCODE`: $text"
    }
    return $text | ConvertFrom-Json
}

$status = Invoke-LemonJson -Arguments @('status', '--json')
$sessionPage = Invoke-LemonJson -Arguments @(
    'sessions', 'list', '--limit', '1000', '--json')
$latest = @($sessionPage.sessions) |
    Sort-Object { [DateTimeOffset]$_.startedUtc } -Descending |
    Select-Object -First 1
if ($null -eq $latest) {
    throw 'No persisted sessions were found.'
}

$output = [IO.Path]::GetFullPath($OutputPath)
$writer = [IO.StreamWriter]::new($output, $false, [Text.UTF8Encoding]::new($false))
try {
    $cursor = $null
    $receipt = $null
    do {
        $arguments = [Collections.Generic.List[string]]::new()
        $arguments.AddRange([string[]]@(
            'events', 'read',
            '--session-id', [string]$latest.sessionId,
            '--limit', [string]$PageSize,
            '--include-hex',
            '--include-text-preview',
            '--json'))
        if (-not [string]::IsNullOrWhiteSpace($cursor)) {
            $arguments.Add('--cursor')
            $arguments.Add($cursor)
            $arguments.Add('--resume-receipt')
            $arguments.Add($receipt)
        }

        $page = Invoke-LemonJson -Arguments $arguments.ToArray()
        foreach ($event in @($page.events)) {
            $writer.WriteLine(($event | ConvertTo-Json -Depth 12 -Compress))
        }
        if (-not [bool]$page.integrity.completeForReturnedRange) {
            Write-Warning 'The returned range is not proven complete. Inspect integrity and warnings.'
        }
        $cursor = [string]$page.nextCursor
        $receipt = [string]$page.resumeReceipt
    } while ([bool]$page.hasMore)
}
finally {
    $writer.Dispose()
}

[pscustomobject]@{
    ServiceState = $status.serviceState
    SessionId = $latest.sessionId
    SessionName = $latest.displayName
    OutputPath = $output
} | Format-List
