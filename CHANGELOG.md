# Changelog

## 1.0.38 - 2026-06-08

- Added profile country detection and cached country metadata.
- Profile cards now show a country flag when the subscription name contains one,
  when the endpoint IP geolocation is resolved, or after the real VPN exit
  country is detected through the local tunnel proxy.
- Unknown countries now show a neutral globe instead of a protocol-only icon.
- Developer diagnostics now include cached country code/name for profiles.

## 1.0.37 - 2026-06-08

- Fixed profile ping for Hysteria/Hysteria2: UDP/QUIC profiles are no longer
  marked `offline` by a TCP socket check.
- Hysteria/Hysteria2 profile rows now verify endpoint DNS reachability and show
  `DNS ... ms` or `UDP ok` instead of a false TCP failure.
- Bumped Android version for the next install/update package.

## 1.0.36 - 2026-06-08

- Pointed Android in-app updates to the renamed GitHub repository:
  `ivan-yurich/Yurich-Connect-Android`.
- Updated project documentation to use the Yurich Connect Android repository
  address.
- Bumped the Android app version so phones can receive the repository-migration
  update through the built-in updater.
- Reworked the profile/network panel into compact rows for protocol, Wi-Fi/LTE,
  DNS, background stability, country, ping, and endpoint.
- Added a clear note that Android apps can detect the system VPN service through
  OS APIs; the app protects IP/DNS routing but cannot hide Android VpnService
  without unsupported root/system tricks.
- Renamed the DNS status to "through profile" so the UI matches the current
  tunnel/FakeIP behavior without implying a forced third-party resolver.
- Kept the current mobile protocol tuning intact while retaining the native
  background health keeper for long-running Wi-Fi/LTE sessions.
- Made the native health keeper recover faster on mobile handoffs by reducing
  the probe grace, interval, cooldown, and failure threshold.

## 1.0.35 - 2026-06-07

- Added a native Android foreground-service health keeper that probes the local
  mixed proxy in the background and reloads sing-box when the tunnel is alive as
  a service but no longer passes traffic.
- Added a red degraded connection state for stalled or auto-recovering tunnels,
  so the main action button no longer stays visually healthy when the connection
  is broken.
- Extended VPN diagnostics with the degraded connection flag, health-failure
  counters, reconnect attempts, uptime, profile ping, and last healthy timestamps.

## 1.0.32 - 2026-06-05

- Renamed the Android app brand from Aurum VPN to Yurich Connect across the
  launcher label, Flutter title, notification title, updater messages, and
  support docs.
- Kept the Android package/application id unchanged so existing installs can
  update in place.

## 1.0.27 - 2026-06-01

- Improved Android APK handoff for in-app updates on OEM firmware by copying
  the downloaded APK into the app cache and opening it with a MIME-aware
  installer intent.
- Granted temporary APK read access to all matching Android package installers.

## 1.0.26 - 2026-06-01

- Added a visible update channel line in the Updates panel so in-app update
  tests clearly show that the GitHub Releases flow is active.
- Prepared a new release build for Android auto-update validation.

## 1.0.25 - 2026-06-01

- Throttled live traffic UI updates so long VPN sessions do not rebuild the
  home screen on every native counter event.
- Added timeouts and best-effort handling around native VPN calls, reducing UI
  hangs during start, stop, reconnect, and language changes.
- Hardened Android service cleanup on destroy by closing the command server,
  TUN file descriptor, network monitor, receiver, and notification.
- Guarded sing-box/libbox initialization so Flutter engine reattach does not
  launch duplicate setup jobs.
- Disabled Android backup/data extraction for app data and explicitly blocked
  cleartext traffic in the release manifest.

## 1.0.24 - 2026-05-26

- Added subscription expiry metadata to saved profiles.
- Imported subscription expiration from common subscription metadata such as
  `subscription-userinfo: ... expire=...`.
- Added a paid subscription countdown to the profile/network card.

## 1.0.23 - 2026-05-26

- Fixed Android in-app update installation by registering the APK
  `FileProvider` and exposing the app cache directory used for downloaded
  update files.
- Switched the updater installer intent to Android's package install action for
  a more reliable handoff after the user allows installs from Aurum VPN.

## 1.0.22 - 2026-05-26

- Moved the main connect/disconnect button directly under the connection status
  card, above the profiles block, so the primary VPN action stays visible
  sooner on mobile screens.

## 1.0.21 - 2026-05-26

- Changed generated NaiveProxy startup order to prefer HTTPS CONNECT fallback
  first and keep native Naive as the second fallback. Local tunnel tests showed
  the fallback avoids native Naive's extra UDP/QUIC probing path and performs at
  least as fast on the tested server.
