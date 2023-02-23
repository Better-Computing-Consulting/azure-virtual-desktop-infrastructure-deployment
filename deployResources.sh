#!/bin/bash

set -ev

SECONDS=0
projectId=bccVDIDemo$RANDOM

echo $'\e[1;33m'$projectId$'\e[0m'

location="westus"
rgName=$projectId-RG

az config set defaults.location=$location defaults.group=$rgName core.output=tsv --only-show-errors

az group create -n $rgName -o none

#
# Deploy the VNet for the vdi hosts and the storage account to be used for the FXLogix profiles.
# Allow access to the storage account only from the VDI hosts subnet, and create 
# a private endpoint between the storage account and subnet.
#
az network vnet create -n VDIVNet --address-prefix 172.23.0.0/16 -o none

subnetId=$(az network vnet subnet create --vnet-name VDIVNet -n VDIHostsSubnet --address-prefixes 172.23.3.0/24 --service-endpoints Microsoft.Storage --query id)

storageAccName=$(echo ${projectId,,})sa

saId=$(az storage account create -n $storageAccName --sku Standard_LRS --default-action Deny --bypass AzureServices --query id --only-show-errors)

az resource list --query "[].{Name:name, Type:type}" -o table

az storage account network-rule add -n $storageAccName --subnet $subnetId -o none

az network private-endpoint create \
    --connection-name $projectId-Connection \
    --name $projectId-Endpoint \
    --private-connection-resource-id $saId \
    --resource-group $rgName \
    --subnet $subnetId \
    --group-id blob -o none
	
az resource list --query "[].{Name:name, Type:type}" -o table

#
# Create random password and store it, along with the vdi host username, store it on a KeyVault, 
# and change the default action of the KeyVault to Deny.
#
vdiHostAdminUsername=vdivmadmin
vdiHostAdminPassword=$(openssl rand -base64 8)

keyVaultName=$projectId-KV

az keyvault create -n "$keyVaultName" -o none
az keyvault secret set --vault-name $keyVaultName --name vdiHostAdminUsername --value $vdiHostAdminUsername -o none
az keyvault secret set --vault-name $keyVaultName --name vdiHostAdminPassword --value $vdiHostAdminPassword -o none
az keyvault update -n "$keyVaultName" --default-action Deny -o none

#
# Deploy the base vm that will be used as source for the first image version of the golden image.
#
vmName=VDImageVM01

vmId=$(az vm create -n $vmName \
	--image MicrosoftWindowsDesktop:windows-11:win11-22h2-avd:22621.1105.230107 \
	--admin-username $vdiHostAdminUsername \
	--admin-password $vdiHostAdminPassword \
	--nsg "" \
	--public-ip-address "" \
	--os-disk-caching None \
	--nic-delete-option Delete \
	--os-disk-delete-option Delete --query id --only-show-errors)

az resource list --query "[].{Name:name, Type:type}" -o table

#	
# Execute on vm the powershell script that will use the connection string from the storage account
# to setup FXLogix and the tenant id to configure OneDrive to silently move windows known folders.
#
connStr=$(az storage account show-connection-string -n $storageAccName)
tenantId=$(az account show --query tenantId)

cmdResult=$(az vm run-command invoke --command-id RunPowerShellScript -n $vmName --scripts @setFSLogixOneDrive.ps1 --parameters "connectionString=$connStr" "tennantId=$tenantId" --query value[0].message)

sed 's/\\n/\'$'\n''/g' <<< $(sed "s|$tenantId|xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx|g" <<< $cmdResult)

#
# Reboot the computer prior to running the powershell script to sysprep the server. 
# Take a snapshot of the disk to use in the next customization of the image, 
# then deallocate and generalize the vm in prepartion to image capture.
#
az vm restart --name $vmName

az vm get-instance-view -n $vmName --query "instanceView.statuses[?starts_with(code, 'PowerState')].displayStatus" -o jsonc

osdsk=$(az vm show -n $vmName --query storageProfile.osDisk.managedDisk.id)

az snapshot create -n ${vmName}-OSDisk-$(date +%Y%m%d%H%M) --source $osdsk --hyper-v-generation V2 -o none

az vm run-command invoke --command-id RunPowerShellScript -n $vmName --scripts @sysprepVM.ps1 -o jsonc

vmState=$(az vm get-instance-view -n $vmName --query "instanceView.statuses[?starts_with(code, 'PowerState')].displayStatus")
while [ "$vmState" != "VM stopped" ]
do
	echo $vmState
	sleep 2
	vmState=$(az vm get-instance-view -n $vmName --query "instanceView.statuses[?starts_with(code, 'PowerState')].displayStatus")
done

az vm deallocate -n $vmName
az vm generalize -n $vmName

