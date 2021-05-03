# 0. Connect to Azure account
# it will prompt for the username and password
# once it will display details of the account
Connect-AzAccount
<#
Account            SubscriptionName            TenantId                Environment
-------            ----------------            --------                -----------
mikey@bronowski.it MSDN Platforms Subscription xxxxxxxx-xxxx-xxxx-xxxx AzureCloud 
#>


# 1. Create a resource group for each resource
# 
$resourceGroupArgs = @{
    Name = "SQLServerCentral"
    Location = "UK South"
    Confirm = $false
    Force = $true
}
$resourceGroup = New-AzResourceGroup @resourceGroupArgs
<#
ResourceGroupName : SQLServerCentral
Location          : uksouth
ProvisioningState : Succeeded
Tags              : 
ResourceId        : /subscriptions/xxxxxxxx-xxxx-xxxx-xxxx/resourceGroups/SQLServerCentral
#>


# 2. Create elastic job database
# setup credentials for the new Azure SQL Server
$azCredentials = (Get-Credential -UserName AzureAdmin -Message "Password please")

# 2.1. Configure Azure SQL Server
$serverArgs = @{
    ResourceGroupName = $resourceGroup.ResourceGroupName
    Location = $resourceGroup.Location
    SqlAdministratorCredentials = $azCredentials
}
# job server
$server0 = New-AzSqlServer @serverArgs -ServerName sqlservercentral-0
<# Example of one of the server's details
ResourceGroupName        : SQLServerCentral
ServerName               : sqlservercentral-0
Location                 : uksouth
SqlAdministratorLogin    : AzureAdmin
SqlAdministratorPassword : 
ServerVersion            : 12.0
Tags                     : 
Identity                 : 
FullyQualifiedDomainName : sqlserversentral-0.database.windows.net
ResourceId               : /subscriptions/xxxxxxxx-xxxx-xxxx-xxxx/resourceGroups/SQLServerCentral/providers/Microsoft.Sql/servers/sqlserversentral-0
MinimalTlsVersion        : 
PublicNetworkAccess      : Enabled
#>


# 2.2. Create Azure SQL Database at minimum S0
$jobDbArgs = @{
    DatabaseName                  = "JobDatabase"
    ServerName                    = $server0.ServerName
    ResourceGroupName             = $resourceGroup.ResourceGroupName
    Edition                       = "Standard"
    RequestedServiceObjectiveName = "S0"
    MaxSizeBytes                  = 2GB
}
$jobDb = New-AzSqlDatabase @jobDbArgs


# 3. Create Elastic Job agent    
$jobAgent = $jobDb | New-AzSqlElasticJobAgent -Name 'sqlservercentralagent'

<#
ResourceGroupName ServerName         DatabaseName AgentName            State Tags
----------------- ----------         ------------ ---------            ----- ----
SQLServerCentral sqlservercentral-0 JobDatabase  sqlservercentralagent Ready     
#>


# 4.1. Create target servers
# using the same parameters as for the job server
# target servers
$server1 = New-AzSqlServer @serverArgs -ServerName sqlservercentral-1
$server2 = New-AzSqlServer @serverArgs -ServerName sqlservercentral-2


# 4.2. Create Azure SQL Databases (Basic edition)
$targetDbArgs = @{
    ResourceGroupName = $resourceGroup.ResourceGroupName
    Edition = "Basic"
    MaxSizeBytes = 1GB
}
    
# four databases on the first server
$targetDb1 = New-AzSqlDatabase @targetDbArgs -DatabaseName db1 -ServerName $server1.ServerName
$targetDb11 = New-AzSqlDatabase @targetDbArgs -DatabaseName db11 -ServerName $server1.ServerName
$targetDb12 = New-AzSqlDatabase @targetDbArgs -DatabaseName db12 -ServerName $server1.ServerName
$targetDb13 = New-AzSqlDatabase @targetDbArgs -DatabaseName db13 -ServerName $server1.ServerName

