# Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Hálózati stabilitás és időkorlát ---
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$API_TIMEOUT_SECONDS = 180

# =========================================================
# --- BEÁLLÍTÁSOK ÉS VÁLTOZÓK ---
# =========================================================

$CLIENT_ID = "ABCDEFGH123456"
$CLIENT_SECRET = "QWERTZUIOPASDFGHJKL123456789YXCVBNMQWERTY"

$APP_BASE_PACKAGE_NAME = "com.example"
$APPS = [ordered]@{
    "free" = @{
        Suffix = "free"
        AppId  = 123456789
    }
    "paid" = @{
        Suffix = "paid"
        AppId  = 987654321
    }
    "dev" = @{
        Suffix = "dev"
        AppId  = 111222333
    }
}

$BASE_DIR = Split-Path -Parent $PSScriptRoot
$CHANGELOG_FILE = "release\publish_changelog.txt"
$BUNDLETOOL_FILE = "release\bundletool.jar"

$DEFAULT_SEND_TO_REVIEW = $false # save only as draft
$DEFAULT_RELEASE_TYPE = 1 # on the entire network
$DEFAULT_CHINESE_MAINLAND_FLAG = 0 # no
$DEFAULT_CHANGELOG_LANG = "hu-HU"

# =========================================================
# --- FUNKCIÓK ---
# =========================================================

function Get-Password {
    $today = (Get-Date -Format yyyyMMdd)
    $expectedPassword = "$today"

    $password = Read-Host -Prompt "🔐 Publikálási jelszó" -AsSecureString
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))

    if ($plainPassword -ne $expectedPassword) {
        Write-Host "❌ Hibás jelszó! A publikálás megszakítva!`n"
        exit 1
    }
    Write-Host "🎉 Jelszó helyes! A publikálás elindult!`n"
}

function Get-Changelog () {
	$file = "$BASE_DIR\$CHANGELOG_FILE"
	
	Write-Host "📜 Changelog ellenőrzése..."
	
    if (-not (Test-Path $file)) {
        Write-Host "⚠️ Hiba: Hiányzik a changelog fájl: $file`n"
        exit 1
    }
	
	$changelog = Get-Content -Path $file -Encoding UTF8 -Raw
	if ($null -ne $changelog) {
        $changelog = $changelog.ToString().Trim()
    } else {
        $changelog = ""
    }
	if ([string]::IsNullOrEmpty($changelog)) {
		Write-Host "⚠️ Hiba: a changelog fájl üres!`n"
        exit 1
	}
	
	Write-Host "📝 Changelog beolvasva`n"
	
    return $changelog
}

function Get-AppVersions ($aabPath) {
	$bundleToolPath = "$BASE_DIR\$BUNDLETOOL_FILE"
	
    if (-not (Test-Path $bundleToolPath)) { throw "Hiányzik a bundletool: $bundleToolPath" }

	$code = [int] (& java -jar $bundleToolPath dump manifest "--bundle=$aabPath" "--xpath=/manifest/@android:versionCode")
	$name = [string] (& java -jar $bundleToolPath dump manifest "--bundle=$aabPath" "--xpath=/manifest/@android:versionName")
	$sha256 = [string] (& java -jar $bundleToolPath dump manifest "--bundle=$aabPath" "--xpath=/manifest/@android:hash")

	return @{ VersionCode = $code; VersionName = $name; SHA256 = $sha256 }
}

