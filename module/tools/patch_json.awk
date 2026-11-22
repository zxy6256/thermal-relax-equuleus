#!/usr/bin/awk -f
# ============================================================================
# patch_json.awk —— QTI Thermal HAL / Android thermal HAL 的 JSON 阈值放宽器（实验性）
#
# 目标文件通常是 /vendor/etc/thermal_info_config.json 一类结构：
#   { "Sensors": [ { "Name": "CPU", "Type": "CPU",
#                    "HotThreshold": [60.0, 75.0],
#                    "VrThreshold":  [58.0, 70.0] } , ... ] }
#
# 用法:
#   awk -v deltaC=8 -v maxC=82 -v safe_re="battery|charger|usb|pa" \
#       -f patch_json.awk thermal_info_config.json > patched.json
#
# 限制（诚实说明）:
#   * 行式处理，只动 "HotThreshold"/"VrThreshold"/"Threshold" 这些键所在行上的数字
#   * 不改变 JSON 结构、不增删键，避免把 HAL 的解析器搞崩
#   * 值 > 1000 视为毫摄氏度（deltaC*1000），否则视为摄氏度
#   * 找不到上述键的文件会原样输出，调用方需用 sha 比对确认"是否真的变了"
# ============================================================================

BEGIN {
	if (deltaC == "") deltaC = 8
	if (maxC == "") maxC = 82
	if (safe_re == "") safe_re = "battery|charger|usb|pa|skin|quiet"
	name = ""
	changed = 0
}

function bump(tok,    v, isfloat) {
	isfloat = (tok ~ /\./) ? 1 : 0
	v = tok + 0
	if (v > 1000) {
		v = v + deltaC * 1000
		if (v > maxC * 1000) v = maxC * 1000
		if (v < 0) v = 0
		return sprintf("%d", v)
	}
	v = v + deltaC
	if (v > maxC) v = maxC
	if (v < 0) v = 0
	if (isfloat) return sprintf("%.1f", v)
	return sprintf("%d", v)
}

function bump_line(line,    out, rest, pre, num) {
	out = ""
	rest = line
	while (match(rest, /-?[0-9]+(\.[0-9]+)?/)) {
		pre = substr(rest, 1, RSTART - 1)
		num = substr(rest, RSTART, RLENGTH)
		out = out pre bump(num)
		rest = substr(rest, RSTART + RLENGTH)
	}
	return out rest
}

{
	# 记录当前对象名，用于安全组判定
	if (match($0, /"Name"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
		name = substr($0, RSTART, RLENGTH)
		sub(/.*"[[:space:]]*:[[:space:]]*"/, "", name)
		sub(/".*/, "", name)
	}

	if ($0 ~ /"[A-Za-z]*Threshold"[[:space:]]*:/ && tolower(name) ~ tolower(safe_re)) {
		print $0
		next
	}

	if ($0 ~ /"[A-Za-z]*Threshold"[[:space:]]*:/) {
		print bump_line($0)
		changed++
		next
	}

	print $0
}
