# Shams desktop and Android client

A Flutter application that talks to the Rails **`/api/v1`** JSON API of this
repository. One codebase targets three platforms:

| Platform | Toolchain that builds it | Status here |
| -------- | ------------------------ | ----------- |
| Android  | Flutter + Android SDK    | built locally, `flutter build apk` |
| macOS    | Flutter + **full Xcode** | built in CI (`macos-latest`) |
| Windows  | Flutter + Windows/MSVC   | built in CI (`windows-latest`) |

Neither macOS nor Windows can be compiled on the other's host, and this
machine has no Xcode installed, so the two desktop artifacts are produced by
GitHub Actions (`.github/workflows/apps.yml`) while the APK is built locally.

The functional scope deliberately matches the Expo client in `../mobile`:
sign in, see the active conversations of your organization, and see its
agents. There is no message composer here yet - that lives on the web app and
in `../mobile`.

## Requirements

Verified on the development machine:

```text
Flutter 3.35.3 stable (channel stable, darwin-arm64)
Dart SDK ^3.9.2
Android Studio 2025.1 + Android SDK command-line tools
Java 17 (Temurin) - what Flutter uses for Gradle
```

`flutter doctor` must show the Android toolchain and (for desktop builds) Xcode
as healthy. Run `sdkmanager --licenses --sdk_root=$ANDROID_SDK_ROOT` once after
installing the SDK.

## Pointing the app at a server

The API origin is compile-time configuration, defaulting to
`http://localhost:3001` because that is the port `Procfile.dev` serves.
Pass `--dart-define` to change it:

```sh
# Desktop on this machine - the Rails server is on localhost
flutter run -d macos --dart-define=SHAMS_API_BASE=http://localhost:3001

# Android emulator - 10.0.2.2 is the host loopback inside the emulator
flutter run -d emulator --dart-define=SHAMS_API_BASE=http://10.0.2.2:3001

# A physical phone on the same network - use the machine's LAN address
flutter run -d <device-id> --dart-define=SHAMS_API_BASE=http://192.168.1.20:3001

flutter build apk --release --dart-define=SHAMS_API_BASE=https://shams.ai
```

Authentication is cookie-based, exactly like the web app: `POST /api/v1/sessions`
returns the `_shams_session` cookie plus a signed `user_id` cookie, and the
client replays both on every later request. Mutating calls additionally send the
CSRF token from `GET /api/v1/csrf` (or the rotated one the server returns in the
`X-CSRF-Token` response header). Cookies live in memory for the life of the
process, so each launch starts at the sign-in screen.

Because the session is carried in cookies, cleartext `http://` only works against
localhost or an emulator; a real deployment should be `https://`.

## Running and verifying

```sh
flutter pub get
flutter analyze                      # zero issues expected
flutter test                         # unit + widget tests (FakeTransport)
dart format --output=none --set-exit-if-changed lib test tool
```

The tests never touch a network: `test/fake_transport.dart` scripts the exact
Rails responses, including a login that sets two cookies.

To exercise the *real* API, start the Rails server and run the smoke script:

```sh
# repository root
env -u DATABASE_URL bin/rails server -p 3001

# apps/shams
dart run tool/live_smoke.dart
```

It signs in with the seeded development account (`shams@shams.ai` /
`password123`, override with `SHAMS_SMOKE_EMAIL` / `SHAMS_SMOKE_PASSWORD`),
lists conversations and agents, then signs out and checks the session is gone.
Use it after any change to the API client.

## Building

```sh
# Android - needs the Android SDK; debug APK at
# build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --debug
flutter build apk --release

# macOS - needs full Xcode; produces a .app bundle
flutter build macos --release

# Windows - needs Windows plus the "Desktop development with C++" workload
flutter build windows --release
```

Release Android builds are unsigned by default. Signing a Play Store upload uses
a keystore plus `android/key.properties`, which is intentionally not committed
(`.gitignore` covers `*.jks` and `*.keystore`).

## Layout

```text
lib/
  main.dart                    app entry + the loading/login/home state machine
  src/config.dart              SHAMS_API_BASE default
  src/api/http_transport.dart  dart:io transport behind a testable seam
  src/api/shams_api.dart       CSRF, cookie jar, sessions, agents, conversations
  src/api/models.dart          Agent and Conversation parsed defensively
  src/screens/app_screens.dart sign-in form and the signed-in lists
test/
  fake_transport.dart          scripted responses (no network)
  shams_api_test.dart          client behaviour: headers, cookies, errors
  widget_test.dart             the sign-in flow and both failure paths
tool/
  live_smoke.dart              end-to-end check against a running server
android/  macos/  windows/     generated platform runners (committed)
```

The transport is deliberately `dart:io` rather than a wrapper package: the login
response sets two cookies and the `user_id` one carries an `Expires` date
containing commas, so a client that flattens repeated headers into a single
joined string cannot parse it reliably. `flutter devices` on this machine shows
`macos` and `chrome`; the Windows runner folder is committed but only builds on
Windows.
