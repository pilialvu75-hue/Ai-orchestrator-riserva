@echo off
setlocal EnableExtensions

set "SOURCE=%LOCALAPPDATA%\AI-Orchestrator\Diagnostics"
set "DEST=%USERPROFILE%\Desktop\AI-Orchestrator-Diagnostics"

if not exist "%DEST%" mkdir "%DEST%" >nul 2>&1

>"%DEST%\collection-info.txt" echo AI Orchestrator Windows diagnostics collection
>>"%DEST%\collection-info.txt" echo Date: %DATE%
>>"%DEST%\collection-info.txt" echo Time: %TIME%
>>"%DEST%\collection-info.txt" echo Computer: %COMPUTERNAME%
>>"%DEST%\collection-info.txt" echo User: %USERNAME%
>>"%DEST%\collection-info.txt" echo Source: %SOURCE%

if exist "%SOURCE%\AI-Orchestrator-win7-startup.log" copy /Y "%SOURCE%\AI-Orchestrator-win7-startup.log" "%DEST%\" >nul
if exist "%SOURCE%\AI-Orchestrator-win7-startup.previous.log" copy /Y "%SOURCE%\AI-Orchestrator-win7-startup.previous.log" "%DEST%\" >nul
if exist "%SOURCE%\AI-Orchestrator-win7-crash.dmp" copy /Y "%SOURCE%\AI-Orchestrator-win7-crash.dmp" "%DEST%\" >nul
if exist "%SOURCE%\AI-Orchestrator-win7-crash.previous.dmp" copy /Y "%SOURCE%\AI-Orchestrator-win7-crash.previous.dmp" "%DEST%\" >nul
if exist "%SOURCE%\AI-Orchestrator-windows-probe.txt" copy /Y "%SOURCE%\AI-Orchestrator-windows-probe.txt" "%DEST%\" >nul
if exist "%SOURCE%\AI-Orchestrator-graphics-probe.txt" copy /Y "%SOURCE%\AI-Orchestrator-graphics-probe.txt" "%DEST%\" >nul

if exist "%TEMP%\AI-Orchestrator-win7-startup.log" copy /Y "%TEMP%\AI-Orchestrator-win7-startup.log" "%DEST%\AI-Orchestrator-win7-startup-temp.log" >nul
if exist "%TEMP%\AI-Orchestrator-win7-startup.previous.log" copy /Y "%TEMP%\AI-Orchestrator-win7-startup.previous.log" "%DEST%\AI-Orchestrator-win7-startup-previous-temp.log" >nul
if exist "%TEMP%\AI-Orchestrator-win7-crash.dmp" copy /Y "%TEMP%\AI-Orchestrator-win7-crash.dmp" "%DEST%\AI-Orchestrator-win7-crash-temp.dmp" >nul
if exist "%TEMP%\AI-Orchestrator-win7-crash.previous.dmp" copy /Y "%TEMP%\AI-Orchestrator-win7-crash.previous.dmp" "%DEST%\AI-Orchestrator-win7-crash-previous-temp.dmp" >nul
if exist "%TEMP%\AI-Orchestrator-windows-probe.txt" copy /Y "%TEMP%\AI-Orchestrator-windows-probe.txt" "%DEST%\AI-Orchestrator-windows-probe-temp.txt" >nul
if exist "%TEMP%\AI-Orchestrator-graphics-probe.txt" copy /Y "%TEMP%\AI-Orchestrator-graphics-probe.txt" "%DEST%\AI-Orchestrator-graphics-probe-temp.txt" >nul

ver >"%DEST%\windows-version.txt" 2>&1
systeminfo >"%DEST%\systeminfo.txt" 2>&1

>>"%DEST%\collection-info.txt" echo.
>>"%DEST%\collection-info.txt" echo Files collected:
dir /B "%DEST%" >>"%DEST%\collection-info.txt" 2>&1

start "" explorer.exe "%DEST%"
endlocal
