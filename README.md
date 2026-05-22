# Aurum VPN Android

Aurum VPN is a gold/dark Android VPN client powered by sing-box. It focuses on
simple profile import, stable reconnects, protected DNS, and clear diagnostics
for VLESS Reality, VLESS TLS, NaiveProxy, Remnawave subscriptions, and sing-box
JSON profiles.

Русская версия ниже.

## Download

Use the GitHub Release asset:

- `AurumVPN-android-release.apk`

Android may warn about APKs installed outside Google Play until the app is
published and verified by Play Protect.

## Features

- Import from Remnawave subscription links, single `vless://` links,
  `naive+https://` links, clipboard, QR code, and sing-box JSON.
- Android VPNService integration through the bundled sing-box plugin.
- Persistent Android notification with connection status and traffic.
- Protected DNS through the VPN tunnel using Cloudflare DoH and FakeDNS.
- Wi-Fi and LTE compatible TUN settings with gVisor stack and strict routing.
- Two languages: Russian and English.
- Built-in diagnostics report with sensitive values redacted before sharing.

## Build

Install Flutter and Android SDK, then run:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

The release APK is created at:

```text
build/app/outputs/apk/release/app-release.apk
```

## Release Checklist

1. Build the APK with the release keystore outside git.
2. Verify the APK signature.
3. Upload the APK to GitHub Releases.
4. Keep signing files, real VPN profiles, subscriptions, and production configs
   out of git.

## Links

- Site: [ivan-it.net](https://ivan-it.net)
- Email: [ai@ivan-it.net](mailto:ai@ivan-it.net)
- VK: [vk.com/ivan_yurievich_it](https://vk.com/ivan_yurievich_it)
- Donate: [dzen.ru/ivanyurievich?donate=true](https://dzen.ru/ivanyurievich?donate=true)

## Русский

Aurum VPN Android — Android-клиент VPN в золотом стиле на базе sing-box. Он
умеет импортировать профили из Remnawave, `vless://`, `naive+https://`, QR,
буфера и sing-box JSON.

### Возможности

- VLESS Reality, VLESS TLS, NaiveProxy и sing-box JSON.
- Защищённый DNS через VPN-туннель.
- Настройки TUN для Wi-Fi и LTE.
- Шторка Android со статусом подключения и трафиком.
- Русский и английский интерфейс.
- Диагностический отчёт с автоматическим скрытием чувствительных данных.

### Сборка

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

APK будет здесь:

```text
build/app/outputs/apk/release/app-release.apk
```

Windows-версия ведётся отдельно в репозитории
[`ivan-yurich/aurum-vpn-windows`](https://github.com/ivan-yurich/aurum-vpn-windows).
