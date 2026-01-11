# Nintex Process Manager Bulk Operations Script
# Version 1.0
# Supports: Archive, Restore, Update Location, Update Ownership, and Delete operations

#Requires -Version 5.1

# ============================================================================
# CONFIGURATION AND AUTHENTICATION
# ============================================================================

function Read-ConfigFile {
    param([string]$ConfigPath = "config.txt")

    if (-not (Test-Path $ConfigPath)) {
        Write-Host "Configuration file not found: $ConfigPath" -ForegroundColor Red
        Write-Host "Please create a config.txt file based on config.template.txt" -ForegroundColor Yellow
        return $null
    }

    $config = @{}
    Get-Content $ConfigPath | ForEach-Object {
        $line = $_.Trim()
        # Skip empty lines and comments
        if ($line -and -not $line.StartsWith('#')) {
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()
                $config[$key] = $value
            }
        }
    }

    # Validate required fields
    if (-not $config.SiteURL -or -not $config.Username -or -not $config.Password) {
        Write-Host "Configuration file is missing required fields (SiteURL, Username, Password)" -ForegroundColor Red
        return $null
    }

    # Remove trailing slash from SiteURL if present
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
            username = $Username
            password = $Password
            duration = 60000
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
            "Authorization" = "Bearer $Token"
            "Accept" = "application/json"
        }
        return Invoke-RestMethod -Uri $Url -Method Get -Headers $headers
    }
    catch {
        Write-Host "API GET Error ($Url): $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Invoke-ApiPost {
    param(
        [string]$Url,
        [string]$Token,
        [object]$Body = $null
    )

    try {
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
            "Accept" = "application/json"
            "X-Requested-With" = "XMLHttpRequest"
        }

        if ($Body) {
            $jsonBody = $Body | ConvertTo-Json -Depth 10
            return Invoke-RestMethod -Uri $Url -Method Post -Headers $headers -Body $jsonBody
        } else {
            return Invoke-RestMethod -Uri $Url -Method Post -Headers $headers
        }
    }
    catch {
        Write-Host "API POST Error ($Url): $($_.Exception.Message)" -ForegroundColor Red
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
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
            "Accept" = "application/json"
            "X-Requested-With" = "XMLHttpRequest"
        }

        $jsonBody = $Body | ConvertTo-Json -Depth 10

        # Invoke-RestMethod throws on HTTP errors, so if this succeeds, we got a 2xx response
        # No -StatusCodeVariable needed (not available in PowerShell 5.1)
        $response = Invoke-RestMethod -Uri $Url -Method Put -Headers $headers -Body $jsonBody -ErrorAction Stop

        # Success - assume 200 since no exception was thrown
        return @{ Success = $true; StatusCode = 200; Response = $response }
    }
    catch {
        $errorDetails = $_.Exception.Message
        $statusCode = "Unknown"

        # Try to extract status code from exception
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode

            # Try to read response body for more details
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
                if ($responseBody) {
                    Write-Host "  Response body: $responseBody" -ForegroundColor Gray
                }
            }
            catch {
                # Couldn't read response body
            }
        }

        Write-Host "API PUT Error ($Url): HTTP $statusCode - $errorDetails" -ForegroundColor Red

        # Return error info instead of null so caller can check status
        return @{ Success = $false; StatusCode = $statusCode; Error = $errorDetails }
    }
}

# ============================================================================
# PROCESS AND DOCUMENT RETRIEVAL
# ============================================================================

function Get-ProcessesFromGroup {
    param(
        [string]$SiteURL,
        [string]$Token,
        [int]$GroupID,
        [string]$GroupUniqueId = "",
        [bool]$IncludeSubgroups = $true
    )

    Write-Host "  Looking for processes in group ID: $GroupID (Include subgroups: $IncludeSubgroups)" -ForegroundColor Gray

    $allProcesses = @()
    $pageSize = 200
    $page = 1

    do {
        $url = "$SiteURL/Bff/Process/api/v1/processes?Page=$page&PageSize=$pageSize"
        $response = Invoke-ApiGet -Url $url -Token $Token

        if ($response -and $response.items) {
            Write-Host "    Page ${page}: Fetched $($response.items.Count) processes" -ForegroundColor Gray

            # Filter processes by group
            $groupProcesses = $response.items | Where-Object {
                if ($GroupUniqueId) {
                    # If we have a uniqueId, use that for filtering
                    $_.groupUniqueId -eq $GroupUniqueId
                } else {
                    # Otherwise use numeric groupId
                    $_.groupId -eq $GroupID
                }
            }

            if ($groupProcesses.Count -gt 0) {
                Write-Host "    Found $($groupProcesses.Count) matching processes on this page" -ForegroundColor Gray
            }

            $allProcesses += $groupProcesses
        }

        $page++
    } while ($response -and $response.items -and $response.items.Count -eq $pageSize)

    Write-Host "  Total processes found: $($allProcesses.Count)" -ForegroundColor Green
    return $allProcesses
}

function Get-ArchivedProcesses {
    param(
        [string]$SiteURL,
        [string]$Token,
        [int]$GroupID = -1
    )

    Write-Host "  Fetching archived processes..." -ForegroundColor Gray

    $allProcesses = @()
    $pageSize = 200
    $page = 1

    do {
        $url = "$SiteURL/Bff/Process/api/v1/processes?Page=$page&PageSize=$pageSize&ListType=7"
        $response = Invoke-ApiGet -Url $url -Token $Token

        if ($response -and $response.items) {
            Write-Host "    Page ${page}: Found $($response.items.Count) archived processes" -ForegroundColor Gray

            if ($GroupID -gt 0) {
                $groupProcesses = $response.items | Where-Object {
                    $_.groupId -eq $GroupID
                }
                $allProcesses += $groupProcesses
            } else {
                $allProcesses += $response.items
            }
        }

        $page++
    } while ($response -and $response.items -and $response.items.Count -eq $pageSize)

    Write-Host "  Total archived processes: $($allProcesses.Count)" -ForegroundColor Gray
    return $allProcesses
}

function Get-DocumentsFromGroup {
    param(
        [string]$SiteURL,
        [string]$Token,
        [int]$GroupID,
        [bool]$IncludeSubgroups = $true
    )

    # Note: This is a placeholder. Adjust the API endpoint based on your Nintex PM version
    # Some versions use /Api/v1/Documents, others may use different endpoints
    try {
        $url = "$SiteURL/Api/v1/ProcessGroups/$GroupID/Documents"
        $response = Invoke-ApiGet -Url $url -Token $Token
        return $response
    }
    catch {
        Write-Host "Document retrieval not available or endpoint differs" -ForegroundColor Yellow
        return @()
    }
}

# ============================================================================
# CSV PROCESSING
# ============================================================================

function Read-CsvWithFlexibleHeaders {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Host "CSV file not found: $Path" -ForegroundColor Red
        return $null
    }

    try {
        $csv = Import-Csv -Path $Path
        return $csv
    }
    catch {
        Write-Host "Error reading CSV: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Get-IdFromCsvRow {
    param($Row)

    # Try various common column names for ID
    $possibleIdColumns = @('ProcessID', 'ProcessId', 'Process ID', 'ProcessUniqueId', 'Id', 'ID', 'DocumentID', 'DocumentId')

    foreach ($col in $possibleIdColumns) {
        if ($Row.PSObject.Properties.Name -contains $col) {
            return $Row.$col
        }
    }

    return $null
}

function Get-NewGroupIdFromCsvRow {
    param($Row)

    $possibleColumns = @('NewGroupID', 'NewGroupId', 'TargetGroupID', 'TargetGroupId', 'GroupID', 'GroupId')

    foreach ($col in $possibleColumns) {
        if ($Row.PSObject.Properties.Name -contains $col) {
            return $Row.$col
        }
    }

    return $null
}

function Get-NewOwnerFromCsvRow {
    param($Row)

    $possibleColumns = @('NewOwner', 'Owner', 'OwnerUsername', 'ProcessOwner')

    foreach ($col in $possibleColumns) {
        if ($Row.PSObject.Properties.Name -contains $col) {
            return $Row.$col
        }
    }

    return $null
}

function Get-NewExpertFromCsvRow {
    param($Row)

    $possibleColumns = @('NewExpert', 'Expert', 'ExpertUsername', 'ProcessExpert')

    foreach ($col in $possibleColumns) {
        if ($Row.PSObject.Properties.Name -contains $col) {
            return $Row.$col
        }
    }

    return $null
}

# ============================================================================
# USER AND GROUP SELECTION
# ============================================================================

function Get-ChildGroupsRecursive {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$ParentUniqueId,
        [int]$ParentId = $null,
        [ref]$AllGroups
    )

    try {
        $url = "$SiteURL/Process/View/GetChildProcessGroupTreeItems?uniqueId=$ParentUniqueId"
        $response = Invoke-ApiGet -Url $url -Token $Token

        if ($response -and $response.treeItems) {
            # Filter for only group items (not processes or documents)
            $groups = $response.treeItems | Where-Object {
                $_.itemType -eq "group" -or $_.itemType -eq "documentgroup"
            }

            foreach ($group in $groups) {
                # Add this group to our collection
                if (-not $AllGroups.Value.ContainsKey($group.id)) {
                    $AllGroups.Value[$group.id] = @{
                        id = $group.id
                        uniqueId = $group.uniqueId
                        name = $group.title
                        parentId = $ParentId
                        hasChild = $group.hasChild
                        totalSubgroups = $group.totalSubgroups
                        itemOrder = $group.itemOrder
                    }
                }

                # Recursively fetch children if this group has any
                if ($group.hasChild -and $group.totalSubgroups -gt 0) {
                    Get-ChildGroupsRecursive -SiteURL $SiteURL -Token $Token `
                        -ParentUniqueId $group.uniqueId -ParentId $group.id `
                        -AllGroups $AllGroups
                }
            }
        }
    }
    catch {
        Write-Host "  Error fetching children for group $ParentUniqueId : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-ProcessGroups {
    param(
        [string]$SiteURL,
        [string]$Token
    )

    try {
        Write-Host "Fetching group tree from Process Manager..." -ForegroundColor Cyan

        # Get root groups by calling GetChildProcessGroupTreeItems without uniqueId parameter
        Write-Host "  Getting root groups..." -ForegroundColor Gray
        $url = "$SiteURL/Process/View/GetChildProcessGroupTreeItems"
        $response = Invoke-ApiGet -Url $url -Token $Token

        if (-not $response -or -not $response.treeItems) {
            Write-Host "  Could not fetch root groups from API" -ForegroundColor Yellow
            return @()
        }

        # Filter for only group items (not processes or documents)
        $rootGroups = $response.treeItems | Where-Object {
            $_.itemType -eq "group" -or $_.itemType -eq "documentgroup"
        }

        Write-Host "  Found $($rootGroups.Count) root groups" -ForegroundColor Green

        # Now recursively fetch the full tree for each root group
        $allGroups = @{}

        foreach ($rootGroup in $rootGroups) {
            Write-Host "  Fetching tree for: $($rootGroup.title)..." -ForegroundColor Gray

            # Add root group
            $allGroups[$rootGroup.id] = @{
                id = $rootGroup.id
                uniqueId = $rootGroup.uniqueId
                name = $rootGroup.title
                parentId = $null
                hasChild = $rootGroup.hasChild
                totalSubgroups = $rootGroup.totalSubgroups
                itemOrder = $rootGroup.itemOrder
            }

            # Recursively fetch children if this group has any
            if ($rootGroup.hasChild -and $rootGroup.totalSubgroups -gt 0) {
                Get-ChildGroupsRecursive -SiteURL $SiteURL -Token $Token `
                    -ParentUniqueId $rootGroup.uniqueId -ParentId $rootGroup.id `
                    -AllGroups ([ref]$allGroups)
            }
        }

        Write-Host "Successfully fetched $($allGroups.Count) groups total" -ForegroundColor Green
        return $allGroups.Values | Sort-Object -Property itemOrder
    }
    catch {
        Write-Host "Error fetching process groups: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        return @()
    }
}

