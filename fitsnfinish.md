This master specification for **FITS n' Finish** provides the complete App Store Connect marketing metadata, iOS developer implementation details, project architecture, and automated CLI notarization pipeline.  
**App Store Connect Metadata**

> * **App Name:** FITS n' Finish  
> * **Subtitle:** Hybrid Atmospheric Gradient Subtraction  
> * **Bundle Identifier:** io.bino.fitsnfinish

> * **Primary Category:** Photo & Video / Utilities  
> * **Keywords:** astrophotography, FITS, light pollution, gradient removal, skyglow, deep sky, astronomy, PixInsight, noise reduction, stretch

**App Store Description** FITS n' Finish brings deterministic physical modeling to astronomical gradient removal, delivering clean backgrounds without destroying faint, extended targets.  
**For All Astrophotographers:**  
Background extraction tools often require placing hundreds of sample boxes across your image, only to end up clipping your nebulosity or leaving dark halos around bright stars. FITS n' Finish automates this by reading live telemetry—including your GPS location, target altitude/azimuth heading, local humidity, and aerosol data—to calculate exact atmospheric skyglow in real time.  
**For Advanced & Veteran Astro-Imagers:** Traditional statistical tools (like ABE/DBE or AI models) treat your image strictly as an isolated numerical grid. When fitting steep horizon gradients or wide-field airmass shifts, high-order polynomials routinely "scoop out" real target flux like Integrated Flux Nebula (IFN) or outer galaxy halos. FITS n' Finish solves this via a hybrid two-stage engine:

> * **Physics Removes the Non-Linear Baseline:** Rayleigh and Mie scattering models calculate the steep airmass curve from device telemetry *before* statistical sampling occurs.  
> * **Math Operates at a Safe Low Order:** The mathematical surface fitter only needs a gentle 1st or 2nd-degree polynomial to clean up remaining localized light domes or optical flat residuals.  
> * **Preserves Deep Target Flux:** Low-order linear surfaces lack the freedom to conform to or erase complex target structures, keeping faint nebulosity intact.

**Developer Prerequisites & Technical Implementation Notes**  
**1\. Required Frameworks & Capabilities**

> * **Core Frameworks:** SwiftUI, MetalKit, Accelerate (vDSP, LAPACK), CoreLocation, CoreMotion, WeatherKit.  
> * **Xcode Capabilities:** Enable **WeatherKit** in App Store Connect & Xcode. Add NSLocationWhenInUseUsageDescription and NSMotionUsageDescription to Info.plist.  
> * **File Handling:** Set LSSupportsOpeningDocumentsInPlace \= YES and UIFileSharingEnabled \= YES in Info.plist for 16-bit FITS file access.

**2\. Memory & Math Pipeline**

> * **FITS Parsing:** FITS uses big-endian storage. Use vDSP.reverseByteOrder on incoming 16-bit buffers before converting to normalized 32-bit floats.  
> * **Surface Fitting:** Execute low-order 2D polynomial least-squares surface fitting on GPU/CPU via Accelerate framework LAPACK routines (dgels\_).  
> * **Metal Shader:** SubtractEngine.metal blends the physical prior texture and mathematical surface texture, applying linear subtraction while clamping black points at 0.0.

**Project Directory Structure**

Plaintext  
FitsnFinish/    
├── App/    
│   ├── FitsnFinishApp.swift    
│   └── Views/ (MetalView.swift, ControlsView.swift)    
├── Core/    
│   ├── FITS/ (FITSReader.swift, FITSHeader.swift)    
│   ├── Telemetry/ (TelemetryManager.swift, WeatherService.swift)    
│   ├── Physics/ (AtmosphericModel.swift, RayleighMie.swift)    
│   └── Math/ (PolynomialFitter.swift, LAPACKSolver.swift)    
├── Metal/    
│   └── SubtractEngine.metal    
├── Tests/    
│   ├── FITSTests.swift    
│   └── SolverTests.swift    
└── Scripts/    
    ├── ExportOptions.plist  
    └── build\_and\_notarize.sh  

**Info.plist & Configuration Overrides**

XML  
\<key\>CFBundleDisplayName\</key\>  
\<string\>FITS n' Finish\</string\>  
\<key\>CFBundleName\</key\>  
\<string\>FITS n' Finish\</string\>  
\<key\>CFBundleIdentifier\</key\>  
\<string\>io.bino.fitsnfinish\</string\>

**Automated CLI Build Script (Scripts/build\_and\_notarize.sh)**

Bash  
\#\!/usr/bin/env bash  
set \-eo pipefail    
    
SCHEME="FitsnFinish"    
BUNDLE\_ID="io.bino.fitsnfinish"    
KEYCHAIN\_PROFILE="FF\_NOTARY\_PROFILE"    
ARCHIVE\_PATH="./build/FitsnFinish.xcarchive"    
EXPORT\_PATH="./build/export"    
    
\# 1\. Run Unit Tests via CLI    
xcodebuild test \\  
  \-scheme "$SCHEME" \\  
  \-destination 'platform=macOS' \\  
  | xcbeautify || exit 1    
    
\# 2\. Archive Application    
xcodebuild archive \\  
  \-scheme "$SCHEME" \\  
  \-archivePath "$ARCHIVE\_PATH" \\  
  \-destination 'generic/platform=macOS' \\  
  CODE\_SIGN\_STYLE="Manual" \\  
  CODE\_SIGN\_IDENTITY="Developer ID Application" \\  
  PROVISIONING\_PROFILE\_SPECIFIER="Mac\_App\_Direct"    
    
\# 3\. Export Package    
xcodebuild \-exportArchive \\  
  \-archivePath "$ARCHIVE\_PATH" \\  
  \-exportOptionsPlist ./Scripts/ExportOptions.plist \\  
  \-exportPath "$EXPORT\_PATH"    
    
\# 4\. Notarize via xcrun notarytool    
xcrun notarytool submit \\  
  "$EXPORT\_PATH/FitsnFinish.pkg" \\  
  \--keychain-profile "$KEYCHAIN\_PROFILE" \\  
  \--wait    
    
\# 5\. Staple Ticket    
xcrun stapler staple "$EXPORT\_PATH/FitsnFinish.app"

**Autonomous LLM Execution Prompt**

Plaintext  
Follow this step-by-step sequence to build FitsnFinish as a Swift engineer:    
    
1\. Scaffold: Create the directory tree and Swift Package file (\`Package.swift\`) or Xcode Project (\`FitsnFinish.xcodeproj\`) configured for macOS/Mac Catalyst. Set display name (\`CFBundleDisplayName\`) to "FITS n' Finish" and bundle identifier to "io.bino.fitsnfinish".    
2\. Implement Modules: Generate code for \`FITSReader.swift\`, \`AtmosphericModel.swift\`, \`PolynomialFitter.swift\`, and \`SubtractEngine.metal\` implementing big-endian decoding, Rayleigh/Mie airmass equations, and GPU subtraction.    
3\. Unit Test: Write unit tests in \`Tests/\` asserting that a synthetic 100x100 FITS grid yields flat residuals after physical subtraction. Run \`swift test\` or \`xcodebuild test\`. Iterate until zero errors.    
4\. Build Shell Script: Generate \`ExportOptions.plist\` and execute \`./Scripts/build\_and\_notarize.sh\`.    
5\. Error Recovery: If \`xcodebuild\` or \`notarytool\` returns a non-zero exit code, parse the error payload, patch the configuration, and re-trigger step 4\.  
