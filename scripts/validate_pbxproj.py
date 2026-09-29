#!/usr/bin/env python3
"""Static validator for MaxCam.xcodeproj/project.pbxproj.

Checks the Xcode object graph without needing Xcode or a Swift toolchain:
- every referenced 24-hex object ID is defined exactly once,
- Products group has exactly the two product references,
- the app Sources phase contains every Swift/metal source file,
- the tests Sources phase contains the test file(s).

Exit code is 0 when valid, 1 otherwise.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBX = ROOT / "MaxCam.xcodeproj" / "project.pbxproj"

IS_ID = re.compile(r"^[A-F0-9]{24}$")

APPS_SWIFT = sorted(
    p.name
    for p in (ROOT / "MaxCam").rglob("*.swift")
    if p.name != "Info.plist"
)
APPS_METAL = sorted(p.name for p in (ROOT / "MaxCam").rglob("*.metal"))
TESTS_SWIFT = sorted(p.name for p in (ROOT / "MaxCamTests").rglob("*.swift"))


def main() -> int:
    text = PBX.read_text()
    problems: list[str] = []

    # Object definitions: `ID /* comment */ = {`.
    defs = re.findall(r"^[ \t]*([A-F0-9]{24}) /\* [^*]+? \*/ = \{", text, re.M)
    defined = set(defs)
    duplicates = sorted({d for d in defs if defs.count(d) > 1})
    if duplicates:
        problems.append(f"duplicate object definitions: {duplicates}")

    # Every ID mentioned with a comment marker must be defined.
    mentioned = re.findall(r"\b([A-F0-9]{24}) /\* [^*]+? \*/", text)
    missing = sorted({m for m in mentioned if m not in defined})
    if missing:
        problems.append(f"referenced but undefined: {missing}")

    # Object type histogram.
    types = re.findall(r"isa = ([A-Za-z]+);", text)
    expected_counts = {
        "PBXFileReference": len(APPS_SWIFT) + len(APPS_METAL) + len(TESTS_SWIFT) + 1 + 2,  # sources + assets + 2 products
        "PBXBuildFile": len(APPS_SWIFT) + len(APPS_METAL) + len(TESTS_SWIFT) + 1,  # +assets resource
        "PBXGroup": 11,
        "PBXNativeTarget": 2,
        "PBXProject": 1,
        "PBXSourcesBuildPhase": 2,
        "PBXFrameworksBuildPhase": 2,
        "PBXResourcesBuildPhase": 2,
        "PBXTargetDependency": 1,
        "PBXContainerItemProxy": 1,
        "XCBuildConfiguration": 6,
        "XCConfigurationList": 3,
    }
    actual = {t: types.count(t) for t in set(types)}
    for t, want in expected_counts.items():
        got = actual.get(t, 0)
        if got != want:
            problems.append(f"object type {t}: expected {want}, got {got}")

    # App Sources phase contains every source file.
    src_block = re.search(
        r"AB12C12345CD000000000003 /\* Sources \*/ = \{(.*?)\n\t\t\};", text, re.S
    )
    if src_block:
        app_names = set(re.findall(r"/\* ([^*]+?) in Sources \*/", src_block.group(1)))
        missing_sources = sorted(set(APPS_SWIFT + APPS_METAL) - app_names)
        if missing_sources:
            problems.append(f"app Sources phase missing: {missing_sources}")
        extra = sorted(app_names - set(APPS_SWIFT + APPS_METAL))
        if extra:
            problems.append(f"app Sources phase has unexpected: {extra}")

    # Tests Sources phase contains the test file(s).
    test_src = re.search(
        r"E2A2123456AC000000000010 /\* Sources \*/ = \{(.*?)\n\t\t\};", text, re.S
    )
    if test_src:
        test_names = set(re.findall(r"/\* ([^*]+?) in Sources \*/", test_src.group(1)))
        if set(TESTS_SWIFT) != test_names:
            problems.append(f"tests Sources phase mismatch: {test_names} vs {TESTS_SWIFT}")

    # Products group.
    prod = re.search(
        r"AB12C12345CD000000000040 /\* Products \*/ = \{(.*?)\n\t\t\};", text, re.S
    )
    if prod:
        prod_children = set(re.findall(r"\b([A-F0-9]{24}) /\* ([^*]+?) \*/", prod.group(1)))
        if not prod_children:
            problems.append("Products group is empty")

    if problems:
        print("VALIDATION FAILED")
        for p in problems:
            print(" -", p)
        return 1

    print(f"VALIDATION OK: {len(defined)} objects")
    return 0


if __name__ == "__main__":
    sys.exit(main())