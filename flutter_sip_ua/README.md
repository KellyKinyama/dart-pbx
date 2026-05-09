# flutter_sip_ua

Pure-Dart SIP user agent and Flutter client for the dart-pbx server. The UI is
modelled on [InnovateAsterisk Browser-Phone](https://github.com/InnovateAsterisk/Browser-Phone)
with a Riverpod-driven state layer and a modular widget tree.

**Repository:** <https://github.com/KellyKinyama/flutter_sip_ua>

## Features

- Pure-Dart SIP signalling stack (`lib/sip/`) — registration, calls, MESSAGE,
  digest auth, SDP, RTP/RTCP helpers.
- Riverpod-based state management (`lib/providers/sip_providers.dart`).
- Browser-Phone-style UI:
  - Two-pane shell with buddy sidebar + active stream.
  - Modular call screen (`lib/ui/widgets/call/`).
  - Dialer sheet, message composer, transfer sheet.
- Light **and** dark themes that mirror `phone.light.css` / `phone.dark.css`.
  Theme choice is persisted via SharedPreferences and toggled from the sidebar
  toolbar (system → light → dark).

## Getting started

```sh
flutter pub get
flutter run -d windows   # or chrome / android / ios / linux / macos
```

Tests:

```sh
flutter test
```

## Project layout

```
lib/
  main.dart
  providers/sip_providers.dart   # Riverpod facade over the SIP UA + UI state
  sip/                           # Pure-Dart SIP UA, SDP, transport, audio/video
  ui/
    theme.dart                   # Light/dark ThemeData built from BP palette
    bp_palette.dart              # Browser-Phone color tokens + ThemeExtension
    home_page.dart               # Two-pane shell + dialer sheet
    call_page.dart               # Slim call orchestrator
    widgets/
      buddy_sidebar.dart         # Left rail incl. theme toggle
      dial_pad.dart
      dialer_action_row.dart
      call/                      # Modular call UI pieces
```

## Links

- Source: <https://github.com/KellyKinyama/flutter_sip_ua>
- Issues: <https://github.com/KellyKinyama/flutter_sip_ua/issues>
- Browser-Phone reference: <https://github.com/InnovateAsterisk/Browser-Phone>
