<#
.SYNOPSIS
    Automatisierter DBCC CHECKDB fuer MSSQL-Datenbanken via Rubrik Live Mount.

.DESCRIPTION
    Mountet jede (oder ausgewaehlte) MSSQL-Datenbank aus Rubrik Security Cloud
    per Live Mount an eine Ziel-SQL-Server-Instanz, fuehrt DBCC CHECKDB aus,
    entfernt den Mount und protokolliert das Ergebnis in CSV und Log-Datei.
    Nur Datenbanken auf dem gleichen Rubrik Cluster wie die Ziel-Instanz werden verarbeitet.
    Optional kann ein Cluster-Name angegeben werden, um die Auswahl weiter einzuschraenken.

.PARAMETER TargetHostName
    Hostname des Ziel-SQL-Servers (ohne Instanzname).

.PARAMETER InstanceName
    Name der SQL Server Instanz auf dem Zielhost.

.PARAMETER SqlClusterName
    Virtueller SQL Server Netzwerkname bei Failover-Clustern. Wenn angegeben, wird dieser
    fuer die SQL-Verbindung verwendet statt TargetHostName. Noetig wenn der Windows-Cluster-
    Knotenname (fuer RSC) und der SQL-Listener-Name unterschiedlich sind.

.PARAMETER ClusterName
    Optionaler Rubrik Cluster-Name. Wenn angegeben, werden nur DBs von diesem Cluster verarbeitet.
    Ohne Angabe wird automatisch der Cluster der Ziel-Instanz verwendet.

.PARAMETER DatabaseName
    Optionale Liste von Datenbanknamen. Ohne Angabe werden alle Online-DBs geprueft.

.PARAMETER EstimateOnly
    Fuehrt nur DBCC CHECKDB WITH ESTIMATEONLY aus (Schnelltest, keine echte Pruefung).

.PARAMETER OutputPath
    Pfad fuer die CSV-Ergebnisdatei.

.PARAMETER LogDir
    Verzeichnis fuer Log-Dateien.

.PARAMETER MaxLogFiles
    Maximale Anzahl Log-Dateien bevor die aeltesten geloescht werden.

.EXAMPLE
    .\Invoke-RscMssqlDbccCheck.ps1 -TargetHostName "sqlhost01" -InstanceName "MSSQLSERVER"

.EXAMPLE
    .\Invoke-RscMssqlDbccCheck.ps1 -TargetHostName "wincluster01" -InstanceName "SQLINST1" -SqlClusterName "sqlcluster01"

.EXAMPLE
    .\Invoke-RscMssqlDbccCheck.ps1 -TargetHostName "sqlhost01" -InstanceName "INST1" -ClusterName "Cluster-A"

.EXAMPLE
    .\Invoke-RscMssqlDbccCheck.ps1 -TargetHostName "sqlhost01" -InstanceName "INST1" -DatabaseName "DB1","DB2" -EstimateOnly
#>

#Requires -Version 5.1
#Requires -Modules RubrikSecurityCloud

param(
    [Parameter(Mandatory = $true, HelpMessage = "Hostname des Ziel-SQL-Servers")]
    [string]$TargetHostName,

    [Parameter(Mandatory = $true, HelpMessage = "SQL Server Instanzname auf dem Zielhost")]
    [string]$InstanceName,

    [string]$SqlClusterName,
    [string]$ClusterName,
    [string[]]$DatabaseName,
    [switch]$EstimateOnly,
    [string]$OutputPath = ".\DBCC_Results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [string]$LogDir = "$PSScriptRoot\logs",
    [int]$MaxLogFiles = 7
)

# --- Log-Verzeichnis und Rotation ---
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$logFile = Join-Path $LogDir "DBCC_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Aelteste Logs loeschen wenn MaxLogFiles ueberschritten
$existingLogs = Get-ChildItem -Path $LogDir -Filter "DBCC_*.log" | Sort-Object LastWriteTime
if ($existingLogs.Count -ge $MaxLogFiles) {
    $toDelete = $existingLogs | Select-Object -First ($existingLogs.Count - $MaxLogFiles + 1)
    $toDelete | Remove-Item -Force
}

