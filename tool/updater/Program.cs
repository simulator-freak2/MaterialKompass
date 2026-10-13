namespace MaterialKompass.Updater;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, args) => MessageBox.Show(
            args.Exception.Message,
            "MaterialKompass-Updater",
            MessageBoxButtons.OK,
            MessageBoxIcon.Error);
        Application.Run(new MainForm());
    }
}
