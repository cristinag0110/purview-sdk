# Prerrequisitos para un tenant nuevo

Este documento recoge todo lo que un **tenant nuevo** (greenfield) necesita para que el escenario del
Purview SDK (evaluar texto contra una política DLP mediante las Purview APIs de Microsoft Graph)
funcione de extremo a extremo.

> En un tenant que ya usa Microsoft 365 E5 y Purview, muchos de estos puntos ya están hechos "de forma
> invisible". En un entorno limpio hay que prepararlos explícitamente. Los que **más se olvidan** están
> marcados con ⚠️.

## Orden recomendado

Licencias → billing pay-as-you-go → activar Purview (DSPM for AI + Audit) → App Registration
(permisos + consent) → política/regla DLP → usuarios en alcance → configurar `.env` → probar.

---

## 1. Licencias y facturación

| Requisito | Detalle |
|---|---|
| **Microsoft 365 E5** (o equivalente con Purview/Compliance) | Habilita DLP, los *Sensitive Information Types* y DSPM for AI. Necesario para los usuarios implicados. |
| ⚠️ **Billing pay-as-you-go de Purview** | Vinculado a una **suscripción de Azure**. **Obligatorio** para apps enterprise (no-Copilot). Sin él, `processContent` / `protectionScopes` devuelven **`402 Payment Required`**. En un tenant nuevo casi nunca está configurado. |

Para pruebas se puede usar un tenant del **Microsoft 365 Developer Program**, pero el billing
pay-as-you-go sigue siendo necesario para las APIs de data security.

---

## 2. Habilitar Microsoft Purview en el tenant

| Requisito | Detalle |
|---|---|
| **Activar Audit** (Unified Audit Log) | En M365 moderno suele venir activo; conviene confirmarlo. Necesario para la auditoría vía `contentActivities`. |
| ⚠️ **Onboarding de DSPM for AI** | Portal de Purview → *Data Security Posture Management for AI* → completar el "Get started". Activa la ingestión y las políticas de colección para apps enterprise. |

> Nota: estas APIs son de **Microsoft Purview (compliance)**, no del recurso de Azure *Microsoft Purview*
> (data map / catálogo). No hace falta crear una cuenta de Azure Purview para este escenario.

---

## 3. Identidad: App Registration en Microsoft Entra ID

| Paso | Detalle |
|---|---|
| Registrar la aplicación | `az ad app create` |
| Crear secreto (o certificado) | `az ad app credential reset` |
| Crear el service principal | `az ad sp create` |
| Asignar los 3 App Roles de Graph y su **grant** (admin consent) | Vía `appRoleAssignments` (ver la guía paso a paso) |
| Verificar el token | Debe incluir los 3 `roles`; si no, `403 InsufficientGraphPermissions` |

Permisos de aplicación (App Roles) de Microsoft Graph:

| Permiso | App Role ID |
|---|---|
| `Content.Process.User` | `24ceb246-ad29-4680-90b4-3e91ffad15eb` |
| `ContentActivity.Write` | `2932e07a-3c29-44e4-bb36-6d0fc176387f` |
| `ProtectionScopes.Compute.User` | `fe696d63-5e1f-4515-8232-cccc316903c6` |

Procedimiento detallado en [guia-paso-a-paso.md](guia-paso-a-paso.md).

---

## 4. Política DLP para la aplicación

| Requisito | Detalle |
|---|---|
| Crear política + regla por **PowerShell** | `New-DlpCompliancePolicy` + `New-DlpComplianceRule` (el portal **no** soporta DLP para apps Entra enterprise). |
| `EnforcementPlanes = Application` | Plano de enforcement para apps registradas en Entra. |
| `Location = appId` de la App Registration | `LocationType: Individual`, `LocationSource: Entra`. Es lo que hace que la política haga match con la app. |
| Alcance de usuarios (`Inclusions` / `Exclusions`) | Define a qué usuarios aplica (todo el tenant, grupos o usuarios concretos). |
| Al menos una **regla** | Con un SIT (p. ej. `credit card number`) y `RestrictAccess … Block`. |

---

## 5. Usuarios y contexto de prueba

- **Usuarios con licencia E5** que estén **dentro del alcance** (`Inclusions`) de la política.
- Un **object id (GUID)** de usuario válido para pasar a los scripts (las llamadas son `/users/{userId}/...`).
  - Obtenerlo con: `az ad user show --id <UPN> --query id -o tsv`.

---

## 6. Permisos del administrador que realiza el setup

- **Global Admin** (o combinación equivalente): crear App Registrations, **conceder admin consent** y
  crear políticas DLP.
- Rol de **Compliance Administrator / Compliance Data Administrator** para los cmdlets `*-DlpCompliance*`.

---

## 7. Herramientas en la máquina de trabajo

| Herramienta | Uso |
|---|---|
| **Azure CLI** (`az login`) | Registro de app, permisos, resolución de object ids |
| **PowerShell 7** | Ejecución de scripts y cmdlets |
| Módulo **`ExchangeOnlineManagement`** | `Connect-IPPSSession` para los cmdlets DLP |
| **Python 3.12** + `requirements.txt` | Cliente Python (`azure-identity`, `httpx`, `python-dotenv`) |

---

## 8. Configuración del cliente (`.env`)

Rellenar el `.env` con los valores del **nuevo** tenant: `AZURE_TENANT_ID`, `PURVIEW_CLIENT_ID`,
`PURVIEW_CLIENT_SECRET`, `PURVIEW_APP_LOCATION_VALUE` (= `appId`), `PURVIEW_APP_NAME`, `GRAPH_BASE_URL`
y `GRAPH_SCOPE`. El `user_id` **no** se define aquí (es un parámetro por llamada).

---

## Lo que con más probabilidad falla en un tenant nuevo

1. **Pay-as-you-go no configurado** → `402 Payment Required`.
2. **DSPM for AI / Audit sin activar** → sin gobernanza ni auditoría.
3. **Admin consent no efectivo** → `403 InsufficientGraphPermissions`.
4. **Propagación**: tras crear la política, esperar unos minutos antes de probar.

---

## Checklist rápido

- [ ] Usuarios con licencia **Microsoft 365 E5**
- [ ] **Billing pay-as-you-go** de Purview configurado (suscripción de Azure)
- [ ] **Audit** activado
- [ ] **DSPM for AI** onboarding completado
- [ ] App Registration creada (secreto + service principal)
- [ ] 3 App Roles de Graph asignados y con **admin consent**
- [ ] Token verificado (incluye los 3 `roles`)
- [ ] Política DLP creada (`Enable`) con `Location = appId` y alcance de usuarios
- [ ] Regla DLP creada (`Enforce`) con SIT + acción de bloqueo
- [ ] Usuario de prueba (object id) dentro del alcance
- [ ] `.env` configurado con los valores del tenant
- [ ] Política **propagada** (esperar unos minutos) y probada con los scripts
