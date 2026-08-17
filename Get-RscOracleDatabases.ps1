#Requires -Version 5.1

param(
    [string]$ServiceAccountFile = "$PSScriptRoot\cred.json"
)

$serviceAccount = Get-Content -Path $ServiceAccountFile -Raw | ConvertFrom-Json

$baseUrl = $serviceAccount.access_token_uri -replace '/api/client_token$', ''

$tokenBody = @{
    client_id     = $serviceAccount.client_id
    client_secret = $serviceAccount.client_secret
} | ConvertTo-Json

$tokenResponse = Invoke-RestMethod -Uri $serviceAccount.access_token_uri -Method Post -Body $tokenBody -ContentType "application/json"
$accessToken = $tokenResponse.access_token

$graphqlUri = "$baseUrl/api/graphql"
$headers = @{
    Authorization = "Bearer $accessToken"
    Content_Type  = "application/json"
}

$allDatabases = @()
$hasNextPage = $true
$endCursor = $null

while ($hasNextPage) {
    $afterClause = if ($endCursor) { ", after: `"$endCursor`"" } else { "" }

    $query = @{
        query = @"
{
  oracleDatabases(first: 200$afterClause) {
    nodes {
      id
      name
      numInstances
      slaAssignment
      effectiveSlaDomain {
        name
      }
      objectType
      physicalPath {
        name
        objectType
      }
      cluster {
        name
      }
    }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}
"@
    } | ConvertTo-Json

    $response = Invoke-RestMethod -Uri $graphqlUri -Method Post -Headers $headers -Body $query -ContentType "application/json"

    if ($response.errors) {
        Write-Error "GraphQL-Fehler: $($response.errors | ConvertTo-Json -Depth 5)"
        exit 1
    }

    $data = $response.data.oracleDatabases
    $allDatabases += $data.nodes
    $hasNextPage = $data.pageInfo.hasNextPage
    $endCursor = $data.pageInfo.endCursor
}

Write-Host "`nOracle Datenbanken in Rubrik RSC: $($allDatabases.Count)`n" -ForegroundColor Cyan

$allDatabases | ForEach-Object {
    [PSCustomObject]@{
        Name      = $_.name
        Host      = ($_.physicalPath | Where-Object { $_.objectType -eq "PhysicalHost" } | Select-Object -First 1).name
        Cluster   = $_.cluster.name
        SLA       = $_.effectiveSlaDomain.name
        Instanzen = $_.numInstances
        Typ       = $_.objectType
    }
} | Format-Table -AutoSize