- Restored Android TUN stack to `gvisor`, matching current NB4A guidance where
  newer builds default back to gVisor for compatibility.
- Kept MTU 9000, FakeDNS, protected DNS through the tunnel, and Hysteria/VLESS
  import support.

## 1.0.20 - 2026-05-25

- Added an in-app Updates section that checks release metadata, downloads the
  matching APK for the phone ABI, and opens the Android installer without
  sending the user to a browser.
- Tuned TUN for throughput by switching from full gVisor to `mixed` stack,
  keeping system TCP for TCP-heavy protocols while retaining gVisor for UDP.
- Removed `endpoint_independent_nat` from the default Android TUN config because
  sing-box documents a possible performance cost and Aurum rejects unsupported
  UDP for NaiveProxy by design.

## 1.0.19 - 2026-05-25

- Reverted the experimental 1.0.18 Android inbound/DNS fields that could make
  sing-box stop immediately on startup on some devices.
- Restored the known-good NaiveProxy order: native Naive first, HTTPS CONNECT
  fallback second.
- Removed the automatic throughput probe from startup so a valid connection is
  not rejected while the tunnel is still warming up.
- Kept Hysteria/Hysteria2 import support and VLESS `packet_encoding: xudp`.

## 1.0.18 - 2026-05-25

- Moved sniffing closer to the NekoBox model by enabling it on TUN/mixed
  inbounds instead of using a global route sniff rule.
- Added `domain_strategy` on generated Android inbounds, plus DNS
  `independent_cache` and FakeDNS `disable_cache`.
- Changed NaiveProxy startup order to try HTTPS CONNECT first, then native
  Naive, and added a short tunnel throughput probe so a very slow mode can
  automatically fall back.
- Kept VLESS `packet_encoding: xudp` and Hysteria import support from 1.0.17.

## 1.0.17 - 2026-05-25

- Added first-class import/build support for Hysteria2 (`hy2://`,
  `hysteria2://`) and Hysteria (`hysteria://`) profiles.
- Tuned generated VLESS profiles with `packet_encoding: xudp`, matching common
  Xray/sing-box mobile profile behavior for better UDP compatibility.
- Kept NaiveProxy on the stable HTTP/2 path and preserved the Neko-style DNS
  split that resolved the previous reconnect and FakeDNS issues.
- Shortened the manual stop wait path so the UI returns from disconnect faster
  while sing-box finishes cleanup in the background.
- Updated UI text, QR hints, diagnostics redaction, and tests for the expanded
  protocol set.

## 1.0.16 - 2026-05-25

- Added NekoBox-style DNS separation: proxy server hostnames are resolved with
  the local resolver, while user traffic DNS stays protected through the tunnel.
- Kept FakeDNS scoped to the TUN inbound so local mixed-proxy checks do not use
  FakeIP records.
- Removed release debug symbols from packaged native libraries to reduce APK
  size and make the build closer to a production artifact.

## 1.0.15 - 2026-05-25

- Tuned Android TUN performance closer to NekoBox: MTU 9000 and
  endpoint-independent NAT.
- Scoped FakeDNS to the TUN inbound so the local mixed proxy and health checks
  do not inherit unnecessary FakeIP behavior.
- Force native NaiveProxy to HTTP/2 unless a raw custom sing-box config is used,
  avoiding accidental QUIC/H3 negotiation in generated profiles.
- Disabled live sing-box log streaming by default; logs are attached only when
  the log panel is opened or a report is prepared.

## 1.0.14 - 2026-05-25

- Removed experimental NaiveProxy QUIC/H3 from automatic startup because it can
  cause reconnect loops on mobile networks and some Wi-Fi routers.
- Restored stable NaiveProxy startup order: native Naive over HTTP/2 first,
  HTTPS CONNECT fallback second.
- Kept IPv4-only endpoint dialing to avoid broken server IPv6 paths, but
  removed TCP Fast Open from default dial settings for safer compatibility.
- Prepared Android split-per-ABI APK artifacts locally to reduce install size.

## 1.0.13 - 2026-05-25

- Added a faster NaiveProxy startup plan that tries native Naive over QUIC/H3
  before falling back to HTTP/2 and HTTPS CONNECT.
- Tuned outbound dial settings for IPv4-only resolution, TCP Fast Open, and
  quicker network fallback.
- Replaced the bottom import sheet with a centered import dialog.
- Prepared local Android test artifacts without publishing to GitHub.

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
