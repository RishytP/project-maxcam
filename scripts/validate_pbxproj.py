#!/usr/bin/env python3
"""Static validator for MaxCam.xcodeproj/project.pbxproj.

Checks the Xcode object graph without needing Xcode or a Swift toolchain, so CI
can fail fast on a broken project file:

- every referenced 24-hex object ID is defined,
- no object ID is defined twice,
- every PBXBuildFile points at a PBXFileReference (not at itself, not at
  another PBXBuildFile) and its filename comment matches the target,
- every source file on disk is in the owning Sources phase,
- no Sources phase entry refers to a file that no longer exists,
- the Products group holds exactly the two product references,
- rootObject resolves to the PBXProject.

Exit code is 0 when valid, 1 otherwise.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBX = ROOT / "MaxCam.xcodeproj" / "project.pbxproj"

ID = r"[A-F0-9]{24}"
# Object definitions live at exactly two tabs of indentation inside `objects`.
# Anchoring to that depth keeps nested dictionaries (for example the
# `TargetAttributes` entries, which repeat a target ID) from being mistaken for
# definitions. Comments are optional: the root PBXGroup has none.
DEFINITION = re.compile(r"^[ \t]{2}(" + ID + r")(?: /\* (.*?) \*/)? = \{", re.M)
BUILD_FILE = re.compile(
    r"^[ \t]*(" + ID + r") /\* (.*?) \*/ = \{isa = PBXBuildFile; "
    r"fileRef = (" + ID + r") /\* (.*?) \*/; \};",
    re.M,
)
FILE_REFERENCE = re.compile(
    r"^[ \t]*(" + ID + r") /\* (.*?) \*/ = \{isa = PBXFileReference;",
    re.M,
)
SOURCES_PHASE = re.compile(
    r"isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);", re.S
)


def source_files() -> set[str]:
    files = {p.name for p in (ROOT / "MaxCam").rglob("*.swift")}
    files |= {p.name for p in (ROOT / "MaxCam").rglob("*.metal")}
    return files


def test_files() -> set[str]:
    return {p.name for p in (ROOT / "MaxCamTests").rglob("*.swift")}


def main() -> int:
    text = PBX.read_text()
    problems: list[str] = []

    definitions = DEFINITION.findall(text)
    defined_ids = [object_id for object_id, _ in definitions]
    defined = set(defined_ids)

    duplicates = sorted({i for i in defined_ids if defined_ids.count(i) > 1})
    if duplicates:
        problems.append(f"duplicate object definitions: {duplicates}")

    referenced = set(re.findall(ID, text))
    undefined = sorted(referenced - defined)
    if undefined:
        problems.append(f"undefined object references: {undefined}")

    file_reference_ids = {i for i, _ in FILE_REFERENCE.findall(text)}

    build_file_ids: set[str] = set()
    for build_id, build_name, ref_id, ref_name in BUILD_FILE.findall(text):
        build_file_ids.add(build_id)
        if ref_id == build_id:
            problems.append(f"{build_name}: fileRef points at itself ({ref_id})")
            continue
        if ref_id not in file_reference_ids:
            problems.append(
                f"{build_name}: fileRef {ref_id} ({ref_name}) is not a PBXFileReference"
            )
            continue
        if build_name.replace(" in Sources", "").replace(" in Resources", "") != ref_name:
            problems.append(
                f"{build_name}: filename comment does not match fileRef ({ref_name})"
            )

    # Sources phases must cover exactly the on-disk source files.
    phases = SOURCES_PHASE.findall(text)
    if len(phases) != 2:
        problems.append(f"expected 2 PBXSourcesBuildPhase blocks, found {len(phases)}")

    app_phase, tests_phase = (phases + ["", ""])[:2]
    app_names = set(re.findall(r"/\* (.*?) in Sources \*/", app_phase))
    test_names = set(re.findall(r"/\* (.*?) in Sources \*/", tests_phase))

    expected_app = source_files()
    if app_names != expected_app:
        problems.append(
            "app Sources phase mismatch: "
            f"missing={sorted(expected_app - app_names)} "
            f"extra={sorted(app_names - expected_app)}"
        )

    expected_tests = test_files()
    if test_names != expected_tests:
        problems.append(
            "tests Sources phase mismatch: "
            f"missing={sorted(expected_tests - test_names)} "
            f"extra={sorted(test_names - expected_tests)}"
        )

    # Products group.
    products = re.search(r"/\* Products \*/ = \{.*?children = \((.*?)\);", text, re.S)
    if not products:
        problems.append("Products group not found")
    else:
        product_names = re.findall(r"/\* (.*?) \*/", products.group(1))
        expected = {"MaxCam.app", "MaxCamTests.xctest"}
        if set(product_names) != expected:
            problems.append(f"Products group contents {product_names} != {sorted(expected)}")

    # rootObject.
    root = re.search(r"rootObject = (" + ID + r") /\* (.*?) \*/;", text)
    if not root:
        problems.append("rootObject not found")
    else:
        root_id, root_name = root.groups()
        project_ids = {
            i for i, name in definitions if name == "Project object"
        }
        if root_id not in project_ids:
            problems.append(f"rootObject {root_id} ({root_name}) is not the PBXProject")

    main_group = re.search(r"mainGroup = (" + ID + r")", text)
    if not main_group:
        problems.append("mainGroup not found")
    elif main_group.group(1) not in defined:
        problems.append(f"mainGroup {main_group.group(1)} is not defined")

    if problems:
        print("VALIDATION FAILED")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    print(
        f"VALIDATION OK: {len(defined)} objects, "
        f"{len(build_file_ids)} build files, "
        f"{len(app_names)} app sources, {len(test_names)} test sources"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
