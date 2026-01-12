# Nintex Process Manager API Architecture Guide

This document outlines the correct API endpoints to use for different operations in the Nintex Process Manager Bulk Operations script.

## Core Principle

**ACTIVE processes** and **ARCHIVED processes** use different API endpoints. Using the wrong endpoint will result in errors or missing data.

---

## Process Fetching APIs

### List All Processes (Paginated)

**Endpoint:** `/Bff/Process/api/v1/processes`

**Query Parameters:**
- `Page`: Page number (starts at 1)
- `PageSize`: Number of items per page (typically 20)
- `ListType`: Process state filter

**ListType Values:**
- `0` = All active processes
- `7` = All archived processes

**Usage:**
```powershell
# Get active processes
$url = "$SiteURL/Bff/Process/api/v1/processes?Page=1&PageSize=20&ListType=0"

# Get archived processes
$url = "$SiteURL/Bff/Process/api/v1/processes?Page=1&PageSize=20&ListType=7"
```

**Returns:** List of process metadata (UniqueId, Name, etc.) without full process details

---

### Get Individual Process Details

#### For ACTIVE Processes

**Endpoint:** `/Api/v1/Processes/{processUniqueId}`

**Method:** GET

**Usage:**
```powershell
$url = "$SiteURL/Api/v1/Processes/$processUniqueId"
$response = Invoke-ApiGet -Url $url -Token $Token
$processJson = $response.processJson
```

**Returns:**
```json
{
  "processJson": {
    "UniqueId": "guid",
    "Name": "Process Name",
    "ProcessProcedures": { ... },
    "ProcessRevisionEditId": 123,
    ...
  },
  "processActions": { ... },
  "configuration": { ... }
}
```

**Use Cases:**
- Getting current working state of active process
- Fetching process details for editing
- Checking active process dependencies

#### For ARCHIVED Processes

**Endpoint:** `/mobile/api/v1/processes`

**Method:** GET

**Query Parameters:** `processUniqueIds={guid1}&processUniqueIds={guid2}&...`

**Batch Support:** Yes (can fetch multiple processes in one call)

**Usage:**
```powershell
# Single process
$url = "$SiteURL/mobile/api/v1/processes?processUniqueIds=$processUniqueId"

# Multiple processes (batch)
$queryParams = @("processUniqueIds=guid1", "processUniqueIds=guid2")
$url = "$SiteURL/mobile/api/v1/processes?" + ($queryParams -join '&')

$response = Invoke-ApiGet -Url $url -Token $Token
$processes = $response.data
```

**Returns:**
```json
{
  "data": [
    {
      "ProcessModel": {
        "UniqueId": "guid",
        "Name": "Process Name",
        "ProcessProcedures": { ... },
        ...
      }
    }
  ]
}
```

**Use Cases:**
- Getting archived process details
- Batch fetching multiple archived processes
- Searching archived processes for dependencies

---

## Process Link Removal Behavior

### CRITICAL: Decision Links vs Process Links

When removing process dependencies, Nintex Process Manager handles different link types differently:

#### Decision Links (ProcessProcedures.Decision)

**Behavior:** Decision links should be **orphaned**, not fully removed.

**What this means:**
- Clear the link reference fields: `LinkedProcessId`, `LinkedProcessUniqueId`, `LinkedProcessName`
- **KEEP** `LinkedProcessDisplayName` - Users need to see what was linked
- Change `DecisionLinkType` from `4` (linked) to `7` (orphaned/broken link)
- This creates a visual indicator in the UI that a link existed but is now broken

**Example:**
```json
// BEFORE removing link (linked decision)
{
  "LinkedProcessId": 1472,
  "LinkedProcessUniqueId": "b8631d0f-b7f8-44bb-80ed-f89886551c42",
  "LinkedProcessName": "CSM Onboarding Process",
  "LinkedProcessDisplayName": "CSM Onboarding Process",
  "DecisionLinkType": 4  // 4 = linked
}

// AFTER removing link (orphaned decision)
{
  "LinkedProcessId": null,
  "LinkedProcessUniqueId": null,
  "LinkedProcessName": null,
  "LinkedProcessDisplayName": "CSM Onboarding Process",  // ✅ KEPT!
  "DecisionLinkType": 7  // ✅ Changed to 7 = orphaned
}
```

#### Process Links (ProcessProcedures.ProcessLink)

**Behavior:** Process links should be **fully removed** from the array.

**What this means:**
- Remove the entire ProcessLink object from the ProcessProcedures.ProcessLink array
- No orphaning - the link is completely deleted

**Example:**
```json
// BEFORE
"ProcessLink": [
  { "LinkedProcessUniqueId": "guid-to-delete", ... },
  { "LinkedProcessUniqueId": "other-guid", ... }
]

// AFTER
"ProcessLink": [
  { "LinkedProcessUniqueId": "other-guid", ... }
]
```

### LinkedStakeholders Must Be Preserved

**CRITICAL:** Do NOT remove entries from `LinkedStakeholders.LinkedStakeholder` array.

**Why:** LinkedStakeholders is a reference cache that Process Manager uses to:
- Track process relationships
- Show related processes in the UI
- Maintain the process dependency graph

**Example:**
```json
// Always keep LinkedStakeholders intact, even when removing links
"LinkedStakeholders": {
  "LinkedStakeholder": [
    {"ProcessId": 1502, "Link": "Process A", ...},
    {"ProcessId": 1472, "Link": "Process B", ...}  // Keep even if we orphaned a decision to Process B
  ]
}
```

### DecisionLinkType Values

- `4` = Active/linked decision
- `7` = Orphaned/broken decision link
- Other values may exist but these are the critical ones for link removal

---

## Update Process APIs

### Update Active Process

