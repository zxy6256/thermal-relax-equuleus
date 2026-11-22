#!/system/bin/sh
# ============================================================================
# run_tests.sh —— 主机侧验证（Linux / WSL / git-bash 上跑，不需要设备）
#   sh tests/run_tests.sh
# 覆盖:
#   1. 所有 shell 脚本语法 (sh -n)、awk 补丁器语法
#   2. patch_conf.awk 变换断言：阈值上抬/上限截断/清阈值让距/降频下限/热插拔收敛/
#      安全组跳过/结构不变/单调性
#   3. patch_json.awk 基本行为
#   4. common/util.sh：配置读写、温度换算、空 sysfs 退化
# ============================================================================
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIX=$ROOT/tests/fixtures/thermal-engine.conf
TMP=$(mktemp -d 2>/dev/null || echo "/tmp/tr-test.$$")
mkdir -p "$TMP"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
ng() {
	FAIL=$((FAIL + 1))
	printf '  [FAIL] %s\n' "$1"
}
chk() {
	if [ "$2" = "$3" ]; then ok "$1"; else ng "$1  >>  want[$2] got[$3]"; fi
}
chk_has() {
	if grep -qE "$3" "$2"; then ok "$1"; else ng "$1  >>  no match /$3/"; fi
}
norm() { sed 's/^[[:space:]]*//; s/[[:space:]][[:space:]]*/ /g' "$1"; }

echo '== 1. 语法检查 =='
for f in "$ROOT"/module/customize.sh "$ROOT"/module/post-fs-data.sh \
	"$ROOT"/module/service.sh "$ROOT"/module/uninstall.sh \
	"$ROOT"/module/common/util.sh "$ROOT"/module/tools/gen_overlay.sh \
	"$ROOT"/module/bin/thermalctl "$ROOT"/tests/run_tests.sh; do
	if sh -n "$f" 2>"$TMP/err"; then ok "sh -n $(basename "$f")"; else ng "sh -n $(basename "$f"): $(cat "$TMP/err")"; fi
done
for f in "$ROOT"/module/tools/patch_conf.awk "$ROOT"/module/tools/patch_json.awk; do
	if awk -f "$f" </dev/null >/dev/null 2>"$TMP/err"; then ok "awk -f $(basename "$f")"; else ng "awk -f $(basename "$f"): $(cat "$TMP/err")"; fi
done

echo '== 2. patch_conf.awk 变换 =='
OUT=$TMP/patched.conf
awk -v delta=8000 -v maxc=84000 -v clrmargin=3000 \
	-v floor0=1401600 -v floor1=1209600 -v hotplug_relax=1 -v gpu_floor=0 \
	-v safe_re="batt|ibat|vbat|chg|usb|pa-therm|pa_therm|pm8|pm_|bcl|smb" \
	-f "$ROOT/module/tools/patch_conf.awk" "$FIX" >"$OUT" 2>"$TMP/awkerr"
if [ -s "$TMP/awkerr" ]; then ng "awk 有 stderr: $(cat "$TMP/awkerr")"; else ok 'awk 无 stderr'; fi

