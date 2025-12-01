#requires -Version 5.1
Set-StrictMode -Version Latest

Configuration TrackerDSC2019SFTP {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SQLServiceUsername,

        [string[]] $NodeName = 'localhost'
    )

    Import-DscResource -ModuleName PSDscResources
    
    Node $NodeName {
        Script Add_SQLUser_SQLService_Enhanced {
            GetScript = {
                $loginName = $using:SQLServiceUsername

                Import-Module SqlServer -ErrorAction Stop

                function Invoke-ContosoSqlQuery {
                    param(
                        [string] $Query,
                        [string] $ErrorActionPreference = 'Stop'
                    )

                    $invokeParams = @{
                        ServerInstance         = 'localhost'
                        Database               = 'master'
                        TrustServerCertificate = $true
                        ConnectionTimeout      = 30
                        QueryTimeout           = 15
                        ErrorAction            = $ErrorActionPreference
                        Variable               = @{ LoginName = $loginName }
                    }

                    Invoke-Sqlcmd @invokeParams -Query $Query
                }

                try {
                    $probeQuery = @"
SELECT name, create_date, is_disabled FROM sys.server_principals WHERE name = N'$(LoginName)'
"@

                    $result = Invoke-ContosoSqlQuery -Query $probeQuery
                    if ($null -ne $result) {
                        $status = if ($result.is_disabled) { 'exists but disabled' } else { 'exists and enabled' }
                        return @{ Result = "Login $loginName $status (Created: $($result.create_date))" }
                    }

                    return @{ Result = "Login $loginName does not exist" }
                } catch {
                    return @{ Result = "Error checking login $loginName : $($_.Exception.Message)" }
                }
            }

            TestScript = {
                $loginName = $using:SQLServiceUsername

                try {
                    Import-Module SqlServer -ErrorAction Stop

                    function Invoke-ContosoSqlQuery {
                        param([string] $Query)

                        $invokeParams = @{
                            ServerInstance         = 'localhost'
                            Database               = 'master'
                            TrustServerCertificate = $true
                            ConnectionTimeout      = 30
                            QueryTimeout           = 15
                            ErrorAction            = 'Stop'
                            Variable               = @{ LoginName = $loginName }
                        }

                        Invoke-Sqlcmd @invokeParams -Query $Query
                    }

                    $testQuery = @"
SELECT name FROM sys.server_principals WHERE name = N'$(LoginName)'  AND is_disabled = 0
"@

                    $result = Invoke-ContosoSqlQuery -Query $testQuery
                    return ($null -ne $result)
                } catch {
                    Write-Verbose "TestScript error for login $loginName : $($_.Exception.Message)"
                    return $false
                }
            }

            SetScript = {
                $loginName = $using:SQLServiceUsername

                Import-Module SqlServer -ErrorAction Stop

                function Invoke-ContosoSqlQuery {
                    param(
                        [string] $Query,
                        [string] $ErrorActionPreference = 'Stop'
                    )

                    $invokeParams = @{
                        ServerInstance         = 'localhost'
                        Database               = 'master'
                        TrustServerCertificate = $true
                        ConnectionTimeout      = 30
                        QueryTimeout           = 15
                        ErrorAction            = $ErrorActionPreference
                        Variable               = @{ LoginName = $loginName }
                    }

                    Invoke-Sqlcmd @invokeParams -Query $Query
                }

                try {
                    $setQuery = @"
DECLARE @login sysname = N'$(LoginName)';

IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login)
BEGIN
    IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login AND is_disabled = 1)
    BEGIN
        DECLARE @enable nvarchar(512) = N'ALTER LOGIN ' + QUOTENAME(@login) + N' ENABLE;';
        EXEC (@enable);
    END
END
ELSE
BEGIN
    DECLARE @create nvarchar(512) = N'CREATE LOGIN ' + QUOTENAME(@login) + N' FROM WINDOWS;';
    EXEC (@create);
END
"@

                    Invoke-ContosoSqlQuery -Query $setQuery
                } catch {
                    throw "Failed to create or enable SQL login $loginName : $($_.Exception.Message)"
                }
            }
        }
    }
}
