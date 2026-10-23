#import <Foundation/Foundation.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <spawn.h>
#import <unistd.h>
#import <stdlib.h>
#import <stdio.h>

// The Settings app loads this bundle and instantiates the class named by
// NSPrincipalClass in Info.plist (26WavePrefsRootListController). It subclasses
// PSListController (Preferences framework, which the Settings app has in
// memory). Linked with -undefined dynamic_lookup because the SDK ships no
// linkable Preferences framework; the PSListController / PSSpecifier symbols
// resolve at runtime from the Settings process.
//
// The UI is loaded from the bundle's Root.plist (the specifiers). Each slider
// cell has a `defaults` key naming the NSUserDefaults domain
// (com.blu-tek.26waveprefs) and a `key` naming the value. The PSListController
// writes the value to that domain when the user changes it; the tweak reads it
// back. The Respring button uses a custom action.
@interface TW26PrefsRootListController : PSListController
@end

@implementation TW26PrefsRootListController

// Invoked by the "Respring" button (the PSButtonCell's `action` key). Kills
// SpringBoard via posix_spawn so the tweak relaunches and reads the new prefs.
// On this jailbreak the real killall is at /var/jb/usr/bin/killall.
- (void)respring:(id)sender {
    char *path = (char *)"/var/jb/usr/bin/killall";
    char *args[] = { (char *)"killall", (char *)"SpringBoard", NULL };
    pid_t pid = 0;
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawn(&pid, path, &attr, NULL, args, NULL);
    posix_spawnattr_destroy(&attr);
    if (pid > 0) {
        int status;
        waitpid(pid, &status, 0);
    }
}

// Invoked by the "Reset to Defaults" button. Deletes the saved prefs so the
// tweak falls back to its built-in defaults, then resprings so the change
// takes effect immediately.
- (void)resetDefaults:(id)sender {
    NSString *domain = @"com.blu-tek.26waveprefs";
    // Remove the user's saved values; the tweak then uses its code defaults.
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:domain];
    // Also delete the file directly (the domain may live under the jailbreak
    // root, which NSUserDefaults may not reach).
    NSArray *paths = @[
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", domain],
        [NSString stringWithFormat:@"/private/var/mobile/Library/Preferences/%@.plist", domain],
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in paths) {
        if ([fm fileExistsAtPath:p]) [fm removeItemAtPath:p error:NULL];
    }
    // No respring: the user taps Respring separately when they want the
    // defaults to take effect.
}

// Load the specifiers from the bundle's Root.plist. The 3-arg form takes an
// explicit bundle so it finds the Root.plist inside our bundle (the 2-arg form
// looks in the main bundle, which is the Settings app, not us).
- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root"
                                               target:self
                                               bundle:[NSBundle bundleForClass:[self class]]];
    }
    return _specifiers;
}

@end
