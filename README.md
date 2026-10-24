# LanBridge — cross-platform LAN file transfer

This is an **early Flutter MVP source project**, not yet a tested/release build. It establishes the first UI and a prototype LAN discovery/upload flow.

## Targets
- iOS: IPA (requires macOS/Xcode to build; TrollStore installation does not remove the need to build an IPA)
- Windows: EXE/MSIX via Flutter Windows build
- Android: APK via Flutter Android build

## Current prototype features
- iPhone-inspired clean interface with light/dark theme
- UDP broadcast discovery on the same LAN
- HTTP upload receiver on TCP port 8765
- multi-file picker and send progress
- receiver approval prompt
- any file extension (binary stream)

## Important limitations before using with real/private files
- Prototype only. Not yet compiled or device-tested.
- Current receive implementation saves to the app documents directory; user-selectable destination and iOS Files export are not yet implemented.
- No encryption/authentication token yet; use only a trusted private LAN.
- UDP broadcast discovery may be blocked by guest Wi-Fi/AP isolation, Windows Firewall, or iOS local-network permissions.
- Upload acceptance is currently a basic prompt; test with non-sensitive sample files first.
- Large-file resume, hash verification, duplicate-name handling, and robust concurrent transfers are not implemented yet.

## Build prerequisites
Install Flutter stable and platform toolchains. From this directory:

```sh
flutter pub get
flutter analyze
flutter run -d windows
flutter build windows --release
flutter build apk --release
```

For iOS, use a Mac with Xcode:

```sh
flutter build ios --release
# Then archive/sign with Xcode as appropriate, or export an IPA from Xcode.
```

## Platform setup still required
- iOS: add `NSLocalNetworkUsageDescription` and Bonjour/local-network declarations as needed in `ios/Runner/Info.plist`; verify local-network permission behavior.
- Android: declare Internet and local network permissions as needed; configure Android version requirements.
- Windows: allow LanBridge through Windows Defender Firewall on private networks.

## Next development milestones
1. Make the save destination user-selectable on each platform.
2. Add a per-session pairing token and encrypted transport.
3. Add file hash verification, collision-safe naming, cancellation and resume.
4. Harden UDP discovery and add manual IP/QR fallback.
5. Compile and test all three targets on real devices.