function Get-AccessToken {
	Write-Host "☁️ HCloud hitelesítés"

    $headers = @{ "Content-Type" = "application/json;charset=UTF-8" }
	
	$clientID = [string] $CLIENT_ID
	$clientSecret = [string] $CLIENT_SECRET
	
	$requestData = @{
        grant_type = "client_credentials"
        client_id = $clientID
        client_secret = $clientSecret
    }
	
	$requestBody = $requestData | ConvertTo-Json -Depth 10 -Compress
	$utf8Body = [System.Text.Encoding]::UTF8.GetBytes($requestBody)

	$tokenUrl = "https://connect-api.cloud.huawei.com/api/oauth2/v1/token"
    $tokenResp = Invoke-RestMethod -Uri $tokenUrl -Method POST -Headers $headers -Body $utf8Body -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop
    if (-not $tokenResp.access_token) { 
		Write-Host "⚠️ Nem sikerült Access Token-t lekérni!`n"
		exit 1
	}

    Write-Host "🟢 Access token sikeresen lekérve"
    return $tokenResp.access_token
}

function Session-Upload-URL ($appId, $accessToken, $filePath, $sha256) {

    $headers = @{ "Authorization" = "Bearer $accessToken"; "client_id" = "$CLIENT_ID"; "Content-Type" = "application/octet-stream" }

	$fileName = [string] [System.IO.Path]::GetFileName($filePath)
	$fileSize = [string] (Get-Item $filePath).Length
	$fileExtension = [string] [System.IO.Path]::GetExtension($filePath).TrimStart('.')
	$releaseType = [int] $DEFAULT_RELEASE_TYPE # on the entire network
	$chineseMainlandFlag = [int] $DEFAULT_CHINESE_MAINLAND_FLAG

	$url = "https://connect-api.cloud.huawei.com/api/publish/v2/upload-url/for-obs?appId=${appId}&fileName=${fileName}&contentLength=${fileSize}&suffix=${fileExtension}&sha256=${sha256}&releaseType=${releaseType}&chineseMainlandFlag=${chineseMainlandFlag}"
    $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $headers -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop
	if (-not ($resp.PSObject.Properties.Name -contains 'urlInfo')) {
		Write-Host "❌ A fájl feltöltés hibára futott!`n"
		Write-Host "Javaslat: frissítse a kiadás ország/régió listáját a Huawei fejlesztői fiókjában, és mentse el a módosításokat.`n"
        exit 1
	}
    return $resp.urlInfo
}

function Session-Upload-AAB ($appId, $accessToken, $aabPath, $versionCode, $sha256) {
    Write-Host "🚀 AAB feltöltés indítása..."
	
	$fileName = [string] [System.IO.Path]::GetFileName($aabPath)
	$urlInfo = Session-Upload-URL $appId $accessToken $aabPath $sha256

    $headers = @{}
	foreach ($key in $urlInfo.headers.PSObject.Properties.Name) { 
		$headers[$key] = [string] $urlInfo.headers.$key
	}

	$uploadUrl = [string] $urlInfo.url
	$method = [string] $urlInfo.method
    Invoke-RestMethod -Uri $uploadUrl -Method $method -InFile $aabPath -Headers $headers -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop | Out-Null

    Write-Host "🚀 AAB feltöltve"
	
	# Write-Host "🚀 Várakozás a feldolgozásra..." # It may take 2-5 minutes, depending on the size of the package
	# Start-Sleep -Seconds 120
	# Write-Host "🚀 Feldolgozva"
	
	# Check App Signing at AppGallery Connect if not uploaded
	
	return @{ FileName = $fileName; ObjectID = $urlInfo.objectId; FileURL = $urlInfo.url }
}

function Session-Upload-APK ($appId, $accessToken, $apkPath, $versionCode, $sha256) {
    Write-Host "🚀 APK feltöltés indítása..."
	
	$fileName = [string] [System.IO.Path]::GetFileName($apkPath)
	$urlInfo = Session-Upload-URL $appId $accessToken $apkPath $sha256

    $headers = @{}
	foreach ($key in $urlInfo.headers.PSObject.Properties.Name) { 
		$headers[$key] = [string] $urlInfo.headers.$key
	}

	$uploadUrl = [string] $urlInfo.url
	$method = [string] $urlInfo.method
    Invoke-RestMethod -Uri $uploadUrl -Method $method -InFile $apkPath -Headers $headers -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop | Out-Null

    Write-Host "🚀 APK feltöltve"
	
	return @{ FileName = $fileName; ObjectID = $urlInfo.objectId; FileURL = $urlInfo.url }
}

