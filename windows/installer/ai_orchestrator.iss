#include "ci_generated.iss"

#ifndef AppVersion
  #error AppVersion must be provided by CI
#endif
#ifndef ReleaseDir
  #error ReleaseDir must be provided by CI
#endif
#ifndef VCRedistPath
  #error VCRedistPath must be provided by CI
#endif
#ifndef OutputDir
  #error OutputDir must be provided by CI
#endif

#define AppName "AI Orchestrator"
#define AppExeName "ai_orchestrator.exe"

[Setup]
AppId={{4DB0E2A9-841F-4AC8-BC18-C72DBBA31E42}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=AI Orchestrator
DefaultDirName={autopf}\AI Orchestrator
DefaultGroupName=AI Orchestrator
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExeName}
OutputDir={#OutputDir}
OutputBaseFilename=AI-Orchestrator-Setup-x64
SetupIconFile=..\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
MinVersion=6.1sp1
PrivilegesRequired=admin
CloseApplications=force
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#VCRedistPath}"; DestDir: "{tmp}"; DestName: "vc_redist.x64.exe"; Flags: deleteafterinstall

[Icons]
Name: "{group}\AI Orchestrator"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\AI Orchestrator"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installazione componenti Microsoft Visual C++..."; Flags: waituntilterminated runhidden
Filename: "{app}\{#AppExeName}"; Description: "Avvia AI Orchestrator"; Flags: nowait postinstall skipifsilent
