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

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        var output = new StringBuilder();
        process.OutputDataReceived += (_, eventArgs) => Append(eventArgs.Data);
        process.ErrorDataReceived += (_, eventArgs) => Append(eventArgs.Data);

        void Append(string? line)
        {
            if (line is null) return;
            output.AppendLine(line);
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
            try { process.Kill(entireProcessTree: true); } catch { }
            throw;
        }
        return new CommandResult(process.ExitCode, output.ToString());
    }
}
