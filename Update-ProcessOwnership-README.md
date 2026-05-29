# Update Process Ownership (Standalone)

`Update-ProcessOwnership.ps1` is a self-contained PowerShell script for bulk
updating the **Owner** and/or **Expert** on a list of Nintex Process Manager
(Promapp) processes. It was extracted from "Mode 4" of the larger
`Nintex-BulkOperations.ps1` tool so it can be shared on its own.

It is fully standalone — it has no dependency on `Nintex-BulkOperations.ps1`.
You only need this script plus a `config.txt`.

## What it does

1. Reads a list of Process IDs from a file you provide.
2. Asks for (or accepts as parameters) the new **Owner** and/or **Expert**,
   identified by username.
3. Resolves each username to a numeric **user Id** and display **name** via the
   **SCIM API**.
4. For each process: fetches the process definition, sets `OwnerId`/`Owner`
   and/or `ExpertId`/`Expert` in the definition, and saves the process.
5. Writes a timestamped results CSV.

## Why SCIM?

The process definition stores the owner/expert as a **numeric user Id**
(`OwnerId`, `ExpertId`) plus a display **name** (`Owner`, `Expert`). The site's
autocomplete endpoint does not return the numeric Id, so the script uses the
SCIM API to look it up:

```
GET {ScimBaseUrl}/users?filter=userName eq "jonathan@palouse.io"
Authorization: Bearer {ScimApiKey}
```

From the SCIM response it takes:
- `Resources[0].id` → written to `OwnerId` / `ExpertId`
- the display name (`displayName`, else `name.formatted`, else
  `name.givenName + " " + name.familyName`) → written to `Owner` / `Expert`

## Requirements

- PowerShell 5.1 or later
- A Nintex Process Manager account with permission to edit the target processes
- A **SCIM API key** (Bearer token) for user lookups
- A `config.txt` file (see below)

## Setup

Create a `config.txt` next to the script (copy from `config.template.txt`):

```
SiteURL=https://yourcompany.promapp.com
Username=your.email@company.com
Password=YourPasswordHere

# Required for this script — resolves usernames to numeric user IDs
ScimApiKey=YourScimApiKeyHere

# Optional — defaults to https://api.promapp.com/api/scim
ScimBaseUrl=https://api.promapp.com/api/scim
```

- `SiteURL` / `Username` / `Password` are used to get an OAuth token for
  reading and saving processes.
- `ScimApiKey` is a **separate** credential used only for the SCIM user lookups.
- `ScimBaseUrl` is optional; override it only if your tenant uses a different
  regional SCIM host.

> **Never commit `config.txt` to version control.** It is already covered by
> `.gitignore` in this repository.

## Process ID file

Provide a file containing the processes to update. Two formats are accepted:

**Plain text** (one ID per line; `#` comments and blank lines ignored):

```
# see Examples/process-ids-example.txt
1234
1235
1236
```

**CSV** with a recognized ID column (`ProcessID`, `ProcessId`, `Process ID`,
`ProcessUniqueId`, `Id`, or `ID`):

```csv
ProcessID
1234
1235
```

IDs may be numeric process IDs or process `UniqueId` GUIDs.

## Usage

Run interactively (prompts for the file, owner, and expert):

```powershell
.\Update-ProcessOwnership.ps1
```

Provide everything up front:

```powershell
.\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -NewOwner jonathan@palouse.io -NewExpert jane@palouse.io
```

Update only the owner (leave expert unchanged):

```powershell
.\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -NewOwner jonathan@palouse.io
```

### Clearing a role (unassigning)

Nintex uses a built-in placeholder user, **"Needs to be reassigned N/A"**
(user Id `2`), when a role has no real assignee. To set the owner or expert to
that placeholder, pass any of these keywords (case-insensitive):
`unassigned`, `unassign`, `none`, `n/a`, `na`.

```powershell
.\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -NewOwner unassigned
```

### Preview before changing anything (recommended)

`-WhatIf` shows exactly what would change for each process — current owner/expert
(name + id) → new — without saving:

```powershell
.\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -NewOwner jonathan@palouse.io -WhatIf
```

## Parameters

| Parameter        | Description                                                                 |
|------------------|-----------------------------------------------------------------------------|
| `-ConfigPath`    | Path to the config file. Default: `config.txt`.                             |
| `-ProcessIdFile` | Path to the file of Process IDs. Prompted if omitted.                       |
| `-NewOwner`      | Username (or numeric user Id) of the new owner, or an unassign keyword. Prompted if both roles omitted. |
| `-NewExpert`     | Username (or numeric user Id) of the new expert, or an unassign keyword. Prompted if both roles omitted. |
| `-WhatIf`        | Preview only — make no changes.                                             |

## Output

A timestamped CSV is written to the current directory:

- `UpdateOwnership_Results_YYYYMMDD_HHMMSS.csv` (live run)
- `UpdateOwnership_Preview_YYYYMMDD_HHMMSS.csv` (`-WhatIf` run)

Columns: `ProcessID`, `ProcessName`, `Status` (Success / Failed / Preview),
`Message`, `ActionUrl`.

## Notes

- The same new owner/expert is applied to **every** process in the list. To set
  different values per process, run the script once per group of processes.
- If a username cannot be resolved via SCIM, the script aborts before making
  any changes (an owner/expert cannot be set without a valid numeric user Id).
- The save sends the full process definition back to the API
  (`ProcessJson` as an escaped string, per `API_ARCHITECTURE.md`). It updates
  the process's working revision; if your tenant requires a separate publish
  step for the change to take effect, publish those processes as you normally
  would.
