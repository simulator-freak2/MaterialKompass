param(
    [string]$ApiBaseUrl = "https://materialkompass.org",
    [string]$Version = "1.5.1",
    [int]$BuildNumber = 1
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$flutterRoot = Join-Path $repositoryRoot "flutter"
$keyProperties = Join-Path $flutterRoot "android\key.properties"
if (-not (Test-Path $keyProperties)) {
    throw "flutter/android/key.properties fehlt. Produktive APKs muessen mit einem dauerhaften Release-Schluessel signiert werden."
}

Push-Location $flutterRoot
try {
    flutter pub get
    $firebaseDefines = @()
    foreach ($name in @("FIREBASE_API_KEY", "FIREBASE_APP_ID", "FIREBASE_MESSAGING_SENDER_ID", "FIREBASE_PROJECT_ID")) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $firebaseDefines += "--dart-define=$name=$value" }
    }
    flutter build apk --release --build-name="$Version" --build-number="$BuildNumber" `
        --dart-define="API_BASE_URL=$ApiBaseUrl" @firebaseDefines
} finally {
    Pop-Location
}

$source = Join-Path $flutterRoot "build\app\outputs\flutter-apk\app-release.apk"
$destination = Join-Path $repositoryRoot "releases\MaterialKompass-Android.apk"
Copy-Item -LiteralPath $source -Destination $destination -Force
Write-Host "Installer: $destination"
