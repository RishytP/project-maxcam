# MaxCam — repository notes for agents

MaxCam is an independent iOS cinema camera app. It uses Apple's public
AVFoundation / CoreMedia / CoreVideo / VideoToolbox / Metal APIs only. There is
no Swift/Xcode toolchain in the dev container, so **CI is the only compile
feedback loop**.

## Building and testing

- CI: `.github/workflows/build-ipa.yml`, runner `macos-26` (Xcode 26 / iOS 26
  SDK). The app uses iOS 26 symbols (`AVCaptureColorSpace.appleLog2`,
  `AVCaptureDevice.Format.supportedDynamicAspectRatios`), which do not exist in
  the iOS 18 SDK shipped with Xcode 16 on `macos-14`/`macos-15`.
- Deployment target stays **iOS 17.0**. Every iOS 26 symbol must be reached
  behind `#available(iOS 26.0, *)`. Naming an iOS 26 symbol outside the guard is
  a compile error, so probes live in `@available` helper functions.
- Local pre-flight: `python3 scripts/validate_pbxproj.py` validates the Xcode
  object graph (undefined/duplicate IDs, `PBXBuildFile` -> `PBXFileReference`
  integrity, Sources-phase coverage, Products group, `rootObject`/`mainGroup`).
  Run it after any `project.pbxproj` edit.
- `project.pbxproj` is TAB-indented. Match tabs exactly when scripting edits;
  a space-indented pattern silently matches nothing (or matches a deeper line
  as a substring) and the registration is silently skipped.

## Project file gotchas

- `MaxCam.xcworkspace/contents.xcworkspacedata` must use
  `location = "group:MaxCam.xcodeproj"`; `self:` breaks scheme lookup.
- When adding a source file, register it in **four** places: `PBXFileReference`,
  `PBXBuildFile`, the owning `PBXGroup` children, and the target's
  `PBXSourcesBuildPhase`.
- `PBXBuildFile.fileRef` must point at the `PBXFileReference` (an earlier
  version of this project had 12 build files pointing at themselves).
- The scheme is `MaxCam.xcodeproj/xcshareddata/xcschemes/MaxCam.xcscheme`.

## Swift/AVFoundation facts that bit us

- `AVCaptureDevice` has no `isColorSpaceSupported(_:)`. Test support with
  `device.activeFormat.supportedColorSpaces.contains(space)`.
- `lensAperture` is on `AVCaptureDevice`, not `AVCaptureDevice.Format`.
- `AVCaptureDevice.AspectRatio` is a raw-representable **struct**, not an enum:
  compare with `==`, never `switch`.
- `AVCaptureColorSpace` members are `.P3_D65` and `.HLG_BT2020` (capitalised),
  not `.p3D65` / `.hlgBT2020`.
- The 10-bit "Lossless" pixel format constants do not exist. CoreVideo declares
  only `kCVPixelFormatType_Lossless_420YpCbCr8BiPlanar*` and the 10-bit
  `..._Lossless_420YpCbCr10PackedBiPlanar*` spellings.
- `AVCapturePhotoOutput.availableRawPhotoPixelFormatTypes` is only populated
  after the output is added to a session that has a video input. Read it after
  `addOutput`, not before.
- Setting `AVCaptureVideoDataOutput.videoSettings` to a format not in
  `availableVideoPixelFormatTypes` can raise. Set it only after the output is
  attached and the format is active.
- `AVAssetWriterInput.append` can return false or report `isReadyForMoreMediaData
  == false` even with `expectsMediaDataInRealTime`; drop and count those frames.
- AVFoundation objects are not `Sendable`. The engine funnels mutations through
  a serial queue and publishes immutable snapshots. Types that hold framework
  objects use `@unchecked Sendable` with documented confinement.

## Product rules

- Never fabricate a capability. Every enabled option comes from a runtime
  AVFoundation query; unsupported features must surface a diagnostic reason
  (`CapabilityGate`).
- Never label the approximate monitoring transform as Apple Log 2. The Apple Log
  transfer function is not published; `MaxCamShaders.metal` implements an
  explicitly approximate display transform and says so.
- Never claim ProRes RAW. It is only reported when the system advertises `aprn`,
  and it is kept distinct from the ProRes 422/4444 family.
- "Open Gate" is only true when a format scans a **square sensor area**. A
  cropped 16:9 stream is never presented as Open Gate.