function Session-Track-Validate ($appId, $accessToken, $versionCode) {
    Write-Host "🔍 Verzió validálás..."

    $headers = @{ "Authorization" = "Bearer $accessToken"; "client_id" = "$CLIENT_ID"; "Content-Type" = "application/json;charset=UTF-8" }

	$validateUrl = "https://connect-api.cloud.huawei.com/api/publish/v2/package-list?appId=${appId}"
    $resp = Invoke-RestMethod -Uri $validateUrl -Method GET -Headers $headers -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop

    $existingVersions = @()
    if ($resp.pkgList) {
        $existingVersions += $resp.pkgList | Select-Object -ExpandProperty versionCode
    }

    if ($existingVersions -contains $versionCode) {
        Write-Host "🔴 HIBA: az aktuális verzió korábban már feltöltésre került!`n"
        exit 1
    }

    Write-Host "🔍 Verzió feltölthető"
}

function Session-Update-FileInfo ($appId, $accessToken, $uploadResult) {
	Write-Host "🗂️ Fájl info frissítése..."

	$headers = @{ "Authorization" = "Bearer $accessToken"; "client_id" = "$CLIENT_ID"; "Content-Type" = "application/json;charset=UTF-8" }

	$releaseType = [int] $DEFAULT_RELEASE_TYPE
	$fileType = [int] 5 # app package, such as RPK, APK, and AAB files
	$fileName = [string] $uploadResult.FileName
	$fileDestUrl = [string] $uploadResult.ObjectID
	
	$bodyData = @{
		fileType    = $fileType
		files		= @(
			@{
				fileName    	= $fileName
				fileDestUrl		= $fileDestUrl
			}
		)
	}

	$bodyJson = $bodyData | ConvertTo-Json -Depth 10 -Compress
	$utf8Body = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)

	$url = "https://connect-api.cloud.huawei.com/api/publish/v2/app-file-info?appId=${appId}&releaseType=${releaseType}"
	Invoke-RestMethod -Uri $url -Method PUT -Headers $headers -Body $utf8Body -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop | Out-Null

	Write-Host "🗂️ Fájl info frissítve"
}

function Session-Track-Update ($appId, $accessToken, $changelog) {
    Write-Host "📝 Changelog feltöltése..."
	
    $headers = @{ "Authorization" = "Bearer $accessToken"; "client_id" = "$CLIENT_ID"; "Content-Type" = "application/json;charset=UTF-8" }

	$language = [string] $DEFAULT_CHANGELOG_LANG
	$changelog = [string] $changelog

    $releaseData = @{
        lang = $language
        newFeatures = $changelog
    }
	
	$releaseBody = $releaseData | ConvertTo-Json -Depth 10 -Compress
	$utf8Body = [System.Text.Encoding]::UTF8.GetBytes($releaseBody)

	$url = "https://connect-api.cloud.huawei.com/api/publish/v2/app-language-info?appId=${appId}"
    Invoke-RestMethod -Uri $url -Method PUT -Headers $headers -Body $utf8Body -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop | Out-Null
    Write-Host "📝 Changelog feltöltve"
}

function Session-Track-Commit ($appId, $accessToken) {
    Write-Host "✅ App Submit (Commit)"

    $headers = @{ "Authorization" = "Bearer $accessToken"; "client_id" = "$CLIENT_ID"; "Content-Type" = "application/json;charset=UTF-8" }

	$releaseType = [int] $DEFAULT_RELEASE_TYPE

	$url = "https://connect-api.cloud.huawei.com/api/publish/v2/app-submit?appId=${appId}&releaseType=${releaseType}"
    Invoke-RestMethod -Uri $url -Method POST -Headers $headers -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop  | Out-Null
    Write-Host "🎯 COMMIT kész"
}

