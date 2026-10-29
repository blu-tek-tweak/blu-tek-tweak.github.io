THEOS_DEVICE_IP ?= localhost
export THEOS_DEVICE_IP
export ARCHS = arm64e
export TARGET = iphone:clang:latest:16.0
# Rootless (Dopamine): use the rootless package scheme. This links against the
# @rpath CydiaSubstrate framework (resolvable on rootless) and stages into
# /var/jb so the tweak lands in /var/jb/Library/MobileSubstrate/DynamicLibraries/
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# WAVE_DEBUG: 0 = prefs bundle disabled (not staged, not in Settings);
#             1 = prefs bundle enabled (staged, appears in Settings).
# Mirrors kWaveDebug in WaveEngine.m. Build with `make WAVE_DEBUG=1` to enable.
WAVE_DEBUG ?= 1

TWEAK_NAME = 26Unlock
ifeq ($(WAVE_DEBUG),1)
TWEAK_NAME += 26WavePrefs
endif

26Unlock_FILES = Tweak.xm WaveEngine.m WaveTable.m
26Unlock_CFLAGS = -fobjc-arc -Wall
26Unlock_FRAMEWORKS = Foundation UIKit QuartzCore
26Unlock_CFLAGS += -DWAVE_DEBUG=$(WAVE_DEBUG)

# The prefs controller lives in its own bundle executable (mirrors the working
# 26Clock tweak). It subclasses PSListController (Preferences framework); the
# SDK ships no linkable Preferences.framework, so leave its symbols unresolved
# at link time -- they resolve at runtime from the Settings process, which has
# the Preferences framework in memory.
ifeq ($(WAVE_DEBUG),1)
26WavePrefs_FILES = Prefs.xm
# No -Wall here: the .xm extension makes Theos compile as C++, and the global
# -Wall (with -Werror) flags the char * string literals in the respring action.
26WavePrefs_CFLAGS = -fobjc-arc
26WavePrefs_FRAMEWORKS = Foundation
26WavePrefs_LDFLAGS = -Xlinker -undefined -Xlinker dynamic_lookup
endif

include $(THEOS_MAKE_PATH)/tweak.mk

# Assemble the prefs bundle. The working tweaks on this device ship a
# PreferenceBundles/<Name>.bundle whose executable defines the root controller
# class (named by NSPrincipalClass in Info.plist). The Settings app loads the
# bundle and instantiates that class when the user taps the entry. We:
#   1. drop the built 26WavePrefs executable into the bundle,
#   2. copy the bundle's Info.plist + Root.plist (the specifiers),
#   3. generate the binary PreferenceLoader entry plist whose `bundle` key
#      names the bundle and whose `isController` names the controller class.
# Only stage the prefs bundle when WAVE_DEBUG=1.
ifeq ($(WAVE_DEBUG),1)
after-stage::
	@mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceBundles/26WavePrefs.bundle
	@cp .theos/obj/debug/26WavePrefs.dylib $(THEOS_STAGING_DIR)/Library/PreferenceBundles/26WavePrefs.bundle/26WavePrefs
	@chmod +x $(THEOS_STAGING_DIR)/Library/PreferenceBundles/26WavePrefs.bundle/26WavePrefs
	@install_name_tool -id /var/jb/Library/PreferenceBundles/26WavePrefs.bundle/26WavePrefs $(THEOS_STAGING_DIR)/Library/PreferenceBundles/26WavePrefs.bundle/26WavePrefs
	@codesign -f -s - $(THEOS_STAGING_DIR)/Library/PreferenceBundles/26WavePrefs.bundle/26WavePrefs
	@cp prefs/26WavePrefs.bundle/Info.plist $(THEOS_STAGING_DIR)/Library/PreferenceBundles/26WavePrefs.bundle/Info.plist
	@if [ -f prefs/26WavePrefs.bundle/icon.png ]; then cp prefs/26WavePrefs.bundle/icon.png $(THEOS_STAGING_DIR)/Library/PreferenceBundles/26WavePrefs.bundle/icon.png; fi
	@plutil -convert binary1 prefs/26WavePrefs.bundle/Root.plist
	@cp prefs/26WavePrefs.bundle/Root.plist $(THEOS_STAGING_DIR)/Library/PreferenceBundles/26WavePrefs.bundle/Root.plist
	@mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences
	@python3 tools/gen_prefs_plist.py $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/26WavePrefs.plist
	@rm -f $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/26WavePrefs.dylib $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/26WavePrefs.plist
endif
