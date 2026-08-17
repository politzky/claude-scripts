<#
.SYNOPSIS
    Liest fehlgeschlagene Backup-Events aus Rubrik CDM aus.
.PARAMETER Server
    Rubrik Cluster FQDN oder IP.
.PARAMETER ApiToken
    Rubrik API Token (Service Account).
.PARAMETER Hours
    Zeitraum in Stunden (Standard: 24).
.PARAMETER ObjectType
    Optional: Filter auf Object-Typ (z.B. VmwareVm, Mssql, Fileset, NutanixVm, HypervVm).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Server,

    [Parameter(Mandatory)]
    [string]$ApiToken,

    [int]$Hours = 24,

    [ValidateSet('VmwareVm','Mssql','Fileset','NutanixVm','HypervVm','ManagedVolume','OracleDb','WindowsVolumeGroup','')]
    [string]$ObjectType
)

# --- TLS 1.2 und Self-Signed Certs ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
}
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

# --- Auth Header ---
$headers = @{
    'Authorization' = "Bearer $ApiToken"
    'Accept'        = 'application/json'
}

$baseUri = "https://$Server/api/v1"

# --- Zeitraum berechnen ---
$afterDate = (Get-Date).AddHours(-$Hours).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$beforeDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

Write-Host "`n=== Rubrik Backup-Failures ===" -ForegroundColor Cyan
Write-Host "Cluster:   $Server"
Write-Host "Zeitraum:  letzte $Hours Stunden ($afterDate - $beforeDate)"
if ($ObjectType) { Write-Host "Filter:    $ObjectType" }
Write-Host ""

# --- Events abrufen (paginiert) ---
$allEvents = [System.Collections.Generic.List[object]]::new()
$hasMore = $true
$afterId = ''
$limit = 100

while ($hasMore) {
    $uri = "$baseUri/event_series?status=Failure&event_type=Backup&after_date=$afterDate&before_date=$beforeDate&limit=$limit"

    if ($ObjectType) {
        $uri += "&object_type=$ObjectType"
    }
    if ($afterId) {
        $uri += "&after_id=$afterId"
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
    }
    catch {
        Write-Host "FEHLER beim API-Aufruf: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            Write-Host "HTTP Status: $statusCode" -ForegroundColor Red
        }
        exit 1
    }

    foreach ($event in $response.data) {
        $allEvents.Add($event)
    }

    $hasMore = $response.hasMore -eq $true
    if ($hasMore -and $response.data.Count -gt 0) {
        $afterId = $response.data[-1].eventSeriesId
    }
}

# --- Ausgabe ---
if ($allEvents.Count -eq 0) {
    Write-Host "Keine fehlgeschlagenen Backups im angegebenen Zeitraum gefunden." -ForegroundColor Green
    exit 0
}

Write-Host "Gefunden: $($allEvents.Count) fehlgeschlagene Backup-Events`n" -ForegroundColor Yellow

$results = $allEvents | ForEach-Object {
    [PSCustomObject]@{
        Zeitpunkt   = if ($_.startTime) { [DateTime]::Parse($_.startTime).ToLocalTime().ToString('dd.MM.yyyy HH:mm') } else { '-' }
        Objekt      = $_.objectName
        ObjektTyp   = $_.objectType
        Location    = $_.location
        Fehler      = if ($_.lastActivityStatus) { $_.lastActivityStatus } else { $_.status }
        Detail      = if ($_.lastActivityMessage) { $_.lastActivityMessage.TrimEnd() } else { '-' }
    }
}

$results | Format-Table -AutoSize -Wrap

# --- Zusammenfassung nach Objekt-Typ ---
Write-Host "`n--- Zusammenfassung ---" -ForegroundColor Cyan
$results | Group-Object ObjektTyp | Sort-Object Count -Descending | ForEach-Object {
    Write-Host ("  {0,-25} {1,4} Failures" -f $_.Name, $_.Count)
}

Write-Host "`nGesamt: $($allEvents.Count) fehlgeschlagene Backups in den letzten $Hours Stunden.`n" -ForegroundColor Yellow
