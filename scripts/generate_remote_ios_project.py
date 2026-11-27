#!/usr/bin/env python3
"""Derive the full Pureline Remote XcodeGen project without local ML assets.

The checked-in base project remains the local + remote product. JSON output is
valid YAML and can be consumed directly by XcodeGen. PyYAML is preferred; macOS's
system Ruby/Psych provides a dependency-free fallback.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import subprocess
import sys


def read_yaml(path: Path) -> dict:
    try:
        import yaml
    except ImportError:
        try:
            result = subprocess.run(
                ["/usr/bin/ruby", "-ryaml", "-rjson", "-e",
                 "print JSON.generate(YAML.safe_load(File.read(ARGV.fetch(0))))", str(path)],
                check=True, capture_output=True, text=True,
            )
            return json.loads(result.stdout)
        except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
            raise SystemExit("Reading the base spec requires PyYAML or macOS system Ruby/Psych.") from error
    return yaml.safe_load(path.read_text())


def source_path(source: dict | str) -> str:
    return source if isinstance(source, str) else source["path"]


def derive(base: dict) -> dict:
    spec = copy.deepcopy(base)
    required = {"HTTrailiOS", "PacketTunnel", "ImageFilterCore", "EmbeddedImageFilter"}
    if not required.issubset(spec.get("targets", {})):
        raise SystemExit("Unexpected base project targets; review the Remote variant before regenerating.")
    if "WireGuardGoBridge" not in spec.get("aggregateTargets", {}):
        raise SystemExit("The base project must include the WireGuard Go bridge aggregate target.")
    if not {"HTTrail", "WireGuardKit"}.issubset(spec.get("packages", {})):
        raise SystemExit("The full application and WireGuard packages must be present.")

    spec["name"] = "PurelineRemote"
    for phase in spec["aggregateTargets"]["WireGuardGoBridge"].get("buildScripts", []):
        if "build_wireguard_bridge.py" in phase.get("script", ""):
            phase["script"] = phase["script"].rstrip() + " --jobs 2\n"
    spec["packages"] = {name: value for name, value in spec["packages"].items()
                        if name in {"HTTrail", "WireGuardKit"}}
    spec["targets"] = {name: value for name, value in spec["targets"].items()
                       if name in {"HTTrailiOS", "PacketTunnel", "ImageFilterCore"}}

    # Keep the configuration schema for legacy diagnostic export, with no
    # CoreML/Vision service, generated model, classifier UI, or model resource.
    schema = spec["targets"]["ImageFilterCore"]
    schema["sources"] = [{"path": "ImageFilterIntegration/Core/PurelineFilterConfiguration.swift"}]
    schema.pop("dependencies", None)

    app = spec["targets"]["HTTrailiOS"]
    sources = []
    for original in app["sources"]:
        path = source_path(original)
        if path.startswith("../Vendor/AI-Image-Classifier/"):
            continue
        item = {"path": original} if isinstance(original, str) else copy.deepcopy(original)
        if path == "Sources":
            item.setdefault("excludes", []).append("ImageFilterTabHostView.swift")
        if path == "PurelineIntegration":
            item.setdefault("excludes", []).extend([
                "ImageFiltering",
                "Configuration/PurelineFilterConfigurationViewModel.swift",
                "Configuration/PurelineConfigurationDocument.swift",
            ])
        sources.append(item)
    sources.append({"path": "RemoteIntegration/App/ImageFilterTabHostView.swift"})
    app["sources"] = sources
    app["dependencies"] = [item for item in app["dependencies"]
                           if item.get("target") != "EmbeddedImageFilter"]
    for item in app["dependencies"]:
        if item.get("target") == "ImageFilterCore":
            item["link"] = True
            item["embed"] = True
    app["settings"]["base"]["PRODUCT_NAME"] = "PurelineRemote"
    # Existing translations use the upstream app name. Change only the copied
    # bundle's display-name key, retaining every upstream localization file.
    app.setdefault("postBuildScripts", []).append({
        "name": "Use Pureline Remote localized display name",
        "script": """set -eu
