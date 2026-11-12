#!/usr/bin/env python3
"""Generate Flutter Android/iOS shells and apply required platform settings.

Idempotent; no SDK binaries or model weights are vendored in the repository.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MINIMUM_AGP = (8, 12, 1)


def _selected_platforms(platforms: str | None) -> tuple[str, ...]:
    if platforms is None:
        return ("android", "ios") if sys.platform == "darwin" else ("android",)
    if platforms not in ("android", "ios", "android,ios"):
        raise ValueError(f"Unsupported platforms: {platforms}")
    return tuple(platforms.split(","))


def _validate_host(platforms: tuple[str, ...]) -> None:
    if sys.platform == "darwin":
        return
    if (ROOT / "ios").exists():
        raise RuntimeError(
            "An ios/ project already exists. Flutter 3.38.6 resolves its SwiftPM "
            "plugins during pub get even for Android, which requires macOS and "
            "Xcode. Preserve that directory in a separate checkout, then run "
            "bootstrap with --platforms android in an Android-only checkout; "
            "or build on macOS. No files have been changed."
        )
    if "ios" in platforms:
        raise RuntimeError(
            "This project's iOS SwiftPM dependencies require macOS and Xcode. "
            "Use --platforms android on Linux/Windows, or run on macOS for iOS."
        )


def _ensure_android_gradle_plugin(path: Path) -> None:
    """Meet the plus plugins' AGP minimum without downgrading newer templates."""
    text = path.read_text()
    pattern = re.compile(
        r'''(id\s*\(?\s*["']com\.android\.application["']\s*\)?\s*version\s*["'])'''
        r'''(\d+\.\d+\.\d+)(["'])'''
    )
    match = pattern.search(text)
    if match is None:
        raise RuntimeError(f"Unknown Android Gradle plugin version layout: {path}")
    version = tuple(int(part) for part in match.group(2).split("."))
    if version < MINIMUM_AGP:
        minimum = ".".join(str(part) for part in MINIMUM_AGP)
        path.write_text(text[:match.start(2)] + minimum + text[match.end(2):])


def _configure_android() -> None:
    # Flutter 3.38.6 generates AGP 8.11.1, but device_info_plus 13 and
    # share_plus 13 require 8.12.1. Its Gradle 8.14 / Kotlin 2.2.20 already
    # meet their requirements, so leave those generated versions unchanged.
    settings_kts = ROOT / "android/settings.gradle.kts"
    settings = settings_kts if settings_kts.exists() else ROOT / "android/settings.gradle"
    _ensure_android_gradle_plugin(settings)

    gradle_kts = ROOT / "android/app/build.gradle.kts"
    gradle_groovy = ROOT / "android/app/build.gradle"
    if gradle_kts.exists():
        text = gradle_kts.read_text()
        updated = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 28", text)
        if updated == text and "minSdk = 28" not in text:
            raise RuntimeError("Unknown Kotlin Android Gradle minSdk layout")
        # Keep all 64-bit targets available to Flutter by default; release builds target arm64.
        gradle_kts.write_text(updated)
    elif gradle_groovy.exists():
        text = gradle_groovy.read_text()
        updated = text.replace("minSdkVersion flutter.minSdkVersion", "minSdkVersion 28")
        if updated == text and "minSdkVersion 28" not in text:
            raise RuntimeError("Unknown Groovy Android Gradle minSdk layout")
        gradle_groovy.write_text(updated)
    else:
        raise FileNotFoundError("Missing Android app Gradle file")

    manifest = ROOT / "android/app/src/main/AndroidManifest.xml"
    contents = manifest.read_text()
    if 'android.permission.INTERNET' not in contents:
        contents = contents.replace('<application',
            '<uses-permission android:name="android.permission.INTERNET" />\n    <application', 1)
    if 'android:networkSecurityConfig=' not in contents:
        contents = contents.replace('<application',
            '<application android:networkSecurityConfig="@xml/network_security_config"', 1)
    contents = contents.replace('android:label="axiom_edge"', 'android:label="Axiom Edge"')
    manifest.write_text(contents)
    config = ROOT / "android/app/src/main/res/xml/network_security_config.xml"
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text('''<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="false" />
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">localhost</domain>
        <domain includeSubdomains="false">127.0.0.1</domain>
    </domain-config>
</network-security-config>
''')