#
# Create the Compute Galery and Image definition to store the different versions of the golden image.
#
imageGalery=${projectId}_Galery
imageDefinitionName=Windows11MultiUser-VDI-Apps

az sig create -r $imageGalery -o none

az sig image-definition create -r $imageGalery -i $imageDefinitionName -f windows-11 -p MicrosoftWindowsDesktop -s win11-22h2-avd --os-type Windows --hyper-v-generation V2 -o none

az resource list --query "[].{Name:name, Type:type}" -o table

#
# Create the image first version by capturing the vm, and then delete the vm.
#
imgId=$(az sig image-version create  -r $imageGalery -i $imageDefinitionName -e 0.1.0 --virtual-machine $vmId --query id)

az vm delete -n $vmName --force-deletion yes -y

az resource list --query "[].{Name:name, Type:type}" -o table

#
# Make sure the tenant and the current console meet the requirement to deploy Virtual Desktop
#
az provider register --namespace Microsoft.DesktopVirtualization
vdProviderState=$(az provider show --namespace Microsoft.DesktopVirtualization --query registrationState -o tsv)
while [ "$vdProviderState" != "Registered" ]
do
	echo $vdProviderState
	sleep 2
	vdProviderState=$(az provider show --namespace Microsoft.DesktopVirtualization --query registrationState -o tsv)
done

az extension add --upgrade -n desktopvirtualization --only-show-errors

#
# Deploy the host pool making sure the rdp settings include targetisaadjoined, as the hosts will be Azure AD joined. 
# Then, deploy the application group and workspace.
#
rdpSettings='audiomode:i:0;videoplaybackmode:i:1;devicestoredirect:s:*;enablecredsspsupport:i:1;redirectwebauthn:i:1;targetisaadjoined:i:1;redirectclipboard:i:1'

hostPoolId=$(az desktopvirtualization hostpool create -n $projectId-HP \
	--custom-rdp-property "$rdpSettings" \
	--host-pool-type "Pooled" \
	--load-balancer-type "DepthFirst" \
	--preferred-app-group-type "Desktop" \
	--friendly-name "VDI Demo" \
	--start-vm-on-connect true \
	--validation-environment false \
	--registration-info expiration-time=$(date +"%Y-%m-%dT%H:%M:%S.%7NZ" -d "$DATE + 1 day") registration-token-operation="Update" \
	--max-session-limit 10 --query id)

agId=$(az desktopvirtualization applicationgroup create -n $projectId-AG -g $rgName \
	--location $location \
	--application-group-type "Desktop" \
	--host-pool-arm-path $hostPoolId --query id)
	
az desktopvirtualization workspace create -n $projectId-Workspace --application-group-references $agId -o none

az resource list --query "[].{Name:name, Type:type}" -o table

#
# Deploy the first vdi host vm based on the first version of the golden image, assign it a managed identity, and 
# join the server to Azure AD.)
#
vmName=sh$(sed 's/[^0-9]*//g' <<< $projectId)v010-1

az vm create -n $vmName \
	--image $imgId \
	--nsg "" \
	--public-ip-address "" \
	--admin-username $vdiHostAdminUsername \
	--admin-password $vdiHostAdminPassword \
	--enable-agent true \
	--assign-identity \
	--license-type Windows_Client \
	--nic-delete-option Delete \
	--os-disk-delete-option Delete --only-show-errors -o none
	
az vm extension set --publisher Microsoft.Azure.ActiveDirectory -n AADLoginForWindows --vm-name $vmName -o none

#
# Lastly, add the server to the hostpool using its registration token as command line argument to the powershell
# script that downloads and installs the  WVD Agent.
#
hpToken=$(az desktopvirtualization hostpool retrieve-registration-token --ids $hostPoolId --query token)

cmdOutput=$(az vm run-command invoke --command-id RunPowerShellScript -n $vmName --scripts @setWVDClient.ps1 --parameters "registrationtoken=$hpToken" --query value[0].message)

sed 's/\\n/\'$'\n''/g' <<< $cmdOutput

az resource list --query "[].{Name:name, Type:type}" -o table

az config unset defaults.location defaults.group core.output --only-show-errors

duration=$SECONDS
echo "$(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

set +v
echo To grant a test user access to the Application Group and VDI hosts run:
echo
echo $'\e[1;33m'./addAssignment.sh $projectId '<testUserUPN>'$'\e[0m'
echo
echo To deploy the DevOps project with pipelines to automate update and replacement of vdi hosts run:
echo
echo $'\e[1;33m'az login$'\e[0m'
echo $'\e[1;33m'export AZURE_DEVOPS_EXT_GITHUB_PAT=enter-github-pat-here$'\e[0m'
echo $'\e[1;33m'./deployDevOpsProject.sh $projectId '<URL of Azure DevOps organization>' '<URL of cloned GitHub repository>' $'\e[0m' 
echo
