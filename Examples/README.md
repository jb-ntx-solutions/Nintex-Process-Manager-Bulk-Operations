# CSV Examples

This folder contains example CSV files for each operation mode.

## Usage

1. Copy the relevant example file
2. Replace the example data with your actual Process IDs and values
3. Save with a meaningful filename
4. Reference the file path when running the script

## File Descriptions

### archive-example.csv
Template for bulk archive operations.
- **Columns:** ProcessID
- **Used in:** Mode 1 (Bulk Archive)

### restore-example.csv
Template for bulk restore operations.
- **Columns:** ProcessID
- **Used in:** Mode 2 (Bulk Restore)

### update-location-example.csv
Template for moving processes/documents to new groups.
- **Columns:** ProcessID, NewGroupID
- **Used in:** Mode 3 (Bulk Update Location)

### update-ownership-example.csv
Template for updating process ownership.
- **Columns:** ProcessID, NewOwner, NewExpert
- **Used in:** Mode 4 (Bulk Update Ownership)
- **Note:** You can leave NewOwner or NewExpert blank if you only want to update one field

### delete-example.csv
Template for bulk delete operations.
- **Columns:** ProcessID
- **Used in:** Mode 5 (Bulk Delete Processes)
- **WARNING:** This is a destructive operation!

## Column Name Variations

The script accepts multiple column name variations. You can use any of these:

**For Process IDs:**
- ProcessID
- ProcessId
- Process ID
- ProcessUniqueId
- Id
- ID

**For Group IDs:**
- NewGroupID
- NewGroupId
- TargetGroupID
- TargetGroupId
- GroupID
- GroupId

**For Ownership:**
- NewOwner / Owner / OwnerUsername / ProcessOwner
- NewExpert / Expert / ExpertUsername / ProcessExpert

## Tips

1. **Excel Users:** Save as "CSV (Comma delimited) (*.csv)" not Excel format
2. **IDs Only:** Use only numeric IDs without quotes or extra characters
3. **Usernames:** Use full email addresses for owner/expert fields
4. **Headers:** Keep the header row (first row with column names)
5. **No Empty Rows:** Remove any empty rows from your CSV
6. **Testing:** Start with a small CSV (2-3 items) to test before bulk operations

## Example Data Explained

All example files use fictional IDs:
- Process IDs like 1234, 1235, etc. - Replace with your actual process IDs
- Group IDs like 456, 457, etc. - Replace with your actual group IDs
- Email addresses like john.doe@company.com - Replace with actual usernames

You can find Process IDs and Group IDs from URLs in Nintex Process Manager:
- Process: `https://yoursite.promapp.com/Process/View/1234` (ID is 1234)
- Group: `https://yoursite.promapp.com/ProcessGroup/View/456` (ID is 456)