function Get-GroupNumericIdByUniqueId {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$UniqueId
    )

    try {
        Write-Host "    Looking for group with uniqueId: $UniqueId" -ForegroundColor Gray

        # Get root level groups only (lightweight call)
        $url = "$SiteURL/Process/View/GetChildProcessGroupTreeItems"
        $response = Invoke-ApiGet -Url $url -Token $Token

        if ($response -and $response.treeItems) {
            Write-Host "    Found $($response.treeItems.Count) root groups" -ForegroundColor Gray

            $matchedGroup = $response.treeItems | Where-Object { $_.uniqueId -eq $UniqueId }
            if ($matchedGroup) {
                Write-Host "    Found matching group with numeric ID: $($matchedGroup.id)" -ForegroundColor Gray
                return $matchedGroup.id
            } else {
                Write-Host "    No matching group found with that uniqueId" -ForegroundColor Yellow
            }
        } else {
            Write-Host "    No root groups returned from API" -ForegroundColor Yellow
        }
        return -1
    }
    catch {
        Write-Host "Error looking up group numeric ID: $($_.Exception.Message)" -ForegroundColor Red
        return -1
    }
}

function New-ProcessGroup {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$GroupName,
        [string]$ParentGroupUniqueId = ""
    )

    try {
        Write-Host "Creating process group: $GroupName" -ForegroundColor Cyan

        # Step 1: Create the group
        $createUrl = "$SiteURL/Process/Edit/CreateGroup"
        $createBody = @{
            parentProcessGroupUniqueId = $ParentGroupUniqueId
        } | ConvertTo-Json

        Write-Host "  Step 1: Creating group..." -ForegroundColor Gray
        $createResponse = Invoke-ApiPost -Url $createUrl -Token $Token -Body $createBody

        if (-not $createResponse) {
            Write-Host "Failed to create group. No response from CreateGroup API." -ForegroundColor Red
            return $null
        }

        # Extract the new group's uniqueId from the response
        # The API returns "groupid" (lowercase) which is the uniqueId
        $newGroupUniqueId = $createResponse.groupid

        if (-not $newGroupUniqueId) {
            Write-Host "Failed to create group. Response did not contain groupid." -ForegroundColor Red
            return $null
        }

        Write-Host "  Group created with uniqueId: $newGroupUniqueId" -ForegroundColor Gray

        # Small delay to ensure group is fully created on server
        Start-Sleep -Milliseconds 500

        # Step 2: Look up the numeric ID (skipping rename to avoid API errors)
        Write-Host "  Step 2: Looking up numeric group ID..." -ForegroundColor Gray
        $numericId = Get-GroupNumericIdByUniqueId -SiteURL $SiteURL -Token $Token -UniqueId $newGroupUniqueId

        Write-Host "Successfully created group (ID: $numericId, uniqueId: $newGroupUniqueId)" -ForegroundColor Green
        Write-Host "  Note: Group created with default name. Will be deleted at end of process." -ForegroundColor Gray

        return @{
            id = $numericId
            uniqueId = $newGroupUniqueId
            name = $GroupName
        }
    }
    catch {
        Write-Host "Error creating process group: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        return $null
    }
}

function Delete-ProcessGroup {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$GroupUniqueId
    )

    try {
        Write-Host "Deleting process group (UniqueId: $GroupUniqueId)..." -ForegroundColor Gray

        $deleteUrl = "$SiteURL/Process/Edit/DeleteGroup"
        $deleteBody = @{
            processGroupUniqueId = $GroupUniqueId
        }

        $result = Invoke-ApiPost -Url $deleteUrl -Token $Token -Body $deleteBody

        if ($result) {
            Write-Host "  Successfully deleted temporary group" -ForegroundColor Green
            return $true
        } else {
            Write-Host "  Failed to delete group" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "  Error deleting process group: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Show-GroupTree {
    param(
        [array]$Groups,
        [int]$ParentId = $null,
        [int]$Level = 0,
        [hashtable]$IndexMap
    )

    $indent = "  " * $Level
    $filteredGroups = $Groups | Where-Object {
        if ($ParentId -eq $null -or $ParentId -eq 0) {
            $_.parentId -eq $null -or $_.parentId -eq 0
        } else {
            $_.parentId -eq $ParentId
        }
    } | Sort-Object -Property itemOrder

    foreach ($group in $filteredGroups) {
        $index = $IndexMap.Count + 1
        $IndexMap[$index] = $group

        $groupName = if ($group.name) { $group.name } else { "Group $($group.id)" }
        $uniqueIdDisplay = if ($group.uniqueId) { " (ID: $($group.uniqueId))" } else { "" }

        Write-Host "$indent[$index] $groupName$uniqueIdDisplay" -ForegroundColor Cyan

        # Recursively show children
        Show-GroupTree -Groups $Groups -ParentId $group.id -Level ($Level + 1) -IndexMap $IndexMap
    }
}

function Select-ProcessGroup {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$Prompt = "Select Process Group"
    )

    Write-Host "`n$Prompt" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Gray
    Write-Host "[1] Select from group tree" -ForegroundColor White
    Write-Host "[2] Enter Group ID manually" -ForegroundColor White
    Write-Host "======================================" -ForegroundColor Gray

    $choice = Read-Host "Choose an option (1-2)"

    if ($choice -eq "1") {
        # Show group tree picker
        Write-Host "`nFetching process groups..." -ForegroundColor Cyan
        $groups = Get-ProcessGroups -SiteURL $SiteURL -Token $Token

        if (-not $groups -or $groups.Count -eq 0) {
            Write-Host "No groups found. Please enter Group ID manually." -ForegroundColor Yellow
            $choice = "2"
        } else {
            Write-Host "`nAvailable Process Groups:" -ForegroundColor Green
            Write-Host "======================================" -ForegroundColor Gray

            $indexMap = @{}
            Show-GroupTree -Groups $groups -IndexMap $indexMap

            Write-Host "======================================" -ForegroundColor Gray
            $selection = Read-Host "`nEnter the number of the group you want to select"

            if ($indexMap.ContainsKey([int]$selection)) {
                $selectedGroup = $indexMap[[int]$selection]
                $groupName = if ($selectedGroup.name) { $selectedGroup.name } else { "Group $($selectedGroup.id)" }
                Write-Host "Selected: $groupName" -ForegroundColor Green
                return $selectedGroup
            } else {
                Write-Host "Invalid selection." -ForegroundColor Red
                return $null
            }
        }
    }

    if ($choice -eq "2") {
        # Manual entry
        Write-Host "`nEnter Process Group ID" -ForegroundColor Cyan
        Write-Host "You can find the Group ID in the URL when viewing a group in Process Manager" -ForegroundColor Gray
        Write-Host "Examples:" -ForegroundColor Gray
        Write-Host "  - Numeric ID: .../ProcessGroup/View/123 - enter: 123" -ForegroundColor Gray
        Write-Host "  - GUID: .../ProcessGroup/View/a1b2c3d4-... - enter: a1b2c3d4-e5f6-7890-abcd-ef1234567890" -ForegroundColor Gray

        $groupId = Read-Host "`nGroup ID"

        $groups = Get-ProcessGroups -SiteURL $SiteURL -Token $Token

        # Check if it's a numeric ID
        if ($groupId -match '^\d+$') {
            $matchedGroup = $groups | Where-Object { $_.id -eq [int]$groupId }
            if ($matchedGroup) {
                Write-Host "Found group: $($matchedGroup.name)" -ForegroundColor Green
                return $matchedGroup
            } else {
                Write-Host "Could not find group with ID: $groupId" -ForegroundColor Red
                return $null
            }
        }
        # Check if it's a GUID
        elseif ($groupId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            $matchedGroup = $groups | Where-Object { $_.uniqueId -eq $groupId }

            if ($matchedGroup) {
                Write-Host "Found group: $($matchedGroup.name)" -ForegroundColor Green
                return $matchedGroup
            } else {
                Write-Host "Could not find group with GUID: $groupId" -ForegroundColor Red
                return $null
            }
        }
        else {
            Write-Host "Invalid Group ID format. Must be a number or a GUID." -ForegroundColor Red
            return $null
        }
    }

    Write-Host "Invalid choice." -ForegroundColor Red
    return $null
}

function Search-User {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$SearchTerm
    )

    try {
        $url = "$SiteURL/user/autocomplete.aspx?includeEmail=true&term=$SearchTerm"
        $headers = @{
            "Authorization" = "Bearer $Token"
        }
        $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
        return $response
    }
    catch {
        Write-Host "User search error: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

function Select-User {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$Prompt = "Enter username or search term"
    )

    Write-Host "`n$Prompt" -ForegroundColor Cyan
    $searchTerm = Read-Host "Search"

    if (-not $searchTerm) {
        return $null
    }

    $users = Search-User -SiteURL $SiteURL -Token $Token -SearchTerm $searchTerm

    if (-not $users -or $users.Count -eq 0) {
        Write-Host "No users found matching '$searchTerm'" -ForegroundColor Yellow
        return $null
    }

    Write-Host "`nFound users:" -ForegroundColor Green
    for ($i = 0; $i -lt $users.Count; $i++) {
        Write-Host "  [$i] $($users[$i].label)" -ForegroundColor White
    }

    $selection = Read-Host "`nSelect user number (or press Enter to cancel)"

    if ($selection -match '^\d+$' -and [int]$selection -lt $users.Count) {
        return $users[[int]$selection]
    }

    return $null
}

# ============================================================================
# MODE 1: BULK ARCHIVE
# ============================================================================

function Invoke-BulkArchive {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$SourceType,  # "CSV" or "Group"
        [string]$ObjectType,  # "Processes", "Documents", or "Both"
        [string]$CsvPath = "",
        [int]$GroupID = -1,
        [string]$GroupUniqueId = ""
    )

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "BULK ARCHIVE OPERATION" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $results = @()
    $processesToArchive = @()
    $documentsToArchive = @()

    # Gather items to archive
    if ($SourceType -eq "CSV") {
        $csv = Read-CsvWithFlexibleHeaders -Path $CsvPath
        if (-not $csv) { return }

        foreach ($row in $csv) {
            $id = Get-IdFromCsvRow -Row $row
            if ($id) {
                if ($ObjectType -eq "Processes" -or $ObjectType -eq "Both") {
                    $processesToArchive += $id
                }
                if ($ObjectType -eq "Documents" -or $ObjectType -eq "Both") {
                    $documentsToArchive += $id
                }
            }
        }
    }
    else {  # Group-based
        if ($ObjectType -eq "Processes" -or $ObjectType -eq "Both") {
            $includeSubgroups = (Read-Host "Include subgroups? (Y/N)") -eq 'Y'
            $processes = Get-ProcessesFromGroup -SiteURL $SiteURL -Token $Token -GroupID $GroupID -GroupUniqueId $GroupUniqueId -IncludeSubgroups $includeSubgroups
            $processesToArchive = $processes | ForEach-Object { $_.id }
            Write-Host "Found $($processesToArchive.Count) processes to archive" -ForegroundColor Green
        }

        if ($ObjectType -eq "Documents" -or $ObjectType -eq "Both") {
            $includeSubgroups = (Read-Host "Include subgroups for documents? (Y/N)") -eq 'Y'
            $documents = Get-DocumentsFromGroup -SiteURL $SiteURL -Token $Token -GroupID $GroupID -IncludeSubgroups $includeSubgroups
            $documentsToArchive = $documents | ForEach-Object { $_.id }
            Write-Host "Found $($documentsToArchive.Count) documents to archive" -ForegroundColor Green
        }
    }

    # Archive processes
    if ($processesToArchive.Count -gt 0) {
        Write-Host "`nArchiving $($processesToArchive.Count) processes..." -ForegroundColor Cyan

        foreach ($processId in $processesToArchive) {
            Write-Host "Archiving Process ID: $processId" -ForegroundColor White

            # Fetch process details to get uniqueId
            $verifyUrl = "$SiteURL/Api/v1/Processes/$processId"
            $process = Invoke-ApiGet -Url $verifyUrl -Token $Token

            if ($process -and $process.uniqueId) {
                $processUniqueId = $process.uniqueId

                # Use Archive-Process helper
                $result = Archive-Process -SiteURL $SiteURL -Token $Token -ProcessUniqueId $processUniqueId -Comment "Bulk archive operation"

                if ($result) {
                    # Verify archive
                    $process = Invoke-ApiGet -Url $verifyUrl -Token $Token
                    if ($process -and $process.isArchived) {
                        Write-Host "  Success: Process archived" -ForegroundColor Green
                        $results += [PSCustomObject]@{
                            ObjectType = "Process"
                            ObjectID = $processId
                            Operation = "Archive"
                            Status = "Success"
                            Message = "Archived successfully"
                        }
                    } else {
                        Write-Host "  Failed: Could not archive process" -ForegroundColor Red
                        $results += [PSCustomObject]@{
                            ObjectType = "Process"
                            ObjectID = $processId
                            Operation = "Archive"
                            Status = "Failed"
                            Message = "Could not archive"
                        }
                    }
                } else {
                    $results += [PSCustomObject]@{
                        ObjectType = "Process"
                        ObjectID = $processId
                        Operation = "Archive"
                        Status = "Failed"
                        Message = "Archive API call failed"
                    }
                }
            } else {
                Write-Host "  Failed: Could not retrieve process details" -ForegroundColor Red
                $results += [PSCustomObject]@{
                    ObjectType = "Process"
                    ObjectID = $processId
                    Operation = "Archive"
                    Status = "Failed"
                    Message = "Could not retrieve process"
                }
            }
        }
    }

    # Archive documents (if applicable)
    if ($documentsToArchive.Count -gt 0) {
        Write-Host "`nArchiving $($documentsToArchive.Count) documents..." -ForegroundColor Cyan
        Write-Host "Note: Document archiving may not be supported in all Nintex PM versions" -ForegroundColor Yellow

        foreach ($docId in $documentsToArchive) {
            Write-Host "Archiving Document ID: $docId" -ForegroundColor White

            # Adjust endpoint based on your version
            $archiveUrl = "$SiteURL/Api/v1/Documents/$docId/Archive"
            $result = Invoke-ApiPost -Url $archiveUrl -Token $Token

            if ($result) {
                $results += [PSCustomObject]@{
                    ObjectType = "Document"
                    ObjectID = $docId
                    Operation = "Archive"
                    Status = "Success"
                    Message = "Archived"
                }
            } else {
                $results += [PSCustomObject]@{
                    ObjectType = "Document"
                    ObjectID = $docId
                    Operation = "Archive"
                    Status = "Failed"
                    Message = "Archive failed"
                }
            }
        }
    }

    # Save results
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outputPath = "Archive_Results_$timestamp.csv"
    $results | Export-Csv -Path $outputPath -NoTypeInformation

    Write-Host "`nResults saved to: $outputPath" -ForegroundColor Green
    Write-Host "Total operations: $($results.Count)" -ForegroundColor Cyan
    Write-Host "Successful: $(($results | Where-Object {$_.Status -eq 'Success'}).Count)" -ForegroundColor Green
    Write-Host "Failed: $(($results | Where-Object {$_.Status -eq 'Failed'}).Count)" -ForegroundColor Red
}

