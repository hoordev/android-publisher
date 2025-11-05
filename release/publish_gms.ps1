# Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Hálózati stabilitás és időkorlát ---
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$API_TIMEOUT_SECONDS = 180

# =========================================================
# --- BEÁLLÍTÁSOK ÉS VÁLTOZÓK ---
# =========================================================
$BASE_DIR = Split-Path -Parent $PSScriptRoot
$CHANGELOG_FILE = "release\publish_changelog.txt"
$BUNDLETOOL_FILE = "release\bundletool.jar"
$SERVICE_ACCOUNT_FILE = "release\service-account.json"

$APP_BASE_PACKAGE_NAME = "com.example"
$FLAVORS = [ordered]@{
    "free"	= "free"
    "paid"	= "paid"
    "dev"	= "dev"
}

$DEFAULT_SEND_TO_REVIEW = $false # save only as draft
$DEFAULT_TRACK = "production"
$DEFAULT_TRACK_STATE = if ($DEFAULT_SEND_TO_REVIEW) { "completed" } else { "draft" }
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
    $file = "$BASE_DIR\$SERVICE_ACCOUNT_FILE"
    if (-not (Test-Path $file)) {
        Write-Host "❌ Hiányzik a szolgáltatásfiók: $SERVICE_ACCOUNT_FILE`n"
        exit 1
    }

    Write-Host "☁️ GCloud hitelesítés"
    Write-Host "🔑 Hitelesítés szolgáltatásfiókkal..."
    & gcloud --no-user-output-enabled auth activate-service-account --key-file=$file | Out-Null
    if ($LASTEXITCODE -ne 0) { 
		Write-Host "⚠️ A szolgáltatásfiók aktiválása sikertelen!`n"
		exit 1
	}

    $token = gcloud auth print-access-token --scopes="https://www.googleapis.com/auth/androidpublisher"
    if (-not $token) { 
		Write-Host "⚠️ Nem sikerült Access Token-t lekérni!`n"
		exit 1
	}

    Write-Host "🟢 Access token sikeresen lekérve"
    return $token
}

function Session-Create ($pkg, $accessToken) {
	Write-Host "🗂️ Új edit session létrehozása..."
	$headers = @{ "Authorization" = "Bearer $accessToken"; "Content-Type" = "application/json; charset=utf-8" }
	$editUrl = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${pkg}/edits"
	$initResp = Invoke-RestMethod -Uri $editUrl -Method Post -Headers $headers -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop
	if (-not $initResp.id) { 
		Write-Host "⚠️ Nem sikerült létrehozni az edit session-t!`n"
		exit 1
	}
	$editId = $initResp.id
	Write-Host "🗂️ Edit Session létrehozva: $editId"
	return $editId
}

function Session-Delete ($pkg, $accessToken, $editId) {
    if (-not $editId) { return }
    Write-Host "🗑️ Edit Session törlése: $editId"
    $deleteUrl = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${pkg}/edits/${editId}"
	$headers = @{ "Authorization" = "Bearer $accessToken" }
    Invoke-RestMethod -Uri $deleteUrl -Method Delete -Headers $headers -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction SilentlyContinue | Out-Null
    Write-Host "🗑️ Edit Session törölve"
}

function Session-Upload-AAB ($pkg, $accessToken, $editId, $aabPath, $aabVersionCode) {
	Write-Host "🚀 AAB feltöltés indítása..."
	$aabInitUrl = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/${pkg}/edits/${editId}/bundles?ackBundleInstallationWarning=false&uploadType=resumable"
	$aabInitHeaders = @{
		"Authorization" = "Bearer $accessToken"
		"Content-Type"  = "application/octet-stream"
		"X-Upload-Content-Type" = "application/octet-stream"
		"X-Upload-Content-Length" = (Get-Item $aabPath).Length
	}
	$aabInitResp = Invoke-WebRequest -Uri $aabInitUrl -Method POST -Headers $aabInitHeaders -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop
	$aabUploadHeaders =  @{ "Authorization" = "Bearer $accessToken"; "Content-Type" = "application/octet-stream" }
	$aabUploadUrl = $aabInitResp.Headers["Location"]
	$aabUploadResp = Invoke-RestMethod -Uri $aabUploadUrl -Method PUT -InFile $aabPath -Headers $aabUploadHeaders -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop
	$versionCode = $aabUploadResp.versionCode
	if([int] $aabVersionCode -ne [int] $versionCode){
		Write-Host "❌ Figyelem! A verziók nem egyeznek: $aabVersionCode != $versionCode`n"
		exit 1
	}
	Write-Host "🚀 AAB feltöltve"
}

