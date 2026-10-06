THEOS_DEVICE_IP ?= localhost
export THEOS_DEVICE_IP
export ARCHS = arm64
export TARGET = iphone:clang:latest:16.0
# Rootless (Dopamine): use the rootless package scheme. This links against the
# @rpath CydiaSubstrate framework (resolvable on rootless) and stages into
# /var/jb so the tweak lands in /var/jb/Library/MobileSubstrate/DynamicLibraries/
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = 26Unlock

26Unlock_FILES = Tweak.xm WaveEngine.m WaveTable.m
26Unlock_CFLAGS = -fobjc-arc -Wall
26Unlock_FRAMEWORKS = Foundation UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