# ============================================================================
# MODE 2: BULK RESTORE
# ============================================================================

function Invoke-BulkRestore {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$SourceType,  # "CSV" or "All"
        [string]$ObjectType,  # "Processes", "Documents", or "Both"
        [string]$CsvPath = "",
        [int]$RestoreGroupID
    )

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "BULK RESTORE OPERATION" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $results = @()
    $processesToRestore = @()
    $documentsToRestore = @()

    # Gather items to restore
    if ($SourceType -eq "CSV") {
        $csv = Read-CsvWithFlexibleHeaders -Path $CsvPath
        if (-not $csv) { return }

        foreach ($row in $csv) {
            $id = Get-IdFromCsvRow -Row $row
            if ($id) {
                if ($ObjectType -eq "Processes" -or $ObjectType -eq "Both") {
                    $processesToRestore += $id
                }
                if ($ObjectType -eq "Documents" -or $ObjectType -eq "Both") {
                    $documentsToRestore += $id
                }
            }
        }
    }
    else {  # Restore all archived items
        if ($ObjectType -eq "Processes" -or $ObjectType -eq "Both") {
            $processes = Get-ArchivedProcesses -SiteURL $SiteURL -Token $Token
            $processesToRestore = $processes | ForEach-Object { $_.processUniqueId }
            Write-Host "Found $($processesToRestore.Count) archived processes" -ForegroundColor Green
        }

        if ($ObjectType -eq "Documents" -or $ObjectType -eq "Both") {
            Write-Host "Restoring all archived documents not yet implemented" -ForegroundColor Yellow
        }
    }

    # Restore processes
    if ($processesToRestore.Count -gt 0) {
        Write-Host "`nRestoring $($processesToRestore.Count) processes to Group ID: $RestoreGroupID..." -ForegroundColor Cyan

        foreach ($processId in $processesToRestore) {
            Write-Host "Restoring Process ID: $processId" -ForegroundColor White

            $restoreUrl = "$SiteURL/Process/Edit/RestoreProcess"
            $restoreBody = @{
                processUniqueId = $processId
                processGroupId = $RestoreGroupID.ToString()
            }
            $result = Invoke-ApiPost -Url $restoreUrl -Token $Token -Body $restoreBody

            if ($result) {
                # Verify restore
                $verifyUrl = "$SiteURL/Api/v1/Processes/$processId"
                $process = Invoke-ApiGet -Url $verifyUrl -Token $Token

                if ($process -and -not $process.isArchived) {
                    Write-Host "  Success: Process restored" -ForegroundColor Green
                    $results += [PSCustomObject]@{
                        ObjectType = "Process"
                        ObjectID = $processId
                        Operation = "Restore"
                        Status = "Success"
                        Message = "Restored to Group $RestoreGroupID"
                        ActionUrl = "$SiteURL/Process/View/$processId"
                    }
                } else {
                    Write-Host "  Failed: Process may still be archived" -ForegroundColor Red
                    $results += [PSCustomObject]@{
                        ObjectType = "Process"
                        ObjectID = $processId
                        Operation = "Restore"
                        Status = "Failed"
                        Message = "Verification failed"
                        ActionUrl = ""
                    }
                }
            } else {
                $results += [PSCustomObject]@{
                    ObjectType = "Process"
                    ObjectID = $processId
                    Operation = "Restore"
                    Status = "Failed"
                    Message = "Restore API call failed"
                    ActionUrl = ""
                }
            }
        }
    }

    # Restore documents
    if ($documentsToRestore.Count -gt 0) {
        Write-Host "`nRestoring $($documentsToRestore.Count) documents..." -ForegroundColor Cyan
        foreach ($docId in $documentsToRestore) {
            Write-Host "Document restore for ID $docId - Not yet implemented" -ForegroundColor Yellow
            $results += [PSCustomObject]@{
                ObjectType = "Document"
                ObjectID = $docId
                Operation = "Restore"
                Status = "Skipped"
                Message = "Not implemented"
                ActionUrl = ""
            }
        }
    }

    # Save results
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outputPath = "Restore_Results_$timestamp.csv"
    $results | Export-Csv -Path $outputPath -NoTypeInformation

    Write-Host "`nResults saved to: $outputPath" -ForegroundColor Green
    Write-Host "Total operations: $($results.Count)" -ForegroundColor Cyan
    Write-Host "Successful: $(($results | Where-Object {$_.Status -eq 'Success'}).Count)" -ForegroundColor Green
    Write-Host "Failed: $(($results | Where-Object {$_.Status -eq 'Failed'}).Count)" -ForegroundColor Red
}

# ============================================================================
# MODE 3: BULK UPDATE LOCATION
# ============================================================================

function Invoke-BulkUpdateLocation {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$ObjectType,  # "Processes", "Documents", or "Both"
        [string]$CsvPath
    )

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "BULK UPDATE LOCATION OPERATION" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "CSV should contain: ID column and NewGroupID column" -ForegroundColor Yellow

    $csv = Read-CsvWithFlexibleHeaders -Path $CsvPath
    if (-not $csv) { return }

    $results = @()

    foreach ($row in $csv) {
        $objectId = Get-IdFromCsvRow -Row $row
        $newGroupId = Get-NewGroupIdFromCsvRow -Row $row

        if (-not $objectId -or -not $newGroupId) {
            Write-Host "Skipping row - missing ID or NewGroupID" -ForegroundColor Yellow
            continue
        }

        if ($ObjectType -eq "Processes" -or $ObjectType -eq "Both") {
            Write-Host "Moving Process $objectId to Group $newGroupId" -ForegroundColor White

            # Get current process
            $getUrl = "$SiteURL/Api/v1/Processes/$objectId"
            $process = Invoke-ApiGet -Url $getUrl -Token $Token

            if ($process) {
                # Update process group
                $process.processGroupId = [int]$newGroupId

                $updateUrl = "$SiteURL/Api/v1/Processes/$objectId"
                $updateResult = Invoke-ApiPut -Url $updateUrl -Token $Token -Body $process

                if ($updateResult -and $updateResult.Success) {
                    Write-Host "  Success: Process moved" -ForegroundColor Green
                    $results += [PSCustomObject]@{
                        ObjectType = "Process"
                        ObjectID = $objectId
                        Operation = "UpdateLocation"
                        Status = "Success"
                        Message = "Moved to Group $newGroupId"
                        ActionUrl = "$SiteURL/Process/View/$objectId"
                    }
                } else {
                    Write-Host "  Failed: Could not update process" -ForegroundColor Red
                    $results += [PSCustomObject]@{
                        ObjectType = "Process"
                        ObjectID = $objectId
                        Operation = "UpdateLocation"
                        Status = "Failed"
                        Message = "Update failed"
                        ActionUrl = ""
                    }
                }
            } else {
                Write-Host "  Failed: Could not retrieve process" -ForegroundColor Red
                $results += [PSCustomObject]@{
                    ObjectType = "Process"
                    ObjectID = $objectId
                    Operation = "UpdateLocation"
                    Status = "Failed"
                    Message = "Process not found"
                    ActionUrl = ""
                }
            }
        }

        if ($ObjectType -eq "Documents" -or $ObjectType -eq "Both") {
            Write-Host "Moving Document $objectId to Group $newGroupId - Not fully implemented" -ForegroundColor Yellow
            $results += [PSCustomObject]@{
                ObjectType = "Document"
                ObjectID = $objectId
                Operation = "UpdateLocation"
                Status = "Skipped"
                Message = "Not implemented"
                ActionUrl = ""
            }
        }
    }

    # Save results
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outputPath = "UpdateLocation_Results_$timestamp.csv"
    $results | Export-Csv -Path $outputPath -NoTypeInformation

    Write-Host "`nResults saved to: $outputPath" -ForegroundColor Green
    Write-Host "Total operations: $($results.Count)" -ForegroundColor Cyan
    Write-Host "Successful: $(($results | Where-Object {$_.Status -eq 'Success'}).Count)" -ForegroundColor Green
    Write-Host "Failed: $(($results | Where-Object {$_.Status -eq 'Failed'}).Count)" -ForegroundColor Red
}

# ============================================================================
# MODE 4: BULK UPDATE OWNERSHIP
# ============================================================================

function Invoke-BulkUpdateOwnership {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$CsvPath
    )

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "BULK UPDATE OWNERSHIP OPERATION" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "CSV should contain: ProcessID, NewOwner (username), NewExpert (username)" -ForegroundColor Yellow
    Write-Host "Note: Currently supports Processes only" -ForegroundColor Yellow

    $csv = Read-CsvWithFlexibleHeaders -Path $CsvPath
    if (-not $csv) { return }

    $results = @()

    foreach ($row in $csv) {
        $processId = Get-IdFromCsvRow -Row $row
        $newOwner = Get-NewOwnerFromCsvRow -Row $row
        $newExpert = Get-NewExpertFromCsvRow -Row $row

        if (-not $processId) {
            Write-Host "Skipping row - missing ProcessID" -ForegroundColor Yellow
            continue
        }

        Write-Host "Updating Process $processId - Owner: $newOwner, Expert: $newExpert" -ForegroundColor White

        # Get current process
        $getUrl = "$SiteURL/Api/v1/Processes/$processId"
        $process = Invoke-ApiGet -Url $getUrl -Token $Token

        if ($process) {
            $updated = $false

            # Update owner if provided
            if ($newOwner) {
                $process.owner = $newOwner
                $updated = $true
            }

            # Update expert if provided
            if ($newExpert) {
                $process.expert = $newExpert
                $updated = $true
            }

            if ($updated) {
                $updateUrl = "$SiteURL/Api/v1/Processes/$processId"
                $updateResult = Invoke-ApiPut -Url $updateUrl -Token $Token -Body $process

                if ($updateResult -and $updateResult.Success) {
                    Write-Host "  Success: Ownership updated" -ForegroundColor Green
                    $results += [PSCustomObject]@{
                        ObjectType = "Process"
                        ObjectID = $processId
                        Operation = "UpdateOwnership"
                        Status = "Success"
                        Message = "Owner: $newOwner, Expert: $newExpert"
                        ActionUrl = "$SiteURL/Process/View/$processId"
                    }
                } else {
                    Write-Host "  Failed: Could not update process" -ForegroundColor Red
                    $results += [PSCustomObject]@{
                        ObjectType = "Process"
                        ObjectID = $processId
                        Operation = "UpdateOwnership"
                        Status = "Failed"
                        Message = "Update failed"
                        ActionUrl = ""
                    }
                }
            } else {
                Write-Host "  Skipped: No owner or expert provided" -ForegroundColor Yellow
                $results += [PSCustomObject]@{
                    ObjectType = "Process"
                    ObjectID = $processId
                    Operation = "UpdateOwnership"
                    Status = "Skipped"
                    Message = "No updates provided"
                    ActionUrl = ""
                }
            }
        } else {
            Write-Host "  Failed: Could not retrieve process" -ForegroundColor Red
            $results += [PSCustomObject]@{
                ObjectType = "Process"
                ObjectID = $processId
                Operation = "UpdateOwnership"
                Status = "Failed"
                Message = "Process not found"
                ActionUrl = ""
            }
        }
    }

    # Save results
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outputPath = "UpdateOwnership_Results_$timestamp.csv"
    $results | Export-Csv -Path $outputPath -NoTypeInformation

    Write-Host "`nResults saved to: $outputPath" -ForegroundColor Green
    Write-Host "Total operations: $($results.Count)" -ForegroundColor Cyan
    Write-Host "Successful: $(($results | Where-Object {$_.Status -eq 'Success'}).Count)" -ForegroundColor Green
    Write-Host "Failed: $(($results | Where-Object {$_.Status -eq 'Failed'}).Count)" -ForegroundColor Red
}

