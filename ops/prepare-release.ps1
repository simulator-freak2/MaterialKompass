[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [Parameter(Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int]$BuildNumber,
    [Parameter(Mandatory)]
    [string]$ChangelogFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$resolvedChangelog = (Resolve-Path -LiteralPath $ChangelogFile).Path
$notes = [IO.File]::ReadAllText($resolvedChangelog, [Text.UTF8Encoding]::new($false)).Trim()
if ([string]::IsNullOrWhiteSpace($notes) -or $notes.Length -gt 4000) {
    throw 'Der Changelog muss zwischen 1 und 4000 Zeichen enthalten.'
}

function Replace-Checked {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Pattern,
        [Parameter(Mandatory)] [string]$Replacement,
        [int]$ExpectedMinimum = 1
    )
    $absolutePath = Join-Path $repositoryRoot $Path
    $content = [IO.File]::ReadAllText($absolutePath)
    $matches = [regex]::Matches($content, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)
    if ($matches.Count -lt $ExpectedMinimum) {
        throw "Versionsmuster wurde in $Path nicht gefunden."
    }
    $updated = [regex]::Replace(
        $content,
        $Pattern,
        $Replacement,
        [Text.RegularExpressions.RegexOptions]::Multiline
    )
    if ($PSCmdlet.ShouldProcess($absolutePath, "Version auf $Version aktualisieren")) {
        [IO.File]::WriteAllText($absolutePath, $updated, [Text.UTF8Encoding]::new($false))
    }
}

Push-Location $repositoryRoot
try {
    if ($PSCmdlet.ShouldProcess('backend/package.json und backend/package-lock.json', "Version auf $Version aktualisieren")) {
        $packagePath = Join-Path $repositoryRoot 'backend/package.json'
        $packageLockPath = Join-Path $repositoryRoot 'backend/package-lock.json'
        $versionScript = @'
const fs = require('node:fs');
const [packagePath, packageLockPath, version] = process.argv.slice(1);
for (const filePath of [packagePath, packageLockPath]) {
  const document = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  if (typeof document.version !== 'string') throw new Error(`Version fehlt in ${filePath}`);
  document.version = version;
  if (filePath === packageLockPath) {
    if (!document.packages || !document.packages['']) {
      throw new Error('Root-Paket fehlt in package-lock.json');
    }
    document.packages[''].version = version;
  }
  fs.writeFileSync(filePath, `${JSON.stringify(document, null, 2)}\n`, 'utf8');
}
'@
        & node -e $versionScript $packagePath $packageLockPath $Version
        if ($LASTEXITCODE -ne 0) { throw 'Node konnte die Backendversion nicht aktualisieren.' }
    }

    Replace-Checked -Path 'flutter/pubspec.yaml' `
        -Pattern '(^version:\s*)[^\r\n]+(\r?)$' `
        -Replacement "`${1}$Version+$BuildNumber`${2}"
    Replace-Checked -Path 'authenticator/pubspec.yaml' `
        -Pattern '(^version:\s*)[^\r\n]+(\r?)$' `
        -Replacement "`${1}$Version+$BuildNumber`${2}"
    Replace-Checked -Path '.github/workflows/client-installers.yml' `
        -Pattern '(^[ \t]*default:[ \t]*)\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?[ \t]*(\r?)$' `
        -Replacement "`${1}$Version`${2}"
    Replace-Checked -Path 'compose.yaml' `
        -Pattern '(CLIENT_(?:WINDOWS|MACOS|LINUX|ANDROID|IOS)_VERSION:\s*\$\{CLIENT_[A-Z]+_VERSION:-)[^}]+(\})' `
        -Replacement "`${1}$Version`${2}" -ExpectedMinimum 5
    Replace-Checked -Path 'backend/.env.example' `
        -Pattern '^(CLIENT_(?:WINDOWS|MACOS|LINUX|ANDROID|IOS)_VERSION=)[^\r\n]*(\r?)$' `
        -Replacement "`${1}$Version`${2}" -ExpectedMinimum 5

    $changelogPath = Join-Path $repositoryRoot 'CHANGELOG.md'
    $existing = if (Test-Path -LiteralPath $changelogPath) {
        [IO.File]::ReadAllText($changelogPath).Trim()
    } else {
        '# Aenderungsprotokoll'
    }
    $date = Get-Date -Format 'yyyy-MM-dd'
    $entry = "## [$Version] - $date`r`n`r`n$notes"
    $escapedVersion = [regex]::Escape($Version)
    $existingEntryPattern = "(?ms)^## \[$escapedVersion\][^\r\n]*\r?\n.*?(?=^## \[|\z)"
    if ([regex]::IsMatch($existing, $existingEntryPattern)) {
        # Wiederholte Aufrufe sind absichtlich idempotent. Das ist wichtig, wenn ein
        # spaeterer Vorbereitungsschritt abbricht und der Nutzer den Vorgang neu startet.
        $updatedChangelog = [regex]::Replace($existing, $existingEntryPattern, $entry.TrimEnd())
    }
    else {
        $headingEnd = $existing.IndexOf("`n")
        $header = if ($headingEnd -ge 0) { $existing.Substring(0, $headingEnd).TrimEnd() } else { $existing }
        $remainder = if ($headingEnd -ge 0) { $existing.Substring($headingEnd).Trim() } else { '' }
        $updatedChangelog = "$header`r`n`r`n$entry"
        if ($remainder) { $updatedChangelog += "`r`n`r`n$remainder" }
    }
    $updatedChangelog = $updatedChangelog.TrimEnd() + "`r`n"
    if ($PSCmdlet.ShouldProcess($changelogPath, "Changelog fuer $Version ergaenzen")) {
        [IO.File]::WriteAllText($changelogPath, $updatedChangelog, [Text.UTF8Encoding]::new($false))
    }

    Write-Host "Release $Version+$BuildNumber wurde vorbereitet. Aenderungen jetzt pruefen und testen."
}
finally {
    Pop-Location
}
