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

#ifdef AivexusWin81UnsignedQABuild
  #ifndef AivexusRecoveryHelper
    #error A Windows 8.1 unsigned QA installation must include a verified recovery helper
  #endif
  #ifdef AivexusTrustedSignedBuild
    #error Windows 8.1 unsigned QA build may not masquerade as signed release
  #endif
#endif

#if FileExists(ReleaseDir + "\runtime-cuda\llama-server.exe")
  #define AivexusHasCudaRuntime
#endif
#if FileExists(ReleaseDir + "\runtime-vulkan\llama-server.exe")
  #define AivexusHasVulkanRuntime
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
#ifdef AivexusWin81UnsignedQABuild
; Explicit owner-only diagnostic exception. Do not use on Windows 10/11.
; Windows 8.1 reports NT version 6.3; Windows 10/11 reports 10.0.
MinVersion=6.3
OnlyBelowVersion=10.0
#else
MinVersion=6.1sp1
#endif
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
Source: "{#ReleaseDir}\*"; Excludes: "ai_orchestrator.exe,\runtime-cuda\*,\runtime-vulkan\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#else
Source: "{#ReleaseDir}\*"; Excludes: "\runtime-cuda\*,\runtime-vulkan\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#endif
#ifdef AivexusHasCudaRuntime
Source: "{#ReleaseDir}\runtime-cuda\*"; DestDir: "{app}\runtime-cuda"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: InstallCudaRuntime
#endif
#ifdef AivexusHasVulkanRuntime
Source: "{#ReleaseDir}\runtime-vulkan\*"; DestDir: "{app}\runtime-vulkan"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: InstallVulkanRuntime
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
Name: "{group}\AI Orchestrator - Recupera versione precedente"; Filename: "{commonappdata}\AI Orchestrator\Recovery\AivexusRecovery.exe"; Parameters: "--mode restore --app ""{app}"" --data ""{localappdata}\AI Orchestrator"" --roaming ""{userappdata}\com.aiorchestrator\AI Orchestrator"" --store ""{commonappdata}\AI Orchestrator\Recovery\Snapshots"""; Comment: "Ripristina la versione precedente da un backup SHA-256 verificato"
Name: "{group}\AI Orchestrator - Conferma aggiornamento funzionante"; Filename: "{commonappdata}\AI Orchestrator\Recovery\AivexusRecovery.exe"; Parameters: "--mode accept --app ""{app}"" --data ""{localappdata}\AI Orchestrator"" --roaming ""{userappdata}\com.aiorchestrator\AI Orchestrator"" --store ""{commonappdata}\AI Orchestrator\Recovery\Snapshots"""; Comment: "Conferma la nuova versione solo dopo il collaudo; conserva lo storico del backup"
#endif

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installazione componenti Microsoft Visual C++..."; Flags: waituntilterminated runhidden; Check: NeedVCRedistRun
Filename: "{app}\{#AppExeName}"; Description: "Avvia AI Orchestrator"; Flags: nowait postinstall skipifsilent

[Code]
var
  CudaSupported, VulkanSupported, GpuProbePrepared, VCRedistPrepared: Boolean;
#ifdef AivexusRecoveryHelper
  SnapshotAttempted: Boolean;
#endif

function NeedVCRedistRun(): Boolean;
begin
  Result := not VCRedistPrepared;
end;