chk '行数不变' "$(grep -c . "$FIX")" "$(grep -c . "$OUT")"
chk '段数不变' "$(grep -c '^\[' "$FIX")" "$(grep -c '^\[' "$OUT")"
chk_has '小核阈值 +8°C' "$OUT" '^  thresholds 68000 73000 78000 83000 84000$'
chk_has '小核清阈值 +8°C 并让出 3°C' "$OUT" '^  thresholds_clr 66000 71000 76000 81000 81000$'
chk_has '小核降频下限 1401600' "$OUT" '^  action_info 1478400 1401600 1401600 1401600 1401600$'
chk_has '大核阈值 62000->70000' "$OUT" '^  thresholds 70000 75000 80000 84000 84000$'
chk_has '大核降频下限 1209600' "$OUT" '^  action_info 1900800 1612800 1324800 1209600 1209600$'
chk_has 'skin 阈值 38000->46000' "$OUT" '^  thresholds 46000 48000 50000$'
chk_has 'skin 降频下限抬到 1401600' "$OUT" '^  action_info 1612800 1401600 1401600$'
chk_has '电池段原样' "$OUT" '^thresholds 45000 50000 55000$'
chk_has '充电段原样' "$OUT" '^thresholds 40000 45000$'
chk_has 'shutdown 段原样' "$OUT" '^thresholds 95000 100000$'
chk_has 'shutdown 的 0 哨兵没被抬' "$OUT" '^thresholds_clr 0 0$'
chk_has '热插拔前两档收敛到 1 核' "$OUT" '^  action_info 1 1 3$'
chk_has 'GPU 段阈值上抬、频率不动' "$OUT" '^  action_info 430000000 342000000 257000000$'
chk '阈值不越过 84000（保护段除外）' '0' "$(awk '
	/^\[/ { sec = $0; next }
	/^[[:space:]]*thresholds / { if (sec ~ /SHUTDOWN/) next; for (i = 2; i <= NF; i++) if ($i + 0 > 84000) c++ }
	END { print c + 0 }' "$OUT")"
chk '清阈值不越过 81000' '0' "$(awk '/^[[:space:]]*thresholds_clr /{for(i=2;i<=NF;i++) if($i>81000) c++} END{print c+0}' "$OUT")"
chk '没有负数' '0' "$(grep -cE '(^|[[:space:]])-[0-9]+([[:space:]]|$)' "$OUT")"
chk '阈值表单调不减' '0' "$(awk '/^[[:space:]]*thresholds /{for(i=3;i<=NF;i++) if($i<$ (i-1)) c++} END{print c+0}' "$OUT")"
chk '清阈值表单调不减' '0' "$(awk '/^[[:space:]]*thresholds_clr /{for(i=3;i<=NF;i++) if($i < $(i-1)) c++} END{print c+0}' "$OUT")"
chk '每一段清阈值都严格低于触发阈值' '0' "$(awk '
	/^\[/ {stage=0; next}
	/^[[:space:]]*thresholds / {delete t; stage=1; n=0; for(i=2;i<=NF;i++) t[++n]=$i; next}
	/^[[:space:]]*thresholds_clr / {if(stage!=1) next; k=0; for(i=2;i<=NF;i++){k++; if(t[k]!="" && $i!="0" && t[k]!="0" && $i+0 >= t[k]+0) c++} stage=0; next}
	END{print c+0}' "$OUT")"

OUT2=$TMP/patched-hp0.conf
awk -v delta=8000 -v maxc=84000 -v clrmargin=3000 -v floor0=1401600 -v floor1=1209600 \
	-v hotplug_relax=0 -v gpu_floor=0 -v safe_re="batt|chg" \
	-f "$ROOT/module/tools/patch_conf.awk" "$FIX" >"$OUT2"
chk_has 'hotplug_relax=0 时关核数原样' "$OUT2" '^  action_info 1 2 3$'

OUT3=$TMP/patched-d0.conf
awk -v delta=0 -v maxc=99999 -v clrmargin=3000 -v floor0=0 -v floor1=0 \
	-v hotplug_relax=0 -v gpu_floor=0 -v safe_re="batt|chg" \
	-f "$ROOT/module/tools/patch_conf.awk" "$FIX" >"$OUT3"
norm "$FIX" >"$TMP/a.norm"
norm "$OUT3" >"$TMP/b.norm"
if diff -q "$TMP/a.norm" "$TMP/b.norm" >/dev/null 2>&1; then
	ok 'delta=0 且无下限时输出等价于原文'
else
	ng "delta=0 时输出与原文不一致: $(diff "$TMP/a.norm" "$TMP/b.norm" | head -n 4 | tr '\n' ' ')"
fi

# gpu_floor 打开后 GPU 段应被抬起
OUT4=$TMP/patched-gpu.conf
awk -v delta=8000 -v maxc=84000 -v clrmargin=3000 -v floor0=1401600 -v floor1=1209600 \
	-v hotplug_relax=1 -v gpu_floor=342000000 -v safe_re="batt|chg" \
	-f "$ROOT/module/tools/patch_conf.awk" "$FIX" >"$OUT4"
chk_has 'gpu_floor 生效' "$OUT4" '^  action_info 430000000 342000000 342000000$'

echo '== 3. patch_json.awk =='
cat >"$TMP/ti.json" <<'EOF'
{
  "Sensors": [
    { "Name": "cpu", "Type": "CPU", "HotThreshold": [60.0, 75.0], "VrThreshold": [58.0, 70.0] },
    { "Name": "battery", "Type": "BATTERY", "HotThreshold": [45.0, 50.0] }
  ]
}
EOF
awk -v deltaC=8 -v maxC=82 -v safe_re="battery|charger|usb|pa" \
	-f "$ROOT/module/tools/patch_json.awk" "$TMP/ti.json" >"$TMP/ti.p.json" 2>&1
chk_has 'JSON: CPU HotThreshold +8' "$TMP/ti.p.json" '"HotThreshold": \[68.0, 82.0\]'
chk_has 'JSON: CPU VrThreshold +8' "$TMP/ti.p.json" '"VrThreshold": \[66.0, 78.0\]'
chk_has 'JSON: 电池段不动' "$TMP/ti.p.json" '"HotThreshold": \[45.0, 50.0\]'
chk 'JSON: 行数不变' "$(grep -c . "$TMP/ti.json")" "$(grep -c . "$TMP/ti.p.json")"

echo '== 4. common/util.sh 冒烟 =='
TR_DIR=$TMP/data
mkdir -p "$TR_DIR"
export TR_DIR
export MODDIR=$ROOT/module
. "$ROOT/module/common/util.sh"
tr_cfg_init >/dev/null 2>&1
chk 'config.conf 由默认值生成' 'yes' "$([ -f "$TR_DIR/config.conf" ] && echo yes || echo no)"
chk '读默认 DELTA_MC' '8000' "$(tr_cfg DELTA_MC 0)"
tr_cfg_set DELTA_MC 10000
chk '改配置 DELTA_MC' '10000' "$(tr_cfg DELTA_MC 0)"
chk '不存在的键回退默认' 'X' "$(tr_cfg NOPE X)"
chk 'profile 默认 relaxed' 'relaxed' "$(tr_profile)"
tr_set_profile stock
chk 'profile 可切换' 'stock' "$(tr_profile)"

mkdir -p "$TMP/z1" "$TMP/z2" "$TMP/z3"
printf '52300\n' >"$TMP/z1/temp"
chk '毫摄氏度原样' '52300' "$(tr_temp_mc "$TMP/z1/temp")"
printf '52\n' >"$TMP/z2/temp"
chk '摄氏度自动换算' '52000' "$(tr_temp_mc "$TMP/z2/temp")"
printf 'garbage\n' >"$TMP/z3/temp"
if tr_temp_mc "$TMP/z3/temp" >/dev/null 2>&1; then ng '坏值应返回失败'; else ok '坏值返回失败'; fi
chk '无 thermal_zone 时 hot_state 退化' '0 none' "$(tr_hot_state)"
chk 'sha 为 64 位' '64' "$(tr_sha "$FIX" | tr -d '\n' | wc -c | tr -d ' ')"
chk 'manifest 不存在时 live_apply 不炸' '1' "$(tr_live_apply; echo $?)"
chk 'restore_stock 无 manifest 不炸' '1' "$(tr_restore_stock; echo $?)"

echo '== 5. gen_overlay.sh 端到端（用假 /vendor 根目录）=='
export TR_VENDOR_ROOT=$TMP/vroot
export TR_DIR=$TMP/data2
MODCOPY=$TMP/modcopy
mkdir -p "$TR_VENDOR_ROOT/vendor/etc" "$MODCOPY"
FAKE=$TR_VENDOR_ROOT/vendor/etc/thermal-engine.conf
cp -f "$FIX" "$FAKE"

sh "$ROOT/module/tools/gen_overlay.sh" "$MODCOPY" >/dev/null 2>&1
chk '原厂副本已落盘' 'yes' "$([ -f "$TR_DIR/stock/thermal-engine.conf" ] && echo yes || echo no)"
chk '放宽版已生成' 'yes' "$([ -f "$TR_DIR/patched/thermal-engine.conf" ] && echo yes || echo no)"
chk 'manifest 一条' '1' "$(grep -c . "$TR_DIR/state/overlay.manifest" 2>/dev/null)"
chk 'manifest 三字段' '3' "$(head -n 1 "$TR_DIR/state/overlay.manifest" | awk -F'|' '{print NF}')"
chk 'manifest 目标是假 vendor 路径' 'yes' "$(grep -q "$FAKE" "$TR_DIR/state/overlay.manifest" && echo yes || echo no)"
chk 'magic mount 副本 system/vendor/etc' 'yes' "$([ -f "$MODCOPY/system/vendor/etc/thermal-engine.conf" ] && echo yes || echo no)"
chk 'magic mount 副本 vendor/etc' 'yes' "$([ -f "$MODCOPY/vendor/etc/thermal-engine.conf" ] && echo yes || echo no)"
if cmp -s "$TR_DIR/stock/thermal-engine.conf" "$TR_DIR/patched/thermal-engine.conf"; then
	ng '放宽版应与原厂不同'
else
	ok '放宽版与原厂不同'
fi
chk '放宽版里大核阈值已抬' '1' "$(grep -c 'thresholds 70000 75000 80000' "$TR_DIR/patched/thermal-engine.conf")"

S1=$(tr_sha "$TR_DIR/patched/thermal-engine.conf")
sh "$ROOT/module/tools/gen_overlay.sh" "$MODCOPY" >/dev/null 2>&1
chk '重复运行结果稳定（幂等）' "$S1" "$(tr_sha "$TR_DIR/patched/thermal-engine.conf")"

# 模拟 ROM 升级：原厂配置变了 -> 应重新抓取
sed -i 's/^thresholds 62000 67000/thresholds 61000 66000/' "$FAKE"
sh "$ROOT/module/tools/gen_overlay.sh" "$MODCOPY" >/dev/null 2>&1
chk 'ROM 更新后重新抓取原厂副本' '1' "$(grep -c '^thresholds 61000 66000' "$TR_DIR/stock/thermal-engine.conf")"
chk '放宽版跟随新原厂值' '1' "$(grep -c 'thresholds 69000 74000' "$TR_DIR/patched/thermal-engine.conf")"

# 模拟"overlay 已挂载"：live 文件就是放宽版，原厂副本不能被它污染
S_STOCK=$(tr_sha "$TR_DIR/stock/thermal-engine.conf")
cp -f "$TR_DIR/patched/thermal-engine.conf" "$FAKE"
sh "$ROOT/module/tools/gen_overlay.sh" "$MODCOPY" >/dev/null 2>&1
chk '已放宽状态下不污染原厂副本' "$S_STOCK" "$(tr_sha "$TR_DIR/stock/thermal-engine.conf")"
chk '已放宽状态下 manifest 仍指向同一目标' '1' "$(grep -c "$FAKE" "$TR_DIR/state/overlay.manifest")"

echo
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
