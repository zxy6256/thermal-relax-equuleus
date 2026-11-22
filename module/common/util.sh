#!/system/bin/sh
# ============================================================================
# ThermalRelax for Mi 8 Pro (equuleus / SDM845) on LineageOS
# common/util.sh —— 公共函数库，被 post-fs-data.sh / service.sh / bin/thermalctl 引入
# 约定：所有函数前缀 tr_，全部 POSIX sh（mksh / busybox ash 均可用）
# ============================================================================

TR_DIR=${TR_DIR:-/data/adb/thermal-relax}
TR_LOG=$TR_DIR/log/thermal-relax.log
TR_STATE=$TR_DIR/state
TR_STOCK=$TR_DIR/stock
TR_PATCHED=$TR_DIR/patched
TR_MANIFEST=$TR_STATE/overlay.manifest
TR_PROFILE_FILE=$TR_STATE/profile
TR_PIDFILE=$TR_STATE/watchdog.pid

# ---------------------------------------------------------------------------
# 基础设施
# ---------------------------------------------------------------------------
tr_ensure_dirs() {
	[ -d "$TR_DIR/log" ] || mkdir -p "$TR_DIR/log" 2>/dev/null
	[ -d "$TR_STATE" ] || mkdir -p "$TR_STATE" 2>/dev/null
	[ -d "$TR_STOCK" ] || mkdir -p "$TR_STOCK" 2>/dev/null
	[ -d "$TR_PATCHED" ] || mkdir -p "$TR_PATCHED" 2>/dev/null
	return 0
}

tr_now() { date '+%Y-%m-%d %H:%M:%S'; }

tr_log() {
	tr_ensure_dirs
	printf '%s %s\n' "$(tr_now)" "$*" >>"$TR_LOG" 2>/dev/null
	log -t ThermalRelax "$*" 2>/dev/null
	return 0
}

# 每个 boot 只记一次，避免日志被巡检刷爆
tr_log_once() {
	tr_ensure_dirs
	_k=$TR_STATE/once.$1
	[ -f "$_k" ] && return 0
	: >"$_k" 2>/dev/null
	shift
	tr_log "$@"
}

# ---------------------------------------------------------------------------
# 配置读取（只认 KEY=VALUE，不 source，避免把配置里的任意代码执行进来）
# ---------------------------------------------------------------------------
tr_cfg_init() {
	[ -f "$TR_DIR/config.conf" ] && return 0
	[ -f "$MODDIR/common/default.conf" ] || return 1
	cp -f "$MODDIR/common/default.conf" "$TR_DIR/config.conf" 2>/dev/null || return 1
	tr_log "已生成默认配置: $TR_DIR/config.conf"
	return 0
}

tr_cfg() { # tr_cfg KEY DEFAULT
	_key=$1
	_def=$2
	_val=''
	if [ -f "$TR_DIR/config.conf" ]; then
		_val=$(sed -n "s/^[[:space:]]*${_key}[[:space:]]*=[[:space:]]*//p" "$TR_DIR/config.conf" 2>/dev/null | tail -n 1)
		_val=$(printf '%s' "$_val" | sed 's/#.*$//; s/[[:space:]]*$//')
	fi
	if [ -z "$_val" ]; then printf '%s' "$_def"; else printf '%s' "$_val"; fi
}

tr_cfg_set() { # tr_cfg_set KEY VALUE
	_key=$1
	_val=$2
	tr_cfg_init
	[ -f "$TR_DIR/config.conf" ] || return 1
	if grep -q "^[[:space:]]*${_key}[[:space:]]*=" "$TR_DIR/config.conf" 2>/dev/null; then
		sed -i "s|^[[:space:]]*${_key}[[:space:]]*=.*|${_key}=${_val}|" "$TR_DIR/config.conf"
	else
		printf '%s=%s\n' "$_key" "$_val" >>"$TR_DIR/config.conf"
	fi
	return 0
}

