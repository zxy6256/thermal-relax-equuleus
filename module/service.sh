#!/system/bin/sh
# ============================================================================
# ThermalRelax —— late_start service（开机后在后台常驻）
#   1) 等 boot_completed，铺调度/GPU/boost 参数
#   2) 看门狗：常态维持 relaxed；过温/电池超限 -> 回滚原厂并冷却；温度回落 -> 重新放宽
# ============================================================================
MODDIR=${0%/*}
[ -f "$MODDIR/common/util.sh" ] || exit 0
. "$MODDIR/common/util.sh"

tr_ensure_dirs
tr_cfg_init

# ---- 等开机完成（最多 180s） ----
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 180 ]; do
	sleep 1
	i=$((i + 1))
done
sleep 10

# ---- 单实例 ----
if [ -f "$TR_PIDFILE" ]; then
	_old=$(cat "$TR_PIDFILE" 2>/dev/null)
	case "$_old" in
	'' | *[!0-9]*) ;;
	*)
		if [ "$_old" != "$$" ] && kill -0 "$_old" 2>/dev/null; then
			tr_log "结束上一个 watchdog (pid=$_old)"
			kill "$_old" 2>/dev/null
			sleep 2
		fi
		;;
	esac
fi
printf '%s\n' "$$" >"$TR_PIDFILE" 2>/dev/null

HOT=$(tr_cfg GUARD_HOT_MC 80000)
CRIT=$(tr_cfg GUARD_CRIT_MC 86000)
BATT=$(tr_cfg BATT_HOT_MC 45000)
COOL=$(tr_cfg GUARD_COOL_MC 55000)
POLL=$(tr_cfg POLL_SEC 10)
COOLDOWN=$(tr_cfg COOLDOWN_SEC 1800)
case "$POLL" in '' | *[!0-9]* | 0) POLL=10 ;; esac
case "$COOLDOWN" in '' | *[!0-9]*) COOLDOWN=1800 ;; esac

tr_log "watchdog 启动 (pid=$$, poll=${POLL}s, hot=${HOT}mC, crit=${CRIT}mC, batt=${BATT}mC)"

# ---- 首轮：铺参数 ----
tr_perf_tune
if [ "$(tr_profile)" = stock ]; then
	tr_restore_stock
	tr_log "当前为 stock 档，不应用放宽"
else
	tr_live_apply
	tr_release_clamp
fi

hot_hits=0
cool_hits=0
cooldown_until=0
last_apply=0
last_release=0
last_perf=0
cool_need=$((60 / POLL))
[ "$cool_need" -lt 2 ] && cool_need=2

while :; do
	[ -d "$MODDIR" ] || break # 模块被删/禁用就退场
	now=$(date +%s 2>/dev/null) || now=0
	set -- $(tr_hot_state)
	maxtemp=${1:-0}
	zone=${2:-none}
	case "$maxtemp" in '' | *[!0-9]*) maxtemp=0 ;; esac
	bt=$(tr_batt_mc)
	case "$bt" in '' | *[!0-9]*) bt=0 ;; esac
	prof=$(tr_profile)

	printf '%s %s %s %s\n' "$now" "$maxtemp" "$bt" "$prof" >"$TR_STATE/heartbeat" 2>/dev/null

	# ---------------- 安全阀 ----------------
	guard=0
	reason=''
	if [ "$bt" -ge "$BATT" ]; then
		guard=1
		reason="电池 ${bt}mC >= ${BATT}mC"
	fi
	if [ "$maxtemp" -ge "$CRIT" ]; then
		guard=1
		reason="结温 ${maxtemp}mC >= crit ${CRIT}mC (${zone})"
	fi
	if [ "$maxtemp" -ge "$HOT" ]; then
		hot_hits=$((hot_hits + 1))
		if [ "$hot_hits" -ge 2 ]; then
			guard=1
			reason="结温 ${maxtemp}mC 持续 >= hot ${HOT}mC (${zone})"
		fi
	else
		hot_hits=0
	fi

	if [ "$guard" = 1 ]; then
		tr_log "【兜底】${reason} → 回滚原厂配置，冷却 ${COOLDOWN}s"
		tr_restore_stock
		cooldown_until=$((now + COOLDOWN))
		hot_hits=0
		cool_hits=0
		sleep "$POLL"
		continue
	fi

	# ---------------- 冷却期：只观察 ----------------
	if [ "$now" -lt "$cooldown_until" ]; then
		if [ "$maxtemp" -lt "$COOL" ]; then
			cool_hits=$((cool_hits + 1))
		else
			cool_hits=0
		fi
		if [ "$cool_hits" -ge "$cool_need" ]; then
			cooldown_until=0
			cool_hits=0
			last_apply=0
			tr_log "温度回落稳定（${maxtemp}mC < ${COOL}mC），重新放宽"
		fi
		sleep "$POLL"
		continue
	fi

	# ---------------- 常态：维持 relaxed ----------------
	if [ "$prof" != "relaxed" ]; then
		sleep "$POLL"
		continue
	fi
	if [ $((now - last_apply)) -ge 60 ]; then
		tr_live_apply
		last_apply=$now
	fi
	if [ $((now - last_release)) -ge 60 ]; then
		tr_release_clamp
		last_release=$now
	fi
	# GPU/boost 可能被 vendor 曲线或框架重新写回去，5 分钟复检一次
	if [ $((now - last_perf)) -ge 300 ]; then
		tr_perf_tune
		last_perf=$now
	fi

	sleep "$POLL"
done

rm -f "$TR_PIDFILE" 2>/dev/null
tr_log "watchdog 退出"
exit 0
