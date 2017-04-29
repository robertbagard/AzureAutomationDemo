workflow demo-provision-windows-web-farm
{
    $StartDate= GET-DATE
    $c = Get-AutomationConnection -Name 'AzureRunAsConnection'
    Add-AzureRmAccount -ServicePrincipal -Tenant $c.TenantID -ApplicationID $c.ApplicationID -CertificateThumbprint $c.CertificateThumbprint
    
    #Azure Automation Account Variables (8)
    $vmInstanceCount=Get-AutomationVariable -Name 'NumberOfVMs' #How many instances should be provisioned
    $vmPrefixName = Get-AutomationVariable -Name 'VMPrefixName'#How vm should be named
    $resourceGroupName = Get-AutomationVariable -Name 'ResourceGroupName' #How Resource Group Should be named
    $location = Get-AutomationVariable -Name 'Location' #Where resources will be reated
    $username = Get-AutomationVariable -Name 'UserName' #Windows vm administrator username 
    $password = Get-AutomationVariable -Name 'Password' #Windows vm administrator password
    $tagDepartmentName = Get-AutomationVariable -Name 'TagDepartmentName' #What is department name
    $tagEnvironmentName = Get-AutomationVariable -Name 'TagEnvironmentName' #What is environment name
   
    
    $vnetName = $resourceGroupName + '-vnet'
    $vnetPrefix = '10.0.0.0/16'
    $subnetName = 'SubLBBackend'
    $subnetPrefix = '10.0.0.0/24'
    $lbName = $resourceGroupName + '-lb'
    
    $avSetName = $resourceGroupName + '-avset'
    
    $vmSize = 'Standard_D1_v2'
    $publisherName = 'MicrosoftWindowsServer'
    $offer = 'WindowsServer'
    $sku = '2016-Datacenter'
    $version = 'latest'
    $vmosDiskSize = 128
 
    $resourceGroup = New-AzureRmResourceGroup -Name $resourceGroupName -Location $location
    $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
    $credentials = New-Object System.Management.Automation.PSCredential -ArgumentList $username,$securePassword
     
    $avSet = New-AzureRmAvailabilitySet -ResourceGroupName $resourceGroupName -Name $avSetName -Location $location -PlatformUpdateDomainCount 5 -PlatformFaultDomainCount 3
    
    InlineScript {

        $vnet = New-AzureRmVirtualNetwork -Name $using:vnetName -ResourceGroupName $using:resourceGroupName -Location $using:location -AddressPrefix $using:vnetPrefix
        $subnet = Add-AzureRmVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $using:subnetName -AddressPrefix $using:subnetPrefix
        $vnet = Set-AzureRmVirtualNetwork -VirtualNetwork $vnet
        
        $publicIplbName = $using:resourceGroupName + 'lb-pip' 
        $feIplbConfigName = $using:resourceGroupName + '-felbipconf'
        $beAddressPoolConfigName = $using:resourceGroupName + 'beipapconf'
        

        $pip = New-AzureRmPublicIpAddress -Name $publicIplbName -ResourceGroupName $using:resourceGroupName -Location $using:location -AllocationMethod Dynamic
        $feIplbConfig = New-AzureRmLoadBalancerFrontendIpConfig -Name $feIplbConfigName -PublicIpAddress $pip
        $beIpAaddressPoolConfig = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name $beAddressPoolConfigName
    
        $healthProbeConfig = New-AzureRmLoadBalancerProbeConfig -Name HealthProbe -RequestPath '\' -Protocol http -Port 80 -IntervalInSeconds 15 -ProbeCount 2
        $lbrule = New-AzureRmLoadBalancerRuleConfig -Name HTTP -FrontendIpConfiguration $feIplbConfig -BackendAddressPool $beIpAaddressPoolConfig -Probe $healthProbeConfig -Protocol Tcp -FrontendPort 80 -BackendPort 80
        $lb = New-AzureRmLoadBalancer -ResourceGroupName $using:resourceGroupName -Name $using:lbName -Location $using:location -FrontendIpConfiguration $feIplbConfig -LoadBalancingRule $lbrule -BackendAddressPool $beIpAaddressPoolConfig -Probe $healthProbeConfig
    }

    ForEach -Parallel ($i in 1..$vmInstanceCount)
    {
        
        InlineScript {    
            $publicIpName = $using:resourceGroupName + $Using:vmPrefixName + [string]$using:i + '-pip' + [string]$using:i
            $nicName= $using:resourceGroupName + $Using:vmPrefixName+ [string]$using:i + '-nic' +[string]$using:i
            $vmName = $Using:vmPrefixName + [string]$using:i
            $vmosDiskName = $resourceGroupName + $vmName + '-osdisk'
            $vnet = Get-AzureRmVirtualNetwork -ResourceGroupName $using:resourceGroupName -Name $using:vnetName 
            $lb = Get-AzureRmLoadBalancer -ResourceGroupName $using:resourceGroupName -Name $using:lbName
            $publicIpvm = New-AzureRmPublicIpAddress -ResourceGroupName $using:resourceGroupName -Name $using:publicIpName  -Location $using:location -AllocationMethod Dynamic
            $nic = New-AzureRmNetworkInterface -ResourceGroupName $using:resourceGroupName -Name $nicName  -Location $using:location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $publicIpvm.Id -LoadBalancerBackendAddressPoolId $lb.BackendAddressPools[0].Id
            $vm = New-AzureRmVMConfig -VMName $using:vmName -VMSize $using:vmSize -AvailabilitySetId $using:avSet.Id
            $vm = Add-AzureRmVMNetworkInterface -VM $vm -Id $nic.Id
            $randomnumber = Get-Random -Minimum 0 -Maximum 99999
            $tempName = ($using:resourceGroupName + $using:vmName + 'stor' + $randomnumber).ToLower()
            #Finding available unque storage namespace
            $nameAvail = Get-AzureRmStorageAccountNameAvailability -Name $tempName
            If ($nameAvail.NameAvailable -ne $true) {
                Do {
                    $randomNumber = Get-Random -Minimum 0 -Maximum 999999
                    $tempName = $using:resourceGroupName + $using:vmName + $randomnumber
                    $nameAvail = Get-AzureRmStorageAccountNameAvailability -Name $tempName
                }
                Until ($nameAvail.NameAvailable -eq $True)
            }
            $storageAccountName = $tempName
            $storageAccount = New-AzureRmStorageAccount -ResourceGroupName $using:resourceGroupName -Name $storageAccountName -SkuName "Standard_LRS" -Kind "Storage" -Location $using:location
            $vm = Set-AzureRmVMOperatingSystem -VM $vm -Windows -ComputerName $using:vmName -Credential $using:credentials -ProvisionVMAgent -EnableAutoUpdate
            $vm = Set-AzureRmVMSourceImage -VM $vm -PublisherName $using:publisherName -Offer $using:offer -Skus $using:sku -Version $using:version
            $blobPath = 'vhds/' + $using:vmosDiskName + '.vhd'
            $osDiskUri = $storageAccount.PrimaryEndpoints.Blob.ToString() + $blobPath
            $vm = Set-AzureRmVMOSDisk -VM $vm -Name $using:vmosDiskName -VhdUri $osDiskUri -CreateOption fromImage
            New-AzureRmVM -ResourceGroupName $using:resourceGroupName -Location $using:location -VM $vm
            # Install IIS Web Server on VM
            $PublicSettings = '{"commandToExecute":"powershell Add-WindowsFeature Web-Server"}'
            Set-AzureRmVMExtension -ExtensionName "IIS" -ResourceGroupName $using:resourceGroupName -VMName $using:vmName -Publisher "Microsoft.Compute" -ExtensionType "CustomScriptExtension" -TypeHandlerVersion 1.4 -SettingString $PublicSettings -Location $using:location
        }
    }
   
    #creating tags
    Checkpoint-Workflow

    InlineScript{
        Set-AzureRmResourceGroup -Name $using:resourceGroupName  -Tag @{ Dept=$using:tagDepartmentName ; Environment=$using:tagEnvironmentName }
        $groups = Get-AzureRmResourceGroup -ResourceGroupName $using:resourceGroupName -Location $using:location
        foreach ($g in $groups) 
        {
           Find-AzureRmResource -ResourceGroupNameEquals $g.ResourceGroupName | ForEach-Object {Set-AzureRmResource -ResourceId $_.ResourceId -Tag $g.Tags -Force }
        }
    }
    $EndDate=GET-DATE
    $timereslut = NEW-TIMESPAN –Start $StartDate –End $EndDate
    Write-Output $timereslut
}