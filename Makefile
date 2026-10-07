TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = CarPlay

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CarSplash

CarSplash_FILES = Tweak.x
CarSplash_FRAMEWORKS = UIKit ImageIO QuartzCore
CarSplash_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += carsplashprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