def _configure_ios(*, require_generated_package: bool = False) -> None:
    swift_package = ROOT / (
        "ios/Flutter/ephemeral/Packages/"
        "FlutterGeneratedPluginSwiftPackage/Package.swift"
    )
    if require_generated_package and not swift_package.exists():
        raise RuntimeError(
            "Generated iOS Swift package is missing. Run flutter pub get with "
            "Swift Package Manager enabled on macOS, then --configure-only."
        )
    if swift_package.exists():
        original = swift_package.read_text()
        platform = re.compile(
            r'\.iOS\(\s*(?:"(?P<string>\d+(?:\.\d+){0,2})"|'
            r'\.v(?P<enum>\d+(?:_\d+){0,2}))\s*\)'
        )
        matches = list(platform.finditer(original))
        if len(matches) != 1:
            raise RuntimeError(f"Unknown generated iOS Swift package platform: {swift_package}")
        match = matches[0]
        version_text = match.group("string") or match.group("enum").replace("_", ".")
        version = tuple(int(part) for part in version_text.split("."))
        version += (0,) * (3 - len(version))
        if version < (16, 4, 0):
            # Flutter 3.38.6 writes 13.0 at pub get, then queries Xcode before
            # raising this floor to Runner's target. Align it before those
            # queries. Subsequent Flutter commands must use --no-pub.
            swift_package.write_text(
                original[:match.start()] + '.iOS("16.4")' + original[match.end():]
            )

    podfile = ROOT / "ios/Podfile"
    if podfile.exists():
        original = podfile.read_text()
        changed = re.sub(r"(?m)^#?[ \t]*platform :ios,[ \t]*'[^']+'[ \t]*$", "platform :ios, '16.4'", original)
        if changed == original and "platform :ios, '16.4'" not in original:
            changed = "platform :ios, '16.4'\n" + original
        podfile.write_text(changed)

    pbxproj = ROOT / "ios/Runner.xcodeproj/project.pbxproj"
    if pbxproj.exists():
        original = pbxproj.read_text()
        changed = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;",
                         "IPHONEOS_DEPLOYMENT_TARGET = 16.4;", original)
        pbxproj.write_text(changed)


def main(platforms: str | None = None, *, configure_only: bool = False) -> None:
    selected = _selected_platforms(platforms)
    _validate_host(selected)
    if not configure_only:
        subprocess.run(
            ["flutter", "create", "--org", "dev.kosarevsky", "--project-name", "axiom_edge",
             "--platforms", ",".join(selected), "--no-pub", "."],
            check=True, cwd=ROOT,
        )

        # `flutter create` may insert its stock counter-app widget test into a
        # pre-existing source tree. It refers to a generated MyApp that this
        # project intentionally does not define.
        generated_test = ROOT / "test/widget_test.dart"
        if generated_test.exists():
            contents = generated_test.read_text()
            if "Counter increments smoke test" in contents and "MyApp" in contents:
                generated_test.unlink()

    if "android" in selected:
        _configure_android()
    if "ios" in selected:
        _configure_ios(require_generated_package=configure_only)
    action = "Configured" if configure_only else "Generated"
    print(f"{action} Flutter shells: {', '.join(selected)}.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--platforms", choices=("android", "ios", "android,ios"),
        metavar="PLATFORMS",
        help="Choose android, ios, or android,ios. Defaults to android,ios on "
             "macOS and android on Linux/Windows.",
    )
    parser.add_argument(
        "--configure-only", action="store_true",
        help="Apply settings after pub get without running flutter create. "
             "Use --no-pub for subsequent Flutter commands.",
    )
    args = parser.parse_args()
    try:
        main(args.platforms, configure_only=args.configure_only)
    except RuntimeError as error:
        parser.exit(1, f"Error: {error}\n")
