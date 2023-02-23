#!/bin/bash

if [ -z "$2" ]; then
	echo "Pass projectId and path to Powershell script"
	exit
fi

set -ev

SECONDS=0
location="westus"
rgName=$1-RG
imageGalery=${1}_Galery
imageDefinitionName=Windows11MultiUser-VDI-Apps

az config set defaults.location=$location defaults.group=$rgName core.output=tsv --only-show-errors

az snapshot list --query "[].{Name:name, TimeCreated:timeCreated}" -o table

az sig image-version list -r $imageGalery -i $imageDefinitionName -o table

#
# Get the id of the most recent snapshot, i.e., the one with highest created time.
# Then create a disk from it and attach it to a new vm.
#
ssId=$(az snapshot list --query "[max_by(@, &timeCreated).id]")

osDiskName=osDisk$RANDOM

az disk create -n $osDiskName --sku Premium_LRS --hyper-v-generation V2 --source $ssId --output none

vmName=VDImageVM01

vmId=$(az vm create -n $vmName \
	--attach-os-disk $osDiskName \
	--os-type Windows \
	--nsg "" \
	--public-ip-address "" \
	--nic-delete-option Delete \
	--os-disk-delete-option Delete --query id --only-show-errors)
	
#
# Run the powershell script that will further customize the what will be the next version of the golden image
#	
cmdResult=$(az vm run-command invoke --command-id RunPowerShellScript -n $vmName --scripts @$2 --query value[0].message)

sed 's/\\n/\'$'\n''/g' <<< $cmdResult

#
# Reboot the computer, prior to remotely submitting powershell scrip to Sysprep server. 
# Take a snapshot of the disk to use in the next customization of the image, 
# then dealocate and generalize the vm in prepartion to image capture.
#
az vm restart --name $vmName

az vm get-instance-view -n $vmName --query "instanceView.statuses[?starts_with(code, 'PowerState')].displayStatus" -o jsonc

az snapshot create -n ${vmName}-OSDisk-$(date +%Y%m%d%H%M) --source $osDiskName --hyper-v-generation V2 --output none

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
# Increment the patch numeber of the image version in the variable that we pass to the command that creates the new image version.
# And lastly, delete the vm.
#
latestversion=$(az sig image-version list -r $imageGalery -i $imageDefinitionName --query "[max_by(@, &publishingProfile.publishedDate).name]")

parts=(${latestversion//./ })
nextVersion=${parts[0]}.${parts[1]}.$((parts[2]+1))

az sig image-version create  -r $imageGalery -i $imageDefinitionName -e $nextVersion --virtual-machine $vmId --output none

az vm delete -n $vmName --force-deletion yes -y

az snapshot list --query "[].{Name:name, TimeCreated:timeCreated}" -o table

az sig image-version list -r $imageGalery -i $imageDefinitionName -o table

az config unset defaults.location defaults.group core.output --only-show-errors

duration=$SECONDS
echo "$(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."
