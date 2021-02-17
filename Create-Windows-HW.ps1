<# 
 This runbook aids users in Creating Windows User Hybrid workers.
 This script must be executed on a Run As Enabled Automation Account only.   
 This would require the following modules to be present in the Automation account :  
 Az.Accounts, Az.Resources, Az.Automation, Az.OperationalInsights, Az.Compute 

 The script could even create (if needed) a Log Analaytics Workspace and also a VM to be registered as User Hybrid worker.
#>



<#
    location : Location where you would want to create or get the LA Workspace from.
    ResourceGroupName : ResourceGroup in which the automation account is present and where you want the resources created as part of this script lie.
    AccountName : Automation Account name in which the Hybrid worker has to be registered.
    WorkspaceName : Name of the Log Analytics workspace, the script will create new one if not already present. Else, it enable "AzureAutomation" solution on the workspace.
    CreateVM : True, creates a new VM with the given VMName in the given VM location. False, Uses the given VMName for registering it as Hybrid worker.
    vmName : Name of the VM
    vmlocation : Location where the VM is present or has to be created. Default is the location given in the first parameter.
    WorkerGroupName : Name of the Hybrid Worker Group. 
#>
Param(
    [Parameter(Mandatory = $true)]
    [string] $location,  
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroupName,
    [Parameter(Mandatory = $true)]
    [string] $AccountName = "",
    [Parameter(Mandatory = $false)]
    [string] $WorkspaceName = "LAWorkspaceForAutomationHW",
    [Parameter(Mandatory = $true)]
    [bool] $CreateVM,
    [Parameter(Mandatory = $false)]
    [String] $vmName="VMForHW",
    [Parameter(Mandatory = $false)]
    [String] $vmlocation,
    [Parameter(Mandatory = $true)]
    [String] $WorkerGroupName
)
 
$ErrorActionPreference = "Stop"
$guid_val = [guid]::NewGuid()
$guid = $guid_val.ToString()


# Connect using RunAs account connection
$agentEndpoint = ""
$aaPrimaryKey = ""
$workspaceId = ""
$workspacePrimaryKey = ""
$vmlocation = $location

