[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*$')]
    [string]$Server = '31.70.106.152',
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_.-]*$')]
    [string]$SshUser = 'materialkompass-deploy',
    [ValidatePattern('^/[A-Za-z0-9._/-]+$')]
    [string]$RemotePath = '/opt/materialkompass',
    [string]$IdentityFile,
    [Parameter(Mandatory)]
    [string]$KnownHostsFile,
    [ValidatePattern('^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [switch]$DeployBackend,
    [switch]$UploadWeb,
    [switch]$UploadReleases,
    [switch]$SkipChecks,
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

function New-ServerBundle {
    param(
        [Parameter(Mandatory)] [string]$RepositoryRoot,
        [Parameter(Mandatory)] [string]$Destination
    )

    $requiredPaths = @(
        'backend/package.json', 'backend/package-lock.json', 'backend/Dockerfile',
        'mailbox-provisioner/Dockerfile', 'mailbox-provisioner/server.js',
        'ops/install-package.sh',
        'ops/apply-package-migrations.sh', 'ops/backup-mariadb.sh',
        'ops/publish-assets.sh', 'ops/sync-public-web.sh',
        'compose.yaml', 'CHANGELOG.md'
    )
    foreach ($relativePath in $requiredPaths) {
        $path = Join-Path $RepositoryRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Erforderliche Paketdatei fehlt: $relativePath"
        }
    }

    foreach ($root in @('backend', 'mailbox-provisioner', 'ops')) {
        $rootPath = Join-Path $RepositoryRoot $root
        $reparsePoint = Get-ChildItem -LiteralPath $rootPath -Recurse -Force -ErrorAction Stop |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
            Select-Object -First 1
        if ($reparsePoint) {
            throw "Das Serverpaket darf keine Verknuepfungen enthalten: $($reparsePoint.FullName)"
        }
    }

    $arguments = @(
        '-czf', $Destination,
        '--exclude=backend/node_modules', '--exclude=backend/coverage',
        '--exclude=backend/test', '--exclude=backend/.env', '--exclude=backend/.env.*',
        '--exclude=backend/tmp', '--exclude=backend/*.log',
        '--exclude=mailbox-provisioner/node_modules', '--exclude=mailbox-provisioner/test',
        '--exclude=mailbox-provisioner/.env', '--exclude=mailbox-provisioner/.env.*',
        '--exclude=mailbox-provisioner/*.log',
        'backend', 'mailbox-provisioner', 'ops', 'compose.yaml', 'CHANGELOG.md'
    )
    Invoke-Checked tar.exe $arguments
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf) -or
        (Get-Item -LiteralPath $Destination).Length -lt 1024) {
        throw 'Das erzeugte Serverpaket ist ungueltig oder leer.'
    }
}

if ($RemotePath.Contains('..')) { throw 'RemotePath darf kein .. enthalten.' }
if (-not ($DeployBackend -or $UploadWeb -or $UploadReleases)) {
    throw 'Mindestens DeployBackend, UploadWeb oder UploadReleases muss ausgewaehlt sein.'
}
if (-not $Version) { throw 'Fuer ein Deployment ist -Version erforderlich.' }

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
    Write-Host "Ziel: $target $RemotePath"
    Write-Host "Backendpaket: $DeployBackend | Web: $UploadWeb | Installer: $UploadReleases"
    Write-Host "Version: $Version | Verfahren: direkter SSH-Upload ohne Git"
    Write-Host "Pruefungen ueberspringen: $SkipChecks"
    if ($DeployBackend) {
        $previewDirectory = Join-Path ([IO.Path]::GetTempPath()) "materialkompass-preview-$PID-$([Guid]::NewGuid().ToString('N'))"
        [IO.Directory]::CreateDirectory($previewDirectory) | Out-Null
        try {
            $previewBundle = Join-Path $previewDirectory 'MaterialKompass-Server.tar.gz'
            Push-Location $repositoryRoot
            try { New-ServerBundle -RepositoryRoot $repositoryRoot -Destination $previewBundle }
            finally { Pop-Location }
            $previewHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $previewBundle).Hash
            $previewSize = (Get-Item -LiteralPath $previewBundle).Length
            Write-Host "Serverpaket: $previewSize Bytes | SHA-256: $previewHash"
        }
        finally {
            if (Test-Path -LiteralPath $previewDirectory) {
                Remove-Item -LiteralPath $previewDirectory -Recurse -Force
            }
        }
    }
    if ($UploadWeb -and -not (Test-Path -LiteralPath (Join-Path $repositoryRoot 'releases/MaterialKompass-Web.zip') -PathType Leaf)) {
        throw 'releases/MaterialKompass-Web.zip fehlt.'
    }
    exit 0
}

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "materialkompass-deploy-$PID-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
$stageName = "upload-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$PID"
$stagePath = "$RemotePath/.deployments/uploads/$stageName"
$stageCreated = $false