function DriverCandidate(const DriverDll: String): Boolean;
begin
  Result := (GetWindowsVersion >= $0A000000) and
    FileExists(ExpandConstant('{sys}\') + DriverDll);
end;

function InstallCudaRuntime(): Boolean;
begin
  Result := CudaSupported;
end;

function InstallVulkanRuntime(): Boolean;
begin
  Result := VulkanSupported;
end;

function PSQuote(Value: String): String;
begin
  StringChangeEx(Value, #39, #39 + #39, True);
  Result := #39 + Value + #39;
end;

{ Probe the exact bundled server in Setup's private temporary directory.
  A device listing is a driver/runtime startup check, not an inference test.
  Never download or install GPU drivers here. Unknown or failed probes skip
  the new GPU files. The existing recovery snapshot still runs before copies. }
function ProbeGpuRuntime(const Backend, DriverDll, DevicePattern: String): Boolean;
var
  ProbeDir, Server, Command, PowerShell: String;
  ResultCode: Integer;
begin
  Result := False;
  if (GetWindowsVersion < $0A000000) or
     (not FileExists(ExpandConstant('{sys}\') + DriverDll)) then begin
    Log('AIVEXUS GPU ' + Backend + ': unsupported OS or driver loader missing; skip.');
    Exit;
  end;
  PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  if not FileExists(PowerShell) then begin
    Log('AIVEXUS GPU ' + Backend + ': probe unavailable; skip.');
    Exit;
  end;
  try
    ExtractTemporaryFiles('{app}\runtime-' + Backend + '\*');
    ProbeDir := ExpandConstant('{tmp}\') + '{app}\runtime-' + Backend;
    Server := AddBackslash(ProbeDir) + 'llama-server.exe';
    if not FileExists(Server) then
      Exit;
    Command := '$ErrorActionPreference=''Stop''; try { ' +
      '$server=' + PSQuote(Server) + '; ' +
      '$out=$server+''.probe-out''; $err=$server+''.probe-err''; ' +
      '$p=Start-Process -FilePath $server -ArgumentList ''--list-devices'' ' +
      '-WorkingDirectory ' + PSQuote(ProbeDir) + ' -PassThru -WindowStyle Hidden ' +
      '-RedirectStandardOutput $out -RedirectStandardError $err; ' +
      'if(-not $p.WaitForExit(15000)){try{$p.Kill()}catch{};exit 2}; ' +
      'if($p.ExitCode -ne 0){exit 3}; ' +
      '$lines=[IO.File]::ReadAllText($out)+[Environment]::NewLine+[IO.File]::ReadAllText($err); ' +
      '$matches=[regex]::Matches($lines,' + PSQuote(DevicePattern) + '); ' +
      'foreach($m in $matches){if(([long]$m.Groups[1].Value -gt 0) -and ' +
      '([long]$m.Groups[2].Value -le [long]$m.Groups[1].Value)){exit 0}}; ' +
      'exit 4 } catch {exit 5}';
    if Exec(PowerShell, '-NoLogo -NoProfile -NonInteractive -Command "' + Command + '"',
      ProbeDir, SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
      Result := ResultCode = 0;
      Log('AIVEXUS GPU ' + Backend + ': probe exit=' + IntToStr(ResultCode));
    end;
  except
    Log('AIVEXUS GPU ' + Backend + ': probe failed; skip new backend files.');
  end;
end;

function InitializeSetup(): Boolean;
begin
  { Provisional candidates count towards the pre-install disk estimate.
    PrepareToInstall performs the actual probe before any application copy. }
  CudaSupported := False;
  VulkanSupported := False;
  GpuProbePrepared := False;
  VCRedistPrepared := False;
#ifdef AivexusHasCudaRuntime
  CudaSupported := DriverCandidate('nvcuda.dll');
#endif
#ifdef AivexusHasVulkanRuntime
  VulkanSupported := DriverCandidate('vulkan-1.dll');
#endif
  Result := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Installed: Cardinal;
  ResultCode: Integer;
begin
  Result := '';
  if GpuProbePrepared then Exit;
  GpuProbePrepared := True;
  if CudaSupported or VulkanSupported then begin
    { The VC redistributable is already included in the approved installation.
      On a fresh machine install it before probing the GPU executable, otherwise
      a missing VC loader would incorrectly exclude supported hardware. }
    if not RegQueryDWordValue(HKLM64,
      'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) or
      (Installed <> 1) then begin
      try
        ExtractTemporaryFile('vc_redist.x64.exe');
        if Exec(ExpandConstant('{tmp}\vc_redist.x64.exe'), '/install /quiet /norestart',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
          VCRedistPrepared := (ResultCode = 0) or (ResultCode = 1638) or
            (ResultCode = 3010);
          Log('AIVEXUS GPU prerequisite VC redistributable exit=' + IntToStr(ResultCode));
        end;
      except
        Log('AIVEXUS GPU prerequisite probe unavailable; normal redist install remains enabled.');
      end;
    end;
  end;
#ifdef AivexusHasCudaRuntime
  if CudaSupported then
    CudaSupported := ProbeGpuRuntime('cuda', 'nvcuda.dll',
      '(?m)\bCUDA\d+:\s*NVIDIA[^\r\n]*\((\d+) MiB,\s*(\d+) MiB free\)');
#endif
#ifdef AivexusHasVulkanRuntime
  if VulkanSupported then
    VulkanSupported := ProbeGpuRuntime('vulkan', 'vulkan-1.dll',
      '(?mi)\bVulkan\d+:\s*(?:NVIDIA|AMD|Intel|ATI|Radeon)[^\r\n]*\((\d+) MiB,\s*(\d+) MiB free\)');
#endif
  Log('AIVEXUS GPU selective install: CUDA=' + IntToStr(Ord(CudaSupported)) +
    ' Vulkan=' + IntToStr(Ord(VulkanSupported)));
end;

#ifdef AivexusRecoveryHelper

procedure SnapshotInstalledVersion();
var
  AppDir, DataDir, RoamingDir, StoreDir, Utility, Args: String;
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
  RoamingDir := ExpandConstant('{userappdata}\com.aiorchestrator\AI Orchestrator');
  StoreDir := ExpandConstant('{commonappdata}\AI Orchestrator\Recovery\Snapshots');
  Args := '--mode backup --app "' + AppDir + '" --data "' +
    DataDir + '" --roaming "' + RoamingDir + '" --store "' + StoreDir + '"';

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
