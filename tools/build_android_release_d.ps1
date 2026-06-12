$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = "D:\Yurich Connect\BuildCache"
$flutter = "C:\Users\ivan-\Downloads\flutter_windows_3.41.9-stable\flutter\bin\flutter.bat"

$mySoft = [string]::Concat(
    [char]0x041C, [char]0x043E, [char]0x0439, " ",
    [char]0x0441, [char]0x043E, [char]0x0444, [char]0x0442
)
$androidApps = [string]::Concat(
    [char]0x0410, [char]0x043D, [char]0x0434, [char]0x0440,
    [char]0x043E, [char]0x0439, [char]0x0434, " ",
    [char]0x043F, [char]0x0440, [char]0x0438, [char]0x043B,
    [char]0x043E, [char]0x0436, [char]0x0435, [char]0x043D,
    [char]0x0438, [char]0x044F
)
$apkOut = Join-Path "D:\" (Join-Path $mySoft $androidApps)

$env:GRADLE_USER_HOME = Join-Path $buildRoot "gradle-user-home"
$env:PUB_CACHE = Join-Path $buildRoot "pub-cache"

New-Item -ItemType Directory -Force -Path $env:GRADLE_USER_HOME | Out-Null
New-Item -ItemType Directory -Force -Path $env:PUB_CACHE | Out-Null
New-Item -ItemType Directory -Force -Path $apkOut | Out-Null

Push-Location $repoRoot
try {
    & $flutter pub get
    & $flutter analyze
    & $flutter test --reporter compact
    & $flutter build apk --release
    & $flutter build apk --release --split-per-abi

    $versionLine = Select-String -LiteralPath "pubspec.yaml" -Pattern "^version:\s*(.+)$" |
        Select-Object -First 1
    $versionName = if ($versionLine) {
        ($versionLine.Matches[0].Groups[1].Value -split "\+")[0].Trim()
    } else {
        "unknown"
    }

    Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-release.apk" `
        -Destination (Join-Path $apkOut "app-release.apk") -Force
    Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-release.apk" `
        -Destination (Join-Path $apkOut "YurichConnect-android-release.apk") -Force
    Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk" `
        -Destination (Join-Path $apkOut "YurichConnect-android-arm64-v8a-v$versionName.apk") -Force
    Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk" `
        -Destination (Join-Path $apkOut "YurichConnect-android-armeabi-v7a-v$versionName.apk") -Force
    Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-x86_64-release.apk" `
        -Destination (Join-Path $apkOut "YurichConnect-android-x86_64-v$versionName.apk") -Force

    Get-ChildItem -LiteralPath $apkOut -Filter "*$versionName*.apk" |
        Select-Object Name, Length, LastWriteTime
} finally {
    Pop-Location
}