# ============================================================================
# MODE 5: BULK DELETE PROCESSES (OPTIMIZED)
# ============================================================================
#
# OPTIMIZATION IMPROVEMENTS:
# 1. Asks user if process approvals are enabled at the start
# 2. Uses CheckProcessDependencies API to find all dependencies for each process
# 3. Implements Approach A: Stores all dependencies and identifies duplicates
#    - More efficient: Only updates each dependent process once
#    - Better visibility: Shows full dependency summary before proceeding
# 4. Checks status of dependent processes using mobile API
# 5. Restores only archived dependencies to temporary group before updating
# 6. Removes dependencies intelligently based on type:
#    - Linked Process: Automatic removal via JSON update and re-publish
#    - Linked Process Group: Informational only (no removal needed)
#    - Other types: Manual removal with user prompts and validation
# 7. Re-archives restored dependencies after delete operation
#
# WORKFLOW:
# Phase 1: Gather processes to delete and get their UniqueIds
# Phase 2: Check dependencies using CheckProcessDependencies API
#          - Tracks unique dependencies by Type|UniqueId
#          - Shows which processes reference each dependency
#          - Displays summary and asks for user confirmation
# Phase 3: Create temporary group for restoring archived dependencies
# Phase 4: Check status of each dependency, restore archived ones
# Phase 5: Remove dependencies from dependent processes
#          - Automatic: Linked Process dependencies via JSON update
#          - Informational: Linked Process Group dependencies (no action)
#          - Manual: Other dependency types with user validation loop
#          - Validates all manual dependencies are removed before proceeding
# Phase 6-10: Original delete workflow (ownership, archive, delete, cleanup)
# ============================================================================

function Get-ProcessDependencies {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$ProcessUniqueId
    )

    try {
        $url = "$SiteURL/Api/v1/Processes/$ProcessUniqueId/CheckProcessDependencies?searchBehavior=15"
        $response = Invoke-ApiGet -Url $url -Token $Token
        return $response
    }
    catch {
        Write-Host "  Error checking dependencies for process $ProcessUniqueId : $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }
}

function Get-ProcessStatus {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$ProcessUniqueId
    )

    try {
        # Use the regular API endpoint to get current working state (not cached published state)
        $url = "$SiteURL/Api/v1/Processes/$ProcessUniqueId"
        $response = Invoke-ApiGet -Url $url -Token $Token

        if ($response -and $response.processJson) {
            return $response.processJson
        }
        return $null
    }
    catch {
        Write-Host "  Error getting status for process $ProcessUniqueId : $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Archive-Process {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$ProcessUniqueId,
        [string]$Comment = "Bulk operation"
    )

    try {
        # Step 1: Archive the process using the correct API format
        $archiveUrl = "$SiteURL/Process/Edit/ArchiveProcess"
        $archiveBody = @{
            processUniqueId = $ProcessUniqueId
            comment = $Comment
        }

        $archiveResult = Invoke-ApiPost -Url $archiveUrl -Token $Token -Body $archiveBody

        if (-not $archiveResult) {
            return $false
        }

        # Step 2: Check if we need to bypass approval
        # After archiving, the process might be in a pending approval state
        # We need to call the Publish endpoint to complete the archive

        # Get the current process data to get ProcessRevisionEditId
        $getUrl = "$SiteURL/Api/v1/Processes/$ProcessUniqueId"
        $processData = Invoke-ApiGet -Url $getUrl -Token $Token

        if ($processData -and $processData.processJson -and $processData.processJson.ProcessRevisionEditId) {
            $processRevisionEditId = $processData.processJson.ProcessRevisionEditId

            # Call the publish/approval bypass endpoint
            $publishUrl = "$SiteURL/Api/v1/Processes/$ProcessUniqueId/Publish"
            $publishBody = @{
                ProcessRevisionEditId = $processRevisionEditId
                IsPublishNow = $true
            }

            Invoke-ApiPost -Url $publishUrl -Token $Token -Body $publishBody | Out-Null
        }

        return $true
    }
    catch {
        Write-Host "  Archive error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Delete-Process {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$ProcessUniqueId,
        [string]$ProcessGroupUniqueId
    )

    try {
        # Delete the process using the correct API format
        $deleteUrl = "$SiteURL/Process/Edit/DeleteProcess"
        $deleteBody = @{
            processUniqueId = $ProcessUniqueId
        }

        # Add processGroupUniqueId if available
        if ($ProcessGroupUniqueId) {
            $deleteBody.processGroupUniqueId = $ProcessGroupUniqueId
        }

        $deleteResult = Invoke-ApiPost -Url $deleteUrl -Token $Token -Body $deleteBody

        if ($deleteResult -ne $null) {
            return $true
        } else {
            return $false
        }
    }
    catch {
        Write-Host "  Delete error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Find-ProcessLinksInJson {
    param(
        [string]$ProcessJson,
        [string]$TargetProcessUniqueId
    )

    # Convert JSON string to object
    $processObj = $ProcessJson | ConvertFrom-Json

    # Check ProcessProcedures.ProcessLink
    if ($processObj.ProcessProcedures.ProcessLink) {
        $found = @($processObj.ProcessProcedures.ProcessLink | Where-Object {
            $_.LinkedProcessUniqueId -eq $TargetProcessUniqueId
        })
        if ($found.Count -gt 0) {
            return $true
        }
    }

    # Check ChildProcessProcedures in Activities
    if ($processObj.ProcessProcedures.Activity) {
        foreach ($activity in $processObj.ProcessProcedures.Activity) {
            if ($activity.ChildProcessProcedures) {
                # Check each child type (Note, Task, Information, etc.)
                $childTypes = @('Note', 'Task', 'Information', 'Form', 'Guide', 'Image', 'Policy', 'Training', 'Video', 'WebLink')

                foreach ($childType in $childTypes) {
                    if ($activity.ChildProcessProcedures.$childType) {
                        foreach ($child in $activity.ChildProcessProcedures.$childType) {
                            if ($child.LinkedProcessUniqueId -eq $TargetProcessUniqueId) {
                                return $true
                            }
                        }
                    }
                }
            }
        }
    }

    return $false
}

function Get-ArchivedProcessDependencies {
    param(
        [string]$SiteURL,
        [string]$Token,
        [hashtable]$ProcessDeleteMap
    )

    Write-Host "  Fetching list of archived processes..." -ForegroundColor Gray

    $archivedDependencies = @()
    $page = 1
    $pageSize = 20
    $hasMore = $true

    # Step 1: Fetch all archived processes with pagination
    while ($hasMore) {
        try {
            $listUrl = "$SiteURL/Bff/Process/api/v1/processes?Page=$page&PageSize=$pageSize&ListType=7"
            $response = Invoke-ApiGet -Url $listUrl -Token $Token

            if ($response -and $response.items -and $response.items.Count -gt 0) {
                Write-Host "  Page $page : Found $($response.items.Count) archived processes" -ForegroundColor Gray

                # Collect UniqueIds for batch fetching
                $uniqueIds = $response.items | ForEach-Object { $_.processUniqueId }

                # Step 2: Batch fetch archived process details (10-20 per batch for efficiency)
                $batchSize = 15
                for ($i = 0; $i -lt $uniqueIds.Count; $i += $batchSize) {
                    $batch = $uniqueIds[$i..[Math]::Min($i + $batchSize - 1, $uniqueIds.Count - 1)]

                    # Build URL with multiple processUniqueIds query parameters
                    $queryParams = $batch | ForEach-Object { "processUniqueIds=$_" }
                    $batchUrl = "$SiteURL/mobile/api/v1/processes?" + ($queryParams -join '&')

                    try {
                        $batchResponse = Invoke-ApiGet -Url $batchUrl -Token $Token

                        if ($batchResponse -and $batchResponse.data -and $batchResponse.data.Count -gt 0) {
                            # Step 3: Search each archived process for links to processes being deleted
                            foreach ($archivedProcess in $batchResponse.data) {
                                $archivedUniqueId = $archivedProcess.ProcessModel.UniqueId
                                $archivedName = $archivedProcess.ProcessModel.Name
                                $archivedProcessJson = $archivedProcess.ProcessModel | ConvertTo-Json -Depth 20 -Compress

                                # Check if this archived process has links to any process being deleted
                                foreach ($processKey in $ProcessDeleteMap.Keys) {
                                    $processInfo = $ProcessDeleteMap[$processKey]
                                    $targetUniqueId = $processInfo.UniqueId

                                    if (Find-ProcessLinksInJson -ProcessJson $archivedProcessJson -TargetProcessUniqueId $targetUniqueId) {
                                        Write-Host "    Found: $archivedName has link to process $targetUniqueId" -ForegroundColor Yellow

                                        # Add to dependencies list
                                        $archivedDependencies += @{
                                            Type = "Linked Process"
                                            UniqueId = $archivedUniqueId
                                            Name = $archivedName
                                            ReferencedProcessKey = $processKey
                                            IsArchived = $true
                                        }
                                    }
                                }
                            }
                        }
                    }
                    catch {
                        Write-Host "  Warning: Failed to fetch batch of archived processes: $($_.Exception.Message)" -ForegroundColor Yellow
                    }
                }

                # Check if there are more pages
                if ($response.items.Count -lt $pageSize) {
                    $hasMore = $false
                } else {
                    $page++
                }
            } else {
                $hasMore = $false
            }
        }
        catch {
            Write-Host "  Warning: Failed to fetch archived processes page $page : $($_.Exception.Message)" -ForegroundColor Yellow
            $hasMore = $false
        }
    }

    return $archivedDependencies
}

