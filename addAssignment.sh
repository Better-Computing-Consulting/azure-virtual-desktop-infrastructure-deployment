#!/bin/bash
set -ev
if [ -z "$2" ]; then
	echo "Pass projectId and UPN of test user"
else
	rgId=$(az group show --name $1-RG --query id -o tsv)

	az role assignment create --assignee $2 --role 'Virtual Machine User Login' --scope $rgId --output none
	
	agId=$(az desktopvirtualization applicationgroup show -g $1-RG -n $1-AG --query id -o tsv)
	
	az role assignment create --assignee $2 --role 'Desktop Virtualization User' --scope $agId --output none
fi