Push-Location $repositoryRoot
try {
    if (-not $SkipChecks) {
        Write-Host '[1/7] Backendtests werden ausgefuehrt.'
        Invoke-Checked npm @('--prefix', 'backend', 'test')
        Write-Host '[2/7] Mailbox-Tests werden ausgefuehrt.'
        Invoke-Checked node @('--test', 'mailbox-provisioner/server.test.js')
        Write-Host '[3/7] Flutter-Analyse und Flutter-Tests werden ausgefuehrt.'
        Push-Location flutter
        try {
            Invoke-Checked flutter @('analyze')
            Invoke-Checked flutter @('test')
        }
        finally { Pop-Location }
    }

    $files = [Collections.Generic.List[string]]::new()
    if ($DeployBackend) {
        Write-Host '[4/7] Geprueftes Serverpaket wird erstellt.'
        $serverBundle = Join-Path $temporaryDirectory 'MaterialKompass-Server.tar.gz'
        New-ServerBundle -RepositoryRoot $repositoryRoot -Destination $serverBundle
        $files.Add($serverBundle)
        $files.Add((Join-Path $repositoryRoot 'ops/install-package.sh'))
    }
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

    Write-Host "[5/7] Geschuetztes Uploadverzeichnis wird auf $target erstellt."
    Invoke-Checked ssh ($sshOptions + @($target,
        "mkdir -p '$RemotePath/.deployments/uploads' && mkdir '$stagePath' && chmod 700 '$stagePath'"))
    $stageCreated = $true
    Write-Host "Lade $($files.Count) Datei(en) per SCP hoch."
    Invoke-Checked scp ($sshOptions + $files.ToArray() + @("${target}:$stagePath/"))

    Write-Host '[6/7] SHA-256-Pruefsummen werden lokal und auf dem Server verglichen.'
    foreach ($file in $files) {
        $name = Split-Path $file -Leaf
        $expected = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
        $actual = (& ssh @sshOptions $target "sha256sum '$stagePath/$name' | cut -d ' ' -f 1").Trim()
        if ($LASTEXITCODE -ne 0 -or $actual -ne $expected) {
            throw "SHA-256-Pruefung fehlgeschlagen: $name"
        }
        Write-Host "Pruefsumme gueltig: $name ($expected)"
    }

    if ($DeployBackend) {
        Write-Host '[7/7] Serverbackup, Paketinstallation, Migrationen und Gesundheitspruefung starten.'
        $deployCommand = "sh '$stagePath/install-package.sh' '$stagePath/MaterialKompass-Server.tar.gz' '$Version' '$RemotePath'"
        Invoke-Checked ssh ($sshOptions + @($target, $deployCommand))
        Invoke-Checked ssh ($sshOptions + @($target,
            "rm -f -- '$stagePath/MaterialKompass-Server.tar.gz' '$stagePath/install-package.sh'"))
    }

    if ($UploadWeb -or $UploadReleases) {
        Write-Host 'Web- und/oder Clientdateien werden atomar veroeffentlicht.'
        $uploadWebFlag = if ($UploadWeb.IsPresent) { '1' } else { '0' }
        $uploadReleasesFlag = if ($UploadReleases.IsPresent) { '1' } else { '0' }
        $publish = "cd '$RemotePath' && sh ops/publish-assets.sh '$stagePath' '$Version' '$uploadWebFlag' '$uploadReleasesFlag'"
        Invoke-Checked ssh ($sshOptions + @($target, $publish))
        $stageCreated = $false
    }
    else {
        Write-Host 'Temporaeres Uploadverzeichnis wird entfernt.'
        Invoke-Checked ssh ($sshOptions + @($target, "rm -rf -- '$stagePath'"))
        $stageCreated = $false
    }
    Write-Host "Deployment von MaterialKompass $Version wurde erfolgreich abgeschlossen."
}
catch {
    Write-Host "Deployment fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
    if ($stageCreated) {
        & ssh @sshOptions $target "rm -rf -- '$stagePath'" 2>$null
    }
    throw
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
