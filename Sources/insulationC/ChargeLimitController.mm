//  ChargeLimitController.mm
//  insulation（be-huge/insulation 的 fork，GPL-3.0）
//
//  充电限制核心 —— 移植自 ChargeLimiter（GPL-3.0）
//    原版  https://github.com/dhinakg/ChargeLimiter（已删库）
//    延续  https://github.com/lich4/ChargeLimiter
//    打包  https://github.com/tunecc/ChargeLimiter
//  上游版权归原作者所有；本文件为同协议（GPL-3.0）衍生代码，
//  按 insulation 的偏好设置体系（com.be-huge.insulation-prefs.plist）适配，
//  并将上游固定的 5% 恢复回差改为可配置的 resumeDrop（任意 X%）。

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
// 注意：theos 自带的 vendor/include/IOKit/IOKit.h 是坏桩头（内容只有一行字面量
// "IOKitLib.h"），解析报错后 clang 的错误恢复会吞 token 找 ';'，连带把后续
// #import 进来的 ObjC 声明上下文毁掉（@interface 被吞 → 剩余 @property 全报
// unexpected '@'）。只引分体真实头，永不引这个伞头。
#import <IOKit/IOTypes.h>
#import <IOKit/IOReturn.h>
#import <IOKit/IOKitLib.h>
#import <dispatch/dispatch.h>

// theos 头件库的 IOKitLib.h 未收录此 API（IOKit 框架二进制内存在，iOS 可用，
// macOS 10.7+ 同名同签名），自行补原型即可；若上游头日后收录则为等价重声明。
extern void IONotificationPortSetDispatchQueue(IONotificationPortRef notify,
                                               dispatch_queue_t queue);

#import "ChargeLimitController.h"

// === 移植自 ChargeLimiter daemon.mm 的常量（按需裁剪）====================
static const NSInteger kCriticalLowLevel = 5;        // ≤5% 强充兜底（与上游一致）
static const NSTimeInterval kPollInterval = 30.0;    // 轮询兜底间隔（秒）
static const NSUInteger kMaxTransitionLog = 50;      // 状态流水保留条数

static NSString *const kPrefsPath =
    @"/var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist";
static NSString *const kStatusPath =
    @"/var/mobile/Library/Preferences/com.be-huge.insulation-charge-status.plist";

/// 设置面板改完充电限制配置后广播，tweak 侧热生效（与 thermalPuppetEvent 同套路）
NSString *const kChargeConfigChangedNotify = @"com.be-huge.insulation-chargeConfigChanged";

// === 工具函数（移植自 daemon.mm / utils.mm）==============================

static BOOL CLIsIOS17OrLater(void) {
    NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
    return v.majorVersion >= 17;
}

static NSInteger CLIntValue(id val, NSInteger fallback) {
    if ([val respondsToSelector:@selector(integerValue)]) {
        return (NSInteger)[val integerValue];
    }
    return fallback;
}

static BOOL CLBoolValue(id val, BOOL fallback) {
    if ([val respondsToSelector:@selector(boolValue)]) {
        return (BOOL)[val boolValue];
    }
    return fallback;
}

// === 私有接口 ============================================================

@interface ChargeLimitController ()

@property (nonatomic, assign) BOOL running;
/// 当前充电命令态：YES=允许充电
@property (nonatomic, assign) BOOL chargeEnabled;
/// 当前输入态：YES=允许输入（禁流的反面）
@property (nonatomic, assign) BOOL inflowEnabled;
@property (nonatomic, assign) NSInteger lastCapacity;

@property (nonatomic, assign) io_service_t batteryService;   // 读路径 service（缓存）
@property (nonatomic, assign) NSInteger overrideUsable;      // -1 未知 / 0 否 / 1 是
@property (nonatomic, assign) IONotificationPortRef notifyPort;
@property (nonatomic, assign) io_object_t interestNoti;
@property (nonatomic, strong) dispatch_source_t pollTimer;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *transitions;

