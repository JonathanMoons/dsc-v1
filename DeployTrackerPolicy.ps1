#requires -Version 7.0
#requires -Modules Az.Accounts, Az.Resources, Az.Storage, GuestConfiguration
<#!
.SYNOPSIS
    Uploads the Contoso tracker Guest Configuration package to Azure Storage, generates an Azure Policy definition,
    and assigns it so Azure Machine Configuration can deploy/remediate the package.

.DESCRIPTION
    Run this script in PowerShell 7 from a machine that already compiled the MOF (CreateTrackerMOF.ps1) and produced
    a package (PackageTrackerConfig.ps1). The script performs the following steps:
      1. Ensures the required Az and GuestConfiguration modules are present (installs into CurrentUser if missing).
      2. Uploads the specified package ZIP to the target storage account/container.
      3. Calls New-GuestConfigurationPolicy to emit a policy definition JSON for audit or deploy semantics.
      4. Creates (or updates) the Azure Policy definition with New-AzPolicyDefinition.
      5. Assigns the policy at the requested scope with a system-assigned identity, enabling machine configuration.

    You must already be able to authenticate with Connect-AzAccount and have permissions to read/write policy and
    the destination storage account. If your subscription enforces branch protection on policy definitions or uses
    a central automation account, adapt the script as needed.

.EXAMPLE
    pwsh ./DeployTrackerPolicy.ps1 -SubscriptionId '<sub-guid>' -ResourceGroupName 'rg-tracker' \
        -StorageAccountName 'trackerconfigstore' -StorageContainerName 'guestconfig' \
        -PolicyDefinitionName 'TrackerDSC2019SFTP' -PolicyAssignmentName 'TrackerDSC2019SFTP-Assignment'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $StorageAccountName,

    [Parameter()]
    [string] $StorageContainerName = 'guestconfiguration',

    [Parameter()]
    [string] $PackagePath,

    [Parameter()]
    [string] $ConfigurationName = 'TrackerDSC2019SFTP',

    [Parameter()]
    [ValidateSet('Audit', 'AuditAndSet')]
    [string] $AssignmentType = 'AuditAndSet',

    [Parameter()]
    [string] $PolicyDefinitionName = 'TrackerDSC2019SFTP',

    [Parameter()]
    [string] $PolicyAssignmentName = 'TrackerDSC2019SFTP-Assignment',

    [Parameter()]
    [string] $PolicyDisplayName = 'TrackerDSC2019SFTP Guest Configuration',

    [Parameter()]
    [string] $PolicyDescription = 'Ensures the Contoso SQL service account exists and stays enabled on managed hosts.',

    [Parameter()]
    [string] $PolicyVersion = '1.0.0',

    [Parameter()]
    [string] $PolicyOutputFolder = (Join-Path $PSScriptRoot 'policies'),

    [Parameter()]
    [string] $AssignmentScope,

    [Parameter()]
    [string] $Location = 'eastus',

    [Parameter()]
    [switch] $UseSystemAssignedIdentity,

    [Parameter()]
    [string] $ManagedIdentityResourceId
)

Set-StrictMode -Version Latest

function Ensure-Module {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Version] $RequiredVersion,
        [Version] $MinimumVersion,
        [ValidateSet('CurrentUser', 'AllUsers')] [string] $Scope = 'CurrentUser'
    )

    $installed = Get-Module -ListAvailable -Name $Name
    $isSatisfied = $false

    if ($RequiredVersion) {
        $isSatisfied = $installed | Where-Object { $_.Version -eq $RequiredVersion } | Select-Object -First 1
    } elseif ($MinimumVersion) {
        $isSatisfied = $installed | Where-Object { $_.Version -ge $MinimumVersion } | Select-Object -First 1
    } else {
        $isSatisfied = [bool]$installed
    }

    if ($isSatisfied) {
        return
    }

    $params = @{ Name = $Name; Scope = $Scope; Force = $true }
    if ($RequiredVersion) {
        $params.RequiredVersion = $RequiredVersion.ToString()
    } elseif ($MinimumVersion) {
        $params.MinimumVersion = $MinimumVersion.ToString()
    }

    Write-Host "Installing module $Name" -ForegroundColor Yellow
    Install-Module @params -ErrorAction Stop
}

$moduleRequirements = @(
    @{ Name = 'Az.Accounts'; MinimumVersion = [Version]'2.13.1' },
    @{ Name = 'Az.Resources'; MinimumVersion = [Version]'6.0.0' },
    @{ Name = 'Az.Storage'; MinimumVersion = [Version]'5.4.0' },
    @{ Name = 'GuestConfiguration'; MinimumVersion = [Version]'3.13.0' }
)