function Session-Upload-APK ($pkg, $accessToken, $editId, $apkPath, $aabVersionCode) {
	Write-Host "🚀 APK feltöltés indítása..."
	$apkInitUrl = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/${pkg}/edits/${editId}/apks?uploadType=resumable"
	$apkInitHeaders = @{
		"Authorization" = "Bearer $accessToken"
		"Content-Type"  = "application/octet-stream"
		"X-Upload-Content-Type" = "application/octet-stream"
		"X-Upload-Content-Length" = (Get-Item $apkPath).Length
	}
	$apkInitResp = Invoke-WebRequest -Uri $apkInitUrl -Method POST -Headers $apkInitHeaders -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop
	$apkUploadUrl = $apkInitResp.Headers["Location"]
	$apkUploadHeaders = @{ "Authorization" = "Bearer $accessToken"; "Content-Type" = "application/octet-stream" }
	$apkUploadResp = Invoke-RestMethod -Uri $apkUploadUrl -Method PUT -InFile $apkPath -Headers $apkUploadHeaders -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop
	$versionCode = $apkUploadResp.versionCode
	if([int] $aabVersionCode -ne [int] $versionCode){
		Write-Host "❌ Figyelem! A verziók nem egyeznek: $aabVersionCode != $versionCode`n"
		exit 1
	}
	Write-Host "🚀 APK feltöltve"
}

function Session-Upload-MAPPING ($pkg, $accessToken, $editId, $mappingPath, $versionCode) {
	Write-Host "🧩 Mapping feltöltés indítása..."
	$mappingInitUrl = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/${pkg}/edits/${editId}/apks/${versionCode}/deobfuscationFiles/proguard?uploadType=resumable"

	$mapInitHeaders = @{
		"Authorization" = "Bearer $accessToken"
		"Content-Type"  = "application/octet-stream"
		"X-Upload-Content-Type" = "application/octet-stream"
		"X-Upload-Content-Length" = (Get-Item $mappingPath).Length
	}

	$mapInitResp = Invoke-WebRequest -Uri $mappingInitUrl -Method POST -Headers $mapInitHeaders -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop
	$mappingUploadUrl = $mapInitResp.Headers["Location"]
	Invoke-RestMethod -Uri $mappingUploadUrl -Method PUT -InFile $mappingPath -Headers @{ "Authorization" = "Bearer $accessToken"; "Content-Type" = "application/octet-stream" } -TimeoutSec $API_TIMEOUT_SECONDS -ErrorAction Stop | Out-Null

	Write-Host "🧩 Mapping feltöltve"
}

function Session-Track-Update ($pkg, $accessToken, $editId, $versionCode, $versionName) {
	Write-Host "📝 Draft release beállítása..."
	$headers = @{ "Authorization" = "Bearer $accessToken"; "Content-Type" = "application/json; charset=utf-8"}

	$track = [string] $DEFAULT_TRACK
	$name = [string] "$versionCode ($versionName)"
	$status = [string] $DEFAULT_TRACK_STATE
	$versionCode = [string] $versionCode
	$language = [string] $DEFAULT_CHANGELOG_LANG
	$changelog = [string] $changelog
	
	$releaseData = @{
		track    = $track
		releases = @(
			@{
				name          = $name
				status        = $status
				versionCodes  = @($versionCode)
				releaseNotes  = @(
					@{
						language = $language
						text     = $changelog
					}
				)
			}
		)
	}
	$trackBody = $releaseData | ConvertTo-Json -Depth 10 -Compress
	$utf8Body = [System.Text.Encoding]::UTF8.GetBytes($trackBody)
	
	$releaseUrl = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${pkg}/edits/${editId}/tracks/${track}"
	Invoke-RestMethod -Uri $releaseUrl -Method Put -Headers $headers -Body $utf8Body -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop | Out-Null
	Write-Host "📝 Draft release kész"
}