- (void)startLocked;
- (void)stopLocked;
- (void)loadConfig;
- (void)resolveServices;
- (io_service_t)copyReadService;
- (io_service_t)copyOverrideWriteService;
- (NSDictionary *)readBatteryInfo;
- (void)setCharging:(BOOL)enabled force:(BOOL)force;
- (void)setInflow:(BOOL)enabled force:(BOOL)force;
- (BOOL)isAdapterConnected:(NSDictionary *)info;
- (void)applyPolicy:(BOOL)force;
- (void)handleConfigChanged;
- (void)registerInterestNotification;
- (void)unregisterInterestNotification;
- (void)startPollTimer;
- (void)stopPollTimer;
- (void)recordTransition:(NSString *)event;

@end

// === 静态 C 回调（置于私有声明之后）======================================

static void batteryInterestCallback(void *refcon, io_service_t service,
                                     uint32_t messageType, void *messageArgument) {
    // IOGeneralInterest：电池状态变化（插拔/电量/充电态），直接跑一轮策略
    [ChargeLimitController.shared applyPolicy:NO];
}

static void chargeConfigChangedCallback(CFNotificationCenterRef center, void *observer,
                                        CFStringRef name, const void *object,
                                        CFDictionaryRef userInfo) {
    [ChargeLimitController.shared handleConfigChanged];
}

// === 实现 ================================================================

@implementation ChargeLimitController

+ (instancetype)shared {
    static ChargeLimitController *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [self new]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled = NO;
        _threshold = 80;
        _resumeDrop = 5;
        _disableInflow = NO;
        _preferSmart = YES;
        _chargeEnabled = YES;
        _inflowEnabled = YES;
        _batteryService = IO_OBJECT_NULL;
        _overrideUsable = -1;
        _interestNoti = IO_OBJECT_NULL;
        _notifyPort = NULL;
        _transitions = [NSMutableArray array];
    }
    return self;
}

#pragma mark - 生命周期

- (void)boot {
    self.workQueue = dispatch_queue_create("com.be-huge.insulation.charge", DISPATCH_QUEUE_SERIAL);
    dispatch_async(self.workQueue, ^{
        [self loadConfig];
        if (self.enabled) {
            [self startLocked];
        }
    });
    // 监听设置面板的配置变更（Darwin 通知，主线程 run loop 投递）
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    // Darwin 中心的挂起行为形参按惯例传 Coalesce（实际投递不受它影响，恒为立即）
    CFNotificationCenterAddObserver(center, (__bridge void *)self, chargeConfigChangedCallback,
                                    (__bridge CFStringRef)kChargeConfigChangedNotify, NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
}

- (void)handleConfigChanged {
    dispatch_async(self.workQueue, ^{
        BOOL wasEnabled = self.enabled;
        [self loadConfig];
        if (self.enabled) {
            [self startLocked];
        } else if (wasEnabled) {
            [self stopLocked];
        }
    });
}

- (void)startLocked {
    if (self.running) return;
    self.running = YES;
    self.chargeEnabled = YES;
    self.inflowEnabled = YES;
    [self resolveServices];
    [self registerInterestNotification];
    [self startPollTimer];
    // 启动即按当前电量执行一次（如已在阈值以上立即停充）
    [self applyPolicy:YES];
}

- (void)stopLocked {
    if (!self.running) return;
    self.running = NO;
    [self stopPollTimer];
    [self unregisterInterestNotification];
    // 关闭功能时恢复充电与输入，避免残留抑制态
    [self setInflow:YES force:YES];
    [self setCharging:YES force:YES];
    [self recordTransition:@"controller_stopped"];
}

#pragma mark - 配置

- (void)loadConfig {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: @{};
    self.enabled = CLBoolValue(prefs[@"chargeLimitEnabled"], NO);
    self.threshold = CLIntValue(prefs[@"chargeLimitAbove"], 80);
    if (self.threshold < 1 || self.threshold > 100) self.threshold = 80;
    // 不固定 5%：可配任意下降值；下限 1 防止阈值附近振荡，上限 99 防呆
    self.resumeDrop = CLIntValue(prefs[@"chargeResumeDrop"], 5);
    if (self.resumeDrop < 1 || self.resumeDrop > 99) self.resumeDrop = 5;
    self.disableInflow = CLBoolValue(prefs[@"chargeDisableInflow"], NO);
    self.preferSmart = CLBoolValue(prefs[@"chargePreferSmartBattery"], YES);
}

#pragma mark - service 解析（移植 getIOPMPSServ / override 判定）

- (void)resolveServices {
    if (self.batteryService == IO_OBJECT_NULL) {
        self.batteryService = [self copyReadService];
    }
    if (self.overrideUsable < 0) {
        io_service_t serv = [self copyOverrideWriteService];
        self.overrideUsable = (CLIsIOS17OrLater() && serv != IO_OBJECT_NULL) ? 1 : 0;
        if (serv != IO_OBJECT_NULL) IOObjectRelease(serv);
    }
}

/// 读路径：优先 AppleSmartBattery（iPhone 8+），回退 IOPMPowerSource
- (io_service_t)copyReadService {
    if (self.preferSmart || CLIsIOS17OrLater()) {
        io_service_t s = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                     IOServiceMatching("AppleSmartBattery"));
        if (s != IO_OBJECT_NULL) return s;
    }
    return IOServiceGetMatchingService(kIOMasterPortDefault,
                                       IOServiceMatching("IOPMPowerSource"));
}