foreach ($module in $moduleRequirements) {
    Ensure-Module @module
    Import-Module $module.Name -ErrorAction Stop | Out-Null
}

if (-not $PackagePath) {
    $latestPackage = Get-ChildItem -Path (Join-Path $PSScriptRoot 'artifacts') -Filter "$ConfigurationName-*.zip" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $latestPackage) {
        throw "Unable to locate a package named $ConfigurationName-<version>.zip in artifacts/. Specify -PackagePath."
    }

    $PackagePath = $latestPackage.FullName
}

if (-not (Test-Path $PackagePath)) {
    throw "Package path not found: $PackagePath"
}

if (-not $AssignmentScope) {
    $AssignmentScope = "/subscriptions/$SubscriptionId"
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

$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
$storageContext = $storageAccount.Context
$container = Get-AzStorageContainer -Name $StorageContainerName -Context $storageContext -ErrorAction SilentlyContinue
if (-not $container) {
    Write-Host "Creating storage container '$StorageContainerName'" -ForegroundColor Yellow
    $container = New-AzStorageContainer -Name $StorageContainerName -Context $storageContext -Permission Off -ErrorAction Stop
}

Write-Host "Uploading package $PackagePath" -ForegroundColor Cyan
$blob = Set-AzStorageBlobContent -File $PackagePath -Container $StorageContainerName -Context $storageContext -Force -ErrorAction Stop
$contentUri = $blob.ICloudBlob.Uri.AbsoluteUri
Write-Host "Package uploaded to $contentUri" -ForegroundColor Green

if (-not (Test-Path $PolicyOutputFolder)) {
    New-Item -Path $PolicyOutputFolder -ItemType Directory -Force | Out-Null
}

$mode = if ($AssignmentType -eq 'Audit') { 'Audit' } else { 'ApplyAndAutoCorrect' }
$policyId = (New-Guid).Guid
$policyConfig = @{
    PolicyId      = $policyId
    ContentUri    = $contentUri
    DisplayName   = $PolicyDisplayName
    Description   = $PolicyDescription
    Path          = $PolicyOutputFolder
    Platform      = 'Windows'
    PolicyVersion = $PolicyVersion
    Mode          = $mode
    Category      = 'Guest Configuration'
}

if ($UseSystemAssignedIdentity) {
    $policyConfig.UseSystemAssignedIdentity = $true
}
elseif ($ManagedIdentityResourceId) {
    $policyConfig.ManagedIdentityResourceId = $ManagedIdentityResourceId
    $policyConfig.LocalContentPath = Split-Path -Path $PackagePath -Parent
    $policyConfig.ExcludeArcMachines = $true
}

Write-Host "Generating policy definition files via New-GuestConfigurationPolicy" -ForegroundColor Cyan
$newPolicy = New-GuestConfigurationPolicy @policyConfig -ErrorAction Stop

$policyFileName = if ($AssignmentType -eq 'Audit') { 'auditIfNotExists.json' } else { 'deployIfNotExists.json' }
$policyFilePath = Join-Path $PolicyOutputFolder $policyFileName
if (-not (Test-Path $policyFilePath)) {
    throw "Expected policy file was not generated: $policyFilePath"
}

Write-Host "Publishing Azure Policy definition $PolicyDefinitionName" -ForegroundColor Cyan
$definition = New-AzPolicyDefinition -Name $PolicyDefinitionName -DisplayName $PolicyDisplayName `
    -Description $PolicyDescription -Policy $policyFilePath -Mode All -ErrorAction Stop

if ($PSCmdlet.ShouldProcess($AssignmentScope, "Assign policy $PolicyAssignmentName")) {
    Write-Host "Assigning policy $PolicyAssignmentName at scope $AssignmentScope" -ForegroundColor Cyan
    $assignmentParams = @{
        Name              = $PolicyAssignmentName
        DisplayName       = $PolicyDisplayName
        Scope             = $AssignmentScope
        PolicyDefinition  = $definition
        Location          = $Location
        IdentityType      = 'SystemAssigned'
    }

    $assignment = New-AzPolicyAssignment @assignmentParams -ErrorAction Stop
    Write-Host "Policy assignment created: $($assignment.Id)" -ForegroundColor Green
    return [PSCustomObject]@{
        PackageUri        = $contentUri
        PolicyDefinition  = $definition.Id
        PolicyAssignment  = $assignment.Id
        AssignmentScope   = $AssignmentScope
        AssignmentType    = $AssignmentType
    }
}
