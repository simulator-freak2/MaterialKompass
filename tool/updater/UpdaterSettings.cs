using System.Text.Json;

namespace MaterialKompass.Updater;

internal sealed class UpdaterSettings
{
    public string Environment { get; set; } = "Produktion";
    public string Server { get; set; } = "31.70.106.152";
    public string SshUser { get; set; } = "materialkompass-deploy";
    public string RemotePath { get; set; } = "/opt/materialkompass";
    public string Branch { get; set; } = "main";
    public string IdentityFile { get; set; } = string.Empty;
    public string ApiBaseUrl { get; set; } = "https://materialkompass.org";

    public static string SettingsDirectory => Path.Combine(
        System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData),
        "MaterialKompass",
        "Updater");

    public static string SettingsPath => Path.Combine(SettingsDirectory, "settings.json");
    public static string KnownHostsPath => Path.Combine(SettingsDirectory, "known_hosts");
    public static string LogDirectory => Path.Combine(SettingsDirectory, "logs");

    public static UpdaterSettings Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                return JsonSerializer.Deserialize<UpdaterSettings>(File.ReadAllText(SettingsPath))
                    ?? new UpdaterSettings();
            }
        }
        catch
        {
            // Invalid local settings fall back to secure defaults.
        }
        return new UpdaterSettings();
    }

    public void Save()
    {
        Directory.CreateDirectory(SettingsDirectory);
        File.WriteAllText(
            SettingsPath,
            JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}
