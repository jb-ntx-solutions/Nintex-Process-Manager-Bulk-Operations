# Nintex Process Manager - Bulk Update Process Ownership
# Standalone script (extracted from Nintex-BulkOperations.ps1 "Mode 4")
#
# Purpose:
#   Apply a single new Owner and/or Expert to a list of processes.
#   The user supplies:
#     1. A file containing the Process IDs to update (one per line, or a ProcessID column).
#     2. The username of the new Owner and/or new Expert.
#   For each process the script:
#     - Resolves the username to a numeric user Id and display name via the SCIM API
#     - Fetches the process definition
#     - Sets OwnerId/Owner and/or ExpertId/Expert in the definition
#     - Saves the process
#
# Authentication:
#   - Process read/save uses an OAuth token from {SiteURL}/oauth2/token (Username/Password in config).
#   - User lookups use the SCIM API, which requires a separate API key (ScimApiKey in config).
#
# Usage:
#   .\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -NewOwner jonathan@palouse.io -NewExpert jane@palouse.io
#   .\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -NewOwner jonathan@palouse.io -WhatIf
#
#   Any parameter you omit will be prompted for interactively (except -WhatIf).
#
#Requires -Version 5.1

[CmdletBinding()]
param(
    # Path to the configuration file (SiteURL / Username / Password / ScimApiKey).
    [string]$ConfigPath = "config.txt",

    # Path to a file containing the Process IDs to update.
    # Accepts a plain text file (one ID per line) or a CSV with a ProcessID column.
    [string]$ProcessIdFile,

    # Username (or numeric user Id) of the new Owner. Leave blank to skip owner updates.
    # Use one of the "unassign" keywords (see below) to set the owner to "Needs to be reassigned".
    [string]$NewOwner,

    # Username (or numeric user Id) of the new Expert. Leave blank to skip expert updates.
    # Use one of the "unassign" keywords (see below) to set the expert to "Needs to be reassigned".
    [string]$NewExpert,

    # Preview mode: show what would change for each process without saving anything.
    [switch]$WhatIf
)

# ============================================================================
# CONSTANTS
# ============================================================================

# The built-in placeholder user used when a process has no assigned owner/expert.
# This user always has Id = 2 in Nintex Process Manager.
$script:UnassignedUserId   = 2
$script:UnassignedUserName = "Needs to be reassigned N/A"

# Input keywords (case-insensitive) that mean "set this role to the unassigned placeholder".
$script:UnassignKeywords = @('unassigned', 'unassign', 'none', 'n/a', 'na')

# ============================================================================
# CONFIGURATION AND AUTHENTICATION
# ============================================================================

function Read-ConfigFile {
    param([string]$Path = "config.txt")

    if (-not (Test-Path $Path)) {
        Write-Host "Configuration file not found: $Path" -ForegroundColor Red
        Write-Host "Please create a config.txt file based on config.template.txt" -ForegroundColor Yellow
        return $null
    }

    $config = @{}
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()
                $config[$key] = $value
            }
        }
    }

    if (-not $config.SiteURL -or -not $config.Username -or -not $config.Password) {
        Write-Host "Configuration file is missing required fields (SiteURL, Username, Password)" -ForegroundColor Red
        return $null
    }

    if (-not $config.ScimApiKey) {
        Write-Host "Configuration file is missing required field: ScimApiKey" -ForegroundColor Red
        Write-Host "This script resolves usernames via the SCIM API, which needs its own API key." -ForegroundColor Yellow
        return $null
    }

    $config.SiteURL = $config.SiteURL.TrimEnd('/')

    # SCIM base URL is a global Nintex endpoint (not the tenant site). Allow override via config.
    if (-not $config.ScimBaseUrl) {
        $config.ScimBaseUrl = "https://api.promapp.com/api/scim"
    }
    $config.ScimBaseUrl = $config.ScimBaseUrl.TrimEnd('/')

    return $config
}

