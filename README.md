# insulation
阻止温度过高导致的降频

## 功能

### 防降频（原版功能）
- 修改 `/System/Library/ThermalMonitor/` 温控 plist：背光亮度/功率曲线取首值拉平、去掉 CPMS 支持声明
- 可锁定 CPU 最大/最小热功率（设置里填频率值）
- 支持模拟热压力档位（nominal/light/moderate/heavy）

### 充电限制（本 fork 新增，移植自 ChargeLimiter）
- 读路径优先 `AppleSmartBattery`（iPhone 8+），自动回退 `IOPMPowerSource`
- 电量达到停充阈值后通过 `PredictiveChargingInhibit` 停充（iOS 17+ 同时写 `IsCharging`，极性相反）
- 可选：停充时同时禁流（iOS 17+ 写 `FieldDiagsInflowInhibit`/`OBCInflowInhibit`；旧系统写 `ExternalConnected=false`）
- **电量下降 X% 后先恢复输入，再恢复充电**——X 为恢复回差，可填任意值，不固定 5%
- 电量 ≤5% 强制充电兜底；拔线自动清除停充/禁流残留
- 运行位置：`thermalmonitord`（随系统守护常驻，事件触发 + 30 秒轮询兜底）

## 充电限制配置（设置 → Insulation）

| 偏好键 | 说明 | 默认值 |
| --- | --- | --- |
| `chargeLimitEnabled` | 充电限制总开关 | 关 |
| `chargeLimitAbove` | 停充阈值（%） | 80 |
| `chargeResumeDrop` | 恢复回差：电量下降百分之几后恢复充电，**可改任意值** | 5 |
| `chargeDisableInflow` | 停充时同时禁流（设备转电池供电） | 关 |
| `chargePreferSmartBattery` | 优先使用 AppleSmartBattery 读数 | 开 |

改完即热生效，无需重启用户空间。

### 真机验证
状态流水写入 `/var/mobile/Library/Preferences/com.be-huge.insulation-charge-status.plist`：
`charge_stop` / `charge_resume` / `inflow_block` / `inflow_resume` / `adaptor_disconnected` 事件及当前阈值、回差、命令态。

## 上游同步与重新打包

本仓库是 [be-huge/insulation](https://github.com/be-huge/insulation) 的 fork，GPL-3.0 同协议。
充电限制核心位于 `Sources/insulationC/ChargeLimitController.{h,mm}`，与上游文件无重叠，
上游更新后按以下流程合并：

```bash
git fetch origin
git checkout main && git merge origin/main      # 先合上游
git checkout feature/charge-limiter && git merge main
# 解决冲突（如上游改了 Root.plist / control / Tweak.x.swift 的相邻区域）
make clean && make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless   # 重新打包
```

## 致谢与协议

- 充电限制核心移植自 [ChargeLimiter](https://github.com/dhinakg/ChargeLimiter)（原版已删库，延续维护 [lich4/ChargeLimiter](https://github.com/lich4/ChargeLimiter)，打包维护 [tunecc/ChargeLimiter](https://github.com/tunecc/ChargeLimiter)），GPL-3.0。
- 本仓库基于 [be-huge/insulation](https://github.com/be-huge/insulation)（GPL-3.0）修改，修改部分以 GPL-3.0 同协议开源。
