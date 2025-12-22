using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

$status = $null
$TenantId = $env:TenantID
$AppSecret = $env:AppSecret
$AppId = $env:AppId
$DCEURI = $env:DceURI
$DcrImmutableId = $env:DcrImmutableId
$streamName = $env:TableName

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Interact with query parameters or the body of the request.
$TimeStampField = $Request.Query.TimeStampField

### Step 1: Obtain a bearer token used later to authenticate against the DCR.
$scope= [System.Web.HttpUtility]::UrlEncode("https://monitor.azure.com//.default")   
$body = "client_id=$AppId&scope=$scope&client_secret=$AppSecret&grant_type=client_credentials";
$headers = @{"Content-Type"="application/x-www-form-urlencoded"};
$uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

$bearerToken = (Invoke-RestMethod -Uri $uri -Method "Post" -Body $body -Headers $headers).access_token


### Step 2: Send the data to the Log Analytics workspace.

$headers = @{"Authorization"="Bearer $bearerToken";"Content-Type"="application/json"};
$uri = "$endpoint_uri/dataCollectionRules/$dcrImmutableId/streams/$($streamName)?api-version=2023-01-01"

if ($Request.Body){
    $uploadResponse = Invoke-RestMethod -Uri $uri -Method "Post" -Body ($Request.Body) -Headers $headers
    $status = [HttpStatusCode]::OK
}else{
    $status = [HttpStatusCode]::BadRequest
}
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = if ($status) { $status } else { [HttpStatusCode]::OK }
    Body = if ($uploadResponse) { $uploadResponse } else { "Please pass a body in the request" }
})
