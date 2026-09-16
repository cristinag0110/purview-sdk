# Guía paso a paso: registro de aplicación, permisos y política DLP para el Purview SDK

Esta guía documenta, de principio a fin, cómo se preparó el entorno de Microsoft Entra ID y Microsoft Purview para poder evaluar texto contra una política de **Data Loss Prevention (DLP)** usando las **Purview APIs de Microsoft Graph** (el mal llamado "Purview SDK").

> El "Purview SDK" no es una librería instalable: es un conjunto de llamadas REST a Microsoft Graph
> (`protectionScopes/compute`, `processContent`, `contentActivities`) bajo `/dataSecurityAndGovernance`.
> Todo lo que se registra aquí existe para que esas llamadas funcionen y para que una política DLP
> sepa qué reglas aplicar.

## Índice

1. [Requisitos previos](#1-requisitos-previos)
2. [Valores de referencia](#2-valores-de-referencia)
3. [Verificar la sesión de Azure CLI](#3-verificar-la-sesión-de-azure-cli)
4. [Registrar la aplicación en Entra ID](#4-registrar-la-aplicación-en-entra-id)
5. [Generar el secreto de cliente](#5-generar-el-secreto-de-cliente)
6. [Añadir los permisos de Microsoft Graph](#6-añadir-los-permisos-de-microsoft-graph)
7. [Crear el service principal](#7-crear-el-service-principal)
8. [Conceder (grant) los permisos: asignación de App Roles](#8-conceder-grant-los-permisos-asignación-de-app-roles)
9. [Conectar a Security & Compliance PowerShell](#9-conectar-a-security--compliance-powershell)
10. [Definir la Location (con sus matices)](#10-definir-la-location-con-sus-matices)
11. [Crear la política DLP y asignarle la Location](#11-crear-la-política-dlp-y-asignarle-la-location)
12. [Crear la regla DLP dentro de la política](#12-crear-la-regla-dlp-dentro-de-la-política)
13. [Acotar el alcance a un conjunto de usuarios](#13-acotar-el-alcance-a-un-conjunto-de-usuarios)
14. [Verificación y checklist final](#14-verificación-y-checklist-final)
15. [Probar el Purview SDK con el script de PowerShell](#15-probar-el-purview-sdk-con-el-script-de-powershell)

---

## 1. Requisitos previos

| Requisito | Detalle |
|---|---|
| PowerShell | 7.x (la sesión de referencia usó 7.6.6) |
| Azure CLI | `az` instalado y con sesión iniciada (`az login`) |
| Módulo PowerShell | `ExchangeOnlineManagement` (aporta los cmdlets `*-DlpCompliance*`) |
| Permisos | Administrador global (o equivalente) para crear apps, conceder consentimiento y crear políticas DLP |
| Licencia | Tenant con Microsoft Purview habilitado y billing pay-as-you-go (apps no-Copilot) |

Instalar el módulo si no está presente:

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
```

---

## 2. Valores de referencia

Sustituye por los valores de tu entorno. Los identificadores reales se muestran **enmascarados** como
marcadores (`<...>`) por seguridad; reemplázalos por los de tu tenant.

| Concepto | Valor de ejemplo | Descripción |
|---|---|---|
| Nombre de la app | `Demo-Purview-sdk` | Nombre visible en Entra ID |
| `appId` (Client ID) | `<APP_ID>` | Autentica **y** es la Location de la política DLP |
| Object ID del registro | `<APP_OBJECT_ID>` | Object ID del *application registration* |
| Object ID del SP | `<SP_OBJECT_ID>` | Service principal de la app |
| API de Graph | `00000003-0000-0000-c000-000000000000` | App ID fijo de Microsoft Graph (igual en todos los tenants) |
| Tenant ID | `<TENANT_ID>` | Directorio |
| Política DLP | `DLP-Demo-Purview-SDK` | Nombre de la política |
| Regla DLP | `Block Credit Cards Purview SDK` | Nombre de la regla |

Permisos de aplicación (App Roles) de Microsoft Graph utilizados:

| Permiso | App Role ID | API asociada |
|---|---|---|
| `Content.Process.User` | `24ceb246-ad29-4680-90b4-3e91ffad15eb` | `processContent` |
| `ContentActivity.Write` | `2932e07a-3c29-44e4-bb36-6d0fc176387f` | `contentActivities` |
| `ProtectionScopes.Compute.User` | `fe696d63-5e1f-4515-8232-cccc316903c6` | `protectionScopes/compute` |

> ⚠️ **Nunca guardes el secreto de cliente en el script, en el repositorio ni en esta guía.**
> Usa Azure Key Vault o una variable de entorno (`.env`, que está en `.gitignore`).

---

## 3. Verificar la sesión de Azure CLI

Confirma tenant y suscripción antes de crear nada.

```powershell
az account show
```

Comprueba `tenantId`, `name` y `user.name` en la salida.

---

## 4. Registrar la aplicación en Entra ID

```powershell
az ad app create `
  --display-name "Demo-Purview-sdk" `
  --sign-in-audience AzureADMyOrg `
  --query "{appId: appId, id: id}" -o json
```

Devuelve dos identificadores, ambos necesarios:

- `appId` → **Client ID** (se usa en el resto de comandos y como Location DLP).
- `id` → **Object ID** del registro de aplicación.

---

## 5. Generar el secreto de cliente

```powershell
az ad app credential reset `
  --id <APP_ID> `
  --display-name "Purview SDK Secret" `
  --years 2
```

La salida incluye `appId`, `password` y `tenant`. **Copia `password` en ese momento: no se puede recuperar después.** Guárdalo en Key Vault o en el `.env` local (nunca en git).

---

## 6. Añadir los permisos de Microsoft Graph

Se añaden los tres App Roles, uno por comando. El sufijo `=Role` indica permiso de **aplicación** (no delegado).

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

Cada comando avisa de que los permisos quedan **añadidos pero no efectivos** hasta conceder el consentimiento (paso 8).

---

## 7. Crear el service principal

El registro de aplicación necesita su service principal en el tenant para recibir asignaciones de roles.

```powershell
az ad sp create --id <APP_ID>
```

En la salida verás `appDisplayName`, `servicePrincipalType: Application` y `signInAudience: AzureADMyOrg`.
Anota el `id` (Object ID del SP): se usa en el paso 8.

---

## 8. Conceder (grant) los permisos: asignación de App Roles

`az ad app permission grant` está pensado para permisos **delegados** (exige `--scope`) y **no sirve** para App Roles de aplicación. La vía correcta es crear las asignaciones de rol directamente contra Microsoft Graph.

```powershell
# Object IDs de los service principals implicados
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

  Write-Host "OK $($role.name) asignado"
}
```

- Crear la asignación (`appRoleAssignments`) equivale a un **admin consent efectivo**: no hace falta el botón "Grant admin consent" del portal.
- El fichero temporal `role.json` debe escribirse como **utf8NoBOM**; con BOM, Graph rechaza el cuerpo.

Verifica que el token incluye los roles:

```powershell
$tenant = "<TENANT_ID>"
$appId  = "<APP_ID>"
# Sustituye <SECRET> por el secreto del paso 5 (no lo dejes escrito en disco).
python -c "
from azure.identity import ClientSecretCredential
import json, base64
cred = ClientSecretCredential('$tenant', '$appId', '<SECRET>')
tok = cred.get_token('https://graph.microsoft.com/.default').token
p = tok.split('.')[1]; p += '=' * (4 - len(p) % 4)
print('roles:', json.loads(base64.b64decode(p)).get('roles', []))
"
```

Resultado esperado:

```
roles: ['Content.Process.User', 'ProtectionScopes.Compute.User', 'ContentActivity.Write']
```

---

## 9. Conectar a Security & Compliance PowerShell

Los cmdlets `*-DlpCompliance*` **no** aparecen solo con `Import-Module`: se generan al abrir la sesión.

```powershell
Import-Module ExchangeOnlineManagement
Connect-IPPSSession -UserPrincipalName <ADMIN_UPN>
```

Verificación:

```powershell
Get-Command New-DlpCompliancePolicy
```

Debe devolver una función del módulo temporal `tmpEXO_*`.

---

## 10. Definir la Location (con sus matices)

La **Location** conecta la política DLP con **tu aplicación de Entra** y define **a qué usuarios** aplica. Se construye como una cadena JSON.

### Campos del objeto de Location

| Campo | Valor | Significado |
|---|---|---|
| `Workload` | `"Applications"` | Plano de enforcement para apps enterprise |
| `Location` | `"<appId>"` | **El `appId` de tu App Registration** (el mismo que el cliente envía como `applicationLocation`/`PurviewAppLocation`). Es lo que garantiza el match. **No** uses ningún otro ID. |
| `LocationDisplayName` | `"Demo-Purview-sdk"` | Nombre legible |
| `LocationSource` | `"Entra"` | La location viene de Entra ID |
| `LocationType` | `"Individual"` | Aplica a UNA app concreta, no a todo el tenant |
| `Inclusions` | array | **A qué usuarios aplica** (ver matices abajo) |
| `Exclusions` | array (opcional) | Usuarios/grupos a excluir |

### Matices del alcance de usuarios (`Inclusions` / `Exclusions`)

| Alcance | Sintaxis | Cómo se identifica |
|---|---|---|
| Un **usuario** | `{"Type":"IndividualResource","Identity":"<email/UPN>"}` | Email (UPN) |
| Un **grupo** | `{"Type":"Group","Identity":"<ObjectId>"}` | **ObjectId (GUID)** del grupo, **no** email |
| **Todo el tenant** | `{"Type":"Tenant","Identity":"All"}` | — |

Matices importantes:

- **Usuarios = email; grupos = GUID.** Confundirlos es un error frecuente.
- Para el workload `Applications` **sí** se permite `Inclusions: Tenant/All` **junto con** `Exclusions` (a diferencia de Exchange/OneDrive, donde no se pueden mezclar).
- El alcance define **quién está sujeto** a la evaluación. Debe ser coherente con el `user_id` que el cliente pasa a `processContent`: si ese usuario no está en el alcance, `protectionScopes/compute` no devolverá la política y **no habrá match**.

### Ejemplo usado (todos los usuarios del tenant)

```powershell
$myEntraAppId   = "<APP_ID>"
$myEntraAppName = "Demo-Purview-sdk"

$locations = "[{`"Workload`":`"Applications`",`"Location`":`"$myEntraAppId`",`"LocationDisplayName`":`"$myEntraAppName`",`"LocationSource`":`"Entra`",`"LocationType`":`"Individual`",`"Inclusions`":[{`"Type`":`"Tenant`",`"Identity`":`"All`"}]}]"
```

---

## 11. Crear la política DLP y asignarle la Location

La Location del paso 10 se pasa en `-Locations`, y el plano de aplicación en `-EnforcementPlanes`.

```powershell
New-DlpCompliancePolicy -Name "DLP-Demo-Purview-SDK" `
  -Mode Enable `
  -Locations $locations `
  -EnforcementPlanes @("Application")
```

- `-Mode Enable`: la política queda activa.
- `-EnforcementPlanes @("Application")`: para apps enterprise registradas en Entra (el valor `Application` reemplaza al antiguo `Entra`, ya deprecado).

Salida esperada: la política `DLP-Demo-Purview-SDK` con `Mode: Enable`.

---

## 12. Crear la regla DLP dentro de la política

La política es el contenedor; la **regla** define **qué** se detecta y **qué acción** se toma. Ejemplo: bloquear la subida de texto que contenga números de tarjeta de crédito.

```powershell
New-DlpComplianceRule -Name "Block Credit Cards Purview SDK" `
  -Policy "DLP-Demo-Purview-SDK" `
  -ContentContainsSensitiveInformation @{Name = "credit card number"} `
  -RestrictAccess @(@{setting="UploadText";value="Block"}) `
  -GenerateAlert $true `
  -GenerateIncidentReport @("siteadmin") `
  -NotifyUser @("<ADMIN_UPN>")
```

Puntos clave de la regla:

- `-ContentContainsSensitiveInformation` → el **Sensitive Information Type (SIT)** que dispara la regla.
- `-RestrictAccess @(@{setting="UploadText";value="Block"})` → la acción: **bloquear** el `uploadText`. Esto es lo que, al llamar a `processContent`, se traduce en un `policyActions` con `restrictAccess/block` (= **match**).
- `-GenerateAlert` / `-GenerateIncidentReport` / `-NotifyUser` → alertas y notificaciones.

La regla se crea en `Mode: Enforce` y su `Workload` incluye `Applications`.

---

## 13. Acotar el alcance a un conjunto de usuarios

Para limitar la política existente a usuarios o grupos concretos, **no** hace falta recrearla: se actualiza con `Set-DlpCompliancePolicy` pasando una nueva Location.

**Solo usuarios concretos:**

```powershell
$app  = "<APP_ID>"
$name = "Demo-Purview-sdk"

$loc = "[{`"Workload`":`"Applications`",`"Location`":`"$app`",`"LocationDisplayName`":`"$name`",`"LocationSource`":`"Entra`",`"LocationType`":`"Individual`",`"Inclusions`":[{`"Type`":`"IndividualResource`",`"Identity`":`"usuario1@<TENANT_DOMAIN>`"},{`"Type`":`"IndividualResource`",`"Identity`":`"usuario2@<TENANT_DOMAIN>`"}]}]"

Set-DlpCompliancePolicy -Identity "DLP-Demo-Purview-SDK" -Locations $loc
```

**Un grupo de seguridad** (recomendado, más mantenible; el grupo se identifica por su ObjectId):

```powershell
# az ad group show --group "Nombre del grupo" --query id -o tsv
$loc = "[{`"Workload`":`"Applications`",`"Location`":`"$app`",`"LocationDisplayName`":`"$name`",`"LocationSource`":`"Entra`",`"LocationType`":`"Individual`",`"Inclusions`":[{`"Type`":`"Group`",`"Identity`":`"<GROUP_OBJECT_ID>`"}]}]"

Set-DlpCompliancePolicy -Identity "DLP-Demo-Purview-SDK" -Locations $loc
```

**Todos menos un grupo** (`Inclusions` tenant + `Exclusions`):

```powershell
$loc = "[{`"Workload`":`"Applications`",`"Location`":`"$app`",`"LocationDisplayName`":`"$name`",`"LocationSource`":`"Entra`",`"LocationType`":`"Individual`",`"Inclusions`":[{`"Type`":`"Tenant`",`"Identity`":`"All`"}],`"Exclusions`":[{`"Type`":`"Group`",`"Identity`":`"<GROUP_OBJECT_ID>`"}]}]"

Set-DlpCompliancePolicy -Identity "DLP-Demo-Purview-SDK" -Locations $loc
```

---

## 14. Verificación y checklist final

### Comprobar que la política DLP se ha desplegado

```powershell
# 1. Conectar a Security & Compliance (si no tienes sesión activa)
Connect-IPPSSession -UserPrincipalName <ADMIN_UPN>

# 2. Ver la política DLP (estado y ubicaciones)
Get-DlpCompliancePolicy -Identity "DLP-Demo-Purview-SDK" | Format-List Name,Mode,Enabled,Workload,*Location*

# 3. Ver la regla asociada (qué detecta y qué acción toma)
Get-DlpComplianceRule -Policy "DLP-Demo-Purview-SDK" | Format-List Name,Mode,Disabled,IsValid,ContentContainsSensitiveInformation
```

Qué mirar en la salida:

- **Política**: `Mode = Enable` y en la Location debe aparecer tu `appId` (`<APP_ID>`) con `Workload = Applications`.
- **Regla**: `Mode = Enforce`, `Disabled = False`, `IsValid = True`.

> ⏳ **Espera a la propagación.** Crear la política es inmediato, pero el servicio tarda **unos minutos**
> en propagarla y activarla en el plano de aplicaciones. Durante ese margen, `protectionScopes/compute`
> puede no devolver la política todavía y `processContent` no hará match aunque el texto sea sensible.
> Si acabas de crearla, **espera unos minutos** y vuelve a ejecutar los comandos de verificación:
> cuando la política aparezca con `Mode: Enable` y la regla con `Mode: Enforce` / `IsValid: True`,
> está lista para probarse de extremo a extremo.

Comprobaciones adicionales:

```powershell
# Ver la Location en crudo (JSON) para confirmar el appId y el alcance de usuarios
Get-DlpCompliancePolicy -Identity "DLP-Demo-Purview-SDK" | Select-Object -ExpandProperty Locations
```

Checklist:

- [ ] Sesión de Azure CLI en el tenant correcto (`az account show`)
- [ ] Aplicación registrada y `appId` anotado
- [ ] Secreto generado y almacenado de forma segura (Key Vault / `.env`)
- [ ] Tres permisos de Graph añadidos
- [ ] Service principal creado
- [ ] Tres App Roles asignados vía `az rest` (grant efectivo)
- [ ] Token verificado: incluye los tres `roles`
- [ ] Sesión `Connect-IPPSSession` establecida
- [ ] Location definida con el `appId` correcto y el alcance de usuarios deseado
- [ ] Política DLP creada (`Mode: Enable`) con la Location asignada
- [ ] Regla DLP creada (`Mode: Enforce`) con su SIT y acción de bloqueo
- [ ] (Opcional) Alcance acotado a usuarios/grupos con `Set-DlpCompliancePolicy`
- [ ] Prueba de extremo a extremo con contenido sensible de ejemplo

---

## 15. Probar el Purview SDK con los scripts

Una vez que la política está creada y **propagada** (ver la nota de propagación del paso 14), puedes
probar la evaluación de extremo a extremo con **cualquiera de los dos scripts** incluidos, que
implementan la misma lógica:

- PowerShell: [`scripts/Invoke-PurviewDlpTest.ps1`](../scripts/Invoke-PurviewDlpTest.ps1)
- Python: [`scripts/invoke_purview_dlp_test.py`](../scripts/invoke_purview_dlp_test.py)

Ambos:

1. Leen la configuración del `.env` de la raíz del repositorio.
2. Autentican con client credentials (la App Registration).
3. Reciben el usuario como **object id** (GUID) y, opcionalmente, la **ruta del fichero de muestras**.
4. Llaman **una vez** a `protectionScopes/compute` y cachean el `ETag`.
5. Envían cada muestra de `data/muestras.txt` a `processContent` e indican si hace **match**.

Ambos parámetros (usuario y fichero de muestras) se pueden pasar en la invocación **o** dejar que el
script los solicite de forma interactiva.

### Requisitos previos

- El fichero `.env` relleno (ver el README) con `AZURE_TENANT_ID`, `PURVIEW_CLIENT_ID`,
  `PURVIEW_CLIENT_SECRET`, `PURVIEW_APP_LOCATION_VALUE`, `PURVIEW_APP_NAME`, `GRAPH_BASE_URL` y `GRAPH_SCOPE`.
- La política DLP creada, en `Mode: Enable`, con la regla en `Mode: Enforce`, y **ya propagada**.
- Billing pay-as-you-go activo en el tenant (si no, las llamadas devuelven `402 Payment Required`).

### Ejecución

El usuario debe indicarse como **object id** (GUID). Si solo tienes el UPN, obtén su object id con:

```powershell
az ad user show --id <UPN> --query id -o tsv
```

#### PowerShell

```powershell
# Desde la raíz del repositorio.

# a) Indicando el usuario por object id (GUID):
./scripts/Invoke-PurviewDlpTest.ps1 -User 11111111-2222-3333-4444-555555555555

# b) Indicando tambien un fichero de muestras concreto:
./scripts/Invoke-PurviewDlpTest.ps1 -User 11111111-2222-3333-4444-555555555555 -SamplesFile data/muestras.txt

# c) Sin parámetros: el script pide el fichero de muestras y el usuario durante la ejecución.
./scripts/Invoke-PurviewDlpTest.ps1
```

#### Python

```powershell
# Usar el interprete del entorno virtual del repositorio.

# a) Indicando el usuario por object id (GUID):
.\.venv\Scripts\python.exe .\scripts\invoke_purview_dlp_test.py --user 11111111-2222-3333-4444-555555555555

# b) Indicando tambien un fichero de muestras concreto:
.\.venv\Scripts\python.exe .\scripts\invoke_purview_dlp_test.py --user 11111111-2222-3333-4444-555555555555 --samples-file data/muestras.txt

# c) Sin parámetros: el script pide el fichero de muestras y el usuario durante la ejecución.
.\.venv\Scripts\python.exe .\scripts\invoke_purview_dlp_test.py
```

> **Object id (GUID)**: la API espera el object id en la ruta `/users/{userId}/...`. Ninguno de los
> dos scripts resuelve UPN; pasa directamente el GUID (usa el comando `az ad user show` de arriba si
> solo tienes el UPN).

### Interpretar la salida

El script imprime una línea por muestra con el veredicto y un resumen final:

```
[ 1] MATCH (block) | Mi numero de tarjeta de credito es 4111 1111 1111 1111, guar...
[ 7] NO MATCH      | Resume el informe trimestral de ventas de la region EMEA.

===== Resumen =====
Total: 12  |  MATCH: 6  |  NO MATCH: 6  |  ERRORES: 0
```

- **MATCH (block)**: `processContent` devolvió `policyActions` con `restrictAccess/block` → la DLP
  bloquearía ese contenido (las muestras con número de tarjeta del Bloque 1).
- **NO MATCH**: `policyActions` vacío → no dispara la regla (las muestras benignas del Bloque 2), pero
  siguen siendo auditables vía `contentActivities`.
- **ERROR 402**: falta el billing pay-as-you-go en el tenant.

### Si no ves match

- Confirma que la política está **propagada** (repite las comprobaciones del paso 14; puede tardar
  unos minutos tras crearla).
- Verifica que `protection scopes devueltos` es mayor que 0 en la salida. Si es 0, ninguna política
  aplica a ese usuario+app: revisa que el `PURVIEW_APP_LOCATION_VALUE` del `.env` coincide con el
  `Location` de la política y que el usuario está dentro del **alcance** (`Inclusions`) de la política.

---

## Errores comunes y soluciones

| Error | Causa | Solución |
|---|---|---|
| `az ad app permission grant: the following arguments are required: --scope` | El comando espera permisos **delegados**, no App Roles | Usar `az rest` con `appRoleAssignments` (paso 8) |
| `New-DlpCompliancePolicy: The term ... is not recognized` | No hay sesión de Security & Compliance abierta | Ejecutar `Connect-IPPSSession` (paso 9) |
| `Get-Command New-DlpCompliancePolicy` no devuelve nada tras `Import-Module` | Los cmdlets se generan al conectar, no al importar | Conectar primero, verificar después |
| Permisos añadidos pero la app recibe `403` | Falta el grant (asignación de App Roles) | Completar el paso 8 y volver a solicitar el token |
| Graph rechaza el cuerpo de `az rest` | Fichero JSON guardado con BOM | Escribir con `-Encoding utf8NoBOM` |
| La política nunca hace match | La Location apunta a otro `appId`, o el usuario no está en el alcance | Usar el `appId` correcto en `Location` y alinear el alcance con el `user_id` de `processContent` |
