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
#ifdef AivexusRecoveryHelper
; Do not forcibly terminate the old app while making a consistent snapshot.
CloseApplications=yes
#else
CloseApplications=force
#endif
RestartApplications=no
SetupLogging=yes
#ifdef AivexusTrustedSignedBuild
; SignTool must be provided by the CI compiler command line. Inno embeds
; signatures in Setup, Uninstaller AND temporary Setup self-copies (error 4551).
SignTool=aivexus_ci
SignedUninstaller=yes
#else
; Legacy unsigned builds remain possible only for non-public QA workflows.
; The owner-only Windows beta release workflow refuses to publish such builds.
SignedUninstaller=no
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
#ifdef AivexusRecoveryHelper
; Recovery helper lives outside {app}: it remains runnable when a new app
; cannot start, and never replaces the old program before snapshot success.
Source: "{#AivexusRecoveryHelper}"; Flags: dontcopy
Source: "{#AivexusRecoveryHelper}"; DestDir: "{commonappdata}\AI Orchestrator\Recovery"; Flags: ignoreversion
; This is the FIRST application file processed, after Restart Manager closes
; the old app but BEFORE any existing AIVEXUS binaries are overwritten.
Source: "{#ReleaseDir}\ai_orchestrator.exe"; DestDir: "{app}"; Flags: ignoreversion; BeforeInstall: SnapshotInstalledVersion
Source: "{#ReleaseDir}\*"; Excludes: "ai_orchestrator.exe"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#else
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#endif
Source: "{#VCRedistPath}"; DestDir: "{tmp}"; DestName: "vc_redist.x64.exe"; Flags: deleteafterinstall

[Icons]
Name: "{group}\AI Orchestrator"; Filename: "{app}\{#AppExeName}"
Name: "{group}\AI Orchestrator - diagnostica Win7 (senza plugin)"; Filename: "{app}\{#AppExeName}"; Parameters: "--win7-no-plugins"; Comment: "Avvio diagnostico Windows 7 senza registrazione plugin"
Name: "{group}\AI Orchestrator - apri log diagnostico Win7"; Filename: "{sys}\notepad.exe"; Parameters: """{localappdata}\AI-Orchestrator\Diagnostics\AI-Orchestrator-win7-startup.log"""; Comment: "Apre il trace di avvio Windows 7"
Name: "{autodesktop}\AI Orchestrator"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon
#ifdef AivexusRecoveryHelper
; The recovery utility is a signed, admin-elevating helper located outside the
; application directory. It works even if the upgraded Flutter app will not.
Name: "{group}\AI Orchestrator - Recupera versione precedente"; Filename: "{commonappdata}\AI Orchestrator\Recovery\AivexusRecovery.exe"; Parameters: "--mode restore --app ""{app}"" --data ""{localappdata}\AI Orchestrator"" --store ""{commonappdata}\AI Orchestrator\Recovery\Snapshots"""; Comment: "Ripristina la versione precedente da un backup SHA-256 verificato"
#endif

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installazione componenti Microsoft Visual C++..."; Flags: waituntilterminated runhidden
Filename: "{app}\{#AppExeName}"; Description: "Avvia AI Orchestrator"; Flags: nowait postinstall skipifsilent

#ifdef AivexusRecoveryHelper
[Code]
var
  SnapshotAttempted: Boolean;

procedure SnapshotInstalledVersion();
var
  AppDir, DataDir, StoreDir, Utility, Args: String;
  ResultCode: Integer;
begin
  if SnapshotAttempted then
    Exit;
  SnapshotAttempted := True;

  AppDir := ExpandConstant('{app}');
  if not FileExists(AddBackslash(AppDir) + '{#AppExeName}') then
    Exit;  { Brand-new installation; there is no old version to save. }

  ExtractTemporaryFile('AivexusRecovery.exe');
  Utility := ExpandConstant('{tmp}\AivexusRecovery.exe');
  DataDir := ExpandConstant('{localappdata}\AI Orchestrator');
  StoreDir := ExpandConstant('{commonappdata}\AI Orchestrator\Recovery\Snapshots');
  Args := '--mode backup --app "' + AppDir + '" --data "' +
    DataDir + '" --store "' + StoreDir + '"';

  Log('AIVEXUS: verifying prior installation snapshot before touching app files.');
  if not Exec(Utility, Args, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    RaiseException('Cannot launch backup verifier. Installation cancelled.');
  if ResultCode <> 0 then
    RaiseException('Previous AIVEXUS version could not be safely backed up. ' +
      'The existing installation will be preserved. Check free disk space, ' +
      'close AIVEXUS and review the recovery log.');
  Log('AIVEXUS: verified recovery snapshot committed. Proceeding with upgrade.');
end;
#endif