tr_profile() {
	_p=''
	[ -f "$TR_PROFILE_FILE" ] && _p=$(cat "$TR_PROFILE_FILE" 2>/dev/null)
	if [ -z "$_p" ]; then _p=$(tr_cfg PROFILE relaxed); fi
	printf '%s' "$_p"
}

tr_set_profile() {
	tr_ensure_dirs
	printf '%s\n' "$1" >"$TR_PROFILE_FILE" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# 温度读取
# ---------------------------------------------------------------------------
tr_temp_mc() { # <温度文件绝对路径，比如 /sys/class/thermal/thermal_zone3/temp> -> 毫摄氏度
	_f=$1
	[ -r "$_f" ] || return 1
	_v=$(cat "$_f" 2>/dev/null)
	[ -n "$_v" ] || return 1
	_neg=0
	case "$_v" in -*) _neg=1; _v=${_v#-} ;; esac
	case "$_v" in *[!0-9]*) return 1 ;; esac
	[ "$_v" -lt 1000 ] && _v=$((_v * 1000))
	if [ "$_neg" = 1 ]; then _v=$((0 - _v)); fi
	printf '%s' "$_v"
}

# 受保护的 zone 清单（type 白名单）。电池/充电单独走 tr_batt_mc
tr_zone_list() {
	tr_ensure_dirs
	: >"$TR_STATE/zones.list" 2>/dev/null
	for _z in /sys/class/thermal/thermal_zone*; do
		[ -d "$_z" ] || continue
		_t=$(cat "$_z/type" 2>/dev/null) || continue
		case "$_t" in
		*-usr | gpu* | cpu-* | quiet* | xo* | pop_mem | apc* | msm-* | soc* | sde* | camera*)
			printf '%s|%s\n' "$_z" "$_t" >>"$TR_STATE/zones.list" 2>/dev/null
			;;
		esac
	done
	return 0
}

# 输出 "最高温毫摄氏度 zone类型"
tr_hot_state() {
	_max=0
	_name=none
	tr_zone_list
	if [ -s "$TR_STATE/zones.list" ]; then
		while IFS='|' read -r _p _t; do
			[ -n "$_p" ] || continue
			_v=$(tr_temp_mc "$_p/temp") || continue
			if [ "$_v" -gt "$_max" ]; then
				_max=$_v
				_name=$_t
			fi
		done <"$TR_STATE/zones.list"
	fi
	printf '%s %s\n' "$_max" "$_name"
}

tr_zone_temp_of() { # tr_zone_temp_of cpu-1-0-usr -> 毫摄氏度
	_want=$1
	tr_zone_list
	while IFS='|' read -r _p _t; do
		[ "$_t" = "$_want" ] || continue
		tr_temp_mc "$_p/temp"
		return 0
	done <"$TR_STATE/zones.list"
	return 1
}

tr_batt_mc() {
	tr_zone_list
	while IFS='|' read -r _p _t; do
		case "$_t" in batt* | *battery*) tr_temp_mc "$_p/temp"; return 0 ;; esac
	done <"$TR_STATE/zones.list"
	# 部分机型没有 battery zone，退回 power_supply
	[ -r /sys/class/power_supply/battery/temp ] && tr_temp_mc /sys/class/power_supply/battery/temp
	return 0
}

# ---------------------------------------------------------------------------
# 温控服务（thermal-engine / QTI thermal HAL）
# ---------------------------------------------------------------------------
tr_thermal_service() {
	for _f in /vendor/etc/init/*thermal*.rc \
		/vendor/etc/init/hw/*thermal*.rc \
		/system/etc/init/*thermal*.rc \
		/system_ext/etc/init/*thermal*.rc; do
		[ -f "$_f" ] || continue
		sed -n 's/^service[[:space:]][[:space:]]*\([^[:space:]]*\).*/\1/p' "$_f" 2>/dev/null
	done | sort -u
}

