<#
.SYNOPSIS
	Veeam Availability Console (VAC) Backup Policy Migration

.DESCRIPTION
	This script will allow you to migrate all Backup Policies
	from one VAC instance to another. This can be highly beneficial
	when consolidating VAC appliances.
	
.PARAMETER Source
	Source VAC Server IP or FQDN

.PARAMETER Source_UserName
	Source VAC Portal Administrator account username

.PARAMETER S_Password
	Source VAC Portal Administrator account password

.PARAMETER S_Credential
	Source VAC Portal Administrator account PS Credential Object

.PARAMETER S_Port
	Source VAC Rest API port

.PARAMETER Destination
	Destination VAC Server IP or FQDN

.PARAMETER D_UserName
	Destination VAC Portal Administrator account username

.PARAMETER D_Password
	Destination VAC Portal Administrator account password

.PARAMETER D_Credential
	Destination VAC Portal Administrator account PS Credential Object

.PARAMETER D_Port
	Destination VAC Rest API port

.PARAMETER AllowSelfSignedCerts
	Flag allowing self-signed certificates (insecure)

.OUTPUTS
	VAC-MigratePolicies returns a series of color coded text outputs showing success/warning/error

.EXAMPLE
	VAC-MigratePolicies.ps1 -VAC "vac.contoso.local" -VAC_Username "vac\jsmith" -VAC_Password "password"
		-SQL "sql.contoso.local" -SQL_Username "vac_ro" -SQL_Password "password"

	Description 
	-----------     
	Connect to the specified VAC/SQL server using the username/password specified

.EXAMPLE
	VAC-MigratePolicies.ps1 -VAC "vac.contoso.local" -VAC_Credential (Get-Credential)
		-SQL "sql.contoso.local" -SQL_Credential (Get-Credential)

	Description 
	-----------     
	PowerShell credentials object is supported

.EXAMPLE
	VAC-MigratePolicies.ps1 -VAC "vac.contoso.local" -Credential $cred_vac
		-SQL "sql.contoso.local" -SQL_Credential $cred_sql -Detailed

	Description 
	-----------     
	Includes a detailed list of all metrics (and then some) used to generate the monthly usage report

.EXAMPLE
	VAC-MigratePolicies.ps1 -VAC "vac.contoso.local" -VAC_Username "vac\jsmith" -VAC_Password "password"
		-SQL "sql.contoso.local" -SQL_Username "vac_ro" -SQL_Password "password" -Database "Custom_VAC_DB"

	Description 
	-----------     
	Connecting to a SQL Database other than the default "VAC"

.EXAMPLE
	VAC-MigratePolicies.ps1 -VAC "vac.contoso.local" -VAC_Username "vac\jsmith" -VAC_Password "password"
		-SQL "sql.contoso.local\MainInstance" -SQL_Username "vac_ro" -SQL_Password "password"

	Description 
	-----------     
	Connecting to a SQL server with multiple instances

.EXAMPLE
	VAC-MigratePolicies.ps1 -VAC "vac.contoso.local" -VAC_Username "vac\jsmith" -VAC_Password "password" -VAC_Port 9999
		-SQL "sql.contoso.local" -SQL_Username "vac_ro" -SQL_Password "password"

	Description 
	-----------     
	Connecting to a VAC server using a non-standard API port

.EXAMPLE
	VAC-MigratePolicies.ps1 -VAC "vac.contoso.local" -VAC_Username "vac\jsmith" -VAC_Password "password"
		-SQL "sql.contoso.local" -SQL_Username "vac_ro" -SQL_Password "password" -AllowSelfSignedCerts

	Description 
	-----------     
	Connecting to a VAC server that uses Self-Signed Certificates (insecure)

.NOTES
	NAME:  VAC-MigratePolicies.ps1
	VERSION: 0.4
	AUTHOR: Chris Arceneaux
	TWITTER: @chris_arceneaux
	GITHUB: https://github.com/carceneaux

.LINK
	https://arsano.ninja/