# --- Logging-Funktion: schreibt in Log-Datei und Terminal mit farbiger Ausgabe ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line
    switch ($Level) {
        "ERROR" { Write-Host $Message -ForegroundColor Red }
        "WARN"  { Write-Host $Message -ForegroundColor Yellow }
        "OK"    { Write-Host $Message -ForegroundColor Green }
        "STEP"  { Write-Host "  $Message" }
        "HEAD"  { Write-Host $Message -ForegroundColor Cyan }
        default { Write-Host $Message }
    }
}

# --- RSC-Verbindung herstellen ---
Import-Module RubrikSecurityCloud
Connect-Rsc -ServiceAccountFile "$PSScriptRoot\cred_encrypted.xml" | Out-Null

Write-Log "=== DBCC CHECKDB Lauf gestartet ==="
Write-Log "Log-Datei: $logFile"
Write-Log "Modus: $(if ($EstimateOnly) { 'ESTIMATEONLY (Test)' } else { 'PHYSICAL_ONLY' })"

# --- Ziel-Instanz in RSC ermitteln und Cluster-ID fuer Filterung merken ---
$targetInstance = Get-RscMssqlInstance -HostName $TargetHostName -Name $InstanceName | Where-Object { $_.Name -eq $InstanceName } | Select-Object -First 1
if (-not $targetInstance) {
    Write-Log "Ziel-Instanz $TargetHostName\$InstanceName nicht gefunden." "ERROR"
    return
}
$targetClusterId = $targetInstance.Cluster.Id
$targetClusterName = $targetInstance.Cluster.Name
Write-Log "Ziel-Instanz: $($targetInstance.Name) auf $TargetHostName (Cluster: $targetClusterName)"

# Wenn ClusterName angegeben, pruefen ob Ziel-Instanz darauf liegt
if ($ClusterName -and $targetClusterName -ne $ClusterName) {
    Write-Log "Ziel-Instanz liegt auf Cluster '$targetClusterName', nicht auf '$ClusterName'. Live Mount nicht moeglich." "ERROR"
    return
}

# SQL-Verbindung: SqlClusterName hat Vorrang vor TargetHostName (Failover-Cluster)
$sqlHost = if ($SqlClusterName) { $SqlClusterName } else { $TargetHostName }
if ($SqlClusterName) {
    Write-Log "SQL Failover-Cluster: $SqlClusterName"
}
# Default-Instanz (MSSQLSERVER) braucht nur den Hostnamen, benannte Instanzen Host\Instanz
if ($InstanceName -eq "MSSQLSERVER") {
    $sqlServerInstance = $sqlHost
} else {
    $sqlServerInstance = "$sqlHost\$InstanceName"
}

# --- Alle MSSQL-Datenbanken aus RSC laden (mit Cluster-Info) ---
$query = New-RscQuery -GqlQuery mssqlDatabases
$query.var.filter = @()
$query.field.nodes[0].Cluster = New-Object -TypeName RubrikSecurityCloud.Types.Cluster
$query.field.nodes[0].Cluster.name = "Fetch"
$query.field.nodes[0].Cluster.id = "Fetch"
# System-DBs und Live-Mount-Artefakte (DBCC_ Prefix) ausfiltern
$allNodes = (Invoke-Rsc -Query $query).nodes | Where-Object {
    $_.Name -notin @('master', 'model', 'msdb', 'tempdb') -and
    $_.Name -notlike 'DBCC_*' -and
    $_.IsOnline -eq $true
}

if ($DatabaseName) {
    $allNodes = $allNodes | Where-Object { $_.Name -in $DatabaseName }
}

# --- Cluster-Filter: nur DBs auf dem Cluster der Ziel-Instanz (oder dem angegebenen Cluster) ---
if ($ClusterName) {
    $databases = $allNodes | Where-Object { $_.Cluster.Name -eq $ClusterName } | Sort-Object Name -Unique
    $skipped = $allNodes | Where-Object { $_.Cluster.Name -ne $ClusterName }
    Write-Log "Cluster-Filter: $ClusterName"
} else {
    $databases = $allNodes | Where-Object { $_.Cluster.Id -eq $targetClusterId } | Sort-Object Name -Unique
    $skipped = $allNodes | Where-Object { $_.Cluster.Id -ne $targetClusterId }
}

