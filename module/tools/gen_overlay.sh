#!/system/bin/sh
# ============================================================================
# gen_overlay.sh —— 抓原厂温控配置 + 生成放宽版 + 落 overlay/manifest
#
# 调用:  sh tools/gen_overlay.sh [MODDIR]
# 时机:  安装期（customize.sh）和每次开机（post-fs-data.sh）各跑一次
#
# 产物:
#   /data/adb/thermal-relax/stock/<name>     原厂副本（只在第一次或 ROM 更新后落盘）
#   /data/adb/thermal-relax/patched/<name>   放宽版（bind-mount 的源）
#   /data/adb/thermal-relax/state/overlay.manifest
#       每行: <live 绝对路径>|<原厂 sha256>|<放宽版 sha256>
#   $MODDIR/system/vendor/etc/<name>         喂给 Magisk magic mount 的副本
#   $MODDIR/vendor/etc/<name>                同上（不同 Magisk 版本的 vendor 挂载点差异）
# ============================================================================

MODDIR=${1:-${MODDIR:-}}
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || {
	echo "gen_overlay: MODDIR 无效: '$MODDIR'" >&2
	exit 1
}

SETD=$(dirname "$0")
. "$SETD/../common/util.sh"

tr_ensure_dirs
tr_cfg_init

DELTA=$(tr_cfg DELTA_MC 8000)
MAXC=$(tr_cfg MAX_MC 84000)
F0=$(tr_cfg CPU0_FLOOR_KHZ 1401600)
F1=$(tr_cfg CPU1_FLOOR_KHZ 1209600)
GF=$(tr_cfg GPU_FLOOR_HZ 0)
HP=$(tr_cfg HOTPLUG_RELAX 1)
SAFE=$(tr_cfg SAFE_SENSORS 'batt|ibat|vbat|chg|usb|pa-therm|pa_therm|pm8|pm_|bcl|smb')
JDELTA=$((DELTA / 1000))
JMAX=$((MAXC / 1000))

NEWMAN=$TR_STATE/overlay.manifest.new
: >"$NEWMAN" 2>/dev/null
COUNT=0

# 同一个目标可能同时出现在 /vendor 和 /system/vendor（符号链接），去重
# TR_VENDOR_ROOT 仅用于主机侧测试（把 /vendor 换成一个假根目录），设备上保持为空
SEEN=''
V=${TR_VENDOR_ROOT:-}

for SRC in $V/vendor/etc/thermal-engine*.conf \
	$V/system/vendor/etc/thermal-engine*.conf \
	$V/vendor/etc/thermal_info_config.json \
	$V/vendor/etc/thermal*config*.json \
	$V/system/vendor/etc/thermal*config*.json; do
	[ -f "$SRC" ] || continue
	REAL=$(readlink -f "$SRC" 2>/dev/null)
	[ -n "$REAL" ] && [ -f "$REAL" ] && SRC=$REAL
	case " $SEEN " in *" $SRC "*) continue ;; esac
	SEEN="$SEEN $SRC"

	NAME=$(basename "$SRC")
	STOCK=$TR_STOCK/$NAME
	PATCHED=$TR_PATCHED/$NAME
	LIVE_SHA=$(tr_sha "$SRC")
	PREV_SHA=$(grep -F "/$NAME|" "$TR_MANIFEST" 2>/dev/null | head -n 1 | cut -d'|' -f3)

	# ---- 1. 抓原厂副本 ----
	if [ ! -f "$STOCK" ]; then
		if cp -f "$SRC" "$STOCK" 2>/dev/null; then
			chmod 0644 "$STOCK" 2>/dev/null
			tr_log "抓取原厂配置: $SRC -> $STOCK"
		else
			tr_log "无法抓取原厂配置: $SRC"
			continue
		fi
	elif [ "$LIVE_SHA" != "$(tr_sha "$STOCK")" ] && [ "$LIVE_SHA" != "$PREV_SHA" ]; then
		# ROM 升级换了配置：重新抓（此刻 live 既不是原厂副本也不是我们上一次的产物）
		if cp -f "$SRC" "$STOCK" 2>/dev/null; then
			chmod 0644 "$STOCK" 2>/dev/null
			tr_log "检测到原厂配置更新，重新抓取: $NAME"
		fi
	fi

	# ---- 2. 生成放宽版 ----
	case "$NAME" in
	*.json)
		awk -v deltaC="$JDELTA" -v maxC="$JMAX" -v safe_re="$SAFE" \
			-f "$SETD/patch_json.awk" "$STOCK" >"$PATCHED.tmp" 2>/dev/null
		KIND=json
		;;
	*)
		awk -v delta="$DELTA" -v maxc="$MAXC" \
			-v floor0="$F0" -v floor1="$F1" \
			-v hotplug_relax="$HP" -v gpu_floor="$GF" \
			-v safe_re="$SAFE" \
			-f "$SETD/patch_conf.awk" "$STOCK" >"$PATCHED.tmp" 2>/dev/null
		KIND=conf
		;;
	esac

	# ---- 3. 校验：不通过就宁可不动 ----
	OK=1
	[ -s "$PATCHED.tmp" ] || OK=0
	if [ "$OK" = 1 ]; then
		[ "$(grep -c . "$PATCHED.tmp" 2>/dev/null)" = "$(grep -c . "$STOCK" 2>/dev/null)" ] || OK=0
	fi
	if [ "$OK" = 1 ] && [ "$KIND" = conf ]; then
		[ "$(grep -c '^[[:space:]]*\[' "$PATCHED.tmp" 2>/dev/null)" = \
			"$(grep -c '^[[:space:]]*\[' "$STOCK" 2>/dev/null)" ] || OK=0
	fi
	if [ "$OK" = 1 ] && [ "$(tr_sha "$PATCHED.tmp")" = "$(tr_sha "$STOCK")" ]; then
		tr_log "配置未被改动（没有可放宽的键）: $NAME"
		OK=0
	fi
	if [ "$OK" != 1 ]; then
		tr_log "放宽版校验失败，保持原厂配置: $NAME"
		rm -f "$PATCHED.tmp" 2>/dev/null
		continue
	fi

	mv -f "$PATCHED.tmp" "$PATCHED" 2>/dev/null
	chmod 0644 "$PATCHED" 2>/dev/null
	PSHA=$(tr_sha "$PATCHED")
	SSHA=$(tr_sha "$STOCK")

	# ---- 4. 铺到模块目录，交给 magic mount ----
	for D in "$MODDIR/system/vendor/etc" "$MODDIR/vendor/etc"; do
		mkdir -p "$D" 2>/dev/null
		cp -f "$PATCHED" "$D/$NAME" 2>/dev/null
		chmod 0644 "$D/$NAME" 2>/dev/null
	done

	printf '%s|%s|%s\n' "$SRC" "$SSHA" "$PSHA" >>"$NEWMAN"
	COUNT=$((COUNT + 1))
	tr_log "已生成放宽版: $NAME ($KIND) stock=$SSHA patched=$PSHA"
done

if [ "$COUNT" -gt 0 ]; then
	mv -f "$NEWMAN" "$TR_MANIFEST" 2>/dev/null
	chmod 0644 "$TR_MANIFEST" 2>/dev/null
	tr_log "manifest 已更新，共 $COUNT 个温控配置文件"
else
	rm -f "$NEWMAN" 2>/dev/null
	if [ ! -s "$TR_MANIFEST" ]; then
		tr_log "未发现可放宽的 vendor 温控配置（ROM 可能用 AIDL HAL 内建曲线），仅应用 sysfs 层"
	fi
fi

exit 0
