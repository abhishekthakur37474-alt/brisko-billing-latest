[Setup]
AppName=Brisko Billing
AppVersion=1.0.0
DefaultDirName={localappdata}\BriskoBilling
DefaultGroupName=Brisko Billing
UninstallDisplayIcon={app}\brisko_billing.exe
OutputBaseFilename=BriskoBilling_Setup
OutputDir=D:\briskobillingmy\installer
PrivilegesRequired=lowest
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Main EXE file
Source: "D:\briskobillingmy\build\windows\x64\runner\Release\brisko_billing.exe"; DestDir: "{app}"; Flags: ignoreversion

; Supporting files, DLLs, and Data folder
Source: "D:\briskobillingmy\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Brisko Billing"; Filename: "{app}\brisko_billing.exe"
Name: "{autodesktop}\Brisko Billing"; Filename: "{app}\brisko_billing.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\brisko_billing.exe"; Description: "{cm:LaunchProgram,Brisko Billing}"; Flags: nowait postinstall skipifsilent