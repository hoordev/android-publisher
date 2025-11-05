@echo off
chcp 65001 >nul
cd /d "%~dp0"
cd ..
setlocal EnableDelayedExpansion

echo.
echo =========================
echo        App Builder
echo =========================
echo.
echo.

set "JAVA_HOME=C:\Program Files\Android\Android Studio\jbr"
set "PATH=%JAVA_HOME%\bin;%PATH%"
set "BUNDLETOOL_JAR=release\bundletool.jar"

if not exist "%BUNDLETOOL_JAR%" (
    echo [FATAL] bundletool.jar nem található! !
    exit /b 1
)

set "APPS=free:Free:free.jks:alias:psw paid:Paid:paid.jks:alias:psw dev:Dev:dev.jks:alias:psw"

for %%A in (%APPS%) do (
	for /f "tokens=1,2,3,4,5 delims=:" %%a in ("%%A") do (
		set "FLAVOR=%%a"
		set "FLAVOR_CAP=%%b"
		set "KEYSTORE_JKS_FILE=%%c"
		set "KEYSTORE_JKS_ALIAS=%%d"
		set "KEYSTORE_JKS_PSW=%%e"
		
		set "AAB_PATH=app\build\outputs\bundle\!FLAVOR!Release\app-!FLAVOR!-release.aab"
        set "MAP_PATH=app\build\outputs\mapping\!FLAVOR!Release\mapping.txt"
		set "KEYSTORE_JKS_PATH=release\keystore\!KEYSTORE_JKS_FILE!"
        set "DEST_DIR=app\!FLAVOR!"
		
		if not exist "!KEYSTORE_JKS_PATH!" (
            echo [HIBA] Nincs keystore a flavorhoz: !FLAVOR_CAP! [!KEYSTORE_JKS_FILE!]
            exit /b 1
        )

        echo [BUILD] !FLAVOR_CAP! buildelése folyamatban...
        call gradlew.bat app:bundle!FLAVOR_CAP!Release --quiet >nul 2>&1
        if errorlevel 1 (
            echo [FAIL] Gradle build sikertelen: !FLAVOR_CAP!
            exit /b 1
        )

        if not exist "!AAB_PATH!" (
            echo [HIBA] AAB fájl nem található: !AAB_PATH!
            exit /b 1
        )

        if not exist "!MAP_PATH!" (
            echo [HIBA] mapping.txt nem található: !MAP_PATH!
            exit /b 1
        )

        if not exist "!DEST_DIR!" mkdir "!DEST_DIR!" >nul
        copy /Y "!AAB_PATH!" "!DEST_DIR!\app-!FLAVOR!-release.aab" >nul
        copy /Y "!MAP_PATH!" "!DEST_DIR!\mapping.txt" >nul
        echo [OK] AAB + mapping másolva ide: !DEST_DIR!

        echo [APK] Universal APK generálása: !FLAVOR_CAP!...
        java -jar "%BUNDLETOOL_JAR%" build-apks ^
            --bundle="!DEST_DIR!\app-!FLAVOR!-release.aab" ^
            --output="!DEST_DIR!\app.apks" ^
            --ks="!KEYSTORE_JKS_PATH!" ^
            --ks-key-alias=!KEYSTORE_JKS_ALIAS! ^
            --ks-pass=pass:!KEYSTORE_JKS_PSW! ^
            --key-pass=pass:!KEYSTORE_JKS_PSW! ^
            --mode=universal ^
            --overwrite >nul 2>&1

        if not exist "!DEST_DIR!\app.apks" (
            echo [HIBA] app.apks nem található: !FLAVOR_CAP!
            exit /b 1
        )

        rem ====== Universal APK kibontása és átnevezése ======
        if exist "!DEST_DIR!\tmp_apks" rd /s /q "!DEST_DIR!\tmp_apks"
        mkdir "!DEST_DIR!\tmp_apks"

        jar xf "!DEST_DIR!\app.apks"

        if exist "universal.apk" (
            move /Y "universal.apk" "!DEST_DIR!\app-!FLAVOR!-release.apk" >nul
            echo [OK] APK átnevezve: !DEST_DIR!\app-!FLAVOR!-release.apk
        ) else (
            echo [HIBA] universal.apk nem található az app.apks-ban: !FLAVOR_CAP!
            exit /b 1
        )

        del /Q "!DEST_DIR!\app.apks" >nul
        if exist "!DEST_DIR!\tmp_apks" rd /s /q "!DEST_DIR!\tmp_apks"

        echo [DONE] !FLAVOR_CAP! build és export kész: !DEST_DIR!
        echo.
    )
)

echo [SUCCESS] Minden flavor sikeresen buildelve, APK + AAB + mapping kész!
endlocal
pause