function Session-Track-Validate ($pkg, $accessToken, $editId, $aabVersionCode) {
	Write-Host "🔍 Ellenőrzés..."
	
	$uploadedAabVersionCodes = @()
	$uploadedApkVersionCodes = @()
	
	$headers = @{ "Authorization" = "Bearer $accessToken"; "Content-Type" = "application/json; charset=utf-8" }
	
	#Validate AAB's
	$aabCheckUrl = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${pkg}/edits/${editId}/bundles"
	$bundlesResp = Invoke-RestMethod -Uri $aabCheckUrl -Method Get -Headers $headers -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop
	if ($bundlesResp.PSObject.Properties.Name -contains 'bundles') {
		if ($bundlesResp.bundles) {
			$uploadedAabVersionCodes += $bundlesResp.bundles | Select-Object -ExpandProperty versionCode
		}	
	}
	
	#Validate APK's
	$apkCheckUrl = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${pkg}/edits/${editId}/apks"
	$apksResp = Invoke-RestMethod -Uri $apkCheckUrl -Method Get -Headers $headers -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop
	if ($apksResp.PSObject.Properties.Name -contains 'apks') {
		if ($apksResp.apks) {
			$uploadedApkVersionCodes += $apksResp.apks | Select-Object -ExpandProperty versionCode
		}
	}
	
	# Az archived aab|apk fajlokat nem adja vissza az API
	
	if ([array]$uploadedAabVersionCodes -contains $aabVersionCode) {
		Write-Host "🔴 HIBA: az aktuális aab korábban már feltöltésre került!`n"
		exit 1
	}
	if ([array]$uploadedApkVersionCodes -contains $aabVersionCode) {
		Write-Host "🔴 HIBA: az aktuális apk korábban már feltöltésre került!`n"
		exit 1
	}
	
	Write-Host "🔍 Verzió feltölthető"
}

function Session-Track-Commit ($pkg, $accessToken, $editId) {
	Write-Host "✅ Módosítások véglegesítése..."
	$headers = @{ "Authorization" = "Bearer $accessToken"; "Content-Type" = "application/json; charset=utf-8" }
	$commitUrl = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${pkg}/edits/${editId}:commit?changesNotSentForReview=false"
	Invoke-RestMethod -Uri $commitUrl -Method Post -Headers $headers -TimeoutSec $API_TIMEOUT_SECONDS -DisableKeepAlive -ErrorAction Stop | Out-Null
	Write-Host "🎯 Módosítások mentve"
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
Write-Host "       Google Play"
Write-Host "=========================="
Write-Host ""

Get-Password

try {
	
	Write-Host "🎯 State: ${DEFAULT_TRACK_STATE}"
	Write-Host "📶 Release type: ${DEFAULT_TRACK}"
	Write-Host "📋 Review mode: $(if ($DEFAULT_SEND_TO_REVIEW -eq 1) { 'igen' } else { 'nem' })"
	Write-Host "🌐 Language: ${DEFAULT_CHANGELOG_LANG}`n"
	
    $changelog = Get-Changelog
	$accessToken = Get-AccessToken

    foreach ($flavor in $FLAVORS.Keys) {
		$pkgBase = $APP_BASE_PACKAGE_NAME
        $pkgSuffix = $FLAVORS[$flavor]
        $pkg = "$pkgBase.$pkgSuffix"
		
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

		$editId = Session-Create $pkg $accessToken

        try {
			Session-Track-Validate $pkg $accessToken $editId $versionCode
			Session-Upload-AAB $pkg $accessToken $editId $aabPath $versionCode
			# Session-Upload-APK $pkg $accessToken $editId $apkPath $versionCode
			Session-Upload-MAPPING $pkg $accessToken $editId $mappingPath $versionCode
			Session-Track-Update $pkg $accessToken $editId $versionCode $versionName
			Session-Track-Commit $pkg $accessToken $editId
			
			Write-Host "🏁 Sikeres publikálás"
			Start-Sleep -Seconds 10
        } catch {
            Session-Delete $pkg $accessToken $editId
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