function Remove-ProcessLinksFromJson {
    param(
        [string]$ProcessJson,
        [string]$TargetProcessUniqueId
    )

    # Convert JSON string to object
    $processObj = $ProcessJson | ConvertFrom-Json

    $linksRemoved = 0

    # Remove from ProcessProcedures.ProcessLink
    if ($processObj.ProcessProcedures.ProcessLink) {
        $originalCount = @($processObj.ProcessProcedures.ProcessLink).Count
        $processObj.ProcessProcedures.ProcessLink = @($processObj.ProcessProcedures.ProcessLink | Where-Object {
            $_.LinkedProcessUniqueId -ne $TargetProcessUniqueId
        })
        $newCount = @($processObj.ProcessProcedures.ProcessLink).Count
        $linksRemoved += ($originalCount - $newCount)
    }

    # Remove from LinkedStakeholders
    if ($processObj.LinkedStakeholders.LinkedStakeholder) {
        $originalCount = @($processObj.LinkedStakeholders.LinkedStakeholder).Count
        # Need to get the ProcessId for the target UniqueId - we'll filter by matching the link
        # This is a bit tricky since we only have UniqueId, but LinkedStakeholder doesn't store UniqueId
        # We'll need to handle this carefully
        $processObj.LinkedStakeholders.LinkedStakeholder = @($processObj.LinkedStakeholders.LinkedStakeholder | Where-Object {
            # We can't directly filter by UniqueId here, so we'll keep all for now
            # The API will clean this up when we remove the actual links
            $true
        })
    }

    # Recursively clean ChildProcessProcedures in Activities
    if ($processObj.ProcessProcedures.Activity) {
        foreach ($activity in $processObj.ProcessProcedures.Activity) {
            if ($activity.ChildProcessProcedures) {
                # Check each child type (Note, Task, Information, etc.)
                $childTypes = @('Note', 'Task', 'Information', 'Form', 'Guide', 'Image', 'Policy', 'Training', 'Video', 'WebLink')

                foreach ($childType in $childTypes) {
                    if ($activity.ChildProcessProcedures.$childType) {
                        foreach ($child in $activity.ChildProcessProcedures.$childType) {
                            if ($child.LinkedProcessUniqueId -eq $TargetProcessUniqueId) {
                                # Clear the linked process fields
                                $child.LinkedProcessId = $null
                                $child.LinkedProcessUniqueId = $null
                                $child.LinkedProcessName = $null
                                $child.LinkedProcessDisplayName = $null
                                $child.LinkedProcessGroupId = $null
                                $child.LinkedProcessGroupName = $null
                                $child.LinkedProcessGroupUniqueId = $null
                                $linksRemoved++
                            }
                        }
                    }
                }
            }
        }
    }

    # Convert back to JSON string
    $cleanedJson = $processObj | ConvertTo-Json -Depth 20 -Compress

    return @{
        CleanedJson = $cleanedJson
        LinksRemoved = $linksRemoved
    }
}

function Remove-InputOutputReferencesFromJson {
    param(
        [string]$ProcessJson,
        [string]$TargetProcessUniqueId
    )

    # Convert JSON string to object
    $processObj = $ProcessJson | ConvertFrom-Json

    $referencesRemoved = 0

    # Remove from Inputs - filter out inputs where FromProcessUniqueId matches target
    if ($processObj.Inputs -and $processObj.Inputs.Input) {
        $originalCount = @($processObj.Inputs.Input).Count
        $processObj.Inputs.Input = @($processObj.Inputs.Input | Where-Object {
            $_.FromProcessUniqueId -ne $TargetProcessUniqueId
        })
        $newCount = @($processObj.Inputs.Input).Count
        $referencesRemoved += ($originalCount - $newCount)

        Write-Host "    Removed $($originalCount - $newCount) input reference(s)" -ForegroundColor Gray
    }

    # Remove from Outputs - filter out outputs where ToProcessUniqueId matches target
    if ($processObj.Outputs -and $processObj.Outputs.Output) {
        $originalCount = @($processObj.Outputs.Output).Count
        $processObj.Outputs.Output = @($processObj.Outputs.Output | Where-Object {
            $_.ToProcessUniqueId -ne $TargetProcessUniqueId
        })
        $newCount = @($processObj.Outputs.Output).Count
        $referencesRemoved += ($originalCount - $newCount)

        Write-Host "    Removed $($originalCount - $newCount) output reference(s)" -ForegroundColor Gray
    }

    # Convert back to JSON string
    $cleanedJson = $processObj | ConvertTo-Json -Depth 20 -Compress

    return @{
        CleanedJson = $cleanedJson
        ReferencesRemoved = $referencesRemoved
    }
}

function Update-ProcessAndPublish {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$ProcessUniqueId,
        [string]$TargetProcessUniqueId,
        [bool]$ApprovalsEnabled,
        [string]$DependencyType = "Linked Process"
    )

    try {
        Write-Host "  Fetching current process data..." -ForegroundColor Gray

        # Step 1: Get current process data
        $getUrl = "$SiteURL/Api/v1/Processes/$ProcessUniqueId"
        $processData = Invoke-ApiGet -Url $getUrl -Token $Token

        if (-not $processData -or -not $processData.processJson) {
            Write-Host "  Failed to retrieve process data" -ForegroundColor Red
            return $false
        }

        $processJson = $processData.processJson | ConvertTo-Json -Depth 20 -Compress
        $processRevisionEditId = $processData.processJson.ProcessRevisionEditId
        $majorVersion = [int]($processData.processJson.Version.Split('.')[0])
        $wasPreviouslyPublished = $majorVersion -gt 0

        Write-Host "  Current version: $($processData.processJson.Version), ProcessRevisionEditId: $processRevisionEditId" -ForegroundColor Gray

        # Step 2: Remove links/references from JSON based on dependency type
        if ($DependencyType -eq "Process Input" -or $DependencyType -eq "Process Output") {
            Write-Host "  Removing $DependencyType references to process $TargetProcessUniqueId..." -ForegroundColor Gray
            $result = Remove-InputOutputReferencesFromJson -ProcessJson $processJson -TargetProcessUniqueId $TargetProcessUniqueId

            if ($result.ReferencesRemoved -eq 0) {
                Write-Host "  No $DependencyType references found to remove" -ForegroundColor Yellow
                return $true
            }

            Write-Host "  Removed $($result.ReferencesRemoved) $DependencyType reference(s)" -ForegroundColor Green
        }
        else {
            # Default: Linked Process removal
            Write-Host "  Removing links to process $TargetProcessUniqueId..." -ForegroundColor Gray
            $result = Remove-ProcessLinksFromJson -ProcessJson $processJson -TargetProcessUniqueId $TargetProcessUniqueId

            if ($result.LinksRemoved -eq 0) {
                Write-Host "  No links found to remove" -ForegroundColor Yellow
                return $true
            }

            Write-Host "  Removed $($result.LinksRemoved) link(s)" -ForegroundColor Green
        }

        # Verify ProcessRevisionEditId is preserved in cleaned JSON
        $cleanedObj = $result.CleanedJson | ConvertFrom-Json
        if ($cleanedObj.ProcessRevisionEditId -ne $processRevisionEditId) {
            Write-Host "  WARNING: ProcessRevisionEditId mismatch! Original: $processRevisionEditId, Cleaned: $($cleanedObj.ProcessRevisionEditId)" -ForegroundColor Yellow
        } else {
            Write-Host "  ProcessRevisionEditId verified: $processRevisionEditId" -ForegroundColor Gray
        }

        # Step 3: Update process with cleaned JSON
        Write-Host "  Updating process..." -ForegroundColor Gray

        $updateBody = @{
            ProcessJson = $result.CleanedJson
            ChangeDescription = ""
            DoSubmitForApproval = $false
            DoPublish = $false
            SuppressChangeNotification = $false
            SharedActivityCollectionEditModel = @{
                ActivitiesToDelete = @()
                ActivitiesToShare = @()
                ActivitiesToUnlink = @()
            }
            VariantConnectionChangeStates = @()
        }

        $updateUrl = "$SiteURL/Api/v1/Processes/$ProcessUniqueId"
        $updateResult = Invoke-ApiPut -Url $updateUrl -Token $Token -Body $updateBody

        if (-not $updateResult -or -not $updateResult.Success) {
            Write-Host "  Failed to update process" -ForegroundColor Red
            if ($updateResult.Error) {
                Write-Host "    Error: $($updateResult.Error)" -ForegroundColor Red
            }
            if ($updateResult.StatusCode) {
                Write-Host "    HTTP Status: $($updateResult.StatusCode)" -ForegroundColor Red
            }
            return $false
        }

        Write-Host "  Process updated successfully (HTTP $($updateResult.StatusCode))" -ForegroundColor Green

        # Step 4: Publish if needed
        if ($wasPreviouslyPublished) {
            Write-Host "  Process requires publishing..." -ForegroundColor Gray

            # Get updated process data to get new ProcessRevisionEditId
            Start-Sleep -Seconds 1
            $updatedProcessData = Invoke-ApiGet -Url $getUrl -Token $Token
            $newProcessRevisionEditId = $updatedProcessData.processJson.ProcessRevisionEditId

            if ($ApprovalsEnabled) {
                Write-Host "  Approvals enabled - submitting for approval and bypassing..." -ForegroundColor Gray

                # Get the updated process JSON with new ProcessRevisionEditId
                $updatedProcessJson = $updatedProcessData.processJson | ConvertTo-Json -Depth 20 -Compress

                # Submit for approval
                $submitBody = @{
                    ProcessJson = $updatedProcessJson
                    ChangeDescription = "Automated dependency removal"
                    DoSubmitForApproval = $true
                    DoPublish = $false
                    SuppressChangeNotification = $false
                    SharedActivityCollectionEditModel = @{
                        ActivitiesToDelete = @()
                        ActivitiesToShare = @()
                        ActivitiesToUnlink = @()
                    }
                    VariantConnectionChangeStates = @()
                }

                $submitResult = Invoke-ApiPut -Url $updateUrl -Token $Token -Body $submitBody

                if (-not $submitResult -or -not $submitResult.Success) {
                    Write-Host "  Failed to submit for approval" -ForegroundColor Red
                    if ($submitResult.Error) {
                        Write-Host "    Error: $($submitResult.Error)" -ForegroundColor Red
                    }
                    return $false
                }

                Write-Host "  Submitted for approval successfully" -ForegroundColor Green

                # Wait and get the latest ProcessRevisionEditId after submit
                Start-Sleep -Seconds 2
                $latestProcessData = Invoke-ApiGet -Url $getUrl -Token $Token
                $latestProcessRevisionEditId = $latestProcessData.processJson.ProcessRevisionEditId

                # Bypass approval and publish
                $publishUrl = "$SiteURL/Api/v1/Processes/$ProcessUniqueId/Publish"
                $publishBody = @{
                    ProcessRevisionEditId = $latestProcessRevisionEditId.ToString()
                    IsPublishNow = $true
                }

                $publishResult = Invoke-ApiPost -Url $publishUrl -Token $Token -Body $publishBody

                if ($publishResult) {
                    Write-Host "  Process published successfully (approval bypassed)" -ForegroundColor Green
                    return $true
                } else {
                    Write-Host "  Failed to publish process" -ForegroundColor Red
                    return $false
                }
            }
            else {
                Write-Host "  Approvals not enabled - publishing directly..." -ForegroundColor Gray

                # Publish without approval
                $publishUrl = "$SiteURL/Process/Edit/PublishProcessRevisionEdit"
                $publishBody = @{
                    publishMessage = "Publishing Process"
                    processUniqueId = $ProcessUniqueId
                    processRevisionEditId = [int]$newProcessRevisionEditId
                }

                $publishResult = Invoke-ApiPost -Url $publishUrl -Token $Token -Body $publishBody

                if ($publishResult) {
                    Write-Host "  Process published successfully" -ForegroundColor Green
                    return $true
                } else {
                    Write-Host "  Failed to publish process" -ForegroundColor Red
                    return $false
                }
            }
        }
        else {
            Write-Host "  Process has not been previously published - no publish needed" -ForegroundColor Green
            return $true
        }
    }
    catch {
        Write-Host "  Error updating process: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Get-ArchivedProcessDetails {
    param(
        [string]$SiteURL,
        [string]$Token,
        [array]$ProcessUniqueIds
    )

    Write-Host "  Fetching archived process details using mobile API..." -ForegroundColor Gray

    $processDetails = @()

    # The mobile API can handle multiple processUniqueIds in a single request
    # However, we'll batch them to avoid URL length limits
    $batchSize = 10
    for ($i = 0; $i -lt $ProcessUniqueIds.Count; $i += $batchSize) {
        $batch = $ProcessUniqueIds[$i..[Math]::Min($i + $batchSize - 1, $ProcessUniqueIds.Count - 1)]
        $uniqueIdsParam = $batch -join ","

        $url = "$SiteURL/mobile/api/v1/processes?processUniqueIds=$uniqueIdsParam"
        $response = Invoke-ApiGet -Url $url -Token $Token

        if ($response -and $response.data) {
            $processDetails += $response.data
        }
    }

    return $processDetails
}