if ($skipped) {
    $skippedNames = ($skipped | Select-Object -ExpandProperty Name -Unique) -join ", "
    Write-Log "Uebersprungen (anderer Cluster): $skippedNames" "WARN"
}

if (-not $databases -or $databases.Count -eq 0) {
    Write-Log "Keine Datenbanken gefunden." "ERROR"
    return
}
Write-Log "$($databases.Count) Datenbank(en) gefunden."
Write-Log ""

$results = @()
$dbIndex = 0
$okCount = 0
$failCount = 0
$skipCount = 0

# --- Hauptschleife: jede DB sequenziell per Live Mount pruefen ---
foreach ($db in $databases) {
    $dbIndex++
    $mountedDbName = "DBCC_$($db.Name)"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Log "[$dbIndex/$($databases.Count)] $($db.Name)" "HEAD"

    try {
        # Vollstaendiges DB-Objekt fuer Live Mount holen
        try {
            $rscDb = Get-RscMssqlDatabase -Id $db.Id 6>$null
        } catch {
            $skipCount++
            Write-Log "DB nicht mehr in RSC verfuegbar - uebersprungen." "WARN"
            $stopwatch.Stop()
            $results += [PSCustomObject]@{
                DatabaseName = $db.Name
                MountedAs    = $mountedDbName
                DbccResult   = "SKIPPED"
                DbccOutput   = "DB nicht in RSC verfuegbar"
                Duration     = [math]::Round($stopwatch.Elapsed.TotalSeconds)
                Timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            }
            Write-Log ""
            continue
        }

        # Letztes Full Backup als Recovery Point (minimiert Log-Restore-Zeit)
        Write-Log "Recovery Point holen (LastFull)..." "STEP"
        $recoveryPoint = Get-RscMssqlDatabaseRecoveryPoint -RscMssqlDatabase $rscDb -LastFull
        Write-Log "Recovery Point: $recoveryPoint" "STEP"

        # Kein gueltiges Full Backup vorhanden (Epoch = 1970-01-01)
        if (-not $recoveryPoint -or "$recoveryPoint" -match "^1970-01-01") {
            $skipCount++
            Write-Log "Kein Full Backup vorhanden - uebersprungen." "WARN"
            $dbccResult = "SKIPPED"
            $dbccDetail = "Kein Full Backup"
            $stopwatch.Stop()
            $results += [PSCustomObject]@{
                DatabaseName = $db.Name
                MountedAs    = $mountedDbName
                DbccResult   = $dbccResult
                DbccOutput   = $dbccDetail
                Duration     = [math]::Round($stopwatch.Elapsed.TotalSeconds)
                Timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            }
            Write-Log ""
            continue
        }

        # Pruefen ob bereits ein Mount mit diesem Namen existiert und ggf. entfernen
        $existingMount = (Get-RscMssqlLiveMount -RscMssqlDatabase $rscDb -MountedDatabaseName $mountedDbName 6>$null | Select-Object -First 1)
        if ($existingMount) {
            Write-Log "Alter Mount '$mountedDbName' gefunden - wird entfernt..." "WARN"
            try {
                Remove-RscMssqlLiveMount -MssqlLiveMount $existingMount -Force | Out-Null
                $cleanupTimeout = 300
                $cleanupElapsed = 0
                while ($cleanupElapsed -lt $cleanupTimeout) {
                    Start-Sleep -Seconds 15
                    $cleanupElapsed += 15
                    $checkOld = (Get-RscMssqlLiveMount -RscMssqlDatabase $rscDb -MountedDatabaseName $mountedDbName 6>$null | Select-Object -First 1)
                    if (-not $checkOld) {
                        Write-Log "Alter Mount entfernt. ($cleanupElapsed Sek.)" "STEP"
                        break
                    }
                }
            } catch {
                Write-Log "Alter Mount konnte nicht entfernt werden: $($_.Exception.Message)" "WARN"
            }
        }

        # Live Mount auf der Ziel-Instanz erstellen
        Write-Log "Live Mount erstellen als '$mountedDbName'..." "STEP"
        try {
            New-RscMssqlLiveMount -RscMssqlDatabase $rscDb `
                -MountedDatabaseName $mountedDbName `
                -TargetMssqlInstance $targetInstance `
                -RecoveryDateTime $recoveryPoint | Out-Null
        } catch {
            $errMsg = $_.Exception.Message
            if ($errMsg -match "incompatible with the internal version") {
                $skipCount++
                Write-Log "SQL Server Version inkompatibel (Quell-DB neuer als Ziel-Instanz) - uebersprungen." "WARN"
                $dbccResult = "SKIPPED"
                $dbccDetail = "SQL Server Versionsinkompatibilitaet"
            } elseif ($errMsg -match "already exists") {
                Write-Log "Mount existiert noch auf anderer Instanz - uebersprungen." "WARN"
                $skipCount++
                $dbccResult = "SKIPPED"
                $dbccDetail = "Mount existiert bereits auf anderer Instanz"
            } else {
                Write-Log "Live Mount fehlgeschlagen: $errMsg" "ERROR"
                $dbccResult = "ERROR"
                $dbccDetail = $errMsg
                $failCount++
            }
            $stopwatch.Stop()
            $results += [PSCustomObject]@{
                DatabaseName = $db.Name
                MountedAs    = $mountedDbName
                DbccResult   = $dbccResult
                DbccOutput   = $dbccDetail
                Duration     = [math]::Round($stopwatch.Elapsed.TotalSeconds)
                Timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            }
            Write-Log ""
            continue
        }

        # Warten bis DB auf SQL Server online ist (prueft RSC und SQL parallel)
        Write-Log "Warte auf Mount und DB online ($sqlServerInstance)..." "STEP"
        $sqlReady = $false
        $mountReady = $false
        $pollTimeout = 600
        $pollElapsed = 0
        $lastSqlError = ""
        while (-not $sqlReady -and $pollElapsed -lt $pollTimeout) {
            Start-Sleep -Seconds 10
            $pollElapsed += 10

            # RSC-Status pruefen (nur zur Info, nicht blockierend)
            if (-not $mountReady) {
                $mount = (Get-RscMssqlLiveMount -RscMssqlDatabase $rscDb -MountedDatabaseName $mountedDbName 6>$null | Select-Object -First 1)
                if ($mount -and $mount.IsReady -eq $true) {
                    $mountReady = $true
                    Write-Log "Mount bereit in RSC. ($pollElapsed Sek.)" "STEP"
                }
            }

            # SQL Server pruefen — DB kann vor RSC-Ready online sein
            try {
                $dbCheck = Invoke-Sqlcmd -ServerInstance $sqlServerInstance `
                    -Query "SELECT name, state_desc FROM sys.databases WHERE name = N'$($mountedDbName -replace "'","''")'" `
                    -ConnectionTimeout 10 `
                    -ErrorAction Stop
                if ($dbCheck -and $dbCheck.state_desc -eq "ONLINE") {
                    $sqlReady = $true
                    Write-Log "DB online auf SQL Server. ($pollElapsed Sek.)" "STEP"
                } elseif ($dbCheck) {
                    Write-Log "DB Status: $($dbCheck.state_desc) ($pollElapsed/$pollTimeout Sek.)" "STEP"
                }
            } catch {
                $currentError = $_.Exception.Message
                if ($currentError -ne $lastSqlError) {
                    Write-Log "SQL Fehler: $currentError" "WARN"
                    $lastSqlError = $currentError
                }
            }
        }
        if (-not $sqlReady) {
            $detail = if ($lastSqlError) { " Letzter Fehler: $lastSqlError" } else { "" }
            throw "DB '$mountedDbName' nicht auf SQL Server online nach $pollTimeout Sekunden.$detail"
        }

        # DBCC CHECKDB ausfuehren (PHYSICAL_ONLY oder ESTIMATEONLY je nach Parameter)
        Write-Log "DBCC CHECKDB laeuft..." "STEP"
        $dbccOutput = Invoke-Sqlcmd -ServerInstance $sqlServerInstance `
            -Database $mountedDbName `
            -Query "DBCC CHECKDB([$mountedDbName]) WITH $(if ($EstimateOnly) { 'ESTIMATEONLY' } else { 'NO_INFOMSGS, PHYSICAL_ONLY' })" `
            -QueryTimeout 3600 `
            -OutputSqlErrors $true `
            -ErrorAction SilentlyContinue 2>&1

        # Ergebnis auswerten
        if ($dbccOutput -and $dbccOutput -match "error|Msg \d+") {
            $dbccResult = "FAILED"
            $dbccDetail = ($dbccOutput | Out-String).Trim()
        } else {
            $dbccResult = "OK"
            $dbccDetail = ""
        }

        $stopwatch.Stop()
        if ($dbccResult -eq "OK") {
            $okCount++
            Write-Log "DBCC Ergebnis: OK ($([math]::Round($stopwatch.Elapsed.TotalSeconds)) Sek.)" "OK"
        } else {
            $failCount++
            Write-Log "DBCC Ergebnis: FAILED ($([math]::Round($stopwatch.Elapsed.TotalSeconds)) Sek.)" "ERROR"
            Write-Log "Detail: $dbccDetail" "ERROR"
        }

        # Live Mount entfernen und warten bis er weg ist (max 300 Sek.)
        Write-Log "Live Mount entfernen..." "STEP"
        try {
            $mount = (Get-RscMssqlLiveMount -RscMssqlDatabase $rscDb -MountedDatabaseName $mountedDbName 6>$null | Select-Object -First 1)
            if ($mount) {
                Remove-RscMssqlLiveMount -MssqlLiveMount $mount -ErrorAction Stop 6>$null | Out-Null

                $unmountTimeout = 300
                $unmountElapsed = 0
                while ($unmountElapsed -lt $unmountTimeout) {
                    Start-Sleep -Seconds 15
                    $unmountElapsed += 15
                    $checkMount = (Get-RscMssqlLiveMount -RscMssqlDatabase $rscDb -MountedDatabaseName $mountedDbName 6>$null | Select-Object -First 1)
                    if (-not $checkMount) {
                        Write-Log "Mount entfernt. ($unmountElapsed Sek.)" "STEP"
                        break
                    }
                }
            } else {
                Write-Log "Mount bereits entfernt." "STEP"
            }
        } catch {
            if ($_.Exception.Message -match "NOT_FOUND|Could not find") {
                Write-Log "Mount bereits entfernt (404)." "STEP"
            } else {
                Write-Log "Unmount-Fehler: $($_.Exception.Message)" "WARN"
            }
        }
    } catch {
        # Fehlerbehandlung mit automatischem Cleanup des Mounts
        $stopwatch.Stop()
        $dbccResult = "ERROR"
        $dbccDetail = $_.Exception.Message
        $failCount++
        Write-Log "FEHLER: $dbccDetail" "ERROR"

        try {
            $mount = (Get-RscMssqlLiveMount -RscMssqlDatabase $rscDb -MountedDatabaseName $mountedDbName 6>$null | Select-Object -First 1)
            if ($mount) {
                Write-Log "Raeume Mount auf..." "STEP"
                Remove-RscMssqlLiveMount -MssqlLiveMount $mount -Force -ErrorAction Stop 6>$null | Out-Null
            }
        } catch {
            Write-Log "Mount-Cleanup fehlgeschlagen: $($_.Exception.Message)" "ERROR"
        }
    }

    # Ergebnis sammeln
    $results += [PSCustomObject]@{
        DatabaseName = $db.Name
        MountedAs    = $mountedDbName
        DbccResult   = $dbccResult
        DbccOutput   = $dbccDetail
        Duration     = [math]::Round($stopwatch.Elapsed.TotalSeconds)
        Timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    Write-Log ""
}

# --- Ergebnisse exportieren und Zusammenfassung ausgeben ---
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Log "=== Zusammenfassung ==="
Write-Log "Gesamt: $($databases.Count) | OK: $okCount | Uebersprungen: $skipCount | Fehler: $failCount"
Write-Log "CSV: $OutputPath"
Write-Log "Log: $logFile"
Write-Log "=== DBCC CHECKDB Lauf beendet ==="
$results | Format-Table -AutoSize