function Get-AuthToken {
    param(
        [string]$SiteURL,
        [string]$Username,
        [string]$Password
    )

    try {
        $tokenUrl = "$SiteURL/oauth2/token"
        $body = @{
            grant_type = "password"
            username   = $Username
            password   = $Password
            duration   = 60000
        }

        Write-Host "Authenticating to $SiteURL..." -ForegroundColor Cyan
        $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"

        if ($response.access_token) {
            Write-Host "Authentication successful!" -ForegroundColor Green
            return $response.access_token
        } else {
            Write-Host "Authentication failed: No access token received" -ForegroundColor Red
            return $null
        }
    }
    catch {
        Write-Host "Authentication error: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# ============================================================================
# API HELPER FUNCTIONS
# ============================================================================

function Invoke-ApiGet {
    param(
        [string]$Url,
        [string]$Token
    )

    try {
        $headers = @{
            "Authorization"    = "Bearer $Token"
            "Accept"           = "application/json"
            "Content-Type"     = "application/json"
            "X-Requested-With" = "XMLHttpRequest"
        }

        return Invoke-RestMethod -Uri $Url -Method Get -Headers $headers
    }
    catch {
        Write-Host "API GET Error ($Url): $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Invoke-ApiPut {
    param(
        [string]$Url,
        [string]$Token,
        [object]$Body
    )

    try {
        $headers = @{
            "Authorization"    = "Bearer $Token"
            "Content-Type"     = "application/json"
            "Accept"           = "application/json"
            "X-Requested-With" = "XMLHttpRequest"
        }

        $jsonBody = $Body | ConvertTo-Json -Depth 20

        $response = Invoke-RestMethod -Uri $Url -Method Put -Headers $headers -Body $jsonBody -ErrorAction Stop
        return @{ Success = $true; StatusCode = 200; Response = $response }
    }
    catch {
        $errorDetails = $_.Exception.Message
        $statusCode = "Unknown"

        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
                if ($responseBody) {
                    Write-Host "  Response body: $responseBody" -ForegroundColor Gray
                }
            }
            catch { }
        }

        Write-Host "API PUT Error ($Url): HTTP $statusCode - $errorDetails" -ForegroundColor Red
        return @{ Success = $false; StatusCode = $statusCode; Error = $errorDetails }
    }
}

# ============================================================================
# USER RESOLUTION (SCIM API)
# ============================================================================

# Looks up a user via the SCIM API by userName (or by numeric id if a number is given).
# Returns an object with Id (numeric), Name (display name), and UserName, or $null.
function Get-ScimUser {
    param(
        [string]$ScimBaseUrl,
        [string]$ScimApiKey,
        [string]$SearchTerm
    )

    try {
        # A purely numeric term is treated as a user Id; anything else as a userName.
        if ($SearchTerm -match '^\d+$') {
            $filter = "id eq `"$SearchTerm`""
        } else {
            $filter = "userName eq `"$SearchTerm`""
        }

        $url = "$ScimBaseUrl/users?filter=" + [uri]::EscapeDataString($filter)
        $headers = @{
            "Authorization" = "Bearer $ScimApiKey"
            "Accept"        = "application/json"
        }

        $resp = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop

        if (-not $resp -or [int]$resp.totalResults -lt 1) {
            return $null
        }

        $r = @($resp.Resources)[0]
        if (-not $r) { return $null }

        # Build the display name the same way the UI does: prefer an explicit display name,
        # then SCIM's formatted name, then "givenName familyName", then the userName.
        $name = $null
        if ($r.displayName) {
            $name = $r.displayName
        } elseif ($r.name -and $r.name.formatted) {
            $name = $r.name.formatted
        } elseif ($r.name) {
            $name = ("{0} {1}" -f $r.name.givenName, $r.name.familyName).Trim()
        }
        if (-not $name) { $name = $r.userName }

        return [PSCustomObject]@{
            Id       = $r.id
            Name     = $name
            UserName = $r.userName
        }
    }
    catch {
        Write-Host "  SCIM lookup error for '$SearchTerm': $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $b = $reader.ReadToEnd(); $reader.Close()
                if ($b) { Write-Host "    Response body: $b" -ForegroundColor Gray }
            } catch { }
        }
        return $null
    }
}