function Get-ArchivedProcessesWithReferences {
    param(
        [string]$SiteURL,
        [string]$Token,
        [array]$ProcessIdsToDelete,
        [array]$ArchivedProcesses
    )

    Write-Host "Checking archived processes for references using mobile API..." -ForegroundColor Cyan

    $referencingArchivedProcesses = @()
    $processUniqueIdSet = @{}

    # First, get the unique IDs for the processes to be deleted
    Write-Host "  Getting details for processes to be deleted..." -ForegroundColor Gray
    foreach ($processId in $ProcessIdsToDelete) {
        $getUrl = "$SiteURL/Api/v1/Processes/$processId"
        $process = Invoke-ApiGet -Url $getUrl -Token $Token
        if ($process) {
            $processUniqueIdSet[$process.uniqueId] = $processId
        }
    }

    # Get archived process unique IDs
    $archivedUniqueIds = $ArchivedProcesses | ForEach-Object { $_.processUniqueId }

    # Fetch details for all archived processes using mobile API
    $archivedProcessDetails = Get-ArchivedProcessDetails -SiteURL $SiteURL -Token $Token -ProcessUniqueIds $archivedUniqueIds

    Write-Host "  Scanning $($archivedProcessDetails.Count) archived processes for references..." -ForegroundColor Gray

    foreach ($archivedProcess in $archivedProcessDetails) {
        # Convert to JSON to search for references
        $processJson = $archivedProcess | ConvertTo-Json -Depth 20

        # Check for references to any of the processes being deleted
        $hasReferences = $false
        $referencedProcessIds = @()

        foreach ($uniqueId in $processUniqueIdSet.Keys) {
            if ($processJson -match $uniqueId) {
                $hasReferences = $true
                $referencedProcessIds += $processUniqueIdSet[$uniqueId]
                Write-Host "    Found: Archived process '$($archivedProcess.ProcessModel.Name)' (ID: $($archivedProcess.ProcessModel.Id)) references process with uniqueId: $uniqueId" -ForegroundColor Yellow
            }
        }

        if ($hasReferences) {
            $referencingArchivedProcesses += [PSCustomObject]@{
                ProcessId = $archivedProcess.ProcessModel.Id
                ProcessUniqueId = $archivedProcess.ProcessUniqueId
                ProcessName = $archivedProcess.ProcessModel.Name
                ReferencedProcessIds = $referencedProcessIds
            }
        }
    }

    Write-Host "  Found $($referencingArchivedProcesses.Count) archived processes with references to processes being deleted" -ForegroundColor $(if ($referencingArchivedProcesses.Count -eq 0) { "Green" } else { "Yellow" })

    return $referencingArchivedProcesses
}

function Get-ProcessReferences {
    param(
        [string]$SiteURL,
        [string]$Token,
        [array]$ProcessIdsToDelete,
        [array]$AllProcesses
    )

    Write-Host "Scanning for references to processes to be deleted..." -ForegroundColor Cyan

    $references = @()
    $processIdSet = @{}
    $ProcessIdsToDelete | ForEach-Object { $processIdSet[$_] = $true }

    foreach ($process in $AllProcesses) {
        # Skip processes that are being deleted
        if ($processIdSet.ContainsKey($process.id)) {
            continue
        }

        # Get full process details
        $getUrl = "$SiteURL/Api/v1/Processes/$($process.id)"
        $fullProcess = Invoke-ApiGet -Url $getUrl -Token $Token

        if ($fullProcess) {
            $processJson = $fullProcess | ConvertTo-Json -Depth 10

            # Check for references
            foreach ($deleteId in $ProcessIdsToDelete) {
                if ($processJson -match $deleteId) {
                    $references += [PSCustomObject]@{
                        ReferencingProcessId = $process.id
                        ReferencingProcessName = $process.name
                        ReferencedProcessId = $deleteId
                    }
                    Write-Host "  Found reference: Process $($process.id) '$($process.name)' references Process $deleteId" -ForegroundColor Yellow
                }
            }
        }
    }

    return $references
}

function Remove-ProcessReferences {
    param(
        [string]$SiteURL,
        [string]$Token,
        [array]$References
    )

    Write-Host "`nRemoving references to processes being deleted..." -ForegroundColor Cyan

    $processesUpdated = @{}

    foreach ($ref in $References) {
        if (-not $processesUpdated.ContainsKey($ref.ReferencingProcessId)) {
            Write-Host "Updating Process $($ref.ReferencingProcessId) '$($ref.ReferencingProcessName)'" -ForegroundColor White

            # Get process
            $getUrl = "$SiteURL/Api/v1/Processes/$($ref.ReferencingProcessId)"
            $process = Invoke-ApiGet -Url $getUrl -Token $Token

            if ($process) {
                # Convert to JSON, remove references, convert back
                # This is a simplified approach - you may need more sophisticated logic
                # to properly remove specific references from complex nested structures

                # For now, we'll just log that references exist
                # A full implementation would parse and modify specific fields
                Write-Host "  Warning: Process contains references - manual review may be needed" -ForegroundColor Yellow

                $processesUpdated[$ref.ReferencingProcessId] = $true
            }
        }
    }

    Write-Host "Reference removal scan complete" -ForegroundColor Green
}

