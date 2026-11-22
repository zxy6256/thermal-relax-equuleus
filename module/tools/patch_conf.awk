#!/usr/bin/awk -f
# ============================================================================
# patch_conf.awk —— vendor thermal-engine.conf 的阈值/降频下限放宽器
#
# 用法:
#   awk -v delta=8000 -v maxc=84000 -v clrmargin=3000 \
#       -v floor0=1401600 -v floor1=1209600 \
#       -v hotplug_relax=1 -v gpu_floor=0 \
#       -v safe_re="batt|ibat|vbat|chg" \
#       -f patch_conf.awk thermal-engine.conf > patched.conf
#
# 设计原则（每一条都是为了不把 vendor 解析器搞崩）:
#   1. 只改数字，不增删行、不加注释、不改段名，段序保持原样
#   2. 安全组（电池/充电/功放/BCL）整段原样输出
#   3. actions 含 shutdown / trip / watchdog / limits 的段整段原样输出
#   4. thresholds 只上抬（+delta，上限 maxc），thresholds_clr 同步上抬，避免"抬了阈值
#      但清阈值没抬"导致 mitigation 抖振
#   5. action_info: 频率值(kHz)设下限；热插拔的关核数默认压到最多 1，最后一档保持原样
# ============================================================================

BEGIN {
	if (delta == "") delta = 8000
	if (maxc == "") maxc = 84000
	if (clrmargin == "") clrmargin = 3000
	if (floor0 == "") floor0 = 1401600
	if (floor1 == "") floor1 = 1209600
	if (hotplug_relax == "") hotplug_relax = 1
	if (gpu_floor == "") gpu_floor = 0
	if (safe_re == "") safe_re = "batt|ibat|vbat|chg|usb|pa-therm|pa_therm|pm8|pm_|bcl|smb"
	nsec = 0
	changed = 0
	skipped = 0
}

function trim(s) {
	sub(/^[[:space:]]+/, "", s)
	sub(/[[:space:]]+$/, "", s)
	return s
}

function isnum(s) {
	if (s == "") return 0
	return (s ~ /^-?[0-9]+$/) ? 1 : 0
}

# min(s+delta, cap) —— 单调不减，所以不会把升序的阈值表打乱
function addn(s, cap) {
	if (!isnum(s)) return s
	if (s + 0 == 0) return "0" # 0 是"不清阈值"的哨兵值，别动
	v = s + delta
	if (cap + 0 > 0 && v > cap) v = cap
	if (v < 0) v = 0
	return sprintf("%d", v)
}

function floored(s, fl) {
	if (!isnum(s)) return s
	if (fl + 0 <= 0) return s
	if (s + 0 < fl + 0) return sprintf("%d", fl)
	return s
}

# 段头？
function is_header(line) {
	return (line ~ /^[[:space:]]*\[[^]]*\][[:space:]]*$/) ? 1 : 0
}

function flush(    i, line, n, t, key, out, k, v, sens, acts, cluster, fl, mode) {
	if (nsec == 0) return

	# 先扫全段，拿 sensor / actions / desc
	sens = ""
	acts = ""
	for (i = 1; i <= nsec; i++) {
		line = trim(sec[i])
		n = split(line, t, /[[:space:]]+/)
		if (n >= 2 && t[1] == "sensor") {
			for (k = 2; k <= n; k++) sens = sens " " t[k]
		}
		if (n >= 2 && t[1] == "actions") {
			acts = ""
			for (k = 2; k <= n; k++) acts = acts " " t[k]
		}
	}

	mode = 0
	if (sens ~ safe_re) mode = 1                     # 安全组：原样
	if (acts ~ /(shutdown|trip|watchdog|limits)/) mode = 2  # 保护动作：原样

	if (mode != 0) {
		for (i = 1; i <= nsec; i++) print sec[i]
		skipped++
		reset()
		return
	}

	cluster = (sens ~ /cpu-1/) ? 1 : 0
	fl = (cluster == 1) ? floor1 : floor0

	for (i = 1; i <= nsec; i++) {
		line = sec[i]
		n = split(trim(line), t, /[[:space:]]+/)
		if (n < 1) {
			print line
			continue
		}
		key = t[1]

		if (key == "thresholds" || key == "thresholds_clr") {
			# 清阈值比触发阈值多让出一段，避免两列一起被 maxc 截断后撞在一起导致抖振
			cap = (key == "thresholds_clr") ? (maxc - clrmargin) : maxc
			out = "  " key
			for (k = 2; k <= n; k++) out = out " " addn(t[k], cap)
			print out
			changed++
			continue
		}

		if (key == "action_info") {
			out = "  " key
			for (k = 2; k <= n; k++) {
				v = t[k]
				if (acts ~ /hotplug/) {
					# 关核数：前几档最多 1，最后一档保留原样（真正的过温兜底）
					if (hotplug_relax == 1 && isnum(v) && k < n && v + 0 > 1) v = "1"
				} else if (acts ~ /gpu/) {
					if (gpu_floor + 0 > 0 && isnum(v) && v + 0 >= 1000000) v = floored(v, gpu_floor)
				} else if (acts ~ /cpu/) {
					if (isnum(v) && v + 0 >= 100000) v = floored(v, fl)
				}
				out = out " " v
			}
			print out
			changed++
			continue
		}

		print line
	}

	reset()
}

function reset() {
	delete sec
	nsec = 0
}

{
	if (is_header($0)) {
		flush()
		sec[++nsec] = $0
		next
	}
	sec[++nsec] = $0
}

END {
	flush()
}
