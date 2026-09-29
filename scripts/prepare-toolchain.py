#!/usr/bin/env python3
"""Work around stale CLT files in the build directory; never edit the SDK."""
import json
import pathlib
import shlex
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
build = root / ".build"
build.mkdir(exist_ok=True)
swift = pathlib.Path(subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip())
usr = swift.parent.parent
manifest = usr / "lib/swift/pm/ManifestAPI"
custom = ""
overlay = ""
private = manifest / "PackageDescription.swiftmodule/arm64-apple-macos.private.swiftinterface"
public = manifest / "PackageDescription.swiftmodule/arm64-apple-macos.swiftinterface"
if private.exists() and public.exists() and "public enum SwiftVersion" in private.read_text() and "public typealias SwiftVersion =" in public.read_text():
    destination = build / "swiftpm-libs/ManifestAPI"
    if not destination.exists():
        shutil.copytree(manifest, destination)
    for path in destination.rglob("*.private.swiftinterface"):
        path.unlink()
    custom = str(destination.parent)

headers = usr / "include/swift"
modulemap = headers / "module.modulemap"
bridging = headers / "bridging.modulemap"
if modulemap.exists() and bridging.exists() and "module SwiftBridging" in modulemap.read_text() and "module SwiftBridging" in bridging.read_text():
    empty = build / "empty.modulemap"
    empty.write_text("// Project-local overlay for a duplicate installed module map.\n")
    target = build / "swift-headers-overlay.json"
    target.write_text(json.dumps({"version": 0, "roots": [{"type": "file", "name": str(modulemap), "external-contents": str(empty)}]}))
    overlay = str(target)

(build / "toolchain.env").write_text("FIELDWORK_SWIFT_LIBS=" + shlex.quote(custom) + "\nFIELDWORK_SWIFT_OVERLAY=" + shlex.quote(overlay) + "\n")
