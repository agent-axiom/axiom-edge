#!/usr/bin/env python3
"""Prepare verified mobile assets and publish a complete GitHub release.

The publishing job supplies GH_TOKEN. This module never reads or prints it.
Only successful trusted main/tag workflows may invoke publication; PRs prepare
and test the same files without receiving a write token.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any
from urllib.parse import quote


ASSET_NAMES = (
    "axiom-edge-android-arm64.apk",
    "axiom-edge-ios-unsigned.zip",
)
UPLOAD_NAMES = (*ASSET_NAMES, "release.json", "SHA256SUMS")
MAX_RELEASE_PAGES = 100
VERSION_RE = re.compile(
    r"(?P<base>(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
    r"(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?)"
    r"(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
)
REPOSITORY_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+")
SHA_RE = re.compile(r"[0-9a-f]{40}")
DIGEST_RE = re.compile(r"[0-9a-f]{64}")


class ReleaseError(Exception):
    """An invalid input or incomplete upload must not become a public release."""


def _positive(value: object, name: str) -> int:
    if isinstance(value, bool) or not re.fullmatch(r"[1-9]\d*", str(value)):
        raise ReleaseError(f"{name} must be a positive integer")
    return int(str(value))


def _identity(repository: object, commit: object) -> tuple[str, str]:
    if (
        not isinstance(repository, str)
        or not REPOSITORY_RE.fullmatch(repository)
        or repository.split("/")[1] in {".", ".."}
    ):
        raise ReleaseError("repository must be an owner/name GitHub repository")
    if not isinstance(commit, str) or not SHA_RE.fullmatch(commit.lower()):
        raise ReleaseError("commit must be a full 40-character hexadecimal SHA")
    return repository, commit.lower()


def _version(pubspec: Path) -> tuple[str, str]:
    try:
        matches = re.findall(r"(?m)^version:\s*([^\n#]+)(?:#.*)?$", pubspec.read_text())
    except OSError as error:
        raise ReleaseError(f"cannot read pubspec: {pubspec}") from error
    if len(matches) != 1:
        raise ReleaseError("pubspec must contain exactly one version")
    value = matches[0].strip().strip("\"'")
    match = VERSION_RE.fullmatch(value)
    if match is None:
        raise ReleaseError("pubspec version must be a valid version without path characters")
    return value, match.group("base")


def _tag(base_version: str, ref: str, run_number: int) -> str:
    if ref == "refs/heads/main":
        return f"v{base_version}-build.{run_number}"
    if ref == f"refs/tags/v{base_version}":
        return f"v{base_version}"
    raise ReleaseError("release ref must be main or the matching explicit version tag")


def _directory(directory: Path) -> Path:
    if directory.is_symlink() or not directory.is_dir():
        raise ReleaseError(f"release directory does not exist or is a symlink: {directory}")
    return directory.resolve()


def _file(directory: Path, name: str) -> Path:
    if name not in {*UPLOAD_NAMES, "release-notes.md"}:
        raise ReleaseError(f"unsupported release asset: {name}")
    path = directory / name
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        raise ReleaseError(f"required nonempty regular release file is missing: {name}")
    return path


def _digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _write(directory: Path, name: str, content: str) -> None:
    path = directory / name
    if path.is_symlink():
        raise ReleaseError(f"refusing to replace a symlink: {name}")
    path.write_text(content, encoding="utf-8")


def _release_url(manifest: dict[str, Any]) -> str:
    return f"https://github.com/{manifest['repository']}/releases/tag/{quote(manifest['tag'], safe='')}"


def _notes(manifest: dict[str, Any]) -> str:
    root = f"https://github.com/{manifest['repository']}"
    assets = f"{root}/releases/download/{quote(manifest['tag'], safe='')}"
    return f"""**[Скачать Android APK (ARM64)]({assets}/{ASSET_NAMES[0]})**

## Загрузки

| ОС | Скачать | Статус |
| --- | --- | --- |
| Android 9+, ARM64 | [APK приложения]({assets}/{ASSET_NAMES[0]}) | Тестовая устанавливаемая сборка |
| iOS 16.4+ | [Архив для разработчика]({assets}/{ASSET_NAMES[1]}) | Без подписи Apple; не устанавливается напрямую на iPhone |

Архив iOS — сборка без подписи, а не готовый к установке IPA.
Для установки нужна подпись Apple и соответствующая настройка распространения.
Устанавливаемые сборки Windows, macOS и Linux пока не выпускаются.

Android APK подписан отладочным ключом CI. Смена ключа может потребовать
удаления предыдущей версии; удаление очищает локальные модели и историю.

