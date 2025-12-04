# DSC v1 Authoring Guide

## Prerequisites
- **PowerShell versions**
  - Windows PowerShell 5.1 (`powershell.exe`) for compilation.
  - PowerShell 7+ (`pwsh`) for packaging and validation.
- **Modules (installed automatically if missing when you run the scripts)**
  - `PSDscResources` version **2.12.0.0** – required during MOF compilation and embedded inside the package.
  - `GuestConfiguration` module – already declared via `#requires` in `PackageTrackerConfig.ps1`.
  - `SqlServer` module (minimum version 21.1.18256) – needed because the DSC resource calls `Invoke-Sqlcmd` when the compliance test executes locally.
- PSGallery access to download modules (or pre-stage the modules in your module path).
- Ability to run elevated PowerShell when testing packages (the Guest Configuration agent writes under `%ProgramData%\GuestConfig` and may be blocked by endpoint protection if not allowed).

## File Map (execution order)
1. **ContosoSqlLoginRsrc.ps1** – the DSC configuration definition (`Configuration ContosoSqlLogin`) that creates/enforces the SQL login. Every subsequent step consumes the MOF compiled from this file.
2. **CreateSqlLoginMOF.ps1** – Windows PowerShell 5.1 entry point that imports `ContosoSqlLoginRsrc.ps1`, installs `PSDscResources`, and emits the node-specific MOF into `out/`. `CreateTrackerMOF.ps1` remains only for legacy workflows still referencing the old name.
3. **ValidateTrackerConfig.ps1** – optional local validation/remediation helper that runs `Test-DscConfiguration`/`Start-DscConfiguration` on the freshly compiled MOF before you package it.
4. **PackageTrackerConfig.ps1** – PowerShell 7 packager that bundles the MOF into a Guest Configuration ZIP, runs the local compliance test (unless `-SkipComplianceTest`), and optionally performs local remediation.
5. **DeployTrackerPolicy.ps1** – publishes the latest ZIP to Azure Storage, generates the Guest Configuration policy JSON, creates/updates the Azure Policy definition, and assigns it at the requested scope.
6. **DebugTrackerStatus.ps1** – post-deployment monitoring utility that queries Azure Policy states, Resource Graph results, and per-VM guest configuration assignments to surface non-compliance.
7. **README.md / workspace-prompt.txt** – living documentation and recap of the workflow; update these when you adjust any of the scripts so future sessions stay in sync.

## Step 1 – Compile the MOF (PowerShell 5.1)
```powershell
powershell.exe -File .\CreateSqlLoginMOF.ps1 -SQLServiceUsername 'apolloAdmin' -NodeName 'localhost'
```
- The script ensures Windows PowerShell 5.1 is in use (via `#requires`).
- It verifies `PSDscResources` 2.12.0.0 is installed, installing it into the current user scope if needed.
- Outputs MOF files under `out/`. Delete or archive previous MOFs if you want a clean run.
- `CreateTrackerMOF.ps1` remains for backward compatibility but will eventually be removed once everything points to the new name.

## Step 2 – Package and Validate (PowerShell 7)
```powershell
pwsh -File .\PackageTrackerConfig.ps1 -ConfigurationName ContosoSqlLogin -NodeName 'localhost' \
  -PackageVersion 1.0.0 -AssignmentType AuditAndSet [-Force] [-RunLocalRemediation] [-SkipComplianceTest]
```
- The script enforces PowerShell 7 and auto-installs `PSDscResources` 2.12.0.0, `SqlServer` (>=21.1.18256), and `GuestConfiguration` (>=3.13.0) if they are missing.
- Produces `artifacts/ContosoSqlLogin-<version>.zip` and runs `Get-GuestConfigurationPackageComplianceStatus` to confirm the archive structure unless `-SkipComplianceTest` is specified.
- Add `-Force` to overwrite an existing package.
- Add `-RunLocalRemediation` to call `Start-GuestConfigurationPackageRemediation` (only valid for `AuditAndSet`). Run this step from an elevated console and ensure security tools allow `gc.exe` located under the GuestConfiguration module folder.
- Use `-SkipComplianceTest` when Defender/EDR tools block access to `%USERPROFILE%\Documents\PowerShell\Modules\GuestConfiguration`. When the test runs, the script clears the `gcworker\packages` cache to avoid access denied issues on re-runs.
- Logs for compliance tests are written under `%USERPROFILE%\Documents\PowerShell\Modules\GuestConfiguration\<version>\gcworker\logs` and `%ProgramData%\GuestConfig`.

