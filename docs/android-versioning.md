# Android versioning and retained builds

The Flutter package version in `pubspec.yaml` is the source of truth:

```yaml
version: 1.0.0+1
```

- `1.0.0` is the user-facing version name.
- `1` is the monotonically increasing Android version code.
- Increment both before archiving the next release, for example `1.0.1+2`.

Create an installable, versioned testing build from PowerShell:

```powershell
.\tool\build-versioned-android.ps1
```

The script creates both a universal debug APK and smaller APKs split by CPU architecture. It stores them outside Flutter's disposable `build` directory at:

```text
..\mobile-releases\android\v<version>+<build-number>\
```

Use the `arm64-v8a` APK for most current physical Android phones. Use the universal APK when the device architecture is unknown. `x86_64` is mainly for emulators and `armeabi-v7a` is for older 32-bit devices.

Each archive includes `release-info.txt` and `SHA256SUMS.txt`. The script refuses to overwrite an existing version, so increment `version` in `pubspec.yaml` before building again.

For Google Play, configure the private release signing key and build an Android App Bundle. Do not commit `key.properties`, `.jks`, or `.keystore` files.