resource_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
for strings in "$resource_dir"/*.lproj/InfoPlist.strings; do
    [ -f "$strings" ] || continue
    /usr/bin/plutil -replace CFBundleDisplayName -string "Pureline Remote" "$strings"
    /usr/bin/plutil -replace CFBundleName -string "Pureline Remote" "$strings"
done
""",
        "basedOnDependencyAnalysis": False,
    })
    app["info"]["path"] = "RemoteIntegration/App/Info.plist"
    properties = app["info"]["properties"]
    properties["CFBundleDisplayName"] = "Pureline Remote"
    properties["PurelineBuildMode"] = "remote-wireguard"
    properties["NSLocalNetworkUsageDescription"] = (
        "Pureline connects to the servers you select for API requests and remote filtering."
    )
    for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                "NSPhotoLibraryUsageDescription", "NSSpeechRecognitionUsageDescription",
                "NSBonjourServices"]:
        properties.pop(key, None)
    app["entitlements"]["path"] = "RemoteIntegration/App/PurelineRemote.entitlements"

    # A genuine, small NetworkExtension entry point delegates only to the same
    # WireGuard transport used by the full product. It cannot start local capture.
    tunnel = spec["targets"]["PacketTunnel"]
    tunnel["sources"] = [
        {"path": "RemoteIntegration/Extension/PacketTunnelProvider.swift"},
        {"path": "WireGuardIntegration/Shared"},
        {"path": "WireGuardIntegration/Extension"},
    ]
    tunnel["dependencies"] = [item for item in tunnel["dependencies"]
                              if item.get("package") == "WireGuardKit"
                              or item.get("target") == "WireGuardGoBridge"]
    tunnel["info"]["path"] = "RemoteIntegration/Extension/Info.plist"
    tunnel["info"]["properties"]["CFBundleDisplayName"] = "Pureline Remote Tunnel"
    tunnel["entitlements"]["path"] = "RemoteIntegration/Extension/PacketTunnel.entitlements"

    # The same UI evidence suite can target the complete app, independently
    # from the focused validation host. No validation-host unit test is imported.
    spec["targets"]["PurelineRemoteWireGuardUITests"] = {
        "type": "bundle.ui-testing",
        "platform": "iOS",
        "sources": [{"path": "WireGuardUITests"}],
        "dependencies": [{"target": "HTTrailiOS"}],
        "settings": {"base": {
            "PRODUCT_BUNDLE_IDENTIFIER": "com.davidpovarsky.pureline.RemoteWireGuardUITests",
            "GENERATE_INFOPLIST_FILE": True,
            "SWIFT_VERSION": "5.0",
            "IPHONEOS_DEPLOYMENT_TARGET": app["settings"]["base"]["IPHONEOS_DEPLOYMENT_TARGET"],
            "TEST_TARGET_NAME": "HTTrailiOS",
        }},
    }

    for target in spec["targets"].values():
        settings = target.setdefault("settings", {}).setdefault("base", {})
        existing = settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "$(inherited)")
        if isinstance(existing, list):
            existing = " ".join(existing)
        settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = existing + " PURELINE_REMOTE_BUILD"

    spec["schemes"] = {
        "PurelineRemote": {
            "build": {"targets": {"HTTrailiOS": "all"}},
            "run": {"config": "Debug"},
            "archive": {"config": "Release"},
        },
        "PurelineRemoteWireGuardUI": {
            "build": {"targets": {
                "HTTrailiOS": "all",
                "PurelineRemoteWireGuardUITests": ["test"],
            }},
            "test": {
                "config": "Debug",
                "targets": [{"name": "PurelineRemoteWireGuardUITests", "parallelizable": False}],
            },
        },
    }
    return spec


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, help="Default: iosapp/project.remote.yml")
    parser.add_argument("--check", action="store_true", help="Fail if the committed derived spec is stale.")
    args = parser.parse_args()
    root = args.source_root.resolve()
    output = args.output or root / "iosapp/project.remote.yml"
    document = json.dumps(derive(read_yaml(root / "iosapp/project.yml")), indent=2) + "\n"
    if args.check:
        if not output.exists() or output.read_text() != document:
            raise SystemExit("Remote spec is stale; run scripts/generate_remote_ios_project.py.")
        print("Remote project matches the current base specification.")
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(document)
        print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
