# Self-Sign PowerShell Script
# This script creates a self-signed code signing certificate and signs the Nintex-BulkOperations.ps1 script
# This will eliminate the "Unknown Publisher" warning on your local machine

#Requires -Version 5.1
#Requires -RunAsAdministrator

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "PowerShell Script Self-Signing Utility" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script will:" -ForegroundColor Yellow
Write-Host "1. Create a self-signed code signing certificate" -ForegroundColor Yellow
Write-Host "2. Install it to your Trusted Root Certification Authorities" -ForegroundColor Yellow
Write-Host "3. Sign the Nintex-BulkOperations.ps1 script" -ForegroundColor Yellow
Write-Host ""
Write-Host "NOTE: This must be run as Administrator" -ForegroundColor Red
Write-Host ""

# Confirm before proceeding
$confirm = Read-Host "Do you want to continue? (Y/N)"
if ($confirm -ne 'Y' -and $confirm -ne 'y') {
    Write-Host "Operation cancelled." -ForegroundColor Yellow
    exit
}

try {
    # Define certificate parameters
    $certName = "Nintex Bulk Operations Self-Signed"
    $scriptPath = Join-Path $PSScriptRoot "Nintex-BulkOperations.ps1"

    # Check if script exists
    if (-not (Test-Path $scriptPath)) {
        Write-Host "Error: Nintex-BulkOperations.ps1 not found in current directory" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "Step 1: Checking for existing certificate..." -ForegroundColor Cyan

    # Check if certificate already exists
    $existingCert = Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object {
        $_.Subject -eq "CN=$certName" -and $_.NotAfter -gt (Get-Date)
    } | Select-Object -First 1

    if ($existingCert) {
        Write-Host "Found existing valid certificate: $($existingCert.Thumbprint)" -ForegroundColor Green
        $cert = $existingCert
    } else {
        Write-Host "Creating new self-signed certificate..." -ForegroundColor Yellow

        # Create self-signed certificate for code signing
        $cert = New-SelfSignedCertificate `
            -Subject $certName `
            -Type CodeSigningCert `
            -CertStoreLocation Cert:\CurrentUser\My `
            -NotAfter (Get-Date).AddYears(5) `
            -HashAlgorithm SHA256

        Write-Host "Certificate created: $($cert.Thumbprint)" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Step 2: Installing certificate to Trusted Root..." -ForegroundColor Cyan

    # Export and import to Trusted Root (requires admin)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
    )

    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

        # Check if already in Trusted Root
        $existingRoot = $store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }

        if (-not $existingRoot) {
            $store.Add($cert)
            Write-Host "Certificate installed to Trusted Root Certification Authorities" -ForegroundColor Green
        } else {
            Write-Host "Certificate already in Trusted Root" -ForegroundColor Green
        }
    }
    finally {
        $store.Close()
    }

    Write-Host ""
    Write-Host "Step 3: Signing PowerShell script..." -ForegroundColor Cyan

    # Sign the script
    $result = Set-AuthenticodeSignature -FilePath $scriptPath -Certificate $cert -HashAlgorithm SHA256

    if ($result.Status -eq 'Valid') {
        Write-Host "Script signed successfully!" -ForegroundColor Green
        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Cyan
        Write-Host "SUCCESS!" -ForegroundColor Green
        Write-Host "==========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "The Nintex-BulkOperations.ps1 script has been signed." -ForegroundColor Green
        Write-Host "You should no longer see the 'Unknown Publisher' warning." -ForegroundColor Green
        Write-Host ""
        Write-Host "Certificate Details:" -ForegroundColor Cyan
        Write-Host "  Subject: $($cert.Subject)" -ForegroundColor White
        Write-Host "  Thumbprint: $($cert.Thumbprint)" -ForegroundColor White
        Write-Host "  Expires: $($cert.NotAfter)" -ForegroundColor White
        Write-Host ""
    } else {
        Write-Host "Warning: Signature status is '$($result.Status)'" -ForegroundColor Yellow
        Write-Host "Status Message: $($result.StatusMessage)" -ForegroundColor Yellow
    }
}
catch {
    Write-Host ""
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Common issues:" -ForegroundColor Yellow
    Write-Host "- Make sure you are running PowerShell as Administrator" -ForegroundColor Yellow
    Write-Host "- Check that the script file exists and is not in use" -ForegroundColor Yellow
    exit 1
}
