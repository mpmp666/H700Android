#!/usr/bin/env python3
"""Probe the official Orange Pi source folder on GitHub-hosted Ubuntu only.

Default: list names/IDs, without downloading archive bodies. Optional MD5
sidecars are hints; only full bytes/MD5/SHA256 verification proves identity.
--download --output FILE downloads one unambiguous candidate by its Drive ID,
never extracts it, and publishes FILE only after all external-inputs locks pass.
Environment checks prevent accidental local use; they are not authentication.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import html
import importlib.metadata
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import sys
from typing import BinaryIO

GDOWN_VERSION = "6.5.1"
TIMEOUT = (15, 45)
OFFICIAL_PAGE = "http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/service-and-support/Orange-Pi-Zero-2.html"
FOLDER_URL = "https://drive.google.com/drive/folders/1HQqYQdJLkL2cmx47448wvQvAW7x9ZQwZ?usp=sharing"
LOCK_PATH = Path(__file__).resolve().parents[2] / "build-support/public/external-inputs.json"
EXPECTED = {
    "name": "android.tar.gz",
    "bytes": 22273432977,
    "md5": "c5dd785ecd45ca9a2b9c53b1092ee6ec",
    "sha256": "94f4b20c4805f3ab1a618e2ebf933d87fcc288632da692d870170e0f6d78ae09",
}
SIDECAR_NAMES = {"android.tar.gz.md5", "android.tar.gz.md5sum", "android.tar.gz.md5.txt"}
SIDECAR_LIMIT = 64 * 1024
REPORT_LIMIT = 256 * 1024


class SourceError(Exception):
    """A safe, locally authored diagnostic, containing no response URLs/text."""


def require_runner(download: bool) -> Path:
    """Reject before importing gdown or starting any network/file-body request."""
    required = {
        "GITHUB_ACTIONS": "true",
        "RUNNER_ENVIRONMENT": "github-hosted",
        "RUNNER_OS": "Linux",
    }
    if any(os.environ.get(key) != value for key, value in required.items()):
        raise SourceError("Requires GITHUB_ACTIONS=true, RUNNER_ENVIRONMENT=github-hosted and RUNNER_OS=Linux")
    if platform.system() != "Linux" or not os.environ.get("ImageOS", "").startswith("ubuntu"):
        raise SourceError("Requires a GitHub-hosted Ubuntu runner")
    if not re.fullmatch(r"[0-9]+", os.environ.get("GITHUB_RUN_ID", "")):
        raise SourceError("Missing GitHub run identity")
    if download and os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
        raise SourceError("Archive download requires an explicit workflow_dispatch run")
    workspace = Path(os.environ.get("GITHUB_WORKSPACE", ""))
    temp = Path(os.environ.get("RUNNER_TEMP", ""))
    if not workspace.is_absolute() or not temp.is_absolute():
        raise SourceError("GITHUB_WORKSPACE and RUNNER_TEMP must be absolute runner directories")
    workspace, temp = workspace.resolve(strict=True), temp.resolve(strict=True)
    if not workspace.is_dir() or not temp.is_dir() or temp == Path("/"):
        raise SourceError("Invalid runner directories")
    if workspace.is_relative_to(temp) or temp.is_relative_to(workspace):
        raise SourceError("RUNNER_TEMP must be separate from the checked-out workspace")
    if not Path(__file__).resolve().is_relative_to(workspace):
        raise SourceError("Run the script checked out inside GITHUB_WORKSPACE")
    return temp


def runner_path(path: Path, temp: Path, *, new: bool = True) -> Path:
    resolved = path.resolve()
    if resolved == temp or not resolved.is_relative_to(temp):
        raise SourceError("Output/report paths must be inside RUNNER_TEMP")
    if new and os.path.lexists(path):
        raise SourceError("Refuse overwriting an existing output/report, including a symlink")
    return resolved


def load_lock() -> dict:
    data = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    matches = [item for item in data["source_archives"] if item.get("name") == EXPECTED["name"]]
    if len(matches) != 1 or any(matches[0].get(key) != value for key, value in EXPECTED.items()):
        raise SourceError("external-inputs.json must retain the exact android.tar.gz bytes/MD5/SHA256 lock")
    return dict(EXPECTED)


def load_gdown():
    if importlib.metadata.version("gdown") != GDOWN_VERSION:
        raise SourceError("Install the required gdown==6.5.1 in the runner environment")
    import gdown
    return gdown


@contextlib.contextmanager
def quiet_library():
    # Only our JSON name/ID records go to stdout; never expose redirected URLs.
    with open(os.devnull, "w", encoding="utf-8") as sink:
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            yield


def list_files(gdown) -> list[dict[str, str]]:
    with quiet_library():
        items = gdown.download_folder(
            url=FOLDER_URL, skip_download=True, quiet=True,
            use_cookies=False, timeout=TIMEOUT,
        )
    if not isinstance(items, list) or len(items) > 1024:
        raise SourceError("Invalid or excessively large folder inventory")
    files = []
    for item in items:
        name, file_id = item.path, item.id
        if not isinstance(name, str) or not name or len(name) > 1024:
            raise SourceError("Invalid folder entry name")
        path = PurePosixPath(name)
        if path.is_absolute() or any(part in (".", "..") for part in path.parts) or "\\" in name:
            raise SourceError("Unsafe folder entry path")
        if not isinstance(file_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{10,200}", file_id):
            raise SourceError("Invalid folder entry ID")
        # Do not retain or use gdown's suggested local_path.
        files.append({"name": name, "id": file_id})
    if len(json.dumps(files, ensure_ascii=True).encode("utf-8")) > REPORT_LIMIT // 2:
        raise SourceError("Folder inventory exceeds the small-report budget")
    return sorted(files, key=lambda item: (item["name"], item["id"]))


def select_archive(files: list[dict[str, str]]) -> dict[str, str]:
    matches = [item for item in files if PurePosixPath(item["name"]).name == EXPECTED["name"]]
    if len(matches) != 1:
        raise SourceError(f"Expected exactly one android.tar.gz candidate; found {len(matches)}; refusing selection")
    return matches[0]


def read_sidecar(file_id: str) -> bytes:
    # gdown streams in 512 KiB chunks, so use requests directly for this optional
    # tiny payload. Range + bounded reads also reject servers ignoring Range.
    import requests
    url = "https://drive.google.com/uc"
    with requests.Session() as session:
        session.trust_env = False
        with session.get(url, params={"export": "download", "id": file_id},
                         headers={"Range": f"bytes=0-{SIDECAR_LIMIT}", "Accept-Encoding": "identity"},
                         stream=True, timeout=TIMEOUT) as response:
            response.raise_for_status()
            if response.status_code not in (200, 206):
                raise SourceError("MD5 sidecar request did not return HTTP 200/206")
            length = response.headers.get("Content-Length")
            if length is not None and (not length.isdigit() or int(length) > SIDECAR_LIMIT):
                raise SourceError("MD5 sidecar exceeds the 64 KiB limit or has invalid length")
            if response.status_code == 206:
                match = re.fullmatch(r"bytes 0-(\d+)/(\d+)", response.headers.get("Content-Range", ""))
                if not match or int(match[2]) > SIDECAR_LIMIT or int(match[1]) + 1 != int(match[2]):
                    raise SourceError("MD5 sidecar range does not describe a complete file of at most 64 KiB")
            body = bytearray()
            for chunk in response.iter_content(chunk_size=4096):
                if len(body) + len(chunk) > SIDECAR_LIMIT:
                    raise SourceError("MD5 sidecar exceeds the 64 KiB limit")
                body.extend(chunk)
            return bytes(body)


def check_sidecar(files: list[dict[str, str]], archive: dict[str, str]) -> dict:
    parent = PurePosixPath(archive["name"]).parent
    candidates = [item for item in files if PurePosixPath(item["name"]).parent == parent
                  and PurePosixPath(item["name"]).name in SIDECAR_NAMES]
    if not candidates:
        return {"status": "absent", "identity_verified": False}
    if len(candidates) != 1:
        raise SourceError("Multiple MD5 sidecar candidates; refusing selection")
    candidate = candidates[0]
    payload = read_sidecar(candidate["id"])
    if len(payload) > SIDECAR_LIMIT:
        raise SourceError("MD5 sidecar exceeds the 64 KiB limit")
    try:
        text = payload.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise SourceError("MD5 sidecar is not UTF-8 text") from None
    digests = []
    for line in text.splitlines():
        line = line.strip()
        match = re.fullmatch(r"([0-9a-fA-F]{32})(?:\s+\*?(?:\./)?android\.tar\.gz)?", line)
        bsd = re.fullmatch(r"MD5\s*\(android\.tar\.gz\)\s*=\s*([0-9a-fA-F]{32})", line)
        if match or bsd:
            digests.append((match or bsd).group(1).lower())
    if len(digests) != 1:
        raise SourceError("MD5 sidecar must contain one unambiguous android.tar.gz checksum")
    if digests[0] != EXPECTED["md5"]:
        raise SourceError("MD5 sidecar disagrees with the locked source version")
    return {**candidate, "status": "matches_md5_hint_only", "bytes": len(payload),
            "md5": digests[0], "identity_verified": False}


class LockedWriter:
    """Bound disk writes and hash exactly the bytes written, without buffering."""
    def __init__(self, stream: BinaryIO, spec: dict):
        self.stream, self.spec, self.count = stream, spec, 0
        self.digests = {name: hashlib.new(name) for name in ("md5", "sha256")}

    def write(self, data: bytes) -> int:
        if self.count + len(data) > self.spec["bytes"]:
            raise SourceError("Archive exceeds the locked byte count")
        size = self.stream.write(data)
        if size != len(data):
            raise SourceError("Short write while receiving archive")
        self.count += size
        for digest in self.digests.values():
            digest.update(data)
        return size

    def flush(self) -> None:
        self.stream.flush()

    def observation(self) -> dict:
        return {"bytes": self.count, **{key: value.hexdigest() for key, value in self.digests.items()}}


def download_archive(gdown, archive: dict[str, str], output: Path, temp: Path, spec: dict, report: dict) -> None:
    # Repeat the guard immediately before the only large-body call.
    require_runner(download=True)
    output = runner_path(output, temp)
    partial = runner_path(output.with_name(output.name + ".unverified.part"), temp)
    output.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(output.parent).free < spec["bytes"] + 1024**3:
        raise SourceError("Not enough free space for the locked archive plus a 1 GiB margin")
    report["archive"] = {"identity_verified": False, "partial_name": partial.name}
    # Never hand gdown a filesystem path: it must not rename/overwrite an output
    # before validation. Failed partials stay on this disposable runner for review.
    with partial.open("xb") as stream:
        writer = LockedWriter(stream, spec)
        try:
            with quiet_library():
                result = gdown.download(
                    id=archive["id"], output=writer, quiet=True,
                    use_cookies=False, timeout=TIMEOUT, resume=False, retries=0,
                )
            if result is not writer:
                raise SourceError("Archive transfer did not complete")
            writer.flush()
            os.fsync(stream.fileno())
        finally:
            report["archive"].update(writer.observation())
    observed = report["archive"]
    if partial.stat().st_size != spec["bytes"] or any(observed[key] != spec[key] for key in ("bytes", "md5", "sha256")):
        raise SourceError("Archive does not match locked bytes/MD5/SHA256; no verified output published")
    # A hard link publishes without replacing any file created concurrently.
    os.link(partial, output)
    if partial.resolve(strict=True) != partial or not partial.is_relative_to(temp):
        raise SourceError("Unexpected partial path; refusing cleanup")
    partial.unlink()
    report["archive"].pop("partial_name")
    report["archive"].update(identity_verified=True, output=str(output))


def publish_report(report: dict, report_path: Path | None, temp: Path) -> None:
    if report_path:
        payload = (json.dumps(report, indent=2, ensure_ascii=True) + "\n").encode("utf-8")
        if len(payload) > REPORT_LIMIT:
            raise SourceError("Report exceeds the 256 KiB limit")
        report_path = runner_path(report_path, temp)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        with report_path.open("xb") as stream:
            stream.write(payload)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        summary_path = runner_path(Path(summary), temp, new=False)
        lines = ["## H700 official source", "", f"Mode: {report['mode']}",
                 f"Status: {report['status']}",
                 f"Archive identity verified: {report.get('archive', {}).get('identity_verified', False)}", "",
                 "Names and sidecars are candidate hints. Exact identity requires locked bytes, MD5 and SHA256.", ""]
        if report.get("error"):
            lines += [html.escape(report["error"]), ""]
        entries = report.get("files", [])
        lines += ["<pre>", html.escape("\n".join(json.dumps(item, ensure_ascii=True) for item in entries[:100])), "</pre>"]
        if len(entries) > 100:
            lines.append("Remaining name/ID records are in the small JSON artifact.")
        with summary_path.open("a", encoding="utf-8") as stream:
            stream.write("\n".join(lines) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", dest="report_path", type=Path, help="Save a small JSON receipt inside RUNNER_TEMP")
    parser.add_argument("--check-md5-sidecar", action="store_true", help="Read one exact-name MD5 sidecar, accepting at most 64 KiB")
    parser.add_argument("--download", action="store_true", help="Explicitly download and verify the unique candidate (hosted manual runs only)")
    parser.add_argument("--output", type=Path, help="New archive file inside RUNNER_TEMP; requires --download")
    args = parser.parse_args(argv)
    if args.download != (args.output is not None):
        parser.error("--download and --output must be supplied together")
    report = {"schema": 1, "mode": "download" if args.download else "metadata",
              "status": "failed", "gdown_version": GDOWN_VERSION, "official_page": OFFICIAL_PAGE,
              "folder_url": FOLDER_URL, "expected": dict(EXPECTED), "files": [],
              "archive": {"identity_verified": False}}
    temp = None
    try:
        temp = require_runner(args.download)
        if args.report_path:
            args.report_path = runner_path(args.report_path, temp)
        if args.output:
            args.output = runner_path(args.output, temp)
            if args.report_path in (args.output, args.output.with_name(args.output.name + ".unverified.part")):
                raise SourceError("JSON receipt and archive paths must be different")
        spec = load_lock()
        gdown = load_gdown()
        report["files"] = list_files(gdown)
        for item in report["files"]:
            print(json.dumps(item, ensure_ascii=True), flush=True)
        report["selected_candidate"] = select_archive(report["files"])
        report["sidecar"] = {"status": "not_requested", "identity_verified": False}
        if args.check_md5_sidecar:
            report["sidecar"] = check_sidecar(report["files"], report["selected_candidate"])
        if args.download:
            download_archive(gdown, report["selected_candidate"], args.output, temp, spec, report)
        report["status"] = "verified" if args.download else "candidate_only"
    except Exception as error:
        # Network/library exception strings can include redirect URLs or server text.
        report["error"] = str(error) if isinstance(error, SourceError) else f"Operation failed ({type(error).__name__}); response details suppressed"
        print("ERROR: " + report["error"], file=sys.stderr)
    if temp is not None:
        try:
            publish_report(report, args.report_path, temp)
        except Exception as error:
            message = str(error) if isinstance(error, SourceError) else type(error).__name__
            print("ERROR: Cannot publish small report: " + message, file=sys.stderr)
            return 2
    return 0 if report["status"] in ("candidate_only", "verified") else 2


if __name__ == "__main__":
    raise SystemExit(main())
