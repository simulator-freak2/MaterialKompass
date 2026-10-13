[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*$')]
    [string]$Server = '31.70.106.152',
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_.-]*$')]
    [string]$SshUser = 'materialkompass-deploy',
    [ValidatePattern('^/[A-Za-z0-9._/-]+$')]
    [string]$RemotePath = '/opt/materialkompass',
    [string]$IdentityFile,
    [Parameter(Mandatory)] [string]$KnownHostsFile,
    [Parameter(Mandatory)] [ValidateSet('release', 'maintenance')] [string]$Type,
    [Parameter(Mandatory)] [ValidateLength(1, 120)] [string]$Title,
    [Parameter(Mandatory)] [ValidateLength(1, 4000)] [string]$Message,
    [ValidatePattern('^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$')] [string]$Version,
    [datetime]$StartsAt,
    [datetime]$EndsAt,
    [string]$Id
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($RemotePath.Contains('..')) { throw 'RemotePath darf kein .. enthalten.' }
if ($Type -eq 'release' -and -not $Version) { throw 'Releasehinweise benoetigen eine Version.' }
if ($Type -eq 'maintenance' -and
    ($StartsAt -eq [datetime]::MinValue -or $EndsAt -eq [datetime]::MinValue -or $StartsAt -ge $EndsAt)) {
    throw 'Wartungshinweise benoetigen einen gueltigen Beginn und ein spaeteres Ende.'
}

$knownHosts = (Resolve-Path -LiteralPath $KnownHostsFile).Path
if (-not (& ssh-keygen -F $Server -f $knownHosts 2>$null)) {
    throw "Fuer $Server fehlt ein gepruefter SSH-Hostschluessel."
}
$sshOptions = @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$knownHosts")
if ($IdentityFile) {
    $sshOptions += @('-o', 'IdentitiesOnly=yes', '-i', (Resolve-Path -LiteralPath $IdentityFile).Path)
}
$target = "$SshUser@$Server"
$remoteFile = "$RemotePath/.deployments/public-messages.json"
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "materialkompass-message-$PID-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
try {
    $localFile = Join-Path $temporaryDirectory 'public-messages.json'
    & scp @sshOptions "${target}:$remoteFile" $localFile
    if ($LASTEXITCODE -ne 0) {
        throw 'Die vorhandenen Systemnachrichten konnten nicht sicher gelesen werden. Zuerst das Backend-Deployment ausfuehren.'
    }
    if ((Get-Item -LiteralPath $localFile).Length -gt 524288) {
        throw 'Die vorhandene Systemnachrichtendatei ist zu gross.'
    }
    $originalHash = (Get-FileHash -LiteralPath $localFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $document = Get-Content -LiteralPath $localFile -Raw | ConvertFrom-Json
    if ($document.schemaVersion -ne 1 -or $null -eq $document.messages -or @($document.messages).Count -gt 100) {
        throw 'Die vorhandene Systemnachrichtendatei ist ungueltig.'
    }
    $messageId = if ($Id) { $Id } elseif ($Type -eq 'release') {
        "release-$Version"
    } else {
        "maintenance-$($StartsAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))"
    }
    if ($messageId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
        throw 'Die Nachrichten-ID ist ungueltig.'
    }
    $messages = @($document.messages | Where-Object { $_.id -ne $messageId })
    $entry = [ordered]@{
        id = $messageId
        type = $Type
        title = $Title.Trim()
        message = $Message.Trim()
        publishedAt = [datetime]::UtcNow.ToString('o')
    }
    if ($Type -eq 'release') { $entry.version = $Version }
    else {
        $entry.startsAt = $StartsAt.ToUniversalTime().ToString('o')
        $entry.endsAt = $EndsAt.ToUniversalTime().ToString('o')
    }
    $messages = @($entry) + $messages | Select-Object -First 100
    $output = [ordered]@{ schemaVersion = 1; messages = @($messages) } | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($localFile, $output, [Text.UTF8Encoding]::new($false))
    $stage = "$remoteFile.new-$PID"
    & scp @sshOptions $localFile "${target}:$stage"
    if ($LASTEXITCODE -ne 0) {
        & ssh @sshOptions $target "rm -f -- '$stage'" 2>$null
        throw 'Systemnachricht konnte nicht uebertragen werden.'
    }
    $expected = (Get-FileHash -LiteralPath $localFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $command = "set -eu; test ! -L '$remoteFile'; test `"`$(sha256sum '$remoteFile' | cut -d ' ' -f 1)`" = '$originalHash'; test `"`$(sha256sum '$stage' | cut -d ' ' -f 1)`" = '$expected'; chmod 0644 '$stage'; mv -f '$stage' '$remoteFile'"
    & ssh @sshOptions $target $command
    if ($LASTEXITCODE -ne 0) {
        & ssh @sshOptions $target "rm -f -- '$stage'" 2>$null
        throw 'Systemnachricht konnte nicht atomar veroeffentlicht werden. Moeglicherweise wurde sie parallel geaendert.'
    }
    Write-Host "Systemnachricht '$messageId' wurde veroeffentlicht."
}
finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