# Resolves an operator-supplied owner/expert value to a concrete user.
# Handles the "unassign" keywords and SCIM lookups. Returns an object with
# Id / Name / UserName, or $null if it could not be resolved.
function Resolve-User {
    param(
        [string]$ScimBaseUrl,
        [string]$ScimApiKey,
        [string]$SearchTerm,
        [string]$RoleLabel = "user"
    )

    if (-not $SearchTerm) { return $null }

    if ($script:UnassignKeywords -contains $SearchTerm.ToLower()) {
        Write-Host "  [OK] $RoleLabel set to placeholder: $script:UnassignedUserName (id $script:UnassignedUserId)" -ForegroundColor Green
        return [PSCustomObject]@{
            Id       = $script:UnassignedUserId
            Name     = $script:UnassignedUserName
            UserName = "(unassigned)"
        }
    }

    $user = Get-ScimUser -ScimBaseUrl $ScimBaseUrl -ScimApiKey $ScimApiKey -SearchTerm $SearchTerm
    if (-not $user) {
        Write-Host "  [X] $RoleLabel '$SearchTerm' not found via SCIM" -ForegroundColor Red
        return $null
    }

    Write-Host "  [OK] $RoleLabel '$SearchTerm' resolved to: $($user.Name) (id $($user.Id))" -ForegroundColor Green
    return $user
}

# ============================================================================
# PROCESS ID FILE
# ============================================================================

# Reads process IDs from a plain-text file (one ID per line) or a CSV that
# contains a ProcessID-style column. Blank lines and '#' comment lines are ignored.
function Read-ProcessIdFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Host "Process ID file not found: $Path" -ForegroundColor Red
        return @()
    }

    $ids = @()

    # Try CSV first if it has a recognizable header row.
    if ($Path -match '\.csv$') {
        try {
            $csv = Import-Csv -Path $Path
            if ($csv -and $csv.Count -gt 0) {
                $idColumns = @('ProcessID', 'ProcessId', 'Process ID', 'ProcessUniqueId', 'Id', 'ID')
                $headerNames = $csv[0].PSObject.Properties.Name
                $idColumn = $idColumns | Where-Object { $headerNames -contains $_ } | Select-Object -First 1

                if ($idColumn) {
                    foreach ($row in $csv) {
                        $val = "$($row.$idColumn)".Trim()
                        if ($val) { $ids += $val }
                    }
                    return $ids
                }
            }
        }
        catch { }
    }

    # Fall back to one ID per line.
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            # If a line has commas, take the first field (handles a header-less CSV).
            $ids += ($line -split ',')[0].Trim()
        }
    }

    # Drop a leading header token if the first line looks like a column name.
    if ($ids.Count -gt 1 -and $ids[0] -match '^(ProcessID|ProcessId|Process ID|ProcessUniqueId|Id|ID)$') {
        $ids = $ids[1..($ids.Count - 1)]
    }

    return $ids
}

# ============================================================================
# DEFINITION HELPERS
# ============================================================================

