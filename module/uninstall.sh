#!/system/bin/sh
# ============================================================================
# ThermalRelax —— 卸载脚本
# 停掉看门狗、清掉运行态，保留 log/ 与 stock/（原厂配置副本，便于事后核对）
# ============================================================================
if [ -f /data/adb/thermal-relax/state/watchdog.pid ]; then
	_pid=$(cat /data/adb/thermal-relax/state/watchdog.pid 2>/dev/null)
	case "$_pid" in
	'' | *[!0-9]*) ;;
	*) kill "$_pid" 2>/dev/null ;;
	esac
fi
pkill -f 'thermal-relax/bin' 2>/dev/null
pkill -f 'thermal_relax_equuleus/service.sh' 2>/dev/null

rm -rf /data/adb/thermal-relax/state 2>/dev/null
rm -rf /data/adb/thermal-relax/patched 2>/dev/null
rm -f /data/adb/thermal-relax/config.conf 2>/dev/null

echo "ThermalRelax 已卸载：bind-mount 随模块目录消失一并失效，重启后回到原厂温控"
echo "日志与原厂配置副本保留在 /data/adb/thermal-relax/{log,stock}"
