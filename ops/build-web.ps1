[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$BuildNumber,
    [Parameter(Mandatory)]
    [ValidatePattern('^https://[^\s]+$')]
    [string]$ApiBaseUrl
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$flutterProject = Join-Path $repositoryRoot 'flutter'
$pubspec = Join-Path $flutterProject 'pubspec.yaml'
if (-not (Test-Path -LiteralPath $pubspec -PathType Leaf)) {
    throw "Flutter-Projekt wurde nicht gefunden: $pubspec"
}

$flutter = Get-Command flutter.bat -ErrorAction Stop
Write-Output "Flutter: $($flutter.Source)"
Write-Output "Projekt: $flutterProject"
Write-Output "Erzeuge Web-App $Version+$BuildNumber fuer $ApiBaseUrl"

Push-Location -LiteralPath $flutterProject
try {
    $flutterArguments = @(
        'build', 'web', '--release',
        # CanvasKit vom eigenen Server statt von gstatic.com: kein zusaetzlicher
        # DNS-/TLS-Aufbau beim ersten Aufruf der Loginseite.
        '--no-web-resources-cdn',
        "--build-name=$Version",
        "--build-number=$BuildNumber",
        "--dart-define=API_BASE_URL=$ApiBaseUrl"
    )
    & $flutter.Source @flutterArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter-Web-Build fehlgeschlagen (Exit-Code $LASTEXITCODE)."
    }
}
finally {
    Pop-Location
}

$indexFile = Join-Path $flutterProject 'build/web/index.html'
if (-not (Test-Path -LiteralPath $indexFile -PathType Leaf)) {
    throw "Flutter meldete Erfolg, aber die Web-Ausgabe fehlt: $indexFile"
}

# Die HTML-Loginseite meldet sich direkt bei der API an und braucht deshalb
# denselben Origin wie --dart-define=API_BASE_URL.
$apiOrigin = $ApiBaseUrl.TrimEnd('/')
if ($apiOrigin -notmatch '^https://[A-Za-z0-9.-]+(:\d+)?$') {
    throw "ApiBaseUrl muss ein HTTPS-Origin ohne Pfad sein: $ApiBaseUrl"
}
$indexContent = [System.IO.File]::ReadAllText($indexFile)
if (-not $indexContent.Contains('__MATERIALKOMPASS_API_BASE_URL__')) {
    throw "Platzhalter fuer den API-Origin fehlt in $indexFile"
}
[System.IO.File]::WriteAllText(
    $indexFile,
    $indexContent.Replace('__MATERIALKOMPASS_API_BASE_URL__', $apiOrigin),
    [System.Text.UTF8Encoding]::new($false))

# Vorkomprimierte Kopien fuer nginx gzip_static. Damit entfaellt die
# Komprimierung von main.dart.js und CanvasKit bei jeder Anfrage.
$webOutput = Join-Path $flutterProject 'build/web'
$compressible = Get-ChildItem -LiteralPath $webOutput -Recurse -File |
    Where-Object { $_.Extension -in '.js', '.wasm', '.json', '.html', '.otf', '.ttf' -and $_.Length -gt 1024 }
foreach ($file in $compressible) {
    $target = "$($file.FullName).gz"
    $source = [System.IO.File]::OpenRead($file.FullName)
    try {
        $destination = [System.IO.File]::Create($target)
        try {
            $gzip = [System.IO.Compression.GZipStream]::new(
                $destination, [System.IO.Compression.CompressionLevel]::Optimal)
            try { $source.CopyTo($gzip) } finally { $gzip.Dispose() }
        }
        finally { $destination.Dispose() }
    }
    finally { $source.Dispose() }
}
Write-Output "Vorkomprimiert: $($compressible.Count) Dateien"
Write-Output "Web-Build erfolgreich: $indexFile"
