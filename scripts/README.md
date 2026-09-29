# Project generation

`MaxCam.xcodeproj/project.pbxproj` is maintained by hand. It contains two
targets:

- **MaxCam** (app): 16 Swift sources + `MaxCamShaders.metal` in Sources,
  `Assets.xcassets` in Resources.
- **MaxCamTests** (unit-test bundle): `CapabilityGateTests.swift`, hosted by the
  app target via `TEST_HOST`.

When files are added or removed, update all four places:

1. `PBXFileReference` section (one entry per file),
2. `PBXBuildFile` section (one build-file entry per file+phase),
3. the matching `PBXGroup` children list,
4. the owning `PBXSourcesBuildPhase` / `PBXResourcesBuildPhase`.

The shared scheme `MaxCam.xcodeproj/xcshareddata/xcschemes/MaxCam.xcscheme`
includes a `TestAction` that runs `MaxCamTests`.

## Static validation (runs without Xcode)

```
python3 scripts/validate_pbxproj.py
```

Checks the object graph: every referenced 24-hex-digit object ID must be
defined exactly once, and returns the counts of each object type. None of this
requires a Swift toolchain.
