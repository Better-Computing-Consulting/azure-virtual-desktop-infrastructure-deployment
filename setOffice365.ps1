mkdir .\temp
cd .\temp

$configfile = "configuration.xml"
New-Item -Path . -Name $configfile -ItemType "file"
Add-Content -Path $configfile -Value '<Configuration>'
Add-Content -Path $configfile -Value ' <Add OfficeClientEdition="64" Channel="Current">'
Add-Content -Path $configfile -Value '  <Product ID="O365ProPlusRetail">'
Add-Content -Path $configfile -Value '   <Language ID="en-US" />'
Add-Content -Path $configfile -Value '   <ExcludeApp ID="Groove" />'
Add-Content -Path $configfile -Value '   <ExcludeApp ID="Lync" />'
Add-Content -Path $configfile -Value '   <ExcludeApp ID="OneDrive" />'
Add-Content -Path $configfile -Value '   <ExcludeApp ID="OneNote" />'
Add-Content -Path $configfile -Value '   <ExcludeApp ID="Teams" />'
Add-Content -Path $configfile -Value '  </Product>'
Add-Content -Path $configfile -Value ' </Add>'
Add-Content -Path $configfile -Value ' <RemoveMSI/>'
Add-Content -Path $configfile -Value ' <Updates Enabled="FALSE"/>'
Add-Content -Path $configfile -Value ' <Display Level="None" AcceptEULA="TRUE" />'
Add-Content -Path $configfile -Value ' <Property Name="FORCEAPPSHUTDOWN" Value="TRUE"/>'
Add-Content -Path $configfile -Value ' <Property Name="SharedComputerLicensing" Value="1"/>'
Add-Content -Path $configfile -Value '</Configuration>'

try {
    $response = Invoke-WebRequest -UseBasicParsing "https://www.microsoft.com/en-us/download/confirmation.aspx?id=49117"
     
    $ODTUri = $response.links | Where-Object {$_.outerHTML -like "*click here to download manually*"}

    Invoke-WebRequest $ODTUri.href -OutFile .\officedeploymenttool.exe

    "Downloaded Office 385 Deployment tool"

    Start-Process -FilePath .\officedeploymenttool.exe -ArgumentList "/quiet /extract:.\" -Wait
    
    "Extracted Office 385 Deployment tool"
 }
catch {
     Throw "Failed to download and extract the Office Deployment tool with error $_."
}

try {
    Start-Process -FilePath .\setup.exe -ArgumentList "/configure $configfile" -Wait
    
    "Installed Office 365"
} 
catch {
    Throw "Failed to install Office 365 with error $_."
}


cd ..
Remove-Item -Recurse -Force .\temp
Remove-Item -Force $MyInvocation.MyCommand.Path
