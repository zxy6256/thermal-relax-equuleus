# ThermalRelax · Mi 8 Pro (equuleus) / SDM845 / LineageOS

放宽 LineageOS 在这台机器上**过于保守的低负载降频**，同时把安全兜底一层不少地留着。

不是"关温控"。是把原厂那条按*体感温度*设计的曲线，改成按*结温*设计，并且给降频设一个
不低于「还能跑满 60fps」的下限 —— 顺带修掉几个让机器"温度不高但一直低频"的脏状态。

```
设备      Xiaomi Mi 8 Pro (equuleus)   SDM845  4×A55 1.766GHz + 4×A75 2.803GHz + Adreno 630
系统      LineageOS (Android 10~14 均可) + Magisk v24+
前提      /vendor 可被 magic mount（Magisk 默认就能），设备已 root
```

## 它到底改了什么

| 层 | 手段 | 效果 |
|---|---|---|
| vendor 温控配置 | `thermal-engine.conf` / `thermal_info_config.json` 的 `thresholds` 整体 +8°C，`action_info` 的频率设下限 | 38°C 就开始压频 → 46°C 才开始；压到底也不低于 1.2GHz(A75) / 1.4GHz(A55) |
| 保护段 | 电池、充电、功放、`shutdown` 段**一行不动** | 过温关机、充电限流、PA 保护全保留 |
| 调度 | `schedutil` rate_limit 20000µs → 5000µs、抬 `hispeed_freq`、大核簇 `core_ctl/min_cpus=2` | 升频决策从 20ms 提前到 5ms；大核簇不再整体掉电，唤醒不抖 |
| GPU | `thermal_pwrlevel=0`、`idle_timer` 110ms、`adrenoboost=1` | 滑动/动画不再因为 GPU 被钉在最低档而掉帧 |
| 脏状态 | 每 60s 巡检 `scaling_max_freq`，温度不高却低于 `cpuinfo_max_freq` 就释放 | 修掉 mitigation 阶梯没复位导致的长尾低频 |
| 兜底 | 看门狗：结温 80°C×2 次 / 86°C / 电池 45°C → 立即回滚原厂并冷却 30 分钟 | 放宽是"临时授权"，不是"永久取消" |

## 三级兜底（放宽之后还剩什么）

```
① 软件看门狗     结温 ≥80°C 连续 2 个周期 / ≥86°C / 电池 ≥45°C  →  回滚原厂配置 + 重启温控服务
② vendor 曲线    原厂 shutdown 段（95/100°C）与充电/电池段一行未改，仍然生效
③ 硬件 LMH       DTB 里的 qcom,lmh-dcvs 与 kernel cooling device，用户态改不动也不该改
```

所以最坏情况不是"烧了"，而是"热到某个点自动回到原厂那套保守曲线"。

## 目录

```
module/                      Magisk 模块本体（打包根）
├── module.prop
├── customize.sh             安装期：抓原厂配置 → 生成放宽版 → 落 overlay
├── post-fs-data.sh          开机早期：重新生成 overlay / bind-mount 兜底 / 释放脏 clamp
├── service.sh               late_start：调度与 GPU 调参 + 看门狗循环
├── uninstall.sh
├── common/
│   ├── util.sh              全部公共函数（sh，mksh/busybox ash 通吃）
│   └── default.conf         用户参数（首次启动复制到 /data/adb/thermal-relax/config.conf）
├── tools/
│   ├── gen_overlay.sh       抓原厂 + 打补丁 + 校验 + 写 manifest + 铺 magic mount 副本
│   ├── patch_conf.awk       thermal-engine.conf 变换器（只改数字，不增删行）
│   └── patch_json.awk       thermal HAL JSON 变换器（实验性）
└── bin/thermalctl           命令行：status / set / apply / stock / diagnose …

docs/
├── 01-架构与温控链路.md      这台机器上温度是怎么变成"降频"的
├── 02-参数取值依据.md        每个数字为什么是这个数
└── 03-安装调试与回滚.md      刷入、验证、调参、回滚

tests/
├── fixtures/thermal-engine.conf   原厂风格样本
└── run_tests.sh                   66 项断言（语法 / 变换 / 安全组跳过 / 幂等 / ROM 更新 / 脏挂载）
```

## 构建

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1   # Windows：测试 + 打包 + 校验
```
```sh
sh build.sh                                            # Linux / WSL / git-bash
```

两条路都做同样三件事：`tests/run_tests.sh`（66 项断言）→ `tools/pack.py`（强制 LF 打包）→
`tools/verify_zip.py`（根目录结构 / 无 CRLF / 关键文件齐全 / 无空文件）。

产物：`dist/ThermalRelax-equuleus-v1.0.0.zip`，Magisk app → 模块 → 从本地安装。

## 安装后

```sh
su -c 'thermalctl status'     # 温度 / 频率 / 档位 / 兜底状态
su -c 'thermalctl diagnose'   # 导出全量诊断到 /sdcard/Download/
su -c 'thermalctl stock'      # 立刻回原厂（不卸载）
su -c 'thermalctl log 60'     # 看日志
```

日志：`/data/adb/thermal-relax/log/thermal-relax.log`

## 已知限制

- 只对 **SDM845 频率表**做了精确取值（大核 1.2GHz / 小核 1.4GHz 下限）。换了平台要按
  `thermalctl diagnose` 的 `cpuinfo_max_freq` 重算 `CPU0_FLOOR_KHZ` / `CPU1_FLOOR_KHZ`。
- 如果 ROM 用 **QTI Thermal HAL + `thermal_info_config.json`**，JSON 变换器只动
  `HotThreshold` / `VrThreshold` 这类键，属于实验性；请拿 `diagnose` 结果核对。
- 如果 ROM 里**没有** `thermal-engine*.conf`（部分 Android 13+ 移植把曲线写进了 HAL 二进制），
  模块只剩 sysfs 层（调度/GPU/clamp），效果会打折 —— 日志里会明确写出来。
- 放宽 = 机身更热。这是把"体感优先"换成"流畅优先"的必然代价，skin 阈值已停在 46~50°C 这个
  手持可接受带上限，不建议继续往上堆。
