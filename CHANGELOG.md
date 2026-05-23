# Changelog

## 1.0.12 - 2026-05-23

- Improved NaiveProxy health checks for servers where CONNECT to IP targets
  works but server-side DNS resolution is broken or slow.
- Kept domain probes first, then falls back to an IP probe so valid TUN
  profiles are not rejected too early during startup.

## 1.0.11 - 2026-05-23

- Added NaiveProxy startup fallback between native Naive and HTTPS CONNECT
  modes, with a real mixed-proxy health check before the connection is accepted.
- Added import support for standalone sing-box outbound JSON such as
  `type: http` / `type: naive` NaiveProxy configs.
- Improved VPN stop timing and status watchdog checks for long-running sessions
  and profile switching.
- Removed technical app text that referenced other clients.

## 1.0.10 - 2026-05-23

- Fixed `naive+https://` profile generation on Android by using sing-box native
  NaiveProxy outbound instead of forcing the link into generic HTTP CONNECT.
- Added regression coverage for go-it style NaiveProxy links.

## 1.0.9 - 2026-05-23

### Android

- Cleaned the app header and removed extra top action icons.
- Fixed the connection status card height so traffic counters do not stretch the
  layout.
- Moved language switching to the contact section.
- Rewrote profile/network helper text to be clearer for regular users.
- Kept protected DNS, mobile network tuning, and explicit profile stop/start
  behavior from the previous build.

### Verification

- `flutter analyze`
- `flutter test`
- Android APK verified with APK Signature Scheme v2

## 1.0.8 - 2026-05-22

- Added protected DNS routing for Android profiles.
- Improved VPN stop handling so the UI does not wait for long sing-box cleanup.
- Improved diagnostics summary for profile, protocol, endpoint, and config.

## 1.0.7 - 2026-05-22

- Improved NaiveProxy compatibility with HTTPS CONNECT mode.
- Tuned Android TUN settings for Wi-Fi and LTE.
- Added Android release APK packaging.

## 1.0.0 - 2026-05-22

- Initial Android edition with Flutter, sing-box, profile import, QR import,
  clipboard import, VLESS Reality, NaiveProxy, notifications, and diagnostics.
