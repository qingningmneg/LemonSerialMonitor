$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'scripts\Lemon.SetupTransactions.psm1') -Force

function New-TestPayload {
    param([Parameter(Mandatory)][string] $Root)

    New-Item -ItemType Directory -Path (Join-Path $Root 'app') -Force |
        Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $Root 'app\sample.bin'),
        'trusted payload',
        [Text.UTF8Encoding]::new($false))
    $hash = (Get-FileHash `
            -LiteralPath (Join-Path $Root 'app\sample.bin') `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        (Join-Path $Root 'SHA256SUMS.txt'),
        "$hash  app/sample.bin`n",
        [Text.UTF8Encoding]::new($false))
}

Describe 'Lemon payload manifest validation' {
    It 'accepts an exact file set with matching SHA-256' {
        $root = Join-Path $TestDrive 'valid'
        New-TestPayload -Root $root

        $result = Assert-LemonPayloadManifest -PackageRoot $root

        $result.FileCount | Should Be 1
    }

    It 'rejects a payload file changed after manifest creation' {
        $root = Join-Path $TestDrive 'tampered'
        New-TestPayload -Root $root
        Add-Content -LiteralPath (Join-Path $root 'app\sample.bin') -Value 'x'

        { Assert-LemonPayloadManifest -PackageRoot $root } | Should Throw
    }

    It 'rejects unlisted and missing payload files' {
        $root = Join-Path $TestDrive 'extra'
        New-TestPayload -Root $root
        [IO.File]::WriteAllText(
            (Join-Path $root 'extra.bin'),
            'extra',
            [Text.UTF8Encoding]::new($false))

        { Assert-LemonPayloadManifest -PackageRoot $root } | Should Throw
    }

    It 'rejects traversal and duplicate manifest paths' {
        $root = Join-Path $TestDrive 'unsafe'
        New-TestPayload -Root $root
        $hash = 'a' * 64
        [IO.File]::WriteAllText(
            (Join-Path $root 'SHA256SUMS.txt'),
            "$hash  ../outside.bin`n",
            [Text.UTF8Encoding]::new($false))
        { Assert-LemonPayloadManifest -PackageRoot $root } | Should Throw

        New-TestPayload -Root $root
        $validHash = (Get-FileHash `
                -LiteralPath (Join-Path $root 'app\sample.bin') `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText(
            (Join-Path $root 'SHA256SUMS.txt'),
            "$validHash  app/sample.bin`n$validHash  APP/SAMPLE.BIN`n",
            [Text.UTF8Encoding]::new($false))
        { Assert-LemonPayloadManifest -PackageRoot $root } | Should Throw
    }
}
