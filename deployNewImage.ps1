param (
    [string]$projectId = $(throw "-projectId is required.")
)
Update-AzConfig -DisplayBreakingChangeWarning $false
$ErrorActionPreference = "Stop"
$rgName = $projectId + "-RG"
$location = "westus"


#
# Determine what is the latest golden image version in the Gallery.
#
$imageGalery = $projectId + "_Galery"
$imgVersions = Get-AzGalleryImageVersion -ResourceGroupName $rgName -GalleryName $imageGalery -GalleryImageDefinitionName Windows11MultiUser-VDI-Apps
$latestImage = $imgVersions | select -first 1
foreach ($ver in $imgVersions){
    if ($latestImage.PublishingProfile.PublishedDate -lt $ver.PublishingProfile.PublishedDate){
        $latestImage = $ver
    }
}

#
# Determine how many of the current hosts were deployed using and older image version.
#
$hostPool = $projectId + "-HP"
$activeHosts = Get-AzWvdSessionHost -ResourceGroupName $rgName -HostPoolName $hostPool | where {$_.AllowNewSession -eq $true} 
foreach ($ahost in $activeHosts){ 
        $vm = Get-AzVM -ResourceId $ahost.ResourceId
        "Current SessionHost version: " + $vm.StorageProfile.ImageReference.ExactVersion
        "Most recent version name: " + $latestImage.name
        if ($vm.StorageProfile.ImageReference.ExactVersion -ne $latestImage.name){
            $hostsToReplace += 1
        }
}

#
# If there are no hosts created with an older image version, end the script.
#
if ( $hostsToReplace -eq 0 ){ 
    "All host are at the latest image version"
    Exit 
}
"Number of hosts to replace: " + $hostsToReplace

#
# Get the information required to deploy new hosts, i.e, Pool registration key, VNet info, Username and Password
#
$registrationInfo = New-AzWvdRegistrationInfo -ResourceGroupName $rgName -HostPoolName $hostPool -ExpirationTime $((get-date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))

$Vnet = Get-AzVirtualNetwork -Name  "VDIVnet" -ResourceGroupName $rgName

$vault = $projectId + "-KV"

$pubIp = (Invoke-WebRequest -uri “https://api.ipify.org/”).Content

#
# Grant KeyVault access to the current public IP and retrieve the VDI host username and password, and remove access when done.
#
Add-AzKeyVaultNetworkRule -VaultName $vault -IpAddressRange $pubIp
$vdiHostAdminUsername = Get-AzKeyVaultSecret -VaultName $vault -Name vdiHostAdminUsername -AsPlainText
$textPassword = Get-AzKeyVaultSecret -VaultName $vault -Name vdiHostAdminPassword -AsPlainText
Remove-AzKeyVaultNetworkRule -VaultName $vault -IpAddressRange $pubIp

$vdiHostAdminPassword = ConvertTo-SecureString $textPassword -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($vdiHostAdminUsername, $vdiHostAdminPassword);

$justId = $projectId -replace "[^0-9]" , ''

#
# Include the image version number in the vm name.
#
$vmName = "sh" + $justId + "v" + $latestImage.name.Replace(".","") + "-"

#
# Create as many hosts as there are currently with dated image versions.
#
for($i = 1;$i -le $hostsToReplace;$i++)
{
    "Deploying host " + $i + " of " + $hostsToReplace
    $newVMName = $vmName + $i
    $newVMName
    $NICName = $newVMName + "VMNic"
    $NIC = New-AzNetworkInterface -Name $NICName -ResourceGroupName $rgName -Location $Location -SubnetId $Vnet.Subnets[0].Id

    $VM = New-AzVMConfig -VMName $newVMName -VMSize "Standard_DS1_v2" -IdentityType SystemAssigned
    $VM = Set-AzVMOperatingSystem -VM $VM -Windows -ComputerName $newVMName -Credential $Credential -ProvisionVMAgent -EnableAutoUpdate
    $VM = Set-AzVMOSDisk -VM $VM -DeleteOption Delete -CreateOption FromImage
    $VM = Set-AzVMBootDiagnostic -VM $VM -Disable
    $VM = Add-AzVMNetworkInterface -VM $VM -Id $NIC.Id -DeleteOption Delete
    $VM = Set-AzVMSourceImage -VM $VM -Id $latestImage.id

    "Deploying VM " + $newVMName
    New-AzVM -ResourceGroupName $rgName -Location $location -VM $VM -LicenseType Windows_Client -DisableBginfoExtension -Verbose

    "Joining VM " + $newVMName + " to AAD"
    Set-AzVMExtension -ResourceGroupName $rgName -VMName $newVMName -Name  "AADLoginForWindows" -Location $VM.Location `
        -Publisher "Microsoft.Azure.ActiveDirectory" -Type "AADLoginForWindows" -TypeHandlerVersion "0.4"
    
    "Adding VM " + $newVMName + " to Host Pool"
    Invoke-AzVMRunCommand -ResourceGroupName $rgName -Name $newVMName -CommandId 'RunPowerShellScript' -ScriptPath 'setWVDClient.ps1' -Parameter @{registrationtoken = $registrationInfo.Token}
}

#
# Disable and deallocate previous-version hosts.
#
foreach ($shost in $activeHosts){ 
        $vm = Get-AzVM -ResourceId $shost.ResourceId
        $vm.Name
        if ($vm.StorageProfile.ImageReference.ExactVersion -ne $latestImage.name){
            "Disabling new sessions on VM: " + $vm.Name
            Update-AzWvdSessionHost -ResourceGroupName $rgName `
                            -HostPoolName $hostPool `
                            -Name $vm.Name `
                            -AllowNewSession:$false
            if ($shost.Session -eq 0){ 
                "Stopping VM: " + $vm.Name
                Stop-AzVM -Id $vm.Id -Force
            }
        }
}