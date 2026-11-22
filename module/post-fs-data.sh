#!/system/bin/sh
# ============================================================================
# ThermalRelax —— post-fs-data 阶段
# 这个阶段 /vendor 已经挂好、magic mount 已经生效、系统服务还没起；
# 温控服务（class core）要等 on boot 才启动，所以配置在这里顶上去最安全。
# ============================================================================
MODDIR=${0%/*}
[ -f "$MODDIR/common/util.sh" ] || exit 0
. "$MODDIR/common/util.sh"

tr_ensure_dirs
tr_cfg_init

VER=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
tr_log "=== post-fs-data: ThermalRelax ${VER:-?} 启动 ==="

# 1. 抓原厂配置 + 生成放宽版（ROM 更新后会自动重新抓）
sh "$MODDIR/tools/gen_overlay.sh" "$MODDIR"

# 2. magic mount 没接住的话（live sha 与放宽版不一致）用 bind-mount 兜底
tr_live_apply

# 3. 释放开机时残留的脏 clamp（此时 HAL 还未起，设了就是设了）
tr_release_clamp

# 4. 记录一次环境快照，方便事后核对
{
	printf 'device=%s\n' "$(getprop ro.product.device)"
	printf 'lineage=%s\n' "$(getprop ro.lineage.version)$(getprop ro.modversion)"
	printf 'build=%s\n' "$(getprop ro.build.display.id)"
	printf 'thermal_svc=%s\n' "$(tr_thermal_service | tr '\n' ' ')"
	printf 'profile=%s\n' "$(tr_profile)"
	printf 'hal_running=%s\n' "$(tr_thermal_service_running && echo yes || echo no)"
} >"$TR_STATE/env.snapshot" 2>/dev/null

exit 0
