function Assert-WebReleaseVersion {
    param(
        [Parameter(Mandatory)] [string]$ArchivePath,
        [Parameter(Mandatory)] [string]$ExpectedVersion
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entry = $archive.GetEntry('version.json')
        if (-not $entry -or $entry.Length -gt 16KB) {
            throw 'Webpaket enthaelt keine gueltige version.json. Bitte Apps fuer die aktuelle Version neu bauen.'
        }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $metadata = $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
        if (-not $metadata.PSObject.Properties['version'] -or $metadata.version -cne $ExpectedVersion) {
            throw "Webpaket passt nicht zur Releaseversion $ExpectedVersion. Bitte Apps fuer diese Version neu bauen oder die passenden GitHub-Artefakte herunterladen. Das Starten von GitHub Actions allein aktualisiert das lokale Webpaket nicht: $ArchivePath"
        }
        Write-Host "Webpaket-Version geprueft: $ExpectedVersion"
    }
    finally { $archive.Dispose() }
}
