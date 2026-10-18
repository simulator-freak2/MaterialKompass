using System.Diagnostics;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace MaterialKompass.Updater;

internal sealed class MainForm : Form
{
    private readonly string _repositoryRoot;
    private readonly string _logFilePath;
    private readonly TextBox _log = new()
    {
        Dock = DockStyle.Fill,
        Multiline = true,
        ReadOnly = true,
        ScrollBars = ScrollBars.Both,
        WordWrap = false,
        Font = new Font("Consolas", 9F),
    };
    private readonly ComboBox _environment = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TextBox _server = new();
    private readonly TextBox _sshUser = new();
    private readonly TextBox _remotePath = new();
    private readonly TextBox _branch = new();
    private readonly TextBox _identity = new();
    private readonly TextBox _apiUrl = new();
    private readonly Label _trustState = new() { AutoSize = true };

    private readonly TextBox _version = new();
    private readonly NumericUpDown _buildNumber = new() { Minimum = 1, Maximum = int.MaxValue };
    private readonly TextBox _changelog = new() { Multiline = true, ScrollBars = ScrollBars.Vertical };
    private readonly TextBox _gitCommitMessage = new();
    private readonly ComboBox _buildMode = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly CheckBox _backend = new() { Text = "Backend und Datenbankmigrationen", Checked = true, AutoSize = true };
    private readonly CheckBox _web = new() { Text = "Web-App", Checked = true, AutoSize = true };
    private readonly CheckBox _native = new() { Text = "Native Installer", AutoSize = true };
    private readonly CheckBox _dataImport = new() { Text = "Produktionsdaten aus Gesamtsicherung ersetzen", AutoSize = true };
    private readonly CheckBox _publishNotes = new() { Text = "Changelog nach erfolgreichem Deployment veröffentlichen", Checked = true, AutoSize = true };
    private readonly CheckBox _allowUnsigned = new() { Text = "UNSIGNIERTE Prüfinstaller ausdrücklich zulassen", AutoSize = true, ForeColor = Color.DarkRed };
    private readonly TextBox _backupFile = new() { ReadOnly = true };

    private readonly TextBox _maintenanceTitle = new() { Text = "Geplante Wartungsarbeiten" };
    private readonly TextBox _maintenanceMessage = new() { Multiline = true, ScrollBars = ScrollBars.Vertical };
    private readonly DateTimePicker _maintenanceStart = new() { Format = DateTimePickerFormat.Custom, CustomFormat = "dd.MM.yyyy HH:mm" };
    private readonly DateTimePicker _maintenanceEnd = new() { Format = DateTimePickerFormat.Custom, CustomFormat = "dd.MM.yyyy HH:mm" };
    private readonly List<Control> _actionControls = [];
    private readonly Button _cancelButton = new() { Text = "Laufenden Vorgang abbrechen", Enabled = false, AutoSize = true };
    private CancellationTokenSource? _operationCancellation;

    public MainForm()
    {
        _repositoryRoot = FindRepositoryRoot();
        Directory.CreateDirectory(UpdaterSettings.LogDirectory);
        _logFilePath = Path.Combine(
            UpdaterSettings.LogDirectory,
            $"updater-{DateTime.Now:yyyyMMdd-HHmmss}.log");
        Text = "MaterialKompass-Updater";
        Width = 1060;
        Height = 820;
        MinimumSize = new Size(900, 680);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 10F);