[Проверить SHA-256]({assets}/SHA256SUMS) · [Сведения о сборке]({assets}/release.json) · [Исходники]({root}/archive/refs/tags/{quote(manifest['tag'], safe='')}.zip)

Версия приложения: `{manifest['version']}`. Сборка CI: `{manifest['run_number']}`.
[Исходный коммит]({root}/commit/{manifest['commit']}) · [Успешная проверка и сборки]({manifest['run_url']}).
"""


def prepare(
    directory: Path,
    repository: str,
    commit: str,
    run_id: str,
    run_number: str,
    ref: str,
    pubspec: Path = Path("pubspec.yaml"),
) -> dict[str, Any]:
    directory = _directory(directory)
    repository, commit = _identity(repository, commit)
    run_id_number = _positive(run_id, "run_id")
    run_number_value = _positive(run_number, "run_number")
    version, base_version = _version(pubspec)
    tag = _tag(base_version, ref, run_number_value)
    assets = []
    for name in ASSET_NAMES:
        path = _file(directory, name)
        assets.append({"name": name, "size": path.stat().st_size, "sha256": _digest(path)})
    manifest = {
        "schema_version": 1,
        "repository": repository,
        "commit": commit,
        "ref": ref,
        "version": version,
        "base_version": base_version,
        "run_id": run_id_number,
        "run_number": run_number_value,
        "run_url": f"https://github.com/{repository}/actions/runs/{run_id_number}",
        "tag": tag,
        "title": f"Axiom Edge {base_version} · сборка {run_number_value}",
        "assets": assets,
        "ios_installable": False,
        "android_signing": "CI debug key; not a stable production signing identity",
    }
    _write(directory, "release.json", json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    checksum_paths = [*ASSET_NAMES, "release.json"]
    _write(
        directory,
        "SHA256SUMS",
        "".join(f"{_digest(_file(directory, name))}  {name}\n" for name in checksum_paths),
    )
    _write(directory, "release-notes.md", _notes(manifest))
    return manifest


class GitHubCLI:
    """Use gh's normal authenticated environment, never a token argument."""

    @staticmethod
    def _run(arguments: list[str], allow_missing: bool = False) -> str | None:
        result = subprocess.run(["gh", *arguments], text=True, capture_output=True, check=False)
        if result.returncode:
            if allow_missing and re.search(r"\bHTTP 404\b", result.stderr):
                return None
            # CLI arguments contain only repository/ref/file metadata, not tokens.
            status = re.search(r"\bHTTP (\d{3})\b", result.stderr)
            detail = f", HTTP {status.group(1)}" if status else ""
            raise ReleaseError(
                f"GitHub CLI failed ({result.returncode}{detail}): gh {' '.join(arguments[:4])}"
            )
        return result.stdout

    def command(self, *arguments: str) -> str:
        return self._run(list(arguments)) or ""

    def request(
        self,
        endpoint: str,
        method: str = "GET",
        fields: dict[str, str] | None = None,
        allow_missing: bool = False,
    ) -> Any:
        arguments = ["api", "--method", method, endpoint, "-H", "Accept: application/vnd.github+json"]
        for key, value in (fields or {}).items():
            arguments.extend(["-f", f"{key}={value}"])
        output = self._run(arguments, allow_missing=allow_missing)
        if output is None:
            return None
        try:
            return json.loads(output)
        except json.JSONDecodeError as error:
            raise ReleaseError(f"GitHub API returned invalid JSON for {endpoint}") from error