tr_thermal_service_running() {
	for _s in $(tr_thermal_service); do
		[ -n "$(pidof "$_s" 2>/dev/null)" ] && return 0
	done
	[ -n "$(pidof thermal-engine 2>/dev/null)" ] && return 0
	return 1
}

tr_restart_thermal() {
	_svcs=$(tr_thermal_service)
	if [ -z "$_svcs" ]; then
		tr_log "未找到温控服务定义，直接结束 thermal-engine 进程"
		pkill -f thermal-engine 2>/dev/null
		pkill -f thermal-service 2>/dev/null
		return 0
	fi
	for _s in $_svcs; do
		setprop ctl.restart "$_s" 2>/dev/null
		tr_log "已重启温控服务: $_s"
	done
	return 0
}

# ---------------------------------------------------------------------------
# 配置文件热替换
#   manifest 每行: <目标绝对路径>|<原厂sha256>|<放宽后sha256>
#   放宽后的文件统一放在 $TR_PATCHED/$(basename 目标)
# ---------------------------------------------------------------------------
tr_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# 把放宽后的配置顶到 live 路径上（magic mount 没接住时的兜底；也可运行时切换）
tr_live_apply() {
	[ -f "$TR_MANIFEST" ] || return 1
	tr_ensure_dirs
	_n=0
	while IFS='|' read -r _dst _sha_stock _sha_patch; do
		[ -n "$_dst" ] || continue
		_p=$TR_PATCHED/$(basename "$_dst")
		[ -f "$_p" ] || continue
		[ -f "$_dst" ] || continue
		_cur=$(tr_sha "$_dst")
		if [ "$_cur" = "$_sha_patch" ]; then continue; fi
		# bind mount 后 SELinux 上下文跟 inode 走，先按 vendor 配置文件的类型标注
		chcon u:object_r:vendor_configs_file:s0 "$_p" 2>/dev/null
		if mount --bind "$_p" "$_dst" 2>/dev/null; then
			_n=$((_n + 1))
			tr_log "bind-mount 生效: $_dst"
		else
			# 每 boot 每个目标只记一次失败，避免看门狗把日志刷爆
			tr_log_once "bindfail.$(basename "$_dst")" "bind-mount 失败(只读/SELinux): $_dst"
		fi
	done <"$TR_MANIFEST"
	if [ "$_n" -gt 0 ]; then tr_restart_thermal; fi
	return 0
}

# 回滚到原厂配置（bind 原厂副本；magic mount 之上再 bind 一层，立即生效）
tr_restore_stock() {
	[ -f "$TR_MANIFEST" ] || return 1
	_n=0
	while IFS='|' read -r _dst _sha_stock _sha_patch; do
		[ -n "$_dst" ] || continue
		_o=$TR_STOCK/$(basename "$_dst")
		[ -f "$_o" ] || continue
		umount "$_dst" 2>/dev/null
		chcon u:object_r:vendor_configs_file:s0 "$_o" 2>/dev/null
		if mount --bind "$_o" "$_dst" 2>/dev/null; then
			_n=$((_n + 1))
		fi
		tr_log "恢复原厂配置: $_dst"
	done <"$TR_MANIFEST"
	if [ "$_n" -gt 0 ]; then tr_restart_thermal; fi
	return 0
}

# ---------------------------------------------------------------------------
# 调度 / GPU / boost
# ---------------------------------------------------------------------------
tr_release_clamp() { # 释放"温度不高但 max_freq 被压死"的脏 clamp
	_hi=$(tr_cfg GUARD_COOL_MC 55000)
	_hot=$(tr_hot_state | cut -d' ' -f1)
	if [ -n "$_hot" ] && [ "$_hot" -ge "$_hi" ]; then
		# 热的时候不释放，是设计如此；不刷日志
		return 0
	fi
	_n=0
	for _p in /sys/devices/system/cpu/cpufreq/policy*; do
		[ -d "$_p" ] || continue
		_mx=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null) || continue
		_cur=$(cat "$_p/scaling_max_freq" 2>/dev/null) || continue
		case "$_mx" in '' | *[!0-9]*) continue ;; esac
		case "$_cur" in '' | *[!0-9]*) continue ;; esac
		if [ "$_cur" -lt "$_mx" ]; then
			if printf '%s\n' "$_mx" >"$_p/scaling_max_freq" 2>/dev/null; then
				_n=$((_n + 1))
				tr_log "释放 clamp: $(basename "$_p") $_cur -> $_mx kHz"
			fi
		fi
	done
	[ "$_n" -gt 0 ] && tr_log "共释放 $_n 个策略的 max_freq clamp"
	return 0
}

