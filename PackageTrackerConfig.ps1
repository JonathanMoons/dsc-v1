#requires -Version 7.0
<#
.SYNOPSIS
    Packages the ContosoSqlLogin configuration into a Guest Configuration ZIP and validates it.

.DESCRIPTION
    Run this script in PowerShell 7 after compiling the MOF with CreateSqlLoginMOF.ps1 (or CreateTrackerMOF.ps1
    if you have not renamed the helper yet). It wraps the MOF inside a Guest Configuration package via
    New-GuestConfigurationPackage, validates the archive with Get-GuestConfigurationPackageComplianceStatus,
    and can optionally run Start-GuestConfigurationPackageRemediation to confirm the Set method (only for
    AuditAndSet packages).
#>

[CmdletBinding()] param(
    [Parameter()]
    [string] $ConfigurationName = 'ContosoSqlLogin',

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
    [switch] $RunLocalRemediation,

    [Parameter()]
    [switch] $SkipComplianceTest
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

    $installParams = @{ Name = $Name; Scope = $Scope; Force = $true }
    if ($RequiredVersion) {
        $installParams.RequiredVersion = $RequiredVersion.ToString()
    } elseif ($MinimumVersion) {
        $installParams.MinimumVersion = $MinimumVersion.ToString()
    }

    Write-Host "Installing module $Name" -ForegroundColor Yellow
    Install-Module @installParams -ErrorAction Stop
}

function Clear-GcComplianceCache {
    param(
        [Parameter(Mandatory)] [string] $PackageFolderName
    )

    $gcWorkerRoot = Join-Path $HOME 'Documents\PowerShell\Modules\GuestConfiguration'
    if (-not (Test-Path $gcWorkerRoot)) {
        return @()
    }

    $removedPaths = @()
    $failedPaths = @()
    $versions = Get-ChildItem -Path $gcWorkerRoot -Directory -ErrorAction SilentlyContinue
    foreach ($versionFolder in $versions) {
        $packagesRoot = Join-Path $versionFolder.FullName 'gcworker\packages'
        if (-not (Test-Path $packagesRoot)) {
            continue
        }

        $targetFolder = Join-Path $packagesRoot $PackageFolderName
        if (Test-Path $targetFolder) {
            Write-Verbose "Clearing cached GuestConfiguration folder $targetFolder"
            try {
                Get-ChildItem -Path $targetFolder -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    try { $_.Attributes = 'Normal' } catch { }
                }

                try {
                    (Get-Item -Path $targetFolder -Force).Attributes = 'Normal'
                } catch { }

                Remove-Item -Path $targetFolder -Recurse -Force -ErrorAction Stop
                $removedPaths += $targetFolder
            } catch {
                Write-Warning "Initial removal of $targetFolder failed: $($_.Exception.Message). Attempting to take ownership and retry."

                try {
                    & takeown.exe /F $targetFolder /A /R /D Y | Out-Null
                    & icacls.exe $targetFolder /grant "$env:USERNAME:(OI)(CI)F" /T /C | Out-Null
                    Remove-Item -Path $targetFolder -Recurse -Force -ErrorAction Stop
                    $removedPaths += $targetFolder
                } catch {
                    Write-Warning "Unable to clear GuestConfiguration cache folder $targetFolder. Manual deletion may be required."
                    $failedPaths += $targetFolder
                }
            }
        }
    }

    if ($failedPaths.Count -gt 0) {
        throw "Failed to clear GuestConfiguration cache folders: $($failedPaths -join ', ')"
    }

    return $removedPaths
}

$moduleRequirements = @(
    @{ Name = 'PSDscResources'; RequiredVersion = [Version]'2.12.0.0'; Scope = 'CurrentUser' },
    @{ Name = 'SqlServer';      MinimumVersion = [Version]'21.1.18256'; Scope = 'CurrentUser' },
    @{ Name = 'GuestConfiguration'; MinimumVersion = [Version]'3.13.0'; Scope = 'CurrentUser' }
)

foreach ($module in $moduleRequirements) {
    Ensure-Module @module
}

if ($RunLocalRemediation -and $SkipComplianceTest) {
    throw "-RunLocalRemediation cannot be combined with -SkipComplianceTest."
}

Write-Host "=== ContosoSqlLogin :: Package + Test (PowerShell 7) ===" -ForegroundColor Cyan

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

$complianceResult = $null
if ($SkipComplianceTest) {
    Write-Warning "Skipping local compliance test at user request (-SkipComplianceTest)."
} else {
    Write-Host "Testing package $packagePath" -ForegroundColor Cyan
    $packageFolderName = "{0}-{1}" -f $ConfigurationName, $PackageVersion
    Clear-GcComplianceCache -PackageFolderName $packageFolderName | Out-Null

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $complianceResult = Get-GuestConfigurationPackageComplianceStatus -Path $packagePath -ErrorAction Stop
            break
        } catch {
            $needsRetry = ($_.Exception -is [System.UnauthorizedAccessException] -or $_.Exception.Message -like '*Access to the path*gcworker\\packages*')
            if (-not $needsRetry -or $attempt -eq 2) {
                throw
            }

            Write-Warning "Compliance test failed due to GuestConfiguration cache access. Clearing cache and retrying..."
            Clear-GcComplianceCache -PackageFolderName $packageFolderName | Out-Null
            Start-Sleep -Seconds 2
        }
    }

    if (-not $complianceResult.complianceStatus) {
        Write-Warning "Package compliance check returned 'false'. Full compliance result follows:"
        try {
            $complianceResult | ConvertTo-Json -Depth 6 | Write-Host
        } catch {
            Write-Host ($complianceResult | Format-List * | Out-String)
        }

        throw "Package compliance check returned 'false'."
    }

    Write-Host "Compliance status: $($complianceResult.complianceStatus)" -ForegroundColor Green
}

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
