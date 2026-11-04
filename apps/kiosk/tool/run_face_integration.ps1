$ErrorActionPreference = 'Stop'
$rhKioskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $rhKioskRoot
try {
    # Flutter test uninstalls its target by default. Never allow that here.
    flutter test integration_test/face_engine_test.dart -d emulator-5554 --no-uninstall
    if ($LASTEXITCODE -ne 0) { throw 'Fallaron las pruebas faciales de Android.' }
} finally {
    # The test activity stays on screen after Flutter finishes. Return to the
    # installed kiosk without uninstalling either package or touching its data.
    $rhAdb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $rhAdb) {
        & $rhAdb shell am force-stop com.example.kiosk.integrationtest | Out-Null
        & $rhAdb shell am start -n com.example.kiosk/.MainActivity | Out-Null
    }
    Pop-Location
}
