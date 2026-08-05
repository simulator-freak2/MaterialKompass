param(
    [string]$ApiBaseUrl = "https://materialkompass.org",
    [string]$Version = "1.2.0",
    [string]$CertificateThumbprint = $env:WINDOWS_CERT_THUMBPRINT,
    [string]$TimestampUrl = "http://timestamp.digicert.com",
    [switch]$AllowUnsigned
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$flutterRoot = Join-Path $repositoryRoot "flutter"
$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    $iscc = @(
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $iscc) {
    throw "Inno Setup 6 wurde nicht gefunden. Installiere es von https://jrsoftware.org/isinfo.php."
}

function Find-SignTool {
    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (-not (Test-Path $kitsRoot)) { return $null }
    return Get-ChildItem -Path $kitsRoot -Recurse -Filter signtool.exe |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

$signTool = Find-SignTool
if (-not $AllowUnsigned) {
    if ($CertificateThumbprint -notmatch '^[A-Fa-f0-9]{40}$') {
        throw "WINDOWS_CERT_THUMBPRINT fehlt oder ist ungültig. Für einen lokalen Prüf-Build kann -AllowUnsigned verwendet werden."
    }
    if (-not $signTool) {
        throw "signtool.exe wurde nicht gefunden. Installiere das Windows SDK."
    }
}

function Sign-Artifact([string]$Path) {
    if ($AllowUnsigned) { return }
    & $signTool sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 $Path
    if ($LASTEXITCODE -ne 0) { throw "Codesignierung fehlgeschlagen: $Path" }
    & $signTool verify /pa /all $Path
    if ($LASTEXITCODE -ne 0) { throw "Signaturprüfung fehlgeschlagen: $Path" }
}

Push-Location $flutterRoot
try {
    flutter pub get
    flutter build windows --release --dart-define="API_BASE_URL=$ApiBaseUrl"
} finally {
    Pop-Location
}

$releaseDirectory = Join-Path $flutterRoot "build\windows\x64\runner\Release"
Get-ChildItem -LiteralPath $releaseDirectory -Filter *.exe -File |
    ForEach-Object { Sign-Artifact $_.FullName }

& $iscc "/DMyAppVersion=$Version" (Join-Path $PSScriptRoot "MaterialKompass.iss")
if ($LASTEXITCODE -ne 0) { throw "Der Windows-Installer konnte nicht erstellt werden." }

$installerPath = Join-Path $repositoryRoot 'releases\MaterialKompass-Windows.exe'
Sign-Artifact $installerPath
Write-Host "Installer: $installerPath"
