#!/usr/bin/env python3
"""Build pinned WireGuardKit's real Go bridge for Apple arm64 SDKs.

The simulator library is linkable test infrastructure. iOS Simulator does not
support NEPacketTunnelProvider; this script never claims a working simulator VPN.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform as host_platform
import re
import shutil
import subprocess
import sys

WIREGUARD_REVISION = "2fec12a6e1f6e3460b6ee483aa00ad29cddadab1"
PINNED_FILES = {
    "api-apple.go": "adfdfffd5d2dc5d7d095ca8bd6afd1675b8bf39712c5fa2dc64ef09f2b522600",
    "go.mod": "1912d9654570e293a0539160de47e9d73d3dd44bcd33c65167de6ce541573bb4",
    "go.sum": "f36f983612d6665d96aa405d888f69a719f3d090fcec0dd4786188f6c673f961",
    "goruntime-boottime-over-monotonic.diff": "1aec6a8d3921707db6265b413133b7aad324639f84b3549a7164f4c6879b82da",
}
RUNTIME_FILES = (
    "src/runtime/sys_darwin.go",
    "src/runtime/sys_darwin_arm64.s",
    "src/runtime/sys_darwin_amd64.s",
)
REQUIRED_EXPORTS = (
    "wgSetLogger", "wgTurnOn", "wgTurnOff", "wgSetConfig", "wgGetConfig",
    "wgBumpSockets", "wgDisableSomeRoamingForBrokenMobileSemantics", "wgVersion",
)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(command, **kwargs):
    result = subprocess.run(command, text=True, check=True, **kwargs)
    return result


def output(command, **kwargs):
    return run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs).stdout.strip()


def write_json(path, value):
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, indent=2) + "\n")
    temp.replace(path)


def resolve_go(explicit):
    candidates = [explicit, os.environ.get("WIREGUARD_GO_BINARY"), shutil.which("go"),
                  str(Path.home() / "toolchains/go1.26.5/bin/go")]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate).resolve()
    raise RuntimeError("Go was not found. Pass --go /path/to/go (tested with Go 1.26.5).")


def prepare_runtime(original_go, cache):
    version = output([str(original_go), "version"])
    original_root = Path(output([str(original_go), "env", "GOROOT"]))
    inputs = {name: sha(original_root / name) for name in RUNTIME_FILES}
    key = hashlib.sha256(json.dumps([version, inputs], sort_keys=True).encode()).hexdigest()[:16]
    overlay_root = cache / "_toolchains" / key / "goroot"
    marker = overlay_root.parent / "runtime-overlay.json"
    if marker.is_file():
        saved = json.loads(marker.read_text())
        if (saved.get("inputs") == inputs and saved.get("go_version") == version
                and all((overlay_root / name).is_file() and
                        sha(overlay_root / name) == saved["outputs"].get(name)
                        for name in RUNTIME_FILES)):
            return overlay_root, saved
        raise RuntimeError("An existing runtime overlay has changed; use a fresh output root.")

    overlay_root.parent.mkdir(parents=True, exist_ok=True)
    if overlay_root.exists():
        raise RuntimeError("Incomplete runtime overlay exists; inspect it before rebuilding.")
    # APFS copy-on-write keeps the system/user toolchain untouched and avoids a
    # second physical copy of its unchanged binaries, sources, and standard lib.
    run(["/bin/cp", "-cR", str(original_root), str(overlay_root)])
    for name in RUNTIME_FILES:
        path = overlay_root / name
        source = path.read_text()
        if source.count("libc_mach_absolute_time") != 1:
            raise RuntimeError("Unsupported Go runtime clock implementation: " + name)
        replacement = source.replace("libc_mach_absolute_time", "libc_mach_continuous_time")
        if name.endswith(".go"):
            original = 'mach_absolute_time "/usr/lib/libSystem.B.dylib"'
            if replacement.count(original) != 1:
                raise RuntimeError("Unexpected Darwin dynamic import in " + name)
            replacement = replacement.replace(
                original, 'mach_continuous_time "/usr/lib/libSystem.B.dylib"')
        path.write_text(replacement)
    metadata = {
        "go_version": version, "original_goroot": str(original_root),
        "inputs": inputs, "outputs": {name: sha(overlay_root / name) for name in RUNTIME_FILES},
        "patch_semantics": "Upstream goruntime-boottime-over-monotonic.diff: use mach_continuous_time",
        "shared_toolchain_modified": False,
    }
    write_json(marker, metadata)
    return overlay_root, metadata


def build_one(args, source, destination, goroot, runtime_metadata, platform_name):
    platform_output = destination / platform_name
    platform_output.mkdir(parents=True, exist_ok=True)
    sdk = output(["xcrun", "--sdk", platform_name, "--show-sdk-path"])
    sdk_version = output(["xcrun", "--sdk", platform_name, "--show-sdk-version"])
    clang = output(["xcrun", "--sdk", platform_name, "--find", "clang"])
    simulator = platform_name == "iphonesimulator"
    target = "arm64-apple-ios" + args.minimum_ios + ("-simulator" if simulator else "")
    flags = ["-target", target, "-isysroot", sdk]
    build_env = os.environ.copy()
    build_env.update({
        "GOROOT": str(goroot), "PATH": str(goroot / "bin") + os.pathsep + build_env.get("PATH", ""),
        "GOOS": "ios", "GOARCH": "arm64", "CGO_ENABLED": "1", "GOTOOLCHAIN": "local",
        "CC": clang, "CGO_CFLAGS": " ".join(flags), "CGO_LDFLAGS": " ".join(flags),
        "GOCACHE": str(destination / "_gocache" / platform_name),
        "GOMODCACHE": str(destination / "_gomodcache"),
    })
    archive = platform_output / "libwg-go.a"
    receipt = platform_output / "build-receipt.json"
    source_hashes = {name: sha(source / name) for name in PINNED_FILES}
    identity = {
        "wireguard_apple_revision": WIREGUARD_REVISION, "source_hashes": source_hashes,
        "runtime": runtime_metadata, "sdk": sdk, "sdk_version": sdk_version,
        "target": target, "platform": platform_name, "minimum_ios": args.minimum_ios,
        "script_sha256": sha(__file__),
    }
    if receipt.is_file():
        old = json.loads(receipt.read_text())
        smoke = platform_output / "link-smoke"
        if (old.get("identity") == identity and archive.is_file() and smoke.is_file()
                and old.get("archive_sha256") == sha(archive)
                and old.get("link_smoke_sha256") == sha(smoke)):
            print(json.dumps({"status": "reused", "receipt": str(receipt), "archive": str(archive)}),
                  flush=True)
            return

    command = [str(goroot / "bin/go"), "build", "-mod=readonly", "-trimpath",
               "-ldflags=-w", "-p", str(args.jobs), "-buildmode=c-archive", "-o", str(archive), "."]
    log = platform_output / "build.log"
    print("Building " + platform_name + " bridge; log: " + str(log), flush=True)
    with log.open("w") as stream:
        try:
            run(command, cwd=source, env=build_env, stdout=stream, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError:
            print(log.read_text()[-6000:], file=sys.stderr)
            raise
    header = platform_output / "libwg-go.h"
    symbols = output(["xcrun", "nm", "-gU", str(archive)])
    missing = [name for name in REQUIRED_EXPORTS if not re.search(r"\b_" + name + r"$", symbols, re.M)]
    if missing:
        raise RuntimeError("Missing Go bridge exports: " + ", ".join(missing))
    architecture = output(["xcrun", "lipo", "-archs", str(archive)])
    if architecture != "arm64":
        raise RuntimeError("Unexpected archive architectures: " + architecture)
    smoke_source = platform_output / "link-smoke.c"
    smoke_source.write_text('#include "wireguard.h"\nint main(void) { return wgVersion() ? 0 : 1; }\n')
    smoke = platform_output / "link-smoke"
    link_command = [clang] + flags + [str(smoke_source), "-I", str(source), str(archive),
                    "-lresolv", "-framework", "Foundation", "-framework", "Security",
                    "-o", str(smoke)]
    linked = run(link_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (platform_output / "link.log").write_text(linked.stdout + linked.stderr)
    load_commands = output(["xcrun", "vtool", "-show-build", str(smoke)])
    required_platform = "IOSSIMULATOR" if simulator else "IOS"
    if not re.search(r"\bplatform\s+" + required_platform + r"\s", load_commands):
        raise RuntimeError("Linked binary has wrong Mach-O platform: " + load_commands)
    (platform_output / "link-platform.txt").write_text(load_commands + "\n")
    # Header is retained for audit. WireGuardKit imports its pinned wireguard.h.
    write_json(receipt, {
        "status": "passed", "created_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "identity": identity, "command": command, "link_command": link_command,
        "environment": {key: build_env[key] for key in
                        ("GOOS", "GOARCH", "CGO_ENABLED", "GOTOOLCHAIN", "CC", "CGO_CFLAGS",
                         "CGO_LDFLAGS", "GOCACHE", "GOMODCACHE", "GOROOT")},
        "archive": str(archive), "archive_bytes": archive.stat().st_size,
        "archive_sha256": sha(archive), "header_sha256": sha(header),
        "link_smoke_sha256": sha(smoke), "architecture": architecture,
        "verified_exports": list(REQUIRED_EXPORTS), "link_platform": load_commands,
        "runtime_validation": "Compilation and link verification only; no tunnel or traffic was started.",
        "simulator_limitation": "NEPacketTunnelProvider cannot run in iOS Simulator.",
    })
    print(json.dumps({"status": "passed", "receipt": str(receipt), "archive": str(archive)}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-root", type=Path,
                        default=Path(os.environ.get("WIREGUARD_BRIDGE_OUTPUT_ROOT",
                                                   str(Path.home() / "caches/DerivedData/pureline-wireguard-20261127/WireGuard"))))
    parser.add_argument("--platform", choices=("iphoneos", "iphonesimulator", "both"), default="both")
    parser.add_argument("--go", help="Path to Go executable; Go 1.26.5 is verified.")
    parser.add_argument("--minimum-ios", default=os.environ.get("IPHONEOS_DEPLOYMENT_TARGET", "17.0"))
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if host_platform.system() != "Darwin":
        parser.error("Run this Apple SDK bridge build on the configured Mac runner.")
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", args.minimum_ios) or args.jobs < 1:
        parser.error("Invalid deployment target or job count.")
    source = args.source_root.resolve() / "Vendor/WireGuard/Sources/WireGuardKitGo"
    for name, expected in PINNED_FILES.items():
        if not (source / name).is_file() or sha(source / name) != expected:
            parser.error("WireGuard source differs from verified revision: " + name)
    if sorted(path.name for path in source.glob("*.go")) != ["api-apple.go"]:
        parser.error("Unexpected WireGuard Go sources; inspect the upstream update before building.")
    destination = args.output_root.expanduser().resolve()
    destination.mkdir(parents=True, exist_ok=True)
    with (destination / ".build.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        goroot, runtime_metadata = prepare_runtime(resolve_go(args.go), destination)
        platforms = ("iphoneos", "iphonesimulator") if args.platform == "both" else (args.platform,)
        for platform_name in platforms:
            build_one(args, source, destination, goroot, runtime_metadata, platform_name)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print("WireGuard bridge build failed: " + str(error), file=sys.stderr)
        sys.exit(1)
