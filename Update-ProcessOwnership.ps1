# Nintex Process Manager - Bulk Update Process Ownership
# Standalone script (extracted from Nintex-BulkOperations.ps1 "Mode 4")
#
# Purpose:
#   Update the Owner and/or Expert on a list of processes, per process, from a CSV.
#   The CSV contains one row per process with the new owner/expert username(s).
#   For each row the script:
#     - Resolves the username to a numeric user Id and display name via the SCIM API
#     - Fetches the process definition
#     - Sets OwnerId/Owner and/or ExpertId/Expert in the definition
#     - Saves the process
#
# CSV format (flexible column names - see helpers below):
#     ProcessID,NewOwner,NewExpert
#     1234,jonathan@palouse.io,jane@palouse.io
#     1235,,jane@palouse.io            <- blank owner: owner left unchanged
#     1236,unassigned,                 <- owner set to "Needs to be reassigned N/A"
#
#   - Leave a cell BLANK to leave that role unchanged.
#   - Use an unassign keyword (unassigned / unassign / none / n/a / na) to set the
#     role to the built-in "Needs to be reassigned N/A" placeholder (user Id 2).
#
# Authentication:
#   - Process read/save uses an OAuth token from {SiteURL}/oauth2/token (Username/Password in config).
#   - User lookups use the SCIM API, which requires a separate API key (ScimApiKey in config).
#
# Usage:
#   .\Update-ProcessOwnership.ps1 -CsvPath .\update-ownership.csv
#   .\Update-ProcessOwnership.ps1 -CsvPath .\update-ownership.csv -WhatIf
#
#Requires -Version 5.1

