<#
.SYNOPSIS
    Envia las muestras de texto de un fichero a las Purview APIs de Microsoft Graph
    (protectionScopes/compute + processContent) y muestra si cada una hace match con la DLP.

.DESCRIPTION
    Lee la configuracion desde el fichero .env de la raiz del repositorio, autentica con
    client credentials (App Registration), recibe el usuario como object id (GUID) y evalua
    cada linea del fichero de muestras (ignorando comentarios que empiezan por '#').

.PARAMETER User
    Object id (GUID) del usuario en cuyo contexto se evalua la DLP. Si no se indica, se solicita
    durante la ejecucion. Obtenlo con: az ad user show --id <UPN> --query id -o tsv

.PARAMETER SamplesFile
    Ruta al fichero de muestras. Por defecto: data/muestras.txt de la raiz del repositorio.
    Si no se indica, se solicita durante la ejecucion (con ese valor por defecto).

.EXAMPLE
    ./Invoke-PurviewDlpTest.ps1 -User 11111111-2222-3333-4444-555555555555

.EXAMPLE
    ./Invoke-PurviewDlpTest.ps1 -User 11111111-2222-3333-4444-555555555555 -SamplesFile ..\data\muestras.txt
#>

[CmdletBinding()]
param(
    [string]$User,
    [string]$SamplesFile
)

$ErrorActionPreference = 'Stop'

# --- Rutas base (repo root = carpeta padre de /scripts) ---
$repoRoot = Split-Path -Parent $PSScriptRoot
$envPath  = Join-Path $repoRoot '.env'

# --- Solicitar parametros si no se pasaron ---
if ([string]::IsNullOrWhiteSpace($SamplesFile)) {
    $default = Join-Path $repoRoot 'data/muestras.txt'
    $answer  = Read-Host "Fichero de muestras [$default]"
    $SamplesFile = if ([string]::IsNullOrWhiteSpace($answer)) { $default } else { $answer }
}
if ([string]::IsNullOrWhiteSpace($User)) {
    $User = Read-Host 'Usuario (object id GUID)'
}
if ([string]::IsNullOrWhiteSpace($User)) { throw 'Debe indicar el object id (GUID) del usuario.' }

# --- Cargar .env en un hashtable ---
function Get-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw ".env no encontrado en: $Path" }
    $map = @{}
    foreach ($line in Get-Content -Path $Path) {
        $trim = $line.Trim()
        if ($trim -eq '' -or $trim.StartsWith('#')) { continue }
        $idx = $trim.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $trim.Substring(0, $idx).Trim()
        $val = $trim.Substring($idx + 1).Trim().Trim('"')
        $map[$key] = $val
    }
    return $map
}

$cfg = Get-DotEnv -Path $envPath

$tenantId    = $cfg['AZURE_TENANT_ID']
$clientId    = $cfg['PURVIEW_CLIENT_ID']
$clientSecret= $cfg['PURVIEW_CLIENT_SECRET']
$appName     = $cfg['PURVIEW_APP_NAME']
$appVersion  = if ($cfg['PURVIEW_APP_VERSION']) { $cfg['PURVIEW_APP_VERSION'] } else { '1.0' }
$appLocation = $cfg['PURVIEW_APP_LOCATION_VALUE']
$graphBase   = if ($cfg['GRAPH_BASE_URL']) { $cfg['GRAPH_BASE_URL'].TrimEnd('/') } else { 'https://graph.microsoft.com/beta' }
$scope       = if ($cfg['GRAPH_SCOPE']) { $cfg['GRAPH_SCOPE'] } else { 'https://graph.microsoft.com/.default' }

foreach ($k in 'AZURE_TENANT_ID','PURVIEW_CLIENT_ID','PURVIEW_CLIENT_SECRET','PURVIEW_APP_LOCATION_VALUE') {
    if ([string]::IsNullOrWhiteSpace($cfg[$k])) { throw "Falta la variable $k en .env" }
}

# --- Leer muestras (ignorando comentarios y lineas vacias) ---
if (-not (Test-Path $SamplesFile)) { throw "Fichero de muestras no encontrado: $SamplesFile" }
$samples = Get-Content -Path $SamplesFile |
    Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') }
if (-not $samples) { throw "El fichero de muestras no contiene lineas validas: $SamplesFile" }

# --- Obtener token (client credentials) ---
Write-Host 'Obteniendo token de Microsoft Graph...' -ForegroundColor Cyan
$tokenResp = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body @{
        client_id     = $clientId
        client_secret = $clientSecret
        scope         = $scope
        grant_type    = 'client_credentials'
    }
$headers = @{ Authorization = "Bearer $($tokenResp.access_token)" }

# --- Validar usuario: debe ser un object id (GUID) ---
$guidRef = [ref]([guid]::Empty)
if (-not [guid]::TryParse($User, $guidRef)) {
    throw "El usuario debe ser un object id (GUID). Valor recibido: '$User'. Obtenlo con: az ad user show --id <UPN> --query id -o tsv"
}
$userId = $User
Write-Host "Usuario (object id): $userId" -ForegroundColor Cyan

