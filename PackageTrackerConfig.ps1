#requires -Version 7.0
#requires -Modules GuestConfiguration
<#
.SYNOPSIS
    Packages the TrackerDSC2019SFTP configuration into a Guest Configuration ZIP and validates it.

.DESCRIPTION
    Run this script in PowerShell 7 after compiling the MOF with CreateTrackerMOF.ps1. It wraps the
    MOF inside a Guest Configuration package via New-GuestConfigurationPackage, validates the archive
    with Get-GuestConfigurationPackageComplianceStatus, and can optionally run Start-GuestConfiguration
    PackageRemediation to confirm the Set method (only for AuditAndSet packages).
#>

[CmdletBinding()] param(
    [Parameter()]
    [string] $ConfigurationName = 'TrackerDSC2019SFTP',

    [Parameter()]
    [string] $NodeName = 'localhost',

    [Parameter()]
    [string] $MofFolder = (Join-Path $PSScriptRoot 'out'),

    [Parameter()]
    [string] $PackageOutputFolder = (Join-Path $PSScriptRoot 'artifacts'),

    [Parameter()]
    [string] $PackageVersion = '1.0.0',

    [Parameter()]
    [ValidateSet('Audit', 'AuditAndSet')]
    [string] $AssignmentType = 'AuditAndSet',

    [Parameter()]
    [string] $Description = 'Ensures the SQL service login exists and stays enabled.',

    [switch] $Force,

    [Parameter()]
    [switch] $RunLocalRemediation
)

Set-StrictMode -Version Latest
Write-Host "=== TrackerDSC2019SFTP :: Package + Test (PowerShell 7) ===" -ForegroundColor Cyan

Import-Module GuestConfiguration -ErrorAction Stop

if (-not (Test-Path $MofFolder)) {
    throw "MOF folder not found: $MofFolder"
}

$mofPath = Join-Path $MofFolder ("{0}.mof" -f $NodeName)
if (-not (Test-Path $mofPath)) {
    throw "Expected MOF not found: $mofPath"
}

if (-not (Test-Path $PackageOutputFolder)) {
    Write-Verbose "Creating package output folder $PackageOutputFolder"
    New-Item -Path $PackageOutputFolder -ItemType Directory -Force | Out-Null
}

$tempZipPath = Join-Path $PackageOutputFolder ("{0}.zip" -f $ConfigurationName)
$versionedZipPath = Join-Path $PackageOutputFolder ("{0}-{1}.zip" -f $ConfigurationName, $PackageVersion)

foreach ($path in @($tempZipPath, $versionedZipPath)) {
    if ((Test-Path $path) -and -not $Force) {
        throw "Package already exists: $path. Use -Force to overwrite."
    }
}

if (Test-Path $tempZipPath) {
    Remove-Item -Path $tempZipPath -Force
}

if (Test-Path $versionedZipPath) {
    Remove-Item -Path $versionedZipPath -Force
}

Write-Host "Packaging $mofPath" -ForegroundColor Cyan
$gcPackageCommand = Get-Command -Name New-GuestConfigurationPackage -ErrorAction Stop
$newPkgParams = @{
    Name           = $ConfigurationName
    Configuration  = $mofPath
    Path           = $PackageOutputFolder
    Type           = $AssignmentType
    Version        = $PackageVersion
}

if ($gcPackageCommand.Parameters.ContainsKey('Description')) {
    $newPkgParams.Description = $Description
} else {
    Write-Verbose "Installed GuestConfiguration module does not expose -Description; skipping."
}

New-GuestConfigurationPackage @newPkgParams | Out-Null

if (Test-Path $tempZipPath) {
    Move-Item -Path $tempZipPath -Destination $versionedZipPath -Force
}

$packagePath = if (Test-Path $versionedZipPath) { $versionedZipPath } else { $tempZipPath }

Write-Host "Testing package $packagePath" -ForegroundColor Cyan
$complianceResult = Get-GuestConfigurationPackageComplianceStatus -Path $packagePath -ErrorAction Stop

if (-not $complianceResult.complianceStatus) {
    throw "Package compliance check returned 'false'." 
}

Write-Host "Compliance status: $($complianceResult.complianceStatus)" -ForegroundColor Green

if ($RunLocalRemediation) {
    if ($AssignmentType -ne 'AuditAndSet') {
        Write-Warning "Local remediation skipped because AssignmentType is '$AssignmentType'."
    } else {
        Write-Host "Running Start-GuestConfigurationPackageRemediation (may modify local machine)" -ForegroundColor Yellow
        Start-GuestConfigurationPackageRemediation -Path $packagePath -ErrorAction Stop -Verbose:$VerbosePreference
        Write-Host "Remediation command completed." -ForegroundColor Green
        $complianceResult = Get-GuestConfigurationPackageComplianceStatus -Path $packagePath -ErrorAction Stop
        Write-Host "Post-remediation compliance status: $($complianceResult.complianceStatus)" -ForegroundColor Green
    }
}

Write-Host "Package ready: $packagePath" -ForegroundColor Green
return $complianceResult
