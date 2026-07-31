#ifndef MyAppVersion
  #define MyAppVersion "1.1.0"
#endif

[Setup]
AppId={{B37DD4B6-CE39-4C20-A0E4-A65CC6EAE614}
AppName=MaterialKompass
AppVersion={#MyAppVersion}
AppPublisher=MaterialKompass
DefaultDirName={autopf}\MaterialKompass
DefaultGroupName=MaterialKompass
DisableProgramGroupPage=yes
OutputDir={#SourcePath}\..\..\releases
OutputBaseFilename=MaterialKompass-Windows
SetupIconFile={#SourcePath}\..\..\flutter\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=yes
UninstallDisplayIcon={app}\materialkompass.exe

[Files]
Source: "{#SourcePath}\..\..\flutter\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\MaterialKompass"; Filename: "{app}\materialkompass.exe"
Name: "{autodesktop}\MaterialKompass"; Filename: "{app}\materialkompass.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Desktop-Verknüpfung erstellen"; GroupDescription: "Zusätzliche Symbole:"

[Run]
Filename: "{app}\materialkompass.exe"; Description: "MaterialKompass starten"; Flags: nowait postinstall skipifsilent
