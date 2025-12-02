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

## Step 1 – Compile the MOF (PowerShell 5.1)
```powershell
powershell.exe -File .\CreateTrackerMOF.ps1 -SQLServiceUsername 'apolloAdmin' -NodeName 'localhost'
```
- The script ensures Windows PowerShell 5.1 is in use (via `#requires`).
- It verifies `PSDscResources` 2.12.0.0 is installed, installing it into the current user scope if needed.
- Outputs MOF files under `out/`. Delete or archive previous MOFs if you want a clean run.

## Step 2 – Package and Validate (PowerShell 7)
```powershell
pwsh -File .\PackageTrackerConfig.ps1 -ConfigurationName TrackerDSC2019SFTP -NodeName 'localhost' \
     -PackageVersion 1.0.0 -AssignmentType AuditAndSet [-Force] [-RunLocalRemediation]
```
- The script enforces PowerShell 7 and auto-installs `PSDscResources` 2.12.0.0 plus the `SqlServer` module if they are missing.
- Produces `artifacts/TrackerDSC2019SFTP-<version>.zip` and runs `Get-GuestConfigurationPackageComplianceStatus` to confirm the archive structure.
- Add `-Force` to overwrite an existing package.
- Add `-RunLocalRemediation` to call `Start-GuestConfigurationPackageRemediation` (only valid for `AuditAndSet`). Run this step from an elevated console and ensure security tools allow `gc.exe` located under the GuestConfiguration module folder.
- Logs for compliance tests are written under `%USERPROFILE%\Documents\PowerShell\Modules\GuestConfiguration\<version>\gcworker\logs` and `%ProgramData%\GuestConfig`.

## Step 3 – Validate Locally (optional but recommended)
Run this step on the Azure VM (or authoring machine) where the MOF was compiled to confirm the DSC resource succeeds before packaging again.

```powershell
powershell.exe -File .\ValidateTrackerConfig.ps1 -NodeName 'localhost' [-Remediate]
```

- Installs `PSDscResources` 2.12.0.0 and `SqlServer` (>=21.1.18256) if they are missing.
- Executes `Test-DscConfiguration` against the compiled MOF and reports compliance.
- Add `-Remediate` to run `Start-DscConfiguration` locally, or `-SkipStatus` to suppress the DSC status table.

## Step 4 – Publish Package + Assign Azure Policy
Use PowerShell 7 on a machine that can reach Azure (the same VM works) and authenticate with `Connect-AzAccount`.

```powershell
pwsh -File .\DeployTrackerPolicy.ps1 \
  -SubscriptionId '<sub-guid>' \
  -ResourceGroupName 'rg-tracker' \
  -StorageAccountName 'trackerconfigstore' \
  -StorageContainerName 'guestconfig' \
  -PolicyDefinitionName 'TrackerDSC2019SFTP' \
  -PolicyAssignmentName 'TrackerDSC2019SFTP-Assignment'
```

- The script ensures `Az.Accounts`, `Az.Resources`, `Az.Storage`, and `GuestConfiguration` are installed.
- Uploads the latest `artifacts/TrackerDSC2019SFTP-<version>.zip` (or a custom `-PackagePath`) to the target storage account.
- Generates the policy JSON via `New-GuestConfigurationPolicy`, publishes it with `New-AzPolicyDefinition`, and assigns it with a system-assigned identity.
- Use `-AssignmentType Audit` if you only need auditing; the default `AuditAndSet` uses `ApplyAndAutoCorrect` mode.

## Step 5 – Monitor Azure Compliance
Collect near-real-time compliance status once the policy assignment evaluates on your machines.

```powershell
pwsh -File .\DebugTrackerStatus.ps1 -SubscriptionId '<sub-guid>' -PolicyAssignmentName 'TrackerDSC2019SFTP-Assignment'
```

- Ensures `Az.Accounts`, `Az.PolicyInsights`, `Az.ResourceGraph`, and `Az.GuestConfiguration` are available.
- Lists the latest `Get-AzPolicyState` records (non-compliant by default).
- Runs an Azure Resource Graph query to summarize which machines are failing and the reported reason.
- Provide `-ResourceGroupName` and `-VmName` to pull `Get-AzGuestConfigurationAssignment` details for a specific server.

## Troubleshooting Tips
- If `Get-GuestConfigurationPackageComplianceStatus` reports "No report was generated", confirm that security policies allow `gc.exe` from the GuestConfiguration module folder or run on a clean VM.
- Missing module errors (for `PSDscResources` or `SqlServer`) indicate the auto-install could not run—install manually with `Install-Module` and rerun the script.
- Review `%ProgramData%\GuestConfig\GuestConfigAgent.log` for detailed agent output when local remediation fails.
