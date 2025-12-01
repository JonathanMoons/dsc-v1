# TrackerDSC2019SFTP Authoring Guide

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

## Step 3 – Next Steps
1. Upload `artifacts/TrackerDSC2019SFTP-<version>.zip` to your storage account (or follow your existing publishing pipeline).
2. Use the upcoming `DeployTrackerPolicy.ps1` helper to publish a Guest Configuration definition and assign the DeployIfNotExists policy once it is available.
3. Track validation/debugging with the planned scripts (`ValidateTrackerConfig.ps1`, `DebugTrackerStatus.ps1`).

## Troubleshooting Tips
- If `Get-GuestConfigurationPackageComplianceStatus` reports "No report was generated", confirm that security policies allow `gc.exe` from the GuestConfiguration module folder or run on a clean VM.
- Missing module errors (for `PSDscResources` or `SqlServer`) indicate the auto-install could not run—install manually with `Install-Module` and rerun the script.
- Review `%ProgramData%\GuestConfig\GuestConfigAgent.log` for detailed agent output when local remediation fails.
