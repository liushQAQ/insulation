#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 充电限制核心（移植自 ChargeLimiter，GPL-3.0）。
///
/// 上游来源：
///   原版  dhinakg/ChargeLimiter（已删库）
///   延续  lich4/ChargeLimiter
///   打包  tunecc/ChargeLimiter
///
/// 行为（与上游一致，回差改为可配置）：
///   - 读路径优先 AppleSmartBattery（iPhone 8+），回退 IOPMPowerSource；
///   - 电量达到停充阈值后通过 PredictiveChargingInhibit 停充
///     （iOS 17+ 同时写 IsCharging，极性相反）；
///   - 可选：停充时同时禁流（iOS 17+ 写 FieldDiagsInflowInhibit/OBCInflowInhibit，
///     旧系统写 ExternalConnected=false）；
///   - 电量下降 resumeDrop%（可配置，默认 5%，不固定）后
///     **先恢复输入，再恢复充电**；
///   - 电量 ≤5% 强充兜底；拔线自动清除停充/禁流残留。
///
/// 运行位置：thermalmonitord（由 Tweak.x.swift 在 tweak 载入时调用 -boot）。
@interface ChargeLimitController : NSObject

@property (class, nonatomic, readonly) ChargeLimitController *shared;

/// 功能总开关（对应偏好键 chargeLimitEnabled）
@property (nonatomic, assign) BOOL enabled;
/// 停充阈值百分比（chargeLimitAbove），默认 80
@property (nonatomic, assign) NSInteger threshold;
/// 恢复回差：电量下降百分之几后恢复充电（chargeResumeDrop），默认 5，可改任意值
@property (nonatomic, assign) NSInteger resumeDrop;
/// 停充时是否同时禁流（chargeDisableInflow），默认 NO
@property (nonatomic, assign) BOOL disableInflow;
/// 读路径是否优先 AppleSmartBattery（chargePreferSmartBattery），默认 YES
@property (nonatomic, assign) BOOL preferSmart;

/// tweak 载入时调用：读配置，启用则立即启动控制循环并监听配置变更。
- (void)boot;

@end

NS_ASSUME_NONNULL_END
