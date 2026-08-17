#Requires -Version 3
#Requires -Modules RubrikSecurityCloud

Import-Module RubrikSecurityCloud
Connect-Rsc -ServiceAccountFile "$PSScriptRoot\cred_encrypted.xml" | Out-Null

function Get-RscMssqlDatabases {
    <#
    .SYNOPSIS
    Retrieves RscMssqlDatabase objects protected by Rubrik Security Cloud

    .DESCRIPTION
    This cmdlet uses the GQL query 'mssqlDatabases' to retrieve a list of MSSQL databases with a predetermined set of properties.

    .LINK
    Schema reference:
    https://rubrikinc.github.io/rubrik-api-documentation/schema/reference

    .EXAMPLE
    # Get all
    Get-RscMssqlDatabases

    .EXAMPLE
    # Get object with specific name
    Get-RscMssqlDatabases -Name "AdventureWorks2019"

    .EXAMPLE
    # Get objects by specifying part of a name
    Get-RscMssqlDatabases -Name "*Adventure*"
    #>

    [CmdletBinding(
        DefaultParameterSetName = "Name"
    )]
    Param(
        [Parameter(
            Mandatory = $false,
            ParameterSetName = "Id"
        )]
        [String]$Id,
        [Parameter(
            Mandatory = $false,
            ParameterSetName = "Name"
        )]
        [String]$Name,
        [Parameter(
            Position = 0,
            Mandatory = $false,
            ValueFromPipeline = $true,
            ParameterSetName = "Name"
        )]
        [RubrikSecurityCloud.Types.GlobalSlaReply]$Sla,
        [Parameter(
            Mandatory = $false,
            ValueFromPipeline = $true,
            ParameterSetName = "Name"
        )]
        [RubrikSecurityCloud.Types.Cluster]$Cluster,

        [Parameter(
            Mandatory = $false,
            ValueFromPipeline = $true,
            ParameterSetName = "Name"
        )]
        [RubrikSecurityCloud.Types.MssqlInstance]$MssqlInstance
    )

    Process {

        if ($Id) {
            $query = New-RscQuery -GqlQuery mssqlDatabase
            $query.var.filter = @()
            $query.Var.fid = $Id

            $result = Invoke-Rsc -Query $query
            $result
        } else {
            $query = New-RscQuery -GqlQuery mssqlDatabases
            $query.var.filter = @()

            if ($Name) {
                $nameFilter = New-Object -TypeName RubrikSecurityCloud.Types.Filter
                if ($name.Contains("*")) {
                    $name.Replace("*",'')
                    $nameFilter.Field = [RubrikSecurityCloud.Types.HierarchyFilterField]::REGEX
                    $nameFilter.texts = $Name.Replace("*",'')
                } else {
                    $nameFilter.Field = [RubrikSecurityCloud.Types.HierarchyFilterField]::NAME_EXACT_MATCH
                    $nameFilter.texts = $Name
                }
                $query.var.filter += $nameFilter
            }

            if ($Sla) {
                $slaFilter = New-Object -TypeName RubrikSecurityCloud.Types.Filter
                $slaFilter.Field = [RubrikSecurityCloud.Types.HierarchyFilterField]::EFFECTIVE_SLA
                $slaFilter.Texts = $Sla.id
                $query.var.filter += $slaFilter
            }

            if ($Cluster) {
                $clusterFilter = New-Object -TypeName RubrikSecurityCloud.Types.Filter
                $clusterFilter.Field = [RubrikSecurityCloud.Types.HierarchyFilterField]::CLUSTER_ID
                $clusterFilter.Texts = $Cluster.id
                $query.var.filter += $clusterFilter
            }

            if ($MssqlInstance) {
                $instanceFilter = New-Object -TypeName RubrikSecurityCloud.Types.Filter
                $instanceFilter.Field = [RubrikSecurityCloud.Types.HierarchyFilterField]::LOCATION
                $instanceFilter.Texts = $MssqlInstance.Name
                $query.var.filter += $instanceFilter
            }

            $result = Invoke-Rsc -Query $query
            $result.nodes | Where-Object { $_.Name -notin @('master', 'model', 'msdb', 'tempdb') -and $_.IsOnline -eq $true } | Select-Object -ExpandProperty Name
        }

    }
}

Get-RscMssqlDatabases