def _manifest(directory: Path) -> dict[str, Any]:
    try:
        manifest = json.loads(_file(directory, "release.json").read_text(encoding="utf-8"))
        repository, commit = _identity(manifest["repository"], manifest["commit"])
        version_match = VERSION_RE.fullmatch(manifest["version"])
        if version_match is None or manifest["base_version"] != version_match.group("base"):
            raise ReleaseError("invalid manifest version")
        expected_tag = _tag(manifest["base_version"], manifest["ref"], _positive(manifest["run_number"], "run_number"))
        if manifest["tag"] != expected_tag or manifest["schema_version"] != 1:
            raise ReleaseError("invalid manifest tag or schema version")
        if manifest["run_url"] != f"https://github.com/{repository}/actions/runs/{_positive(manifest['run_id'], 'run_id')}":
            raise ReleaseError("invalid source run URL")
        if commit != manifest["commit"] or manifest.get("ios_installable") is not False:
            raise ReleaseError("invalid source commit or iOS installability")
        assets = manifest["assets"]
        if not isinstance(assets, list) or [asset["name"] for asset in assets] != list(ASSET_NAMES):
            raise ReleaseError("manifest must contain exactly the two supported platform assets")
        for asset in assets:
            path = _file(directory, asset["name"])
            if (
                not isinstance(asset["sha256"], str)
                or not DIGEST_RE.fullmatch(asset["sha256"])
                or asset["size"] != path.stat().st_size
                or asset["sha256"] != _digest(path)
            ):
                raise ReleaseError(f"local asset differs from manifest: {asset['name']}")
        expected_sums = "".join(
            f"{_digest(_file(directory, name))}  {name}\n"
            for name in (*ASSET_NAMES, "release.json")
        )
        if _file(directory, "SHA256SUMS").read_text(encoding="utf-8") != expected_sums:
            raise ReleaseError("local SHA256SUMS does not match release assets")
        if _file(directory, "release-notes.md").read_text(encoding="utf-8") != _notes(manifest):
            raise ReleaseError("release notes differ from the verified manifest")
        return manifest
    except (KeyError, TypeError, ValueError, OSError) as error:
        raise ReleaseError("invalid or incomplete prepared release manifest") from error


def _trusted_context(manifest: dict[str, Any]) -> None:
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    if os.environ.get("GITHUB_EVENT_NAME") not in {"push", "workflow_dispatch"}:
        raise ReleaseError("publishing is forbidden for pull-request events")
    if (
        os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
        and manifest["ref"] != "refs/heads/main"
    ):
        raise ReleaseError("manual publication is allowed only from main")
    for environment, key in (
        ("GITHUB_REPOSITORY", "repository"),
        ("GITHUB_SHA", "commit"),
        ("GITHUB_REF", "ref"),
    ):
        if os.environ.get(environment) != manifest[key]:
            raise ReleaseError(f"{environment} does not match the prepared release")


def _current_main(cli: GitHubCLI, manifest: dict[str, Any]) -> None:
    if manifest["ref"] != "refs/heads/main":
        return
    result = cli.request(f"repos/{manifest['repository']}/git/ref/heads/main")
    if result.get("object", {}).get("sha") != manifest["commit"]:
        raise ReleaseError("release source is no longer main HEAD; refusing to replace latest")


def _tag_commit(cli: GitHubCLI, manifest: dict[str, Any]) -> str | None:
    # /commits/<missing-tag> returns 422, not the 404 used for missing refs.
    result = cli.request(
        f"repos/{manifest['repository']}/git/ref/tags/{quote(manifest['tag'], safe='')}",
        allow_missing=True,
    )
    if result is None:
        return None
    seen = set()
    for _ in range(16):
        if not isinstance(result, dict) or not isinstance(result.get("object"), dict):
            raise ReleaseError("GitHub returned an invalid release tag reference")
        target = result["object"]
        sha = target.get("sha")
        if not isinstance(sha, str) or not SHA_RE.fullmatch(sha):
            raise ReleaseError("GitHub returned an invalid release tag object SHA")
        if target.get("type") == "commit":
            return sha
        if target.get("type") != "tag" or sha in seen:
            raise ReleaseError("release tag does not resolve to a commit")
        seen.add(sha)
        result = cli.request(f"repos/{manifest['repository']}/git/tags/{sha}")
    raise ReleaseError("release tag nesting exceeds the supported depth")


def _release_by_tag(cli: GitHubCLI, manifest: dict[str, Any]) -> dict[str, Any] | None:
    # REST /releases/tags/<tag> is published-only. Authenticated users with
    # push access receive drafts from the paginated release-list endpoint.
    matches = []
    for page in range(1, MAX_RELEASE_PAGES + 1):
        releases = cli.request(
            f"repos/{manifest['repository']}/releases?per_page=100&page={page}"
        )
        if not isinstance(releases, list):
            raise ReleaseError("GitHub did not return a release listing")
        for release in releases:
            if isinstance(release, dict) and release.get("tag_name") == manifest["tag"]:
                matches.append(release)
                if len(matches) > 1:
                    raise ReleaseError("multiple releases use the requested tag; refusing to choose")
        if len(releases) < 100:
            return matches[0] if matches else None
    raise ReleaseError("release listing exceeds the supported pagination limit")


def _published_assets(release: dict[str, Any]) -> None:
    assets = {asset["name"]: asset for asset in release.get("assets", [])}
    if not all(
        name in assets
        and assets[name].get("state") == "uploaded"
        and isinstance(assets[name].get("size"), int)
        and assets[name]["size"] > 0
        for name in UPLOAD_NAMES
    ):
        raise ReleaseError("existing published release is incomplete; refusing to overwrite it")


