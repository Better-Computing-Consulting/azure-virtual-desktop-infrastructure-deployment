#!/bin/bash

if [ -z "$3" ]; then
	echo "Pass:"
	echo "  1) projectId"
	echo "  2) URL of DevOps organization, and"
	echo "  3) URL of your clone of the github repository"
	exit
fi

set -ev

SECONDS=0
rgName=$1-RG

az config set defaults.group=$rgName core.output=tsv --only-show-errors

#
# Deploy DevOps Project and Pipelines
#
# Register Azure Service Principal for the pipelines with enough rights to deploy virtual machines,
# assign managed identities, and add them to hostpool.
spName=$1-sp
subscription_id=$(az account show --query id -o tsv)

sed -i "s/enter-subscription-id-here/$subscription_id/g" CustomRole.json

az role definition create --role-definition @CustomRole.json --only-show-errors --query "{roleType: roleType, roleName:roleName}" -o jsonc

sed -i "s/$subscription_id/enter-subscription-id-here/g" CustomRole.json

rgId=$(az group show --query id)

spkey=$(az ad sp create-for-rbac --name $spname --role "Custom VDI Demo Contributor Role" --scopes $rgId --only-show-errors --query password -o tsv)

#spKey=$(az ad sp create-for-rbac --name $spName --role "Website Contributor" --scopes $rgId --only-show-errors --query password)

#az login
#export AZURE_DEVOPS_EXT_GITHUB_PAT=enter-github-pat-here
export AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY=$spKey

az devops configure --defaults project=$1 organization=$2

# Create Azure DevOps project
az devops project create --name $1 --output none

# Create AzureRM service endpoint
spClientId=$(az ad sp list --display-name $spName --query [].appId)
subsId=$(az account show --query id)
subsName=$(az account show --query name)
tenantId=$(az account show --query tenantId)

azRMSvcId=$(az devops service-endpoint azurerm create --azure-rm-service-principal-id $spClientId \
	--azure-rm-subscription-id $subsId --azure-rm-subscription-name "$subsName" --azure-rm-tenant-id $tenantId \
	--name AzureServiceConnection --query id)

# Enable AzureRM service endpoint for all pipelines
az devops service-endpoint update --id $azRMSvcId --enable-for-all true --output none

# Create GitHub service endpoint
gitHubSvcId=$(az devops service-endpoint github create --github-url https://github.com/ --name GitHubService --project $1 --query id)

# Enable Github service endpoint for all pipelines
az devops service-endpoint update --id $gitHubSvcId --enable-for-all true --output none

# Create triggered update golden image pipeline
pipelineId=$(az pipelines create --name TriggeredUpdateImagePipeline --project $projectId --repository $3 --branch master \
	--yml-path update-image.yml --skip-first-run true --service-connection $gitHubSvcId --only-show-errors --query id)

echo $'\e[1;33m'$2/$projectId/_build?definitionId=$pipelineId$'\e[0m'

# Create cron deploy latest image ipeline
pipelineId=$(az pipelines create --name CronDeployImagePipeline --project $projectId --repository $3 --branch master \
        --yml-path deploy-image.yml --skip-first-run true --service-connection $gitHubSvcId --only-show-errors --query id)

echo $'\e[1;33m'$2/$1/_build?definitionId=$pipelineId$'\e[0m'

az devops configure --defaults project="" organization=""
az config unset defaults.group=$rgName core.output --only-show-errors

duration=$SECONDS
echo "$(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

