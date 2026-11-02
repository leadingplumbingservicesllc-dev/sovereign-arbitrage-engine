"""Install the pinned Linux compiler only after official manifest SHA-256 verification."""
import hashlib
import json
import platform
from pathlib import Path
from urllib.request import urlopen

if platform.system() != "Linux" or platform.machine() != "x86_64":
    raise SystemExit("Use a native Foundry-supported compiler on this platform")
base = "https://raw.githubusercontent.com/ethereum/solc-bin/gh-pages/linux-amd64/"
with urlopen(base + "list.json", timeout=30) as response:
    builds = json.load(response)["builds"]
build = next(b for b in builds if b["version"] == "0.8.24")
target = Path(".tools/solc-0.8.24")
if not target.exists() or "0x" + hashlib.sha256(target.read_bytes()).hexdigest() != build["sha256"]:
    with urlopen(base + build["path"], timeout=60) as response:
        content = response.read()
    if "0x" + hashlib.sha256(content).hexdigest() != build["sha256"]:
        raise SystemExit("Solidity release checksum mismatch")
    target.parent.mkdir(exist_ok=True)
    temporary = target.with_suffix(".tmp")
    temporary.write_bytes(content)
    temporary.chmod(0o755)
    temporary.replace(target)
print(target.resolve())
