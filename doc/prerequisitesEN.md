# Prerequisites for a new tenant

This document lists everything a **new tenant** (greenfield) needs for the
Purview SDK scenario (evaluating text against a DLP policy through the Microsoft Graph Purview APIs)
to work end to end.

> In a tenant that already uses Microsoft 365 E5 and Purview, many of these items are already done "invisibly".
> In a clean environment they must be prepared explicitly. The ones **most often forgotten** are
> marked with ⚠️.

## Recommended order

Licenses → pay-as-you-go billing → enable Purview (DSPM for AI + Audit) → App Registration
(permissions + consent) → DLP policy/rule → users in scope → configure `.env` → test.

---

## 1. Licensing and billing

| Requirement | Details |
|---|---|
| **Microsoft 365 E5** (or equivalent with Purview/Compliance) | Enables DLP, *Sensitive Information Types* and DSPM for AI. Required for the users involved. |
| ⚠️ **Purview pay-as-you-go billing** | Linked to an **Azure subscription**. **Mandatory** for enterprise (non-Copilot) apps. Without it, `processContent` / `protectionScopes` return **`402 Payment Required`**. In a new tenant it is almost never configured. |

For testing, a **Microsoft 365 Developer Program** tenant can be used, but pay-as-you-go
billing is still required for the data security APIs.

---

## 2. Enable Microsoft Purview in the tenant

| Requirement | Details |
|---|---|
| **Enable Audit** (Unified Audit Log) | In modern M365 it is usually on by default; it is worth confirming. Required for auditing via `contentActivities`. |
| ⚠️ **DSPM for AI onboarding** | Purview portal → *Data Security Posture Management for AI* → complete "Get started". Enables ingestion and collection policies for enterprise apps. |

> Note: these APIs belong to **Microsoft Purview (compliance)**, not to the Azure *Microsoft Purview* resource
> (data map / catalog). There is no need to create an Azure Purview account for this scenario.

---

## 3. Identity: App Registration in Microsoft Entra ID

| Step | Details |
|---|---|
| Register the application | `az ad app create` |
| Create a secret (or certificate) | `az ad app credential reset` |
| Create the service principal | `az ad sp create` |
| Assign the 3 Graph App Roles and their **grant** (admin consent) | Via `appRoleAssignments` (see the step-by-step guide) |
| Verify the token | It must include the 3 `roles`; otherwise `403 InsufficientGraphPermissions` |

Microsoft Graph application permissions (App Roles):

| Permission | App Role ID |
|---|---|
| `Content.Process.User` | `24ceb246-ad29-4680-90b4-3e91ffad15eb` |
| `ContentActivity.Write` | `2932e07a-3c29-44e4-bb36-6d0fc176387f` |
| `ProtectionScopes.Compute.User` | `fe696d63-5e1f-4515-8232-cccc316903c6` |

Detailed procedure in [guia-paso-a-paso.md](guia-paso-a-paso.md).

---

## 4. DLP policy for the application

| Requirement | Details |
|---|---|
| Create policy + rule via **PowerShell** | `New-DlpCompliancePolicy` + `New-DlpComplianceRule` (the portal does **not** support DLP for Entra enterprise apps). |
| `EnforcementPlanes = Application` | Enforcement plane for apps registered in Entra. |
| `Location = appId` of the App Registration | `LocationType: Individual`, `LocationSource: Entra`. This is what makes the policy match the app. |
| User scope (`Inclusions` / `Exclusions`) | Defines which users it applies to (entire tenant, groups or specific users). |
| At least one **rule** | With a SIT (e.g. `credit card number`) and `RestrictAccess … Block`. |

---

## 5. Users and test context

- **E5-licensed users** who are **within the scope** (`Inclusions`) of the policy.
- A valid user **object id (GUID)** to pass to the scripts (the calls are `/users/{userId}/...`).
  - Get it with: `az ad user show --id <UPN> --query id -o tsv`.

---

## 6. Permissions of the administrator performing the setup

- **Global Admin** (or an equivalent combination): create App Registrations, **grant admin consent** and
  create DLP policies.
- **Compliance Administrator / Compliance Data Administrator** role for the `*-DlpCompliance*` cmdlets.

---

## 7. Tools on the workstation

| Tool | Use |
|---|---|
| **Azure CLI** (`az login`) | App registration, permissions, resolving object ids |
| **PowerShell 7** | Running scripts and cmdlets |
| **`ExchangeOnlineManagement`** module | `Connect-IPPSSession` for the DLP cmdlets |
| **Python 3.12** + `requirements.txt` | Python client (`azure-identity`, `httpx`, `python-dotenv`) |

---

## 8. Client configuration (`.env`)

Fill in the `.env` with the values from the **new** tenant: `AZURE_TENANT_ID`, `PURVIEW_CLIENT_ID`,
`PURVIEW_CLIENT_SECRET`, `PURVIEW_APP_LOCATION_VALUE` (= `appId`), `PURVIEW_APP_NAME`, `GRAPH_BASE_URL`
and `GRAPH_SCOPE`. The `user_id` is **not** defined here (it is a per-call parameter).

---

## What is most likely to fail in a new tenant

1. **Pay-as-you-go not configured** → `402 Payment Required`.
2. **DSPM for AI / Audit not enabled** → no governance or auditing.
3. **Admin consent not effective** → `403 InsufficientGraphPermissions`.
4. **Propagation**: after creating the policy, wait a few minutes before testing.

---

## Quick checklist

- [ ] Users with a **Microsoft 365 E5** license
- [ ] Purview **pay-as-you-go billing** configured (Azure subscription)
- [ ] **Audit** enabled
- [ ] **DSPM for AI** onboarding completed
- [ ] App Registration created (secret + service principal)
- [ ] 3 Graph App Roles assigned with **admin consent**
- [ ] Token verified (includes the 3 `roles`)
- [ ] DLP policy created (`Enable`) with `Location = appId` and user scope
- [ ] DLP rule created (`Enforce`) with SIT + block action
- [ ] Test user (object id) within scope
- [ ] `.env` configured with the tenant values
- [ ] Policy **propagated** (wait a few minutes) and tested with the scripts
