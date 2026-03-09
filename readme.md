# InviteGuestUsers

An Azure Function that automatically invites external guest users to your Microsoft Entra ID tenant. Drop a text file containing email addresses into a blob storage container and the function handles the rest.

## How it works

1. A `.txt` file is uploaded to the `guest-imports` container in Azure Blob Storage
2. The function triggers, reads the file, and parses one email address per line
3. For each email, it sends a guest invitation via the Microsoft Graph API
4. The invited user's display name, first name, last name, and company are set automatically based on their email address
5. Optionally assigns a sponsor to the guest user

Email addresses are expected to follow the `firstname.lastname@domain.com` format for name parsing.

## App Settings

| Setting | Description |
|---|---|
| `AzureWebJobsStorage` | Connection string for the Azure Storage account |
| `BLOB_STORAGE_CONNECTION` | Connection string for the storage account containing the `guest-imports` container |
| `GUEST_COMPANY_NAME` | Company name to set on invited guest users |
| `INVITE_REDIRECT_URL` | URL guests are redirected to after accepting their invitation |
| `GUEST_SPONSOR_ID` | (Optional) Object ID of the user to set as sponsor for invited guests |

## Azure Setup

- **Function App** — Consumption plan, PowerShell 7.4, Windows, System Assigned Managed Identity enabled
- **Storage Account** — GPv2, with a container named `guest-imports`
- **IAM — Storage Account** — Managed identity needs Storage Blob Data Contributor, Storage Queue Data Contributor, Storage Table Data Contributor
- **IAM — Entra ID** — Managed identity needs `User.Invite.All`, `User.ReadWrite.All`, and `User-Sponsor.ReadWrite.All` Graph API application permissions

## Input Format

Plain text file, one email address per line:

```
john.smith@contoso.com
jane.doe@contoso.com
```
