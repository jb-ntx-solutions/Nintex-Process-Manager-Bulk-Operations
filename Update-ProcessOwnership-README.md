# Update Process Ownership (Standalone)

`Update-ProcessOwnership.ps1` is a self-contained PowerShell script for bulk
updating the **Owner** and/or **Expert** on Nintex Process Manager (Promapp)
processes, one process per CSV row. It was extracted from "Mode 4" of the
larger `Nintex-BulkOperations.ps1` tool so it can be shared on its own.

It is fully standalone — it has no dependency on `Nintex-BulkOperations.ps1`.
You only need this script plus a `config.txt` and a CSV.

## What it does

1. Reads a CSV with one row per process (`ProcessID`, `NewOwner`, `NewExpert`).
2. Resolves each distinct username to a numeric **user Id** and display **name**
   via the **SCIM API** (looked up once and cached).
3. For each row: fetches the process definition, sets `OwnerId`/`Owner` and/or
   `ExpertId`/`Expert` in the definition, and saves the process.
4. Writes a timestamped results CSV.

## CSV format

| Column      | Accepted names                                         | Meaning                                  |
|-------------|--------------------------------------------------------|------------------------------------------|
| Process ID  | `ProcessID`, `ProcessId`, `Process ID`, `ProcessUniqueId`, `Id`, `ID` | The process **UniqueId (GUID)** to update |
| New owner   | `NewOwner`, `Owner`, `OwnerUsername`, `ProcessOwner`   | Username of the new owner                |
| New expert  | `NewExpert`, `Expert`, `ExpertUsername`, `ProcessExpert` | Username of the new expert             |

> **Process ID must be the process `UniqueId` (GUID)** — the value in a process
> URL (`.../Process/View/{guid}`), not the short numeric Id. The
> `/Api/v1/Processes/{id}` endpoint addresses processes by their GUID. The
> script warns if it sees non-GUID values.

```csv
ProcessID,NewOwner,NewExpert
9b55b171-4e9e-4a4a-acc3-093327047153,jonathan@palouse.io,jane@palouse.io
b8631d0f-b7f8-44bb-80ed-f89886551c42,,jane@palouse.io
f5698de9-1956-4095-9d6f-edaf6e28f022,jonathan@palouse.io,
a1b2c3d4-e5f6-7890-abcd-ef1234567890,unassigned,jane@palouse.io
c2a29d7b-1b61-4784-9524-7b5583db084c,jonathan@palouse.io,N/A
```

Per-cell rules:

- **Blank cell** → leave that role **unchanged**.
- **A username** (e.g. `jonathan@palouse.io`) → resolved via SCIM and set.
- **An unassign keyword** (`unassigned`, `unassign`, `none`, `n/a`, `na`,
  case-insensitive) → set the role to the built-in **"Needs to be reassigned
  N/A"** placeholder (user Id `2`).

See `Examples/update-ownership-example.csv`.

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

## Usage

Run interactively (prompts for the CSV path):

```powershell
.\Update-ProcessOwnership.ps1
```

Provide the CSV up front:

```powershell
.\Update-ProcessOwnership.ps1 -CsvPath .\update-ownership.csv
```

### Preview before changing anything (recommended)

`-WhatIf` shows exactly what would change for each row — current owner/expert
(name + id) → new — without saving:

```powershell
.\Update-ProcessOwnership.ps1 -CsvPath .\update-ownership.csv -WhatIf
```

## Parameters

| Parameter        | Description                                             |
|------------------|---------------------------------------------------------|
| `-ConfigPath`    | Path to the config file. Default: `config.txt`.        |
| `-CsvPath`       | Path to the CSV. Prompted if omitted.                  |
| `-WhatIf`        | Preview only — make no changes.                        |
| `-DelaySeconds`  | Seconds to wait between processes that contact the server. Default: `1`. Increase if you still see intermittent `500` errors; set to `0` to disable. |
| `-MaxRetries`    | Times to retry a request that fails with a transient error (HTTP 5xx or a network error), using exponential backoff (2s, 4s, 8s, …). Default: `3`; set to `0` to disable retries. |
| `-NoPause`       | Skip the "Press Enter to close" prompt at the end.     |

## Output

A timestamped CSV is written to the current directory:

- `UpdateOwnership_Results_YYYYMMDD_HHMMSS.csv` (live run)
- `UpdateOwnership_Preview_YYYYMMDD_HHMMSS.csv` (`-WhatIf` run)

Columns: `ProcessID`, `ProcessName`, `Status` (Success / Failed / Skipped /
Preview), `Message`, `ActionUrl`.

## Notes

- Each distinct username is resolved via SCIM **once** before processing and
  cached, so a large CSV with repeated owners/experts makes minimal SCIM calls.
- If a username cannot be resolved via SCIM, you are warned up front. Rows that
  reference an unresolved username are **skipped** (that role cannot be set
  without a valid numeric user Id); other rows still process.
- The save sends the full process definition back to the API
  (`ProcessJson` as an escaped string, per `API_ARCHITECTURE.md`). It updates
  the process's working revision; if your tenant requires a separate publish
  step for the change to take effect, publish those processes as you normally
  would.
