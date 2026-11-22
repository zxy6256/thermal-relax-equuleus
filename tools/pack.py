#!/usr/bin/env python3
# ============================================================================
# pack.py —— 把 module/ 打成 Magisk 可刷的 zip（根目录就是 module.prop）
# 强制 LF：Android 的 sh 不认 CRLF，Windows 上编辑过的脚本会直接 "not found"
# ============================================================================
import pathlib
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOD = ROOT / "module"
DIST = ROOT / "dist"

EXEC_SUFFIX = (".sh",)
EXEC_PREFIX = ("bin/", "tools/")

SKIP_NAMES = {".DS_Store", "Thumbs.db"}
SKIP_PARTS = {"__pycache__", ".git"}


def read_version() -> str:
    for line in (MOD / "module.prop").read_text(encoding="utf-8").splitlines():
        if line.startswith("version="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("module.prop 里没有 version=")


def main() -> int:
    ver = read_version()
    DIST.mkdir(exist_ok=True)
    out = DIST / f"ThermalRelax-equuleus-{ver}.zip"
    if out.exists():
        out.unlink()

    files = []
    for p in sorted(MOD.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(MOD).as_posix()
        if p.name in SKIP_NAMES or any(part in SKIP_PARTS for part in p.parts):
            continue
        files.append((rel, p))

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for rel, p in files:
            raw = p.read_bytes().replace(b"\r\n", b"\n")
            zi = zipfile.ZipInfo(rel, date_time=(2024, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if (rel.endswith(EXEC_SUFFIX) or rel.startswith(EXEC_PREFIX)) else 0o644
            zi.external_attr = mode << 16
            z.writestr(zi, raw)

    size = out.stat().st_size
    print(f"{out}  ({size} bytes, {len(files)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