# single database on the second server
$targetDb2 = New-AzSqlDatabase @targetDbArgs -DatabaseName db2 -ServerName $server2.ServerName


# 5. Add firewall rules
# https://www.scriptinglibrary.com/languages/powershell/how-to-get-your-external-ip-with-powershell-core-using-a-restapi/
$myIp = Invoke-RestMethod -Uri https://api.ipify.org
# 5.1. Firewall rule to allow connections from my own IP address
$firewallMyIpArgs = @{
    FirewallRuleName = "Firewall rule - Let me in"
    StartIpAddress = $myIp 
    EndIpAddress = $myIp 
    ResourceGroupName = $resourceGroup.ResourceGroupName
}
# set up the rules
$firewallMyIp0 = New-AzSqlServerFirewallRule @firewallMyIpArgs -ServerName $server0.ServerName
$firewallMyIp1 = New-AzSqlServerFirewallRule @firewallMyIpArgs -ServerName $server1.ServerName
$firewallMyIp1 = New-AzSqlServerFirewallRule @firewallMyIpArgs -ServerName $server2.ServerName

# 5.2. firewall rule to allow connections beteween Azure resources
$firewallAzureArgs = @{
    ResourceGroupName = $resourceGroup.ResourceGroupName
    AllowAllAzureIPs = $true
}
# set up the rules
$firewallAzure0 = New-AzSqlServerFirewallRule @firewallAzureArgs -ServerName $server0.ServerName
$firewallAzure1 = New-AzSqlServerFirewallRule @firewallAzureArgs -ServerName $server1.ServerName
$firewallAzure2 = New-AzSqlServerFirewallRule @firewallAzureArgs -ServerName $server2.ServerName


# 6. Create two database scoped credentials in the job database
# set the password
$password = Read-Host
$loginPasswordSecure = (ConvertTo-SecureString -String $password -AsPlainText -Force)

# configure the refresh credential
$refreshCred = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList "refresh_credential", $loginPasswordSecure
$refreshCred = $jobAgent | New-AzSqlElasticJobCredential -Name "refresh_credential" -Credential $refreshCred

# configure the job execution credential
$jobCred = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList "job_credential", $loginPasswordSecure
$jobCred = $jobAgent | New-AzSqlElasticJobCredential -Name "job_credential" -Credential $jobCred


# 7. Create logins and users in target servers
# 7.1. Create the login for both credentials: refresh and job execution
# In the master database on both servers
$targetLoginUserArgs = @{
  'Database' = 'master'
  'SqlInstance' =  @($server1.FullyQualifiedDomainName, $server2.FullyQualifiedDomainName)
  'SqlCredential' = $azCredentials
  'Query' = "CREATE LOGIN refresh_credential WITH PASSWORD='$($password)';"
}

# using dbatools Invoke-DbaQuery as New-DbaLogin does not support Azure SQL Database
# create a login for refresh credential
Invoke-DbaQuery @targetLoginUserArgs

# create a login for job execution credential
$targetLoginUserArgs.Query = "CREATE LOGIN job_credential WITH PASSWORD='$($password)';"
Invoke-DbaQuery @targetLoginUserArgs


# 7.2. Create users for both credentials
# create a user for refresh credential in master database
$targetLoginUserArgs.Query = "CREATE USER refresh_credential FROM LOGIN refresh_credential;"
Invoke-DbaQuery @targetLoginUserArgs

# create a user for job execution credential in each target database
# get the database list on target servers with Get-DbaDatabase from dbatools
$targetDatabases = Get-DbaDatabase -SqlInstance $server1.FullyQualifiedDomainName, $server2.FullyQualifiedDomainName -SqlCredential $azCredentials # -ExcludeSystem
# loop through all the databases and create user + extra permission
$targetDatabases | % {
    $targetLoginUserArgs.SqlInstance = $_.ComputerName
    $targetLoginUserArgs.Database = $_.Name
    $targetLoginUserArgs.Query = "CREATE USER job_credential FROM LOGIN job_credential;"
    $targetLoginUserArgs.Query += "ALTER ROLE db_ddladmin ADD MEMBER [job_credential];"
    Invoke-DbaQuery @targetLoginUserArgs
}