## Step 3 – Validate Locally (optional but recommended)
Run this step on the Azure VM (or authoring machine) where the MOF was compiled to confirm the DSC resource succeeds before packaging again.

```powershell
powershell.exe -File .\ValidateTrackerConfig.ps1 -NodeName 'localhost' [-Remediate]
```

- Installs `PSDscResources` 2.12.0.0 and `SqlServer` (>=21.1.18256) if they are missing.
- Executes `Test-DscConfiguration` against the compiled MOF and reports compliance.
- Add `-Remediate` to run `Start-DscConfiguration` locally, or `-SkipStatus` to suppress the DSC status table.
- Errors that mention a missing MOF will now point you back to `CreateSqlLoginMOF.ps1`; re-run the compile step there to regenerate the MOF.

## Step 4 – Publish Package + Assign Azure Policy
Use PowerShell 7 on a machine that can reach Azure (the same VM works) and authenticate with `Connect-AzAccount`.

```powershell
pwsh -File .\DeployTrackerPolicy.ps1 \
  -SubscriptionId '<sub-guid>' \
  -ResourceGroupName 'rg-contoso-sql' \
  -StorageAccountName 'contososqllogin' \
  -StorageContainerName 'guestconfig' \
  -PolicyDefinitionName 'ContosoSqlLogin' \
  -PolicyAssignmentName 'ContosoSqlLogin-Assignment'
```

- The script ensures `Az.Accounts`, `Az.Resources`, `Az.Storage`, and `GuestConfiguration` are installed.
- Uploads the latest `artifacts/ContosoSqlLogin-<version>.zip` (or a custom `-PackagePath`) to the target storage account and creates the resource group, storage account, and container if they do not exist yet.
- Generates the policy JSON via `New-GuestConfigurationPolicy`, publishes it with `New-AzPolicyDefinition`, and assigns it with a system-assigned identity.
- Use `-AssignmentType Audit` if you only need auditing; the default `AuditAndSet` uses `ApplyAndAutoCorrect` mode.
- Skip `-PackagePath` to automatically use the newest `ContosoSqlLogin-<version>.zip` under `artifacts/`.
- Specify `-DisableBlobSas` to keep the storage URI private (default behavior issues a read-only SAS that expires after `-BlobSasExpiryHours`, 720 hours by default).
- Provide `-ManagedIdentityResourceId` to reuse an existing identity or set `-AssignmentScope` to deploy at a narrower scope than the subscription.

## Step 5 – Monitor Azure Compliance
Collect near-real-time compliance status once the policy assignment evaluates on your machines.

```powershell
pwsh -File .\DebugTrackerStatus.ps1 -SubscriptionId '<sub-guid>' -PolicyAssignmentName 'ContosoSqlLogin-Assignment'
```

- Ensures `Az.Accounts`, `Az.PolicyInsights`, `Az.ResourceGraph`, and `Az.GuestConfiguration` are available.
- Lists the latest `Get-AzPolicyState` records (non-compliant by default).
- Runs an Azure Resource Graph query to summarize which machines are failing and the reported reason.
- Provide `-ResourceGroupName` and `-VmName` to pull `Get-AzGuestConfigurationAssignment` details for a specific server, or use `-IncludeCompliant` to list healthy resources alongside failures.

## Troubleshooting Tips
- If `Get-GuestConfigurationPackageComplianceStatus` reports "No report was generated", confirm that security policies allow `gc.exe` from the GuestConfiguration module folder or run on a clean VM.
- Missing module errors (for `PSDscResources` or `SqlServer`) indicate the auto-install could not run—install manually with `Install-Module` and rerun the script.
- Review `%ProgramData%\GuestConfig\GuestConfigAgent.log` for detailed agent output when local remediation fails.