/// 写路径 service：AppleSmartBattery（iOS 17+ override 写目标），Manager 仅兜底
- (io_service_t)copyOverrideWriteService {
    io_service_t s = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                 IOServiceMatching("AppleSmartBattery"));
    if (s != IO_OBJECT_NULL) return s;
    return IOServiceGetMatchingService(kIOMasterPortDefault,
                                       IOServiceMatching("AppleSmartBatteryManager"));
}

#pragma mark - 读写

- (NSDictionary *)readBatteryInfo {
    if (self.batteryService == IO_OBJECT_NULL) return nil;
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(self.batteryService, &props,
                                                         kCFAllocatorDefault, 0);
    if (kr != KERN_SUCCESS || props == NULL) {
        if (props) CFRelease(props);
        // service 可能已终止：清缓存重解析一次
        self.batteryService = IO_OBJECT_NULL;
        [self resolveServices];
        if (self.batteryService == IO_OBJECT_NULL) return nil;
        props = NULL;
        if (IORegistryEntryCreateCFProperties(self.batteryService, &props,
                                              kCFAllocatorDefault, 0) != KERN_SUCCESS ||
            props == NULL) {
            if (props) CFRelease(props);
            return nil;
        }
    }
    return CFBridgingRelease(props);
}

/// 停充/恢复充电。移植 setChargeStatus 的完整回退链：
/// iOS 17+ override（IsCharging + PredictiveChargingInhibit 极性相反）
///   → 旧路径① PredictiveChargingInhibit（IsCharging 保持 YES）
///   → 旧路径② 直接写 IsCharging
- (void)setCharging:(BOOL)enabled force:(BOOL)force {
    if (!force && enabled == self.chargeEnabled) return;
    BOOL ok = NO;
    if (self.overrideUsable == 1) {
        io_service_t serv = [self copyOverrideWriteService];
        if (serv != IO_OBJECT_NULL) {
            BOOL stop = !enabled;
            NSDictionary *props = @{
                @"IsCharging": @(!stop),
                @"PredictiveChargingInhibit": @(stop),
            };
            ok = (IORegistryEntrySetCFProperties(serv, (__bridge CFTypeRef)props) == KERN_SUCCESS);
            IOObjectRelease(serv);
        }
    }
    if (!ok && self.batteryService != IO_OBJECT_NULL) {
        NSDictionary *props = @{
            @"IsCharging": @YES,
            @"PredictiveChargingInhibit": @(!enabled),
        };
        ok = (IORegistryEntrySetCFProperties(self.batteryService, (__bridge CFTypeRef)props) ==
              KERN_SUCCESS);
        if (!ok) {
            props = @{
                @"IsCharging": @(enabled),
                @"PredictiveChargingInhibit": @NO,
            };
            ok = (IORegistryEntrySetCFProperties(self.batteryService, (__bridge CFTypeRef)props) ==
                  KERN_SUCCESS);
        }
    }
    if (ok) {
        BOOL changed = (enabled != self.chargeEnabled);
        self.chargeEnabled = enabled;
        if (changed) {
            [self recordTransition:enabled ? @"charge_resume" : @"charge_stop"];
        }
    }
}

