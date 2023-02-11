Remove-Item -Recurse -Force C:\Windows\Panther
Remove-Item "$PSScriptRoot\*" -Force
cd $env:windir\system32\sysprep
.\sysprep.exe /oobe /generalize /mode:vm /shutdown
