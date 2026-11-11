$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'remote-package-install.ps1')

$script:polls = 0
$script:commands = [Collections.Generic.List[string]]::new()
$runner = {
    param($Options, $Destination, $Command)
    $script:commands.Add($Command)
    $script:polls += 1
    switch ($script:polls) {
        1 { return @{ ExitCode = 255; Output = @('connection reset') } }
        2 { return @{ ExitCode = 0; Output = @('MKDEPLOY:running', 'building') } }
        3 { return @{ ExitCode = 0; Output = @('MKDEPLOY:0', 'ready') } }
        default { throw 'Unexpected repeat installation status request.' }
    }
}
Wait-RemotePackageInstall -SshOptions @('-o', 'BatchMode=yes') -Target 'dummy@dummy' `
    -RunPath '/dummy/.deployments/runs/upload-test' -PollSeconds 0 -CommandRunner $runner
if ($script:polls -ne 3 -or $script:commands[2] -notlike '*2,$p*') {
    throw 'Reconnect or incremental log replay failed.'
}

foreach ($scenario in @('failed', 'malformed', 'timeout')) {
    $failed = $false
    $timeout = if ($scenario -eq 'timeout') { 0 } else { 10 }
    $failureRunner = {
        param($Options, $Destination, $Command)
        if ($scenario -eq 'failed') { return @{ ExitCode = 0; Output = @('MKDEPLOY:7', 'migration failed') } }
        return @{ ExitCode = 0; Output = @('unexpected response') }
    }
    try {
        Wait-RemotePackageInstall -SshOptions @('-o', 'BatchMode=yes') -Target 'dummy@dummy' `
            -RunPath '/dummy/run' -PollSeconds 0 -TimeoutSeconds $timeout -CommandRunner $failureRunner
    }
    catch {
        $failed = $true
        if ($scenario -eq 'failed' -and $_.Exception.Message -notmatch 'Exit-Code 7') { throw }
        if ($scenario -eq 'malformed' -and $_.Exception.Message -notmatch 'Ungueltige') { throw }
        if ($scenario -eq 'timeout' -and $_.Exception.Message -notmatch 'Zeitlimit') { throw }
    }
    if (-not $failed) { throw "Scenario $scenario was incorrectly reported as successful." }
}
Write-Host 'PASS: reconnect, incremental logs, installer failure, invalid response and timeout.'
