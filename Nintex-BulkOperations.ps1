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
        }

        $jsonBody = $Body | ConvertTo-Json -Depth 10
        return Invoke-RestMethod -Uri $Url -Method Put -Headers $headers -Body $jsonBody
    }
    catch {
        Write-Host "API PUT Error ($Url): $($_.Exception.Message)" -ForegroundColor Red
        return $null
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
        Write-Host "    DEBUG: Calling API: $url" -ForegroundColor Cyan
        $response = Invoke-ApiGet -Url $url -Token $Token

        Write-Host "    DEBUG: Response type: $($response.GetType().Name)" -ForegroundColor Cyan
        Write-Host "    DEBUG: Response has 'items' property: $($response.PSObject.Properties.Name -contains 'items')" -ForegroundColor Cyan
        if ($response) {
            Write-Host "    DEBUG: Response properties: $($response.PSObject.Properties.Name -join ', ')" -ForegroundColor Cyan
        }

        if ($response -and $response.items) {
            Write-Host "    Page ${page}: Fetched $($response.items.Count) processes" -ForegroundColor Gray

            # Debug: Show sample process properties on first page
            if ($page -eq 1 -and $response.items.Count -gt 0) {
                $sampleProcess = $response.items[0]
                Write-Host "    Sample process: $($sampleProcess.processName)" -ForegroundColor Gray
                Write-Host "    Properties: groupId=$($sampleProcess.groupId), groupUniqueId=$($sampleProcess.groupUniqueId)" -ForegroundColor Gray
            }

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
        # Get root level groups only (lightweight call)
        $url = "$SiteURL/Process/View/GetChildProcessGroupTreeItems"
        $response = Invoke-ApiGet -Url $url -Token $Token

        if ($response -and $response.treeItems) {
            $matchedGroup = $response.treeItems | Where-Object { $_.uniqueId -eq $UniqueId }
            if ($matchedGroup) {
                return $matchedGroup.id
            }
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
            Write-Host "Failed to create group. Response did not contain groupid: $($createResponse | ConvertTo-Json -Depth 2)" -ForegroundColor Red
            return $null
        }

        Write-Host "  Group created with uniqueId: $newGroupUniqueId" -ForegroundColor Gray

        # Small delay to ensure group is fully created on server
        Start-Sleep -Milliseconds 500

        # Step 2: Rename the group to the desired name (with retry)
        $renameUrl = "$SiteURL/Process/Edit/RenameGroup"
        $renameBody = @{
            processGroupUniqueId = $newGroupUniqueId
            newName = $GroupName
        } | ConvertTo-Json

        Write-Host "  Step 2: Renaming group to '$GroupName'..." -ForegroundColor Gray

        $renameSuccess = $false
        $retryCount = 0
        $maxRetries = 2

        while (-not $renameSuccess -and $retryCount -le $maxRetries) {
            if ($retryCount -gt 0) {
                Write-Host "    Retry attempt $retryCount..." -ForegroundColor Gray
                Start-Sleep -Seconds 1
            }

            $renameResponse = Invoke-ApiPost -Url $renameUrl -Token $Token -Body $renameBody

            if ($renameResponse -and $renameResponse.isValid) {
                $renameSuccess = $true
            } else {
                $retryCount++
            }
        }

        # Step 3: Look up the numeric ID
        Write-Host "  Step 3: Looking up numeric group ID..." -ForegroundColor Gray
        $numericId = Get-GroupNumericIdByUniqueId -SiteURL $SiteURL -Token $Token -UniqueId $newGroupUniqueId

        if ($renameSuccess) {
            Write-Host "Successfully created and named group (ID: $numericId, uniqueId: $newGroupUniqueId)" -ForegroundColor Green
            return @{
                id = $numericId
                uniqueId = $newGroupUniqueId
                name = $GroupName
            }
        } else {
            Write-Host "Group created but rename failed after $maxRetries retries. (ID: $numericId, uniqueId: $newGroupUniqueId)" -ForegroundColor Yellow
            return @{
                id = $numericId
                uniqueId = $newGroupUniqueId
                name = "Unnamed Group"
            }
        }
    }
    catch {
        Write-Host "Error creating process group: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        return $null
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

            $archiveUrl = "$SiteURL/Process/Edit/ArchiveProcess?id=$processId"
            $result = Invoke-ApiPost -Url $archiveUrl -Token $Token

            if ($result) {
                # Verify archive
                $verifyUrl = "$SiteURL/Api/v1/Processes/$processId"
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
                    Write-Host "  Warning: Archive may have failed, trying publish first" -ForegroundColor Yellow

                    # Try publishing first (for processes in draft state)
                    $publishUrl = "$SiteURL/Api/v1/Processes/Publish"
                    $publishBody = @{ id = $processId }
                    $publishResult = Invoke-ApiPost -Url $publishUrl -Token $Token -Body $publishBody

                    Start-Sleep -Seconds 1

                    # Retry archive
                    $result = Invoke-ApiPost -Url $archiveUrl -Token $Token

                    $process = Invoke-ApiGet -Url $verifyUrl -Token $Token
                    if ($process -and $process.isArchived) {
                        Write-Host "  Success: Process archived after publish" -ForegroundColor Green
                        $results += [PSCustomObject]@{
                            ObjectType = "Process"
                            ObjectID = $processId
                            Operation = "Archive"
                            Status = "Success"
                            Message = "Archived after publish"
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
            $processesToRestore = $processes | ForEach-Object { $_.id }
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

            $restoreUrl = "$SiteURL/Process/Edit/RestoreProcess?id=$processId&processGroupId=$RestoreGroupID"
            $result = Invoke-ApiPost -Url $restoreUrl -Token $Token

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

                if ($updateResult) {
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

                if ($updateResult) {
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
# MODE 5: BULK DELETE PROCESSES
# ============================================================================

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

    # Step 2: Create temporary group and restore all archived processes
    Write-Host "`n=== PHASE 2: Creating Temporary Group and Restoring Archives ===" -ForegroundColor Cyan

    # Create temp group automatically
    $tempGroup = New-ProcessGroup -SiteURL $SiteURL -Token $Token -GroupName $TempGroupName

    if (-not $tempGroup -or -not $tempGroup.id -or $tempGroup.id -lt 0) {
        Write-Host "Failed to create temporary group. Operation cancelled." -ForegroundColor Red
        return
    }

    $tempGroupId = $tempGroup.id
    $tempGroupUniqueId = $tempGroup.uniqueId
    Write-Host "Temporary group created (ID: $tempGroupId, uniqueId: $tempGroupUniqueId)" -ForegroundColor Green

    # Get all archived processes
    $archivedProcesses = Get-ArchivedProcesses -SiteURL $SiteURL -Token $Token
    Write-Host "Found $($archivedProcesses.Count) archived processes" -ForegroundColor Green

    # Restore all to temp group
    $restoredProcessIds = @()
    foreach ($archivedProc in $archivedProcesses) {
        Write-Host "Restoring archived process '$($archivedProc.processName)' (uniqueId: $($archivedProc.processUniqueId)) to temp group" -ForegroundColor White

        $restoreUrl = "$SiteURL/Process/Edit/RestoreProcess"
        $restoreBody = @{
            processUniqueId = $archivedProc.processUniqueId
            processGroupId = $tempGroupId
        } | ConvertTo-Json

        $result = Invoke-ApiPost -Url $restoreUrl -Token $Token -Body $restoreBody
        if ($result) {
            $restoredProcessIds += $archivedProc.processId
        }
    }

    Write-Host "Restored $($restoredProcessIds.Count) processes to temporary group" -ForegroundColor Green

    # Step 3: Get all processes and find references
    Write-Host "`n=== PHASE 3: Scanning for References ===" -ForegroundColor Cyan

    $allProcesses = Get-ProcessesFromGroup -SiteURL $SiteURL -Token $Token -GroupID 0 -IncludeSubgroups $true
    Write-Host "Retrieved $($allProcesses.Count) total processes" -ForegroundColor Green

    $references = Get-ProcessReferences -SiteURL $SiteURL -Token $Token -ProcessIdsToDelete $processesToDelete -AllProcesses $allProcesses

    if ($references.Count -gt 0) {
        Write-Host "`nFound $($references.Count) references" -ForegroundColor Yellow
        $removeRefs = Read-Host "Do you want to attempt to remove these references? (Y/N)"

        if ($removeRefs -eq 'Y') {
            Remove-ProcessReferences -SiteURL $SiteURL -Token $Token -References $references
        } else {
            Write-Host "Warning: Proceeding without removing references may cause issues" -ForegroundColor Yellow
        }
    } else {
        Write-Host "No references found" -ForegroundColor Green
    }

    # Step 4: Update ownership to current user
    Write-Host "`n=== PHASE 4: Updating Ownership ===" -ForegroundColor Cyan

    foreach ($processId in $processesToDelete) {
        Write-Host "Updating ownership of Process $processId to $CurrentUsername" -ForegroundColor White

        $getUrl = "$SiteURL/Api/v1/Processes/$processId"
        $process = Invoke-ApiGet -Url $getUrl -Token $Token

        if ($process) {
            $process.owner = $CurrentUsername
            $process.expert = $CurrentUsername

            $updateUrl = "$SiteURL/Api/v1/Processes/$processId"
            Invoke-ApiPut -Url $updateUrl -Token $Token -Body $process | Out-Null
        }
    }

    # Step 5: Archive processes
    Write-Host "`n=== PHASE 5: Archiving Processes ===" -ForegroundColor Cyan

    $confirm = Read-Host "Ready to archive processes. Continue? (Y/N)"
    if ($confirm -ne 'Y') {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }

    foreach ($processId in $processesToDelete) {
        Write-Host "Archiving Process $processId" -ForegroundColor White

        $archiveUrl = "$SiteURL/Process/Edit/ArchiveProcess?id=$processId"
        Invoke-ApiPost -Url $archiveUrl -Token $Token | Out-Null
    }

    # Step 6: Delete processes
    Write-Host "`n=== PHASE 6: Deleting Processes ===" -ForegroundColor Cyan

    $confirm = Read-Host "Ready to PERMANENTLY DELETE processes. Type 'DELETE' to confirm"
    if ($confirm -ne 'DELETE') {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }

    foreach ($processId in $processesToDelete) {
        Write-Host "Deleting Process $processId" -ForegroundColor Red

        $deleteUrl = "$SiteURL/Process/Edit/DeleteProcess?id=$processId"
        $result = Invoke-ApiPost -Url $deleteUrl -Token $Token

        if ($result) {
            $results += [PSCustomObject]@{
                ProcessID = $processId
                Operation = "Delete"
                Status = "Success"
                Message = "Deleted"
            }
        } else {
            $results += [PSCustomObject]@{
                ProcessID = $processId
                Operation = "Delete"
                Status = "Failed"
                Message = "Delete failed"
            }
        }
    }

    # Step 7: Re-archive previously archived processes
    Write-Host "`n=== PHASE 7: Re-archiving Previously Archived Processes ===" -ForegroundColor Cyan

    foreach ($processId in $restoredProcessIds) {
        # Skip if this process was deleted
        if ($processesToDelete -contains $processId) {
            continue
        }

        Write-Host "Re-archiving Process $processId" -ForegroundColor White

        $archiveUrl = "$SiteURL/Process/Edit/ArchiveProcess?id=$processId"
        Invoke-ApiPost -Url $archiveUrl -Token $Token | Out-Null
    }

    # Step 8: Clean up temp group
    Write-Host "`n=== PHASE 8: Cleanup ===" -ForegroundColor Cyan
    Write-Host "You should manually delete the temporary group (ID: $tempGroupId) if it's empty" -ForegroundColor Yellow

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