/// 禁流/恢复输入。移植 setInflowStatus：
/// iOS 17+ override（FieldDiagsInflowInhibit/OBCInflowInhibit）
///   → 旧路径 ExternalConnected=false 禁流 / true 恢复输入
- (void)setInflow:(BOOL)enabled force:(BOOL)force {
    if (!force && enabled == self.inflowEnabled) return;
    BOOL ok = NO;
    if (self.overrideUsable == 1) {
        io_service_t serv = [self copyOverrideWriteService];
        if (serv != IO_OBJECT_NULL) {
            NSDictionary *props = @{
                @"FieldDiagsInflowInhibit": @(!enabled),
                @"OBCInflowInhibit": @(!enabled),
            };
            ok = (IORegistryEntrySetCFProperties(serv, (__bridge CFTypeRef)props) == KERN_SUCCESS);
            IOObjectRelease(serv);
        }
    }
    if (!ok && self.batteryService != IO_OBJECT_NULL) {
        NSDictionary *props = @{@"ExternalConnected": @(enabled)};
        ok = (IORegistryEntrySetCFProperties(self.batteryService, (__bridge CFTypeRef)props) ==
              KERN_SUCCESS);
    }
    if (ok) {
        BOOL changed = (enabled != self.inflowEnabled);
        self.inflowEnabled = enabled;
        if (changed) {
            [self recordTransition:enabled ? @"inflow_resume" : @"inflow_block"];
        }
    }
}

#pragma mark - 插电判定（移植 isAdaptorConnect）

- (BOOL)isAdapterConnected:(NSDictionary *)info {
    // 禁流态下 ExternalConnected/ExternalChargeCapable 由系统派生且会抖动，
    // 改看 AdapterDetails（与上游禁流分支一致）
    BOOL inflowRuntimeDisabled = self.disableInflow && !self.inflowEnabled;
    if (inflowRuntimeDisabled) {
        NSDictionary *adapter = info[@"AdapterDetails"];
        NSString *desc = adapter[@"Description"];
        if (desc.length == 0 || [desc isEqualToString:@"batt"]) return NO;
        return YES;
    }
    return [info[@"ExternalChargeCapable"] boolValue];
}

#pragma mark - 策略主循环（移植 refreshBatteryStateAndApplyPolicy，按需求精简）