tr_perf_tune() {
	_rate=$(tr_cfg SCHEDUTIL_RATE_US 5000)
	for _p in /sys/devices/system/cpu/cpufreq/policy*; do
		[ -d "$_p" ] || continue
		_pol=$(basename "$_p" | sed 's/policy//')
		[ -w "$_p/schedutil/rate_limit_us" ] && printf '%s\n' "$_rate" >"$_p/schedutil/rate_limit_us" 2>/dev/null
		[ -w "$_p/schedutil/up_rate_limit_us" ] && printf '%s\n' "$_rate" >"$_p/schedutil/up_rate_limit_us" 2>/dev/null
		[ -w "$_p/schedutil/down_rate_limit_us" ] && printf '%s\n' $((_rate * 4)) >"$_p/schedutil/down_rate_limit_us" 2>/dev/null
		_hs=$(tr_cfg "HISPEED_POLICY${_pol}" '')
		if [ -n "$_hs" ] && [ -w "$_p/schedutil/hispeed_freq" ]; then
			printf '%s\n' "$_hs" >"$_p/schedutil/hispeed_freq" 2>/dev/null
		fi
	done

	# 大核簇最少在线核心数：避免 cluster power collapse 造成的唤醒抖动
	_min=$(tr_cfg CORE_CTL_MIN_BIG 2)
	for _c in /sys/devices/system/cpu/cpu[4-7]/core_ctl; do
		[ -d "$_c" ] || continue
		[ -w "$_c/min_cpus" ] && printf '%s\n' "$_min" >"$_c/min_cpus" 2>/dev/null
	done

	# GPU：解除 thermal_pwrlevel 压制，抬高 idle 停留，开轻度 adrenoboost
	_k=/sys/class/kgsl/kgsl-3d0
	if [ -d "$_k" ]; then
		[ -w "$_k/thermal_pwrlevel" ] && printf '0\n' >"$_k/thermal_pwrlevel" 2>/dev/null
		[ -w "$_k/idle_timer" ] && printf '%s\n' "$(tr_cfg GPU_IDLE_TIMER_MS 110)" >"$_k/idle_timer" 2>/dev/null
		[ -w "$_k/devfreq/adrenoboost" ] && printf '%s\n' "$(tr_cfg GPU_ADRENOBOOST 1)" >"$_k/devfreq/adrenoboost" 2>/dev/null
	fi

	# 输入 boost（内核里带 cpu_boost 模块的 ROM 才有）
	_ib=$(tr_cfg INPUT_BOOST_MS 500)
	if [ -d /sys/module/cpu_boost/parameters ] && [ "$_ib" -gt 0 ]; then
		[ -w /sys/module/cpu_boost/parameters/input_boost_ms ] &&
			printf '%s\n' "$_ib" >/sys/module/cpu_boost/parameters/input_boost_ms 2>/dev/null
	fi
	return 0
}

# 一次性把"放宽"这一侧全部铺上去
tr_apply_relaxed() {
	tr_set_profile relaxed
	tr_live_apply
	tr_perf_tune
	tr_release_clamp
	tr_log "已应用 relaxed 档"
	return 0
}

tr_apply_stock() {
	tr_set_profile stock
	tr_restore_stock
	tr_log "已回到 stock 档（原厂温控）"
	return 0
}
