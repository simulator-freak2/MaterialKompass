function Wait-RemotePackageInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$SshOptions,
        [Parameter(Mandatory)] [string]$Target,
        [Parameter(Mandatory)] [ValidatePattern('^/[A-Za-z0-9._/-]+$')] [string]$RunPath,
        [int]$TimeoutSeconds = 1800,
        [int]$PollSeconds = 3,
        [scriptblock]$CommandRunner = {
            param($Options, $Destination, $Command)
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $outputLines = @(& ssh @Options $Destination $Command 2>&1)
                $exitCode = $LASTEXITCODE
                return @{ ExitCode = $exitCode; Output = @($outputLines | ForEach-Object { $_.ToString() }) }
            }
            finally { $ErrorActionPreference = $previousPreference }
        }
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $nextLine = 1
    $wasDisconnected = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        # The first line is a machine-readable state. The rest is only new log
        # content; it is never evaluated as a command.
        $command = "if [ -f '$RunPath/exit-code' ]; then printf 'MKDEPLOY:'; cat '$RunPath/exit-code'; elif [ -f '$RunPath/pid' ]; then printf 'MKDEPLOY:running\n'; else printf 'MKDEPLOY:starting\n'; fi; if [ -f '$RunPath/install.log' ]; then sed -n '${nextLine},`$p' '$RunPath/install.log'; fi"
        $result = & $CommandRunner $SshOptions $Target $command
        if ($result.ExitCode -ne 0) {
            Write-Host 'SSH-Verbindung unterbrochen. Die Serverinstallation laeuft unabhaengig weiter; Status wird erneut abgefragt.'
            $wasDisconnected = $true
        }
        else {
            $lines = @($result.Output)
            if ($lines.Count -lt 1 -or $lines[0] -notmatch '^MKDEPLOY:(starting|running|[0-9]+)$') {
                throw "Ungueltige Installationsantwort. Serverprotokoll bleibt erhalten: $RunPath/install.log"
            }
            $state = $Matches[1]
            if ($wasDisconnected) { Write-Host 'SSH-Verbindung wiederhergestellt.'; $wasDisconnected = $false }
            for ($lineIndex = 1; $lineIndex -lt $lines.Count; $lineIndex++) {
                Write-Host $lines[$lineIndex]
                $nextLine += 1
            }
            if ($state -eq 'starting' -and [DateTime]::UtcNow -gt $deadline.AddSeconds(-$TimeoutSeconds + 30)) {
                throw "Serverstart konnte nicht bestaetigt werden. Upload bleibt erhalten; Serverprotokoll pruefen: $RunPath"
            }
            if ($state -notin @('starting', 'running')) {
                if ($state -ne '0') {
                    throw "Serverinstallation fehlgeschlagen (Exit-Code $state). Serverprotokoll: $RunPath/install.log"
                }
                return
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
    throw "Zeitlimit der Statusabfrage erreicht. Installationsstatus ist ungeklaert; keinen zweiten Lauf starten. Serverprotokoll: $RunPath/install.log"
}
