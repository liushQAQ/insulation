TARGET := iphone:clang:latest:12.2

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = InsulationPrefs

InsulationPrefs_FILES = $(shell find Sources/InsulationPrefs -name '*.swift') $(shell find Sources/InsulationPrefsC -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')
InsulationPrefs_SWIFTFLAGS = -ISources/InsulationPrefsC/include
InsulationPrefs_INSTALL_PATH = /Library/PreferenceBundles
InsulationPrefs_CFLAGS = -fobjc-arc

# theos 精简版 SDK 的 System/Library/PrivateFrameworks 不含 Preferences.framework，
# 而 Swift `import Preferences`（theos/headers 的 modulemap 带 `link framework
# "Preferences"`）会在对象文件里埋 LC_LINKER_OPTION autolink。链接期 clang 驱动
# 在 -F 搜索路径里找不到该框架就会丢弃 autolink，进而报
# "_OBJC_CLASS_$_PSListController undefined"。
# 解决：把工程内 vendor 的 Preferences.tbd 桩目录加进框架搜索路径。
# 桩的 install-name 指向设备真实路径（/System/Library/PrivateFrameworks/...），
# 链接期用桩、运行期 dyld 加载真框架，与 theos/lib 下 Cephei.tbd 等同机制。
InsulationPrefs_LDFLAGS = -F$(THEOS_PROJECT_DIR)/InsulationPrefs/vendor

include $(THEOS_MAKE_PATH)/bundle.mk
