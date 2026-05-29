# Nintex Process Manager - Bulk Update Process Ownership
# Standalone script (extracted from Nintex-BulkOperations.ps1 "Mode 4")
#
# Purpose:
#   Apply a single new Owner and/or Expert to a list of processes.
#   The user supplies:
#     1. A file containing the Process IDs to update (one per line, or a ProcessID column).
#     2. The username (or non-GUID user ID) of the new Owner and/or new Expert.
#   For each process the script fetches the process definition, updates the
#   owner/expert in the definition, and saves the process.
#
# Usage:
#   .\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -NewOwner john.doe -NewExpert jane.smith
#   .\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -NewOwner john.doe -WhatIf
#   .\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -Discover
#
#   Any parameter you omit will be prompted for interactively (except -WhatIf / -Discover).
#
#Requires -Version 5.1

[CmdletBinding()]
param(
    # Path to the configuration file (SiteURL / Username / Password).
    [string]$ConfigPath = "config.txt",

    # Path to a file containing the Process IDs to update.
    # Accepts a plain text file (one ID per line) or a CSV with a ProcessID column.
    [string]$ProcessIdFile,

    # Username or non-GUID user ID of the new Owner. Leave blank to skip owner updates.
    [string]$NewOwner,

    # Username or non-GUID user ID of the new Expert. Leave blank to skip expert updates.
    [string]$NewExpert,

    # Preview mode: show what would change for each process without saving anything.
    [switch]$WhatIf,

    # Discovery mode: fetch the first process and print every owner/expert-related field
    # found in its definition. Use this to confirm the field names for your tenant.
    [switch]$Discover
)

# ============================================================================
# CONFIGURATION: Owner / Expert field detection
# ----------------------------------------------------------------------------
# The Nintex Process Manager process definition (processJson) stores the owner
# and expert under tenant/version-specific property names. The script looks for
# the FIRST property below that exists on the definition. If your tenant uses a
# different name, run the script with -Discover to list the actual fields, then
# add the correct name to the appropriate list.
# ============================================================================
$script:OwnerFieldCandidates = @(
    'Owner', 'ProcessOwner', 'OwnerUserName', 'OwnerUsername',
    'ProcessOwnerUserName', 'ProcessOwnerUsername', 'OwnerUser', 'ProcessOwnerUser'
)
$script:ExpertFieldCandidates = @(
    'Expert', 'ProcessExpert', 'ExpertUserName', 'ExpertUsername',
    'ProcessExpertUserName', 'ProcessExpertUsername', 'ExpertUser', 'ProcessExpertUser'
)

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

    $config.SiteURL = $config.SiteURL.TrimEnd('/')
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
# USER SEARCH / RESOLUTION
# ============================================================================

