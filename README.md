# Aurum VPN

Aurum VPN is a compact VPN client built with Flutter and sing-box. The project
currently ships Android and Windows builds with a single gold/dark interface,
profile import, QR support, live traffic counters, diagnostics, and support for
VLESS Reality, VLESS TLS, NaiveProxy, Remnawave subscriptions, and raw sing-box
JSON.

> Русская версия ниже.

## Downloads

Stable builds are published on the GitHub Releases page.

Recommended release assets:

- `AurumVPN-android-release.apk` for Android phones.
- `AurumVPN_Setup.exe` for Windows 11 installation.
- `AurumVPN_Windows_Portable.zip` for portable Windows usage.

## Contacts

- Site: [ivan-it.net](https://ivan-it.net)
- Support email: [ai@ivan-it.net](mailto:ai@ivan-it.net)
- VK: [vk.com/ivan_yurievich_it](https://vk.com/ivan_yurievich_it)
- Donate: [dzen.ru/ivanyurievich?donate=true](https://dzen.ru/ivanyurievich?donate=true)

## Features

- Import subscriptions, QR codes, clipboard links, and manual profile links.
- VLESS Reality, VLESS TLS, NaiveProxy, Remnawave, and sing-box JSON support.
- Android VPN mode with foreground notification and live traffic counters.
- Windows TUN mode with Wintun, tray support, autostart, auto-connect, and app
  exclusions.
- Diagnostics report with sensitive values redacted before sending.
- Russian and English interface.
- Gold/dark UI with the custom Aurum VPN icon.

## Android Notes

Android builds use sing-box TUN mode and are tuned for Wi-Fi and mobile networks:

- MTU `1380`
- gVisor stack
- strict route
- protected DNS through the VPN tunnel
- local mixed proxy on `127.0.0.1:20808`
- profile switching with explicit stop/start cleanup

## Windows Notes

Windows builds use sing-box TUN mode with Wintun:

- MTU `1380`
- mixed stack for Windows stability
- local mixed proxy on `127.0.0.1:20808`
- Clash API on `127.0.0.1:19090`
- private IP ranges routed directly
- optional app exclusions by `.exe` process name
- tray actions: show, hide, connect/disconnect, and quit

## Build From Source

```powershell
flutter pub get
flutter analyze
flutter test
```

Android release:

```powershell
flutter build apk --release
```

Windows release:

```powershell
flutter build windows --release
```

## Release Checks

Before publishing a GitHub Release:

```powershell
flutter analyze
flutter test
```

For Android, verify APK signing with Android SDK `apksigner`.

For Windows, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\qa\smoke_windows.ps1
```

## Security Notes

- Do not commit real VPN profile links, UUIDs, passwords, private keys, or
  production configs.
- Generated release binaries belong on GitHub Releases, not in git history.
- Diagnostic reports redact passwords, UUIDs, and keys.
- Android and Windows VPN/TUN modes require OS-level VPN/network permissions.

## License

No project license has been selected yet. Bundled runtime components keep their
own licenses in their source directories.

---

# Aurum VPN на русском

Aurum VPN - компактный VPN-клиент на Flutter и sing-box. Сейчас проект собирает
Android и Windows версии в едином золотом стиле: импорт профилей, QR, буфер,
счетчики трафика, диагностика, VLESS Reality, VLESS TLS, NaiveProxy, Remnawave
подписки и raw sing-box JSON.

## Скачать

Стабильные сборки публикуются на странице GitHub Releases.

Рекомендуемые файлы релиза:

- `AurumVPN-android-release.apk` для Android.
- `AurumVPN_Setup.exe` для установки на Windows 11.
- `AurumVPN_Windows_Portable.zip` для portable-версии Windows.

## Контакты

- Сайт: [ivan-it.net](https://ivan-it.net)
- Почта поддержки: [ai@ivan-it.net](mailto:ai@ivan-it.net)
- VK: [vk.com/ivan_yurievich_it](https://vk.com/ivan_yurievich_it)
- Донат: [dzen.ru/ivanyurievich?donate=true](https://dzen.ru/ivanyurievich?donate=true)

## Возможности

- Импорт подписок, QR-кодов, ссылок из буфера и ручной ввод.
- Поддержка VLESS Reality, VLESS TLS, NaiveProxy, Remnawave и sing-box JSON.
- Android VPN-режим со шторкой уведомления и счетчиками трафика.
- Windows TUN-режим с Wintun, треем, автостартом, автоподключением и
  исключениями приложений.
- Отчет диагностики с автоматическим скрытием чувствительных данных.
- Интерфейс на русском и английском.
- Золотой дизайн и фирменная иконка Aurum VPN.

## Android

Android-сборка использует sing-box TUN и настроена для Wi-Fi и мобильных сетей:

- MTU `1380`
- gVisor stack
- strict route
- защищенный DNS через VPN-туннель
- локальный mixed proxy `127.0.0.1:20808`
- переключение профилей через аккуратную остановку и запуск

## Windows

Windows-сборка использует sing-box TUN с Wintun:

- MTU `1380`
- mixed stack для стабильности Windows
- локальный mixed proxy `127.0.0.1:20808`
- Clash API `127.0.0.1:19090`
- приватные IP идут напрямую
- исключения приложений по имени `.exe`
- трей: открыть, скрыть, подключить/отключить и выйти

## Сборка

```powershell
flutter pub get
flutter analyze
flutter test
```

Android release:

```powershell
flutter build apk --release
```

Windows release:

```powershell
flutter build windows --release
```

## Перед публикацией релиза

```powershell
flutter analyze
flutter test
```

Для Android проверь подпись APK через Android SDK `apksigner`.

Для Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\qa\smoke_windows.ps1
```

## Безопасность

- Не коммить реальные VPN-ссылки, UUID, пароли, приватные ключи и рабочие
  конфиги.
- Готовые `.apk`, `.exe` и `.zip` файлы загружай на GitHub Releases, а не в git.
- Диагностические отчеты скрывают пароли, UUID и ключи.
- Android и Windows VPN/TUN режимы требуют системных VPN/сетевых разрешений.
