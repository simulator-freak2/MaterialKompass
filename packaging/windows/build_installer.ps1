param(
    [string]$ApiBaseUrl = "https://materialkompass.org",
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$flutterRoot = Join-Path $repositoryRoot "flutter"
$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    throw "Inno Setup 6 wurde nicht gefunden. Installiere es von https://jrsoftware.org/isinfo.php."
}

Push-Location $flutterRoot
try {
    flutter pub get
    flutter build windows --release --dart-define="API_BASE_URL=$ApiBaseUrl"
} finally {
    Pop-Location
}

& $iscc "/DMyAppVersion=$Version" (Join-Path $PSScriptRoot "MaterialKompass.iss")
if ($LASTEXITCODE -ne 0) { throw "Der Windows-Installer konnte nicht erstellt werden." }

Write-Host "Installer: $(Join-Path $repositoryRoot 'releases\MaterialKompass-Windows.exe')"
