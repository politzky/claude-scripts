# Rubrik RSC PowerShell Scripts

PowerShell-Skripte zur Automatisierung von Rubrik Security Cloud (RSC) und Rubrik CDM Aufgaben.

## Voraussetzungen

- **PowerShell** 5.1 oder hoher
- **RubrikSecurityCloud** PowerShell Modul (fuer MSSQL- und Oracle-Skripte)
- **SqlServer** PowerShell Modul (fuer DBCC CHECKDB)
- Netzwerkzugriff auf die Rubrik RSC API
- Ein RSC Service Account (JSON-Datei)

### Module installieren

```powershell
Install-Module RubrikSecurityCloud -Scope CurrentUser
Install-Module SqlServer -Scope CurrentUser
```

### Service Account einrichten

1. In Rubrik RSC einloggen
2. Unter **Settings > API Access** einen neuen Service Account anlegen
3. Die JSON-Datei herunterladen und als `cred.json` im Skript-Verzeichnis ablegen
4. Verschluesseltes Credential-File erstellen:

```powershell
Import-Module RubrikSecurityCloud
Set-RscServiceAccountFile -InputFilePath .\cred.json -OutputFilePath .\cred_encrypted.xml
```

Die `cred.json` hat folgendes Format:

```json
{
  "client_id": "client|...",
  "client_secret": "...",
  "name": "spo",
  "access_token_uri": "https://<cluster>.my.rubrik.com/api/client_token"
}
```

> **Hinweis:** `cred.json` und `cred_encrypted.xml` enthalten Zugangsdaten und sind per `.gitignore` vom Repository ausgeschlossen.

---

## Skripte

### Invoke-RscMssqlDbccCheck.ps1

Fuehrt automatisiert DBCC CHECKDB auf allen (oder ausgewaehlten) MSSQL-Datenbanken durch. Jede Datenbank wird per Rubrik Live Mount an eine Ziel-SQL-Server-Instanz gemountet, DBCC CHECKDB ausgefuehrt und der Mount anschliessend entfernt.

**Ablauf pro Datenbank:**
1. Recovery Point (letztes Full Backup) ermitteln
2. Live Mount auf Ziel-SQL-Server erstellen
3. Warten bis DB auf SQL Server online ist
4. DBCC CHECKDB (PHYSICAL_ONLY) ausfuehren
5. Live Mount entfernen
6. Ergebnis in CSV und Log schreiben

**Voraussetzungen:**
- RubrikSecurityCloud Modul
- SqlServer Modul
- Windows-Authentifizierung mit sysadmin-Rechten auf der Ziel-SQL-Instanz
- Der ausfuehrende Account braucht Rechte sowohl in RSC als auch auf dem Ziel-SQL-Server

**Parameter:**

| Parameter | Pflicht | Default | Beschreibung |
|-----------|---------|---------|-------------|
| `-TargetHostName` | Ja | - | Hostname des Ziel-SQL-Servers (wie in RSC registriert) |
| `-InstanceName` | Ja | - | Name der SQL Server Instanz auf dem Zielhost |
| `-SqlClusterName` | Nein | - | Virtueller SQL Server Name bei Failover-Clustern (fuer SQL-Verbindung statt TargetHostName) |
| `-ClusterName` | Nein | (auto) | Rubrik Cluster-Name. Ohne Angabe wird der Cluster der Ziel-Instanz verwendet |
| `-DatabaseName` | Nein | (alle) | Eine oder mehrere DBs (kommasepariert). Ohne Angabe werden alle Online-DBs geprueft |
| `-EstimateOnly` | Nein | `$false` | Schnelltest: fuehrt nur DBCC ESTIMATEONLY aus (Sekunden statt Minuten) |
| `-OutputPath` | Nein | `.\DBCC_Results_<timestamp>.csv` | Pfad fuer die CSV-Ergebnisdatei |
| `-LogDir` | Nein | `.\logs` | Verzeichnis fuer Log-Dateien |
| `-MaxLogFiles` | Nein | `7` | Maximale Anzahl Log-Dateien (aeltere werden automatisch geloescht) |

**Beispiele:**

