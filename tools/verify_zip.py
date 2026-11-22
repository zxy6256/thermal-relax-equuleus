#!/usr/bin/env python3
# ============================================================================
# verify_zip.py —— 校验打出来的模块 zip 是否真的是 Magisk 想要的样子
#   python tools/verify_zip.py [dist/xxx.zip]
# 检查：module.prop 在根目录 / 没有源码目录前缀 / 没有 CRLF / 关键文件齐全
# ============================================================================
import glob
import sys
import zipfile

REQUIRED = [
    "module.prop",
    "customize.sh",
    "post-fs-data.sh",
    "service.sh",
    "uninstall.sh",
    "common/util.sh",
    "common/default.conf",
    "bin/thermalctl",
    "tools/gen_overlay.sh",
    "tools/patch_conf.awk",
    "tools/patch_json.awk",
]

BAD_PREFIX = ("module/", "tests/", "docs/", "tools/pack.py", "tools/verify_zip.py")


def main(path: str) -> int:
    z = zipfile.ZipFile(path)
    names = z.namelist()
    errs = []

    if "module.prop" not in names:
        errs.append("module.prop 必须在 zip 根目录")
    bad = [n for n in names if n.startswith(BAD_PREFIX)]
    if bad:
        errs.append(f"zip 里出现了源码目录: {bad[:3]}")
    crlf = [n for n in names if b"\r\n" in z.read(n)]
    if crlf:
        errs.append(f"发现 CRLF 行尾（Android sh 会报 not found）: {crlf}")
    miss = [n for n in REQUIRED if n not in names]
    if miss:
        errs.append(f"缺文件: {miss}")
    empty = [n for n in names if len(z.read(n)) == 0]
    if empty:
        errs.append(f"空文件: {empty}")

    if errs:
        for e in errs:
            print("FAIL:", e)
        return 1

    total = sum(len(z.read(n)) for n in names)
    print(f"OK: {path}  {len(names)} files  {total} bytes  LF clean")
    for n in sorted(names):
        print("   ", n)
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1:
        target = sys.argv[1]
    else:
        found = sorted(glob.glob("dist/*.zip"))
        if not found:
            print("dist/ 下没有 zip")
            sys.exit(1)
        target = found[-1]
    sys.exit(main(target))
