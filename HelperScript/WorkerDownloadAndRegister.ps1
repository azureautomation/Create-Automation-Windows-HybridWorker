Param(
    [Parameter(Mandatory = $true)]
    [string] $workspaceId ,
    [Parameter(Mandatory = $true)]
    [string] $workspaceKey ,
    [Parameter(Mandatory = $false)]
    [string] $agentServiceEndpoint,
    [Parameter(Mandatory = $false)]
    [string] $aaToken,
    [Parameter(Mandatory = $false)]
    [string] $workerGroupName = "Test-Auto-Created-Worker"   
)

#Create path for the MMA agent download
$directoryPathForMMADownload="C:\temp"
if(!(Test-Path -path $directoryPathForMMADownload))  
{  
     New-Item -ItemType directory -Path $directoryPathForMMADownload
     Write-Host "Folder path has been created successfully at: " $directoryPathForMMADownload    
}
else 
{ 
    Write-Host "The given folder path $directoryPathForMMADownload already exists"; 
}

Write-Output "Downloading MMA Agent...."
$outputPath = $directoryPathForMMADownload + "\MMA.exe"
# need to update the MMA Agent exe link for gov clouds
Invoke-WebRequest "https://go.microsoft.com/fwlink/?LinkId=828603" -Out $outputPath

Start-Sleep -s 30


$changeDirectoryToMMALocation = "cd  $directoryPathForMMADownload"
Invoke-Expression $changeDirectoryToMMALocation

Write-Output "Extracting MMA Agent...."
$commandToInstallMMAAgent = ".\MMA.exe /c /t:c:\windows\temp\oms"
Invoke-Expression $commandToInstallMMAAgent

Start-Sleep -s 30


$tmpFolderOfMMA = "cd c:\windows\temp\oms"
Invoke-Expression $tmpFolderOfMMA

$cloudType = 0
Write-Output "Connecting LA Workspace to the MMA Agent...."
$commandToConnectoToLAWorkspace = '.\setup.exe /qn NOAPM=1 ADD_OPINSIGHTS_WORKSPACE=1 OPINSIGHTS_WORKSPACE_AZURE_CLOUD_TYPE=' + $cloudType + ' OPINSIGHTS_WORKSPACE_ID="'+ $workspaceId +'" OPINSIGHTS_WORKSPACE_KEY="'+ $workspaceKey+'" AcceptEndUserLicenseAgreement=1'
Invoke-Expression $commandToConnectoToLAWorkspace

Start-Sleep -Seconds 60

# wait until the MMA Agent downloads AzureAutomation on to the machine
$workerFolder = "C:\\Program Files\\Microsoft Monitoring Agent\\Agent\\AzureAutomation\\7.3.837.0\\HybridRegistration"
$i = 0
$azureAutomationPresent = $false
while($i -le 5)
{
    $i++
    if(!(Test-Path -path $workerFolder))  
    {  
        Start-Sleep -s 60
        Write-Host "Folder path is not present waiting..:  $workerFolder"    
    }
    else 
    { 
        $azureAutomationPresent = $true
        Write-Host "The given folder path $workerFolder already exists"
        break
    }
    Write-Verbose 'Timedout waiting for Automation folder.'
}

if($azureAutomationPresent){

    $itemLocation = "HKLM:\SOFTWARE\Microsoft\HybridRunbookWorker" 
    $existingRegistration = Get-Item -Path $itemLocation 
    if($null -ne $existingRegistration){ 
        Write-Output "Registry was found..." 
        Remove-Item -Path $itemLocation -Recurse
    } 
    else{   
        Write-Output "Not found..." 
    }

    $azureAutomationDirectory = "cd '$workerFolder'"
    Start-Sleep -s 10
    Invoke-Expression $azureAutomationDirectory

    Import-Module .\HybridRegistration.psd1
    Start-Sleep -s 10
    Add-HybridRunbookWorker -GroupName $workerGroupName -EndPoint $agentServiceEndpoint -Token $aaToken
}