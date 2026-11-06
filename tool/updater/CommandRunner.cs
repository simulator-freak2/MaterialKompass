using System.Diagnostics;
using System.Text;

namespace MaterialKompass.Updater;

internal sealed record CommandResult(int ExitCode, string Output)
{
    public bool Success => ExitCode == 0;
}

internal static class CommandRunner
{
    public static async Task<CommandResult> RunAsync(
        string executable,
        IEnumerable<string> arguments,
        string workingDirectory,
        Action<string> log,
        CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(workingDirectory))
            throw new DirectoryNotFoundException($"Arbeitsordner wurde nicht gefunden: {workingDirectory}");
        log($"Starte Prozess: {executable}");
        log($"Arbeitsordner: {workingDirectory}");
        var startInfo = new ProcessStartInfo(executable)
        {
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
        var temporaryDirectory = Path.Combine(workingDirectory, "tmp", "updater");
        Directory.CreateDirectory(temporaryDirectory);
        startInfo.Environment["TEMP"] = temporaryDirectory;
        startInfo.Environment["TMP"] = temporaryDirectory;
        startInfo.Environment["TMPDIR"] = temporaryDirectory;
        log($"Temporärer Arbeitsordner: {temporaryDirectory}");

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        var output = new StringBuilder();
        process.OutputDataReceived += (_, eventArgs) => Append(eventArgs.Data);
        process.ErrorDataReceived += (_, eventArgs) => Append(eventArgs.Data);

        void Append(string? line)
        {
            if (line is null) return;
            lock (output) output.AppendLine(line);
            log(line);
        }

        if (!process.Start()) throw new InvalidOperationException($"{executable} konnte nicht gestartet werden.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            log($"Prozess wird abgebrochen: {executable}");
            try { process.Kill(entireProcessTree: true); } catch { }
            throw;
        }
        log($"Prozess beendet: {executable} (Exit-Code {process.ExitCode})");
        var capturedOutput = output.ToString();
        if (process.ExitCode != 0 && IsDiskFull(capturedOutput))
            throw new IOException($"Zu wenig Speicherplatz beim Update. Ein Werkzeug konnte seine Dateien nicht schreiben.\n\nTemporärer Arbeitsordner: {temporaryDirectory}\nBitte auf dem im Protokoll genannten Laufwerk Speicher freigeben und den Vorgang erneut starten. Die Prüfungen wurden nicht erfolgreich abgeschlossen.");
        return new CommandResult(process.ExitCode, capturedOutput);
    }

    private static bool IsDiskFull(string output) =>
        new[] { "errno = 112", "not enough space", "no space left on device", "device is full", "nicht genug Speicherplatz", "unzureichender Speicherplatz" }
            .Any(marker => output.Contains(marker, StringComparison.OrdinalIgnoreCase));
}