$connectionName = "AzureRunAsConnection"
try {  
    Write-Output  "Logging in to Azure..." -verbose
    $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName  
        
    Connect-AzAccount `
    -ServicePrincipal `
    -TenantId $servicePrincipalConnection.TenantId `
    -ApplicationId $servicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
}
catch {
    Write-Error -Message $_.Exception
    throw $_.Exception
}

#Get-Automation Account
Write-Output  "Getting Automation Account....."

try {
    ($Account = Get-AzAutomationAccount -Name $AccountName -ResourceGroupName $ResourceGroupName) | Out-Null 
    if ($Account.AutomationAccountName -like $AccountName) {
        ($accRegInfo = Get-AzAutomationRegistrationInfo -ResourceGroup $ResourceGroupName -AutomationAccountName  $AccountName) | Out-Null
        $agentEndpoint = $accRegInfo.Endpoint
        $aaPrimaryKey = $accRegInfo.PrimaryKey

        Write-Output "Automation Account details retrieved to be used for HW creation"
    } 
    else {
        Write-Error "HWG Creation :: Account retrieval failed"
    }
}
catch {
    Write-Error "HWG Creation :: Account retrieval failed"
}


### Create an LA workspace

if ($WorkspaceName -eq "LAWorkspaceForAutomationHW") {
    $workspace_guid = [guid]::NewGuid()
    $WorkspaceName = $WorkspaceName + $workspace_guid.ToString()
}

# Create a new Log Analytics workspace if needed
try {
    $laworkspace = Get-AzResource -ResourceGroupName $ResourceGroupName -Name $WorkspaceName

    if ($null -eq $laworkspace) {
        Write-Output  "Creating LA Workspace...."
        New-AzOperationalInsightsWorkspace -Location $Location -Name $WorkspaceName -Sku Standard -ResourceGroupName $ResourceGroupName
        Start-Sleep -s 60
    }

    Write-Output "Enabling Automation for the created workspace...."
    (Set-AzOperationalInsightsIntelligencePack -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -IntelligencePackName "AzureAutomation" -Enabled $true) | Out-Null

    ($workspaceDetails = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName)  | Out-Null
    $workspaceId = $workspaceDetails.CustomerId

    ($workspaceSharedKey = Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $ResourceGroupName -Name $WorkspaceName) | Out-Null
    $workspacePrimaryKey = $workspaceSharedKey.PrimarySharedKey

    Write-Output  "Workspace Details retrieved to use for Hybrid worker registration"
} 
catch {
    Write-Error "HWG Creation :: Error creating LA workspace : $_"
}



function New-VM {
    $vmNetworkName = "VMVnet" + $guid.SubString(0, 4)
    $subnetName = "VMSubnet" + $guid.SubString(0, 4)
    $newtworkSG = "VMNetworkSecurityGroup" + $guid.SubString(0, 4)
    $ipAddressName = "VMPublicIpAddress" + $guid.SubString(0, 4)
    $User = "VMUser"


    $vmName = $vmName + $guid.SubString(0, 4)
    $length = 12
    Add-Type -AssemblyName System.Web 
    $vmpassword = [System.Web.Security.Membership]::GeneratePassword($length,2)

    $VMAccessingString = ConvertTo-SecureString $vmpassword -AsPlainText -Force
    $VMCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $User, $VMAccessingString
    $vmlocation = $location # VM Creation
    try {
        New-AzVm `
            -ResourceGroupName $ResourceGroupName `
            -Name $vmName `
            -Location $vmlocation `
            -VirtualNetworkName $vmNetworkName `
            -SubnetName $subnetName `
            -SecurityGroupName $newtworkSG `
            -PublicIpAddressName $ipAddressName `
            -Credential $VMCredential | Out-Null

        Start-Sleep -s 120
        return
    }
    catch {
        $vmlocation = "West Europe"
        Write-Output "Error creating VM in $location retrying in $vmlocation..."
        New-AzVm `
            -ResourceGroupName $ResourceGroupName `
            -Name $vmName `
            -Location $vmlocation `
            -VirtualNetworkName $vmNetworkName `
            -SubnetName $subnetName `
            -SecurityGroupName $newtworkSG `
            -PublicIpAddressName $ipAddressName `
            -Credential $VMCredential | Out-Null
        Start-Sleep -s 120
    }
    
    throw "Error Creating VM after 3 attempts"
}

#Create a VM
try { 
    if($CreateVM -eq $true){
        New-VM
    }
}
catch {
    Write-Error "HWG Creation :: Error creating VM : $_"
}

#Run the VM Extension to register the Hybrid worker
## Run AZ VM Extension to download and Install MMA Agent
$commandToExecute = "powershell .\WorkerDownloadAndRegister.ps1 -workspaceId $workspaceId -workspaceKey $workspacePrimaryKey -workerGroupName $WorkerGroupName -agentServiceEndpoint $agentEndpoint -aaToken $aaPrimaryKey"
$uri = "https://raw.githubusercontent.com/azureautomation/Create-Automation-Windows-HybridWorker/main/HelperScript/WorkerDownloadAndRegister.ps1"

$settings = @{"fileUris" = @($uri.ToString()); "commandToExecute" = $commandToExecute };
$protectedSettings = @{"storageAccountName" = ""; "storageAccountKey" = "" };


Write-Output  "Registration Command executing on VM..."
try {
    Set-AzVMExtension -ResourceGroupName $ResourceGroupName `
        -Location $vmlocation `
        -VMName $vmName `
        -Name "Register-HybridWorker" `
        -Publisher "Microsoft.Compute" `
        -ExtensionType "CustomScriptExtension" `
        -TypeHandlerVersion "1.10" `
        -Settings $settings `
        -ProtectedSettings $protectedSettings 

}
catch {
    Write-Error "HWG Creation :: Error running VM extension - $_"
}

Get-AzAutomationHybridWorkerGroup -AutomationAccountName $AccountName -ResourceGroupName $ResourceGroupName -Name $WorkerGroupName
Write-Output "Creation of HWG Successful"