.LINK
	https://www.powershellgallery.com/packages/SqlServer
#>
#Requires -Modules SqlServer
[CmdletBinding(DefaultParametersetName="UsePass")]
param(
    [Parameter(Mandatory=$true)]
		[String] $Source,
	[Parameter(Mandatory=$true, ParameterSetName="UsePass")]
		[String] $S_Username,
	[Parameter(Mandatory=$true, ParameterSetName="UsePass")]
		[String] $S_Password = $True,
	[Parameter(Mandatory=$true, ParameterSetName="UseCred")]
		[System.Management.Automation.PSCredential]$S_Credential,
	[Parameter(Mandatory=$false)]
		[Int] $S_Port = 1281,
	[Parameter(Mandatory=$true)]
		[String] $Destination,
	[Parameter(Mandatory=$true, ParameterSetName="UsePass")]
		[String] $D_Username,
	[Parameter(Mandatory=$true, ParameterSetName="UsePass")]
		[String] $D_Password = $True,
	[Parameter(Mandatory=$true, ParameterSetName="UseCred")]
		[System.Management.Automation.PSCredential]$D_Credential,
	[Parameter(Mandatory=$false)]
		[Int] $D_Port = 1281,
	[Parameter(Mandatory=$false)]
		[Switch] $AllowSelfSignedCerts
)

Function Get-AuthToken{
	param(
		[String] $vac,
		[String] $username,
		[String] $password,
		[String] $port
	)

	# POST - /token - Authorization
	[String] $url = "https://" + $vac + ":" + $port + "/token"
	Write-Verbose "Authorization Url: $url"
	$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
	$headers.Add("Content-Type", "application/x-www-form-urlencoded")
	$body = "grant_type=password&username=$username&password=$password"
	try {
		$response = Invoke-RestMethod $url -Method 'POST' -Headers $headers -Body $body -ErrorAction Stop
		return $response.access_token
	} catch {
		Write-Error "`nERROR: Authorization Failed! - $vac"
		Exit 1
	}
	# End Authorization

}

Function Get-BackupPolicies{
	param(
		[String] $vac,
		[String] $port,
		[String] $token
	)

	# GET /v2/backupPolicies
	[String] $url = "https://" + $vac + ":" + $port + "/v2/backupPolicies" +
		'?$filter=' + "type%20ne%20'Predefined'" # Filters out predefined policies
	Write-Verbose "VAC Get Backup Policies Url: $url"
	$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
	$headers.Add("Authorization", "Bearer $token")
	try {
		$response = Invoke-RestMethod $url -Method 'GET' -Headers $headers -ErrorAction Stop
		return $response
	} catch {
		Write-Error "`nERROR: Retrieving Backup Policies - $vac - Failed!"
		Exit 1
	}
	# End Backup Policies Retrieval

}

Function Get-DetailedPolicyInfo{
	param(
		[String] $vac,
		[String] $port,
		[String] $token,
		[String] $policyId
	)

	# GET /v2/backupPolicies/{id}
	[String] $url = "https://" + $vac + ":" + $port + "/v2/backupPolicies/$policyId"
	Write-Verbose "VAC Get Detailed Policy Url: $url"
	$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
	$headers.Add("Authorization", "Bearer $token")
	try {
		$response = Invoke-RestMethod $url -Method 'GET' -Headers $headers -ErrorAction Stop
		return $response
	} catch {
		Write-Error "`nERROR: Retrieving Detailed Policy Info - $policyId - Failed!"
		Exit 1
	}
	# End Backup Policies Retrieval

}

Function New-BackupPolicy{
	param(
		[String] $vac,
		[String] $port,
		[String] $token,
		[String] $policy
	)

	# POST /v2/backupPolicies
	[String] $url = "https://" + $vac + ":" + $port + "/v2/backupPolicies"
	Write-Verbose "VAC New Backup Policy Url: $url"
	$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
	$headers.Add("Authorization", "Bearer $token")
	$headers.Add("Content-Type", "application/json")
	try {
		$response = Invoke-RestMethod $url -Method 'POST' -Headers $headers -Body $policy -ErrorAction Stop
		return $response
	} catch {
		Write-Error "`nERROR: Creating Backup Policy Failed!`n$policy"
		Exit 1
	}
	# End New Backup Policy

}

