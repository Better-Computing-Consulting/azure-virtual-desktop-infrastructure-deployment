param (
    [string]$connectionString = $(throw "-connectionString is required."),
    [string]$tennantId = $(throw "-tennantId is required.")
)
mkdir .\temp
cd .\temp

#Download fxlogix
try {
    Invoke-WebRequest 'https://aka.ms/fslogix_download' -OutFile '.\fslogix.zip'
    Expand-Archive '.\fslogix.zip'
    $FsLogixInstallFile = Get-ChildItem -Path .\fslogix -Recurse -Include 'FSLogixAppsSetup.exe' | where {$_.FullName -match 'x64'}
    "Downloaded FSLogix"
} 
catch {
    Throw "Failed to download FSLogix"
}
#Install fxlogix
try {
    Start-Process -FilePath $FsLogixInstallFile -ArgumentList "/quiet /norestart" -Wait
    "Installed FSLogix"
}
catch {
    Throw "FSLogix not installed $_"
}
#Download PSTools
try {
    Invoke-WebRequest 'https://download.sysinternals.com/files/PSTools.zip' -OutFile PSTools.zip
    Expand-Archive PSTools.zip
    "Downloaded PSTools"
} 
catch {
    Throw "Failed to download PSTools"
}
#Add secure key to credential manager
if ((Test-Path ".\PSTools\PsExec.exe") -and (Test-Path "C:\Program Files\FSLogix\Apps\frx.exe")){
    try {
        .\PSTools\PsExec.exe -s -accepteula "C:\Program Files\FSLogix\Apps\frx.exe" add-secure-key -key='connectionString' -value="$connectionString"
    }
    catch {
        "Error adding key: $_"
    }
}
else{
    "not both exist"
}

#Configure FXLogix
if(Test-Path HKLM:\Software\FSLogix\Profiles){
    New-ItemProperty -Path "HKLM:\Software\FSLogix\Profiles" `
        -Name "Enabled" `
        -PropertyType:DWord `
        -Value 1 -Force
    New-ItemProperty -Path "HKLM:\Software\FSLogix\Profiles" `
        -Name "CCDLocations" `
        -PropertyType:String `
        -Value "type=azure,connectionString=|fslogix/connectionString|" -Force
    New-ItemProperty -Path "HKLM:\Software\FSLogix\Profiles" `
        -Name "VolumeType" `
        -PropertyType:String -Value vhdx -Force
    New-ItemProperty -Path "HKLM:\Software\FSLogix\Profiles" `
        -Name "DeleteLocalProfileWhenVHDShouldApply" `
        -PropertyType:dword `
        -Value 1 -Force
    New-ItemProperty -Path "HKLM:\Software\FSLogix\Profiles" `
        -Name "FlipFlopProfileDirectoryName" `
        -PropertyType:dword `
        -Value 1 -Force
}

#Silently move Windows known folders to OneDrive

$HKLMregistryPath = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'

if(!(Test-Path HKLM:\SOFTWARE\Microsoft\OneDrive)){
    Invoke-WebRequest 'https://go.microsoft.com/fwlink/p/?LinkID=2182910' -OutFile OneDriveSetup.exe
    Start-Process -FilePath ./OneDriveSetup.exe -ArgumentList "/allusers /silent" -Wait
    $oneDrivePath = 'C:\Program Files\Microsoft OneDrive\OneDrive.exe'
    if(Test-Path "C:\Program Files (x86)\Microsoft OneDrive\OneDrive.exe"){ $oneDrivePath = "C:\Program Files (x86)\Microsoft OneDrive\OneDrive.exe"}
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -PropertyType:String -Value $oneDrivePath -Force
}

if(!(Test-Path $HKLMregistryPath)){New-Item -Path $HKLMregistryPath -Force > $null}
New-ItemProperty -Path $HKLMregistryPath -Name 'SilentAccountConfig' -PropertyType:DWord  -Value '1' -Force 
New-ItemProperty -Path $HKLMregistryPath -Name "KFMSilentOptIn" -PropertyType:String -Value $tennantId -Force
New-ItemProperty -Path $HKLMregistryPath -Name 'FilesOnDemandEnabled' -PropertyType:DWord -Value '1' -Force

try {
    Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
    Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
    rm .\AzureCLI.msi
    "Installed AzureCLI"
} 
catch {
    Throw "Failed to install AzureCLI"
}

cd ..
Remove-Item -Recurse -Force .\temp
Remove-Item -Force $MyInvocation.MyCommand.Path
