@echo off
setlocal EnableExtensions
title AI Orchestrator - Raccogli diagnostica Windows

echo [1/5] Individuo la cartella Desktop...
set "DESKTOP="
set "DESKTOP_RAW="
for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v Desktop 2^>nul ^| find /i "Desktop"') do set "DESKTOP_RAW=%%B"
if defined DESKTOP_RAW call set "DESKTOP=%%DESKTOP_RAW%%"
if not defined DESKTOP set "DESKTOP=%USERPROFILE%\Desktop"

set "SOURCE=%LOCALAPPDATA%\AI-Orchestrator\Diagnostics"
set "DEST=%DESKTOP%\AI-Orchestrator-Diagnostics"

echo [2/5] Creo la cartella di raccolta...
if not exist "%DEST%" mkdir "%DEST%" >nul 2>&1
if not exist "%DEST%" (
  echo ERRORE: impossibile creare "%DEST%"
  echo Premi un tasto per chiudere.
  pause >nul
  exit /b 2
)

>"%DEST%\collection-info.txt" echo AI Orchestrator Windows diagnostics collection
>>"%DEST%\collection-info.txt" echo Date: %DATE%
>>"%DEST%\collection-info.txt" echo Time: %TIME%
>>"%DEST%\collection-info.txt" echo Computer: %COMPUTERNAME%
>>"%DEST%\collection-info.txt" echo User: %USERNAME%
>>"%DEST%\collection-info.txt" echo Source: %SOURCE%
>>"%DEST%\collection-info.txt" echo Desktop: %DESKTOP%

echo [3/5] Copio log, dump e rapporti disponibili...
if exist "%SOURCE%\AI-Orchestrator-*" (
  for %%F in ("%SOURCE%\AI-Orchestrator-*") do if exist "%%~fF" copy /Y "%%~fF" "%DEST%\%%~nxF" >nul 2>&1
)
if exist "%TEMP%\AI-Orchestrator-win7-startup.log" copy /Y "%TEMP%\AI-Orchestrator-win7-startup.log" "%DEST%\AI-Orchestrator-win7-startup-temp.log" >nul 2>&1
if exist "%TEMP%\AI-Orchestrator-win7-startup.previous.log" copy /Y "%TEMP%\AI-Orchestrator-win7-startup.previous.log" "%DEST%\AI-Orchestrator-win7-startup-previous-temp.log" >nul 2>&1
if exist "%TEMP%\AI-Orchestrator-win7-crash.dmp" copy /Y "%TEMP%\AI-Orchestrator-win7-crash.dmp" "%DEST%\AI-Orchestrator-win7-crash-temp.dmp" >nul 2>&1
if exist "%TEMP%\AI-Orchestrator-win7-crash.previous.dmp" copy /Y "%TEMP%\AI-Orchestrator-win7-crash.previous.dmp" "%DEST%\AI-Orchestrator-win7-crash-previous-temp.dmp" >nul 2>&1
if exist "%TEMP%\AI-Orchestrator-windows-probe.txt" copy /Y "%TEMP%\AI-Orchestrator-windows-probe.txt" "%DEST%\AI-Orchestrator-windows-probe-temp.txt" >nul 2>&1
if exist "%TEMP%\AI-Orchestrator-graphics-probe.txt" copy /Y "%TEMP%\AI-Orchestrator-graphics-probe.txt" "%DEST%\AI-Orchestrator-graphics-probe-temp.txt" >nul 2>&1

echo [4/5] Registro informazioni Windows essenziali...
ver >"%DEST%\windows-version.txt" 2>&1
(
  echo PROCESSOR_ARCHITECTURE=%PROCESSOR_ARCHITECTURE%
  echo PROCESSOR_IDENTIFIER=%PROCESSOR_IDENTIFIER%
  echo NUMBER_OF_PROCESSORS=%NUMBER_OF_PROCESSORS%
  echo LOCALAPPDATA=%LOCALAPPDATA%
  echo TEMP=%TEMP%
) >"%DEST%\environment.txt"

REM Intentionally do not call systeminfo here. On some Windows 7 machines its
REM WMI query can block indefinitely, which would make the collector appear hung.
>>"%DEST%\collection-info.txt" echo systeminfo: skipped intentionally to keep collection non-blocking
>>"%DEST%\collection-info.txt" echo.
>>"%DEST%\collection-info.txt" echo Files collected:
dir /B "%DEST%" >>"%DEST%\collection-info.txt" 2>&1

echo [5/5] Apro la cartella dei risultati...
start "" explorer.exe "%DEST%"
echo Fatto. La cartella e':
echo %DEST%
timeout /t 3 /nobreak >nul 2>&1
endlocal
