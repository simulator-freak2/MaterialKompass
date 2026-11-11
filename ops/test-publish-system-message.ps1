$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$directory = Join-Path ([IO.Path]::GetTempPath()) ('mk-publish-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
$global:mkPublishTestRemote = Join-Path $directory 'remote.json'
$global:mkPublishTestStaged = Join-Path $directory 'staged.json'
$knownHosts = Join-Path $directory 'known_hosts'
[IO.File]::WriteAllText($knownHosts, 'test-host')
# Construct Unicode without relying on the test runner's source-file encoding.
$text = 'Umlaut: ' + [char]0x00dc + [char]0x00e4 + [char]0x00f6 + [char]0x00df + ' ' + [char]0x2013
$initial = @{ schemaVersion = 1; messages = @(@{
    id = 'release-1.0.0'; type = 'release'; version = '1.0.0'
    title = 'Initial'; message = $text; publishedAt = '2026-01-01T00:00:00Z'
}) } | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($global:mkPublishTestRemote, $initial, [Text.UTF8Encoding]::new($false))

# Keep the actual publication script and serialization; replace only SSH transport.
function ssh-keygen { $global:LASTEXITCODE = 0; 'test-host' }
function scp {
    $source = $args[$args.Count - 2]
    $destination = $args[$args.Count - 1]
    if ($source -like '*:/*') {
        Copy-Item -LiteralPath $global:mkPublishTestRemote -Destination $destination
    } else {
        Copy-Item -LiteralPath $source -Destination $global:mkPublishTestStaged -Force
    }
    $global:LASTEXITCODE = 0
}
function ssh {
    Copy-Item -LiteralPath $global:mkPublishTestStaged -Destination $global:mkPublishTestRemote -Force
    $global:LASTEXITCODE = 0
}
try {
    for ($index = 1; $index -le 12; $index++) {
        & (Join-Path $PSScriptRoot 'publish-system-message.ps1') -Server test-host `
            -KnownHostsFile $knownHosts -Type release -Title 'Release' `
            -Message $text -Version "1.0.$index"
        $result = Get-Content -LiteralPath $global:mkPublishTestRemote -Raw -Encoding UTF8 | ConvertFrom-Json
        if (@($result.messages).Count -ne $index + 1) { throw 'Message history was lost.' }
        foreach ($entry in $result.messages) {
            if ($entry.message -cne $text) { throw 'UTF-8 text changed during publication.' }
        }
    }
    # A malformed legacy text must also be blocked before upload.
    $legacy = $result
    $legacy.messages[0].message = 'x' * 4001
    [IO.File]::WriteAllText($global:mkPublishTestRemote, ($legacy | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $before = (Get-FileHash -LiteralPath $global:mkPublishTestRemote).Hash
    $blocked = $false
    try {
        & (Join-Path $PSScriptRoot 'publish-system-message.ps1') -Server test-host `
            -KnownHostsFile $knownHosts -Type release -Title 'Release' -Message 'Valid' -Version '3.0.0'
    } catch {
        if ($_.Exception.Message -notlike '*Textlaenge*') { throw }
        $blocked = $true
    }
    if (-not $blocked -or (Get-FileHash -LiteralPath $global:mkPublishTestRemote).Hash -ne $before) {
        throw 'Oversized legacy text was published.'
    }
    Write-Host 'PASS: 12 UTF-8 publication cycles preserve history; oversized legacy text is blocked.'
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
    Remove-Variable -Name mkPublishTestRemote, mkPublishTestStaged -Scope Global
}
