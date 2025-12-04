# Nintex Process Manager Bulk Operations

A comprehensive PowerShell script for performing bulk operations on Nintex Process Manager (Promapp) processes and documents.

## Features

This script supports five distinct operation modes:

1. **Bulk Archive** - Archive processes/documents from CSV or group selection
2. **Bulk Restore** - Restore archived items to a specified group
3. **Bulk Update Location** - Move processes/documents to different groups
4. **Bulk Update Ownership** - Update process owners and experts
5. **Bulk Delete Processes** - Safely delete processes with reference detection and removal

## Requirements

- PowerShell 5.1 or later
- Nintex Process Manager (Promapp) account with appropriate permissions
- Internet connectivity to access your Nintex PM site

## Setup

### 1. Download the Script

Clone or download this repository to your local machine.

### 2. Create Configuration File

Copy `config.template.txt` to `config.txt` and fill in your details:

```
SiteURL=https://yourcompany.promapp.com
Username=your.email@company.com
Password=YourPasswordHere
DefaultRestoreGroupID=123
TempGroupName=Bulk Delete Temporary Group
```

**IMPORTANT:** Add `config.txt` to your `.gitignore` file to prevent committing credentials to version control.

### 3. Prepare CSV Files (if needed)

Depending on your operation, you may need CSV files with specific columns. See the Examples folder for templates.

## Usage

### Running the Script

Open PowerShell and navigate to the script directory:

```powershell
cd path\to\Nintex-Process-Manager-Bulk-Operations
.\Nintex-BulkOperations.ps1
```

The script will:
1. Load your configuration from `config.txt`
2. Authenticate to your Nintex PM site
3. Present a menu of operation modes
4. Guide you through the selected operation

### Operation Modes

#### Mode 1: Bulk Archive

Archives processes or documents based on a CSV file or group selection.

**CSV Format:**
- Required column: `ProcessID` (or `ProcessId`, `Process ID`, `Id`)

**Options:**
- Source: CSV file or Process/Document Group
- Object Type: Processes, Documents, or Both
- Include Subgroups: Yes/No (for group-based operations)

**Example:**
```
Select Mode: 1
Select Source: 1 (CSV)
Select Object Type: 1 (Processes)
Enter CSV file path: archive-list.csv
```

#### Mode 2: Bulk Restore

Restores archived processes or documents to a specified target group.

**CSV Format:**
- Required column: `ProcessID` (or similar)

**Options:**
- Source: CSV file or All Archived Items
- Object Type: Processes, Documents, or Both
- Target Group: Specify the group ID to restore items to

**Example:**
```
Select Mode: 2
Select Source: 2 (All Archived)
Select Object Type: 1 (Processes)
Select Target Group for Restore: 456
```

#### Mode 3: Bulk Update Location

Moves processes or documents to new groups based on a CSV mapping.

**CSV Format:**
- Required columns:
  - `ProcessID` (or similar) - The ID of the item to move
  - `NewGroupID` (or `TargetGroupID`) - The destination group ID

**Example CSV:**
```csv
ProcessID,NewGroupID
1234,456
1235,457
1236,456
```

**Example:**
```
Select Mode: 3
Select Object Type: 1 (Processes)
Enter CSV file path: update-locations.csv
```

#### Mode 4: Bulk Update Ownership

Updates process owners and experts based on a CSV file.

**Note:** Currently supports Processes only.

**CSV Format:**
- Required columns:
  - `ProcessID` - The process to update
  - `NewOwner` - Username of the new owner (optional)
  - `NewExpert` - Username of the new expert (optional)

**Example CSV:**
```csv
ProcessID,NewOwner,NewExpert
1234,john.doe@company.com,jane.smith@company.com
1235,jane.smith@company.com,john.doe@company.com
```

**Example:**
```
Select Mode: 4
Enter CSV file path: update-ownership.csv
```

#### Mode 5: Bulk Delete Processes

**WARNING: This is a DESTRUCTIVE operation that permanently deletes processes.**

This mode performs a comprehensive deletion workflow:

1. Identifies processes to delete (from CSV or group)
2. Creates/uses a temporary holding group
3. Restores all archived processes temporarily
4. Scans entire site for references to processes being deleted
5. Optionally removes references from other processes
6. Updates ownership of target processes to current user
7. Archives target processes
8. Permanently deletes target processes
9. Re-archives previously archived processes
10. Cleanup (temp group should be manually deleted if empty)

