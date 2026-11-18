#ifndef TargetArch
  #define TargetArch "x64"
#endif
#ifndef SourceDir
  #error SourceDir must be defined.
#endif
#ifndef OutputDir
  #error OutputDir must be defined.
#endif

[Setup]
AppId=TodoEndfield.Desktop
AppName=待办清单
AppVersion=1.0.0
AppPublisher=Todo Endfield
DefaultDirName={localappdata}\Programs\TodoEndfield
DefaultGroupName=待办清单
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
CreateUninstallRegKey=yes
UpdateUninstallLogAppName=yes
UsePreviousAppDir=yes
UsePreviousGroup=no
UsePreviousTasks=no
UsePreviousLanguage=no
UsePreviousUserInfo=no
Uninstallable=yes
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayName=待办清单
UninstallDisplayIcon={app}\todo_endfield.exe
AppMutex=Local\TodoEndfield.Desktop
CloseApplications=yes
RestartApplications=no
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
OutputDir={#OutputDir}
OutputBaseFilename=flutter-todo-windows-{#TargetArch}-setup
#if TargetArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
MinVersion=10.0.22000
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "ledger_native_test.exe"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\待办清单"; Filename: "{app}\todo_endfield.exe"; WorkingDir: "{app}"
Name: "{userprograms}\卸载待办清单"; Filename: "{uninstallexe}"
Name: "{userdesktop}\待办清单"; Filename: "{app}\todo_endfield.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\todo_endfield.exe"; Description: "Open Todo Endfield"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{userstartup}\TodoEndfield.lnk"
