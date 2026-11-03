/// Base URL of the Shams Rails JSON API.
///
/// The development server listens on port 3001 (see `Procfile.dev` at the
/// repository root). Every request this app makes is prefixed with
/// `/api/v1`, so only the scheme, host and port belong here.
///
/// Override it per platform at build or run time:
///
/// ```sh
/// flutter run   -d macos  --dart-define=SHAMS_API_BASE=http://localhost:3001
/// flutter run   -d <phone> --dart-define=SHAMS_API_BASE=http://192.168.1.20:3001
/// flutter build apk        --dart-define=SHAMS_API_BASE=http://10.0.2.2:3001
/// ```
///
/// `10.0.2.2` is the host loopback as seen from an Android emulator.
const String apiBase = String.fromEnvironment(
  'SHAMS_API_BASE',
  defaultValue: 'http://localhost:3001',
);
