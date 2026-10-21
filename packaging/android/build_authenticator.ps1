param(
    [string]$Version = "1.0.0",
    [int]$BuildNumber = 1
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$authenticatorRoot = Join-Path $repositoryRoot "authenticator"
$keyProperties = Join-Path $authenticatorRoot "android\key.properties"
if (-not (Test-Path -LiteralPath $keyProperties)) {
    throw "authenticator/android/key.properties fehlt. Produktive APKs muessen mit einem dauerhaften Release-Schluessel signiert werden."
}

Push-Location $authenticatorRoot
try {
    flutter pub get
    flutter test
    flutter build apk --release --build-name="$Version" --build-number="$BuildNumber"
} finally {
    Pop-Location
}

$source = Join-Path $authenticatorRoot "build\app\outputs\flutter-apk\app-release.apk"
$destination = Join-Path $repositoryRoot "releases\MaterialKompass-Authenticator-Android.apk"
Copy-Item -LiteralPath $source -Destination $destination -Force
Write-Host "Authenticator: $destination"
