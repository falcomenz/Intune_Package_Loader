# Intune Package Loader

`Intune Package Loader` is a macOS app for capturing unmanaged Intune-delivered macOS installer payloads while they are being staged for installation.

The app watches Intune's temporary staging area, mirrors discovered installer files to a persistent folder, and shows them in a small GUI so they can be opened in Finder or copied elsewhere.

## What It Is For

This project is useful when:

- a macOS `PKG` or `DMG` still exists in Intune
- the original installer file is no longer available elsewhere
- the app can still be installed from Company Portal or as an Intune-assigned macOS app

The current implementation is aimed at unmanaged macOS package-style apps delivered through the local Intune macOS agent.

## How It Works

The app uses a privileged helper tool to watch Intune's short-lived staging path under:

```text
/private/var/folders/.../T/com.microsoft.intuneMDMAgent/
```

New installer artifacts are mirrored to:

```text
/Library/Application Support/Intune_Package_Loader/packages
```

The GUI reads from that mirrored folder and shows captured packages.

Additional behavior:

- the root helper runs via `SMJobBless`
- the GUI communicates with the helper over XPC
- mirrored files are renamed from random UUID filenames to the Intune app name when a matching entry is found in Intune daemon logs
- the app tracks `.pkg` and `.dmg` files in the UI
- the mirror auto-stops after a newly captured `.pkg`

## Requirements

- macOS 13 or newer
- Microsoft Intune / Company Portal installed and functional on the Mac
- the target app must still be installable from Intune on that device
- Xcode and Xcode command line tools if you want to build the project yourself
- a valid Apple signing setup if you want to archive, distribute, and notarize the app

## Using the App

1. Launch `IntunePackageLoader.app`.
2. Click `Start Mirror`.
3. Approve the admin prompt.
   The first privileged-helper installation/update requires authentication.
4. Open Company Portal and start installation of the macOS app you want to capture.
5. Wait until the GUI shows a captured package.
6. Use `Reveal` or `Copy Path` to access the mirrored file.

Mirrored files are stored here:

```text
/Library/Application Support/Intune_Package_Loader/packages
```

Other GUI actions:

- `Refresh`: reload status and file list
- `Open Folder`: open the mirrored packages folder in Finder
- `Cleanup`: remove mirrored packages from the storage folder
- `Stop Mirror`: stop the privileged mirror helper manually

## Notes About Behavior

- Intune often creates transient files such as `.pkg.bin` before the actual installer appears.
- The GUI intentionally focuses on real mirrored installer files, not every transient artifact.
- Package names are resolved from local Intune logs when possible.
- If Intune already considers the app installed, it may not download it again. In that case, remove the app first or test with another available app.

## Build From Source

The project is generated with XcodeGen.

Build locally:

```bash
cd /Intune_Package_Loader
chmod +x ./build_intune_package_loader_app.sh
./build_intune_package_loader_app.sh
open ./dist/IntunePackageLoader.app
```

Unsigned local build:

```bash
cd /Intune_Package_Loader
SKIP_CODESIGN=1 ./build_intune_package_loader_app.sh
```

## Open In Xcode

Generate and open the project:

```bash
cd /Intune_Package_Loader
xcodegen generate --spec project.yml
open IntunePackageLoader.xcodeproj
```

Important project facts:

- main app bundle id: `de.axelspringer.intune.package-loader`
- privileged helper bundle id: `de.axelspringer.intune.package-loader.mirror-service`
- the helper is embedded at:

```text
IntunePackageLoader.app/Contents/Library/LaunchServices/de.axelspringer.intune.package-loader.mirror-service
```

## Archive And Distribution

For a proper archive that Xcode recognizes as a `macOS App Archive`:

- the helper target must not be archived as a standalone installable tool
- the helper is embedded into the app bundle during the app target post-build step
- the archive should contain the app under `Products/Applications`

To create a distributable archive:

1. Open the project in Xcode.
2. Set your signing team for app and helper.
3. Use `Developer ID Application` signing for distribution builds.
4. Run `Product > Clean Build Folder`.
5. Run `Product > Archive`.
6. Use Organizer for export / notarization.

If Organizer still does not offer direct distribution, check:

- app and helper are both signed
- the archive appears as `macOS App Archive`, not `Other Items`
- the archive `Info.plist` contains `ApplicationProperties`

## Important Paths

Mirrored payloads:

```text
/Library/Application Support/Intune_Package_Loader/packages
```

Mirror log:

```text
/Library/Application Support/Intune_Package_Loader/mirror.log
```

Intune logs used for renaming:

```text
/Library/Logs/Microsoft/Intune
```

Privileged helper install location:

```text
/Library/PrivilegedHelperTools/de.axelspringer.intune.package-loader.mirror-service
```

## Repository Layout

- [IntunePackageLoaderApp]: SwiftUI GUI
- [MirrorService]: privileged helper / mirror logic
- [Shared]: shared constants and XPC protocol
- [project.yml]: XcodeGen project definition
- [build_intune_package_loader_app.sh]: local build helper

## Disclaimer

This tool relies on observed local Intune staging behavior on macOS. Microsoft can change that behavior at any time. Test on a non-critical device before using it in broader workflows.
