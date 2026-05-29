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
   identified by username or non-GUID user ID.
3. Validates each user against the site's user directory.
4. For each process: fetches the process definition, updates the owner/expert
   inside the definition, and saves the process.
5. Writes a timestamped results CSV.

## Requirements

- PowerShell 5.1 or later
- A Nintex Process Manager account with permission to edit the target processes
- A `config.txt` file (see below)

## Setup

Create a `config.txt` next to the script (copy from `config.template.txt`):

```
SiteURL=https://yourcompany.promapp.com
Username=your.email@company.com
Password=YourPasswordHere
```

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
.\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -NewOwner john.doe -NewExpert jane.smith
```

Update only the owner (leave expert unchanged):

```powershell
.\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -NewOwner john.doe
```

### Preview before changing anything (recommended)

`-WhatIf` shows exactly what would change for each process — including which
definition field would be set — without saving:

```powershell
.\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -NewOwner john.doe -WhatIf
```

### Confirm the owner/expert field names for your tenant

The owner and expert are stored in the process definition under
tenant/version-specific property names. The script auto-detects them from a
list of common candidates. If your tenant uses a different name, run with
`-Discover` to print every owner/expert-related field found on the first
process in your file:

```powershell
.\Update-ProcessOwnership.ps1 -ProcessIdFile .\process-ids.txt -Discover
```

If the correct field is not already covered, add its name to the
`$OwnerFieldCandidates` / `$ExpertFieldCandidates` lists near the top of the
script and re-run.

## Parameters

| Parameter        | Description                                                                 |
|------------------|-----------------------------------------------------------------------------|
| `-ConfigPath`    | Path to the config file. Default: `config.txt`.                             |
| `-ProcessIdFile` | Path to the file of Process IDs. Prompted if omitted.                       |
| `-NewOwner`      | Username / non-GUID user ID of the new owner. Prompted if both roles omitted. |
| `-NewExpert`     | Username / non-GUID user ID of the new expert. Prompted if both roles omitted. |
| `-WhatIf`        | Preview only — make no changes.                                             |
| `-Discover`      | Print owner/expert fields found in the first process, then exit.            |

## Output

A timestamped CSV is written to the current directory:

- `UpdateOwnership_Results_YYYYMMDD_HHMMSS.csv` (live run)
- `UpdateOwnership_Preview_YYYYMMDD_HHMMSS.csv` (`-WhatIf` run)

Columns: `ProcessID`, `ProcessName`, `Status` (Success / Failed / Skipped /
Preview), `Message`, `ActionUrl`.

## Notes

- The same new owner/expert is applied to **every** process in the list. To set
  different values per process, run the script once per group of processes.
- The save sends the full process definition back to the API
  (`ProcessJson` as an escaped string, per `API_ARCHITECTURE.md`). It updates
  the process's working revision; if your tenant requires a separate publish
  step for owner/expert changes to take effect, publish those processes as you
  normally would.
- If a process has no detectable owner/expert field, it is reported as
  `Skipped` (run `-Discover` to identify the field name).