def _verify_uploaded(cli: GitHubCLI, manifest: dict[str, Any], directory: Path, release_id: int) -> None:
    expected = {
        name: (path.stat().st_size, f"sha256:{_digest(path)}")
        for name in UPLOAD_NAMES
        for path in [_file(directory, name)]
    }
    for attempt in range(3):
        payload = cli.request(f"repos/{manifest['repository']}/releases/{release_id}/assets?per_page=100")
        if not isinstance(payload, list) or not all(isinstance(asset, dict) for asset in payload):
            raise ReleaseError("GitHub did not return the uploaded release assets")
        assets = {asset.get("name"): asset for asset in payload}
        if set(assets) != set(UPLOAD_NAMES):
            raise ReleaseError("uploaded draft does not contain exactly the expected release assets")
        pending_digest = False
        for name in UPLOAD_NAMES:
            asset = assets[name]
            size, digest = expected[name]
            if asset.get("state") != "uploaded" or asset.get("size") != size:
                raise ReleaseError(f"uploaded asset state or size differs: {name}")
            if asset.get("digest") is None:
                pending_digest = True
            elif asset["digest"] != digest:
                raise ReleaseError(f"uploaded asset checksum differs: {name}")
        if not pending_digest:
            return
        if attempt < 2:
            time.sleep(2)
    raise ReleaseError("GitHub asset digests are still unavailable; draft was not published")


def _summary(manifest: dict[str, Any]) -> None:
    url = _release_url(manifest)
    latest_apk = f"https://github.com/{manifest['repository']}/releases/latest/download/{ASSET_NAMES[0]}"
    print(f"Release: {url}\nAndroid APK: {latest_apk}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with Path(summary).open("a", encoding="utf-8") as target:
            target.write(f"## Axiom Edge downloads\n\n[Release and all files]({url})\n\n")
            target.write(f"**[Download Android APK]({latest_apk})**\n\n")
            target.write("iOS is available as an unsigned developer archive on the release page.\n")


def publish(directory: Path, cli: GitHubCLI | None = None) -> str:
    directory = _directory(directory)
    manifest = _manifest(directory)
    _trusted_context(manifest)
    cli = cli or GitHubCLI()
    _current_main(cli, manifest)
    repository, tag = manifest["repository"], manifest["tag"]
    source = _tag_commit(cli, manifest)
    if source is not None and source != manifest["commit"]:
        raise ReleaseError("release tag points to a different source commit")
    if source is None:
        cli.request(
            f"repos/{repository}/git/refs",
            method="POST",
            fields={"ref": f"refs/tags/{tag}", "sha": manifest["commit"]},
        )
    release = _release_by_tag(cli, manifest)
    if release is not None and not release.get("draft", False):
        _published_assets(release)
        _summary(manifest)
        return _release_url(manifest)
    if release is None:
        cli.command(
            "release", "create", tag, "--repo", repository, "--verify-tag", "--draft",
            "--title", manifest["title"], "--notes-file", str(directory / "release-notes.md"),
        )
        release = _release_by_tag(cli, manifest)
    if not isinstance(release, dict) or release.get("draft") is not True or not isinstance(release.get("id"), int):
        raise ReleaseError("GitHub did not create an unpublished draft release")
    cli.command(
        "release", "upload", tag,
        *(str(_file(directory, name)) for name in UPLOAD_NAMES),
        "--repo", repository, "--clobber",
    )
    _verify_uploaded(cli, manifest, directory, release["id"])
    _current_main(cli, manifest)
    if _tag_commit(cli, manifest) != manifest["commit"]:
        raise ReleaseError("release tag changed before publication")
    cli.command(
        "release", "edit", tag, "--repo", repository,
        "--title", manifest["title"], "--notes-file", str(directory / "release-notes.md"),
        "--draft=false", "--latest",
    )
    _summary(manifest)
    return _release_url(manifest)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--repository", required=True)
    prepare_parser.add_argument("--commit", required=True)
    prepare_parser.add_argument("--run-id", required=True)
    prepare_parser.add_argument("--run-number", required=True)
    prepare_parser.add_argument("--ref", required=True)
    prepare_parser.add_argument("--directory", type=Path, required=True)
    publish_parser = commands.add_parser("publish")
    publish_parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            manifest = prepare(
                args.directory, args.repository, args.commit, args.run_id, args.run_number, args.ref
            )
            print(f"Prepared {manifest['tag']} from {manifest['commit']}")
        else:
            publish(args.directory)
    except ReleaseError as error:
        print(f"Release error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
