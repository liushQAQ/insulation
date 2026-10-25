#import <spawn.h>
#import <Foundation/Foundation.h>
#import "./PSSpecifier/PSSpecifier.h"

// 越狱根前缀运行时探测（同源拷贝，源头：Sources/insulationC/include/JBRootPath.h）。
// 原上游写法 return jbroot(path) 依赖 roothide 定制 theos 自动链 libroothide，
// 官方 theos / CI 环境无该库，rootless 与 roothide scheme 均报 jbroot 未定义。
//   roothide  /var/.jbroot-XXXX（运行时枚举）  rootless  /var/jb  rootful  原样
static NSString *_Nonnull JBRootPrefix(void) {
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

static NSString *_Nonnull JBRootPrefixedPath(NSString *_Nonnull path) {
    NSString *prefix = JBRootPrefix();
    if (prefix.length == 0 || [path hasPrefix:@"/var/jb"] ||
        [path containsString:@"/.jbroot-"]) {
        return path;
    }
    return [prefix stringByAppendingString:path];
}

static NSString *_Nonnull rootlessPath(NSString* _Nonnull path) {
  return JBRootPrefixedPath(path);
}