**CSV Format:**
- Required column: `ProcessID`

**Safety Features:**
- Multiple confirmation prompts
- Reference detection across all processes
- Staged execution with checkpoints
- Detailed logging

**Example:**
```
Select Mode: 5
Select Source: 1 (CSV)
Enter CSV file path: processes-to-delete.csv
Type 'DELETE' to confirm: DELETE
Enter the ID of a temporary group to use: 999
Include subgroups? (Y/N): N
[Process scans for references...]
Do you want to attempt to remove these references? (Y/N): Y
Ready to archive processes. Continue? (Y/N): Y
Ready to PERMANENTLY DELETE processes. Type 'DELETE' to confirm: DELETE
```

## Output

All operations generate timestamped CSV files with results:

- `Archive_Results_YYYYMMDD_HHMMSS.csv`
- `Restore_Results_YYYYMMDD_HHMMSS.csv`
- `UpdateLocation_Results_YYYYMMDD_HHMMSS.csv`
- `UpdateOwnership_Results_YYYYMMDD_HHMMSS.csv`
- `Delete_Results_YYYYMMDD_HHMMSS.csv`

Each results file contains:
- Object Type (Process/Document)
- Object ID
- Operation performed
- Status (Success/Failed/Skipped)
- Message with details
- Action URL (where applicable)

## CSV Column Name Flexibility

The script accepts various column naming conventions:

**For IDs:**
- `ProcessID`, `ProcessId`, `Process ID`, `ProcessUniqueId`, `Id`, `ID`
- `DocumentID`, `DocumentId` (for documents)

**For Group IDs:**
- `NewGroupID`, `NewGroupId`, `TargetGroupID`, `TargetGroupId`, `GroupID`, `GroupId`

**For Ownership:**
- `NewOwner`, `Owner`, `OwnerUsername`, `ProcessOwner`
- `NewExpert`, `Expert`, `ExpertUsername`, `ProcessExpert`

## Troubleshooting

### Authentication Fails

- Verify your SiteURL, Username, and Password in `config.txt`
- Ensure there are no extra spaces or special characters
- Check that your account has not been locked

### CSV Not Found

- Use absolute paths: `C:\Users\YourName\Documents\file.csv`
- Or relative paths from the script directory: `.\data\file.csv`
- Ensure the file exists and has the correct extension

### Operations Fail

- Check that you have appropriate permissions in Nintex PM
- Verify IDs are correct (Process IDs, Group IDs)
- Review the results CSV for specific error messages
- Some operations may require processes to be in specific states (published, archived, etc.)

### Document Operations Not Working

Document-related features may vary by Nintex PM version. The script includes placeholder implementations that may need adjustment based on your specific API endpoints.

## Best Practices

1. **Test First** - Start with a small CSV of test items before bulk operations
2. **Backup** - Consider exporting processes before bulk delete operations
3. **Review Results** - Always check the results CSV files after operations
4. **Security** - Never commit `config.txt` to version control
5. **Permissions** - Ensure you have necessary permissions for all operations
6. **References** - For delete operations, carefully review reference reports

## API Endpoints Used

The script uses various Nintex Process Manager API endpoints:

- `/oauth2/token` - Authentication
- `/Api/v1/Processes/*` - Process operations
- `/BFF/Api/Processes/All/List` - Process listing
- `/Process/Edit/*` - Archive, restore, delete operations
- `/user/autocomplete.aspx` - User search

## Limitations

- Document operations are partially implemented (varies by Nintex PM version)
- Process group creation for Mode 5 requires manual setup
- Reference removal in Mode 5 is conservative (logs warnings, may need manual review)
- Large-scale operations (1000+ items) may take significant time

## Support

For issues or questions:

1. Check the Troubleshooting section above
2. Review the results CSV for specific error messages
3. Consult Nintex Process Manager documentation
4. Contact your Nintex administrator

## Version History

**Version 1.0** (Initial Release)
- Five operation modes
- Text-based configuration
- Flexible CSV column detection
- Comprehensive error handling
- Detailed results logging

## License

This script is provided as-is without warranty. Test thoroughly before production use.

## Credits

Based on patterns from the Process Manager Bulk Delete Processes script.
