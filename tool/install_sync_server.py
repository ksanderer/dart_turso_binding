"""Install the pinned upstream CLI for integration tests, never an unverified latest."""
import hashlib
import os
from pathlib import Path
import platform
import shutil
import tarfile
import urllib.request
import zipfile

RELEASE = "v0.7.2"
ASSETS = {
    ("Darwin", "arm64"): ("aarch64-apple-darwin.tar.xz", "973afde6809383d165b222445c42925cf112562cfacd9c9a0e767b15d8698e9c"),
    ("Darwin", "x86_64"): ("x86_64-apple-darwin.tar.xz", "89ed17e9ca8642eda8d44dcd0635cce670c0d3e9db7a5d13603d2df1e7b615f5"),
    ("Linux", "x86_64"): ("x86_64-unknown-linux-gnu.tar.xz", "321e401e44f7ee8ea656caff0f85304025f7e905acafe7bedf6a9304f1af1783"),
    ("Windows", "AMD64"): ("x86_64-pc-windows-msvc.zip", "a3778389de379d690cc2822aea2e9bb2a50bdccd2e790893961eea7a290824f2"),
}


def main():
    asset, digest = ASSETS[(platform.system(), platform.machine())]
    directory = Path(".dart_tool/sync-server").resolve()
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / ("turso_cli-" + asset)
    url = f"https://github.com/tursodatabase/turso/releases/download/{RELEASE}/{archive.name}"
    with urllib.request.urlopen(url, timeout=120) as response, archive.open("wb") as output:
        shutil.copyfileobj(response, output)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError("Upstream CLI checksum mismatch")
    executable_name = "tursodb.exe" if os.name == "nt" else "tursodb"
    executable = directory / executable_name
    # Extract only the executable, never arbitrary archive paths or symlinks.
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as package:
            member = next(n for n in package.namelist() if Path(n).name == executable_name)
            executable.write_bytes(package.read(member))
    else:
        with tarfile.open(archive) as package:
            member = next(m for m in package.getmembers() if m.isfile() and Path(m.name).name == executable_name)
            with package.extractfile(member) as source, executable.open("wb") as output:
                shutil.copyfileobj(source, output)
    executable.chmod(0o755)
    if "GITHUB_ENV" in os.environ:
        with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as output:
            output.write(f"DTB_SYNC_SERVER={executable}\n")
            output.write("DTB_REQUIRE_SYNC_TESTS=1\n")
    print(executable)


if __name__ == "__main__":
    main()
