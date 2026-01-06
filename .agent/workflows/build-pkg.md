---
description: Build a Universal macOS PKG installer for Dictant
---

This workflow builds the Dictant application as a Universal Binary (Intel + Apple Silicon) and packages it into a `.pkg` installer for easy distribution.

// turbo-all
1. Create a build directory
```bash
mkdir -p build
```

2. Archive the application as a Universal Binary
```bash
xcodebuild archive \
  -project Dictant.xcodeproj \
  -scheme Dictant \
  -configuration Release \
  -archivePath ./build/Dictant.xcarchive \
  -destination "generic/platform=macOS" \
  BUILD_MARKETING_VERSION="1.0.0" \
  ONLY_ACTIVE_ARCH=NO
```

3. Create the PKG installer from the archived .app
```bash
pkgbuild --component ./build/Dictant.xcarchive/Products/Applications/Dictant.app \
         --install-location /Applications \
         --identifier "ilin.pt.Dictant" \
         --version "1.0.0" \
         DictantInstaller.pkg
```

4. Clean up the archive (optional)
```bash
rm -rf ./build/Dictant.xcarchive
```

5. Success! The installer is ready.
```bash
ls -lh DictantInstaller.pkg
```
