# FaceUnlock for macOS

A lightweight menu bar face unlock tool for macOS, built with Swift, AppKit, and Apple's Vision framework. No Electron, no bundled ML model, no third-party runtime, and no network access.

> **Security warning**
>
> This is a convenience tool, not a security upgrade. Macs do not have Face ID hardware; this project uses the built-in 2D camera, which can be spoofed by a video. To unlock the Mac, the app stores your login password encrypted with a locally stored key and types it at the lock screen using the Accessibility API. Use at your own risk. If you need real security, use Touch ID or a strong password.

## Features

- On-device face enrollment and matching with Apple Vision
- Menu bar only: the icon appears while scanning and hides 3 seconds after unlock
- Lock screen and wake triggers
- Optional automatic password typing at the lock screen
- Encrypted local templates and password; camera frames are never written to disk
- Launch at login via `SMAppService`, with a LaunchAgent fallback
- Small footprint: roughly 400 KB app, ~40 MB idle memory, 0% idle CPU

## How it works

1. Enrollment captures 30 frames of a single face at 640x480 and stores up to 8 feature-print prototypes.
2. On lock or wake, the app captures frames, requires exactly one face, and computes the minimum Euclidean distance to the stored prototypes.
3. A strong single-frame match or two consecutive matches triggers the unlock path.
4. If automatic typing is enabled and Accessibility permission is granted, the app types the stored password and presses Return.
5. The menu bar icon is visible during scanning and collapses 3 seconds after unlock if the menu was not opened.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6 toolchain is recommended)
- Camera permission
- Accessibility permission, only if you enable automatic password typing
- An administrator account to install the app in `/Applications`

## Build

```bash
./scripts/build_app.sh
open dist/FaceUnlock.app
```

The build uses ad-hoc code signing. The app bundle is kept immutable at runtime; all mutable data lives in Application Support.

## Install

```bash
cp -R dist/FaceUnlock.app /Applications/
open /Applications/FaceUnlock.app
```

For a public distribution, change `CFBundleIdentifier` from `com.local.faceunlock` to a reverse-DNS identifier you own, rebuild, and sign with a Developer ID certificate. Ad-hoc signed builds may require right-clicking the app and choosing Open on first launch.

## Permissions

| Permission | Why |
|---|---|
| Camera | Capture frames for face detection and matching |
| Accessibility | Type the stored password at the lock screen, only when automatic typing is enabled |
| Login item | Optional launch at login |

## Data locations

```text
~/Library/Application Support/FaceUnlock/
├── key.bin
├── profile.bin
├── credential.bin
└── settings.json

~/Library/Logs/FaceUnlock/FaceUnlock.log
```

No images are stored. The app keeps only feature vectors, an encrypted password, and local settings.

## Uninstall

1. Open the menu and choose **Clear All Data and Quit**.
2. Delete `/Applications/FaceUnlock.app`.
3. If Camera or Accessibility entries remain in System Settings, remove them manually.

## Security model and limitations

- Face data is stored as feature vectors, never as images.
- The login password is encrypted with AES-GCM. The key is stored in the same data directory, so this protects against casual plaintext inspection, not a local attacker running as your user.
- Automatic password typing is disabled by default and requires explicit Accessibility permission.
- The app has no network code and does not send telemetry.
- A 2D camera cannot reliably distinguish a live face from a video replay. This project is not equivalent to Touch ID or Apple Face ID.
- The feature print is a generic image descriptor, not a face-specific recognition model. Thresholds need to be calibrated for your environment.
- The current build is ad-hoc signed. Rebuilding changes the code signature and may reset macOS privacy permissions.

## Project structure

```text
Sources/FaceUnlock/       Swift sources
Resources/Info.plist      App bundle metadata
scripts/build_app.sh      Build and package the app
docs/DESIGN.zh-CN.md      Development notes (Chinese)
```

## License

MIT. See [LICENSE](LICENSE).

## Trademark notice

This project is not affiliated with Apple Inc. "Face ID" is a trademark of Apple Inc. This project is named FaceUnlock to avoid confusion with Apple's product.