function Invoke-BulkDeleteProcesses {
    param(
        [string]$SiteURL,
        [string]$Token,
        [string]$SourceType,  # "CSV" or "Group"
        [string]$CsvPath = "",
        [int]$GroupID = -1,
        [string]$GroupUniqueId = "",
        [string]$TempGroupName = "Bulk Delete Temporary Group",
        [string]$CurrentUsername
    )

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "BULK DELETE PROCESSES OPERATION" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "WARNING: This is a destructive operation!" -ForegroundColor Red
    Write-Host "This will permanently delete processes after removing references." -ForegroundColor Red

    # Ask about process approvals
    $approvalsEnabled = (Read-Host "Are process approvals enabled in your environment? (Y/N)") -eq 'Y'
    if ($approvalsEnabled) {
        Write-Host "Process approvals are enabled - this will be considered during dependency removal" -ForegroundColor Yellow
    }

    $confirm = Read-Host "Type 'DELETE' to confirm you want to proceed"
    if ($confirm -ne 'DELETE') {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }

    $results = @()
    $processesToDelete = @()

    # Step 1: Gather processes to delete
    Write-Host "`n=== PHASE 1: Gathering Processes ===" -ForegroundColor Cyan

    if ($SourceType -eq "CSV") {
        $csv = Read-CsvWithFlexibleHeaders -Path $CsvPath
        if (-not $csv) { return }

        foreach ($row in $csv) {
            $id = Get-IdFromCsvRow -Row $row
            if ($id) {
                $processesToDelete += $id
            }
        }
    }
    else {  # Group-based
        $includeSubgroups = (Read-Host "Include subgroups? (Y/N)") -eq 'Y'
        $processes = Get-ProcessesFromGroup -SiteURL $SiteURL -Token $Token -GroupID $GroupID -GroupUniqueId $GroupUniqueId -IncludeSubgroups $includeSubgroups
        $processesToDelete = $processes | ForEach-Object { $_.id }
    }

    Write-Host "Identified $($processesToDelete.Count) processes to delete" -ForegroundColor Green

    if ($processesToDelete.Count -eq 0) {
        Write-Host "No processes to delete" -ForegroundColor Yellow
        return
    }

    # Step 1.5: Get unique IDs and numeric IDs for all processes to delete
    Write-Host "`n=== Getting Process Details ===" -ForegroundColor Cyan

    $processDeleteMap = @{}  # Maps any ID to object with {NumericId, UniqueId, GroupUniqueId}
    foreach ($processId in $processesToDelete) {
        # Check if the ID is already a GUID (UniqueId) or a numeric ID
        $guidRegex = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

        if ($processId -match $guidRegex) {
            # It's already a UniqueId (GUID format), need to fetch numeric ID and group info
            Write-Host "  Process UniqueId: $processId (fetching numeric ID and group)" -ForegroundColor Gray
            $processStatus = Get-ProcessStatus -SiteURL $SiteURL -Token $Token -ProcessUniqueId $processId
            if ($processStatus) {
                $numericId = $processStatus.Id
                $groupUniqueId = if ($processStatus.GroupUniqueId) {
                    $processStatus.GroupUniqueId
                } else {
                    $null
                }
                $processDeleteMap[$processId] = @{
                    NumericId = $numericId
                    UniqueId = $processId
                    GroupUniqueId = $groupUniqueId
                }
                Write-Host "    -> Numeric ID: $numericId, GroupUniqueId: $groupUniqueId" -ForegroundColor Gray
            } else {
                Write-Host "  Warning: Could not retrieve process details for UniqueId $processId" -ForegroundColor Yellow
            }
        } else {
            # It's a numeric ID, fetch the process to get the UniqueId and group info
            $getUrl = "$SiteURL/Api/v1/Processes/$processId"
            $process = Invoke-ApiGet -Url $getUrl -Token $Token
            if ($process -and $process.uniqueId) {
                # Get the process status to retrieve group information
                $processStatus = Get-ProcessStatus -SiteURL $SiteURL -Token $Token -ProcessUniqueId $process.uniqueId
                $groupUniqueId = if ($processStatus -and $processStatus.GroupUniqueId) {
                    $processStatus.GroupUniqueId
                } else {
                    $null
                }
                $processDeleteMap[$processId] = @{
                    NumericId = $processId
                    UniqueId = $process.uniqueId
                    GroupUniqueId = $groupUniqueId
                }
                Write-Host "  Process ID $processId -> UniqueId: $($process.uniqueId), GroupUniqueId: $groupUniqueId" -ForegroundColor Gray
            } else {
                Write-Host "  Warning: Could not retrieve process details for ID $processId" -ForegroundColor Yellow
            }
        }
    }

    # Step 2: Check dependencies for each process (active and archived)
    Write-Host "`n=== PHASE 2: Checking Dependencies ===" -ForegroundColor Cyan

    $allDependencies = @()  # Array to store all dependencies
    $dependencyMap = @{}    # Map to track unique dependencies by UniqueId

    # Part 1: Check active process dependencies
    Write-Host "Checking active process dependencies..." -ForegroundColor Gray
    foreach ($processKey in $processDeleteMap.Keys) {
        $processInfo = $processDeleteMap[$processKey]
        $processUniqueId = $processInfo.UniqueId
        $processNumericId = $processInfo.NumericId
        Write-Host "  Process ID $processNumericId (UniqueId: $processUniqueId)..." -ForegroundColor White

        $dependencies = Get-ProcessDependencies -SiteURL $SiteURL -Token $Token -ProcessUniqueId $processUniqueId

        if ($dependencies -and $dependencies.Count -gt 0) {
            foreach ($depType in $dependencies) {
                $typeName = $depType.Type
                Write-Host "    Found $($depType.Dependencies.Count) dependencies of type: $typeName" -ForegroundColor Yellow

                foreach ($dep in $depType.Dependencies) {
                    $depUniqueId = $dep.UniqueId
                    $depName = $dep.Name

                    # Create a unique key for this dependency
                    $depKey = "$typeName|$depUniqueId"

                    # Track which processes reference this dependency
                    if (-not $dependencyMap.ContainsKey($depKey)) {
                        $dependencyMap[$depKey] = @{
                            Type = $typeName
                            UniqueId = $depUniqueId
                            Name = $depName
                            ReferencedByProcesses = @()
                        }
                    }

                    # Add the current process to the list of processes that reference this dependency
                    # Use $processKey (the original ID) as the key for consistency with processDeleteMap
                    if ($dependencyMap[$depKey].ReferencedByProcesses -notcontains $processKey) {
                        $dependencyMap[$depKey].ReferencedByProcesses += $processKey
                    }

                    Write-Host "      - $depName ($depUniqueId)" -ForegroundColor Gray
                }
            }
        } else {
            Write-Host "    No active dependencies found" -ForegroundColor Green
        }
    }

    # Part 2: Check archived process dependencies
    Write-Host "`nChecking archived process dependencies..." -ForegroundColor Gray
    Write-Host "  NOTE: The API only returns active dependencies, so we check archived processes separately." -ForegroundColor DarkGray

    $archivedDependencies = Get-ArchivedProcessDependencies -SiteURL $SiteURL -Token $Token -ProcessDeleteMap $processDeleteMap

    if ($archivedDependencies.Count -gt 0) {
        Write-Host "  Found $($archivedDependencies.Count) archived process(es) with dependencies" -ForegroundColor Yellow

        # Add archived dependencies to the dependencyMap
        foreach ($archivedDep in $archivedDependencies) {
            $depKey = "$($archivedDep.Type)|$($archivedDep.UniqueId)"

            if (-not $dependencyMap.ContainsKey($depKey)) {
                $dependencyMap[$depKey] = @{
                    Type = $archivedDep.Type
                    UniqueId = $archivedDep.UniqueId
                    Name = $archivedDep.Name
                    ReferencedByProcesses = @()
                    IsArchived = $true
                }
            }

            # Add the process key that this archived process references
            if ($dependencyMap[$depKey].ReferencedByProcesses -notcontains $archivedDep.ReferencedProcessKey) {
                $dependencyMap[$depKey].ReferencedByProcesses += $archivedDep.ReferencedProcessKey
            }

            Write-Host "    - [Archived] $($archivedDep.Name) ($($archivedDep.UniqueId))" -ForegroundColor Gray
        }
    } else {
        Write-Host "  No archived process dependencies found" -ForegroundColor Green
    }

    # Display summary of all dependencies (active and archived)
    Write-Host "`n=== Dependency Summary ===" -ForegroundColor Cyan
    if ($dependencyMap.Count -eq 0) {
        Write-Host "No dependencies found - processes can be deleted directly" -ForegroundColor Green
    } else {
        Write-Host "Found $($dependencyMap.Count) unique dependencies:" -ForegroundColor Yellow
        $archivedCount = ($dependencyMap.Values | Where-Object { $_.IsArchived -eq $true }).Count
        if ($archivedCount -gt 0) {
            Write-Host "  ($archivedCount will be temporarily restored for link removal)" -ForegroundColor Cyan
        }

        foreach ($depKey in $dependencyMap.Keys) {
            $dep = $dependencyMap[$depKey]
            $refCount = $dep.ReferencedByProcesses.Count
            $archivedLabel = if ($dep.IsArchived) { " [Archived]" } else { "" }
            Write-Host "  [$($dep.Type)]$archivedLabel $($dep.Name)" -ForegroundColor White
            Write-Host "    Referenced by $refCount process(es) being deleted" -ForegroundColor Gray
        }

        $proceed = Read-Host "`nDo you want to proceed with dependency removal? (Y/N)"
        if ($proceed -ne 'Y') {
            Write-Host "Operation cancelled by user" -ForegroundColor Yellow
            return
        }
    }

    # Step 3: Create temporary group for restoring archived dependencies
    Write-Host "`n=== PHASE 3: Creating Temporary Group ===" -ForegroundColor Cyan

    $tempGroup = New-ProcessGroup -SiteURL $SiteURL -Token $Token -GroupName $TempGroupName

    if (-not $tempGroup -or -not $tempGroup.id -or $tempGroup.id -lt 0) {
        Write-Host "Failed to create temporary group. Operation cancelled." -ForegroundColor Red
        return
    }

    $tempGroupId = $tempGroup.id
    $tempGroupUniqueId = $tempGroup.uniqueId
    Write-Host "Temporary group created (ID: $tempGroupId, uniqueId: $tempGroupUniqueId)" -ForegroundColor Green

    # Step 4: Check status of each dependency and restore if needed
    Write-Host "`n=== PHASE 4: Checking Dependency Status and Restoring Archived Dependencies ===" -ForegroundColor Cyan

    $restoredDependencies = @()  # Track which dependencies were restored

    foreach ($depKey in $dependencyMap.Keys) {
        $dep = $dependencyMap[$depKey]

        # Only process archived dependencies from PHASE 2.5 (incoming references)
        # Skip outgoing dependencies from PHASE 2 (things the target process references)
        # We only need to restore processes that REFERENCE the targets being deleted, not processes REFERENCED BY the targets
        if ($dep.IsArchived -eq $true) {
            Write-Host "Checking status of dependency: $($dep.Name) ($($dep.UniqueId))" -ForegroundColor White

            $processStatus = Get-ProcessStatus -SiteURL $SiteURL -Token $Token -ProcessUniqueId $dep.UniqueId

            if ($processStatus) {
                $state = $processStatus.State
                $numericId = $processStatus.Id

                Write-Host "  Status: $state (Numeric ID: $numericId)" -ForegroundColor Gray

                if ($state -eq "Archived") {
                    Write-Host "  Process is archived - restoring to temporary group..." -ForegroundColor Yellow

                    $restoreUrl = "$SiteURL/Process/Edit/RestoreProcess"
                    $restoreBody = @{
                        processUniqueId = $dep.UniqueId
                        processGroupId = $tempGroupId.ToString()
                    }
                    $result = Invoke-ApiPost -Url $restoreUrl -Token $Token -Body $restoreBody

                    if ($result) {
                        Write-Host "  Successfully restored to temporary group" -ForegroundColor Green
                        $restoredDependencies += @{
                            UniqueId = $dep.UniqueId
                            NumericId = $numericId
                            Name = $dep.Name
                        }
                    } else {
                        Write-Host "  Failed to restore process" -ForegroundColor Red
                    }
                } else {
                    Write-Host "  Process is active - no restore needed" -ForegroundColor Green
                }
            } else {
                Write-Host "  Could not retrieve process status" -ForegroundColor Red
            }
        }
    }

    Write-Host "`nRestored $($restoredDependencies.Count) archived dependencies to temporary group" -ForegroundColor Green

    # Step 5: Remove dependencies
    Write-Host "`n=== PHASE 5: Removing Dependencies ===" -ForegroundColor Cyan

    if ($dependencyMap.Count -eq 0) {
        Write-Host "No dependencies to remove - skipping this phase" -ForegroundColor Green
    } else {
        # Separate dependencies by type
        $automaticDeps = @()
        $manualDeps = @()

        foreach ($depKey in $dependencyMap.Keys) {
            $dep = $dependencyMap[$depKey]
            # Automatic removal: Linked Process, Process Input, Process Output
            if ($dep.Type -eq "Linked Process" -or $dep.Type -eq "Process Input" -or $dep.Type -eq "Process Output") {
                $automaticDeps += $dep
            }
            else {
                # All other dependencies (including Linked Process Group) require manual removal
                $manualDeps += $dep
            }
        }

        # Handle automatic removal of dependencies (Linked Process, Process Input, Process Output)
        if ($automaticDeps.Count -gt 0) {
            Write-Host "`n--- Removing Dependencies (Automatic) ---" -ForegroundColor Cyan
            Write-Host "Processing $($automaticDeps.Count) dependencies (Linked Process, Process Input, Process Output)..." -ForegroundColor White

            $dependenciesProcessed = 0
            $dependenciesSuccessful = 0
            $dependenciesFailed = 0

            foreach ($dep in $automaticDeps) {
                $dependenciesProcessed++

                # Get all processes being deleted that reference this dependency
                $processesToRemoveFrom = $dep.ReferencedByProcesses

                Write-Host "`n[$dependenciesProcessed/$($automaticDeps.Count)] Processing $($dep.Type) dependency: $($dep.Name)" -ForegroundColor White
                Write-Host "  Removing references from $($processesToRemoveFrom.Count) process(es) being deleted" -ForegroundColor Gray

                # For each process being deleted that references this dependency
                foreach ($processIdToDelete in $processesToRemoveFrom) {
                    $processInfo = $processDeleteMap[$processIdToDelete]
                    $processUniqueIdToDelete = $processInfo.UniqueId

                    Write-Host "  Removing $($dep.Type) from dependent process: $($dep.Name) ($($dep.UniqueId))" -ForegroundColor White
                    Write-Host "    Target process to remove: $processUniqueIdToDelete" -ForegroundColor Gray

                    $success = Update-ProcessAndPublish -SiteURL $SiteURL -Token $Token `
                        -ProcessUniqueId $dep.UniqueId `
                        -TargetProcessUniqueId $processUniqueIdToDelete `
                        -ApprovalsEnabled $approvalsEnabled `
                        -DependencyType $dep.Type

                    if ($success) {
                        $dependenciesSuccessful++
                    } else {
                        $dependenciesFailed++
                    }

                    # Small delay between updates
                    Start-Sleep -Milliseconds 500
                }
            }

            Write-Host "`n=== Automatic Dependency Removal Summary ===" -ForegroundColor Cyan
            Write-Host "Total dependencies processed: $dependenciesProcessed" -ForegroundColor White
            Write-Host "Successful: $dependenciesSuccessful" -ForegroundColor Green
            Write-Host "Failed: $dependenciesFailed" -ForegroundColor $(if ($dependenciesFailed -gt 0) { "Red" } else { "Green" })

            if ($dependenciesFailed -gt 0) {
                $continueAnyway = Read-Host "`nSome dependencies failed to update. Do you want to continue? (Y/N)"
                if ($continueAnyway -ne 'Y') {
                    Write-Host "Operation cancelled. Restored dependencies remain in temporary group for manual cleanup." -ForegroundColor Yellow
                    return
                }
            }
        }

        # Handle manual removal dependencies (includes Linked Process Group and other types)
        if ($manualDeps.Count -gt 0) {
            Write-Host "`n--- Manual Dependency Removal Required ---" -ForegroundColor Yellow
            Write-Host "The following dependencies require MANUAL removal:" -ForegroundColor Yellow
            Write-Host ""

            # Group manual dependencies by the processes being deleted
            $manualDepsByProcess = @{}
            foreach ($dep in $manualDeps) {
                foreach ($processIdToDelete in $dep.ReferencedByProcesses) {
                    if (-not $manualDepsByProcess.ContainsKey($processIdToDelete)) {
                        $manualDepsByProcess[$processIdToDelete] = @()
                    }
                    $manualDepsByProcess[$processIdToDelete] += $dep
                }
            }

            # Display dependencies grouped by process
            foreach ($processIdToDelete in $manualDepsByProcess.Keys) {
                $processInfo = $processDeleteMap[$processIdToDelete]
                $processUniqueIdToDelete = $processInfo.UniqueId
                $deps = $manualDepsByProcess[$processIdToDelete]

                Write-Host "Process to be deleted: ID $processIdToDelete (UniqueId: $processUniqueIdToDelete)" -ForegroundColor White
                Write-Host "  Has the following dependencies that must be manually removed:" -ForegroundColor Yellow

                foreach ($dep in $deps) {
                    Write-Host "    - Type: $($dep.Type)" -ForegroundColor Cyan
                    Write-Host "      Name: $($dep.Name)" -ForegroundColor Cyan
                    Write-Host "      UniqueId: $($dep.UniqueId)" -ForegroundColor Cyan
                    Write-Host ""
                }
            }

            Write-Host "========================================" -ForegroundColor Yellow
            Write-Host "ACTION REQUIRED:" -ForegroundColor Red
            Write-Host "Please manually remove the dependencies listed above from Nintex Process Manager." -ForegroundColor Yellow
            Write-Host "The script will wait until you confirm they have been removed." -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Yellow
            Write-Host ""

            # Wait for user confirmation
            $manualRemovalComplete = $false
            while (-not $manualRemovalComplete) {
                $userConfirm = Read-Host "Have you manually removed all the dependencies listed above? (Y/N/Cancel)"

                if ($userConfirm -eq 'Cancel') {
                    Write-Host "Operation cancelled by user. Restored dependencies remain in temporary group for manual cleanup." -ForegroundColor Yellow
                    return
                }
                elseif ($userConfirm -eq 'Y') {
                    # Validate that dependencies have been removed
                    Write-Host "`nValidating that dependencies have been removed..." -ForegroundColor Cyan

                    $validationFailed = $false
                    foreach ($processId in $manualDepsByProcess.Keys) {
                        $processInfo = $processDeleteMap[$processId]
                        $processUniqueId = $processInfo.UniqueId
                        Write-Host "  Checking process $processId..." -ForegroundColor Gray

                        $currentDeps = Get-ProcessDependencies -SiteURL $SiteURL -Token $Token -ProcessUniqueId $processUniqueId

                        # Check if any of the manual dependencies still exist
                        $stillHasDeps = $false
                        if ($currentDeps -and $currentDeps.Count -gt 0) {
                            foreach ($depType in $currentDeps) {
                                # Skip automatically handled types: Linked Process, Process Input, Process Output
                                # Include Linked Process Group and other types since they require manual removal
                                if ($depType.Type -ne "Linked Process" -and $depType.Type -ne "Process Input" -and $depType.Type -ne "Process Output") {
                                    if ($depType.Dependencies -and $depType.Dependencies.Count -gt 0) {
                                        $stillHasDeps = $true
                                        Write-Host "    WARNING: Process still has $($depType.Dependencies.Count) dependencies of type '$($depType.Type)'" -ForegroundColor Red
                                        foreach ($dep in $depType.Dependencies) {
                                            Write-Host "      - $($dep.Name) ($($dep.UniqueId))" -ForegroundColor Red
                                        }
                                    }
                                }
                            }
                        }

                        if ($stillHasDeps) {
                            $validationFailed = $true
                        } else {
                            Write-Host "    Process validated - no manual dependencies remaining" -ForegroundColor Green
                        }
                    }

                    if ($validationFailed) {
                        Write-Host "`nValidation failed: Some dependencies still exist." -ForegroundColor Red
                        Write-Host "Please remove all dependencies before continuing." -ForegroundColor Yellow
                    } else {
                        Write-Host "`nValidation successful: All manual dependencies have been removed!" -ForegroundColor Green
                        $manualRemovalComplete = $true
                    }
                }
                else {
                    Write-Host "Please remove the dependencies and then enter 'Y' to continue, or 'Cancel' to abort." -ForegroundColor Yellow
                }
            }

            Write-Host "`nManual dependency removal completed successfully." -ForegroundColor Green
        }

        Write-Host "`n=== All Dependencies Processed ===" -ForegroundColor Green
    }

    # Step 6: Archive processes (skipping ownership update as it's not needed with bypass approvals)
    Write-Host "`n=== PHASE 6: Archiving Processes ===" -ForegroundColor Cyan

    foreach ($processKey in $processDeleteMap.Keys) {
        $processInfo = $processDeleteMap[$processKey]
        $processNumericId = $processInfo.NumericId
        $processUniqueId = $processInfo.UniqueId

        # Check if process is already archived
        $processStatus = Get-ProcessStatus -SiteURL $SiteURL -Token $Token -ProcessUniqueId $processUniqueId

        if ($processStatus -and $processStatus.State -eq "Archived") {
            Write-Host "Process $processNumericId is already archived - skipping" -ForegroundColor Gray
        } else {
            Write-Host "Archiving Process $processNumericId" -ForegroundColor White
            Archive-Process -SiteURL $SiteURL -Token $Token -ProcessUniqueId $processUniqueId -Comment "Pre-delete archive" | Out-Null
        }
    }

    # Step 7: Delete processes
    Write-Host "`n=== PHASE 7: Deleting Processes ===" -ForegroundColor Cyan

    $confirm = Read-Host "Ready to PERMANENTLY DELETE processes. Type 'DELETE' to confirm"
    if ($confirm -ne 'DELETE') {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }

    foreach ($processKey in $processDeleteMap.Keys) {
        $processInfo = $processDeleteMap[$processKey]
        $processNumericId = $processInfo.NumericId
        $processUniqueId = $processInfo.UniqueId
        $processGroupUniqueId = $processInfo.GroupUniqueId

        Write-Host "Deleting Process $processNumericId (UniqueId: $processUniqueId)" -ForegroundColor Red

        $result = Delete-Process -SiteURL $SiteURL -Token $Token -ProcessUniqueId $processUniqueId -ProcessGroupUniqueId $processGroupUniqueId

        if ($result) {
            $results += [PSCustomObject]@{
                ProcessID = $processNumericId
                ProcessUniqueId = $processUniqueId
                Operation = "Delete"
                Status = "Success"
                Message = "Deleted"
            }
        } else {
            $results += [PSCustomObject]@{
                ProcessID = $processNumericId
                ProcessUniqueId = $processUniqueId
                Operation = "Delete"
                Status = "Failed"
                Message = "Delete failed"
            }
        }
    }

    Write-Host "`nProcesses deleted. Total: $($results.Count)" -ForegroundColor Cyan

    # Step 8: Re-archive temporarily restored dependencies
    Write-Host "`n=== PHASE 8: Re-archiving Temporarily Restored Dependencies ===" -ForegroundColor Cyan

    foreach ($restoredDep in $restoredDependencies) {
        Write-Host "Re-archiving dependency: $($restoredDep.Name) (ID: $($restoredDep.NumericId))" -ForegroundColor White

        $result = Archive-Process -SiteURL $SiteURL -Token $Token -ProcessUniqueId $restoredDep.UniqueId -Comment "Re-archiving after dependency cleanup"

        if ($result) {
            Write-Host "  Successfully re-archived" -ForegroundColor Green
        } else {
            Write-Host "  Failed to re-archive - may need manual cleanup" -ForegroundColor Yellow
        }
    }

    Write-Host "`nRe-archived $($restoredDependencies.Count) dependencies" -ForegroundColor Green

    # Step 9: Clean up temp group
    Write-Host "`n=== PHASE 9: Cleanup ===" -ForegroundColor Cyan
    Write-Host "Deleting temporary group (ID: $tempGroupId, UniqueId: $tempGroupUniqueId)..." -ForegroundColor White

    $deleteSuccess = Delete-ProcessGroup -SiteURL $SiteURL -Token $Token -GroupUniqueId $tempGroupUniqueId

    if (-not $deleteSuccess) {
        Write-Host "  Warning: Failed to delete temporary group. You may need to delete it manually." -ForegroundColor Yellow
    }

    # Save results
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outputPath = "Delete_Results_$timestamp.csv"
    $results | Export-Csv -Path $outputPath -NoTypeInformation

    Write-Host "`nResults saved to: $outputPath" -ForegroundColor Green
    Write-Host "Total deletions: $($results.Count)" -ForegroundColor Cyan
    Write-Host "Successful: $(($results | Where-Object {$_.Status -eq 'Success'}).Count)" -ForegroundColor Green
    Write-Host "Failed: $(($results | Where-Object {$_.Status -eq 'Failed'}).Count)" -ForegroundColor Red
}