**Endpoint:** `/Api/v1/Processes/{processUniqueId}`

**Method:** PUT

**Body Structure:**
```json
{
  "ProcessJson": "{...json string...}",
  "ChangeDescription": "Description of changes",
  "DoSubmitForApproval": false,
  "DoPublish": false,
  "SuppressChangeNotification": false,
  "SharedActivityCollectionEditModel": {
    "ActivitiesToDelete": [],
    "ActivitiesToShare": [],
    "ActivitiesToUnlink": []
  },
  "VariantConnectionChangeStates": []
}
```

**Important Notes:**
- `ProcessJson` must be a JSON string (use `ConvertTo-Json -Depth 20 -Compress`)
- Depth 20 is critical for complex process structures
- After updating, may need to publish separately

---

## Dependency Checking APIs

### Check Process Dependencies (Outgoing)

**Endpoint:** `/Api/v1/Processes/{processUniqueId}/CheckProcessDependencies`

**Query Parameters:** `searchBehavior=15`

**Method:** GET

**Usage:**
```powershell
$url = "$SiteURL/Api/v1/Processes/$processUniqueId/CheckProcessDependencies?searchBehavior=15"
$dependencies = Invoke-ApiGet -Url $url -Token $Token
```

**Returns:** What resources/processes the target process **depends on** (outgoing dependencies)

**Limitation:** Only returns what the process references, NOT what other processes reference it!

### Check Incoming Dependencies

**No Direct API:** There is no single API endpoint to check what other processes reference a target process.

**Solution:** Must manually search through all processes:

1. For **active processes**: Fetch each individually using `/Api/v1/Processes/{processUniqueId}`
2. For **archived processes**: Batch fetch using `/mobile/api/v1/processes`
3. Search the JSON for references to target process UniqueId

**Code Example:**
```powershell
# Check if a process has links to a target
function Find-ProcessLinksInJson {
    param([string]$ProcessJson, [string]$TargetProcessUniqueId)

    $processObj = $ProcessJson | ConvertFrom-Json

    # Check ProcessProcedures.ProcessLink
    # Check ProcessProcedures.Decision
    # Check ChildProcessProcedures
    # etc.
}
```

---

## Publishing APIs

### Publish Process (No Approval)

**Endpoint:** `/Process/Edit/PublishProcessRevisionEdit`

**Method:** POST

**Body:**
```json
{
  "publishMessage": "Publishing Process",
  "processUniqueId": "guid",
  "processRevisionEditId": 123
}
```

### Publish Process (With Approval Bypass)

**Endpoint:** `/Api/v1/Processes/{processUniqueId}/Publish`

**Method:** POST

**Body:**
```json
{
  "ProcessRevisionEditId": "123",
  "IsPublishNow": true
}
```

---

## Group Management APIs

### Get Group Children (Breadcrumb)

**Endpoint:** `/bff/navigation/api/v1/breadcrumb/children`

**Query Parameters:** `type=ProcessGroup&id={groupUniqueId}`

**Returns:** Direct children (processes and subgroups) of a group

---

## Common Patterns

### Pattern 1: Scan All Active Processes for Dependencies

```powershell
# Step 1: Get list of all active processes (paginated)
$listUrl = "$SiteURL/Bff/Process/api/v1/processes?Page=$page&PageSize=20&ListType=0"
$response = Invoke-ApiGet -Url $listUrl -Token $Token

# Step 2: For each process, fetch full details individually
foreach ($item in $response.items) {
    $processUrl = "$SiteURL/Api/v1/Processes/$($item.processUniqueId)"
    $processData = Invoke-ApiGet -Url $processUrl -Token $Token
    # Search processData.processJson for references
}
```

### Pattern 2: Scan All Archived Processes for Dependencies

```powershell
# Step 1: Get list of all archived processes (paginated)
$listUrl = "$SiteURL/Bff/Process/api/v1/processes?Page=$page&PageSize=20&ListType=7"
$response = Invoke-ApiGet -Url $listUrl -Token $Token

# Step 2: Batch fetch process details using mobile API
$uniqueIds = $response.items | ForEach-Object { $_.processUniqueId }
$queryParams = $uniqueIds | ForEach-Object { "processUniqueIds=$_" }
$batchUrl = "$SiteURL/mobile/api/v1/processes?" + ($queryParams -join '&')
$batchData = Invoke-ApiGet -Url $batchUrl -Token $Token

# Step 3: Search each process
foreach ($proc in $batchData.data) {
    # Search proc.ProcessModel for references
}
```

---

## Critical Rules

1. ✅ **Active processes** → Use `/Api/v1/Processes/{processUniqueId}` (individual fetch)
2. ✅ **Archived processes** → Use `/mobile/api/v1/processes` (batch fetch)
3. ❌ **Never** use mobile API for active processes
4. ❌ **Never** use individual fetch for archived processes (too slow)
5. ⚠️ Always use `ConvertTo-Json -Depth 20` when preparing process JSON for PUT requests
6. ⚠️ Progress indicators should use `\r` with `-NoNewline` for single-line updates

---

## Error Codes

- **400 Bad Request** - Usually means:
  - Invalid JSON structure in PUT body
  - Missing required fields
  - ProcessJson depth too shallow (use -Depth 20)
  - Wrong endpoint for process state (active vs archived)

- **404 Not Found** - Process doesn't exist or wrong UniqueId

- **403 Forbidden** - Insufficient permissions

---

## Questions?

If you encounter an API-related issue:

1. Check if you're using the correct endpoint for the process state (active vs archived)
2. Verify the request body structure matches the examples above
3. Check the -Depth parameter on ConvertTo-Json (should be 20)
4. Review the debug logs from Invoke-ApiPut/Post/Get functions
