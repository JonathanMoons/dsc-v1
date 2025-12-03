#requires -Version 7.0
#requires -Modules Az.Accounts, Az.PolicyInsights, Az.ResourceGraph, Az.GuestConfiguration
<#!
.SYNOPSIS
    Provides quick visibility into Azure Policy compliance state and guest configuration assignment health
    for the ContosoSqlLogin package.

.DESCRIPTION
    Use this script from any PowerShell 7 session that can authenticate to Azure. It ensures the Az modules
    needed for policy insights and Resource Graph are installed, then gathers:
      * The latest Azure Policy states for the specified policy assignment.
      * Guest configuration assignment details for an optional VM.
      * A Resource Graph summary of machines failing the assignment and their reason phrases.

.EXAMPLE
    pwsh ./DebugTrackerStatus.ps1 -SubscriptionId '<sub-guid>' -PolicyAssignmentName 'ContosoSqlLogin-Assignment'

.EXAMPLE
    pwsh ./DebugTrackerStatus.ps1 -SubscriptionId '<sub-guid>' -ResourceGroupName 'rg-contoso-sql' -VmName 'sql-login-vm01'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [Parameter()]
    [string] $PolicyAssignmentName = 'ContosoSqlLogin-Assignment',

    [Parameter()]
    [string] $ConfigurationName = 'ContosoSqlLogin',

    [Parameter()]
    [string] $ResourceGroupName,

    [Parameter()]
    [string] $VmName,

    [Parameter()]
    [int] $Top = 20,

    [Parameter()]
    [switch] $IncludeCompliant
)

Set-StrictMode -Version Latest

function Ensure-Module {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Version] $MinimumVersion,
        [ValidateSet('CurrentUser', 'AllUsers')] [string] $Scope = 'CurrentUser'
    )

    $installed = Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -ge $MinimumVersion }
    if ($installed) {
        return
    }

    Write-Host "Installing module $Name" -ForegroundColor Yellow
    Install-Module -Name $Name -Scope $Scope -MinimumVersion $MinimumVersion.ToString() -Force -ErrorAction Stop
}

$moduleRequirements = @(
    @{ Name = 'Az.Accounts';       MinimumVersion = [Version]'2.13.1' },
    @{ Name = 'Az.PolicyInsights'; MinimumVersion = [Version]'1.6.0' },
    @{ Name = 'Az.ResourceGraph';  MinimumVersion = [Version]'1.2.0' },
    @{ Name = 'Az.GuestConfiguration'; MinimumVersion = [Version]'0.11.0' }
)

foreach ($module in $moduleRequirements) {
    Ensure-Module @module
    Import-Module $module.Name -ErrorAction Stop | Out-Null
}

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Host "No Az context detected. Calling Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
    $context = Get-AzContext -ErrorAction Stop
}

if ($context.Subscription.Id -ne $SubscriptionId) {
    Write-Host "Switching Az context to $SubscriptionId" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
}

$filter = if ($IncludeCompliant) { $null } else { "ComplianceState eq 'NonCompliant'" }
Write-Host "Querying Azure Policy states for assignment '$PolicyAssignmentName'" -ForegroundColor Cyan
$policyStates = Get-AzPolicyState -SubscriptionId $SubscriptionId -PolicyAssignmentName $PolicyAssignmentName `
    -Top $Top -OrderBy 'Timestamp desc' -Filter $filter -ErrorAction SilentlyContinue

if ($policyStates) {
    $policyStates | Select-Object Timestamp, ComplianceState, ResourceId, PolicyDefinitionId | Format-Table -AutoSize
} else {
    Write-Warning "No policy states were returned. Validate the assignment name or wait for the next compliance cycle."
}

if ($ResourceGroupName -and $VmName) {
    Write-Host "Getting guest configuration assignment details for VM $VmName" -ForegroundColor Cyan
    $assignment = Get-AzGuestConfigurationAssignment -ResourceGroupName $ResourceGroupName -MachineName $VmName -Name $ConfigurationName -ErrorAction SilentlyContinue
    if ($assignment) {
        $assignment | Select-Object Name, ComplianceStatus, AssignmentState, LastComplianceStatusChangedTime, ReportId | Format-List
    } else {
        Write-Warning "No guest configuration assignment named '$ConfigurationName' found on $VmName."
    }
}

$statusClause = if ($IncludeCompliant) { '' } else { "| where status == 'NonCompliant'" }
$query = @"
GuestConfigurationResources
| where type =~ 'microsoft.guestconfiguration/guestconfigurationassignments'
| where name =~ '$ConfigurationName'
| extend machine = tostring(split(properties.targetResourceId,'/')[(-1)])
| extend scope = tostring(split(properties.targetResourceId,'/')[2])
| extend status = tostring(properties.complianceStatus)
| extend report = properties.latestAssignmentReport
| extend reasons = case(isnull(report.resources[0].reasons[0].phrase), 'N/A', tostring(report.resources[0].reasons[0].phrase))
$statusClause
| project machine, status, reason = reasons, assignment = name, scope
| limit $Top
"@

Write-Host "Running Azure Resource Graph query for assignment breakdown" -ForegroundColor Cyan
try {
    $graphResults = Search-AzGraph -Query $query -First $Top -ErrorAction Stop
    if ($graphResults) {
        $graphResults | Format-Table -AutoSize
    } else {
        Write-Host "Resource Graph query returned no rows." -ForegroundColor Yellow
    }
} catch {
    Write-Warning "Resource Graph query failed: $($_.Exception.Message)"
}

return [PSCustomObject]@{
    PolicyAssignment = $PolicyAssignmentName
    RecordsReturned  = ($policyStates | Measure-Object).Count
    GraphRows        = ($graphResults | Measure-Object).Count
}
