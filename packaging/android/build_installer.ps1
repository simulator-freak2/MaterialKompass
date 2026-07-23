param([string]$ApiBaseUrl = "https://materialkompass.org")

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$flutterRoot = Join-Path $repositoryRoot "flutter"
$keyProperties = Join-Path $flutterRoot "android\key.properties"
if (-not (Test-Path $keyProperties)) {
    throw "flutter/android/key.properties fehlt. Produktive APKs müssen mit einem dauerhaften Release-Schlüssel signiert werden."
}

Push-Location $flutterRoot
try {
    flutter pub get
    flutter build apk --release --dart-define="API_BASE_URL=$ApiBaseUrl"
} finally {
    Pop-Location
}

$source = Join-Path $flutterRoot "build\app\outputs\flutter-apk\app-release.apk"
$destination = Join-Path $repositoryRoot "releases\MaterialKompass-Android.apk"
Copy-Item -LiteralPath $source -Destination $destination -Force
Write-Host "Installer: $destination"