        _environment.Items.AddRange(["Produktion", "Staging"]);
        _buildMode.Items.AddRange(["GitHub Actions (optional, externe Plattform-Builds)", "Lokal ohne Git (Windows/Web/Android)"]);
        _buildMode.SelectedIndex = 1;
        _maintenanceStart.Value = DateTime.Now.AddDays(1).Date.AddHours(20);
        _maintenanceEnd.Value = _maintenanceStart.Value.AddHours(2);

        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(BuildConfigurationTab());
        tabs.TabPages.Add(BuildReleaseTab());
        tabs.TabPages.Add(BuildMaintenanceTab());

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1 };
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 68));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 32));
        layout.Controls.Add(tabs, 0, 0);
        layout.Controls.Add(_cancelButton, 0, 1);
        layout.Controls.Add(BuildLogPanel(), 0, 2);
        Controls.Add(layout);

        _cancelButton.Click += (_, _) => _operationCancellation?.Cancel();
        _environment.SelectedIndexChanged += (_, _) => ApplyEnvironmentDefaults();
        LoadSettings();
        LoadCurrentVersion();
        UpdateTrustState();
        Log("MaterialKompass-Updater gestartet.");
        Log($"Repository: {_repositoryRoot}");
        Log($"Logdatei: {_logFilePath}");
    }

    private TabPage BuildConfigurationTab()
    {
        var page = new TabPage("Server & Sicherheit");
        var panel = FormPanel();
        AddRow(panel, "Umgebung", _environment);
        AddRow(panel, "Server-IP", _server);
        AddRow(panel, "SSH-Benutzer", _sshUser);
        AddRow(panel, "Serverpfad", _remotePath);
        AddRow(panel, "Git-Branch", _branch);
        AddRow(panel, "SSH-Schlüssel (optional)", WithBrowse(_identity, "SSH-Schlüssel auswählen", false));
        AddRow(panel, "Öffentliche API", _apiUrl);
        AddRow(panel, "Hostschlüssel", _trustState);

        var scan = ActionButton("Hostschlüssel erfassen und prüfen", ScanHostKeyAsync);
        var test = ActionButton("SSH-Verbindung testen", TestSshAsync);
        var save = ActionButton("Einstellungen speichern", () => { SaveSettings(); return Task.CompletedTask; });
        AddRow(panel, string.Empty, Buttons(scan, test, save));
        var note = new Label
        {
            AutoSize = true,
            MaximumSize = new Size(800, 0),
            Text = "Wichtig: Den angezeigten SHA-256-Fingerprint vor dem Speichern über die Serverkonsole oder den Hosting-Anbieter vergleichen. Das Programm akzeptiert später keinen unbekannten oder geänderten Hostschlüssel.",
        };
        AddRow(panel, string.Empty, note);
        page.Controls.Add(panel);
        return page;
    }

    private TabPage BuildReleaseTab()
    {
        var page = new TabPage("Release & Deployment");
        var panel = FormPanel();
        AddRow(panel, "Version", _version);
        AddRow(panel, "Buildnummer", _buildNumber);
        _changelog.Height = 130;
        AddRow(panel, "Changelog", _changelog);
        AddRow(panel, "Git-Commitnachricht", _gitCommitMessage);
        AddRow(panel, "Buildquelle", _buildMode);
        AddRow(panel, "Umfang", Flow(_backend, _web, _native, _dataImport));
        AddRow(panel, "Nutzerinformation", _publishNotes);
        AddRow(panel, "Codesignatur", _allowUnsigned);
        AddRow(panel, "Gesamtsicherung", WithBrowse(_backupFile, "MaterialKompass-Gesamtsicherung auswählen", false, "JSON (*.json)|*.json"));

        var prepare = ActionButton("1. Release vorbereiten", PrepareReleaseAsync);
        var push = ActionButton("2. Git committen & pushen", CommitAndPushGitAsync);
        var build = ActionButton("3. Apps bauen", BuildAppsAsync);
        var preview = ActionButton("4. Sicherheitsvorschau", () => DeployAsync(dryRun: true));
        var deploy = ActionButton("5. Deployment starten", () => DeployAsync(dryRun: false));
        AddRow(panel, string.Empty, Buttons(prepare, push, build, preview, deploy));

        var warning = new Label
        {
            AutoSize = true,
            MaximumSize = new Size(820, 0),
            ForeColor = Color.DarkRed,
            Text = "Der Git-Push ist optional und unabhängig vom direkten SSH-Deployment. Vor dem Commit werden Zielbranch und alle Dateien zur Bestätigung angezeigt; Force-Push wird nicht verwendet. Ohne Codesignatur bleiben native Produktionsinstaller gesperrt.",
        };
        AddRow(panel, string.Empty, warning);
        page.Controls.Add(panel);
        return page;
    }

    private TabPage BuildMaintenanceTab()
    {
        var page = new TabPage("Wartungsinformation");
        var panel = FormPanel();
        AddRow(panel, "Titel", _maintenanceTitle);
        _maintenanceMessage.Height = 150;
        AddRow(panel, "Nachricht", _maintenanceMessage);
        AddRow(panel, "Beginn", _maintenanceStart);
        AddRow(panel, "Ende", _maintenanceEnd);
        var publish = ActionButton("Wartungshinweis veröffentlichen", PublishMaintenanceAsync);
        AddRow(panel, string.Empty, publish);
        AddRow(panel, string.Empty, new Label
        {
            AutoSize = true,
            MaximumSize = new Size(800, 0),
            Text = "Der Hinweis ist für alle sichtbar – auch vor der Anmeldung. Er informiert nur und sperrt die Nutzung nicht. Nach dem Endzeitpunkt blendet der Server ihn automatisch aus.",
        });
        page.Controls.Add(panel);
        return page;
    }

    private static TableLayoutPanel FormPanel() => new()
    {
        Dock = DockStyle.Fill,
        AutoScroll = true,
        Padding = new Padding(20),
        ColumnCount = 2,
        AutoSize = true,
        ColumnStyles = { new ColumnStyle(SizeType.Absolute, 210), new ColumnStyle(SizeType.Percent, 100) },
    };

    private static void AddRow(TableLayoutPanel panel, string label, Control control)
    {
        var row = panel.RowCount++;
        panel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        panel.Controls.Add(new Label { Text = label, AutoSize = true, Padding = new Padding(0, 8, 8, 0) }, 0, row);
        control.Margin = new Padding(3, 5, 3, 7);
        control.Anchor = AnchorStyles.Left | AnchorStyles.Right;
        panel.Controls.Add(control, 1, row);
    }

    private static FlowLayoutPanel Flow(params Control[] controls)
    {
        var panel = new FlowLayoutPanel { AutoSize = true, WrapContents = true };
        panel.Controls.AddRange(controls);
        return panel;
    }

    private static FlowLayoutPanel Buttons(params Control[] controls) => Flow(controls);

    private Control BuildLogPanel()
    {
        var panel = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1 };
        panel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var header = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 3 };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        header.Controls.Add(new Label
        {
            Text = $"Protokoll – {_logFilePath}",
            AutoEllipsis = true,
            Dock = DockStyle.Fill,
            Padding = new Padding(3, 7, 3, 0),
        }, 0, 0);
        var copy = new Button { Text = "Protokoll kopieren", AutoSize = true };
        copy.Click += (_, _) =>
        {
            if (_log.TextLength > 0) Clipboard.SetText(_log.Text);
        };
        var open = new Button { Text = "Logdatei öffnen", AutoSize = true };
        open.Click += (_, _) =>
        {
            try
            {
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{_logFilePath}\"")
                {
                    UseShellExecute = true,
                });
            }
            catch (Exception exception)
            {
                Log($"Logordner konnte nicht geöffnet werden: {exception.Message}");
            }
        };
        header.Controls.Add(copy, 1, 0);
        header.Controls.Add(open, 2, 0);
        panel.Controls.Add(header, 0, 0);
        panel.Controls.Add(_log, 0, 1);
        return panel;
    }

    private Control WithBrowse(TextBox target, string title, bool folder, string filter = "Alle Dateien (*.*)|*.*")
    {
        var button = new Button { Text = "Durchsuchen …", AutoSize = true };
        button.Click += (_, _) =>
        {
            if (folder)
            {
                using var dialog = new FolderBrowserDialog { Description = title };
                if (dialog.ShowDialog(this) == DialogResult.OK) target.Text = dialog.SelectedPath;
            }
            else
            {
                using var dialog = new OpenFileDialog { Title = title, Filter = filter, CheckFileExists = true };
                if (dialog.ShowDialog(this) == DialogResult.OK) target.Text = dialog.FileName;
            }
        };
        var panel = new TableLayoutPanel { AutoSize = true, ColumnCount = 2, Dock = DockStyle.Fill };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        target.Dock = DockStyle.Fill;
        panel.Controls.Add(target, 0, 0);
        panel.Controls.Add(button, 1, 0);
        return panel;
    }

    private Button ActionButton(string text, Func<Task> action)
    {
        var button = new Button { Text = text, AutoSize = true };
        _actionControls.Add(button);
        button.Click += async (_, _) => await RunGuardedAsync(text, action);
        return button;
    }

    private async Task RunGuardedAsync(string operationName, Func<Task> action)
    {
        if (_operationCancellation is not null) return;
        _operationCancellation = new CancellationTokenSource();
        SetActionsEnabled(false);
        _cancelButton.Enabled = true;
        try
        {
            Log($"=== START: {operationName} ===");
            SaveSettings();
            await action();
            Log($"=== ERFOLGREICH: {operationName} ===");
        }
        catch (OperationCanceledException)
        {
            Log("Vorgang wurde abgebrochen.");
        }
        catch (Exception exception)
        {
            Log($"FEHLER: {exception}");
            var message = exception.Message;
            const int maximumDialogLength = 900;
            if (message.Length > maximumDialogLength) message = "..." + message[^maximumDialogLength..];
            message += $"\n\nVollständiges Protokoll:\n{_logFilePath}";
            MessageBox.Show(this, message, "Vorgang fehlgeschlagen", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            _operationCancellation.Dispose();
            _operationCancellation = null;
            SetActionsEnabled(true);
            _cancelButton.Enabled = false;
        }
    }

    private void SetActionsEnabled(bool enabled)
    {
        foreach (var control in _actionControls) control.Enabled = enabled;
    }

    private void LoadSettings()
    {
        var settings = UpdaterSettings.Load();
        _environment.SelectedItem = settings.Environment;
        if (_environment.SelectedIndex < 0) _environment.SelectedIndex = 0;
        _server.Text = settings.Server;
        _sshUser.Text = settings.SshUser;
        _remotePath.Text = settings.RemotePath;
        _branch.Text = settings.Branch;
        _identity.Text = settings.IdentityFile;
        _apiUrl.Text = settings.ApiBaseUrl;
    }

    private void SaveSettings()
    {
        ValidateConfiguration(requireTrust: false);
        new UpdaterSettings
        {
            Environment = _environment.Text,
            Server = _server.Text.Trim(),
            SshUser = _sshUser.Text.Trim(),
            RemotePath = _remotePath.Text.Trim(),
            Branch = _branch.Text.Trim(),
            IdentityFile = _identity.Text.Trim(),
            ApiBaseUrl = _apiUrl.Text.Trim(),
        }.Save();
        Log("Einstellungen gespeichert (keine Passwörter oder Schlüssel). ");
    }

    private void ApplyEnvironmentDefaults()
    {
        if (_environment.Text == "Staging") _server.Text = "85.215.181.248";
        else if (_environment.Text == "Produktion") _server.Text = "31.70.106.152";
        UpdateTrustState();
    }

    private void LoadCurrentVersion()
    {
        var pubspec = File.ReadAllText(Path.Combine(_repositoryRoot, "flutter", "pubspec.yaml"));
        var match = Regex.Match(pubspec, @"(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?");
        _version.Text = match.Success ? match.Groups[1].Value : "1.0.0";
        _buildNumber.Value = match.Success && int.TryParse(match.Groups[2].Value, out var build)
            ? build
            : 1;
        _gitCommitMessage.Text = $"Release {_version.Text}";

        var changelogPath = Path.Combine(_repositoryRoot, "CHANGELOG.md");
        if (match.Success && File.Exists(changelogPath))
        {
            var changelog = File.ReadAllText(changelogPath);
            var versionPattern = Regex.Escape(match.Groups[1].Value);
            var notes = Regex.Match(
                changelog,
                $@"(?ms)^## \[{versionPattern}\][^\r\n]*\r?\n\s*(?<notes>.*?)(?=^## \[|\z)");
            if (notes.Success) _changelog.Text = notes.Groups["notes"].Value.Trim();
        }
    }

    private void ValidateConfiguration(bool requireTrust)
    {
        if (!Regex.IsMatch(_server.Text.Trim(), @"^[A-Za-z0-9][A-Za-z0-9.-]*$")) throw new InvalidOperationException("Ungültige Serveradresse.");
        if (!Regex.IsMatch(_sshUser.Text.Trim(), @"^[A-Za-z_][A-Za-z0-9_.-]*$")) throw new InvalidOperationException("Ungültiger SSH-Benutzer.");
        if (!Regex.IsMatch(_remotePath.Text.Trim(), @"^/[A-Za-z0-9._/-]+$") || _remotePath.Text.Contains("..")) throw new InvalidOperationException("Ungültiger Serverpfad.");
        if (!Uri.TryCreate(_apiUrl.Text.Trim(), UriKind.Absolute, out var api) || api.Scheme != Uri.UriSchemeHttps) throw new InvalidOperationException("Die öffentliche API muss eine HTTPS-Adresse sein.");
        if (_identity.TextLength > 0 && !File.Exists(_identity.Text)) throw new FileNotFoundException("Der ausgewählte SSH-Schlüssel wurde nicht gefunden.");
        if (requireTrust && !HasKnownHost()) throw new InvalidOperationException("Der SSH-Hostschlüssel wurde noch nicht geprüft.");
    }

    private bool HasKnownHost()
    {
        if (!File.Exists(UpdaterSettings.KnownHostsPath)) return false;
        return File.ReadLines(UpdaterSettings.KnownHostsPath)
            .Any(line => line.StartsWith(_server.Text.Trim() + " ", StringComparison.Ordinal)
                || line.StartsWith($"[{_server.Text.Trim()}]:22 ", StringComparison.Ordinal));
    }

    private void UpdateTrustState()
    {
        var trusted = HasKnownHost();
        _trustState.Text = trusted ? "Geprüfter Schlüssel vorhanden" : "Noch nicht eingerichtet";
        _trustState.ForeColor = trusted ? Color.DarkGreen : Color.DarkRed;
    }

    private async Task ScanHostKeyAsync()
    {
        ValidateConfiguration(requireTrust: false);
        Log($"Lese öffentliche Hostschlüssel von {_server.Text.Trim()} …");
        var result = await CommandRunner.RunAsync(
            "ssh-keyscan.exe",
            ["-T", "10", _server.Text.Trim()],
            _repositoryRoot,
            Log,
            Token);
        var lines = result.Output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Where(line => !line.StartsWith('#'))
            .Where(line => line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length == 3)
            .Distinct()
            .ToArray();
        if (lines.Length == 0)
        {
            Log("ssh-keyscan ist mit dem Server-Schlüsselaustausch nicht kompatibel; verwende sicheren Ed25519-Fallback …");
            var temporaryKnownHosts = Path.Combine(
                Path.GetTempPath(),
                $"materialkompass-known-hosts-{Guid.NewGuid():N}");
            try
            {
                await CommandRunner.RunAsync(
                    "ssh.exe",
                    [
                        "-o", "BatchMode=yes",
                        "-o", "StrictHostKeyChecking=accept-new",
                        "-o", $"UserKnownHostsFile={temporaryKnownHosts}",
                        "-o", "GlobalKnownHostsFile=NUL",
                        "-o", "HashKnownHosts=no",
                        "-o", "KexAlgorithms=curve25519-sha256",
                        "-o", "HostKeyAlgorithms=ssh-ed25519",
                        "-o", "PreferredAuthentications=none",
                        $"{_sshUser.Text.Trim()}@{_server.Text.Trim()}",
                        "exit",
                    ],
                    _repositoryRoot,
                    _ => { },
                    Token);
                if (File.Exists(temporaryKnownHosts))
                {
                    lines = File.ReadAllLines(temporaryKnownHosts)
                        .Where(line => !string.IsNullOrWhiteSpace(line) && !line.StartsWith('#'))
                        .Where(line => line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length == 3)
                        .Distinct()
                        .ToArray();
                }
            }
            finally
            {
                try { File.Delete(temporaryKnownHosts); } catch { }
            }
        }
        if (lines.Length == 0) throw new InvalidOperationException("Der Server hat keinen SSH-Hostschlüssel geliefert.");
        var fingerprints = lines.Select(Fingerprint).ToArray();
        var message = "Vergleiche diese Fingerprints mit der Serverkonsole oder dem Hosting-Anbieter:\n\n"
            + string.Join("\n", fingerprints)
            + "\n\nSind die Fingerprints über einen unabhängigen Weg bestätigt?";
        if (MessageBox.Show(this, message, "SSH-Fingerprint prüfen", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
        {
            Log("Hostschlüssel wurde nicht gespeichert.");
            return;
        }
        Directory.CreateDirectory(UpdaterSettings.SettingsDirectory);
        var existing = File.Exists(UpdaterSettings.KnownHostsPath)
            ? File.ReadAllLines(UpdaterSettings.KnownHostsPath)
            : [];
        var host = _server.Text.Trim();
        var retained = existing.Where(line => !line.StartsWith(host + " ", StringComparison.Ordinal)
            && !line.StartsWith($"[{host}]:22 ", StringComparison.Ordinal));
        File.WriteAllLines(UpdaterSettings.KnownHostsPath, retained.Concat(lines), new UTF8Encoding(false));
        Log("Geprüfter Hostschlüssel wurde gespeichert.");
        UpdateTrustState();
    }

    private static string Fingerprint(string line)
    {
        var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var key = Convert.FromBase64String(parts[2]);
        var hash = Convert.ToBase64String(SHA256.HashData(key)).TrimEnd('=');
        return $"{parts[1]}  SHA256:{hash}";
    }

    private async Task TestSshAsync()
    {
        ValidateConfiguration(requireTrust: true);
        var arguments = SshArguments();
        arguments.Add($"{_sshUser.Text.Trim()}@{_server.Text.Trim()}");
        arguments.Add("printf 'MaterialKompass SSH ok\\n'");
        var result = await CommandRunner.RunAsync("ssh.exe", arguments, _repositoryRoot, Log, Token);
        if (!result.Success) throw new InvalidOperationException("SSH-Verbindung fehlgeschlagen.");
    }

    private async Task PrepareReleaseAsync()
    {
        ValidateRelease();
        if (string.IsNullOrWhiteSpace(_changelog.Text) || _changelog.Text.Trim() == "-")
            throw new InvalidOperationException("Bitte einen aussagekraeftigen Changelog eingeben.");
        var temp = Path.Combine(Path.GetTempPath(), $"materialkompass-changelog-{Guid.NewGuid():N}.txt");
        try
        {
            await File.WriteAllTextAsync(temp, _changelog.Text.Trim(), new UTF8Encoding(false), Token);
            var result = await RunPowerShellAsync("ops/prepare-release.ps1",
            [
                "-Version", _version.Text.Trim(),
                "-BuildNumber", ((int)_buildNumber.Value).ToString(),
                "-ChangelogFile", temp,
            ]);
            if (!result.Success)
                throw new InvalidOperationException(CommandFailure("Releasevorbereitung fehlgeschlagen.", result));
            _gitCommitMessage.Text = $"Release {_version.Text.Trim()}";
            MessageBox.Show(this, "Versions- und Changelogdateien wurden geändert. Bitte Diff und Tests prüfen. Anschließend kannst du die Änderungen mit Schritt 2 direkt committen und pushen.", "Release vorbereitet", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        finally { try { File.Delete(temp); } catch { } }
    }

    private async Task CommitAndPushGitAsync()
    {
        var branch = _branch.Text.Trim();
        if (!Regex.IsMatch(branch, @"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
            || branch.Contains("..", StringComparison.Ordinal)
            || branch.Contains("//", StringComparison.Ordinal)
            || branch.EndsWith('/'))
        {
            throw new InvalidOperationException("Der Git-Branchname ist nicht sicher.");
        }

        var commitMessage = _gitCommitMessage.Text.Trim();
        if (commitMessage.Length is < 3 or > 120 || commitMessage.Contains('\n') || commitMessage.Contains('\r'))
            throw new InvalidOperationException("Die Git-Commitnachricht muss 3 bis 120 Zeichen lang und einzeilig sein.");

        var currentBranchResult = await RunGitAsync("branch", "--show-current");
        if (!currentBranchResult.Success)
            throw new InvalidOperationException(CommandFailure("Der aktuelle Git-Branch konnte nicht gelesen werden.", currentBranchResult));
        var currentBranch = currentBranchResult.Output.Trim();
        if (!string.Equals(currentBranch, branch, StringComparison.Ordinal))
            throw new InvalidOperationException($"Erwarteter Branch: {branch}; aktueller Branch: {currentBranch}.");

        var statusResult = await RunGitAsync("status", "--porcelain=v1", "--untracked-files=all");
        if (!statusResult.Success)
            throw new InvalidOperationException(CommandFailure("Der Git-Status konnte nicht gelesen werden.", statusResult));
        var statusLines = statusResult.Output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
        var sensitivePaths = statusLines
            .Select(GitStatusPath)
            .Where(IsSensitiveGitPath)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (sensitivePaths.Length > 0)
        {
            throw new InvalidOperationException(
                "Der Git-Push wurde blockiert, weil typische Geheimdateinamen betroffen sind:\n\n"
                + string.Join(Environment.NewLine, sensitivePaths));
        }

        var statusPreview = statusLines.Length == 0
            ? "Keine lokalen Änderungen; bereits vorhandene Commits werden gepusht."
            : string.Join(Environment.NewLine, statusLines.Take(35))
                + (statusLines.Length > 35 ? $"\n… und {statusLines.Length - 35} weitere" : string.Empty);
        var confirmation = $"Ziel: origin/{branch}\n\nCommit: {commitMessage}\n\n{statusPreview}\n\n"
            + "Alle angezeigten lokalen Änderungen committen und anschließend ohne Force-Push übertragen?";
        if (MessageBox.Show(this, confirmation, "Git-Commit und Push bestätigen", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
        {
            Log("Git-Commit und Push wurden nicht gestartet.");
            return;
        }

        if (statusLines.Length > 0)
        {
            var addResult = await RunGitAsync("add", "--all");
            if (!addResult.Success)
                throw new InvalidOperationException(CommandFailure("Die Git-Änderungen konnten nicht vorgemerkt werden.", addResult));
            var checkResult = await RunGitAsync("diff", "--cached", "--check");
            if (!checkResult.Success)
                throw new InvalidOperationException(CommandFailure("Der Commit enthält Git-Diff-Fehler. Die Dateien bleiben zur Prüfung vorgemerkt.", checkResult));
            var commitResult = await RunGitAsync("commit", "-m", commitMessage);
            if (!commitResult.Success)
                throw new InvalidOperationException(CommandFailure("Der Git-Commit konnte nicht erstellt werden.", commitResult));
        }

        var pushResult = await RunGitAsync("push", "origin", $"HEAD:refs/heads/{branch}");
        if (!pushResult.Success)
            throw new InvalidOperationException(CommandFailure("Der Git-Push ist fehlgeschlagen. Ein erstellter Commit bleibt lokal erhalten.", pushResult));
        Log($"Git-Push zu origin/{branch} wurde erfolgreich abgeschlossen.");
        MessageBox.Show(this, $"Die Änderungen wurden zu origin/{branch} gepusht.", "Git-Push erfolgreich", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private static string GitStatusPath(string statusLine)
    {
        var path = statusLine.Length > 3 ? statusLine[3..].Trim() : string.Empty;
        var renameSeparator = path.LastIndexOf(" -> ", StringComparison.Ordinal);
        if (renameSeparator >= 0) path = path[(renameSeparator + 4)..];
        return path.Trim('"').Replace('\\', '/');
    }

    private static bool IsSensitiveGitPath(string path)
    {
        var fileName = Path.GetFileName(path);
        if (fileName.Equals(".env", StringComparison.OrdinalIgnoreCase)) return true;
        if (fileName.StartsWith(".env.", StringComparison.OrdinalIgnoreCase)
            && !fileName.Equals(".env.example", StringComparison.OrdinalIgnoreCase)
            && !fileName.Equals(".env.sample", StringComparison.OrdinalIgnoreCase)) return true;
        return Regex.IsMatch(fileName, @"^(?:id_(?:rsa|dsa|ecdsa|ed25519)|credentials(?:\.json)?|secrets?(?:\.json)?)$", RegexOptions.IgnoreCase)
            || Regex.IsMatch(fileName, @"\.(?:key|pem|pfx|p12|jks|keystore)$", RegexOptions.IgnoreCase);
    }

    private async Task BuildAppsAsync()
    {
        ValidateRelease();
        if (_buildMode.SelectedIndex == 0)
        {
            var result = await CommandRunner.RunAsync("gh.exe",
            [
                "workflow", "run", "client-installers.yml", "--ref", _branch.Text.Trim(),
                "-f", $"version={_version.Text.Trim()}", "-f", $"api_base_url={_apiUrl.Text.Trim()}",
            ], _repositoryRoot, Log, Token);
            if (!result.Success) throw new InvalidOperationException("GitHub-Workflow konnte nicht gestartet werden.");
            Log("GitHub Actions wurde gestartet. Die signierten Artefakte können nach Einrichtung der Zertifikate aus dem Workflow heruntergeladen werden.");
            return;
        }

        var webBuild = await RunPowerShellAsync("ops/build-web.ps1",
        [
            "-Version", _version.Text.Trim(),
            "-BuildNumber", ((int)_buildNumber.Value).ToString(),
            "-ApiBaseUrl", _apiUrl.Text.Trim(),
        ]);
        if (!webBuild.Success)
            throw new InvalidOperationException(CommandFailure("Web-Build fehlgeschlagen.", webBuild));
        Directory.CreateDirectory(Path.Combine(_repositoryRoot, "releases"));
        var archive = Path.Combine(_repositoryRoot, "releases", "MaterialKompass-Web.zip");
        if (File.Exists(archive)) File.Delete(archive);
        System.IO.Compression.ZipFile.CreateFromDirectory(
            Path.Combine(_repositoryRoot, "flutter", "build", "web"), archive,
            System.IO.Compression.CompressionLevel.Optimal, includeBaseDirectory: false);

        if (!_native.Checked)
        {
            Log("Web-Build wurde erstellt. Native Installer sind nicht ausgewählt und werden übersprungen.");
            return;
        }

        var windows = await RunPowerShellAsync("packaging/windows/build_installer.ps1",
        [
            "-ApiBaseUrl", _apiUrl.Text.Trim(), "-Version", _version.Text.Trim(),
            "-BuildNumber", ((int)_buildNumber.Value).ToString(), "-AllowUnsigned",
        ]);
        if (!windows.Success)
            throw new InvalidOperationException(CommandFailure("Windows-Prüf-Build fehlgeschlagen.", windows));

        var keyProperties = Path.Combine(_repositoryRoot, "flutter", "android", "key.properties");
        if (File.Exists(keyProperties))
        {
            var android = await RunPowerShellAsync("packaging/android/build_installer.ps1",
            [
                "-ApiBaseUrl", _apiUrl.Text.Trim(), "-Version", _version.Text.Trim(),
                "-BuildNumber", ((int)_buildNumber.Value).ToString(),
            ]);
            if (!android.Success)
                throw new InvalidOperationException(CommandFailure("Android-Build fehlgeschlagen.", android));
        }
        else Log("Android wurde übersprungen: flutter/android/key.properties fehlt.");
        Log("Lokale Prüf-Builds wurden erstellt. Linux, macOS und iOS benötigen passende Buildsysteme oder GitHub Actions.");
    }

    private async Task DeployAsync(bool dryRun)
    {
        ValidateConfiguration(requireTrust: true);
        ValidateRelease();
        if (!_backend.Checked && !_web.Checked && !_native.Checked && !_dataImport.Checked)
            throw new InvalidOperationException("Bitte mindestens einen Updateumfang auswählen.");
        if (_native.Checked && !_allowUnsigned.Checked)
            throw new InvalidOperationException("Native Installer sind ohne Codesignaturen gesperrt. Richte zuerst Zertifikate ein oder kennzeichne bewusst einen unsignierten Prüf-Build.");
        if (_native.Checked && _allowUnsigned.Checked && !dryRun)
        {
            using var confirmation = new PhraseConfirmationDialog("UNSIGNIERT VERÖFFENTLICHEN");
            if (confirmation.ShowDialog(this) != DialogResult.OK) return;
        }
        if (_dataImport.Checked && !File.Exists(_backupFile.Text))
            throw new FileNotFoundException("Für den Datenimport muss eine Gesamtsicherung ausgewählt werden.");
        if (!dryRun) await AuthorizeUpdateAsync();

        if (_backend.Checked || _web.Checked || _native.Checked)
        {
            var arguments = new List<string>
            {
                "-Server", _server.Text.Trim(), "-SshUser", _sshUser.Text.Trim(),
                "-RemotePath", _remotePath.Text.Trim(),
                "-KnownHostsFile", UpdaterSettings.KnownHostsPath,
                "-Version", _version.Text.Trim(),
            };
            if (_identity.TextLength > 0) arguments.AddRange(["-IdentityFile", _identity.Text.Trim()]);
            if (_backend.Checked) arguments.Add("-DeployBackend");
            if (_web.Checked) arguments.Add("-UploadWeb");
            if (_native.Checked) arguments.Add("-UploadReleases");
            if (_allowUnsigned.Checked) arguments.Add("-AllowUnsigned");
            if (dryRun) arguments.Add("-DryRun");
            var result = await RunPowerShellAsync("ops/deploy-package.ps1", arguments);
            if (!result.Success)
                throw new InvalidOperationException(CommandFailure("Deployment fehlgeschlagen.", result));
        }
        if (dryRun)
        {
            if (_dataImport.Checked) Log("Vorschau: Gesamtsicherung würde nach einem frischen Serverbackup importiert.");
            return;
        }
        if (_publishNotes.Checked && !string.IsNullOrWhiteSpace(_changelog.Text)) await PublishReleaseNotesAsync();
        if (_dataImport.Checked) await ImportProductionDataAsync();
        MessageBox.Show(this, "Der gewählte Vorgang wurde erfolgreich abgeschlossen.", "MaterialKompass", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private async Task AuthorizeUpdateAsync()
    {
        using var credentials = new ImportCredentialsDialog(
            "Update autorisieren",
            "Update autorisieren",
            "Melde dich mit einem Plattformadministratorkonto an, das neue Organisationen anlegen darf.");
        if (credentials.ShowDialog(this) != DialogResult.OK) throw new OperationCanceledException();

        using var client = new HttpClient
        {
            BaseAddress = new Uri(_apiUrl.Text.Trim()),
            Timeout = TimeSpan.FromMinutes(2),
        };
        var token = await AuthenticateAdminAsync(client, credentials, "Update-Autorisierung");
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/updater/authorization");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await client.SendAsync(request, Token);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(Token);
            throw new InvalidOperationException(
                $"Update-Autorisierung fehlgeschlagen ({(int)response.StatusCode}): {SafeServerError(body)}");
        }
        Log("Update wurde durch ein berechtigtes Administratorkonto autorisiert.");
    }

    private async Task PublishReleaseNotesAsync()
    {
        var arguments = MessageScriptBase("release", $"MaterialKompass {_version.Text.Trim()}", _changelog.Text.Trim());
        arguments.AddRange(["-Version", _version.Text.Trim()]);
        var result = await RunPowerShellAsync("ops/publish-system-message.ps1", arguments);
        if (!result.Success) throw new InvalidOperationException("Changelog konnte nicht veröffentlicht werden.");
    }

    private async Task PublishMaintenanceAsync()
    {
        ValidateConfiguration(requireTrust: true);
        if (string.IsNullOrWhiteSpace(_maintenanceTitle.Text) || string.IsNullOrWhiteSpace(_maintenanceMessage.Text))
            throw new InvalidOperationException("Titel und Nachricht dürfen nicht leer sein.");
        if (_maintenanceEnd.Value <= _maintenanceStart.Value)
            throw new InvalidOperationException("Das Wartungsende muss nach dem Beginn liegen.");
        var arguments = MessageScriptBase("maintenance", _maintenanceTitle.Text.Trim(), _maintenanceMessage.Text.Trim());
        arguments.AddRange([
            "-StartsAt", _maintenanceStart.Value.ToString("o"),
            "-EndsAt", _maintenanceEnd.Value.ToString("o"),
        ]);
        var result = await RunPowerShellAsync("ops/publish-system-message.ps1", arguments);
        if (!result.Success) throw new InvalidOperationException("Wartungshinweis konnte nicht veröffentlicht werden.");
    }

    private List<string> MessageScriptBase(string type, string title, string message)
    {
        var arguments = new List<string>
        {
            "-Server", _server.Text.Trim(), "-SshUser", _sshUser.Text.Trim(),
            "-RemotePath", _remotePath.Text.Trim(), "-KnownHostsFile", UpdaterSettings.KnownHostsPath,
            "-Type", type, "-Title", title, "-Message", message,
        };
        if (_identity.TextLength > 0) arguments.AddRange(["-IdentityFile", _identity.Text.Trim()]);
        return arguments;
    }

    private async Task ImportProductionDataAsync()
    {
        using var phrase = new PhraseConfirmationDialog("ALLE DATEN ERSETZEN");
        if (phrase.ShowDialog(this) != DialogResult.OK) throw new OperationCanceledException();
        Log("Erstelle vor dem Datenimport ein frisches serverseitiges Datenbankbackup …");
        var ssh = SshArguments();
        ssh.Add($"{_sshUser.Text.Trim()}@{_server.Text.Trim()}");
        ssh.Add($"cd '{_remotePath.Text.Trim()}' && docker compose run --rm -e BACKUP_ONCE=true backup");
        var backupResult = await CommandRunner.RunAsync("ssh.exe", ssh, _repositoryRoot, Log, Token);
        if (!backupResult.Success) throw new InvalidOperationException("Sicherungsimport abgebrochen: Serverbackup fehlgeschlagen.");

        using var credentials = new ImportCredentialsDialog();
        if (credentials.ShowDialog(this) != DialogResult.OK) throw new OperationCanceledException();
        var api = new Uri(_apiUrl.Text.Trim());
        using var client = new HttpClient { BaseAddress = api, Timeout = TimeSpan.FromMinutes(10) };
        var token = await AuthenticateAdminAsync(client, credentials, "Datenimport");
        using var backupDocument = JsonDocument.Parse(await File.ReadAllTextAsync(_backupFile.Text, Token));
        var importBody = new Dictionary<string, object?>
        {
            ["confirmation"] = "ALLE DATEN ERSETZEN",
            ["currentPassword"] = credentials.Password,
            ["mfaCode"] = credentials.MfaCode,
            ["backup"] = backupDocument.RootElement.Clone(),
        };
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/system/backup/import")
        {
            Content = new StringContent(JsonSerializer.Serialize(importBody), Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await client.SendAsync(request, Token);
        var body = await response.Content.ReadAsStringAsync(Token);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"Datenimport fehlgeschlagen ({(int)response.StatusCode}): {SafeServerError(body)}");
        Log("Produktionsdaten wurden importiert. Alle bestehenden Anmeldesitzungen müssen erneuert werden.");
        credentials.ClearSecrets();
    }

    private async Task<string> AuthenticateAdminAsync(
        HttpClient client,
        ImportCredentialsDialog credentials,
        string purpose)
    {
        var loginResponse = await PostJsonAsync(client, "/api/auth/login", new
        {
            identifier = credentials.Identifier,
            password = credentials.Password,
        }, Token);
        var loginBody = await ReadJsonAsync(loginResponse, Token);
        if ((int)loginResponse.StatusCode == 202 && loginBody.TryGetProperty("challenge", out var challenge))
        {
            if (string.IsNullOrWhiteSpace(credentials.MfaCode))
            {
                loginResponse.Dispose();
                throw new InvalidOperationException("Für dieses Konto ist ein 2-FA- oder Recovery-Code erforderlich.");
            }
            loginResponse.Dispose();
            loginResponse = await PostJsonAsync(client, "/api/auth/mfa/verify", new
            {
                challenge = challenge.GetString(),
                code = credentials.MfaCode,
            }, Token);
            loginBody = await ReadJsonAsync(loginResponse, Token);
        }
        using (loginResponse)
        {
            if (!loginResponse.IsSuccessStatusCode || !loginBody.TryGetProperty("token", out var tokenElement))
                throw new InvalidOperationException($"Admin-Anmeldung für {purpose} fehlgeschlagen.");
            return tokenElement.GetString()
                ?? throw new InvalidOperationException("Der Server lieferte kein Anmeldetoken.");
        }
    }

    private static async Task<HttpResponseMessage> PostJsonAsync(
        HttpClient client,
        string path,
        object body,
        CancellationToken cancellationToken)
    {
        using var content = new StringContent(
            JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        return await client.PostAsync(path, content, cancellationToken);
    }

    private static async Task<JsonElement> ReadJsonAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        var text = await response.Content.ReadAsStringAsync(cancellationToken);
        try { return JsonDocument.Parse(text).RootElement.Clone(); }
        catch { throw new InvalidOperationException($"Ungültige Serverantwort ({(int)response.StatusCode})."); }
    }

    private static string SafeServerError(string body)
    {
        try
        {
            var root = JsonDocument.Parse(body).RootElement;
            return root.TryGetProperty("error", out var error) ? error.GetString() ?? "Unbekannter Fehler" : "Unbekannter Fehler";
        }
        catch { return "Unbekannter Fehler"; }
    }

    private void ValidateRelease()
    {
        if (!Regex.IsMatch(_version.Text.Trim(), @"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$"))
            throw new InvalidOperationException("Die Version muss SemVer entsprechen, zum Beispiel 1.6.0.");
        if (_changelog.TextLength > 4000) throw new InvalidOperationException("Der Changelog darf höchstens 4000 Zeichen enthalten.");
        if (_publishNotes.Checked && (string.IsNullOrWhiteSpace(_changelog.Text) || _changelog.Text.Trim() == "-"))
            throw new InvalidOperationException("Zum Veröffentlichen muss ein aussagekräftiger Changelog eingetragen sein.");
    }

    private List<string> SshArguments()
    {
        var arguments = new List<string>
        {
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", $"UserKnownHostsFile={UpdaterSettings.KnownHostsPath}",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
        };
        if (_identity.TextLength > 0)
            arguments.AddRange(["-o", "IdentitiesOnly=yes", "-i", _identity.Text.Trim()]);
        return arguments;
    }

    private Task<CommandResult> RunPowerShellAsync(string relativeScript, IEnumerable<string> arguments)
    {
        var all = new List<string>
        {
            "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", Path.Combine(_repositoryRoot, relativeScript.Replace('/', Path.DirectorySeparatorChar)),
        };
        all.AddRange(arguments);
        return CommandRunner.RunAsync("powershell.exe", all, _repositoryRoot, Log, Token);
    }

    private Task<CommandResult> RunGitAsync(params string[] arguments) =>
        CommandRunner.RunAsync("git.exe", arguments, _repositoryRoot, Log, Token);

    private static string CommandFailure(string heading, CommandResult result)
    {
        var output = result.Output.Trim();
        if (output.Length == 0) return $"{heading}\n\nExit-Code: {result.ExitCode}";
        const int maximumLength = 1800;
        if (output.Length > maximumLength) output = "..." + output[^maximumLength..];
        return $"{heading}\n\n{output}";
    }

    private CancellationToken Token => _operationCancellation?.Token ?? CancellationToken.None;

    private void Log(string message)
    {
        if (InvokeRequired) { BeginInvoke(() => Log(message)); return; }
        var normalized = message.Replace("\0", string.Empty);
        var lines = normalized.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        var rendered = string.Join(
            Environment.NewLine,
            lines.Select(line => $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {line}")) + Environment.NewLine;
        _log.AppendText(rendered);
        try { File.AppendAllText(_logFilePath, rendered, new UTF8Encoding(false)); }
        catch { /* Logging must never abort an update. */ }
    }

    private static string FindRepositoryRoot()
    {
        foreach (var start in new[] { AppContext.BaseDirectory, Environment.CurrentDirectory })
        {
            var directory = new DirectoryInfo(start);
            while (directory is not null)
            {
                if (File.Exists(Path.Combine(directory.FullName, "compose.yaml"))
                    && Directory.Exists(Path.Combine(directory.FullName, "backend"))) return directory.FullName;
                directory = directory.Parent;
            }
        }
        throw new DirectoryNotFoundException("Das MaterialKompass-Repository wurde nicht gefunden. Lege die EXE in oder unterhalb des Repositorys ab.");
    }
}

internal sealed class PhraseConfirmationDialog : Form
{
    private readonly string _phrase;
    private readonly TextBox _input = new();
    private readonly Button _confirm = new() { Text = "Bestätigen", Enabled = false, DialogResult = DialogResult.OK };

    public PhraseConfirmationDialog(string phrase)
    {
        _phrase = phrase;
        Text = "Sicherheitsbestätigung";
        Width = 560;
        Height = 220;
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, Padding = new Padding(20), WrapContents = false };
        panel.Controls.Add(new Label { AutoSize = true, MaximumSize = new Size(490, 0), Text = $"Diese Aktion verändert Produktionsdaten. Tippe zur Bestätigung exakt:\n\n{phrase}" });
        _input.Width = 490;
        panel.Controls.Add(_input);
        var cancel = new Button { Text = "Abbrechen", DialogResult = DialogResult.Cancel, AutoSize = true };
        panel.Controls.Add(new FlowLayoutPanel { AutoSize = true, Controls = { cancel, _confirm } });
        Controls.Add(panel);
        AcceptButton = _confirm;
        CancelButton = cancel;
        _input.TextChanged += (_, _) => _confirm.Enabled = _input.Text == _phrase;
    }
}

internal sealed class ImportCredentialsDialog : Form
{
    private readonly TextBox _identifier = new();
    private readonly TextBox _password = new() { UseSystemPasswordChar = true };
    private readonly TextBox _mfa = new() { UseSystemPasswordChar = true };

    public string Identifier => _identifier.Text.Trim();
    public string Password => _password.Text;
    public string MfaCode => _mfa.Text.Trim();

    public ImportCredentialsDialog(
        string title = "Admin-Bestätigung",
        string actionText = "Import autorisieren",
        string? description = null)
    {
        Text = title;
        Width = 520;
        Height = description is null ? 300 : 350;
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        var panel = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), ColumnCount = 2, AutoSize = true };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 170));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var rowOffset = 0;
        if (description is not null)
        {
            var descriptionLabel = new Label
            {
                Text = description,
                AutoSize = true,
                MaximumSize = new Size(460, 0),
            };
            panel.Controls.Add(descriptionLabel, 0, 0);
            panel.SetColumnSpan(descriptionLabel, 2);
            rowOffset = 1;
        }
        Add("Admin-Nutzer/E-Mail", _identifier, rowOffset);
        Add("Aktuelles Passwort", _password, rowOffset + 1);
        Add("2-FA-/Recovery-Code", _mfa, rowOffset + 2);
        var ok = new Button { Text = actionText, DialogResult = DialogResult.OK, AutoSize = true };
        var cancel = new Button { Text = "Abbrechen", DialogResult = DialogResult.Cancel, AutoSize = true };
        var buttons = new FlowLayoutPanel { AutoSize = true, Controls = { cancel, ok } };
        panel.Controls.Add(buttons, 1, rowOffset + 3);
        Controls.Add(panel);
        AcceptButton = ok;
        CancelButton = cancel;

        void Add(string label, Control control, int row)
        {
            control.Dock = DockStyle.Fill;
            panel.Controls.Add(new Label { Text = label, AutoSize = true }, 0, row);
            panel.Controls.Add(control, 1, row);
        }
    }

    public void ClearSecrets()
    {
        _password.Clear();
        _mfa.Clear();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) ClearSecrets();
        base.Dispose(disposing);
    }
}