# Sets a property on the process definition, adding it if it does not yet exist.
function Set-DefinitionProperty {
    param(
        $ProcessObj,
        [string]$Name,
        $Value
    )
    $ProcessObj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

# Returns a printable value for an existing definition property.
function Get-DefinitionValue {
    param(
        $ProcessObj,
        [string]$Name
    )
    if (-not ($ProcessObj.PSObject.Properties.Name -contains $Name)) { return "(none)" }
    $v = $ProcessObj.$Name
    if ($null -eq $v -or "$v" -eq "") { return "(none)" }
    return "$v"
}

# ============================================================================
# MAIN
# ============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "NINTEX PM - BULK UPDATE PROCESS OWNERSHIP" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# --- Load config and authenticate ---
$config = Read-ConfigFile -Path $ConfigPath
if (-not $config) { return }

$token = Get-AuthToken -SiteURL $config.SiteURL -Username $config.Username -Password $config.Password
if (-not $token) { return }
$siteUrl     = $config.SiteURL
$scimBaseUrl = $config.ScimBaseUrl
$scimApiKey  = $config.ScimApiKey

# --- Gather the process ID file ---
if (-not $ProcessIdFile) {
    $ProcessIdFile = Read-Host "`nEnter the path to the file containing Process IDs (one per line, or a ProcessID column)"
}
$processIds = @(Read-ProcessIdFile -Path $ProcessIdFile)
if (-not $processIds -or $processIds.Count -eq 0) {
    Write-Host "No Process IDs found in '$ProcessIdFile'. Nothing to do." -ForegroundColor Yellow
    return
}
Write-Host "Loaded $($processIds.Count) Process ID(s) from '$ProcessIdFile'" -ForegroundColor Green

# --- Gather the new owner / expert ---
if (-not $PSBoundParameters.ContainsKey('NewOwner') -and -not $PSBoundParameters.ContainsKey('NewExpert')) {
    Write-Host "`nTip: enter a username (e.g. jonathan@palouse.io), or 'unassigned' to clear the role." -ForegroundColor Gray
    $NewOwner  = Read-Host "New Owner username (leave blank to skip)"
    $NewExpert = Read-Host "New Expert username (leave blank to skip)"
}

if (-not $NewOwner -and -not $NewExpert) {
    Write-Host "No new owner or expert provided. Nothing to update." -ForegroundColor Yellow
    return
}

# --- Resolve users via SCIM ---
Write-Host "`nResolving users via SCIM ($scimBaseUrl)..." -ForegroundColor Cyan
$resolvedOwner  = $null
$resolvedExpert = $null

if ($NewOwner) {
    $resolvedOwner = Resolve-User -ScimBaseUrl $scimBaseUrl -ScimApiKey $scimApiKey -SearchTerm $NewOwner -RoleLabel "owner"
    if (-not $resolvedOwner) {
        Write-Host "Owner '$NewOwner' could not be resolved. Aborting (cannot set an owner without a valid user Id)." -ForegroundColor Red
        return
    }
}

if ($NewExpert) {
    $resolvedExpert = Resolve-User -ScimBaseUrl $scimBaseUrl -ScimApiKey $scimApiKey -SearchTerm $NewExpert -RoleLabel "expert"
    if (-not $resolvedExpert) {
        Write-Host "Expert '$NewExpert' could not be resolved. Aborting (cannot set an expert without a valid user Id)." -ForegroundColor Red
        return
    }
}

# --- Summary / confirmation ---
Write-Host "`n----------------------------------------" -ForegroundColor Cyan
if ($WhatIf) { Write-Host "*** PREVIEW MODE: No changes will be made ***" -ForegroundColor Yellow }
Write-Host "Processes to update : $($processIds.Count)" -ForegroundColor White
if ($resolvedOwner)  { Write-Host "New Owner           : $($resolvedOwner.Name) (id $($resolvedOwner.Id))" -ForegroundColor White }
if ($resolvedExpert) { Write-Host "New Expert          : $($resolvedExpert.Name) (id $($resolvedExpert.Id))" -ForegroundColor White }
Write-Host "----------------------------------------" -ForegroundColor Cyan

if (-not $WhatIf) {
    $proceed = Read-Host "Proceed with the update? (Y/N)"
    if ($proceed -ne 'Y') { Write-Host "Operation cancelled" -ForegroundColor Yellow; return }
}

# --- Process each ID ---
$results = @()
$currentIndex = 0
$total = $processIds.Count

foreach ($processId in $processIds) {
    $currentIndex++
    Write-Host "`r  Processing $currentIndex of $total ..." -NoNewline -ForegroundColor Gray

    $resp = Invoke-ApiGet -Url "$siteUrl/Api/v1/Processes/$processId" -Token $token
    if (-not $resp -or -not $resp.processJson) {
        $results += [PSCustomObject]@{
            ProcessID = $processId; ProcessName = ""; Status = "Failed"
            Message = "Process not found or definition unavailable"; ActionUrl = ""
        }
        continue
    }

    $processObj  = $resp.processJson
    $processName = if ($processObj.Name) { $processObj.Name } else { "Unknown" }

    # Describe the intended change for reporting.
    $changes = @()
    if ($resolvedOwner) {
        $changes += "Owner: $(Get-DefinitionValue -ProcessObj $processObj -Name 'Owner') (id $(Get-DefinitionValue -ProcessObj $processObj -Name 'OwnerId')) -> $($resolvedOwner.Name) (id $($resolvedOwner.Id))"
    }
    if ($resolvedExpert) {
        $changes += "Expert: $(Get-DefinitionValue -ProcessObj $processObj -Name 'Expert') (id $(Get-DefinitionValue -ProcessObj $processObj -Name 'ExpertId')) -> $($resolvedExpert.Name) (id $($resolvedExpert.Id))"
    }

    if ($WhatIf) {
        $results += [PSCustomObject]@{
            ProcessID = $processId; ProcessName = $processName; Status = "Preview"
            Message = "Would update '$processName' - $($changes -join '; ')"
            ActionUrl = "$siteUrl/Process/View/$processId"
        }
        continue
    }

    # Apply the changes to the definition (both the numeric Id and the display name).
    if ($resolvedOwner) {
        Set-DefinitionProperty -ProcessObj $processObj -Name 'OwnerId' -Value ([int]$resolvedOwner.Id)
        Set-DefinitionProperty -ProcessObj $processObj -Name 'Owner'   -Value $resolvedOwner.Name
    }
    if ($resolvedExpert) {
        Set-DefinitionProperty -ProcessObj $processObj -Name 'ExpertId' -Value ([int]$resolvedExpert.Id)
        Set-DefinitionProperty -ProcessObj $processObj -Name 'Expert'   -Value $resolvedExpert.Name
    }

    # Save: ProcessJson must be sent as an escaped JSON STRING (per API_ARCHITECTURE.md).
    $processJsonString = $processObj | ConvertTo-Json -Depth 20 -Compress
    $updateBody = @{
        ProcessJson                       = $processJsonString
        ChangeDescription                 = "Bulk ownership update"
        DoSubmitForApproval               = $false
        DoPublish                         = $false
        SuppressChangeNotification        = $false
        SharedActivityCollectionEditModel = @{
            ActivitiesToDelete = @()
            ActivitiesToShare  = @()
            ActivitiesToUnlink = @()
        }
        VariantConnectionChangeStates     = @()
    }

    $updateResult = Invoke-ApiPut -Url "$siteUrl/Api/v1/Processes/$processId" -Token $token -Body $updateBody

    if ($updateResult -and $updateResult.Success) {
        $results += [PSCustomObject]@{
            ProcessID = $processId; ProcessName = $processName; Status = "Success"
            Message = ($changes -join '; '); ActionUrl = "$siteUrl/Process/View/$processId"
        }
    } else {
        $msg = if ($updateResult.Error) { "Save failed: $($updateResult.Error)" } else { "Save failed" }
        $results += [PSCustomObject]@{
            ProcessID = $processId; ProcessName = $processName; Status = "Failed"
            Message = $msg; ActionUrl = "$siteUrl/Process/View/$processId"
        }
    }
}
Write-Host ""   # newline after progress counter

# --- Save results and print summary ---
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outputPath = if ($WhatIf) { "UpdateOwnership_Preview_$timestamp.csv" } else { "UpdateOwnership_Results_$timestamp.csv" }
$results | Export-Csv -Path $outputPath -NoTypeInformation

Write-Host ""
if ($WhatIf) {
    Write-Host "Preview results saved to: $outputPath" -ForegroundColor Yellow
    Write-Host "Total checked   : $($results.Count)" -ForegroundColor Cyan
    Write-Host "Would update    : $(($results | Where-Object { $_.Status -eq 'Preview' }).Count)" -ForegroundColor Yellow
    Write-Host "Failed to check : $(($results | Where-Object { $_.Status -eq 'Failed' }).Count)" -ForegroundColor Red
    Write-Host "`n*** This was a PREVIEW - no changes were made ***" -ForegroundColor Yellow
} else {
    Write-Host "Results saved to: $outputPath" -ForegroundColor Green
    Write-Host "Total operations: $($results.Count)" -ForegroundColor Cyan
    Write-Host "Successful      : $(($results | Where-Object { $_.Status -eq 'Success' }).Count)" -ForegroundColor Green
    Write-Host "Failed          : $(($results | Where-Object { $_.Status -eq 'Failed' }).Count)" -ForegroundColor Red
}
