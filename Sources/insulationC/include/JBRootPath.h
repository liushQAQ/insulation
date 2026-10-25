#ifndef JB_ROOT_PATH_H
#define JB_ROOT_PATH_H

// 运行时探测越狱根前缀，替代 roothide.h 的 jbroot()：
// 上游用魔改 theos（自动链 libroothide）才能过链接；官方 theos / CI 环境没有
// libroothide，rootless 与 roothide 两个 scheme 都会报 jbroot 未定义。
// 探测规则（与各越狱实际布局一致）：
//   roothide  /var/.jbroot-XXXXXXXX/*（目录名安装时随机、之后恒定，运行时枚举）
//   rootless  /var/jb/*（Dopamine 系符号链接）
//   rootful   原样路径（老越狱，直接写 /var/mobile/...）
// 被 Tweak.h / ChargeLimitController.mm / InsulationPrefs.h 三处共用；
// InsulationPrefs 子项目各有一份同源拷贝（其 Makefile 不含本目录 -I）。

#import <Foundation/Foundation.h>

static inline NSString *_Nonnull JBRootPrefix(void) {
    static NSString *prefix;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefix = @"";
        NSArray *entries = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:@"/var" error:nil];
        for (NSString *entry in entries) {
            if ([entry hasPrefix:@".jbroot-"]) {
                prefix = [@"/var" stringByAppendingPathComponent:entry];
                break;
            }
        }
        if (prefix.length == 0 &&
            [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
            prefix = @"/var/jb";
        }
    });
    return prefix;
}

static inline NSString *_Nonnull JBRootPrefixedPath(NSString *_Nonnull path) {
    NSString *prefix = JBRootPrefix();
    if (prefix.length == 0 || [path hasPrefix:@"/var/jb"] ||
        [path containsString:@"/.jbroot-"]) {
        return path;
    }
    return [prefix stringByAppendingString:path];
}

#endif /* JB_ROOT_PATH_H */