- (void)applyPolicy:(BOOL)force {
    if (!self.running || !self.enabled) return;
    [self loadConfig];
    if (!self.enabled) {
        [self stopLocked];
        return;
    }
    [self resolveServices];
    NSDictionary *info = [self readBatteryInfo];
    if (!info) return;

    NSInteger capacity = [info[@"CurrentCapacity"] integerValue];
    self.lastCapacity = capacity;
    BOOL adapterConnected = [self isAdapterConnected:info];

    // 恢复线 = 停充阈值 - 回差 X%（可配置，不固定 5%）
    NSInteger resumeLevel = self.threshold - self.resumeDrop;
    if (resumeLevel >= self.threshold) resumeLevel = MAX(0, self.threshold - 1);
    if (resumeLevel < 0) resumeLevel = 0;

    // 拔线：清除软件停充/禁流残留，下次插电从干净态开始（与上游一致）
    if (!adapterConnected) {
        if (!self.chargeEnabled || !self.inflowEnabled) {
            [self setInflow:YES force:YES];
            [self setCharging:YES force:YES];
            [self recordTransition:@"adaptor_disconnected"];
        }
        return;
    }
    // 优先级1：极低电量强充（安全兜底，防误配置导致无法充电）
    if (capacity <= kCriticalLowLevel) {
        [self setInflow:YES force:force];
        [self setCharging:YES force:force];
        return;
    }
    // 优先级2：达到停充阈值 → PredictiveChargingInhibit 停充；可选同时禁流
    if (capacity >= self.threshold) {
        [self setCharging:NO force:force];
        if (self.disableInflow) {
            [self setInflow:NO force:force];
        }
        return;
    }
    // 优先级3：电量下降 X% → 先恢复输入，再恢复充电
    if (capacity <= resumeLevel) {
        [self setInflow:YES force:force];
        [self setCharging:YES force:force];
        return;
    }
    // 阈值与恢复线之间：维持停充态，不写
}

#pragma mark - 通知与轮询

- (void)registerInterestNotification {
    if (self.batteryService == IO_OBJECT_NULL) return;
    IONotificationPortRef port = IONotificationPortCreate(kIOMasterPortDefault);
    if (!port) return;
    self.notifyPort = port;
    // 用 dispatch queue 投递，不依赖 thermalmonitord 的 run loop
    IONotificationPortSetDispatchQueue(port, self.workQueue);
    io_object_t noti = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceAddInterestNotification(
        port, self.batteryService, "IOGeneralInterest", batteryInterestCallback,
        (__bridge void *)self, &noti);
    if (kr == KERN_SUCCESS) {
        self.interestNoti = noti;
    }
}

- (void)unregisterInterestNotification {
    if (self.interestNoti != IO_OBJECT_NULL) {
        IOObjectRelease(self.interestNoti);
        self.interestNoti = IO_OBJECT_NULL;
    }
    if (self.notifyPort) {
        IONotificationPortDestroy(self.notifyPort);
        self.notifyPort = NULL;
    }
}

- (void)startPollTimer {
    [self stopPollTimer];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     self.workQueue);
    uint64_t interval = (uint64_t)(kPollInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval,
                              1.0 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf applyPolicy:NO];
    });
    dispatch_resume(timer);
    self.pollTimer = timer;
}

- (void)stopPollTimer {
    if (self.pollTimer) {
        dispatch_source_cancel(self.pollTimer);
        self.pollTimer = nil;
    }
}

#pragma mark - 状态流水（真机验证用：落盘 com.be-huge.insulation-charge-status.plist）

- (void)recordTransition:(NSString *)event {
    @autoreleasepool {
        NSDictionary *item = @{
            @"event": event,
            @"capacity": @(self.lastCapacity),
            @"chargeEnabled": @(self.chargeEnabled),
            @"inflowEnabled": @(self.inflowEnabled),
            @"ts": @([[NSDate date] timeIntervalSince1970]),
        };
        [self.transitions addObject:item];
        if (self.transitions.count > kMaxTransitionLog) {
            [self.transitions removeObjectsInRange:NSMakeRange(0, self.transitions.count -
                                                                       kMaxTransitionLog)];
        }
        NSDictionary *payload = @{
            @"updated": @([[NSDate date] timeIntervalSince1970]),
            @"enabled": @(self.enabled),
            @"threshold": @(self.threshold),
            @"resumeDrop": @(self.resumeDrop),
            @"disableInflow": @(self.disableInflow),
            @"chargeEnabled": @(self.chargeEnabled),
            @"inflowEnabled": @(self.inflowEnabled),
            @"transitions": [self.transitions copy],
        };
        [payload writeToFile:kStatusPath atomically:YES];
    }
}

@end
