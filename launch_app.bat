@echo off
echo Starting CTManager with proper elevation...
echo.

REM Check if already running as administrator
net session >nul 2>&1
if %errorLevel% == 0 (
    echo Running as administrator - starting app...
    flutter run -d windows
) else (
    echo Not running as administrator - requesting elevation...
    powershell -Command "Start-Process cmd -ArgumentList '/c cd /d \"%cd%\" && flutter run -d windows' -Verb RunAs"
)
