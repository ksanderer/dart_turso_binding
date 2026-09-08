"""Fail closed on mismatched release metadata; GitHub release follows publication."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib


def main():
    match = re.search(r"^version: (\S+)$", Path("pubspec.yaml").read_text(), re.MULTILINE)
    if not match:
        raise RuntimeError("Missing Dart package version")
    version = match.group(1)
    tag = os.environ["GITHUB_REF_NAME"]
    if tag != f"v{version}":
        raise RuntimeError("Release tag does not match pubspec.yaml")
    cargo = tomllib.loads(Path("rust/Cargo.toml").read_text())
    if cargo["package"]["version"] != version:
        raise RuntimeError("Rust and Dart versions differ")
    lock = tomllib.loads(Path("rust/Cargo.lock").read_text())
    package = next(p for p in lock["package"] if p["name"] == "dart_turso_binding")
    if package["version"] != version:
        raise RuntimeError("Native lockfile version differs")
    if f"## {version}\n" not in Path("CHANGELOG.md").read_text():
        raise RuntimeError("Missing changelog section")
    if "--github-release" in sys.argv:
        args = ["gh", "release", "create", tag, "--verify-tag", "--generate-notes"]
        if "-" in version:
            args.append("--prerelease")
        subprocess.run(args, check=True)
    print(f"Validated {tag}")


if __name__ == "__main__":
    main()
