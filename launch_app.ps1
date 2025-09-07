# CTManager Launcher Script
Write-Host "Starting CTManager..." -ForegroundColor Green

# Check if running as administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if ($isAdmin) {
    Write-Host "Running as administrator - starting app..." -ForegroundColor Green
    Set-Location $PSScriptRoot
    flutter run -d windows
} else {
    Write-Host "Not running as administrator - requesting elevation..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$PSScriptRoot'; flutter run -d windows" -Verb RunAs
}