function Handle-Exception ($_) {
    $errorFile = "publish_error_details.txt"
    Write-Host ""
    Write-Host "🛑 Hiba! Részletek itt: $errorFile`n"

    if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $errorMessage = $reader.ReadToEnd()
        $output = @"
KRITIKUS API HIBA!
-----------------------------------------------------
Időpont: $(Get-Date)
API Hívás Státusz: $($_.Exception.Response.StatusCode) - $($_.Exception.Response.StatusDescription)
Részletes JSON Válasz:
$errorMessage
-----------------------------------------------------
"@
        $output | Out-File $errorFile -Encoding UTF8 -Force
    } else {
        Write-Host $_.Exception
    }
}

# =========================================================
# --- FŐ VÉGREHAJTÁS ---
# =========================================================
Write-Host ""
Write-Host "=========================="
Write-Host "        AppGallery"
Write-Host "=========================="
Write-Host ""

Get-Password

try {
	
	Write-Host "🏯 Chinese mainland: $(if ($DEFAULT_CHINESE_MAINLAND_FLAG -eq 1) { 'igen' } else { 'nem' })"
	Write-Host "📶 Release type: ${DEFAULT_RELEASE_TYPE}"
	Write-Host "📋 Review mode: $(if ($DEFAULT_SEND_TO_REVIEW -eq 1) { 'igen' } else { 'nem' })"
	Write-Host "🌐 Language: ${DEFAULT_CHANGELOG_LANG}`n"
	
    $changelog = Get-Changelog
	$accessToken = Get-AccessToken
	
	# Write-Host ""
	# Write-Host $accessToken
	# Write-Host ""

    foreach ($flavor in $APPS.Keys) {
        $pkgBase = $APP_BASE_PACKAGE_NAME
        $pkgSuffix = $APPS[$flavor].Suffix
        $pkg = "$pkgBase.$pkgSuffix"

        $appId = $APPS[$flavor].AppId
        $appDir = "$BASE_DIR/app/$flavor"
        $aabPath = "$appDir/app-$flavor-release.aab"
        $apkPath = "$appDir/app-$flavor-release.apk"
        $mappingPath = "$appDir/mapping.txt"

        if (-not (Test-Path $aabPath)) { 
            Write-Host "❌ Hiányzik az aab file: $aabPath`n"
            exit 1
        }
        if (-not (Test-Path $apkPath)) { 
            Write-Host "❌ Hiányzik az apk file: $apkPath`n"
            exit 1
        }
        if (-not (Test-Path $mappingPath)) { 
            Write-Host "❌ Hiányzik a mapping file: $mappingPath`n"
            exit 1
        }

        $aabDetails = Get-AppVersions $aabPath
        $versionCode = $aabDetails.VersionCode
        $versionName = $aabDetails.VersionName
		$sha256 = $aabDetails.SHA256

        Write-Host ""
        Write-Host "⚙️ Feldolgozás: $flavor"
        Write-Host "📦 Csomagnév: $pkg"
        Write-Host "🔖 Verzió: $versionCode ($versionName)"

        try {
            Session-Track-Validate $appId $accessToken $versionCode
            # $uploadResult = Session-Upload-AAB $appId $accessToken $aabPath $versionCode $sha256
            $uploadResult = Session-Upload-APK $appId $accessToken $apkPath $versionCode $sha256
			Session-Update-FileInfo $appId $accessToken $uploadResult
            Session-Track-Update $appId $accessToken $changelog
			if($DEFAULT_SEND_TO_REVIEW) {
				Session-Track-Commit $appId $accessToken
			}
			
            Write-Host "🏁 Sikeres publikálás"
			Start-Sleep -Seconds 10
        } catch {
            throw $_
        }
    }

    Write-Host ""
    Write-Host "🎉 Az alkalmazások publikálása sikeresen lezárult!`n"
    exit 0

} catch {
    Handle-Exception $_
    exit 1
}
