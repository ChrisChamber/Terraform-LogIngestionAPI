using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

$status = $null
$TenantId = $env:TenantID
$AppSecret = $env:AppSecret
$AppId = $env:AppId
$endpoint_uri = $env:DceURI
$DcrImmutableId = $env:DcrImmutableId
$streamName = $env:TableName
$uploadResponse = $null
# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Interact with query parameters or the body of the request.
$TimeStampField = $Request.Query.TimeStampField

### Step 1: Obtain a bearer token used later to authenticate against the DCR.
$scope = [System.Web.HttpUtility]::UrlEncode("https://monitor.azure.com//.default")   
$body = "client_id=$AppId&scope=$scope&client_secret=$AppSecret&grant_type=client_credentials";
$headers = @{"Content-Type" = "application/x-www-form-urlencoded" };
$uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

$bearerToken = (Invoke-RestMethod -Uri $uri -Method "Post" -Body $body -Headers $headers).access_token


### Step 2: Send the data to the Log Analytics workspace.

$headers = @{"Authorization" = "Bearer $bearerToken"; "Content-Type" = "application/json" };
$uri = "$endpoint_uri/dataCollectionRules/$dcrImmutableId/streams/$($streamName)?api-version=2023-01-01"

# Convert the body to a JSON array if it is not already one.
if ($Request.Body -is [System.Array]) {
    $Log = $Request.Body | ConvertTo-Json
} else {
    $Log = $Request.Body | ConvertTo-Json -AsArray
}

$Log = $Request.Body | ConvertTo-Json -AsArray

if ($Log) {
    $uploadResponse = Invoke-RestMethod -Uri $uri -Method "Post" -Body $Log -Headers $headers
    $status = [HttpStatusCode]::OK
}
else {
    $status = [HttpStatusCode]::BadRequest
}
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $status
        Body       = $uploadResponse
    })
