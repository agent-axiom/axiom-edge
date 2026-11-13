from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


MODULE_PATH = Path(__file__).resolve().parents[1] / "release.py"
SPEC = importlib.util.spec_from_file_location("axiom_release_under_test", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
release = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release
SPEC.loader.exec_module(release)

REPOSITORY = "agent-axiom/axiom-edge"
COMMIT = "a" * 40
OTHER_COMMIT = "b" * 40
PAYLOADS = ("axiom-edge-android-arm64.apk", "axiom-edge-ios-unsigned.zip")
PUBLISHED = (*PAYLOADS, "release.json", "SHA256SUMS")


def metadata(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    return {
        "name": path.name,
        "state": "uploaded",
        "size": len(data),
        "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
    }


class FakeGitHub:
    """Stateful release service; publishing is observed separately from upload."""

    def __init__(
        self,
        directory: Path,
        *,
        tag_commit: str | None = None,
        existing: bool = False,
        draft: bool = True,
        upload_fails: bool = False,
        damaged_asset: str | None = None,
        damage: str = "digest",
        move_after_upload: bool = False,
        main_commit: str = COMMIT,
        advance_main_after_upload: bool = False,
        annotated_tag: bool = False,
        digest_available_after: int | None = None,
        hide_draft: bool = False,
        native_missing_reads: int = 0,
        native_always_missing: bool = False,
    ) -> None:
        self.directory = directory
        self.manifest = json.loads((directory / "release.json").read_text())
        self.tag = self.manifest["tag"]
        self.tag_commit = tag_commit
        self.exists = existing
        self.draft = draft
        self.upload_fails = upload_fails
        self.damaged_asset = damaged_asset
        self.damage = damage
        self.move_after_upload = move_after_upload
        self.main_commit = main_commit
        self.advance_main_after_upload = advance_main_after_upload
        self.annotated_tag = annotated_tag
        self.digest_available_after = digest_available_after
        self.hide_draft = hide_draft
        self.native_missing_reads = native_missing_reads
        self.native_always_missing = native_always_missing
        self.native_reads = 0
        self.asset_reads = 0
        self.calls: list[tuple[object, ...]] = []
        self.uploaded = False
        self.assets = [metadata(directory / name) for name in PUBLISHED] if existing else []

    def request(
        self,
        endpoint: str,
        method: str = "GET",
        fields: dict[str, object] | None = None,
        allow_missing: bool = False,
    ) -> object:
        self.calls.append(("request", method, endpoint, fields))
        endpoint = endpoint.lstrip("/").split("?", 1)[0]
        prefix = f"repos/{REPOSITORY}/"
        if endpoint == prefix + "git/ref/heads/main":
            return {"object": {"sha": self.main_commit}}
        if endpoint.startswith(prefix + "git/ref/tags/"):
            if self.tag_commit is None:
                self.assert_missing_allowed(allow_missing)
                return None
            return {
                "object": {
                    "type": "tag" if self.annotated_tag else "commit",
                    "sha": "c" * 40 if self.annotated_tag else self.tag_commit,
                }
            }
        if endpoint == prefix + "git/tags/" + "c" * 40:
            assert self.annotated_tag
            return {"object": {"type": "commit", "sha": self.tag_commit}}
        if endpoint == prefix + "git/refs" and method == "POST":
            assert fields is not None
            assert fields["ref"] == f"refs/tags/{self.tag}"
            self.tag_commit = str(fields["sha"])
            return {"object": {"sha": self.tag_commit}}
        if endpoint == prefix + "releases":
            if not self.exists or (self.hide_draft and self.draft):
                return []
            return [self.release_record()]
        if endpoint == prefix + "releases/42":
            assert self.exists
            return self.release_record()
        if endpoint == prefix + "releases/42/assets":
            self.asset_reads += 1
            if self.digest_available_after is not None and self.asset_reads >= self.digest_available_after:
                for asset in self.assets:
                    asset["digest"] = metadata(self.directory / str(asset["name"]))["digest"]
            return self.assets
        raise AssertionError(f"Unexpected GitHub API call: {method} {endpoint}")

    def release_record(self) -> dict[str, object]:
        return {
            "id": 42,
            "draft": self.draft,
            "tag_name": self.tag,
            "html_url": self.url,
            "assets": self.assets,
        }

    def release_view(self, repository: str, tag: str) -> object:
        self.calls.append(("release_view", repository, tag))
        assert repository == REPOSITORY and tag == self.tag
        if not self.exists:
            return None
        self.native_reads += 1
        if self.native_always_missing or self.native_reads <= self.native_missing_reads:
            return None
        return {"databaseId": 42, "isDraft": self.draft, "tagName": self.tag}

    @staticmethod
    def assert_missing_allowed(allowed: bool) -> None:
        if not allowed:
            raise AssertionError("Missing-object lookup must allow a 404")

    @property
    def url(self) -> str:
        return f"https://github.com/{REPOSITORY}/releases/tag/{self.tag}"

    def command(self, *args: str) -> str:
        self.calls.append(("command", *args))
        operation = args[:2]
        if operation == ("release", "create"):
            assert "--draft" in args
            assert "--verify-tag" in args
            assert not self.exists
            notes = Path(args[args.index("--notes-file") + 1])
            assert notes == self.directory / "release-notes.md"
            assert notes.is_file()
            self.exists = True
            self.draft = True
            return self.url
        if operation == ("release", "upload"):
            assert self.exists and self.draft
            file_args = [Path(str(arg)) for arg in args[3:] if Path(str(arg)).name in PUBLISHED]
            assert len(file_args) == len(PUBLISHED)
            assert {path.name for path in file_args} == set(PUBLISHED)
            assert all(path == self.directory / path.name for path in file_args)
            if self.upload_fails:
                raise release.ReleaseError("Simulated upload failure")
            self.uploaded = True
            self.assets = [metadata(path) for path in file_args]
            if self.damaged_asset is not None:
                asset = next(item for item in self.assets if item["name"] == self.damaged_asset)
                if self.damage == "missing":
                    self.assets.remove(asset)
                elif self.damage == "size":
                    asset["size"] = int(asset["size"]) + 1
                elif self.damage == "missing_digest":
                    asset["digest"] = None
                else:
                    asset["digest"] = "sha256:" + "0" * 64
            if self.move_after_upload:
                self.tag_commit = OTHER_COMMIT
            if self.advance_main_after_upload:
                self.main_commit = OTHER_COMMIT
            return ""
        if operation == ("release", "edit"):
            assert self.exists and self.draft and self.uploaded
            assert "--draft=false" in args
            assert "--latest" in args
            assert args[args.index("--title") + 1] == self.manifest["title"]
            assert Path(args[args.index("--notes-file") + 1]) == self.directory / "release-notes.md"
            self.draft = False
            return ""
        raise AssertionError(f"Unexpected gh command: {args}")

    def commands(self) -> list[tuple[object, ...]]:
        return [call for call in self.calls if call[0] == "command"]


class ReleaseTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        # macOS temporary paths can pass through /var -> /private/var.
        self.root = Path(self.temporary.name).resolve()
        self.directory = self.root / "dist"
        self.directory.mkdir()
        self.pubspec = self.root / "pubspec.yaml"
        self.pubspec.write_text("name: fixture\nversion: 0.1.2+3\n")
        for index, name in enumerate(PAYLOADS):
            (self.directory / name).write_bytes(b"PK test fixture " + bytes([index]))
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def prepare(self, **overrides: object) -> dict[str, object]:
        values: dict[str, object] = {
            "directory": self.directory,
            "repository": REPOSITORY,
            "commit": COMMIT,
            "run_id": "1234",
            "run_number": "8",
            "ref": "refs/heads/main",
            "pubspec": self.pubspec,
        }
        values.update(overrides)
        return release.prepare(**values)


class GitHubCLIErrorTest(unittest.TestCase):
    def test_transport_error_reports_status_without_echoing_sensitive_stderr(self) -> None:
        result = release.subprocess.CompletedProcess(
            args=["gh", "api", "repos/example/repository/releases"],
            returncode=1,
            stdout="",
            stderr="gh: secret-placeholder (HTTP 403)",
        )
        with patch.object(release.subprocess, "run", return_value=result):
            with self.assertRaises(release.ReleaseError) as raised:
                release.GitHubCLI()._run(["api", "repos/example/repository/releases"])
        message = str(raised.exception)
        self.assertRegex(message, r"HTTP\s*403")
        self.assertIn("1", message)
        self.assertNotIn("secret-placeholder", message)
        self.assertNotIn(result.stderr, message)

    def test_native_release_lookup_accepts_only_exact_not_found_as_absence(self) -> None:
        result = release.subprocess.CompletedProcess(
            args=["gh", "release", "view", "v0.1.2"],
            returncode=1,
            stdout="",
            stderr="release not found\n",
        )
        with patch.object(release.subprocess, "run", return_value=result):
            self.assertIsNone(release.GitHubCLI().release_view(REPOSITORY, "v0.1.2"))
        for stderr in (
            "gh: secret-placeholder (HTTP 403)",
            "gh: access denied; release not found",
        ):
            result.stderr = stderr
            with self.subTest(stderr=stderr), patch.object(release.subprocess, "run", return_value=result):
                with self.assertRaises(release.ReleaseError) as raised:
                    release.GitHubCLI().release_view(REPOSITORY, "v0.1.2")
            self.assertNotIn("secret-placeholder", str(raised.exception))

    def test_native_release_lookup_preserves_structured_metadata(self) -> None:
        payload = {"databaseId": 42, "isDraft": True, "tagName": "v0.1.2"}
        result = release.subprocess.CompletedProcess(
            args=["gh", "release", "view", "v0.1.2"],
            returncode=0,
            stdout=json.dumps(payload),
            stderr="",
        )
        with patch.object(release.subprocess, "run", return_value=result):
            self.assertEqual(release.GitHubCLI().release_view(REPOSITORY, "v0.1.2"), payload)


class PrepareReleaseTest(ReleaseTestCase):
    def test_manifest_and_checksums_describe_exact_build_inputs(self) -> None:
        manifest = self.prepare()
        self.assertEqual(manifest["repository"], REPOSITORY)
        self.assertEqual(manifest["commit"], COMMIT)
        self.assertEqual(manifest["version"], "0.1.2+3")
        self.assertEqual(manifest["base_version"], "0.1.2")
        self.assertEqual(manifest["tag"], "v0.1.2-build.8")
        self.assertEqual(manifest["run_url"], f"https://github.com/{REPOSITORY}/actions/runs/1234")
        assets = {item["name"]: item for item in manifest["assets"]}
        self.assertEqual(set(assets), set(PAYLOADS))
        for name, item in assets.items():
            data = (self.directory / name).read_bytes()
            self.assertEqual(item["size"], len(data))
            self.assertEqual(item["sha256"], hashlib.sha256(data).hexdigest())
        sums = {
            name: digest
            for digest, name in (
                line.split("  ", 1)
                for line in (self.directory / "SHA256SUMS").read_text().splitlines()
            )
        }
        self.assertEqual(set(sums), {*PAYLOADS, "release.json"})
        for name, digest in sums.items():
            self.assertEqual(digest, hashlib.sha256((self.directory / name).read_bytes()).hexdigest())

    def test_release_notes_have_direct_download_and_honest_ios_status(self) -> None:
        manifest = self.prepare()
        notes = (self.directory / "release-notes.md").read_text()
        direct = f"https://github.com/{REPOSITORY}/releases/download/{manifest['tag']}/{PAYLOADS[0]}"
        self.assertIn(direct, notes)
        self.assertIn(direct, notes.splitlines()[0])
        self.assertIn("**", notes.splitlines()[0])
        self.assertIn("без подписи", notes.lower())
        self.assertIn("Apple", notes)
        self.assertIn(PAYLOADS[1], notes)
        self.assertNotRegex(notes.lower(), r"\]\([^\)\n]+\.ipa\)")

    def test_explicit_matching_version_tag_is_used_without_build_suffix(self) -> None:
        self.assertEqual(self.prepare(ref="refs/tags/v0.1.2")["tag"], "v0.1.2")

    def test_unsupported_publish_contexts_and_malformed_identifiers_are_rejected(self) -> None:
        cases = [
            {"repository": "owner/../repo"},
            {"repository": "owner/repo;echo injected"},
            {"commit": "a" * 39},
            {"run_id": "0"},
            {"run_number": "8\nlatest=true"},
            {"ref": "refs/pull/1/merge"},
            {"ref": "refs/heads/feature"},
            {"ref": "refs/tags/v9.9.9"},
        ]
        for values in cases:
            with self.subTest(values=values), self.assertRaises(release.ReleaseError):
                self.prepare(**values)
        self.assertFalse((self.directory / "release.json").exists())

    def test_missing_empty_or_symlinked_payload_cannot_be_prepared(self) -> None:
        target = self.directory / PAYLOADS[0]
        target.unlink()
        with self.assertRaises(release.ReleaseError):
            self.prepare()
        target.touch()
        with self.assertRaises(release.ReleaseError):
            self.prepare()
        target.unlink()
        outside = self.root / "outside.apk"
        outside.write_bytes(b"outside payload")
        target.symlink_to(outside)
        with self.assertRaises(release.ReleaseError):
            self.prepare()
        self.assertFalse((self.directory / "release.json").exists())

    def test_preparing_same_inputs_is_deterministic(self) -> None:
        first = self.prepare()
        files = {name: (self.directory / name).read_bytes() for name in ("release.json", "release-notes.md", "SHA256SUMS")}
        self.assertEqual(first, self.prepare())
        for name, contents in files.items():
            self.assertEqual((self.directory / name).read_bytes(), contents)

    def test_invalid_or_ambiguous_pubspec_version_is_rejected(self) -> None:
        for version in ("version: 0.1\n", "version: ../unsafe\n", "version: 0.1.2\nversion: 0.1.3\n"):
            self.pubspec.write_text(version)
            with self.subTest(version=version), self.assertRaises(release.ReleaseError):
                self.prepare()


class PublishReleaseTest(ReleaseTestCase):
    def test_parent_symlink_is_normalized_before_publishing(self) -> None:
        alias = self.root / "parent-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.prepare(directory=alias / "dist")
        cli = FakeGitHub(self.directory)
        self.assertEqual(release.publish(alias / "dist", cli), cli.url)

    def test_new_release_is_draft_until_all_asset_hashes_are_verified(self) -> None:
        self.prepare()
        cli = FakeGitHub(self.directory)
        self.assertEqual(release.publish(self.directory, cli), cli.url)
        commands = cli.commands()
        self.assertEqual([call[2] for call in commands], ["create", "upload", "edit"])
        self.assertFalse(cli.draft)
        tag_creates = [call for call in cli.calls if call[:2] == ("request", "POST")]
        self.assertEqual(tag_creates[0][3]["sha"], COMMIT)

    def test_upload_failure_leaves_release_draft(self) -> None:
        self.prepare()
        cli = FakeGitHub(self.directory, upload_fails=True)
        with self.assertRaises(release.ReleaseError):
            release.publish(self.directory, cli)
        self.assertTrue(cli.draft)
        self.assertFalse(any(call[1:3] == ("release", "edit") for call in cli.commands()))

    def test_corrupt_or_missing_remote_asset_cannot_be_published(self) -> None:
        self.prepare()
        with patch.object(release.time, "sleep"):
            for damage in ("digest", "size", "missing", "missing_digest"):
                cli = FakeGitHub(self.directory, damaged_asset=PAYLOADS[0], damage=damage)
                with self.subTest(damage=damage), self.assertRaises(release.ReleaseError):
                    release.publish(self.directory, cli)
                self.assertTrue(cli.draft)
                self.assertFalse(any(call[1:3] == ("release", "edit") for call in cli.commands()))

    def test_delayed_remote_digest_is_retried_before_publishing(self) -> None:
        self.prepare()
        cli = FakeGitHub(
            self.directory,
            damaged_asset=PAYLOADS[0],
            damage="missing_digest",
            digest_available_after=2,
        )
        with patch.object(release.time, "sleep") as sleep:
            self.assertEqual(release.publish(self.directory, cli), cli.url)
        self.assertEqual(cli.asset_reads, 2)
        sleep.assert_called_once_with(2)
        self.assertFalse(cli.draft)

    def test_annotated_tag_is_peeled_to_the_exact_source_commit(self) -> None:
        self.prepare(ref="refs/tags/v0.1.2")
        cli = FakeGitHub(self.directory, tag_commit=COMMIT, annotated_tag=True)
        self.assertEqual(release.publish(self.directory, cli), cli.url)
        peeled = [call for call in cli.calls if call[0] == "request" and "/git/tags/" in str(call[2])]
        self.assertGreaterEqual(len(peeled), 2)

    def test_existing_draft_is_resumed_without_creating_or_publishing_early(self) -> None:
        self.prepare()
        cli = FakeGitHub(self.directory, tag_commit=COMMIT, existing=True, draft=True)
        self.assertEqual(release.publish(self.directory, cli), cli.url)
        self.assertEqual([call[2] for call in cli.commands()], ["upload", "edit"])

    def test_native_lookup_resumes_draft_hidden_from_rest_listing(self) -> None:
        self.prepare()
        cli = FakeGitHub(self.directory, tag_commit=COMMIT, existing=True, draft=True, hide_draft=True)
        self.assertEqual(release.publish(self.directory, cli), cli.url)
        self.assertEqual([call[2] for call in cli.commands()], ["upload", "edit"])
        self.assertEqual(cli.native_reads, 1)
        self.assertTrue(any(call[0] == "release_view" for call in cli.calls))
        self.assertTrue(any(call[0] == "request" and str(call[2]).endswith("/releases/42") for call in cli.calls))

    def test_post_create_lookup_retries_without_creating_another_draft(self) -> None:
        self.prepare()
        cli = FakeGitHub(self.directory, hide_draft=True, native_missing_reads=2)
        with patch.object(release.time, "sleep") as sleep:
            self.assertEqual(release.publish(self.directory, cli), cli.url)
        self.assertEqual(cli.native_reads, 3)
        self.assertEqual([call[2] for call in cli.commands()], ["create", "upload", "edit"])
        self.assertEqual(sleep.call_args_list, [((2,),), ((2,),)])

    def test_permanently_missing_new_draft_has_bounded_lookup_and_no_second_create(self) -> None:
        self.prepare()
        cli = FakeGitHub(self.directory, hide_draft=True, native_always_missing=True)
        with patch.object(release.time, "sleep") as sleep, self.assertRaises(release.ReleaseError):
            release.publish(self.directory, cli)
        self.assertEqual(cli.native_reads, 3)
        self.assertEqual([call[2] for call in cli.commands()], ["create"])
        self.assertEqual(sleep.call_count, 2)

    def test_malformed_or_ambiguous_native_metadata_is_not_followed(self) -> None:
        manifest = self.prepare()
        valid = {"databaseId": 42, "isDraft": True, "tagName": manifest["tag"]}
        malformed = [
            [{**valid}, {**valid}],
            {**valid, "databaseId": True},
            {**valid, "databaseId": 0},
            {**valid, "isDraft": "true"},
            {**valid, "tagName": "other-tag"},
        ]
        for value in malformed:
            cli = FakeGitHub(self.directory, tag_commit=COMMIT, existing=True, draft=True, hide_draft=True)
            with self.subTest(value=value), patch.object(cli, "release_view", return_value=value):
                with self.assertRaises(release.ReleaseError):
                    release.publish(self.directory, cli)
            self.assertEqual(cli.commands(), [])
            self.assertFalse(any(call[1] == "POST" for call in cli.calls if call[0] == "request"))

    def test_native_lookup_id_must_agree_with_rest_tag_and_draft(self) -> None:
        self.prepare()
        for changes in ({"id": 41}, {"tag_name": "other-tag"}, {"draft": False}):
            cli = FakeGitHub(self.directory, tag_commit=COMMIT, existing=True, draft=True, hide_draft=True)
            native = {"databaseId": 42, "isDraft": True, "tagName": cli.tag}
            record = {**cli.release_record(), **changes}
            with self.subTest(changes=changes), patch.object(cli, "release_view", return_value=native), patch.object(cli, "release_record", return_value=record):
                with self.assertRaises(release.ReleaseError):
                    release.publish(self.directory, cli)
            self.assertEqual(cli.commands(), [])

    def test_resumed_draft_refreshes_title_and_verified_notes_at_publish(self) -> None:
        manifest = self.prepare()
        cli = FakeGitHub(self.directory, tag_commit=COMMIT, existing=True, draft=True)
        self.assertEqual(release.publish(self.directory, cli), cli.url)
        final = cli.commands()[-1]
        self.assertEqual(final[final.index("--title") + 1], manifest["title"])
        self.assertEqual(final[final.index("--notes-file") + 1], str(self.directory / "release-notes.md"))

    def test_existing_published_release_is_not_overwritten_by_nondeterministic_rebuild(self) -> None:
        self.prepare()
        cli = FakeGitHub(self.directory, tag_commit=COMMIT, existing=True, draft=False)
        (self.directory / PAYLOADS[0]).write_bytes(b"a different build with the same source")
        self.prepare()
        self.assertEqual(release.publish(self.directory, cli), cli.url)
        self.assertEqual(cli.commands(), [])
        self.assertFalse(any(call[1] == "POST" for call in cli.calls if call[0] == "request"))

    def test_existing_published_release_with_missing_asset_is_not_mutated(self) -> None:
        self.prepare()
        cli = FakeGitHub(self.directory, tag_commit=COMMIT, existing=True, draft=False)
        cli.assets.pop()
        with self.assertRaises(release.ReleaseError):
            release.publish(self.directory, cli)
        self.assertEqual(cli.commands(), [])

    def test_existing_release_is_found_after_the_first_full_page(self) -> None:
        self.prepare()

        class PagedGitHub(FakeGitHub):
            def request(self, endpoint, method="GET", fields=None, allow_missing=False):
                if urlsplit(endpoint).path.rstrip("/") == f"repos/{REPOSITORY}/releases":
                    page = parse_qs(urlsplit(endpoint).query).get("page", ["1"])[0]
                    if page == "1":
                        self.calls.append(("request", method, endpoint, fields))
                        return [{"tag_name": f"unrelated-build-{number}"} for number in range(100)]
                return super().request(endpoint, method, fields, allow_missing)

        cli = PagedGitHub(self.directory, tag_commit=COMMIT, existing=True, draft=False)
        self.assertEqual(release.publish(self.directory, cli), cli.url)
        self.assertTrue(any("page=2" in str(call[2]) for call in cli.calls if call[0] == "request"))
        self.assertEqual(cli.commands(), [])

    def test_duplicate_exact_tags_on_different_pages_fail_without_mutation(self) -> None:
        self.prepare()

        class DuplicateGitHub(FakeGitHub):
            def request(self, endpoint, method="GET", fields=None, allow_missing=False):
                if urlsplit(endpoint).path.rstrip("/") == f"repos/{REPOSITORY}/releases":
                    page = parse_qs(urlsplit(endpoint).query).get("page", ["1"])[0]
                    exact = super().request(endpoint, method, fields, allow_missing)
                    if page == "1":
                        return exact + [{"tag_name": f"unrelated-{number}"} for number in range(99)]
                    return exact
                return super().request(endpoint, method, fields, allow_missing)

        cli = DuplicateGitHub(self.directory, tag_commit=COMMIT, existing=True, draft=True)
        with self.assertRaises(release.ReleaseError):
            release.publish(self.directory, cli)
        self.assertEqual(cli.commands(), [])
        self.assertFalse(any(call[1] == "POST" for call in cli.calls))

    def test_release_listing_has_a_hard_page_limit(self) -> None:
        self.prepare()

        class EndlessGitHub(FakeGitHub):
            def request(self, endpoint, method="GET", fields=None, allow_missing=False):
                if urlsplit(endpoint).path.rstrip("/") == f"repos/{REPOSITORY}/releases":
                    self.calls.append(("request", method, endpoint, fields))
                    return [{"tag_name": f"unrelated-{number}"} for number in range(100)]
                return super().request(endpoint, method, fields, allow_missing)

        cli = EndlessGitHub(self.directory, tag_commit=COMMIT)
        with patch.object(release, "MAX_RELEASE_PAGES", 2), self.assertRaises(release.ReleaseError):
            release.publish(self.directory, cli)
        listing = [call for call in cli.calls if "/releases?" in str(call[2])]
        self.assertEqual(len(listing), 2)
        self.assertEqual(cli.commands(), [])
        self.assertFalse(any(call[1] == "POST" for call in cli.calls))

    def test_source_mismatch_and_tag_moved_after_upload_prevent_publication(self) -> None:
        self.prepare()
        cli = FakeGitHub(self.directory, tag_commit=OTHER_COMMIT, existing=True, draft=True)
        with self.assertRaises(release.ReleaseError):
            release.publish(self.directory, cli)
        self.assertEqual(cli.commands(), [])
        moved = FakeGitHub(self.directory, move_after_upload=True)
        with self.assertRaises(release.ReleaseError):
            release.publish(self.directory, moved)
        self.assertTrue(moved.draft)
        self.assertFalse(any(call[1:3] == ("release", "edit") for call in moved.commands()))

    def test_old_main_run_cannot_publish_or_replace_the_latest_release(self) -> None:
        self.prepare()
        stale = FakeGitHub(self.directory, main_commit=OTHER_COMMIT)
        with self.assertRaises(release.ReleaseError):
            release.publish(self.directory, stale)
        self.assertEqual(stale.commands(), [])
        self.assertFalse(any(call[1] == "POST" for call in stale.calls))
        advanced = FakeGitHub(self.directory, advance_main_after_upload=True)
        with self.assertRaises(release.ReleaseError):
            release.publish(self.directory, advanced)
        self.assertTrue(advanced.draft)
        self.assertFalse(any(call[1:3] == ("release", "edit") for call in advanced.commands()))

    def test_payload_or_checksum_tampering_fails_before_github_mutation(self) -> None:
        self.prepare()
        (self.directory / PAYLOADS[0]).write_bytes(b"changed after manifest preparation")
        cli = FakeGitHub(self.directory)
        with self.assertRaises(release.ReleaseError):
            release.publish(self.directory, cli)
        self.assertEqual(cli.calls, [])
        self.prepare()
        (self.directory / "SHA256SUMS").write_text("incorrect checksums\n")
        with self.assertRaises(release.ReleaseError):
            release.publish(self.directory, cli)
        self.assertEqual(cli.calls, [])

    def test_manifest_cannot_redirect_asset_reads_outside_distribution(self) -> None:
        manifest = self.prepare()
        manifest["assets"][0]["name"] = "../../private-key"
        (self.directory / "release.json").write_text(json.dumps(manifest))
        cli = FakeGitHub(self.directory)
        with self.assertRaises(release.ReleaseError):
            release.publish(self.directory, cli)
        self.assertEqual(cli.calls, [])

    def test_pull_request_ci_and_mismatched_build_contexts_fail_before_github(self) -> None:
        self.prepare()
        context = {
            "GITHUB_ACTIONS": "true",
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REPOSITORY": REPOSITORY,
            "GITHUB_SHA": COMMIT,
            "GITHUB_REF": "refs/heads/main",
        }
        for override in (
            {"GITHUB_EVENT_NAME": "pull_request"},
            {"GITHUB_REPOSITORY": "elsewhere/repository"},
            {"GITHUB_SHA": OTHER_COMMIT},
            {"GITHUB_REF": "refs/pull/1/merge"},
        ):
            cli = FakeGitHub(self.directory)
            with self.subTest(override=override), patch.dict(os.environ, {**context, **override}), self.assertRaises(release.ReleaseError):
                release.publish(self.directory, cli)
            self.assertEqual(cli.calls, [])

    def test_tag_workflow_dispatch_is_rejected_but_matching_tag_push_is_allowed(self) -> None:
        self.prepare(ref="refs/tags/v0.1.2")
        context = {
            "GITHUB_ACTIONS": "true",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REPOSITORY": REPOSITORY,
            "GITHUB_SHA": COMMIT,
            "GITHUB_REF": "refs/tags/v0.1.2",
        }
        cli = FakeGitHub(self.directory, tag_commit=COMMIT)
        with patch.dict(os.environ, context), self.assertRaises(release.ReleaseError):
            release.publish(self.directory, cli)
        self.assertEqual(cli.calls, [])
        pushed = FakeGitHub(self.directory, tag_commit=COMMIT)
        with patch.dict(os.environ, {**context, "GITHUB_EVENT_NAME": "push"}):
            self.assertEqual(release.publish(self.directory, pushed), pushed.url)

    def test_main_workflow_dispatch_publishes_the_matching_source(self) -> None:
        self.prepare()
        cli = FakeGitHub(self.directory)
        context = {
            "GITHUB_ACTIONS": "true",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REPOSITORY": REPOSITORY,
            "GITHUB_SHA": COMMIT,
            "GITHUB_REF": "refs/heads/main",
        }
        with patch.dict(os.environ, context):
            self.assertEqual(release.publish(self.directory, cli), cli.url)


if __name__ == "__main__":
    unittest.main()