function Write-ColorOutput($ForegroundColor){
    # save the current color
    $fc = $host.UI.RawUI.ForegroundColor

    # set the new color
    $host.UI.RawUI.ForegroundColor = $ForegroundColor

    # output
    if ($args) {
        Write-Output $args
    }
    else {
        $input | Write-Output
    }

    # restore the original color
    $host.UI.RawUI.ForegroundColor = $fc
}

# Allow Self-Signed Certificates (not recommended)
if ($AllowSelfSignedCerts){
	add-type -TypeDefinition  @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                return true;
            }
        }
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}

# Enables use of PSCredential objects
if ($S_Credential){
	$s_username = $S_Credential.GetNetworkCredential().Username
	$s_password = $S_Credential.GetNetworkCredential().Password
}
if ($D_Credential){
	$d_username = $D_Credential.GetNetworkCredential().Username
	$d_password = $D_Credential.GetNetworkCredential().Password
}

# Authenticating to both VAC servers
$s_token = Get-AuthToken -VAC $Source -Username $s_username -Password $s_password -Port $s_port
#$d_token = Get-AuthToken -VAC $Destination -Username $d_username -Password $d_password -Port $d_port

# Retrieving Source Backup Policies
$s_policies = Get-BackupPolicies -VAC $Source -Port $s_port -Token $s_token

# Retrieving Detailed Policy Information
$policyInfo = @()
foreach ($policy in $s_policies){
	$response = Get-DetailedPolicyInfo -VAC $Source -Port $s_port -Token $s_token -PolicyID $policy.id
	# Removing uncessary properties
	$filtered = $response | Select-Object -Property * -ExcludeProperty id, modifiedDate, tenantsCount, type, createdBy, osType, _links
	$policyInfo += $filtered
}

# Retrieving Destination Backup Policies
$d_token = Get-AuthToken -VAC $Destination -Username $d_username -Password $d_password -Port $d_port
$d_policies = Get-BackupPolicies -VAC $Destination -Port $d_port -Token $d_token

# Comparing policies by name to see if there are any matches
$compared = Compare-Object -IncludeEqual -ExcludeDifferent $s_policies.name $d_policies.name
#$compared = Select-Object @{n='InputObject';e={'Lobster-Laptop'}} -InputObject '' # for debugging purposes
$copyAll = $true # boolean to determine if all of the policies are copied to the destination VAC server
if ($compared.Count -gt 0){
	Write-Warning "One or more Backup Policies with the same name already exist on the Destination VAC server and will NOT be migrated."
	Write-Output ""
	$copyAll = $false
}

# Creating new Backup Policies on Destination VAC server
foreach ($policy in $policyInfo){
	if ($copyAll -eq $true){ # no duplicate policies found
		# $name = $policy.name
		# $name = "testing_$name"
		# $policy.name = $name # adding pseudo policy name for debugging and avoiding duplicates
		$response = New-BackupPolicy -VAC $Destination -Port $d_port -Token $d_token -Policy ($policy | ConvertTo-Json)
		Write-ColorOutput green "Policy created successfully: $($policy.name)"
	} elseif ($policy.name -notin $compared.InputObject) { # filtering out duplicate policies
		# $name = $policy.name
		# $name = "testing_$name"
		# $policy.name = $name # adding pseudo policy name for debugging and avoiding duplicates
		$response = New-BackupPolicy -VAC $Destination -Port $d_port -Token $d_token -Policy ($policy | ConvertTo-Json)
		Write-ColorOutput green "Policy created successfully: $($policy.name)"
	} else { # skipping duplicate policies
		Write-ColorOutput yellow "Policy marked duplicate. Skipping: $($policy.name)"
	}
	
}