function Search-User {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$SearchTerm
    )

    try {
        $url = "$SiteURL/user/autocomplete.aspx?includeEmail=true&term=$SearchTerm"
        $headers = @{ "Authorization" = "Bearer $Token" }
        $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
        return $response
    }
    catch {
        Write-Host "User search error: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

# Resolves a username / user ID typed by the operator to a concrete user.
# Returns an object with Username (the value sent to the API) and DisplayName,
# or $null if no user could be resolved.
function Resolve-User {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$SearchTerm,
        [string]$RoleLabel = "user"
    )

    if (-not $SearchTerm) { return $null }

    $users = Search-User -SiteURL $SiteURL -Token $Token -SearchTerm $SearchTerm
    if (-not $users -or $users.Count -eq 0) {
        Write-Host "  [X] No $RoleLabel found matching '$SearchTerm'" -ForegroundColor Red
        return $null
    }

    # Prefer an exact match on the value (username/user ID) or on the label.
    $exact = $users | Where-Object { $_.value -eq $SearchTerm -or $_.label -eq $SearchTerm } | Select-Object -First 1
    if ($exact) {
        Write-Host "  [OK] $RoleLabel '$SearchTerm' resolved to: $($exact.label)" -ForegroundColor Green
        return [PSCustomObject]@{ Username = $exact.value; DisplayName = $exact.label }
    }

    # A single result is unambiguous - use it.
    if (@($users).Count -eq 1) {
        Write-Host "  [OK] $RoleLabel '$SearchTerm' resolved to: $($users[0].label)" -ForegroundColor Green
        return [PSCustomObject]@{ Username = $users[0].value; DisplayName = $users[0].label }
    }

    # Multiple matches - let the operator pick.
    Write-Host "`n  Multiple matches for $RoleLabel '$SearchTerm':" -ForegroundColor Yellow
    for ($i = 0; $i -lt $users.Count; $i++) {
        Write-Host "    [$i] $($users[$i].label)" -ForegroundColor White
    }
    $selection = Read-Host "  Select the correct $RoleLabel (number, or press Enter to cancel)"
    if ($selection -match '^\d+$' -and [int]$selection -lt $users.Count) {
        $picked = $users[[int]$selection]
        return [PSCustomObject]@{ Username = $picked.value; DisplayName = $picked.label }
    }

    return $null
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
# DEFINITION FIELD HELPERS
# ============================================================================

# Returns the name of the first candidate property that exists on the definition.
function Find-DefinitionField {
    param(
        $ProcessObj,
        [string[]]$Candidates
    )

    if (-not $ProcessObj -or -not $ProcessObj.PSObject) { return $null }
    $names = $ProcessObj.PSObject.Properties.Name
    foreach ($candidate in $Candidates) {
        if ($names -contains $candidate) { return $candidate }
    }
    return $null
}

# Returns a printable representation of the current value of a definition field.
function Get-FieldValueDisplay {
    param(
        $ProcessObj,
        [string]$FieldName
    )

    if (-not $FieldName) { return "(field not found)" }
    $val = $ProcessObj.$FieldName
    if ($null -eq $val) { return "(empty)" }
    if ($val -is [string]) { return $val }
    return ($val | ConvertTo-Json -Depth 5 -Compress)
}

# Applies a resolved user to a definition field, handling both string-valued
# and object-valued fields. Returns $true if a change was applied.
function Set-DefinitionUser {
    param(
        $ProcessObj,
        [string]$FieldName,
        $User   # object with Username / DisplayName
    )

    if (-not $FieldName) { return $false }
    $current = $ProcessObj.$FieldName

    if ($null -eq $current -or $current -is [string] -or $current -is [ValueType]) {
        $ProcessObj.$FieldName = $User.Username
        return $true
    }

    # Object-valued field - update the recognizable sub-properties in place.
    $changed = $false
    if ($current.PSObject) {
        $subNames = $current.PSObject.Properties.Name
        foreach ($sub in @('UserName', 'Username', 'Value', 'Login', 'Email', 'Id', 'UserId')) {
            if ($subNames -contains $sub) { $current.$sub = $User.Username; $changed = $true }
        }
        foreach ($sub in @('Name', 'DisplayName', 'Label', 'FullName')) {
            if ($subNames -contains $sub -and $User.DisplayName) { $current.$sub = $User.DisplayName; $changed = $true }
        }
    }

    if (-not $changed) {
        # Unknown object shape - replace wholesale with the username.
        $ProcessObj.$FieldName = $User.Username
        $changed = $true
    }

    return $changed
}

# Recursively collects every property whose name mentions owner/expert. Used by -Discover.
function Get-OwnerExpertProperties {
    param(
        $Obj,
        [string]$Path = ""
    )

    $results = @()
    if ($null -eq $Obj) { return $results }

    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
        $i = 0
        foreach ($item in $Obj) {
            $results += Get-OwnerExpertProperties -Obj $item -Path "$Path[$i]"
            $i++
            if ($i -ge 3) { break }   # cap array traversal to limit noise
        }
        return $results
    }

    if ($Obj.PSObject -and $Obj.PSObject.Properties) {
        foreach ($p in $Obj.PSObject.Properties) {
            $childPath = if ($Path) { "$Path.$($p.Name)" } else { $p.Name }
            if ($p.Name -match '(?i)owner|expert') {
                $typeName = if ($null -ne $p.Value) { $p.Value.GetType().Name } else { 'null' }
                $valueStr = if ($null -eq $p.Value) { "(empty)" }
                            elseif ($p.Value -is [string]) { $p.Value }
                            else { ($p.Value | ConvertTo-Json -Depth 5 -Compress) }
                $results += [PSCustomObject]@{ Path = $childPath; Type = $typeName; Value = $valueStr }
            }
            if ($p.Value -and -not ($p.Value -is [string]) -and -not ($p.Value -is [ValueType])) {
                $results += Get-OwnerExpertProperties -Obj $p.Value -Path $childPath
            }
        }
    }

    return $results
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
$siteUrl = $config.SiteURL

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

# --- Discovery mode: inspect the first process and exit ---
if ($Discover) {
    $firstId = $processIds[0]
    Write-Host "`n[DISCOVER] Inspecting owner/expert fields on process '$firstId'..." -ForegroundColor Yellow
    $resp = Invoke-ApiGet -Url "$siteUrl/Api/v1/Processes/$firstId" -Token $token
    if (-not $resp -or -not $resp.processJson) {
        Write-Host "Could not retrieve the process definition for '$firstId'." -ForegroundColor Red
        return
    }
    $found = @(Get-OwnerExpertProperties -Obj $resp.processJson)
    if ($found.Count -eq 0) {
        Write-Host "No properties containing 'owner' or 'expert' were found in the definition." -ForegroundColor Yellow
        Write-Host "The owner/expert may be stored under a different name or via a separate endpoint." -ForegroundColor Yellow
    } else {
        Write-Host "`nOwner/Expert-related fields found in the process definition:" -ForegroundColor Cyan
        $found | Format-Table -AutoSize | Out-Host
        Write-Host "If the correct field is not in the candidate lists at the top of this script," -ForegroundColor Gray
        Write-Host "add its name to `$OwnerFieldCandidates / `$ExpertFieldCandidates and re-run." -ForegroundColor Gray
    }
    return
}

# --- Gather and validate the new owner / expert ---
if (-not $PSBoundParameters.ContainsKey('NewOwner') -and -not $PSBoundParameters.ContainsKey('NewExpert')) {
    $NewOwner  = Read-Host "`nNew Owner username or user ID (leave blank to skip)"
    $NewExpert = Read-Host "New Expert username or user ID (leave blank to skip)"
}

if (-not $NewOwner -and -not $NewExpert) {
    Write-Host "No new owner or expert provided. Nothing to update." -ForegroundColor Yellow
    return
}

Write-Host "`nValidating users..." -ForegroundColor Cyan
$resolvedOwner = $null
$resolvedExpert = $null

if ($NewOwner) {
    $resolvedOwner = Resolve-User -SiteURL $siteUrl -Token $token -SearchTerm $NewOwner -RoleLabel "owner"
    if (-not $resolvedOwner) {
        $continue = Read-Host "Owner '$NewOwner' could not be resolved. Continue anyway? (Y/N)"
        if ($continue -ne 'Y') { Write-Host "Operation cancelled" -ForegroundColor Yellow; return }
        $resolvedOwner = [PSCustomObject]@{ Username = $NewOwner; DisplayName = $NewOwner }
    }
}

if ($NewExpert) {
    $resolvedExpert = Resolve-User -SiteURL $siteUrl -Token $token -SearchTerm $NewExpert -RoleLabel "expert"
    if (-not $resolvedExpert) {
        $continue = Read-Host "Expert '$NewExpert' could not be resolved. Continue anyway? (Y/N)"
        if ($continue -ne 'Y') { Write-Host "Operation cancelled" -ForegroundColor Yellow; return }
        $resolvedExpert = [PSCustomObject]@{ Username = $NewExpert; DisplayName = $NewExpert }
    }
}

# --- Summary / confirmation ---
Write-Host "`n----------------------------------------" -ForegroundColor Cyan
if ($WhatIf) { Write-Host "*** PREVIEW MODE: No changes will be made ***" -ForegroundColor Yellow }
Write-Host "Processes to update : $($processIds.Count)" -ForegroundColor White
if ($resolvedOwner)  { Write-Host "New Owner           : $($resolvedOwner.DisplayName) [$($resolvedOwner.Username)]" -ForegroundColor White }
if ($resolvedExpert) { Write-Host "New Expert          : $($resolvedExpert.DisplayName) [$($resolvedExpert.Username)]" -ForegroundColor White }
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

    $ownerField  = if ($resolvedOwner)  { Find-DefinitionField -ProcessObj $processObj -Candidates $script:OwnerFieldCandidates }  else { $null }
    $expertField = if ($resolvedExpert) { Find-DefinitionField -ProcessObj $processObj -Candidates $script:ExpertFieldCandidates } else { $null }

    # Build a description of the intended change for reporting.
    $changes = @()
    if ($resolvedOwner) {
        if ($ownerField) {
            $changes += "Owner: $(Get-FieldValueDisplay -ProcessObj $processObj -FieldName $ownerField) -> $($resolvedOwner.Username) [field: $ownerField]"
        } else {
            $changes += "Owner: (no owner field found in definition)"
        }
    }
    if ($resolvedExpert) {
        if ($expertField) {
            $changes += "Expert: $(Get-FieldValueDisplay -ProcessObj $processObj -FieldName $expertField) -> $($resolvedExpert.Username) [field: $expertField]"
        } else {
            $changes += "Expert: (no expert field found in definition)"
        }
    }

    # If neither role could be mapped to a field, record and skip.
    if (-not $ownerField -and -not $expertField) {
        $results += [PSCustomObject]@{
            ProcessID = $processId; ProcessName = $processName; Status = "Skipped"
            Message = "No owner/expert field found in definition. Run with -Discover to identify the field name."
            ActionUrl = "$siteUrl/Process/View/$processId"
        }
        continue
    }

    if ($WhatIf) {
        $results += [PSCustomObject]@{
            ProcessID = $processId; ProcessName = $processName; Status = "Preview"
            Message = "Would update '$processName' - $($changes -join '; ')"
            ActionUrl = "$siteUrl/Process/View/$processId"
        }
        continue
    }

    # Apply the changes to the definition object.
    if ($resolvedOwner -and $ownerField)  { [void](Set-DefinitionUser -ProcessObj $processObj -FieldName $ownerField  -User $resolvedOwner) }
    if ($resolvedExpert -and $expertField) { [void](Set-DefinitionUser -ProcessObj $processObj -FieldName $expertField -User $resolvedExpert) }

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
