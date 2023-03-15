# azure-virtual-desktop-infrastructure-deployment

This project will deploy an Azure Virtual Desktop infrastructure, including a Compute Gallery with a custom golden image, hostpool hosts, and an Azure DevOps project with two pipelines. One pipeline is triggered saving a new PowerShell onto the new_scrips directory. This pipeline will run the PowerShell script on a new VM that is deployed by attaching a hard drive created from a snapshot made before running Sysprep on the host from which the previous golden image version was created. The second pipeline runs on a schedule and will replace the existing hosts in the virtual desktop host pool, if they were created from an older golden image version.

These are some of the features of the Virtual Desktop infrastructure:
+ The OS of the hostpool servers is Windows 11 multisession.
+ The servers are joined to Azure Active Directory, so cloud-only accounts can log onto them.
+ The initial golden image for the servers is configured with FSLogix profiles using blob storage.
+ Line of sight to on-prem Active Directory is not required for user login or FSLogix profile redirection.
+ The connection string for the storage account containing the FSLogix profiles is stored in the server on a secure key. Thus, the connection string is not visible to users or administrators logged on to the server.
+ The initial golden image of the servers is also configured with automatic logon to OneDrive and silent redirection of users’ Document, Desktop and Pictures folders.
+ There is a private endpoint connection between the storage account and the subnet of the hostpool server, so connections to the FSLogix containers travel through Microsoft’s backbone.
+ The storage account has a Network Rule to allow connections only from the subnet containing the hostpool servers.
      
> :warning: To successfully run the scripts the user should have sufficient permissions to 1) deploy new resource groups and resources, 2) assign managed identities, create custom roles and service principals, and 3) create new DevOps projects.


To deploy the Virtual Desktop infrastructure run the **deployResources.sh**. This script will:

1.	Deploy the Resource group for the project and VNet.
2.	Deploy the storage account for the FSLogix containers.
3.	Setup the storage account Network Rule and private endpoint.
4.	Deploy a KeyVault and store the server’s administrator account username and random password to use through the life cycle of the project.
5.	Deploy a temporary VM using a marketplace image of Windows 11 multiuser.
6.	Install and configure FXLogix and OneDrive on the VM by remote executing the **setFSLogixOneDrive.ps1** script, which takes as arguments the storage account connection string and the tenant id.
7.	Create a snapshot of the VM’s OS disk.
8.	Run sysprep on the VM by remote executing the **sysprepVM.ps1** script.
9.	Deallocate and generalize the VM.
10.	Deploy a shared image gallery.
11.	Deploy an image definition.
12.	Create the first version of the image definition by capturing the temporary VM.
13.	Makes sure the Microsoft.DesktopVirtualization is registered for the tenant and adds the desktopvirtualization extension to the console.
14.	Deploys a Desktop virtualization hostpool, application group and workspace.
15.	Deploys a hostpool VM based on the first version of the image definition.
16.	Joins the VM to Azure Active Directory.
17.	Finally, joins the VM to the hostpool by remote executing the **setWVDClient.ps1** script, which install the client and takes as an argument the registration token from the hostpool.

When the **deployResources.sh** ends you grant access users access to the virtual desktop by running the **addAssignment.sh** script, which the project id and the user UPN as arguments. This script will:

1.	Assign *Virtual Machine User Login* to the user at the resource group level. This allows the user to remote login to Azure Active Directory joined server.
2.	Assign *Desktop Virtualization User* to the user the application group level, so the get the Virtual Desktop assigned.

This repository also includes an **updateImage.sh** script. The script the project id and the path to a PowerShell script, and will:

1.	Create a new disk based on the latest snapshot found on the project’s resource group.
2.	Create a new temp VM attaching the disk.
3.	Remotely execute the provided PowerShell script to install additional software or configurations.
4.	Take a new snapshot of the OS disk.
5.	Run sysprep on the VM by remote executing the **sysprepVM.ps1** script.
6.	Deallocate and generalize the VM.
7.	Finally, capture the VM as the next version of the image definition in the gallery.
8.	(The repository includes a **setOffice365.ps1** script under the **done_scripts** folder to test this functionality. It will install Office 365 on the target computer.)



This repository also includes a **deployNewImage.ps1** PowerShell script. This script takes the project id as an argument and will:

1.	Get the latest image definition version from the gallery.
2.	Check to see if there are any hostpool servers based on a different version of the image.
3.	If there is any such server, the script will create a new registration token from the hostpool. 
4.	get the administrator username and password from the keyvault.
5.	Deploy as many new servers as there are active servers in hostpool based on older image versions.
6.	For every new server deploy, the script adds the server to Azure Active Directory, and
7.	joins the VM to the hostpool by remote executing the **setWVDClient.ps1** script, which install the client and takes as an argument the registration token from the hostpool.
8.	Finally, it will disable connections to the old servers and deallocate them.


Both the **updateImage.sh** and **deployNewImage.ps1** can be run manually given the appropriate arguments. However, the repository also includes a **deployDevOpsProject.sh** script which will deploy a DevOps project that contains two pipelines to run these two scripts. The pipeline that run the **updateImage.sh** is triggered by saving a new **.ps1** script onto the **new_scrips** directory. The pipeline that runs the **deployNewImage.ps1** runs on a schedule.

> :warning: **An important note** relating to the update image pipeline. For it to work, after deploying the DevOps project you must **manually grant** ***Bypass policies when pushing*** and ***Contribute*** rights to the Project's **Build Service _User_ account** under **Project settings > Repositories > Security**. Otherwise, the GitHub command that commits the move of the script from the **new_script** to the **done_script** folder will fail.

The **deployDevOpsProject.sh** takes three arguments, the project’s id, the URL of your DevOps organization, and the URL of your clone of the GitHub repository. Before running the script you should run **az login** again, and export your PAT to the environment with the export **AZURE_DEVOPS_EXT_GITHUB_PAT=enter-github-pat-here** command. The script will:

1.	Create a custom role for the pipelines’s service account that allows assigning managed identities, which is required for Azure Active Directory joins.
2.	Create a service account with the new custom role scoped to the project’s resource group.
3.	Grant the service account access to the keyvault’s secrets.
4.	Create a DevOps project.
5.	Create a service endpoint for Azure.
6.	Create a service endpoint for GitHub.
7.	Create the update image pipeline based on the **update-image.yml** script.
8.	Create a variable for the pipeline with the username of the account running the script, to set the email of the GitHub user for the git commands.
9.	Create the deploy image pipeline based on the **deploy-image.yml** script.

I hope you find this project useful. 

Enjoy.
