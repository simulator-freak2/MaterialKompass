[CmdletBinding()]
param(
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$projectDirectory = $PSScriptRoot
$repositoryRoot = (Resolve-Path (Join-Path $projectDirectory '..\..')).Path
$project = Join-Path $projectDirectory 'MaterialKompass.Updater.csproj'
$output = Join-Path $repositoryRoot 'releases\MaterialKompass-Updater'
$archive = Join-Path $repositoryRoot 'releases\MaterialKompass-Updater.zip'

& dotnet restore $project --configfile (Join-Path $projectDirectory 'NuGet.Config')
if ($LASTEXITCODE -ne 0) { throw 'Wiederherstellung des Updaterprojekts fehlgeschlagen.' }
& dotnet build $project -c $Configuration --no-restore
if ($LASTEXITCODE -ne 0) { throw 'Build des Updaters fehlgeschlagen.' }

$source = Join-Path $projectDirectory "bin\$Configuration\net10.0-windows"
if (Test-Path -LiteralPath $output) {
    Remove-Item -LiteralPath $output -Recurse -Force
}
New-Item -ItemType Directory -Path $output | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'MaterialKompass-Updater.exe') -Destination $output
Copy-Item -LiteralPath (Join-Path $source 'MaterialKompass-Updater.dll') -Destination $output
Copy-Item -LiteralPath (Join-Path $source 'MaterialKompass-Updater.deps.json') -Destination $output
Copy-Item -LiteralPath (Join-Path $source 'MaterialKompass-Updater.runtimeconfig.json') -Destination $output

Compress-Archive -Path (Join-Path $output '*') -DestinationPath $archive -CompressionLevel Optimal -Force

Write-Host "Updater: $(Join-Path $output 'MaterialKompass-Updater.exe')"
Write-Host "Archiv: $archive"
