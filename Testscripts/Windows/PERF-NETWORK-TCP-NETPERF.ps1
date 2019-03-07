# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
param([String] $TestParams,
      [object] $AllVmData,
      [object] $CurrentTestData)

function Main {
    param (
        $TestParams, $AllVmData, $CurrentTestData
    )
    # Create test result
    $resultArr = @()
    $currentTestResult = Create-TestResultObject

    try {
        $noClient = $true
        $noServer = $true
        # role-0 vm is considered as the client-vm
        # role-1 vm is considered as the server-vm
        foreach ($vmData in $allVMData) {
            if ($vmData.RoleName -imatch "role-0") {
                $clientVMData = $vmData
                $noClient = $false
            }
            elseif ($vmData.RoleName -imatch "role-1") {
                $noServer = $false
                $serverVMData = $vmData
            }
        }
        if ($noClient -or $noServer) {
            Throw "Client or Server VM not defined. Be sure that the SetupType has 2 VMs defined"
        }

        #region CONFIGURE VM FOR TERASORT TEST
        Write-LogInfo "CLIENT VM details :"
        Write-LogInfo "  RoleName : $($clientVMData.RoleName)"
        Write-LogInfo "  Public IP : $($clientVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($clientVMData.SSHPort)"
        Write-LogInfo "SERVER VM details :"
        Write-LogInfo "  RoleName : $($serverVMData.RoleName)"
        Write-LogInfo "  Public IP : $($serverVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($serverVMData.SSHPort)"

        # PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.
        Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
        #endregion

        Write-LogInfo "Getting Active NIC Name."
        if ($TestPlatform -eq "Azure") {
            $getNicCmd = ". ./utils.sh &> /dev/null && get_active_nic_name"
            $clientNicName = (Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort `
                -username "root" -password $password -command $getNicCmd).Trim()
            $serverNicName = (Run-LinuxCmd -ip $serverVMData.PublicIP -port $serverVMData.SSHPort `
                -username "root" -password $password -command $getNicCmd).Trim()
        } elseif ($TestPlatform -eq "HyperV") {
            $clientNicName = Get-GuestInterfaceByVSwitch $TestParams.PERF_NIC $clientVMData.RoleName `
                $clientVMData.HypervHost $user $clientVMData.PublicIP $password $clientVMData.SSHPort
            $serverNicName = Get-GuestInterfaceByVSwitch $TestParams.PERF_NIC $serverVMData.RoleName `
                $serverVMData.HypervHost $user $serverVMData.PublicIP $password $serverVMData.SSHPort
        }
        if ($serverNicName -eq $clientNicName) {
            $nicName = $clientNicName
        }
        else {
            Throw "Server and client SRIOV NICs are not same."
        }
        if ($currentTestData.AdditionalHWConfig.Networking -imatch "SRIOV") {
            $DataPath = "SRIOV"
        }
        else {
            $DataPath = "Synthetic"
        }
        Write-LogInfo "CLIENT $DataPath NIC: $clientNicName"
        Write-LogInfo "SERVER $DataPath NIC: $serverNicName"

        Write-LogInfo "Generating constants.sh ..."
        $constantsFile = "$LogDir\constants.sh"
        Set-Content -Value "#Generated by LISAv2 Automation" -Path $constantsFile
        Add-Content -Value "server=$($serverVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "client=$($clientVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "nicName=$nicName" -Path $constantsFile
        foreach ($param in $currentTestData.TestParameters.param) {
            Add-Content -Value "$param" -Path $constantsFile
            if ( $param -imatch "test_type") {
                $TestType = $param.Split("=")[1]
            }
        }
        $TestType = $TestType.Replace('"','')
        Write-LogInfo "constants.sh created successfully..."
        Write-LogInfo (Get-Content -Path $constantsFile)
        #endregion

        #region EXECUTE TEST
        $myString = @"
cd /root/
./perf_netperf.sh &> netperfConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
        Set-Content "$LogDir\StartnetperfTest.sh" $myString
        Copy-RemoteFiles -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files "$constantsFile,$LogDir\StartnetperfTest.sh" -username "root" -password $password -upload
        Copy-RemoteFiles -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files $currentTestData.files -username "root" -password $password -upload

        $null = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh"
        $testJob = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "/root/StartnetperfTest.sh" -RunInBackground
        #endregion

        #region MONITOR TEST
        while ((Get-Job -Id $testJob).State -eq "Running") {
            $currentStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "tail -1 netperfConsoleLogs.txt | head -1"
            Write-LogInfo "Current Test Status : $currentStatus"
            Wait-Time -seconds 20
        }
        $finalStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "netperfConsoleLogs.txt"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "TestExecution.log"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "netperf-client-sar-output.txt"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "netperf-client-output.txt"
        Copy-RemoteFiles -downloadFrom $serverVMData.PublicIP -port $serverVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "netperf-server-sar-output.txt"
        Copy-RemoteFiles -downloadFrom $serverVMData.PublicIP -port $serverVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "netperf-server-output.txt"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"

        $NetperfReportLog = Get-Content -Path "$LogDir\netperf-client-sar-output.txt"

        #Region : parse the logs
        try {
            $RxPpsArray = @()
            $TxPpsArray = @()
            $TxRxTotalPpsArray = @()

            foreach ($line in $NetperfReportLog) {
                if ($line -imatch "$nicName" -and $line -inotmatch "Average") {
                    Write-LogInfo "Collecting data from '$line'"
                    $line = $line.Replace("  ", " ").Replace("  ", " ").Replace("  ", " ").Replace("  ", " ").Replace("  ", " ")
                    for ($i = 0; $i -lt $line.split(' ').Count; $i++) {
                        if ($line.split(" ")[$i] -eq "$nicName") {
                            break;
                        }
                    }
                    $RxPps = [int]$line.Replace("  ", " ").Replace("  ", " ").Replace("  ", " ").Replace("  ", " ").Split(" ")[$i+1]
                    $RxPpsArray += $RxPps
                    $TxPps = [int]$line.Replace("  ", " ").Replace("  ", " ").Replace("  ", " ").Replace("  ", " ").Split(" ")[$i+2]
                    $TxPpsArray += $TxPps
                    $TxRxTotalPpsArray += ($RxPps + $TxPps)
                }
            }
            $RxData = $RxPpsArray | Measure-Object -Maximum -Minimum -Average
            $RxPpsMinimum = $RxData.Minimum
            $RxPpsMaximum = $RxData.Maximum
            $RxPpsAverage = [math]::Round($RxData.Average,0)
            Write-LogInfo "RxPpsMinimum = $RxPpsMinimum"
            Write-LogInfo "RxPpsMaximum = $RxPpsMaximum"
            Write-LogInfo "RxPpsAverage = $RxPpsAverage"

            $TxData = $TxPpsArray | Measure-Object -Maximum -Minimum -Average
            $TxPpsMinimum = $TxData.Minimum
            $TxPpsMaximum = $TxData.Maximum
            $TxPpsAverage = [math]::Round($TxData.Average,0)
            Write-LogInfo "TxPpsMinimum = $TxPpsMinimum"
            Write-LogInfo "TxPpsMaximum = $TxPpsMaximum"
            Write-LogInfo "TxPpsAverage = $TxPpsAverage"

            $RxTxTotalData = $TxRxTotalPpsArray | Measure-Object -Maximum -Minimum -Average
            $RxTxPpsMinimum = $RxTxTotalData.Minimum
            $RxTxPpsMaximum = $RxTxTotalData.Maximum
            $RxTxPpsAverage = [math]::Round($RxTxTotalData.Average,0)
            Write-LogInfo "RxTxPpsMinimum = $RxTxPpsMinimum"
            Write-LogInfo "RxTxPpsMaximum = $RxTxPpsMaximum"
            Write-LogInfo "RxTxPpsAverage = $RxTxPpsAverage"

            $CurrentTestResult.TestSummary += New-ResultSummary -testResult "$RxPpsAverage" -metaData "Rx Average PPS" `
                -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
            $CurrentTestResult.TestSummary += New-ResultSummary -testResult "$RxPpsMinimum" -metaData "Rx Minimum PPS" `
                -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
            $CurrentTestResult.TestSummary += New-ResultSummary -testResult "$RxPpsMaximum" -metaData "Rx Maximum PPS" `
                -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            $ErrorLine = $_.InvocationInfo.ScriptLineNumber
            Write-LogErr "EXCEPTION in Netperf log parsing : $ErrorMessage at line: $ErrorLine"
        }
        #endregion

        #region Upload results to Netperf DB.
        try {
            Write-LogInfo "Uploading the test results.."
            $dataSource = $GlobalConfig.Global.$TestPlatform.ResultsDatabase.server
            $user = $GlobalConfig.Global.$TestPlatform.ResultsDatabase.user
            $password = $GlobalConfig.Global.$TestPlatform.ResultsDatabase.password
            $database = $GlobalConfig.Global.$TestPlatform.ResultsDatabase.dbname
            $dataTableName = $GlobalConfig.Global.$TestPlatform.ResultsDatabase.dbtable
            $TestExecutionTag = $GlobalConfig.Global.$TestPlatform.ResultsDatabase.testTag
            if ($dataSource -And $user -And $password -And $database -And $dataTableName) {
                $GuestDistro = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
                $HostOS = cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
                $GuestOSType = "Linux"
                $GuestDistro = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
                $GuestSize = $clientVMData.InstanceSize
                $KernelVersion = cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}
                $IPVersion = "IPv4"
                $ProtocolType = "TCP"
                $SQLQuery = "INSERT INTO $dataTableName (TestExecutionTag,TestDate,HostType,HostBy,HostOS,GuestOSType,GuestDistro,GuestSize,KernelVersion,IPVersion,ProtocolType,DataPath,TestType,RxPpsMinimum,RxPpsAverage,RxPpsMaximum,TxPpsMinimum,TxPpsAverage,TxPpsMaximum,RxTxPpsMinimum,RxTxPpsAverage,RxTxPpsMaximum) VALUES "
                $SQLQuery += "('$TestExecutionTag','$(Get-Date -Format 'yyyy-MM-dd hh:mm:ss')','$TestPlatform','$TestLocation','$HostOS','$GuestOSType','$GuestDistro','$GuestSize','$KernelVersion','$IPVersion','$ProtocolType','$DataPath','$TestType','$RxPpsMinimum','$RxPpsAverage','$RxPpsMaximum','$TxPpsMinimum','$TxPpsAverage','$TxPpsMaximum','$RxTxPpsMinimum','$RxTxPpsAverage','$RxTxPpsMaximum')"
                Upload-TestResultToDatabase $SQLQuery
            } else {
                Write-LogErr "Invalid database details. Failed to upload result to database!"
            }
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            $ErrorLine = $_.InvocationInfo.ScriptLineNumber
            Write-LogErr "EXCEPTION in uploading netperf results to DB : $ErrorMessage at line: $ErrorLine"
        }
        #endregion

        if ($finalStatus -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status : $currentStatus."
            $testResult = "FAIL"
        }
        elseif ($finalStatus -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status : $currentStatus."
            $testResult = "ABORTED"
        }
        elseif ($finalStatus -imatch "TestCompleted") {
            Write-LogInfo "Test Completed."
            $testResult = "PASS"
        }
        Write-LogInfo "Test result : $testResult"
    }
    catch {
        $ErrorMessage = $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogErr "EXCEPTION : $ErrorMessage at line: $ErrorLine"
    }
    finally {
        if (!$testResult) {
            $testResult = "ABORTED"
        }
        $resultArr += $testResult
    }

    $currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
    return $currentTestResult
}

Main -TestParams (ConvertFrom-StringData $TestParams.Replace(";","`n")) -AllVmData $AllVmData -CurrentTestData $CurrentTestData