$dsg = "$graphBase/users/$userId/dataSecurityAndGovernance"

# --- 1) Calcular protection scopes (una vez) y capturar ETag ---
Write-Host 'Calculando protection scopes...' -ForegroundColor Cyan
$etag = $null
try {
    $scopeBody = @{
        activities = 'uploadText'
        locations  = @(
            @{ '@odata.type' = 'microsoft.graph.policyLocationApplication'; value = $appLocation }
        )
    } | ConvertTo-Json -Depth 6

    $scopeResp = Invoke-WebRequest -Method Post -Uri "$dsg/protectionScopes/compute" `
        -Headers $headers -Body $scopeBody -ContentType 'application/json'
    if ($scopeResp.Headers.ETag) { $etag = [string]$scopeResp.Headers.ETag }
    $scopeJson = $scopeResp.Content | ConvertFrom-Json
    $scopeCount = if ($scopeJson.value) { $scopeJson.value.Count } else { 0 }
    Write-Host "  protection scopes devueltos: $scopeCount (ETag: $etag)" -ForegroundColor DarkGray
    if ($scopeCount -eq 0) {
        Write-Warning 'No se devolvieron protection scopes: puede que ninguna politica aplique a este usuario+app, o que aun no se haya propagado.'
    }
} catch {
    Write-Warning "protectionScopes/compute fallo: $($_.Exception.Message)"
}

# --- 2) Evaluar cada muestra con processContent ---
function Get-Verdict {
    param($PolicyActions)
    if (-not $PolicyActions -or $PolicyActions.Count -eq 0) { return 'NO MATCH' }
    $verdicts = foreach ($a in $PolicyActions) {
        if ($a.restrictionAction) { "MATCH ($($a.restrictionAction))" }
        elseif ($a.action)        { "MATCH ($($a.action))" }
        else                      { 'MATCH' }
    }
    return ($verdicts -join ', ')
}

$results = @()
$i = 0
foreach ($text in $samples) {
    $i++
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss')
    $entry = @{
        '@odata.type'    = 'microsoft.graph.processConversationMetadata'
        identifier       = [guid]::NewGuid().ToString()
        content          = @{ '@odata.type' = 'microsoft.graph.textContent'; data = $text }
        name             = 'purview-sdk PowerShell test'
        correlationId    = [guid]::NewGuid().ToString()
        sequenceNumber   = 0
        isTruncated      = $false
        createdDateTime  = $now
        modifiedDateTime = $now
        contentCategory  = 'ai'
    }
    $payload = @{
        contentToProcess = @{
            contentEntries       = @($entry)
            activityMetadata     = @{ activity = 'uploadText' }
            protectedAppMetadata = @{
                name                = $appName
                version             = $appVersion
                applicationLocation = @{ '@odata.type' = 'microsoft.graph.policyLocationApplication'; value = $appLocation }
            }
            integratedAppMetadata = @{ name = $appName; version = $appVersion }
        }
    } | ConvertTo-Json -Depth 12

    $callHeaders = $headers.Clone()
    if ($etag) { $callHeaders['If-None-Match'] = $etag }

    $short = if ($text.Length -gt 60) { $text.Substring(0, 60) + '...' } else { $text }
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "$dsg/processContent" `
            -Headers $callHeaders -Body $payload -ContentType 'application/json'
        $verdict = Get-Verdict -PolicyActions $resp.policyActions
        $color = if ($verdict -eq 'NO MATCH') { 'Green' } else { 'Red' }
        Write-Host ("[{0,2}] {1,-12} | {2}" -f $i, $verdict, $short) -ForegroundColor $color
        $results += [pscustomobject]@{ N = $i; Verdict = $verdict; Text = $short }
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 402) {
            Write-Host ("[{0,2}] ERROR 402   | {1}" -f $i, 'Pay-as-you-go no configurado (Payment Required)') -ForegroundColor Yellow
        } else {
            Write-Host ("[{0,2}] ERROR {1}    | {2}" -f $i, $status, $_.Exception.Message) -ForegroundColor Yellow
        }
        $results += [pscustomobject]@{ N = $i; Verdict = "ERROR $status"; Text = $short }
    }
}

# --- Resumen ---
Write-Host ''
Write-Host '===== Resumen =====' -ForegroundColor Cyan
$match   = ($results | Where-Object { $_.Verdict -like 'MATCH*' }).Count
$nomatch = ($results | Where-Object { $_.Verdict -eq 'NO MATCH' }).Count
$errors  = ($results | Where-Object { $_.Verdict -like 'ERROR*' }).Count
Write-Host ("Total: {0}  |  MATCH: {1}  |  NO MATCH: {2}  |  ERRORES: {3}" -f $results.Count, $match, $nomatch, $errors)
