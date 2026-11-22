#!/system/bin/sh
# ============================================================================
# ThermalRelax —— Magisk 安装脚本（customize.sh）
# 安装期能读到真实的 /vendor，所以在这里就把原厂温控配置抓下来、生成放宽版，
# 交给 magic mount 在下次开机时顶上（比开机后再 bind-mount 更早、更干净）。
# ============================================================================
SKIPUNZIP=0

ui_print " "
ui_print "  ███ ThermalRelax  ·  Mi 8 Pro (equuleus) / SDM845"
ui_print "  放宽 LineageOS 低负载降频，保留过温兜底"
ui_print " "

[ -f "$MODPATH/module.prop" ] || abort "! module.prop 缺失，安装包结构不对"

DEV=$(getprop ro.product.device)
SOC=$(getprop ro.board.platform)
ui_print "- 设备: ${DEV:-unknown} / 平台: ${SOC:-unknown}"
case "$DEV" in
equuleus | dipper | ursa | sirius | platina) ui_print "- 设备在预期范围内" ;;
*) ui_print "- 注意: 非 Mi8 系列代号，配置会照常生成，但请自行核对 /vendor 路径" ;;
esac
case "$SOC" in
sdm845) ui_print "- SDM845 平台，阈值/频率表按 845 取值" ;;
*) ui_print "- 非 sdm845 平台：频率下限相关设置请按 thermalctl diagnose 结果再调" ;;
esac

[ "$API" -ge 24000 ] 2>/dev/null || ui_print "- 建议 Magisk v24+（需要 magic mount 到 /vendor）"

# ---- 权限 ----
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/tools" 0 0 0755 0755
set_perm "$MODPATH/common/util.sh" 0 0 0644
set_perm "$MODPATH/common/default.conf" 0 0 0644

# ---- 数据目录 ----
mkdir -p /data/adb/thermal-relax/log /data/adb/thermal-relax/state \
	/data/adb/thermal-relax/stock /data/adb/thermal-relax/patched 2>/dev/null

# ---- 抓原厂配置 + 生成放宽版 ----
ui_print "- 扫描 vendor 温控配置…"
sh "$MODPATH/tools/gen_overlay.sh" "$MODPATH"
if [ -s /data/adb/thermal-relax/state/overlay.manifest ]; then
	while IFS='|' read -r d s p; do
		[ -n "$d" ] && ui_print "  ✓ $(basename "$d")"
	done </data/adb/thermal-relax/state/overlay.manifest
	ui_print "- 已生成放宽版配置（开机由 magic mount 顶上）"
else
	ui_print "- 未找到 thermal-engine.conf，仅启用 sysfs/调度层放宽"
	ui_print "  请用 thermalctl diagnose 导出信息后按需适配"
fi

# ---- /system/bin/thermalctl 命令行 ----
mkdir -p "$MODPATH/system/bin" 2>/dev/null
cat >"$MODPATH/system/bin/thermalctl" <<'EOS'
#!/system/bin/sh
for d in /data/adb/modules/thermal_relax_equuleus /data/adb/modules_update/thermal_relax_equuleus; do
	[ -f "$d/bin/thermalctl" ] && exec sh "$d/bin/thermalctl" "$@"
done
echo "thermalctl: 模块目录未找到（未安装或已禁用）"
exit 1
EOS
set_perm "$MODPATH/system/bin/thermalctl" 0 0 0755

ui_print " "
ui_print "- 核心策略：阈值 +8°C / 大核降频下限 1.2GHz / 释放脏 clamp / schedutil 提速"
ui_print "- 兜底：结温 80°C×2 或 86°C、电池 45°C -> 自动回滚原厂并冷却 30 分钟"
ui_print "- 命令行：thermalctl status | diagnose | stock | apply"
ui_print "- 重启生效"
ui_print " "
