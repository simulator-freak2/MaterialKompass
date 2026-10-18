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
Write-Output "Web-Build erfolgreich: $indexFile"
