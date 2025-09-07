@echo off
title CTManager
echo ========================================
echo    CTManager - Cloudflare Tunnel Manager
echo ========================================
echo.

REM Check if already running as administrator
net session >nul 2>&1
if %errorLevel% == 0 (
    echo [INFO] Running as administrator - starting app...
    echo.
    "build\windows\x64\runner\Release\ctmanager.exe"
) else (
    echo [WARNING] Not running as administrator
    echo [INFO] Requesting elevation to start the app...
    echo.
    powershell -Command "Start-Process cmd -ArgumentList '/c cd /d \"%cd%\" && \"build\windows\x64\runner\Release\ctmanager.exe\"' -Verb RunAs"
)

pause
