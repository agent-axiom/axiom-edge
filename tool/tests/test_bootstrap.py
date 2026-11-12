"""Template compatibility checks; no Flutter or platform SDK is required."""
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import patch

from tool import bootstrap


TEMPLATES = {
    "android/settings.gradle.kts":
        'id("com.android.application") version "8.11.1" apply false\n',
    "android/app/build.gradle.kts":
        'android { defaultConfig { minSdk = flutter.minSdkVersion } }\n',
    "android/app/src/main/AndroidManifest.xml":
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <application android:label="axiom_edge" />\n</manifest>\n',
    "ios/Podfile": "# platform :ios, '13.0'\n",
    "ios/Runner.xcodeproj/project.pbxproj":
        'IPHONEOS_DEPLOYMENT_TARGET = 13.0;\n',
    "test/widget_test.dart": '// Counter increments smoke test MyApp\n',
    "test/core_test.dart": '// Custom application tests\n',
}


def write_templates(root, platforms):
    for name, contents in TEMPLATES.items():
        if name.split("/")[0] not in (*platforms, "test"):
            continue
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)


def snapshot(root):
    return {
        str(path.relative_to(root)): path.read_bytes()
        for path in root.rglob("*") if path.is_file()
    }


class AndroidGradlePluginTest(unittest.TestCase):
    def test_upgrades_supported_plugin_dsl_templates(self):
        templates = [
            'id("com.android.application") version "8.11.1" apply false\n',
            "id 'com.android.application' version '8.11.1' apply false\n",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            settings = Path(temporary) / "settings.gradle"
            for template in templates:
                with self.subTest(template=template):
                    settings.write_text(template)
                    bootstrap._ensure_android_gradle_plugin(settings)
                    expected = template.replace("8.11.1", "8.12.1")
                    self.assertEqual(settings.read_text(), expected)
                    bootstrap._ensure_android_gradle_plugin(settings)
                    self.assertEqual(settings.read_text(), expected)

    def test_preserves_newer_template_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            settings = Path(temporary) / "settings.gradle.kts"
            template = 'id("com.android.application") version "9.1.0" apply false\n'
            settings.write_text(template)
            bootstrap._ensure_android_gradle_plugin(settings)
            self.assertEqual(settings.read_text(), template)

    def test_unknown_template_fails_with_actionable_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            settings = Path(temporary) / "settings.gradle.kts"
            settings.write_text('alias(libs.plugins.android.application) apply false\n')
            with self.assertRaisesRegex(RuntimeError, "Unknown Android Gradle plugin"):
                bootstrap._ensure_android_gradle_plugin(settings)


class BootstrapTemplateTest(unittest.TestCase):
    swift_package_path = (
        "ios/Flutter/ephemeral/Packages/"
        "FlutterGeneratedPluginSwiftPackage/Package.swift"
    )

    def test_platform_settings_and_repeated_bootstrap(self):
        cases = [
            ("linux", None, ("android",)),
            ("win32", None, ("android",)),
            ("darwin", None, ("android", "ios")),
            ("darwin", "android", ("android",)),
            ("darwin", "ios", ("ios",)),
            ("darwin", "android,ios", ("android", "ios")),
        ]
        for host, requested, expected in cases:
            with self.subTest(host=host, requested=requested), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                write_templates(root, expected)
                with (patch.object(bootstrap, "ROOT", root),
                      patch.object(bootstrap.sys, "platform", host),
                      patch.object(bootstrap.subprocess, "run") as run):
                    bootstrap.main(requested)
                    self.assertEqual(run.call_args.kwargs, {"check": True, "cwd": root})
                    command = run.call_args.args[0]
                    self.assertIn("--no-pub", command)
                    self.assertEqual(command[command.index("--platforms") + 1], ",".join(expected))
                    self.assertFalse((root / "test/widget_test.dart").exists())
                    self.assertEqual((root / "test/core_test.dart").read_text(), TEMPLATES["test/core_test.dart"])
                    if "android" in expected:
                        self.assertIn("minSdk = 28", (root / "android/app/build.gradle.kts").read_text())
                        manifest = (root / "android/app/src/main/AndroidManifest.xml").read_text()
                        self.assertIn('android:label="Axiom Edge"', manifest)
                        self.assertEqual(manifest.count("android.permission.INTERNET"), 1)
                        self.assertEqual(manifest.count("android:networkSecurityConfig="), 1)
                        config = ET.parse(root / "android/app/src/main/res/xml/network_security_config.xml").getroot()
                        self.assertEqual(config.find("base-config").get("cleartextTrafficPermitted"), "false")
                        domain_config = config.find("domain-config")
                        self.assertEqual(domain_config.get("cleartextTrafficPermitted"), "true")
                        domains = domain_config.findall("domain")
                        self.assertEqual({domain.text for domain in domains}, {"localhost", "127.0.0.1"})
                        self.assertTrue(all(domain.get("includeSubdomains") == "false" for domain in domains))
                    else:
                        self.assertFalse((root / "android").exists())
                    if "ios" in expected:
                        self.assertEqual((root / "ios/Podfile").read_text(), "platform :ios, '16.4'\n")
                        self.assertIn("IPHONEOS_DEPLOYMENT_TARGET = 16.4;", (root / "ios/Runner.xcodeproj/project.pbxproj").read_text())
                    else:
                        self.assertFalse((root / "ios").exists())
                    first = snapshot(root)
                    bootstrap.main(requested)
                    self.assertEqual(first, snapshot(root))

    def test_existing_ios_on_linux_fails_before_any_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_templates(root, ("android", "ios"))
            original = snapshot(root)
            with (patch.object(bootstrap, "ROOT", root),
                  patch.object(bootstrap.sys, "platform", "linux"),
                  patch.object(bootstrap.subprocess, "run") as run):
                with self.assertRaisesRegex(RuntimeError, "An ios/ project already exists"):
                    bootstrap.main("android")
                run.assert_not_called()
                self.assertEqual(original, snapshot(root))

    def test_ios_requested_on_non_mac_fails_before_create(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for host in ("linux", "win32"):
                with (self.subTest(host=host), patch.object(bootstrap, "ROOT", root),
                      patch.object(bootstrap.sys, "platform", host),
                      patch.object(bootstrap.subprocess, "run") as run):
                    with self.assertRaisesRegex(RuntimeError, "Use --platforms android"):
                        bootstrap.main("ios")
                    run.assert_not_called()
                    self.assertEqual({}, snapshot(root))

    def test_unselected_existing_platform_is_preserved_on_mac(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_templates(root, ("android", "ios"))
            original_ios = snapshot(root / "ios")
            with (patch.object(bootstrap, "ROOT", root),
                  patch.object(bootstrap.sys, "platform", "darwin"),
                  patch.object(bootstrap.subprocess, "run")):
                bootstrap.main("android")
            self.assertEqual(original_ios, snapshot(root / "ios"))

    def test_configure_only_updates_ios_after_pub_without_running_flutter(self):
        for platform in ('.iOS("13.0")', '.iOS(.v13)'):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                write_templates(root, ("ios",))
                manifest = root / self.swift_package_path
                manifest.parent.mkdir(parents=True)
                manifest.write_text(f'let package = Package(platforms: [{platform}])\n')
                with (patch.object(bootstrap, "ROOT", root),
                      patch.object(bootstrap.sys, "platform", "darwin"),
                      patch.object(bootstrap.subprocess, "run") as run):
                    bootstrap.main("ios", configure_only=True)
                    run.assert_not_called()
                    self.assertIn('.iOS("16.4")', manifest.read_text())
                    self.assertEqual((root / "ios/Podfile").read_text(), "platform :ios, '16.4'\n")
                    self.assertTrue((root / "test/widget_test.dart").exists())
                    first = snapshot(root)
                    bootstrap.main("ios", configure_only=True)
                    self.assertEqual(first, snapshot(root))

    def test_configure_only_preserves_higher_swift_package_platform(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_templates(root, ("ios",))
            manifest = root / self.swift_package_path
            manifest.parent.mkdir(parents=True)
            original = 'let package = Package(platforms: [.iOS("17.0")])\n'
            manifest.write_text(original)
            with (patch.object(bootstrap, "ROOT", root),
                  patch.object(bootstrap.sys, "platform", "darwin")):
                bootstrap.main("ios", configure_only=True)
            self.assertEqual(original, manifest.read_text())

    def test_configure_only_missing_swift_manifest_fails_before_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_templates(root, ("ios",))
            original = snapshot(root)
            with (patch.object(bootstrap, "ROOT", root),
                  patch.object(bootstrap.sys, "platform", "darwin"),
                  patch.object(bootstrap.subprocess, "run") as run):
                with self.assertRaisesRegex(RuntimeError, "Run flutter pub get"):
                    bootstrap.main("ios", configure_only=True)
                run.assert_not_called()
            self.assertEqual(original, snapshot(root))

    def test_configure_only_unknown_swift_platform_fails_before_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_templates(root, ("ios",))
            manifest = root / self.swift_package_path
            manifest.parent.mkdir(parents=True)
            manifest.write_text('let package = Package(platforms: configuredPlatforms)\n')
            original = snapshot(root)
            with (patch.object(bootstrap, "ROOT", root),
                  patch.object(bootstrap.sys, "platform", "darwin")):
                with self.assertRaisesRegex(RuntimeError, "Unknown generated iOS Swift package"):
                    bootstrap.main("ios", configure_only=True)
            self.assertEqual(original, snapshot(root))


if __name__ == "__main__":
    unittest.main()
