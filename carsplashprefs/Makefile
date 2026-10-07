TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CarSplashPrefs

CarSplashPrefs_FILES = CSPRootListController.m
CarSplashPrefs_FRAMEWORKS = UIKit AVFoundation AVKit UniformTypeIdentifiers
CarSplashPrefs_PRIVATE_FRAMEWORKS = Preferences
CarSplashPrefs_INSTALL_PATH = /Library/PreferenceBundles
CarSplashPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
