@echo off
title CTManager Launcher
echo ========================================
echo    CTManager - Cloudflare Tunnel Manager
echo ========================================
echo.

REM Check if already running as administrator
net session >nul 2>&1
if %errorLevel% == 0 (
    echo [INFO] Running as administrator - starting app...
    echo.
    flutter run -d windows
) else (
    echo [WARNING] Not running as administrator
    echo [INFO] Requesting elevation to start the app...
    echo.
    powershell -Command "Start-Process cmd -ArgumentList '/c cd /d \"%cd%\" && flutter run -d windows' -Verb RunAs"
)

pause
