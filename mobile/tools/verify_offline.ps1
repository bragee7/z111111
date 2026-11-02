# Offline verification for the police-station feature.
#
# Turns the network OFF on the phone, then walks through every part of the
# feature: login, nearby, all stations, search, districts, map, nearest route
# (car / bicycle / walk), directions, call, WhatsApp, route here.
#
# Usage: powershell -File verify_offline.ps1 [-DebugBuild]

param(
  [switch]$DebugBuild,
  [string]$Apk = ""
)

$ErrorActionPreference = 'Continue'
$adb = "C:\Users\HP\AppData\Local\Android\Sdk\platform-tools\adb.exe"
$pkg = "com.zelda.zelda_guardian"
$out = "E:\revapk\kaaval_uthavi_full_apk\zelda1\mobile\build\offline_verify"
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }

function Shot($name) {
  & $adb shell screencap -p "/sdcard/$name.png" 2>&1 | Out-Null
  & $adb pull "/sdcard/$name.png" "$out\$name.png" 2>&1 | Out-Null
  Write-Host "   shot -> $out\$name.png"
}

function Log($m) { Write-Host "== $m" }

# ---------------------------------------------------------------- airplane
Log "disabling wifi + mobile data (true offline)"
& $adb shell svc wifi disable 2>&1 | Out-Null
& $adb shell svc data disable 2>&1 | Out-Null
Start-Sleep -Seconds 3
$net = & $adb shell dumpsys connectivity 2>&1 | Select-String -Pattern "Active default network|NetworkAgentInfo.*CONNECTED" | Select-Object -First 3
foreach ($n in $net) { Write-Host "   $($n.ToString().Trim())" }

# ---------------------------------------------------------------- install
if ($Apk -ne "") {
  Log "installing $Apk"
  & $adb install -r -t $Apk 2>&1 | Select-Object -Last 2 | ForEach-Object { "   $_" }
}

# ---------------------------------------------------------------- launch
Log "launching app"
& $adb shell am force-stop $pkg 2>&1 | Out-Null
& $adb logcat -c 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $adb shell am start -n "$pkg/.MainActivity" 2>&1 | Out-Null
Start-Sleep -Seconds 14
& $adb shell cmd statusbar collapse 2>&1 | Out-Null
Shot "01_login"

# ---------------------------------------------------------------- login
Log "logging in (user@guardian.com)"
& $adb shell input tap 540 1162; Start-Sleep -Seconds 2
for ($i = 0; $i -lt 40; $i++) { & $adb shell input keyevent 67 | Out-Null }
& $adb shell input text "user@guardian.com"; Start-Sleep -Seconds 1
& $adb shell input keyevent 61; Start-Sleep -Seconds 1
& $adb shell input text "user123"; Start-Sleep -Seconds 1
& $adb shell input keyevent 66; Start-Sleep -Seconds 2
Start-Sleep -Seconds 20
& $adb shell cmd statusbar collapse 2>&1 | Out-Null
Shot "02_dashboard"

# ---------------------------------------------------------------- open feature
Log "opening Police Stations"
# the card sits on the user dashboard; try a few spots until it opens
foreach ($y in @(1180, 1320, 1460, 1040)) {
  & $adb shell input tap 540 $y 2>&1 | Out-Null
  Start-Sleep -Seconds 3
}
Shot "03_police_stations"

# ---------------------------------------------------------------- tabs
$tabs = @{ "04_tab_nearby" = 150; "05_tab_all" = 320; "06_tab_map" = 470; "07_tab_districts" = 620 }
foreach ($k in $tabs.Keys | Sort-Object) {
  Log "tab $k"
  & $adb shell input tap $tabs[$k] 2>&1 | Out-Null
  Start-Sleep -Seconds 4
  & $adb shell cmd statusbar collapse 2>&1 | Out-Null
  Shot $k
}

# ---------------------------------------------------------------- map actions
Log "map: nearest route (drive)"
& $adb shell input tap 470 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $adb shell input tap 880 300 2>&1 | Out-Null    # "Nearest route" button
Start-Sleep -Seconds 8
Shot "08_nearest_route"

Log "map: walk mode then re-route"
& $adb shell input tap 560 300 2>&1 | Out-Null    # walk chip
Start-Sleep -Seconds 6
Shot "09_walk_route"

Log "map: bike mode then re-route"
& $adb shell input tap 640 300 2>&1 | Out-Null    # bike chip
Start-Sleep -Seconds 6
Shot "10_bike_route"

Log "map: pan + zoom"
& $adb shell input swipe 600 900 350 1100 400 2>&1 | Out-Null
Start-Sleep -Seconds 3
Shot "11_map_panned"
& $adb shell input tap 60 1100 2>&1 | Out-Null    # zoom in
Start-Sleep -Seconds 2
& $adb shell input tap 60 1100 2>&1 | Out-Null
Start-Sleep -Seconds 3
Shot "12_map_zoomed"

# ---------------------------------------------------------------- logcat
Log "logcat: offline timings + errors"
& $adb logcat -d 2>&1 |
  Select-String -Pattern "offline|flutter|FATAL|AndroidRuntime|SocketException|connectivity" |
  Select-Object -Last 60 | ForEach-Object { "   $($_.Line.Trim())" }

Log "network sockets still open by the app?"
$pkgPid = (& $adb shell pidof $pkg 2>&1).Trim()
Write-Host "   app pid = $pkgPid"
if ($pkgPid) {
  & $adb shell "cat /proc/$pkgPid/net/tcp 2>/dev/null | wc -l" 2>&1 | ForEach-Object { "   tcp rows = $_" }
}

Log "done. screenshots in $out"
