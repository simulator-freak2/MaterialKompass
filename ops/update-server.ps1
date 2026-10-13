[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*$')]
    [string]$Server = '31.70.106.152',
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_.-]*$')]
    [string]$SshUser = 'materialkompass-deploy',
    [ValidatePattern('^/[A-Za-z0-9._/-]+$')]
    [string]$RemotePath = '/opt/materialkompass',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')]
    [string]$Branch = 'main',
    [string]$IdentityFile,
    [Parameter(Mandatory)]
    [string]$KnownHostsFile,
    [ValidatePattern('^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [switch]$DeployBackend,
    [switch]$UploadWeb,
    [switch]$UploadReleases,
    [switch]$SkipChecks,
    [switch]$SkipPush,
    [switch]$AllowUnsigned,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Checked {
    param(
        [Parameter(Mandatory)] [string]$Program,
        [Parameter(Mandatory)] [string[]]$Arguments
    )
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Befehl fehlgeschlagen ($LASTEXITCODE): $Program" }
}

if ($Branch.Contains('..') -or $Branch.Contains('//') -or $Branch.EndsWith('/')) {
    throw 'Der Branchname ist nicht sicher.'
}
if ($RemotePath.Contains('..')) { throw 'RemotePath darf kein .. enthalten.' }
if (-not ($DeployBackend -or $UploadWeb -or $UploadReleases)) {
    throw 'Mindestens DeployBackend, UploadWeb oder UploadReleases muss ausgewaehlt sein.'
}
if (($UploadWeb -or $UploadReleases) -and -not $Version) {
    throw 'Fuer Web- oder Installer-Updates ist -Version erforderlich.'
}

$knownHosts = (Resolve-Path -LiteralPath $KnownHostsFile).Path
$knownHostMatch = & ssh-keygen -F $Server -f $knownHosts 2>$null
if ($LASTEXITCODE -ne 0 -or -not $knownHostMatch) {
    throw "Fuer $Server wurde kein gepruefter Hostschluessel in $knownHosts gefunden."
}
$resolvedIdentity = if ($IdentityFile) { (Resolve-Path -LiteralPath $IdentityFile).Path } else { $null }
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sshOptions = @(
    '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
    '-o', "UserKnownHostsFile=$knownHosts",
    '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3'
)
if ($resolvedIdentity) { $sshOptions += @('-o', 'IdentitiesOnly=yes', '-i', $resolvedIdentity) }
$target = "$SshUser@$Server"

if ($DryRun) {
    Write-Host 'SICHERHEITSVORSCHAU - es werden keine Aenderungen ausgefuehrt.'
    Write-Host "Ziel: $target $RemotePath ($Branch)"
    Write-Host "Backend: $DeployBackend | Web: $UploadWeb | Installer: $UploadReleases"
    Write-Host "Version: $Version | Pruefungen ueberspringen: $SkipChecks | Push ueberspringen: $SkipPush"
    exit 0
}

Push-Location $repositoryRoot
try {
    $changes = & git status --porcelain
    if ($LASTEXITCODE -ne 0) { throw 'Git-Status konnte nicht gelesen werden.' }
    if ($changes) {
        throw "Vor einem Deployment muessen alle Aenderungen geprueft und committed sein.`n$($changes -join [Environment]::NewLine)"
    }
    $currentBranch = (& git branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or $currentBranch -ne $Branch) {
        throw "Erwarteter Branch: $Branch; aktueller Branch: $currentBranch."
    }

    if (-not $SkipChecks) {
        Invoke-Checked npm @('--prefix', 'backend', 'test')
        Invoke-Checked node @('--test', 'mailbox-provisioner/server.test.js')
        Push-Location flutter
        try {
            Invoke-Checked flutter @('analyze')
            Invoke-Checked flutter @('test')
        }
        finally { Pop-Location }
    }

    if ($DeployBackend) {
        if (-not $SkipPush) { Invoke-Checked git @('push', 'origin', "HEAD:refs/heads/$Branch") }
        $remoteCommand = "cd '$RemotePath' && git fetch origin '$Branch' && git show FETCH_HEAD:ops/update-server.sh | sh -s -- '$Branch' '$RemotePath'"
        Invoke-Checked ssh ($sshOptions + @($target, $remoteCommand))
    }

    if ($UploadWeb -or $UploadReleases) {
        $files = [Collections.Generic.List[string]]::new()
        if ($UploadWeb) {
            $webArchive = Join-Path $repositoryRoot 'releases/MaterialKompass-Web.zip'
            if (-not (Test-Path -LiteralPath $webArchive -PathType Leaf)) {
                throw 'releases/MaterialKompass-Web.zip fehlt.'
            }
            $files.Add($webArchive)
        }
        if ($UploadReleases) {
            $releaseNames = @(
                'MaterialKompass-Windows.exe', 'MaterialKompass-Linux.deb',
                'MaterialKompass-Android.apk', 'MaterialKompass-iOS.ipa',
                'MaterialKompass-macOS.dmg'
            )
            $nativeCount = 0
            foreach ($name in $releaseNames) {
                $file = Join-Path $repositoryRoot "releases/$name"
                if (Test-Path -LiteralPath $file -PathType Leaf) {
                    $files.Add($file)
                    $nativeCount += 1
                }
            }
            if ($nativeCount -eq 0) { throw 'Keine freigegebenen nativen Installer wurden gefunden.' }
            if (-not $AllowUnsigned) {
                throw 'Native Veroeffentlichung ist ohne eingerichtete Codesignaturen gesperrt. Pruef-Builds erfordern ausdruecklich -AllowUnsigned.'
            }
        }

        $stageName = "upload-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$PID"
        $stagePath = "$RemotePath/.deployments/uploads/$stageName"
        Invoke-Checked ssh ($sshOptions + @($target,
            "mkdir -p '$RemotePath/.deployments/uploads' && mkdir '$stagePath' && chmod 700 '$stagePath'"))
        try {
            Invoke-Checked scp ($sshOptions + $files.ToArray() + @("${target}:$stagePath/"))
            foreach ($file in $files) {
                $name = Split-Path $file -Leaf
                $expected = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
                $actual = (& ssh @sshOptions $target "sha256sum '$stagePath/$name' | cut -d ' ' -f 1").Trim()
                if ($LASTEXITCODE -ne 0 -or $actual -ne $expected) {
                    throw "SHA-256-Pruefung fehlgeschlagen: $name"
                }
            }
            $publish = "cd '$RemotePath' && sh ops/publish-assets.sh '$stagePath' '$Version' '$([int]$UploadWeb)' '$([int]$UploadReleases)'"
            Invoke-Checked ssh ($sshOptions + @($target, $publish))
        }
        catch {
            & ssh @sshOptions $target "rm -rf -- '$stagePath'" 2>$null
            throw
        }
    }
}
finally { Pop-Location }