# 8. Create target groups

# 8.1. whole servers - this will contain both servers, i.e. all databases on those servers
$serverGroup1 = $jobAgent | New-AzSqlElasticJobTargetGroup -Name 'TargetGroup1'
$serverGroup1 | Add-AzSqlElasticJobTarget -ServerName $server1.FullyQualifiedDomainName -RefreshCredentialName $refreshCred.CredentialName
$serverGroup1 | Add-AzSqlElasticJobTarget -ServerName $server2.FullyQualifiedDomainName -RefreshCredentialName $refreshCred.CredentialName


# 8.2. selected databases - one database per server
$serverGroup2 = $jobAgent | New-AzSqlElasticJobTargetGroup -Name 'TargetGroup2'
$serverGroup2 | Add-AzSqlElasticJobTarget -ServerName $server1.FullyQualifiedDomainName -DatabaseName $targetDb1.DatabaseName
$serverGroup2 | Add-AzSqlElasticJobTarget -ServerName $server2.FullyQualifiedDomainName -DatabaseName $targetDb2.DatabaseName


# 8.3. exclude database from a server
$serverGroup3 = $jobAgent | New-AzSqlElasticJobTargetGroup -Name 'TargetGroup3'
$($server1 | Get-AzSqlDatabase) | % { $serverGroup3 | Add-AzSqlElasticJobTarget -ServerName $server1.FullyQualifiedDomainName -DatabaseName $_.DatabaseName }
$serverGroup3 | Add-AzSqlElasticJobTarget -ServerName $server1.FullyQualifiedDomainName -DatabaseName $targetDb1.DatabaseName -Exclude
$serverGroup3 | Add-AzSqlElasticJobTarget -ServerName $server1.FullyQualifiedDomainName -DatabaseName master -Exclude


# 9. Create elastic job

# 9.1. Create a job and setup the schedule
$jobName = "Job"
$job = $jobAgent | New-AzSqlElasticJob -Name $jobName -RunOnce

# 9.2. Add steps to the job

# each job runs different T-SQL command

$sqlText1 = "IF NOT EXISTS (SELECT * FROM sys.tables WHERE object_id = object_id('Step1Table')) CREATE TABLE [dbo].[Step1Table]([TestId] [int] NOT NULL);"
$sqlText2 = "IF NOT EXISTS (SELECT * FROM sys.tables WHERE object_id = object_id('Step2Table')) CREATE TABLE [dbo].[Step2Table]([TestId] [int] NOT NULL);"
$sqlText3 = "IF NOT EXISTS (SELECT * FROM sys.tables WHERE object_id = object_id('Step3Table')) CREATE TABLE [dbo].[Step3Table]([TestId] [int] NOT NULL);"

# add the steps with target group assignment and command to be executed
$job | Add-AzSqlElasticJobStep -Name "step1" -TargetGroupName $serverGroup1.TargetGroupName -CredentialName $jobCred.CredentialName -CommandText $sqlText1
$job | Add-AzSqlElasticJobStep -Name "step2" -TargetGroupName $serverGroup2.TargetGroupName -CredentialName $jobCred.CredentialName -CommandText $sqlText2
$job | Add-AzSqlElasticJobStep -Name "step3" -TargetGroupName $serverGroup3.TargetGroupName -CredentialName $jobCred.CredentialName -CommandText $sqlText3


$jobExecution = $job | Start-AzSqlElasticJob
$jobExecution | Get-AzSqlElasticJobStepExecution



$tables = Get-DbaDbTable -SqlInstance $server1.FullyQualifiedDomainName, $server2.FullyQualifiedDomainName -SqlCredential $azCredentials -Table Step1Table, Step2Table, Step3Table 
$tables |  select ComputerName, Database, Name |  Format-Table | Sort-Object Name



