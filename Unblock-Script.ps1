# Unblock PowerShell Script
# This script removes the "downloaded from the Internet" flag from the Nintex-BulkOperations.ps1 script
# This is the quickest way to eliminate the security warning

#Requires -Version 5.1

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "PowerShell Script Unblock Utility" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

$scriptPath = Join-Path $PSScriptRoot "Nintex-BulkOperations.ps1"

# Check if script exists
if (-not (Test-Path $scriptPath)) {
    Write-Host "Error: Nintex-BulkOperations.ps1 not found in current directory" -ForegroundColor Red
    exit 1
}

Write-Host "Script found: Nintex-BulkOperations.ps1" -ForegroundColor Green
Write-Host ""
Write-Host "This will unblock the script and remove the security warning." -ForegroundColor Yellow
Write-Host ""

# Check if file is currently blocked
$isBlocked = Get-Item $scriptPath -Stream Zone.Identifier -ErrorAction SilentlyContinue

if ($isBlocked) {
    Write-Host "Script is currently blocked (downloaded from Internet)" -ForegroundColor Yellow
    Write-Host "Unblocking script..." -ForegroundColor Cyan

    try {
        Unblock-File -Path $scriptPath
        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Cyan
        Write-Host "SUCCESS!" -ForegroundColor Green
        Write-Host "==========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "The script has been unblocked." -ForegroundColor Green
        Write-Host "You should no longer see the security warning when running it." -ForegroundColor Green
        Write-Host ""
    }
    catch {
        Write-Host ""
        Write-Host "Error unblocking file: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Script is not blocked - no action needed." -ForegroundColor Green
    Write-Host ""
    Write-Host "If you're still seeing security warnings, consider:" -ForegroundColor Yellow
    Write-Host "1. Running Sign-Script.ps1 to self-sign the script" -ForegroundColor Yellow
    Write-Host "2. Adjusting your PowerShell execution policy" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
