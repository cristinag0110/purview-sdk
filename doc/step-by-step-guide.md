# Step-by-step guide: app registration, permissions and DLP policy for the Purview SDK

This guide documents, end to end, how the Microsoft Entra ID and Microsoft Purview environment was prepared to evaluate text against a **Data Loss Prevention (DLP)** policy using the **Microsoft Graph Purview APIs** (the so-called "Purview SDK").

> The "Purview SDK" is not an installable library: it is a set of REST calls to Microsoft Graph
> (`protectionScopes/compute`, `processContent`, `contentActivities`) under `/dataSecurityAndGovernance`.
> Everything registered here exists so that those calls work and so that a DLP policy
> knows which rules to apply.

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Reference values](#2-reference-values)
3. [Verify the Azure CLI session](#3-verify-the-azure-cli-session)
4. [Register the application in Entra ID](#4-register-the-application-in-entra-id)
5. [Generate the client secret](#5-generate-the-client-secret)
6. [Add the Microsoft Graph permissions](#6-add-the-microsoft-graph-permissions)
7. [Create the service principal](#7-create-the-service-principal)
8. [Grant the permissions: App Role assignment](#8-grant-the-permissions-app-role-assignment)
9. [Connect to Security & Compliance PowerShell](#9-connect-to-security--compliance-powershell)
10. [Define the Location (and its nuances)](#10-define-the-location-and-its-nuances)
11. [Create the DLP policy and assign the Location](#11-create-the-dlp-policy-and-assign-the-location)
12. [Create the DLP rule within the policy](#12-create-the-dlp-rule-within-the-policy)
13. [Narrow the scope to a set of users](#13-narrow-the-scope-to-a-set-of-users)
14. [Verification and final checklist](#14-verification-and-final-checklist)
15. [Test the Purview SDK with the PowerShell script](#15-test-the-purview-sdk-with-the-scripts)

---

## 1. Prerequisites

| Requirement | Details |
|---|---|
| PowerShell | 7.x (the reference session used 7.6.6) |
| Azure CLI | `az` installed and signed in (`az login`) |
| PowerShell module | `ExchangeOnlineManagement` (provides the `*-DlpCompliance*` cmdlets) |
| Permissions | Global Administrator (or equivalent) to create apps, grant consent and create DLP policies |
| License | Tenant with Microsoft Purview enabled and pay-as-you-go billing (non-Copilot apps) |

Install the module if it is not present:

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
```

---

## 2. Reference values

Replace with the values from your environment. The real identifiers are shown **masked** as
placeholders (`<...>`) for security; replace them with those of your tenant.

| Concept | Example value | Description |
|---|---|---|
| App name | `Demo-Purview-sdk` | Display name in Entra ID |
| `appId` (Client ID) | `<APP_ID>` | Authenticates **and** is the DLP policy Location |
| Registration Object ID | `<APP_OBJECT_ID>` | Object ID of the *application registration* |
| SP Object ID | `<SP_OBJECT_ID>` | The app's service principal |
| Graph API | `00000003-0000-0000-c000-000000000000` | Fixed App ID of Microsoft Graph (same in every tenant) |
| Tenant ID | `<TENANT_ID>` | Directory |
| DLP policy | `DLP-Demo-Purview-SDK` | Policy name |
| DLP rule | `Block Credit Cards Purview SDK` | Rule name |

Microsoft Graph application permissions (App Roles) used:

| Permission | App Role ID | Associated API |
|---|---|---|
| `Content.Process.User` | `24ceb246-ad29-4680-90b4-3e91ffad15eb` | `processContent` |
| `ContentActivity.Write` | `2932e07a-3c29-44e4-bb36-6d0fc176387f` | `contentActivities` |
| `ProtectionScopes.Compute.User` | `fe696d63-5e1f-4515-8232-cccc316903c6` | `protectionScopes/compute` |

> ⚠️ **Never store the client secret in the script, in the repository or in this guide.**
> Use Azure Key Vault or an environment variable (`.env`, which is in `.gitignore`).

---

## 3. Verify the Azure CLI session

Confirm the tenant and subscription before creating anything.

```powershell
az account show
```

Check `tenantId`, `name` and `user.name` in the output.

---

## 4. Register the application in Entra ID

```powershell
az ad app create `
  --display-name "Demo-Purview-sdk" `
  --sign-in-audience AzureADMyOrg `
  --query "{appId: appId, id: id}" -o json
```

It returns two identifiers, both required:

- `appId` → **Client ID** (used in the rest of the commands and as the DLP Location).
- `id` → **Object ID** of the application registration.

---

## 5. Generate the client secret

```powershell
az ad app credential reset `
  --id <APP_ID> `
  --display-name "Purview SDK Secret" `
  --years 2
```

The output includes `appId`, `password` and `tenant`. **Copy `password` right away: it cannot be retrieved later.** Store it in Key Vault or in the local `.env` (never in git).

---

## 6. Add the Microsoft Graph permissions

The three App Roles are added, one per command. The `=Role` suffix indicates an **application** permission (not delegated).

```powershell
$appId    = "<APP_ID>"
$graphApi = "00000003-0000-0000-c000-000000000000"

# Content.Process.User
az ad app permission add --id $appId --api $graphApi `
  --api-permissions "24ceb246-ad29-4680-90b4-3e91ffad15eb=Role"

# ContentActivity.Write
az ad app permission add --id $appId --api $graphApi `
  --api-permissions "2932e07a-3c29-44e4-bb36-6d0fc176387f=Role"

# ProtectionScopes.Compute.User
az ad app permission add --id $appId --api $graphApi `
  --api-permissions "fe696d63-5e1f-4515-8232-cccc316903c6=Role"
```

Each command warns that the permissions are **added but not effective** until consent is granted (step 8).

---

## 7. Create the service principal

The application registration needs its service principal in the tenant in order to receive role assignments.

```powershell
az ad sp create --id <APP_ID>
```

In the output you will see `appDisplayName`, `servicePrincipalType: Application` and `signInAudience: AzureADMyOrg`.
Note down the `id` (SP Object ID): it is used in step 8.

---

## 8. Grant the permissions: App Role assignment

`az ad app permission grant` is intended for **delegated** permissions (it requires `--scope`) and **does not work** for application App Roles. The correct approach is to create the role assignments directly against Microsoft Graph.

```powershell
# Object IDs of the service principals involved
$purviewSpId = az ad sp show --id <APP_ID> --query id -o tsv
$graphSpId   = az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv

$roles = @(
  @{ name = "Content.Process.User";          id = "24ceb246-ad29-4680-90b4-3e91ffad15eb" },
  @{ name = "ContentActivity.Write";         id = "2932e07a-3c29-44e4-bb36-6d0fc176387f" },
  @{ name = "ProtectionScopes.Compute.User"; id = "fe696d63-5e1f-4515-8232-cccc316903c6" }
)

foreach ($role in $roles) {
  $body = @{ principalId = $purviewSpId; resourceId = $graphSpId; appRoleId = $role.id } |
          ConvertTo-Json -Compress
  $body | Out-File "$env:TEMP\role.json" -Encoding utf8NoBOM

  az rest --method POST `
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$purviewSpId/appRoleAssignments" `
    --body "@$env:TEMP\role.json" `
    --headers "Content-Type=application/json" `
    --query "appRoleId" -o tsv

  Write-Host "OK $($role.name) assigned"
}
```

- Creating the assignment (`appRoleAssignments`) is equivalent to an **effective admin consent**: the portal's "Grant admin consent" button is not needed.
- The temporary `role.json` file must be written as **utf8NoBOM**; with a BOM, Graph rejects the body.

Verify that the token includes the roles:

```powershell
$tenant = "<TENANT_ID>"
$appId  = "<APP_ID>"
# Replace <SECRET> with the secret from step 5 (do not leave it written to disk).
python -c "
from azure.identity import ClientSecretCredential
import json, base64
cred = ClientSecretCredential('$tenant', '$appId', '<SECRET>')
tok = cred.get_token('https://graph.microsoft.com/.default').token
p = tok.split('.')[1]; p += '=' * (4 - len(p) % 4)
print('roles:', json.loads(base64.b64decode(p)).get('roles', []))
"
```

Expected result:

```
roles: ['Content.Process.User', 'ProtectionScopes.Compute.User', 'ContentActivity.Write']
```

---

## 9. Connect to Security & Compliance PowerShell

The `*-DlpCompliance*` cmdlets do **not** appear with `Import-Module` alone: they are generated when the session is opened.

```powershell
Import-Module ExchangeOnlineManagement
Connect-IPPSSession -UserPrincipalName <ADMIN_UPN>
```

Verification:

```powershell
Get-Command New-DlpCompliancePolicy
```

It should return a function from the temporary `tmpEXO_*` module.

---

## 10. Define the Location (and its nuances)

The **Location** connects the DLP policy to **your Entra application** and defines **which users** it applies to. It is built as a JSON string.

### Location object fields

| Field | Value | Meaning |
|---|---|---|
| `Workload` | `"Applications"` | Enforcement plane for enterprise apps |
| `Location` | `"<appId>"` | **The `appId` of your App Registration** (the same one the client sends as `applicationLocation`/`PurviewAppLocation`). This is what guarantees the match. Do **not** use any other ID. |
| `LocationDisplayName` | `"Demo-Purview-sdk"` | Readable name |
| `LocationSource` | `"Entra"` | The location comes from Entra ID |
| `LocationType` | `"Individual"` | Applies to ONE specific app, not the whole tenant |
| `Inclusions` | array | **Which users it applies to** (see nuances below) |
| `Exclusions` | array (optional) | Users/groups to exclude |

### User scope nuances (`Inclusions` / `Exclusions`)

| Scope | Syntax | How it is identified |
|---|---|---|
| A **user** | `{"Type":"IndividualResource","Identity":"<email/UPN>"}` | Email (UPN) |
| A **group** | `{"Type":"Group","Identity":"<ObjectId>"}` | The group's **ObjectId (GUID)**, **not** its email |
| **Entire tenant** | `{"Type":"Tenant","Identity":"All"}` | — |

Important nuances:

- **Users = email; groups = GUID.** Mixing them up is a common mistake.
- For the `Applications` workload, `Inclusions: Tenant/All` **is** allowed **together with** `Exclusions` (unlike Exchange/OneDrive, where they cannot be combined).
- The scope defines **who is subject** to evaluation. It must be consistent with the `user_id` the client passes to `processContent`: if that user is not in scope, `protectionScopes/compute` will not return the policy and **there will be no match**.

### Example used (all users in the tenant)

```powershell
$myEntraAppId   = "<APP_ID>"
$myEntraAppName = "Demo-Purview-sdk"

$locations = "[{`"Workload`":`"Applications`",`"Location`":`"$myEntraAppId`",`"LocationDisplayName`":`"$myEntraAppName`",`"LocationSource`":`"Entra`",`"LocationType`":`"Individual`",`"Inclusions`":[{`"Type`":`"Tenant`",`"Identity`":`"All`"}]}]"
```

---

## 11. Create the DLP policy and assign the Location

The Location from step 10 is passed in `-Locations`, and the application plane in `-EnforcementPlanes`.

```powershell
New-DlpCompliancePolicy -Name "DLP-Demo-Purview-SDK" `
  -Mode Enable `
  -Locations $locations `
  -EnforcementPlanes @("Application")
```

- `-Mode Enable`: the policy is active.
- `-EnforcementPlanes @("Application")`: for enterprise apps registered in Entra (the `Application` value replaces the old `Entra` value, now deprecated).

Expected output: the `DLP-Demo-Purview-SDK` policy with `Mode: Enable`.

---

## 12. Create the DLP rule within the policy

The policy is the container; the **rule** defines **what** is detected and **what action** is taken. Example: block the upload of text containing credit card numbers.

```powershell
New-DlpComplianceRule -Name "Block Credit Cards Purview SDK" `
  -Policy "DLP-Demo-Purview-SDK" `
  -ContentContainsSensitiveInformation @{Name = "credit card number"} `
  -RestrictAccess @(@{setting="UploadText";value="Block"}) `
  -GenerateAlert $true `
  -GenerateIncidentReport @("siteadmin") `
  -NotifyUser @("<ADMIN_UPN>")
```

Key points of the rule:

- `-ContentContainsSensitiveInformation` → the **Sensitive Information Type (SIT)** that triggers the rule.
- `-RestrictAccess @(@{setting="UploadText";value="Block"})` → the action: **block** `uploadText`. This is what, when calling `processContent`, translates into a `policyActions` with `restrictAccess/block` (= **match**).
- `-GenerateAlert` / `-GenerateIncidentReport` / `-NotifyUser` → alerts and notifications.

The rule is created in `Mode: Enforce` and its `Workload` includes `Applications`.

---

## 13. Narrow the scope to a set of users

To limit the existing policy to specific users or groups, you do **not** need to recreate it: update it with `Set-DlpCompliancePolicy`, passing a new Location.

**Specific users only:**

```powershell
$app  = "<APP_ID>"
$name = "Demo-Purview-sdk"

$loc = "[{`"Workload`":`"Applications`",`"Location`":`"$app`",`"LocationDisplayName`":`"$name`",`"LocationSource`":`"Entra`",`"LocationType`":`"Individual`",`"Inclusions`":[{`"Type`":`"IndividualResource`",`"Identity`":`"user1@<TENANT_DOMAIN>`"},{`"Type`":`"IndividualResource`",`"Identity`":`"user2@<TENANT_DOMAIN>`"}]}]"

Set-DlpCompliancePolicy -Identity "DLP-Demo-Purview-SDK" -Locations $loc
```

**A security group** (recommended, easier to maintain; the group is identified by its ObjectId):

```powershell
# az ad group show --group "Group name" --query id -o tsv
$loc = "[{`"Workload`":`"Applications`",`"Location`":`"$app`",`"LocationDisplayName`":`"$name`",`"LocationSource`":`"Entra`",`"LocationType`":`"Individual`",`"Inclusions`":[{`"Type`":`"Group`",`"Identity`":`"<GROUP_OBJECT_ID>`"}]}]"

Set-DlpCompliancePolicy -Identity "DLP-Demo-Purview-SDK" -Locations $loc
```

**Everyone except one group** (tenant `Inclusions` + `Exclusions`):

```powershell
$loc = "[{`"Workload`":`"Applications`",`"Location`":`"$app`",`"LocationDisplayName`":`"$name`",`"LocationSource`":`"Entra`",`"LocationType`":`"Individual`",`"Inclusions`":[{`"Type`":`"Tenant`",`"Identity`":`"All`"}],`"Exclusions`":[{`"Type`":`"Group`",`"Identity`":`"<GROUP_OBJECT_ID>`"}]}]"

Set-DlpCompliancePolicy -Identity "DLP-Demo-Purview-SDK" -Locations $loc
```

---

## 14. Verification and final checklist

### Check that the DLP policy has been deployed

```powershell
# 1. Connect to Security & Compliance (if you do not have an active session)
Connect-IPPSSession -UserPrincipalName <ADMIN_UPN>

# 2. View the DLP policy (status and locations)
Get-DlpCompliancePolicy -Identity "DLP-Demo-Purview-SDK" | Format-List Name,Mode,Enabled,Workload,*Location*

# 3. View the associated rule (what it detects and what action it takes)
Get-DlpComplianceRule -Policy "DLP-Demo-Purview-SDK" | Format-List Name,Mode,Disabled,IsValid,ContentContainsSensitiveInformation
```

What to look for in the output:

- **Policy**: `Mode = Enable` and the Location must show your `appId` (`<APP_ID>`) with `Workload = Applications`.
- **Rule**: `Mode = Enforce`, `Disabled = False`, `IsValid = True`.

> ⏳ **Wait for propagation.** Creating the policy is immediate, but the service takes **a few minutes**
> to propagate it and activate it on the applications plane. During that window, `protectionScopes/compute`
> may not return the policy yet and `processContent` will not match even if the text is sensitive.
> If you have just created it, **wait a few minutes** and run the verification commands again:
> once the policy shows `Mode: Enable` and the rule shows `Mode: Enforce` / `IsValid: True`,
> it is ready to be tested end to end.

Additional checks:

```powershell
# View the raw Location (JSON) to confirm the appId and the user scope
Get-DlpCompliancePolicy -Identity "DLP-Demo-Purview-SDK" | Select-Object -ExpandProperty Locations
```

Checklist:

- [ ] Azure CLI session on the correct tenant (`az account show`)
- [ ] Application registered and `appId` noted down
- [ ] Secret generated and stored securely (Key Vault / `.env`)
- [ ] Three Graph permissions added
- [ ] Service principal created
- [ ] Three App Roles assigned via `az rest` (effective grant)
- [ ] Token verified: includes the three `roles`
- [ ] `Connect-IPPSSession` session established
- [ ] Location defined with the correct `appId` and the desired user scope
- [ ] DLP policy created (`Mode: Enable`) with the Location assigned
- [ ] DLP rule created (`Mode: Enforce`) with its SIT and block action
- [ ] (Optional) Scope narrowed to users/groups with `Set-DlpCompliancePolicy`
- [ ] End-to-end test with sample sensitive content

---

## 15. Test the Purview SDK with the scripts

Once the policy has been created and **propagated** (see the propagation note in step 14), you can
test the evaluation end to end with **either of the two included scripts**, which
implement the same logic:

- PowerShell: [`scripts/Invoke-PurviewDlpTest.ps1`](../scripts/Invoke-PurviewDlpTest.ps1)
- Python: [`scripts/invoke_purview_dlp_test.py`](../scripts/invoke_purview_dlp_test.py)

Both:

1. Read the configuration from the `.env` at the repository root.
2. Authenticate with client credentials (the App Registration).
3. Take the user as an **object id** (GUID) and, optionally, the **path to the samples file**.
4. Call `protectionScopes/compute` **once** and cache the `ETag`.
5. Send each sample from `data/muestras.txt` to `processContent` and report whether it is a **match**.

Both parameters (user and samples file) can be passed on invocation **or** you can let the
script prompt for them interactively.

### Prerequisites

- The `.env` file filled in (see the README) with `AZURE_TENANT_ID`, `PURVIEW_CLIENT_ID`,
  `PURVIEW_CLIENT_SECRET`, `PURVIEW_APP_LOCATION_VALUE`, `PURVIEW_APP_NAME`, `GRAPH_BASE_URL` and `GRAPH_SCOPE`.
- The DLP policy created, in `Mode: Enable`, with the rule in `Mode: Enforce`, and **already propagated**.
- Pay-as-you-go billing active on the tenant (otherwise the calls return `402 Payment Required`).

### Running

The user must be specified as an **object id** (GUID). If you only have the UPN, get its object id with:

```powershell
az ad user show --id <UPN> --query id -o tsv
```

#### PowerShell

```powershell
# From the repository root.

# a) Specifying the user by object id (GUID):
./scripts/Invoke-PurviewDlpTest.ps1 -User 11111111-2222-3333-4444-555555555555

# b) Also specifying a specific samples file:
./scripts/Invoke-PurviewDlpTest.ps1 -User 11111111-2222-3333-4444-555555555555 -SamplesFile data/muestras.txt

# c) No parameters: the script prompts for the samples file and the user at runtime.
./scripts/Invoke-PurviewDlpTest.ps1
```

#### Python

```powershell
# Use the repository's virtual environment interpreter.

# a) Specifying the user by object id (GUID):
.\.venv\Scripts\python.exe .\scripts\invoke_purview_dlp_test.py --user 11111111-2222-3333-4444-555555555555

# b) Also specifying a specific samples file:
.\.venv\Scripts\python.exe .\scripts\invoke_purview_dlp_test.py --user 11111111-2222-3333-4444-555555555555 --samples-file data/muestras.txt

# c) No parameters: the script prompts for the samples file and the user at runtime.
.\.venv\Scripts\python.exe .\scripts\invoke_purview_dlp_test.py
```

> **Object id (GUID)**: the API expects the object id in the `/users/{userId}/...` path. Neither of the
> two scripts resolves UPNs; pass the GUID directly (use the `az ad user show` command above if
> you only have the UPN).

### Interpreting the output

The script prints one line per sample with the verdict and a final summary:

```
[ 1] MATCH (block) | Mi numero de tarjeta de credito es 4111 1111 1111 1111, guar...
[ 7] NO MATCH      | Resume el informe trimestral de ventas de la region EMEA.

===== Resumen =====
Total: 12  |  MATCH: 6  |  NO MATCH: 6  |  ERRORES: 0
```

- **MATCH (block)**: `processContent` returned `policyActions` with `restrictAccess/block` → DLP
  would block that content (the samples with a card number in Block 1).
- **NO MATCH**: empty `policyActions` → it does not trigger the rule (the benign samples in Block 2), but
  they remain auditable via `contentActivities`.
- **ERROR 402**: pay-as-you-go billing is missing on the tenant.

### If you don't see a match

- Confirm that the policy has **propagated** (repeat the checks from step 14; it may take
  a few minutes after creating it).
- Check that `protection scopes devueltos` is greater than 0 in the output. If it is 0, no policy
  applies to that user+app: check that `PURVIEW_APP_LOCATION_VALUE` in the `.env` matches the
  policy's `Location` and that the user is within the policy's **scope** (`Inclusions`).

---

## Common errors and solutions

| Error | Cause | Solution |
|---|---|---|
| `az ad app permission grant: the following arguments are required: --scope` | The command expects **delegated** permissions, not App Roles | Use `az rest` with `appRoleAssignments` (step 8) |
| `New-DlpCompliancePolicy: The term ... is not recognized` | No Security & Compliance session is open | Run `Connect-IPPSSession` (step 9) |
| `Get-Command New-DlpCompliancePolicy` returns nothing after `Import-Module` | The cmdlets are generated on connect, not on import | Connect first, verify afterwards |
| Permissions added but the app gets `403` | The grant (App Role assignment) is missing | Complete step 8 and request the token again |
| Graph rejects the `az rest` body | JSON file saved with a BOM | Write with `-Encoding utf8NoBOM` |
| The policy never matches | The Location points to a different `appId`, or the user is not in scope | Use the correct `appId` in `Location` and align the scope with the `user_id` of `processContent` |
