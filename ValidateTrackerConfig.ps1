#requires -Version 5.1
<#!
.SYNOPSIS
    Runs Test/Start-DscConfiguration against the TrackerDSC2019SFTP MOF on a Windows Server VM.

.DESCRIPTION
    Use this helper after compiling the MOF (CreateTrackerMOF.ps1) to validate or remediate a machine locally
    before packaging or assigning through Azure Policy. The script:
      * Ensures the PSDscResources and SqlServer modules are available (matching the configuration requirements).
      * Loads the compiled MOF from the out/ folder (or a custom path).
      * Executes Test-DscConfiguration to report compliance.
      * Optionally calls Start-DscConfiguration -Force to apply the Set logic locally.
      * Emits the last DSC status entries so you can review timestamps and errors.

.EXAMPLE
    powershell.exe -File ./ValidateTrackerConfig.ps1 -NodeName 'localhost'

.EXAMPLE
    powershell.exe -File ./ValidateTrackerConfig.ps1 -MofFolder 'C:/temp/out' -NodeName 'TrackerVM' -Remediate
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $MofFolder = (Join-Path $PSScriptRoot 'out'),

    [Parameter()]
    [string] $NodeName = 'localhost',

    [Parameter()]
    [switch] $Remediate,

    [Parameter()]
    [switch] $SkipStatus
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
    @{ Name = 'PSDscResources'; RequiredVersion = [Version]'2.12.0.0' },
    @{ Name = 'SqlServer';      MinimumVersion = [Version]'21.1.18256' }
)

foreach ($module in $moduleRequirements) {
    Ensure-Module @module
    Import-Module $module.Name -ErrorAction Stop | Out-Null
}

if (-not (Test-Path $MofFolder)) {
    throw "MOF folder not found: $MofFolder"
}

$mofPath = Join-Path $MofFolder ("{0}.mof" -f $NodeName)
if (-not (Test-Path $mofPath)) {
    throw "MOF for node '$NodeName' not found at $mofPath. Re-run CreateTrackerMOF.ps1."
}

Write-Host "Testing DSC configuration at $MofFolder" -ForegroundColor Cyan
$testResult = Test-DscConfiguration -Path $MofFolder -Verbose:$VerbosePreference -ErrorAction Stop

$inDesiredState = $false
if ($null -ne $testResult) {
    $inDesiredState = $testResult.InDesiredState
}

if ($inDesiredState) {
    Write-Host "Node '$NodeName' is already compliant." -ForegroundColor Green
} else {
    Write-Warning "Node '$NodeName' is NOT compliant with TrackerDSC2019SFTP."
}

if ($Remediate) {
    Write-Host "Applying configuration locally via Start-DscConfiguration..." -ForegroundColor Yellow
    Start-DscConfiguration -Path $MofFolder -Wait -Verbose -Force
}

if (-not $SkipStatus) {
    Write-Host "Recent DSC status entries:" -ForegroundColor Cyan
    Get-DscConfigurationStatus -All | Sort-Object -Property StartDate -Descending | Select-Object -First 5 |
        Select-Object StartDate, Type, StatusMessage | Format-Table -AutoSize
}

return [PSCustomObject]@{
    NodeName        = $NodeName
    MofPath         = $mofPath
    InDesiredState  = $inDesiredState
    RemediationRan  = [bool]$Remediate
}