[CmdletBinding()]
param(
    # Path to the configuration file (SiteURL / Username / Password / ScimApiKey).
    [string]$ConfigPath = "config.txt",

    # Path to the CSV containing ProcessID, NewOwner, NewExpert columns.
    [string]$CsvPath,

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
# CSV HELPERS
# ============================================================================

function Read-CsvWithFlexibleHeaders {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Host "CSV file not found: $Path" -ForegroundColor Red
        return $null
    }

    try {
        $csv = Import-Csv -Path $Path
        if (-not $csv -or $csv.Count -eq 0) {
            Write-Host "CSV file is empty: $Path" -ForegroundColor Red
            return $null
        }
        return $csv
    }
    catch {
        Write-Host "Error reading CSV: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# Returns the value of the first matching column on a CSV row, or $null.
function Get-RowValue {
    param(
        $Row,
        [string[]]$ColumnNames
    )
    $names = $Row.PSObject.Properties.Name
    foreach ($col in $ColumnNames) {
        if ($names -contains $col) {
            $val = "$($Row.$col)".Trim()
            if ($val) { return $val }
        }
    }
    return $null
}

function Get-IdFromCsvRow {
    param($Row)
    return Get-RowValue -Row $Row -ColumnNames @('ProcessID', 'ProcessId', 'Process ID', 'ProcessUniqueId', 'Id', 'ID')
}

# The /Api/v1/Processes/{id} endpoint expects the process UniqueId (a GUID),
# not the numeric internal Id. This is used to warn about likely-wrong values.
function Test-IsGuid {
    param([string]$Value)
    return $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

function Get-NewOwnerFromCsvRow {
    param($Row)
    return Get-RowValue -Row $Row -ColumnNames @('NewOwner', 'Owner', 'OwnerUsername', 'ProcessOwner')
}

function Get-NewExpertFromCsvRow {
    param($Row)
    return Get-RowValue -Row $Row -ColumnNames @('NewExpert', 'Expert', 'ExpertUsername', 'ProcessExpert')
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

# True if the supplied value is one of the "unassign" keywords.
function Test-IsUnassignKeyword {
    param([string]$Value)
    if (-not $Value) { return $false }
    return $script:UnassignKeywords -contains $Value.ToLower()
}

# Returns the placeholder "unassigned" user object.
function Get-UnassignedUser {
    return [PSCustomObject]@{
        Id       = $script:UnassignedUserId
        Name     = $script:UnassignedUserName
        UserName = "(unassigned)"
    }
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

# --- Read the CSV ---
if (-not $CsvPath) {
    $CsvPath = Read-Host "`nEnter the path to the CSV (columns: ProcessID, NewOwner, NewExpert)"
}
$csv = Read-CsvWithFlexibleHeaders -Path $CsvPath
if (-not $csv) { return }
Write-Host "Loaded $($csv.Count) row(s) from '$CsvPath'" -ForegroundColor Green
Write-Host "Blank owner/expert cells leave that role unchanged. Keywords ($($script:UnassignKeywords -join ', ')) set the placeholder user." -ForegroundColor Gray

# The Processes API path expects the process UniqueId (GUID). Warn if values look
# like numeric internal Ids, which the endpoint will not resolve.
$nonGuidIds = @($csv | ForEach-Object { Get-IdFromCsvRow -Row $_ } | Where-Object { $_ -and -not (Test-IsGuid -Value $_) })
if ($nonGuidIds.Count -gt 0) {
    Write-Host "`nNote: $($nonGuidIds.Count) ProcessID value(s) are not GUIDs (e.g. '$($nonGuidIds[0])')." -ForegroundColor Yellow
    Write-Host "This script addresses processes by their UniqueId (GUID), as found in a process URL (.../Process/View/{guid})." -ForegroundColor Yellow
    Write-Host "Numeric internal Ids will likely fail to resolve." -ForegroundColor Yellow
}

# --- Pre-flight: resolve every distinct username via SCIM ---
Write-Host "`nResolving users via SCIM ($scimBaseUrl)..." -ForegroundColor Cyan
$distinctNames = @{}
foreach ($row in $csv) {
    foreach ($v in @((Get-NewOwnerFromCsvRow -Row $row), (Get-NewExpertFromCsvRow -Row $row))) {
        if ($v -and -not (Test-IsUnassignKeyword -Value $v)) { $distinctNames[$v] = $true }
    }
}

$resolvedCache = @{}   # raw value -> resolved user object (or $null if not found)
$invalidUsers = @()
foreach ($name in $distinctNames.Keys) {
    $user = Get-ScimUser -ScimBaseUrl $scimBaseUrl -ScimApiKey $scimApiKey -SearchTerm $name
    $resolvedCache[$name] = $user
    if ($user) {
        Write-Host "  [OK] '$name' -> $($user.Name) (id $($user.Id))" -ForegroundColor Green
    } else {
        $invalidUsers += $name
        Write-Host "  [X] '$name' not found via SCIM" -ForegroundColor Red
    }
}

if ($invalidUsers.Count -gt 0) {
    Write-Host "`nWarning: $($invalidUsers.Count) username(s) could not be resolved:" -ForegroundColor Yellow
    foreach ($u in $invalidUsers) { Write-Host "  - $u" -ForegroundColor Yellow }
    Write-Host "Rows that reference these usernames will be skipped (that role cannot be set without a valid Id)." -ForegroundColor Yellow
    if (-not $WhatIf) {
        $continue = Read-Host "Continue anyway? (Y/N)"
        if ($continue -ne 'Y') { Write-Host "Operation cancelled" -ForegroundColor Yellow; return }
    }
} elseif ($distinctNames.Count -gt 0) {
    Write-Host "All usernames resolved successfully" -ForegroundColor Green
}

# Resolves a single CSV cell to an action: a user object, 'unchanged', or 'invalid'.
function Resolve-Cell {
    param([string]$Value)
    if (-not $Value) { return @{ Action = 'unchanged' } }
    if (Test-IsUnassignKeyword -Value $Value) { return @{ Action = 'set'; User = (Get-UnassignedUser) } }
    $u = $resolvedCache[$Value]
    if ($u) { return @{ Action = 'set'; User = $u } }
    return @{ Action = 'invalid'; Value = $Value }
}

# --- Confirmation ---
Write-Host "`n----------------------------------------" -ForegroundColor Cyan
if ($WhatIf) { Write-Host "*** PREVIEW MODE: No changes will be made ***" -ForegroundColor Yellow }
Write-Host "Rows to process : $($csv.Count)" -ForegroundColor White
Write-Host "----------------------------------------" -ForegroundColor Cyan
if (-not $WhatIf) {
    $proceed = Read-Host "Proceed with the update? (Y/N)"
    if ($proceed -ne 'Y') { Write-Host "Operation cancelled" -ForegroundColor Yellow; return }
}

# --- Process each row ---
$results = @()
$currentIndex = 0
$total = $csv.Count

foreach ($row in $csv) {
    $currentIndex++
    Write-Host "`r  Processing row $currentIndex of $total ..." -NoNewline -ForegroundColor Gray

    $processId = Get-IdFromCsvRow -Row $row
    if (-not $processId) {
        $results += [PSCustomObject]@{
            ProcessID = "N/A"; ProcessName = ""; Status = "Skipped"
            Message = "Missing ProcessID"; ActionUrl = ""
        }
        continue
    }

    $ownerCell  = Resolve-Cell -Value (Get-NewOwnerFromCsvRow -Row $row)
    $expertCell = Resolve-Cell -Value (Get-NewExpertFromCsvRow -Row $row)

    # Nothing to do for this row?
    if ($ownerCell.Action -eq 'unchanged' -and $expertCell.Action -eq 'unchanged') {
        $results += [PSCustomObject]@{
            ProcessID = $processId; ProcessName = ""; Status = "Skipped"
            Message = "No owner/expert provided"; ActionUrl = "$siteUrl/Process/View/$processId"
        }
        continue
    }

    # If any provided role references an unresolved user, skip the whole row.
    $invalidNotes = @()
    if ($ownerCell.Action  -eq 'invalid') { $invalidNotes += "owner '$($ownerCell.Value)' not found" }
    if ($expertCell.Action -eq 'invalid') { $invalidNotes += "expert '$($expertCell.Value)' not found" }
    if ($invalidNotes.Count -gt 0) {
        $results += [PSCustomObject]@{
            ProcessID = $processId; ProcessName = ""; Status = "Skipped"
            Message = ($invalidNotes -join '; '); ActionUrl = "$siteUrl/Process/View/$processId"
        }
        continue
    }

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
    if ($ownerCell.Action -eq 'set') {
        $changes += "Owner: $(Get-DefinitionValue -ProcessObj $processObj -Name 'Owner') (id $(Get-DefinitionValue -ProcessObj $processObj -Name 'OwnerId')) -> $($ownerCell.User.Name) (id $($ownerCell.User.Id))"
    }
    if ($expertCell.Action -eq 'set') {
        $changes += "Expert: $(Get-DefinitionValue -ProcessObj $processObj -Name 'Expert') (id $(Get-DefinitionValue -ProcessObj $processObj -Name 'ExpertId')) -> $($expertCell.User.Name) (id $($expertCell.User.Id))"
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
    if ($ownerCell.Action -eq 'set') {
        Set-DefinitionProperty -ProcessObj $processObj -Name 'OwnerId' -Value ([int]$ownerCell.User.Id)
        Set-DefinitionProperty -ProcessObj $processObj -Name 'Owner'   -Value $ownerCell.User.Name
    }
    if ($expertCell.Action -eq 'set') {
        Set-DefinitionProperty -ProcessObj $processObj -Name 'ExpertId' -Value ([int]$expertCell.User.Id)
        Set-DefinitionProperty -ProcessObj $processObj -Name 'Expert'   -Value $expertCell.User.Name
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
    Write-Host "Skipped         : $(($results | Where-Object { $_.Status -eq 'Skipped' }).Count)" -ForegroundColor Gray
    Write-Host "Failed to check : $(($results | Where-Object { $_.Status -eq 'Failed' }).Count)" -ForegroundColor Red
    Write-Host "`n*** This was a PREVIEW - no changes were made ***" -ForegroundColor Yellow
} else {
    Write-Host "Results saved to: $outputPath" -ForegroundColor Green
    Write-Host "Total operations: $($results.Count)" -ForegroundColor Cyan
    Write-Host "Successful      : $(($results | Where-Object { $_.Status -eq 'Success' }).Count)" -ForegroundColor Green
    Write-Host "Skipped         : $(($results | Where-Object { $_.Status -eq 'Skipped' }).Count)" -ForegroundColor Gray
    Write-Host "Failed          : $(($results | Where-Object { $_.Status -eq 'Failed' }).Count)" -ForegroundColor Red
}
