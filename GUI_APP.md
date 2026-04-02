# Intune Package Loader GUI

Build:

```bash
cd /Users/falco.menz/Documents/macOS_pkg_Intune_loader
chmod +x ./build_intune_package_loader_app.sh
./build_intune_package_loader_app.sh
open ./dist/IntunePackageLoader.app
```

The project is generated with XcodeGen and built with Xcode. The GUI uses a privileged installer script to register a `launchd` daemon that runs the bundled `IntunePackageMirrorService` root helper and mirrors files into:

- `/Library/Application Support/Intune_Package_Loader/packages`
