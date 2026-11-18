# Ads Kill Windows — 0.1.0-beta1

Portable Windows 11 **x64** beta (not Windows 8.1). Built independently from the Android app and AI Orchestrator. Source lives under ads-kill/windows.

## Actual features

- Native Windows Forms UI on .NET 10 LTS, bundled in a self-contained single-file executable (no .NET installer required).
- Adds its **own marked section** with 30 exact advertising hostnames to the Windows HOSTS file, covering IPv4 (0.0.0.0) and IPv6 (::).
- Before every actual change, saves the complete original HOSTS file bytes to C:\ProgramData\AdsKill\backups.
- Makes an atomic replacement and leaves unrelated existing HOSTS lines intact.
- Flushes the Windows DNS cache after changes, or reports a warning.
- **Attiva blocco** and **Disattiva blocco** buttons; **Ricompensa: 60 s** temporarily removes the block across the whole PC and restores it after 60 seconds while the app is running. Closing the app normally during the pause restores protection before exiting.

## Limitations and privacy

- No network driver, system proxy, VPN, browser extension, telemetry, accounts, subscriptions or remote AIVEXUS service.
- HOSTS rules match only exact names. Applications using their own hardcoded IP or custom encrypted DNS can bypass this.
- Cannot reliably remove YouTube in-stream video ads. No request counters: the displayed number is the **number of HOSTS rules**, not measured traffic.
- Windows UAC administrator confirmation is required to modify HOSTS. The beta executable is unsigned. Windows Smart App Control/Defender may block it: do NOT weaken Windows security settings merely to run a test build.
- The reward pause is global, not limited to a single game. If the app is force-terminated or the PC loses power during pause, protection may remain off. On reopening click Attiva blocco.
- Blocking rules persist across program exits and Windows restarts until you click Disattiva blocco, or remove the marked section manually.
- Windows 8.1 is not supported by the .NET 10 binary. A separate legacy adaptation can follow.
- No background service, auto-updater, automatic list update or code signature in this initial prototype.

## First test on ASUS Windows 11

1. Download the prerelease asset named AdsKill-Windows-v0.1.0-beta1-win-x64.zip.
2. Unzip into an ordinary folder, then run AdsKill.Windows.exe. Only approve UAC if you trust the test build.
3. Click Attiva blocco and browse normally; use Disattiva blocco to revert. Observe any interference with games or websites.
4. To test rewarded ads, click Ricompensa: 60 s, leave the window open, test the game's ad and verify automatic reactivation.
5. If Smart App Control blocks the unsigned executable, do not turn off Defender/Smart App Control. Report the exact error.

## Manual recovery if app is inaccessible

1. Launch Notepad as administrator.
2. Open C:\Windows\System32\drivers\etc\hosts (show 'All files').
3. Delete only entries between # ADS-KILL BEGIN v1 and # ADS-KILL END v1, including those two marker lines.
4. Save the file. In an elevated command prompt run: ipconfig /flushdns.
5. Original-file backups are in C:\ProgramData\AdsKill\backups.

## Build and test (Windows 11 + .NET 10 SDK)

  dotnet run --project ads-kill/windows/AdsKill.Windows.Tests/AdsKill.Windows.Tests.csproj -c Release

  dotnet publish ads-kill/windows/AdsKill.Windows/AdsKill.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:DebugType=None -o dist

Code signing and a separate dedicated repository are future improvements. This prototype uses the existing GitHub repository as a source/build host, not a runtime dependency.
