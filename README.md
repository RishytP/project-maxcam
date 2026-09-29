# MaxCam

A professional third-party cinema camera app for iPhone. MaxCam exposes the
maximum legitimate video capability available through Apple's **public**
AVFoundation / CoreMedia / VideoToolbox / Metal APIs on the physical device —
and nothing it cannot prove.

## Philosophy

> Expose everything the hardware legitimately allows. Do not artificially
> restrict to Apple's stock Camera feature set. Do not pretend to unlock
> features that public APIs do not expose.

Hard rules enforced throughout the codebase:

1. Inspect the actual device at runtime. Nothing is hard-coded per model.
2. A capability is selectable **only** if the current device advertises it.
3. **Apple Log 2** is only labeled "Apple Log 2" when `AVCaptureColorSpace.appleLog2`
   is genuinely present in the active format's `supportedColorSpaces`.
   No custom transform is ever mislabeled as native Apple Log 2.
4. **ProRes RAW** is only offered when `AVCaptureMovieFileOutput.availableVideoCodecTypes`
   advertises the RAW identifier, and never conflated with standard ProRes.
5. **Open Gate** mode is only labeled "true sensor-format Open Gate" when the
   active format scans the full square sensor (4032×4032 class formats backed
   by `supportedDynamicAspectRatios` on iOS 26+, or an equal-width/height
   format on older systems).
6. The monitoring LUT never bakes into the recorded master unless the user
   explicitly chooses a baked-in mode.
7. The realtime recording pipeline avoids `UIImage`/`CGImage` conversions.

## Architecture

```
CameraEngine                     (thread-safe engine, owns AVCaptureSession)
├── DeviceCapabilities           runtime device tree (model, cameras, formats)
├── CameraFormatInfo             normalized AVCaptureDevice.Format wrapper
├── CapabilityMatrix             valid RecordingConfiguration builder
├── CapabilityGate               named "why not supported" reasons
├── EncoderCapabilities          codec advertising via AVCaptureMovieFileOutput
├── DiagnosticsExport            full on-device support report
├── MetalProcessor               preview-only display transform (log/P3 → sRGB)
├── AppViewModel                 ObservableObject glue (SwiftUI <-> engine)
└── CameraView / CapabilitiesView  dark cinema UI + capability inspector
```

Engine code imports only AVFoundation/CoreMedia/Foundation/UIKit/Metal and has
zero SwiftUI dependencies. All `AVCaptureDevice` mutations are serialized on the
engine queue.

## Current feature set

- Live camera preview (`AVCaptureVideoPreviewLayer`, AVFoundation native
  tone-mapping for Apple Log / P3 / HLG).
- **Custom Camera Capabilities** diagnostic screen enumerating every real
  camera, format, frame-rate range, pixel format, color space, HDR flag, field
  of view, and lens aperture where exposed.
- Capability-driven recording configuration matrix (resolution × FPS × color
  space × codec). Only combinations the device advertises are selectable.
- HEVC 10-bit recording via `AVAssetWriter` with correct BT.2020 color
  metadata for Log/HLG modes.
- Apple Log / Apple Log 2 capture when the device's format advertises them.
- Manual exposure (ISO, shutter, bias), focus (tap/lock), and white balance
  (temperature/tint presets to gains).
- Open Gate: on iOS 26+, `AVCaptureDevice.setDynamicAspectRatio` applied over
  square full-sensor formats; older OS falls back to square-format detection.
- Thermal state surfacing and dropped-frame accounting.
- Pro Video Storage (iOS 27+) gated on `isProVideoStorageSupported`.
- Unit-testable capability gate and configuration summary tests.

## Building

Requires Xcode 16+ with the iOS 26 SDK (for `.appleLog2` and
`setDynamicAspectRatio`; the source compiles against lower deployment targets
via `#available` guards). No Swift toolchain is available in this repository's
Linux environment; verification is by static source/byte inspection and the
unit tests run on-device/Xcode.

Open `MaxCam.xcworkspace` or `MaxCam.xcodeproj` and run the `MaxCam` scheme on
an iPhone. The `MaxCamTests` scheme runs the capability-gate tests.

## Timelines / availability notes (researched from public Apple docs)

| Capability | API | Availability |
|---|---|---|
| Apple Log | `AVCaptureColorSpace.appleLog` | iOS 17+ (iPhone 15 Pro line) |
| Apple Log 2 | `AVCaptureColorSpace.appleLog2` | iOS 26+ (iPhone 17 line) |
| Dynamic aspect ratio | `AVCaptureDevice.setDynamicAspectRatio` / `supportedDynamicAspectRatios` | iOS 26+ |
| Pro Video Storage | `AVAssetWriter.usesProVideoStorage` | iOS 27+ |
| ProRes RAW | `AVVideoCodecType.proResRAW` | gained via `availableVideoCodecTypes` (iPhone 17 Pro line); verified at runtime only |
| ProRes (422 family) | `availableVideoCodecTypes` | iPhone 13 Pro+ |

## Device-specific behavior

The capability tree is generated on launch from `AVCaptureDevice.DiscoverySession`
and `device.formats`. Dialogs that show enabled/disabled states always display
the `CapabilityGate` reason for any disabled option, so nothing is ever silently
withheld.

## Repository contents note

`MaxCamShaders.metal` compiles into the default Metal library only when the
build embeds a metallib. The `MetalProcessor` degrades gracefully to
AVFoundation's native preview tone-mapping when no shader library is present.