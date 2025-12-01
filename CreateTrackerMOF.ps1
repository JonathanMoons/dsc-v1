#requires -Version 5.1
<#
.SYNOPSIS
    Compiles the TrackerDSC2019SFTP configuration to a MOF file.

.DESCRIPTION
    Run this script in **Windows PowerShell 5.1** before packaging the configuration for Azure Machine Configuration.
    The script imports the configuration definition from ContosoMOFIssueNew.ps1, prompts for any required parameters,
    and emits the MOF under the local `out` folder beside the script.

.NOTES
    Execution environment: Windows PowerShell 5.1 (powershell.exe)
    Required modules: PSDscResources 2.12.0.0 (installed automatically when missing)
    Output folder: <script-root>\out
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SQLServiceUsername,

    [string[]] $NodeName = 'localhost'
)

Set-StrictMode -Version Latest

function Ensure-RequiredModule {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Version] $RequiredVersion,
        [Version] $MinimumVersion,
        [ValidateSet('CurrentUser', 'AllUsers')] [string] $Scope = 'CurrentUser',
        [string] $Purpose = ''
    )

    $installed = Get-Module -ListAvailable -Name $Name

    $isSatisfied = $false
    if ($RequiredVersion) {
        $isSatisfied = $installed | Where-Object { $_.Version -eq $RequiredVersion } | ForEach-Object { $true } | Select-Object -First 1
    } elseif ($MinimumVersion) {
        $isSatisfied = $installed | Where-Object { $_.Version -ge $MinimumVersion } | ForEach-Object { $true } | Select-Object -First 1
    } else {
        $isSatisfied = [bool]$installed
    }

    if ($isSatisfied) {
        return
    }

    $versionNote = if ($RequiredVersion) { " version $RequiredVersion" } elseif ($MinimumVersion) { " >= $MinimumVersion" } else { '' }
    $purposeNote = if ($Purpose) { " ($Purpose)" } else { '' }
    Write-Host "Installing module $Name$versionNote$purposeNote..." -ForegroundColor Yellow

    $installParams = @{ Name = $Name; Scope = $Scope; Force = $true }
    if ($RequiredVersion) {
        $installParams.RequiredVersion = $RequiredVersion.ToString()
    } elseif ($MinimumVersion) {
        $installParams.MinimumVersion = $MinimumVersion.ToString()
    }

    try {
        Install-Module @installParams -ErrorAction Stop
    } catch {
        throw "Failed to install module $Name$versionNote : $($_.Exception.Message)"
    }
}

$moduleRequirements = @(
    @{ Name = 'PSDscResources'; RequiredVersion = [Version]'2.12.0.0'; Scope = 'CurrentUser'; Purpose = 'compile TrackerDSC2019SFTP' }
)

foreach ($requirement in $moduleRequirements) {
    Ensure-RequiredModule @requirement
}

Write-Host "=== TrackerDSC2019SFTP :: MOF Compilation (PowerShell 5.1) ===" -ForegroundColor Cyan

$scriptRoot = $PSScriptRoot
$configPath = Join-Path $scriptRoot 'ContosoMOFIssueNew.ps1'
$outFolder  = Join-Path $scriptRoot 'out'

if (-not (Test-Path $configPath)) {
    throw "Configuration file not found: $configPath"
}

Write-Host "Importing configuration from $configPath" -ForegroundColor Cyan
. $configPath

if (-not (Test-Path $outFolder)) {
    New-Item -Path $outFolder -ItemType Directory -Force | Out-Null
}

Write-Host "Compiling TrackerDSC2019SFTP..." -ForegroundColor Cyan
TrackerDSC2019SFTP -SQLServiceUsername $SQLServiceUsername -NodeName $NodeName -OutputPath $outFolder

Write-Host "MOF files written to: $outFolder" -ForegroundColor Green
Get-ChildItem $outFolder -Filter '*.mof' | Select-Object Name, Length, LastWriteTime