# ============================================================================
# MAIN MENU AND FLOW
# ============================================================================

function Show-MainMenu {
    Write-Host "`n============================================" -ForegroundColor Cyan
    Write-Host "  NINTEX PROCESS MANAGER BULK OPERATIONS" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Select Operation Mode:" -ForegroundColor Yellow
    Write-Host "  [1] Bulk Archive" -ForegroundColor White
    Write-Host "  [2] Bulk Restore" -ForegroundColor White
    Write-Host "  [3] Bulk Update Location" -ForegroundColor White
    Write-Host "  [4] Bulk Update Ownership" -ForegroundColor White
    Write-Host "  [5] Bulk Delete Processes" -ForegroundColor White
    Write-Host "  [Q] Quit" -ForegroundColor White
    Write-Host ""
}

function Get-SourceType {
    param([int]$Mode)

    # Mode 3 (Update Location) and 4 (Update Ownership) always use CSV
    if ($Mode -eq 3 -or $Mode -eq 4) {
        return "CSV"
    }

    # Mode 2 (Restore) can be CSV or All
    if ($Mode -eq 2) {
        Write-Host "`nSelect Source:" -ForegroundColor Yellow
        Write-Host "  [1] CSV File (restore specific items)" -ForegroundColor White
        Write-Host "  [2] All Archived Items in Site" -ForegroundColor White
        $choice = Read-Host "Choice"

        if ($choice -eq '2') {
            return "All"
        }
        return "CSV"
    }

    # Other modes: CSV or Group
    Write-Host "`nSelect Source:" -ForegroundColor Yellow
    Write-Host "  [1] CSV File" -ForegroundColor White
    Write-Host "  [2] Process/Document Group" -ForegroundColor White
    $choice = Read-Host "Choice"

    if ($choice -eq '2') {
        return "Group"
    }
    return "CSV"
}

function Get-ObjectType {
    param([int]$Mode)

    # Mode 4 (Update Ownership) only supports Processes
    if ($Mode -eq 4) {
        return "Processes"
    }

    # Mode 5 (Delete) only supports Processes
    if ($Mode -eq 5) {
        return "Processes"
    }

    Write-Host "`nSelect Object Type:" -ForegroundColor Yellow
    Write-Host "  [1] Processes" -ForegroundColor White
    Write-Host "  [2] Documents" -ForegroundColor White
    Write-Host "  [3] Both" -ForegroundColor White
    $choice = Read-Host "Choice"

    switch ($choice) {
        '2' { return "Documents" }
        '3' { return "Both" }
        default { return "Processes" }
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

# Clear screen
Clear-Host

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  NINTEX PROCESS MANAGER BULK OPERATIONS" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Load configuration
$config = Read-ConfigFile
if (-not $config) {
    Write-Host "Cannot proceed without valid configuration" -ForegroundColor Red
    exit
}

# Authenticate
$token = Get-AuthToken -SiteURL $config.SiteURL -Username $config.Username -Password $config.Password
if (-not $token) {
    Write-Host "Authentication failed. Cannot proceed." -ForegroundColor Red
    exit
}

# Main loop
$running = $true
while ($running) {
    Show-MainMenu
    $mode = Read-Host "Select Mode"

    switch ($mode) {
        '1' {  # Bulk Archive
            $sourceType = Get-SourceType -Mode 1
            $objectType = Get-ObjectType -Mode 1

            if ($sourceType -eq "CSV") {
                $csvPath = Read-Host "Enter CSV file path"
                Invoke-BulkArchive -SiteURL $config.SiteURL -Token $token -SourceType $sourceType -ObjectType $objectType -CsvPath $csvPath
            } else {
                $group = Select-ProcessGroup -SiteURL $config.SiteURL -Token $token -Prompt "Select Group to Archive"
                if ($group) {
                    Invoke-BulkArchive -SiteURL $config.SiteURL -Token $token -SourceType $sourceType -ObjectType $objectType -GroupID $group.id -GroupUniqueId $group.uniqueId
                }
            }
        }

        '2' {  # Bulk Restore
            $sourceType = Get-SourceType -Mode 2
            $objectType = Get-ObjectType -Mode 2

            # Get restore target group
            $restoreGroupId = -1
            if ($config.DefaultRestoreGroupID -and $config.DefaultRestoreGroupID -match '^\d+$') {
                $useDefault = Read-Host "Use default restore group ID $($config.DefaultRestoreGroupID)? (Y/N)"
                if ($useDefault -eq 'Y') {
                    $restoreGroupId = [int]$config.DefaultRestoreGroupID
                }
            }

            if ($restoreGroupId -lt 0) {
                $restoreGroup = Select-ProcessGroup -SiteURL $config.SiteURL -Token $token -Prompt "Select Target Group for Restore"
                if ($restoreGroup) {
                    $restoreGroupId = $restoreGroup.id
                }
            }

            if ($restoreGroupId -gt 0) {
                if ($sourceType -eq "CSV") {
                    $csvPath = Read-Host "Enter CSV file path"
                    Invoke-BulkRestore -SiteURL $config.SiteURL -Token $token -SourceType $sourceType -ObjectType $objectType -CsvPath $csvPath -RestoreGroupID $restoreGroupId
                } else {
                    Invoke-BulkRestore -SiteURL $config.SiteURL -Token $token -SourceType $sourceType -ObjectType $objectType -RestoreGroupID $restoreGroupId
                }
            }
        }

        '3' {  # Bulk Update Location
            $objectType = Get-ObjectType -Mode 3
            $csvPath = Read-Host "Enter CSV file path (must contain ID and NewGroupID columns)"
            Invoke-BulkUpdateLocation -SiteURL $config.SiteURL -Token $token -ObjectType $objectType -CsvPath $csvPath
        }

        '4' {  # Bulk Update Ownership
            $csvPath = Read-Host "Enter CSV file path (must contain ProcessID, NewOwner, NewExpert columns)"
            Invoke-BulkUpdateOwnership -SiteURL $config.SiteURL -Token $token -CsvPath $csvPath
        }

        '5' {  # Bulk Delete Processes
            $sourceType = Get-SourceType -Mode 5

            $tempGroupName = $config.TempGroupName
            if (-not $tempGroupName) {
                $tempGroupName = "Bulk Delete Temporary Group"
            }

            if ($sourceType -eq "CSV") {
                $csvPath = Read-Host "Enter CSV file path"
                Invoke-BulkDeleteProcesses -SiteURL $config.SiteURL -Token $token -SourceType $sourceType -CsvPath $csvPath -TempGroupName $tempGroupName -CurrentUsername $config.Username
            } else {
                $group = Select-ProcessGroup -SiteURL $config.SiteURL -Token $token -Prompt "Select Group to Delete (WARNING: Destructive!)"
                if ($group) {
                    Invoke-BulkDeleteProcesses -SiteURL $config.SiteURL -Token $token -SourceType $sourceType -GroupID $group.id -GroupUniqueId $group.uniqueId -TempGroupName $tempGroupName -CurrentUsername $config.Username
                }
            }
        }

        'Q' {
            $running = $false
            Write-Host "`nExiting..." -ForegroundColor Cyan
        }

        default {
            Write-Host "Invalid selection. Please try again." -ForegroundColor Red
        }
    }

    if ($running) {
        Write-Host "`nPress any key to continue..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

Write-Host "Thank you for using Nintex Process Manager Bulk Operations!" -ForegroundColor Green