```powershell
# Alle Online-Datenbanken pruefen (ohne System-DBs)
.\Invoke-RscMssqlDbccCheck.ps1 -TargetHostName "sqlhost01" -InstanceName "MSSQLSERVER"

# SQL Server Failover-Cluster (TargetHostName = Windows-Cluster fuer RSC, SqlClusterName = SQL-Listener)
.\Invoke-RscMssqlDbccCheck.ps1 -TargetHostName "wincluster01" -InstanceName "SQLINST1" -SqlClusterName "sqlcluster01"

# Nur Datenbanken eines bestimmten Rubrik Clusters
.\Invoke-RscMssqlDbccCheck.ps1 -TargetHostName "sqlhost01" -InstanceName "INST1" -ClusterName "Cluster-A"

# Einzelne Datenbank pruefen
.\Invoke-RscMssqlDbccCheck.ps1 -TargetHostName "sqlhost01" -InstanceName "INST1" -DatabaseName "AdventureWorks2019"

# Mehrere Datenbanken pruefen
.\Invoke-RscMssqlDbccCheck.ps1 -TargetHostName "sqlhost01" -InstanceName "INST1" -DatabaseName "DB1","DB2","DB3"

# Schnelltest mit EstimateOnly
.\Invoke-RscMssqlDbccCheck.ps1 -TargetHostName "sqlhost01" -InstanceName "INST1" -DatabaseName "AdventureWorks2019" -EstimateOnly
```

**Ausgabe:**

- Terminal: Fortschritt und Ergebnisse pro DB in Echtzeit
- CSV-Datei mit Spalten: DatabaseName, MountedAs, DbccResult, DbccOutput, Duration, Timestamp
- Log-Datei unter `.\logs\` mit vollstaendigem Ablaufprotokoll (rotiert nach 7 Durchlaeufen)

---

### Get-RscMssqlDatabases.ps1

Listet alle Online-MSSQL-Datenbanken in Rubrik RSC auf (ohne Systemdatenbanken).

**Beispiele:**

```powershell
# Alle Online-DBs auflisten
.\Get-RscMssqlDatabases.ps1
```

**Ausgabe:** Liste der Datenbanknamen (nur Name, keine System-DBs, nur Online).

---

### Get-RscOracleDatabases.ps1

Listet alle Oracle-Datenbanken in Rubrik RSC auf (nutzt die REST API direkt, nicht das RSC PowerShell Modul).

**Voraussetzungen:**
- `cred.json` im gleichen Verzeichnis (unverschluesselt, da direkte REST-Aufrufe)

**Beispiele:**

```powershell
.\Get-RscOracleDatabases.ps1

# Mit anderem Service Account
.\Get-RscOracleDatabases.ps1 -ServiceAccountFile "C:\pfad\zu\andere.json"
```

**Ausgabe:** Tabellarische Uebersicht mit Name, Host, Cluster, SLA, Instanzen und Typ.

---

### Get-RubrikBackupFailures.ps1

Liest fehlgeschlagene Backup-Events aus einem Rubrik CDM Cluster aus (nutzt die CDM REST API v1, nicht RSC).

**Voraussetzungen:**
- Rubrik CDM API Token (kein RSC Service Account)
- Netzwerkzugriff auf den Rubrik CDM Cluster

**Parameter:**

| Parameter | Pflicht | Beschreibung |
|-----------|---------|-------------|
| `-Server` | Ja | Rubrik Cluster FQDN oder IP |
| `-ApiToken` | Ja | Rubrik CDM API Token |
| `-Hours` | Nein (24) | Zeitraum in Stunden |
| `-ObjectType` | Nein | Filter: VmwareVm, Mssql, Fileset, NutanixVm, HypervVm, etc. |

**Beispiele:**

```powershell
# Alle Failures der letzten 24 Stunden
.\Get-RubrikBackupFailures.ps1 -Server "rubrik.domain.com" -ApiToken "eyJ..."

# Nur MSSQL Failures der letzten 48 Stunden
.\Get-RubrikBackupFailures.ps1 -Server "rubrik.domain.com" -ApiToken "eyJ..." -Hours 48 -ObjectType Mssql
```

---

## Sicherheit

- Credential-Dateien (`cred.json`, `cred_encrypted.xml`) sind per `.gitignore` ausgeschlossen
- DBCC CHECKDB nutzt Windows-Authentifizierung (kein Passwort im Skript)
- RSC-Authentifizierung laeuft ueber verschluesselte Service Account Dateien (`cred_encrypted.xml`)
- CDM API Token muss als Parameter uebergeben werden (nicht gespeichert)

## Lizenz

MIT
