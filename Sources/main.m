// HotspotKeeper — Automatically wake and connect your Mac to a pinned iPhone Personal Hotspot
// when your physical network drops, with an optional (Opt-in) three-layer fail-safe Clamshell
// Keep-Awake engine for Apple Silicon MacBooks.
//
// Designed to work cleanly alongside Surge Enhanced Mode, Clash/Mihomo TUN, Tailscale, and Sill.
//
// Usage:
//   hotspot-keeper                      Run menu bar app (default)
//   hotspot-keeper --headless           Run background daemon without menu bar icon
//   hotspot-keeper --status             Print physical link, internet, hotspot, battery, lid & power status
//   hotspot-keeper --list               Scan and list nearby same-Apple-Account iPhones
//   hotspot-keeper --test               Test waking the target iPhone hotspot over Bluetooth (no Wi-Fi switch)
//   hotspot-keeper --force              Immediately connect to the target hotspot (BLE wake + Wi-Fi fallback)
//   hotspot-keeper --target <name>      Override target iPhone / hotspot SSID (empty = first nearby iPhone)
//   hotspot-keeper --setup-clamshell    Install least-privilege sudoers + boot-reset daemon + lease watchdog (sudo)
//   hotspot-keeper --teardown-clamshell Reset disablesleep 0 and remove all clamshell system hooks (sudo)
//   hotspot-keeper --enable-clamshell   Enable Opt-in Clamshell Keep-Awake mode (requires --setup-clamshell first)
//   hotspot-keeper --disable-clamshell  Disable Clamshell Keep-Awake mode and release disablesleep 0
//   hotspot-keeper --sleep-now          Release disablesleep 0 and put Mac to sleep immediately
//   hotspot-keeper --install-login      Install & start LaunchAgent for Start at Login
//   hotspot-keeper --uninstall-login    Remove LaunchAgent (and release disablesleep 0 if owned)
//   hotspot-keeper --version            Print version

#import <AppKit/AppKit.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreWLAN/CoreWLAN.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <dlfcn.h>
#import <signal.h>
#import <sys/file.h>
#import <time.h>
#import <objc/message.h>

#define HK_BUNDLE_ID          @"io.github.wangnov.hotspot-keeper"
#define HK_WATCHDOG_LABEL     @"io.github.wangnov.hotspot-keeper.watchdog"
#define HK_BOOTGUARD_LABEL    @"io.github.wangnov.hotspot-keeper.sleepguard"
#define HK_SUDOERS_PATH       @"/etc/sudoers.d/hotspot-keeper-pmset"
#define HK_BOOTGUARD_PLIST    @"/Library/LaunchDaemons/io.github.wangnov.hotspot-keeper.sleepguard.plist"
#define HK_AMPHETAMINE_BUNDLE @"com.if.Amphetamine"
#define HK_VERSION            @"1.2.0"

// Power guard safety constants
#define HK_GRACE_MIN_SECONDS       120.0
#define HK_GRACE_HARD_CAP_SECONDS  180.0
#define HK_GRACE_MIN_ROUNDS        3
#define HK_DEAD_LINK_MAX_SECONDS   240.0   // Physical link without internet max stay-awake (4 min)
#define HK_BATT_RELEASE_PCT        20      // Release SleepDisabled below 20% on battery
#define HK_BATT_REARM_PCT          25      // Hysteresis: require >= 25% (or AC) to re-arm
#define HK_BUSY_TIMEOUT_SECONDS    60.0    // Watchdog timeout for hung BLE/join operations

#pragma mark - Localization Helper (Auto Simplified Chinese / English)

static BOOL hkIsChinese(void) {
    static BOOL zh = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *lang = [NSLocale preferredLanguages].firstObject ?: @"en";
        zh = [lang.lowercaseString hasPrefix:@"zh"];
    });
    return zh;
}

static NSString *HKStr(NSString *zh, NSString *en) {
    return hkIsChinese() ? zh : en;
}

static double hkMonotonicSeconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

#pragma mark - Paths & Logging

static NSString *hkLogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/HotspotKeeper.log"];
}

static NSString *hkLockPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/.HotspotKeeper.lock"];
}

static NSString *hkAppSupportDir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/HotspotKeeper"];
}

static NSString *hkLeasePath(void) {
    return [hkAppSupportDir() stringByAppendingPathComponent:@"lease"];
}

static NSString *hkPlistPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/" HK_BUNDLE_ID ".plist"];
}

static NSString *hkWatchdogPlistPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/" HK_WATCHDOG_LABEL ".plist"];
}

static void (^gOnLogLine)(NSString *line) = nil;

static void HKLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    static NSDateFormatter *df = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"MM-dd HH:mm:ss";
    });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:NSDate.date], msg];
    if (isatty(STDOUT_FILENO)) {
        printf("%s", line.UTF8String);
        fflush(stdout);
    }

    NSString *path = hkLogPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attrs[NSFileSize] unsignedLongLongValue] > 2 * 1024 * 1024) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    if (gOnLogLine) {
        gOnLogLine(msg);
    }
}

#pragma mark - Preferences

static NSUserDefaults *hkPrefs(void) {
    static NSUserDefaults *u = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:HK_BUNDLE_ID]) {
            u = NSUserDefaults.standardUserDefaults;
        } else {
            u = [[NSUserDefaults alloc] initWithSuiteName:HK_BUNDLE_ID];
        }
        [u registerDefaults:@{
            @"targetName": @"",              // Empty = auto-pick first nearby same-Apple-Account iPhone
            @"paused": @NO,                  // Pause automatic hotspot reconnecting (independent from clamshell)
            @"deadWifi": @NO,                // Also switch if Wi-Fi has no internet for 30s
            @"offlineSeconds": @6,           // Seconds offline before auto-connecting
            @"clamshellKeepAwake": @NO,      // Opt-in! Default OFF (zero sudo, zero pmset changes)
            @"maxClamshellHours": @4.0,      // Max continuous closed-lid hours on battery (0 = unlimited)
        }];
    });
    return u;
}

static NSString *gTargetOverride = nil;

static NSString *hkTargetName(void) {
    if (gTargetOverride != nil) return gTargetOverride;
    NSString *s = [hkPrefs() stringForKey:@"targetName"];
    return s ?: @"";
}

static NSString *hkTargetDisplayName(void) {
    NSString *t = hkTargetName();
    return t.length > 0 ? t : HKStr(@"自动（附近首台 iPhone）", @"Auto (First Nearby iPhone)");
}

static NSString *hkNormalizeName(NSString *s) {
    if (!s) return @"";
    NSArray *parts = [s.lowercaseString componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [parts componentsJoinedByString:@""];
}

static BOOL hkNamesMatch(NSString *a, NSString *b) {
    NSString *na = hkNormalizeName(a);
    NSString *nb = hkNormalizeName(b);
    return na.length > 0 && [na isEqualToString:nb];
}

#pragma mark - Subprocess Helper with Timeout (Never Logs Passwords)

static NSString *hkRunCommandTimeout(NSString *path, NSArray<NSString *> *args, NSTimeInterval timeoutSec, int *outStatus) {
    NSTask *task = [NSTask new];
    task.launchPath = path;
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    __block BOOL finished = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *t) {
        finished = YES;
        dispatch_semaphore_signal(sem);
    };

    @try {
        [task launch];
    } @catch (NSException *ex) {
        if (outStatus) *outStatus = -1;
        return ex.reason ?: @"launch failed";
    }

    long waitRes = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSec * NSEC_PER_SEC)));
    if (waitRes != 0 && !finished) {
        [task terminate];
        usleep(200000);
        if (task.isRunning) {
            kill(task.processIdentifier, SIGKILL);
        }
        if (outStatus) *outStatus = -124;
        return @"command timed out";
    }

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    if (outStatus) *outStatus = task.terminationStatus;
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *hkRunCommand(NSString *path, NSArray<NSString *> *args, int *outStatus) {
    return hkRunCommandTimeout(path, args, 15.0, outStatus);
}

#pragma mark - Hardware, Power & Battery Telemetry

typedef struct {
    BOOL hasBattery;
    BOOL onAC;
    int percent;
} HKBatteryInfo;

static HKBatteryInfo hkBatteryInfo(void) {
    HKBatteryInfo info = { NO, YES, 100 };
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) return info;

    CFStringRef srcType = IOPSGetProvidingPowerSourceType(blob);
    if (srcType) {
        info.onAC = CFEqual(srcType, CFSTR(kIOPMACPowerKey));
    }

    CFArrayRef list = IOPSCopyPowerSourcesList(blob);
    if (list) {
        CFIndex count = CFArrayGetCount(list);
        for (CFIndex i = 0; i < count; i++) {
            CFDictionaryRef ps = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, i));
            if (!ps) continue;
            CFStringRef type = CFDictionaryGetValue(ps, CFSTR(kIOPSTypeKey));
            if (type && CFEqual(type, CFSTR(kIOPSInternalBatteryType))) {
                info.hasBattery = YES;
                CFNumberRef cur = CFDictionaryGetValue(ps, CFSTR(kIOPSCurrentCapacityKey));
                CFNumberRef max = CFDictionaryGetValue(ps, CFSTR(kIOPSMaxCapacityKey));
                int c = 0, m = 100;
                if (cur) CFNumberGetValue(cur, kCFNumberIntType, &c);
                if (max) CFNumberGetValue(max, kCFNumberIntType, &m);
                if (m > 0) info.percent = (int)((c * 100) / m);
                break;
            }
        }
        CFRelease(list);
    }
    CFRelease(blob);
    return info;
}

static BOOL hkIsLidClosed(void) {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!root) return NO;
    BOOL closed = NO;
    CFTypeRef val = IORegistryEntryCreateCFProperty(root, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    if (val) {
        if (CFGetTypeID(val) == CFBooleanGetTypeID()) {
            closed = CFBooleanGetValue(val);
        }
        CFRelease(val);
    }
    IOObjectRelease(root);
    return closed;
}

static BOOL hkReadSystemSleepDisabled(void) {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (root) {
        CFTypeRef val = IORegistryEntryCreateCFProperty(root, CFSTR("SleepDisabled"), kCFAllocatorDefault, 0);
        if (val) {
            BOOL disabled = NO;
            if (CFGetTypeID(val) == CFBooleanGetTypeID()) {
                disabled = CFBooleanGetValue(val);
            }
            CFRelease(val);
            IOObjectRelease(root);
            return disabled;
        }
        IOObjectRelease(root);
    }
    int st = 0;
    NSString *out = hkRunCommandTimeout(@"/usr/bin/pmset", @[@"-g"], 5.0, &st);
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        if ([line containsString:@"SleepDisabled"]) {
            return [line containsString:@"1"];
        }
    }
    return NO;
}

static BOOL hkIsAmphetamineRunning(void) {
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:HK_AMPHETAMINE_BUNDLE];
    return apps.count > 0;
}

static BOOL hkPowerSudoersReady(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:HK_SUDOERS_PATH];
}

static NSString *hkThermalName(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal:  return @"nominal";
        case NSProcessInfoThermalStateFair:     return @"fair";
        case NSProcessInfoThermalStateSerious:  return @"serious";
        case NSProcessInfoThermalStateCritical: return @"critical";
    }
    return @"unknown";
}

static NSString *hkTelemetryTag(void) {
    HKBatteryInfo b = hkBatteryInfo();
    return [NSString stringWithFormat:@"lid=%@ sd=%d batt=%d%%(%@) thermal=%@",
            hkIsLidClosed() ? @"closed" : @"open",
            hkReadSystemSleepDisabled() ? 1 : 0,
            b.percent,
            b.onAC ? @"AC" : @"BATT",
            hkThermalName(NSProcessInfo.processInfo.thermalState)];
}

#pragma mark - Physical Network Inspection (Surge / Clash TUN / Tailscale safe)

@interface HKPhysicalLink : NSObject
@property (nonatomic, copy) NSString *iface;
@property (nonatomic, copy) NSString *ip;
@property (nonatomic, copy) NSString *router;
@property (nonatomic) BOOL isWiFi;
@property (nonatomic) BOOL isHotspot;
@end
@implementation HKPhysicalLink
@end

static CWInterface *hkWiFiInterface(void) {
    return [[CWWiFiClient sharedWiFiClient] interface];
}

static NSString *hkWiFiIfaceName(void) {
    NSString *n = hkWiFiInterface().interfaceName;
    return n.length > 0 ? n : @"en0";
}

static BOOL hkWiFiPowerOn(void) {
    return hkWiFiInterface().powerOn;
}

static BOOL hkIsVirtualInterface(NSString *iface) {
    if (!iface.length) return YES;
    NSArray *prefixes = @[
        @"utun", @"lo", @"ipsec", @"ppp", @"bridge", @"awdl", @"llw",
        @"anpi", @"ap", @"gif", @"stf", @"feth", @"vmenet", @"vmnet", @"vnic"
    ];
    for (NSString *p in prefixes) {
        if ([iface hasPrefix:p]) return YES;
    }
    return NO;
}

// Fail-closed: if Link key is unreadable/missing, treat link as inactive for sleep safety.
static BOOL hkIsLinkActive(SCDynamicStoreRef store, NSString *iface) {
    NSString *key = [NSString stringWithFormat:@"State:/Network/Interface/%@/Link", iface];
    NSDictionary *d = (__bridge_transfer NSDictionary *)SCDynamicStoreCopyValue(store, (__bridge CFStringRef)key);
    if (![d isKindOfClass:NSDictionary.class]) return NO;
    NSNumber *active = d[@"Active"];
    return active ? active.boolValue : NO;
}

static NSArray<HKPhysicalLink *> *hkPhysicalLinks(void) {
    NSMutableArray<HKPhysicalLink *> *result = [NSMutableArray array];
    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("HotspotKeeper"), NULL, NULL);
    if (!store) return result;

    NSString *wifiIface = hkWiFiIfaceName();
    NSArray *keys = (__bridge_transfer NSArray *)SCDynamicStoreCopyKeyList(store, CFSTR("State:/Network/Service/.*/IPv4"));
    for (NSString *key in keys) {
        NSDictionary *d = (__bridge_transfer NSDictionary *)SCDynamicStoreCopyValue(store, (__bridge CFStringRef)key);
        if (![d isKindOfClass:NSDictionary.class]) continue;
        NSString *iface = d[@"InterfaceName"];
        if (hkIsVirtualInterface(iface)) continue;

        NSArray *addrs = d[@"Addresses"];
        NSString *ip = ([addrs isKindOfClass:NSArray.class] && addrs.count > 0) ? addrs.firstObject : nil;
        NSString *router = d[@"Router"];
        if (!ip.length || [ip hasPrefix:@"169.254."] || [ip hasPrefix:@"127."]) continue;
        if (!router.length) continue;
        if (!hkIsLinkActive(store, iface)) continue;

        HKPhysicalLink *link = [HKPhysicalLink new];
        link.iface = iface;
        link.ip = ip;
        link.router = router;
        link.isWiFi = [iface isEqualToString:wifiIface];
        // iPhone Personal Hotspot (Wi-Fi or USB) hands out 172.20.10.x / gateway 172.20.10.1
        link.isHotspot = ([router hasPrefix:@"172.20.10."] || [ip hasPrefix:@"172.20.10."]);
        [result addObject:link];
    }
    CFRelease(store);
    return result;
}

static HKPhysicalLink *hkPrimaryPhysicalLink(void) {
    NSArray<HKPhysicalLink *> *links = hkPhysicalLinks();
    if (links.count == 0) return nil;
    for (HKPhysicalLink *l in links) {
        if (!l.isHotspot && !l.isWiFi) return l;
    }
    for (HKPhysicalLink *l in links) {
        if (!l.isHotspot) return l;
    }
    return links.firstObject;
}

static BOOL hkHasPhysicalLink(void) {
    return hkPrimaryPhysicalLink() != nil;
}

static BOOL hkOnHotspot(void) {
    for (HKPhysicalLink *l in hkPhysicalLinks()) {
        if (l.isHotspot) return YES;
    }
    return NO;
}

static BOOL hkInternetOK(void) {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 4.0;
    cfg.timeoutIntervalForResource = 5.0;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];
    NSURL *url = [NSURL URLWithString:@"https://captive.apple.com/hotspot-detect.html"];
    [[sess dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data.length > 0 && !err) {
            NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            ok = [body containsString:@"Success"];
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
    [sess invalidateAndCancel];
    return ok;
}

static BOOL hkJoinWiFiSSID(NSString *ssid, NSString *password, NSString **outMsg) {
    if (!ssid.length) return NO;
    NSString *iface = hkWiFiIfaceName();
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-setairportnetwork", iface, ssid, nil];
    if (password.length > 0) {
        [args addObject:password];
    }
    int status = 0;
    NSString *out = hkRunCommandTimeout(@"/usr/sbin/networksetup", args, 15.0, &status);
    if (outMsg) *outMsg = out;
    if (status != 0) return NO;
    if ([out localizedCaseInsensitiveContainsString:@"Could not find"] ||
        [out localizedCaseInsensitiveContainsString:@"Failed to join"] ||
        [out localizedCaseInsensitiveContainsString:@"Error:"]) {
        return NO;
    }
    return YES;
}

#pragma mark - Clamshell Power Guard (Opt-in, 3-Layer Fail-Safe)

typedef NS_ENUM(NSInteger, HKPowerState) {
    HKPowerStateDisabled = 0,       // Feature off (default)
    HKPowerStateBlockedConflict,    // Amphetamine running or sudoers not installed
    HKPowerStateArmedOnline,        // SleepDisabled=1 (online & safe)
    HKPowerStateArmedGrace,         // SleepDisabled=1 (offline grace window while reconnecting)
    HKPowerStateReleasedLatched,    // Released to SleepDisabled=0; locked until lid open or full wake
};

@interface HKPowerGuard : NSObject
@property (atomic) HKPowerState state;
@property (atomic) BOOL ownsSleepDisabled;
@property (atomic, copy) NSString *statusReason;
@property (atomic) double graceRemainingSec;
@property (atomic) double clamshellBattElapsedSec;
@property (atomic) int graceRoundsCompleted;

@property (nonatomic) BOOL lowBatteryLatched;
@property (nonatomic) double offlineSinceMono;
@property (nonatomic) double deadInternetSinceMono;
@property (nonatomic) double clamshellBattStartMono;
@property (nonatomic) double lastLeaseWriteMono;
@property (nonatomic) double releasedAtMono;
@property (nonatomic) BOOL releasedWhileClosed;
@property (nonatomic) BOOL pendingSleepNowAfterRelease;
@property (nonatomic) IOPMAssertionID idleAssertionID;
@property (nonatomic) BOOL hasIdleAssertion;
@property (nonatomic, copy) void (^onStateChanged)(void);

- (void)evaluateWithPhysicalLink:(BOOL)hasLink internetOK:(BOOL)internetOK;
- (void)noteReconnectRoundCompleted;
- (void)onFullWake;
- (void)releaseForShutdownReason:(NSString *)reason;
- (void)sleepNow;
- (BOOL)isInGracePeriod;
- (NSString *)menuStatusLine;
@end

static HKPowerGuard *gPowerGuard = nil;

@implementation HKPowerGuard

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = HKPowerStateDisabled;
        _statusReason = @"";
        // Startup self-check: if a stale lease file exists from a previous crash, assume ownership so we clean it safely.
        if ([[NSFileManager defaultManager] fileExistsAtPath:hkLeasePath()]) {
            _ownsSleepDisabled = YES;
        }
    }
    return self;
}

- (void)notify {
    if (self.onStateChanged) {
        dispatch_async(dispatch_get_main_queue(), self.onStateChanged);
    }
}

- (BOOL)isInGracePeriod {
    return self.state == HKPowerStateArmedGrace;
}

- (void)writeLeaseFile {
    NSString *dir = hkAppSupportDir();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *content = [NSString stringWithFormat:@"owner=%@\npid=%d\nts=%.0f\n",
                         HK_BUNDLE_ID, getpid(), NSDate.date.timeIntervalSince1970];
    [content writeToFile:hkLeasePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    self.lastLeaseWriteMono = hkMonotonicSeconds();
}

- (void)removeLeaseFile {
    [[NSFileManager defaultManager] removeItemAtPath:hkLeasePath() error:nil];
    self.lastLeaseWriteMono = 0;
}

- (void)acquireIdleAssertion {
    if (self.hasIdleAssertion) return;
    IOPMAssertionID aid = 0;
    IOReturn r = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionLevelOn,
        CFSTR("HotspotKeeper Clamshell Keep-Awake"),
        &aid
    );
    if (r == kIOReturnSuccess) {
        self.idleAssertionID = aid;
        self.hasIdleAssertion = YES;
    }
}

- (void)releaseIdleAssertion {
    if (!self.hasIdleAssertion) return;
    IOPMAssertionRelease(self.idleAssertionID);
    self.idleAssertionID = 0;
    self.hasIdleAssertion = NO;
}

- (BOOL)applySystemSleepDisabled:(BOOL)disable reason:(NSString *)reason {
    BOOL current = hkReadSystemSleepDisabled();
    if (disable) {
        // Ownership guard: if an external tool already set SleepDisabled=1 and we don't own it, do NOT hijack it.
        if (current && !self.ownsSleepDisabled) {
            return NO;
        }
        [self acquireIdleAssertion];
        if (!current) {
            int st = 0;
            NSString *out = hkRunCommandTimeout(@"/usr/bin/sudo", @[@"-n", @"/usr/bin/pmset", @"-a", @"disablesleep", @"1"], 8.0, &st);
            if (st != 0) {
                HKLog(HKStr(@"开启合盖防休眠失败（sudo pmset 退出码 %d：%@）[%@]",
                            @"Failed to set disablesleep 1 (exit %d: %@) [%@]"),
                      st, out, hkTelemetryTag());
                return NO;
            }
            HKLog(HKStr(@"合盖防休眠已开启（%@）[%@]", @"Clamshell keep-awake ARMED (%@) [%@]"),
                  reason, hkTelemetryTag());
        }
        self.ownsSleepDisabled = YES;
        [self writeLeaseFile];
        return YES;
    } else {
        [self releaseIdleAssertion];
        if (self.ownsSleepDisabled) {
            if (current) {
                int st = 0;
                NSString *out = hkRunCommandTimeout(@"/usr/bin/sudo", @[@"-n", @"/usr/bin/pmset", @"-a", @"disablesleep", @"0"], 8.0, &st);
                if (st != 0) {
                    HKLog(HKStr(@"释放合盖防休眠失败（sudo pmset 退出码 %d：%@）[%@]",
                                @"Failed to reset disablesleep 0 (exit %d: %@) [%@]"),
                          st, out, hkTelemetryTag());
                } else {
                    HKLog(HKStr(@"合盖防休眠已释放（%@）[%@]", @"Clamshell keep-awake RELEASED (%@) [%@]"),
                          reason, hkTelemetryTag());
                }
            }
            self.ownsSleepDisabled = NO;
            [self removeLeaseFile];
        }
        return YES;
    }
}

- (void)transitionToReleasedWithReason:(NSString *)reason forceSleepIfClosed:(BOOL)forceSleep immediateSleep:(BOOL)immediateSleep {
    BOOL lidClosed = hkIsLidClosed();
    BOOL wasArmed = (self.ownsSleepDisabled || self.state == HKPowerStateArmedOnline || self.state == HKPowerStateArmedGrace);
    [self applySystemSleepDisabled:NO reason:reason];
    self.graceRemainingSec = 0;
    self.offlineSinceMono = 0;
    self.deadInternetSinceMono = 0;
    self.clamshellBattStartMono = 0;
    self.clamshellBattElapsedSec = 0;
    self.graceRoundsCompleted = 0;
    self.releasedAtMono = hkMonotonicSeconds();
    self.releasedWhileClosed = lidClosed;

    if (lidClosed) {
        self.state = HKPowerStateReleasedLatched;
        self.statusReason = reason;
        if (immediateSleep && forceSleep) {
            self.pendingSleepNowAfterRelease = NO;
            HKLog(HKStr(@"%@，立即执行 pmset sleepnow [%@]", @"%@; running immediate pmset sleepnow [%@]"), reason, hkTelemetryTag());
            hkRunCommandTimeout(@"/usr/bin/pmset", @[@"sleepnow"], 5.0, NULL);
        } else {
            self.pendingSleepNowAfterRelease = forceSleep;
        }
    } else {
        // Lid is open: stay in non-latched standby (avoid 5s DarkWake unlatch log spam).
        if (wasArmed || ![self.statusReason isEqualToString:reason]) {
            HKLog(HKStr(@"合盖防休眠暂不启用：%@ [%@]", @"Clamshell keep-awake paused: %@ [%@]"), reason, hkTelemetryTag());
        }
        self.state = HKPowerStateDisabled;
        self.statusReason = reason;
        self.pendingSleepNowAfterRelease = NO;
    }
    [self notify];
}

- (void)noteReconnectRoundCompleted {
    if (self.state == HKPowerStateArmedGrace) {
        self.graceRoundsCompleted++;
    }
}

- (void)onFullWake {
    if (self.state == HKPowerStateReleasedLatched) {
        HKLog(HKStr(@"检测到完整系统唤醒，解除合盖放行锁存 [%@]",
                    @"Full system wake detected; clearing released latch [%@]"), hkTelemetryTag());
        self.state = HKPowerStateDisabled; // Re-evaluated immediately on next power tick
        self.pendingSleepNowAfterRelease = NO;
        self.releasedWhileClosed = NO;
        self.clamshellBattStartMono = 0;
        self.offlineSinceMono = 0;
        self.deadInternetSinceMono = 0;
    }
}

- (void)releaseForShutdownReason:(NSString *)reason {
    [self applySystemSleepDisabled:NO reason:reason];
    self.state = HKPowerStateDisabled;
    self.statusReason = reason;
    self.pendingSleepNowAfterRelease = NO;
    self.releasedWhileClosed = NO;
}

- (void)sleepNow {
    HKLog(HKStr(@"用户触发「立即睡眠」，正在释放合盖防休眠并休眠 [%@]",
                @"User requested Sleep Now; releasing disablesleep and sleeping [%@]"), hkTelemetryTag());
    [self releaseIdleAssertion];
    if (hkReadSystemSleepDisabled() && hkPowerSudoersReady()) {
        hkRunCommandTimeout(@"/usr/bin/sudo", @[@"-n", @"/usr/bin/pmset", @"-a", @"disablesleep", @"0"], 8.0, NULL);
    }
    self.ownsSleepDisabled = NO;
    [self removeLeaseFile];
    self.state = HKPowerStateReleasedLatched;
    self.releasedAtMono = hkMonotonicSeconds();
    self.releasedWhileClosed = NO;
    self.statusReason = HKStr(@"用户手动睡眠", @"Manual sleep");
    self.pendingSleepNowAfterRelease = NO;
    [self notify];
    hkRunCommandTimeout(@"/usr/bin/pmset", @[@"sleepnow"], 5.0, NULL);
}

// Called independently every 5 seconds on dedicated power queue (never blocked by network busy state).
- (void)evaluateWithPhysicalLink:(BOOL)hasLink internetOK:(BOOL)internetOK {
    CFPreferencesAppSynchronize((__bridge CFStringRef)HK_BUNDLE_ID);
    double now = hkMonotonicSeconds();
    BOOL enabled = [hkPrefs() boolForKey:@"clamshellKeepAwake"];
    BOOL lidClosed = hkIsLidClosed();
    HKBatteryInfo batt = hkBatteryInfo();
    NSProcessInfoThermalState thermal = NSProcessInfo.processInfo.thermalState;

    // 0. If feature is OFF, ensure we clean up any stale lease we own.
    if (!enabled) {
        if (self.ownsSleepDisabled || self.hasIdleAssertion) {
            [self applySystemSleepDisabled:NO reason:HKStr(@"合盖保活开关已关闭", @"Clamshell mode turned off")];
        }
        if (self.state != HKPowerStateDisabled) {
            self.state = HKPowerStateDisabled;
            self.statusReason = @"";
            self.graceRemainingSec = 0;
            self.clamshellBattStartMono = 0;
            self.clamshellBattElapsedSec = 0;
            self.pendingSleepNowAfterRelease = NO;
            self.releasedWhileClosed = NO;
            [self notify];
        }
        return;
    }

    // 1. Mutual exclusion with Amphetamine & prerequisite check.
    if (hkIsAmphetamineRunning()) {
        if (self.ownsSleepDisabled || self.hasIdleAssertion) {
            [self applySystemSleepDisabled:NO reason:HKStr(@"检测到 Amphetamine 正在运行，已自动避让", @"Amphetamine running; yielding")];
        }
        NSString *r = HKStr(@"已停用：检测到 Amphetamine 正在运行（避免冲突）",
                            @"Paused: Amphetamine is running (conflict guard)");
        if (self.state != HKPowerStateBlockedConflict || ![self.statusReason isEqualToString:r]) {
            self.state = HKPowerStateBlockedConflict;
            self.statusReason = r;
            HKLog(@"%@", r);
            [self notify];
        }
        return;
    }
    if (!hkPowerSudoersReady()) {
        NSString *r = HKStr(@"未完成电源授权（请运行 hotspot-keeper --setup-clamshell）",
                            @"Power helper not installed (run hotspot-keeper --setup-clamshell)");
        if (self.state != HKPowerStateBlockedConflict || ![self.statusReason isEqualToString:r]) {
            self.state = HKPowerStateBlockedConflict;
            self.statusReason = r;
            [self notify];
        }
        return;
    }

    // 2. DarkWake protection: if we released while lid was closed, do NOT re-arm until lid opens (or onFullWake).
    if (self.state == HKPowerStateReleasedLatched) {
        if (!lidClosed) {
            // If user clicked "Sleep Now" while lid was open, wait at least 15s before assuming sleep didn't happen.
            if (self.releasedWhileClosed || (now - self.releasedAtMono) >= 15.0) {
                HKLog(HKStr(@"检测到开盖，恢复合盖保活监控 [%@]", @"Lid opened; resuming clamshell monitor [%@]"), hkTelemetryTag());
                self.state = HKPowerStateDisabled;
                self.pendingSleepNowAfterRelease = NO;
                self.releasedWhileClosed = NO;
                self.clamshellBattStartMono = 0;
            } else {
                return;
            }
        } else {
            // If powerd didn't sleep within 10s after we released disablesleep=0 while closed, nudge it with pmset sleepnow.
            if (self.pendingSleepNowAfterRelease && (now - self.releasedAtMono) >= 10.0) {
                self.pendingSleepNowAfterRelease = NO;
                HKLog(HKStr(@"合盖释放后 10 秒仍未休眠，主动执行 pmset sleepnow [%@]",
                            @"Still awake 10s after release while closed; running pmset sleepnow [%@]"), hkTelemetryTag());
                hkRunCommandTimeout(@"/usr/bin/pmset", @[@"sleepnow"], 5.0, NULL);
            }
            return;
        }
    }

    // 3. Hard thermal safety guard (Serious or Critical -> immediate release + immediate sleep if closed).
    if (thermal >= NSProcessInfoThermalStateSerious) {
        NSString *r = [NSString stringWithFormat:HKStr(@"触发过热保护（thermal=%@）", @"Thermal protection triggered (%@)"),
                       hkThermalName(thermal)];
        [self transitionToReleasedWithReason:r forceSleepIfClosed:YES immediateSleep:YES];
        return;
    }

    // 4. Battery guard with hysteresis (release < 20% unplugged; require >= 25% or AC to re-arm).
    if (batt.hasBattery && !batt.onAC) {
        if (batt.percent < HK_BATT_RELEASE_PCT) {
            self.lowBatteryLatched = YES;
        } else if (batt.percent >= HK_BATT_REARM_PCT) {
            self.lowBatteryLatched = NO;
        }
        if (self.lowBatteryLatched) {
            NSString *r = [NSString stringWithFormat:HKStr(@"电池低电量保护（%d%% < %d%%）", @"Low battery guard (%d%% < %d%%)"),
                           batt.percent, HK_BATT_RELEASE_PCT];
            [self transitionToReleasedWithReason:r forceSleepIfClosed:YES immediateSleep:NO];
            return;
        }
    } else {
        self.lowBatteryLatched = NO;
    }

    // 5. Max continuous closed-lid duration on battery (monotonic clock; unlimited on AC).
    double maxHours = [hkPrefs() doubleForKey:@"maxClamshellHours"];
    if (lidClosed && batt.hasBattery && !batt.onAC) {
        if (self.clamshellBattStartMono <= 0) {
            self.clamshellBattStartMono = now;
        }
        self.clamshellBattElapsedSec = now - self.clamshellBattStartMono;
        if (maxHours > 0 && self.clamshellBattElapsedSec >= maxHours * 3600.0) {
            NSString *r = [NSString stringWithFormat:HKStr(@"达到电池合盖最长保活上限（%.0f 小时）",
                                                           @"Reached max closed-lid battery duration (%.0fh)"), maxHours];
            [self transitionToReleasedWithReason:r forceSleepIfClosed:YES immediateSleep:NO];
            return;
        }
    } else {
        self.clamshellBattStartMono = 0;
        self.clamshellBattElapsedSec = 0;
    }

    // 6. Network & internet evaluation (with 120s / >=3 rounds grace period, 180s hard cap).
    if (hasLink) {
        self.offlineSinceMono = 0;
        self.graceRoundsCompleted = 0;
        self.graceRemainingSec = 0;

        if (internetOK) {
            self.deadInternetSinceMono = 0;
        } else {
            if (self.deadInternetSinceMono <= 0) {
                self.deadInternetSinceMono = now;
            }
            if ((now - self.deadInternetSinceMono) >= HK_DEAD_LINK_MAX_SECONDS) {
                NSString *r = HKStr(@"有物理链路但连续 4 分钟无外网，放行休眠",
                                    @"Physical link has no internet for 4 min; releasing sleep");
                [self transitionToReleasedWithReason:r forceSleepIfClosed:YES immediateSleep:NO];
                return;
            }
        }

        // Armed & Online
        BOOL armed = [self applySystemSleepDisabled:YES reason:HKStr(@"网络在线", @"network online")];
        if (armed) {
            self.state = HKPowerStateArmedOnline;
            self.statusReason = internetOK ? HKStr(@"网络在线，合盖防休眠生效中", @"Online · Clamshell keep-awake active")
                                           : HKStr(@"有局域网链路（检测外网中）", @"LAN active (checking internet)");
            if ((now - self.lastLeaseWriteMono) >= 15.0) {
                [self writeLeaseFile];
            }
        } else if (hkReadSystemSleepDisabled() && !self.ownsSleepDisabled) {
            NSString *r = HKStr(@"已避让：检测到外部工具已持有 SleepDisabled=1",
                                @"Yielded: external tool already holds SleepDisabled=1");
            if (self.state != HKPowerStateBlockedConflict || ![self.statusReason isEqualToString:r]) {
                self.state = HKPowerStateBlockedConflict;
                self.statusReason = r;
                HKLog(@"%@ [%@]", r, hkTelemetryTag());
            }
        }
        [self notify];
    } else {
        // Offline: if we were already armed, enter / stay in reconnect grace period.
        self.deadInternetSinceMono = 0;
        if (self.ownsSleepDisabled || self.state == HKPowerStateArmedOnline || self.state == HKPowerStateArmedGrace) {
            if (self.offlineSinceMono <= 0) {
                self.offlineSinceMono = now;
                self.graceRoundsCompleted = 0;
                HKLog(HKStr(@"进入断网重连宽限期（最长 %.0f 秒 / 至少 %d 轮重连）[%@]",
                            @"Entering offline reconnect grace period (min %.0fs / %d rounds, cap %.0fs) [%@]"),
                      HK_GRACE_MIN_SECONDS, HK_GRACE_MIN_ROUNDS, HK_GRACE_HARD_CAP_SECONDS, hkTelemetryTag());
            }
            double elapsed = now - self.offlineSinceMono;
            BOOL hardExpired = (elapsed >= HK_GRACE_HARD_CAP_SECONDS);
            BOOL graceDone = (elapsed >= HK_GRACE_MIN_SECONDS && self.graceRoundsCompleted >= HK_GRACE_MIN_ROUNDS);
            if (hardExpired || graceDone) {
                NSString *r = [NSString stringWithFormat:HKStr(@"断网重连宽限期已满（%.0f 秒，已完成 %d 轮）",
                                                               @"Offline grace expired (%.0fs, %d rounds)"),
                               elapsed, self.graceRoundsCompleted];
                [self transitionToReleasedWithReason:r forceSleepIfClosed:YES immediateSleep:NO];
                return;
            }
            self.state = HKPowerStateArmedGrace;
            double targetEnd = (self.graceRoundsCompleted >= HK_GRACE_MIN_ROUNDS) ? HK_GRACE_MIN_SECONDS : HK_GRACE_HARD_CAP_SECONDS;
            self.graceRemainingSec = MAX(0.0, targetEnd - elapsed);
            self.statusReason = [NSString stringWithFormat:HKStr(@"断网宽限保活中（已 %.0fs · 第 %d 轮）",
                                                                 @"Grace keep-awake (%.0fs · round %d)"),
                                 elapsed, self.graceRoundsCompleted];
            if ((now - self.lastLeaseWriteMono) >= 15.0) {
                [self writeLeaseFile];
            }
            // Self-heal: if SleepDisabled somehow flipped to 0 during grace, re-arm.
            if (!hkReadSystemSleepDisabled()) {
                [self applySystemSleepDisabled:YES reason:HKStr(@"宽限期自愈重锁", @"grace self-heal")];
            }
            [self notify];
        } else {
            // Started offline and not armed: do not arm while offline.
            self.state = HKPowerStateDisabled;
            self.statusReason = HKStr(@"当前离线，等待联网后自动启用合盖防休眠", @"Offline · waiting for network to arm");
            [self notify];
        }
    }
}

- (NSString *)menuStatusLine {
    HKBatteryInfo b = hkBatteryInfo();
    switch (self.state) {
        case HKPowerStateDisabled:
            if (![hkPrefs() boolForKey:@"clamshellKeepAwake"]) {
                return HKStr(@"合盖防休眠：关闭（默认）", @"Clamshell Keep-Awake: Off");
            }
            return self.statusReason.length > 0 ? self.statusReason
                                                : HKStr(@"合盖防休眠：待机（联网后自动激活）", @"Clamshell Keep-Awake: Standby");
        case HKPowerStateBlockedConflict:
            return self.statusReason;
        case HKPowerStateArmedOnline: {
            if (self.clamshellBattElapsedSec > 60) {
                return [NSString stringWithFormat:HKStr(@"合盖防休眠：生效中（电量 %d%% · 已合盖 %.0f 分钟）",
                                                        @"Clamshell Active (%d%% · closed %.0fm)"),
                        b.percent, self.clamshellBattElapsedSec / 60.0];
            }
            return [NSString stringWithFormat:HKStr(@"合盖防休眠：生效中（电量 %d%%%@）",
                                                    @"Clamshell Active (%d%%%@)"),
                    b.percent, b.onAC ? HKStr(@" · 插电", @" · AC") : @""];
        }
        case HKPowerStateArmedGrace:
            return [NSString stringWithFormat:HKStr(@"合盖防休眠：断网宽限中（剩 %.0f 秒）",
                                                    @"Clamshell Grace (%.0fs left)"),
                    self.graceRemainingSec];
        case HKPowerStateReleasedLatched:
            return [NSString stringWithFormat:HKStr(@"合盖防休眠：已放行休眠（%@）",
                                                    @"Clamshell Released (%@)"),
                    self.statusReason];
    }
    return @"";
}

@end

#pragma mark - Hotspot Keeper Core

static NSString *hkSafeDeviceName(id dev) {
    if (!dev) return @"";
    @try {
        id v = [dev valueForKey:@"deviceName"];
        if ([v isKindOfClass:NSString.class]) return v;
    } @catch (NSException *ignored) {}
    return @"";
}

static NSString *hkSafeDeviceSummary(id dev) {
    NSString *name = hkSafeDeviceName(dev);
    NSMutableArray *extra = [NSMutableArray array];
    @try {
        id batt = [dev valueForKey:@"batteryLife"];
        if ([batt isKindOfClass:NSNumber.class] && [batt integerValue] > 0) {
            [extra addObject:[NSString stringWithFormat:HKStr(@"电量 %ld%%", @"%ld%%"), (long)[batt integerValue]]];
        }
    } @catch (NSException *ignored) {}
    @try {
        id sig = [dev valueForKey:@"signalStrength"];
        if ([sig isKindOfClass:NSNumber.class] && [sig integerValue] > 0) {
            [extra addObject:[NSString stringWithFormat:HKStr(@"信号 %@", @"sig %@"), sig]];
        }
    } @catch (NSException *ignored) {}
    if (extra.count > 0) {
        return [NSString stringWithFormat:HKStr(@"%@（%@）", @"%@ (%@)"),
                name, [extra componentsJoinedByString:HKStr(@"，", @", ")]];
    }
    return name;
}

@interface HKController : NSObject
@property (nonatomic, strong) id session; // SFRemoteHotspotSession
@property (nonatomic, strong) HKPowerGuard *powerGuard;
@property (atomic, copy) NSArray *devices;
@property (atomic) BOOL busy;
@property (atomic) double busySinceMono;
@property (atomic) BOOL internetOK;
@property (atomic, copy) NSString *phase;

@property (nonatomic) BOOL cliOnce;
@property (nonatomic) BOOL cliListOnly;
@property (nonatomic) BOOL cliWakeOnly;
@property (nonatomic) BOOL cliForce;

@property (nonatomic) BOOL lastKnownHasLink;
@property (nonatomic) int downTicks;
@property (nonatomic) int deadWifiTicks;
@property (nonatomic) int tickCount;
@property (nonatomic) int consecutiveFails;
@property (nonatomic, strong) NSDate *lastAttemptAt;
@property (nonatomic, strong) NSDate *lastBrowseRestartAt;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *memPasswords; // RAM-only
@property (nonatomic) BOOL loggedTargetMissing;
@property (nonatomic, copy) void (^onStateChanged)(void);

- (id)matchingTargetDevice;
- (NSArray<NSString *> *)discoveredDeviceNames;
- (void)startBrowsing;
- (void)restartBrowsingForce:(BOOL)force;
- (void)tick;
- (void)onNetworkEvent;
- (void)onSystemWake;
- (void)connectNow:(BOOL)force reason:(NSString *)reason;
@end

@implementation HKController

- (instancetype)init {
    self = [super init];
    if (self) {
        _devices = @[];
        _internetOK = YES;
        _lastKnownHasLink = hkHasPhysicalLink();
        _memPasswords = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)notifyUI {
    if (self.onStateChanged) {
        dispatch_async(dispatch_get_main_queue(), self.onStateChanged);
    }
}

- (void)setPhaseAndNotify:(NSString *)p {
    self.phase = p;
    [self notifyUI];
}

- (void)startBrowsing {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startBrowsing]; });
        return;
    }
    dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW);
    Class cls = NSClassFromString(@"SFRemoteHotspotSession");
    if (!cls) {
        HKLog(@"%@", HKStr(@"警告：当前 macOS 缺少 SFRemoteHotspotSession，将仅使用 Wi-Fi 直连兜底",
                           @"Warning: SFRemoteHotspotSession unavailable; falling back to Wi-Fi direct join only"));
        return;
    }
    self.session = [cls new];
    if (!self.session) return;
    self.lastBrowseRestartAt = NSDate.date;
    [self.session setValue:self forKey:@"delegate"];
    ((void(*)(id, SEL))objc_msgSend)(self.session, NSSelectorFromString(@"startBrowsing"));
}

- (void)restartBrowsingForce:(BOOL)force {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self restartBrowsingForce:force]; });
        return;
    }
    if (!force && self.lastBrowseRestartAt && -self.lastBrowseRestartAt.timeIntervalSinceNow < 6.0) {
        return;
    }
    if (self.session) {
        @try {
            SEL stopSel = NSSelectorFromString(@"stopBrowsing");
            if ([self.session respondsToSelector:stopSel]) {
                ((void(*)(id, SEL))objc_msgSend)(self.session, stopSel);
            }
            [self.session setValue:nil forKey:@"delegate"];
        } @catch (NSException *ignored) {}
        self.session = nil;
    }
    [self startBrowsing];
}

- (void)cachePassword:(NSString *)pw forSSID:(NSString *)ssid {
    if (!ssid.length || !pw.length) return;
    @synchronized (self.memPasswords) {
        self.memPasswords[hkNormalizeName(ssid)] = [pw copy];
    }
}

- (NSString *)cachedPasswordForSSID:(NSString *)ssid {
    if (!ssid.length) return nil;
    @synchronized (self.memPasswords) {
        return self.memPasswords[hkNormalizeName(ssid)];
    }
}

- (NSArray<NSString *> *)discoveredDeviceNames {
    NSMutableArray *names = [NSMutableArray array];
    for (id d in self.devices) {
        NSString *n = hkSafeDeviceName(d);
        if (n.length > 0 && ![names containsObject:n]) [names addObject:n];
    }
    return names;
}

- (id)matchingTargetDevice {
    NSString *target = hkTargetName();
    if (target.length == 0) {
        return self.devices.firstObject;
    }
    for (id d in self.devices) {
        if (hkNamesMatch(hkSafeDeviceName(d), target)) {
            return d;
        }
    }
    return nil;
}

// SFRemoteHotspotSessionDelegate
- (void)session:(id)session updatedFoundDevices:(NSArray *)list {
    self.devices = list ?: @[];
    if ([self matchingTargetDevice]) {
        self.loggedTargetMissing = NO;
    }
    [self notifyUI];

    if (self.cliListOnly) {
        if (self.devices.count > 0 && !self.busy) {
            self.busy = YES;
            self.busySinceMono = hkMonotonicSeconds();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                printf("%s\n", [NSString stringWithFormat:HKStr(@"发现 %lu 台支持即时热点的同账号设备：",
                                                                @"Found %lu Instant Hotspot device(s):"),
                                (unsigned long)self.devices.count].UTF8String);
                NSString *target = hkTargetName();
                for (id d in self.devices) {
                    BOOL match = (target.length == 0 && d == self.devices.firstObject) || hkNamesMatch(hkSafeDeviceName(d), target);
                    printf("  %s %s\n", match ? "*" : "-", hkSafeDeviceSummary(d).UTF8String);
                }
                exit(0);
            });
        }
        return;
    }

    if (self.cliOnce && !self.busy) {
        if ([self matchingTargetDevice]) {
            [self connectNow:self.cliForce reason:HKStr(@"命令行触发", @"CLI trigger")];
        }
    }
}

- (NSTimeInterval)currentCooldown {
    // During clamshell offline grace period, clear retry backoff so we run full fresh rounds immediately.
    if (self.powerGuard && [self.powerGuard isInGracePeriod]) {
        return 2.0;
    }
    switch (self.consecutiveFails) {
        case 0: return 8;
        case 1: return 15;
        case 2: return 30;
        case 3: return 60;
        default: return 120;
    }
}

- (void)onSystemWake {
    HKLog(HKStr(@"系统已唤醒，刷新蓝牙扫描并重置冷却计数 [%@]",
                @"System woke up; refreshing BLE browse & resetting backoff [%@]"), hkTelemetryTag());
    self.lastAttemptAt = nil;
    self.consecutiveFails = 0;
    self.loggedTargetMissing = NO;
    self.downTicks = 1;
    self.deadWifiTicks = 0;
    [self.powerGuard onFullWake];
    [self restartBrowsingForce:YES];
    [self notifyUI];
}

- (void)onNetworkEvent {
    BOOL nowHasLink = hkHasPhysicalLink();
    if (nowHasLink) {
        self.downTicks = 0;
        if (hkOnHotspot()) {
            self.consecutiveFails = 0;
        }
    } else if (self.lastKnownHasLink && !nowHasLink) {
        [self restartBrowsingForce:NO];
    }
    self.lastKnownHasLink = nowHasLink;
    [self notifyUI];
}

- (void)tick {
    // Watchdog: prevent hung BLE callbacks from sticking busy=YES forever.
    if (self.busy) {
        if (self.busySinceMono > 0 && (hkMonotonicSeconds() - self.busySinceMono) >= HK_BUSY_TIMEOUT_SECONDS) {
            HKLog(HKStr(@"检测到连接任务超过 %.0f 秒无响应，强制复位状态 [%@]",
                        @"Connect task stuck > %.0fs; resetting busy state [%@]"),
                  HK_BUSY_TIMEOUT_SECONDS, hkTelemetryTag());
            self.busy = NO;
            self.busySinceMono = 0;
            self.consecutiveFails++;
            [self.powerGuard noteReconnectRoundCompleted];
            [self setPhaseAndNotify:nil];
        } else {
            return;
        }
    }
    self.tickCount++;

    if (!hkWiFiPowerOn()) {
        self.downTicks = 0;
        self.deadWifiTicks = 0;
        [self notifyUI];
        return;
    }

    BOOL hasLink = hkHasPhysicalLink();
    self.lastKnownHasLink = hasLink;
    BOOL onHS = hkOnHotspot();
    BOOL paused = [hkPrefs() boolForKey:@"paused"];
    int offlineThreshold = MAX(1, (int)(([hkPrefs() integerForKey:@"offlineSeconds"] + 2) / 3));

    NSString *reason = nil;
    BOOL forceSwitch = NO;

    if (!hasLink) {
        self.deadWifiTicks = 0;
        if (self.internetOK) {
            self.internetOK = NO;
            [self notifyUI];
        }
        self.downTicks++;
        if (self.downTicks >= offlineThreshold) {
            reason = [NSString stringWithFormat:HKStr(@"物理网卡断网 %d 秒", @"Physical link offline for %ds"),
                      self.downTicks * 3];
        }
    } else {
        self.downTicks = 0;
        if (self.tickCount % 5 == 0) {
            BOOL ok = hkInternetOK();
            if (ok != self.internetOK) {
                self.internetOK = ok;
                [self notifyUI];
            }
            if (ok) {
                self.deadWifiTicks = 0;
                self.consecutiveFails = 0;
                self.loggedTargetMissing = NO;
            } else if (!onHS && [hkPrefs() boolForKey:@"deadWifi"]) {
                self.deadWifiTicks++;
                if (self.deadWifiTicks >= 2) {
                    reason = HKStr(@"当前 Wi-Fi 连续 30 秒无外网", @"Wi-Fi has no internet for 30s");
                    forceSwitch = YES;
                }
            }
        }
    }

    if (!reason || paused) return;
    if (self.lastAttemptAt && -self.lastAttemptAt.timeIntervalSinceNow < [self currentCooldown]) {
        return;
    }

    [self connectNow:forceSwitch reason:reason];
}

- (void)connectNow:(BOOL)force reason:(NSString *)reason {
    if (self.busy) return;
    self.busy = YES;
    self.busySinceMono = hkMonotonicSeconds();
    self.lastAttemptAt = NSDate.date;

    NSString *target = hkTargetName();
    HKLog(HKStr(@"%@ -> 准备连接目标热点「%@」[%@]", @"%@ -> connecting to target hotspot \"%@\" [%@]"),
          reason, hkTargetDisplayName(), hkTelemetryTag());

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL inGrace = (self.powerGuard && [self.powerGuard isInGracePeriod]);
        // Refresh BLE session whenever target is missing OR on every grace round.
        if (![self matchingTargetDevice] || inGrace) {
            [self setPhaseAndNotify:[NSString stringWithFormat:HKStr(@"刷新蓝牙扫描 %@…", @"Scanning BLE for %@…"),
                                     hkTargetDisplayName()]];
            [self restartBrowsingForce:YES];
            for (int w = 0; w < 14; w++) {
                if ([self matchingTargetDevice]) break;
                if (!force && !self.cliWakeOnly && hkHasPhysicalLink()) break;
                usleep(250000);
            }
        }

        if (!force && !self.cliWakeOnly && hkHasPhysicalLink()) {
            HKLog(@"%@", HKStr(@"期间检测到常规网络已恢复，取消切换热点", @"Regular network returned; skipping hotspot"));
            [self finishAttemptWithSuccess:YES];
            return;
        }

        if ([self matchingTargetDevice]) {
            [self wakeViaBluetoothAttempt:1 force:force target:target];
            return;
        }
        if (self.cliWakeOnly || target.length == 0) {
            if (!self.loggedTargetMissing) {
                HKLog(HKStr(@"蓝牙附近未发现目标设备「%@」[%@]", @"Target device \"%@\" not found nearby over BLE [%@]"),
                      hkTargetDisplayName(), hkTelemetryTag());
                self.loggedTargetMissing = YES;
            }
            [self finishAttemptWithSuccess:NO];
            return;
        }
        [self tryDirectWiFiFallbackForce:force target:target];
    });
}

- (void)tryDirectWiFiFallbackForce:(BOOL)force target:(NSString *)target {
    if (target.length == 0) {
        [self finishAttemptWithSuccess:NO];
        return;
    }
    if (!force && hkHasPhysicalLink()) {
        HKLog(@"%@", HKStr(@"期间检测到常规网络已恢复，取消切换热点", @"Regular network returned; skipping hotspot"));
        [self finishAttemptWithSuccess:YES];
        return;
    }
    if (!self.loggedTargetMissing) {
        NSArray *others = [self discoveredDeviceNames];
        if (others.count > 0) {
            HKLog(HKStr(@"蓝牙暂未发现「%@」（附近仅看到：%@），尝试 Wi-Fi 直连兜底",
                        @"\"%@\" not seen over BLE (nearby: %@); trying direct Wi-Fi join"),
                  target, [others componentsJoinedByString:HKStr(@"、", @", ")]);
        } else {
            HKLog(HKStr(@"蓝牙暂未发现「%@」，尝试 Wi-Fi 直连兜底",
                        @"\"%@\" not seen over BLE; trying direct Wi-Fi join"), target);
        }
        self.loggedTargetMissing = YES;
    }
    [self setPhaseAndNotify:[NSString stringWithFormat:HKStr(@"Wi-Fi 直连 %@…", @"Joining %@ via Wi-Fi…"), target]];

    NSString *cachedPw = [self cachedPasswordForSSID:target];
    NSString *joinOut = nil;
    BOOL joined = NO;
    if (cachedPw.length > 0) {
        joined = hkJoinWiFiSSID(target, cachedPw, &joinOut);
    }
    if (!joined) {
        joined = hkJoinWiFiSSID(target, nil, &joinOut);
    }

    if (joined) {
        for (int w = 0; w < 6; w++) {
            if (hkOnHotspot()) break;
            sleep(1);
        }
        if (hkOnHotspot()) {
            HKLog(HKStr(@"已通过 Wi-Fi 直连接入热点「%@」[%@]", @"Joined \"%@\" via direct Wi-Fi [%@]"),
                  target, hkTelemetryTag());
            [self finishAttemptWithSuccess:YES];
            return;
        }
    } else if (joinOut.length > 0) {
        HKLog(HKStr(@"Wi-Fi 直连未命中：%@", @"Direct Wi-Fi join missed: %@"), joinOut);
    }

    if ([self matchingTargetDevice]) {
        [self wakeViaBluetoothAttempt:1 force:force target:target];
        return;
    }
    [self finishAttemptWithSuccess:NO];
}

- (void)wakeViaBluetoothAttempt:(int)attempt force:(BOOL)force target:(NSString *)target {
    id dev = [self matchingTargetDevice];
    if (!dev) {
        if (self.cliWakeOnly) {
            [self finishAttemptWithSuccess:NO];
        } else {
            [self tryDirectWiFiFallbackForce:force target:target];
        }
        return;
    }

    NSString *devName = hkSafeDeviceName(dev);
    [self setPhaseAndNotify:[NSString stringWithFormat:HKStr(@"蓝牙唤醒 %@ (%d/3)…", @"Waking %@ via BLE (%d/3)…"),
                             devName, attempt]];
    HKLog(HKStr(@"蓝牙请求唤醒「%@」热点（第 %d 次）[%@]", @"Requesting hotspot on \"%@\" via BLE (attempt %d) [%@]"),
          devName, attempt, hkTelemetryTag());

    void (^completion)(id, id, id, id) = ^(id a, id b, id c, id d) {
        NSString *ssid = [a isKindOfClass:NSString.class] ? a : nil;
        NSString *pw = [b isKindOfClass:NSString.class] ? b : nil;
        if (!ssid.length) {
            NSError *err = [d isKindOfClass:NSError.class] ? d : ([c isKindOfClass:NSError.class] ? c : nil);
            HKLog(HKStr(@"蓝牙唤醒第 %d 次失败：%@", @"BLE wake attempt %d failed: %@"),
                  attempt, err.localizedDescription ?: HKStr(@"手机未响应", @"no response from phone"));
            if (attempt < 3) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    sleep(3);
                    if (!force && !self.cliWakeOnly && hkHasPhysicalLink()) {
                        HKLog(@"%@", HKStr(@"等待重试期间常规网络已恢复，停止唤醒", @"Regular network returned during retry; aborting"));
                        [self finishAttemptWithSuccess:YES];
                        return;
                    }
                    [self wakeViaBluetoothAttempt:attempt + 1 force:force target:target];
                });
                return;
            }
            if (self.cliWakeOnly || target.length == 0) {
                [self finishAttemptWithSuccess:NO];
            } else {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    HKLog(@"%@", HKStr(@"蓝牙 3 次未响应，尝试 Wi-Fi 直连兜底", @"BLE failed 3 times; trying direct Wi-Fi fallback"));
                    [self tryDirectWiFiFallbackForce:force target:target];
                });
            }
            return;
        }

        HKLog(HKStr(@"蓝牙唤醒成功，热点已开启：%@", @"Hotspot awake: %@"), ssid);
        [self cachePassword:pw forSSID:ssid];
        if (target.length > 0) {
            [self cachePassword:pw forSSID:target];
        }
        if (self.cliWakeOnly) {
            [self finishAttemptWithSuccess:YES];
            return;
        }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self setPhaseAndNotify:[NSString stringWithFormat:HKStr(@"正在加入 %@…", @"Joining %@…"), ssid]];
            sleep(2);
            for (int i = 0; i < 4 && !hkOnHotspot() && (force || !hkHasPhysicalLink()); i++) {
                NSString *out = nil;
                BOOL ok = hkJoinWiFiSSID(ssid, pw, &out);
                if (!ok && out.length > 0) {
                    HKLog(HKStr(@"加入热点第 %d 次反馈：%@", @"Join attempt %d: %@"), i + 1, out);
                }
                for (int w = 0; w < 4; w++) {
                    if (hkOnHotspot() || (!force && hkHasPhysicalLink())) break;
                    sleep(1);
                }
            }
            BOOL connected = hkOnHotspot() || (!force && hkHasPhysicalLink());
            if (hkOnHotspot()) {
                HKLog(HKStr(@"已成功接入热点「%@」[%@]", @"Connected to hotspot \"%@\" [%@]"), ssid, hkTelemetryTag());
            } else if (!force && hkHasPhysicalLink()) {
                HKLog(@"%@", HKStr(@"常规网络已恢复，保持在常规网络", @"Regular network returned; staying on it"));
            } else {
                HKLog(HKStr(@"未能完成接入热点「%@」，稍后重试 [%@]", @"Could not join \"%@\"; retrying later [%@]"),
                      ssid, hkTelemetryTag());
            }
            [self finishAttemptWithSuccess:connected];
        });
    };

    ((void(*)(id, SEL, id, id))objc_msgSend)(
        self.session,
        NSSelectorFromString(@"enableHotspotForDevice:withCompletionHandler:"),
        dev,
        completion
    );
}

- (void)finishAttemptWithSuccess:(BOOL)ok {
    self.consecutiveFails = ok ? 0 : (self.consecutiveFails + 1);
    self.downTicks = 0;
    self.deadWifiTicks = 0;
    if (ok) self.internetOK = YES;
    self.busy = NO;
    self.busySinceMono = 0;
    if (!ok) {
        [self.powerGuard noteReconnectRoundCompleted];
    }
    [self setPhaseAndNotify:nil];
    if (self.cliOnce) {
        exit(ok ? 0 : 1);
    }
}

@end

#pragma mark - LaunchAgent & Clamshell Watchdog / Boot-Guard Installers

static NSString *hkSelfExecPath(void) {
    return NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath;
}

static NSString *hkUIDDomain(void) {
    return [NSString stringWithFormat:@"gui/%d", getuid()];
}

static BOOL hkLoginItemEnabled(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:hkPlistPath()];
}

static void hkWriteLoginItem(void) {
    NSDictionary *plist = @{
        @"Label": HK_BUNDLE_ID,
        @"ProgramArguments": @[hkSelfExecPath()],
        @"RunAtLoad": @YES,
        @"KeepAlive": @{@"SuccessfulExit": @NO},
        @"ThrottleInterval": @5,
        @"ProcessType": @"Interactive",
        @"StandardErrorPath": hkLogPath(),
    };
    NSString *path = hkPlistPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [plist writeToFile:path atomically:YES];
}

static void hkInstallAndBootstrapLoginItem(void) {
    hkWriteLoginItem();
    NSString *domain = hkUIDDomain();
    NSString *service = [NSString stringWithFormat:@"%@/%@", domain, HK_BUNDLE_ID];
    int status = 0;
    hkRunCommand(@"/bin/launchctl", @[@"print", service], &status);
    if (status == 0) {
        hkRunCommand(@"/bin/launchctl", @[@"kickstart", @"-k", service], NULL);
    } else {
        hkRunCommand(@"/bin/launchctl", @[@"bootstrap", domain, hkPlistPath()], NULL);
    }
}

static void hkUninstallLoginItem(void) {
    NSString *domain = hkUIDDomain();
    NSString *service = [NSString stringWithFormat:@"%@/%@", domain, HK_BUNDLE_ID];
    hkRunCommand(@"/bin/launchctl", @[@"bootout", service], NULL);
    [[NSFileManager defaultManager] removeItemAtPath:hkPlistPath() error:nil];
}

// Independent lease watchdog LaunchAgent: uses ONLY /bin/sh + /usr/bin/sudo -n /usr/bin/pmset
// Survives HotspotKeeper crash, kill -9, or dragging HotspotKeeper.app to Trash!
static void hkInstallLeaseWatchdog(void) {
    NSString *lease = hkLeasePath();
    NSString *script = [NSString stringWithFormat:
        @"L=\"%@\"; "
        @"[ -f \"$L\" ] || exit 0; "
        @"now=$(/bin/date +%%s); "
        @"mt=$(/usr/bin/stat -f %%m \"$L\" 2>/dev/null || echo 0); "
        @"age=$((now - mt)); "
        @"if [ \"$age\" -gt 120 ]; then "
        @"  /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; "
        @"  /bin/rm -f \"$L\"; "
        @"fi", lease];

    NSDictionary *plist = @{
        @"Label": HK_WATCHDOG_LABEL,
        @"ProgramArguments": @[@"/bin/sh", @"-c", script],
        @"StartInterval": @30,
        @"RunAtLoad": @YES,
    };
    NSString *path = hkWatchdogPlistPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [plist writeToFile:path atomically:YES];

    NSString *domain = hkUIDDomain();
    NSString *service = [NSString stringWithFormat:@"%@/%@", domain, HK_WATCHDOG_LABEL];
    hkRunCommand(@"/bin/launchctl", @[@"bootout", service], NULL);
    hkRunCommand(@"/bin/launchctl", @[@"bootstrap", domain, path], NULL);
}

static void hkUninstallLeaseWatchdog(void) {
    NSString *domain = hkUIDDomain();
    NSString *service = [NSString stringWithFormat:@"%@/%@", domain, HK_WATCHDOG_LABEL];
    hkRunCommand(@"/bin/launchctl", @[@"bootout", service], NULL);
    [[NSFileManager defaultManager] removeItemAtPath:hkWatchdogPlistPath() error:nil];
}

// CLI-driven setup for Opt-in Clamshell Keep-Awake (requires interactive sudo or root):
// 1. Installs least-privilege $USER-only /etc/sudoers.d/hotspot-keeper-pmset (validated via visudo -cf, mode 0440)
// 2. Installs root RunAtLoad LaunchDaemon that resets /usr/bin/pmset -a disablesleep 0 on every boot (covers pre-login/FileVault)
// 3. Installs independent user LaunchAgent lease watchdog (covers crash / kill -9 / app deletion)
static int hkSetupClamshellCLI(void) {
    NSString *user = NSUserName();
    if (!user.length || [user rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"] invertedSet]].location != NSNotFound) {
        fprintf(stderr, "Invalid username for sudoers rule.\n");
        return 1;
    }

    NSString *tmpSudo = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hk_sudoers_tmp"];
    NSString *sudoContent = [NSString stringWithFormat:
        @"# Managed by HotspotKeeper (Opt-in Clamshell Keep-Awake)\n"
        @"Cmnd_Alias HK_PMSET = /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n"
        @"%@ ALL=(root) NOPASSWD: HK_PMSET\n", user];
    [sudoContent writeToFile:tmpSudo atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *tmpDaemon = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hk_sleepguard_tmp.plist"];
    NSDictionary *daemonPlist = @{
        @"Label": HK_BOOTGUARD_LABEL,
        @"ProgramArguments": @[@"/usr/bin/pmset", @"-a", @"disablesleep", @"0"],
        @"RunAtLoad": @YES,
    };
    [daemonPlist writeToFile:tmpDaemon atomically:YES];

    printf("%s\n", HKStr(
        @"正在安装合盖防休眠的三重安全组件（需要管理员密码）：\n"
        @"  1. 最小权限 sudoers（仅限当前用户执行 pmset disablesleep 0/1）\n"
        @"  2. 开机复位 LaunchDaemon（每次重启登录前强制恢复 disablesleep 0）\n"
        @"  3. 独立租约看门狗 LaunchAgent（App 崩溃/被删超过 120 秒自动复位）",
        @"Installing 3-layer Clamshell Keep-Awake components (administrator password required):\n"
        @"  1. Least-privilege sudoers (current user only, exact pmset disablesleep 0/1)\n"
        @"  2. Boot-reset LaunchDaemon (forces disablesleep 0 on every boot before login)\n"
        @"  3. Independent lease watchdog LaunchAgent (resets if app crashes or is deleted >120s)"
    ).UTF8String);

    NSString *cmd = [NSString stringWithFormat:
        @"set -e; "
        @"/usr/sbin/visudo -cf '%@'; "
        @"/usr/bin/install -o root -g wheel -m 0440 '%@' '%@'; "
        @"/usr/sbin/visudo -c; "
        @"/usr/bin/install -o root -g wheel -m 0644 '%@' '%@'; "
        @"/bin/launchctl bootout system/%@ 2>/dev/null || true; "
        @"/bin/launchctl enable system/%@ 2>/dev/null || true",
        tmpSudo, tmpSudo, HK_SUDOERS_PATH, tmpDaemon, HK_BOOTGUARD_PLIST, HK_BOOTGUARD_LABEL, HK_BOOTGUARD_LABEL];

    int rc = system([[NSString stringWithFormat:@"/usr/bin/sudo /bin/sh -c \"%@\"", cmd] UTF8String]);
    [[NSFileManager defaultManager] removeItemAtPath:tmpSudo error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:tmpDaemon error:nil];

    if (rc != 0) {
        fprintf(stderr, "%s\n", HKStr(@"安装失败（权限不足或已取消）", @"Setup failed (canceled or insufficient privileges)").UTF8String);
        return 1;
    }

    hkInstallLeaseWatchdog();
    printf("%s\n", HKStr(
        @"安装完成！运行 'hotspot-keeper --enable-clamshell' 或在菜单栏即可开启合盖防休眠。",
        @"Setup complete! Run 'hotspot-keeper --enable-clamshell' or enable it from the menu bar."
    ).UTF8String);
    return 0;
}

static int hkTeardownClamshellCLI(void) {
    [hkPrefs() setBool:NO forKey:@"clamshellKeepAwake"];
    [hkPrefs() synchronize];
    hkUninstallLeaseWatchdog();
    [[NSFileManager defaultManager] removeItemAtPath:hkLeasePath() error:nil];

    NSString *cmd = [NSString stringWithFormat:
        @"set -e; "
        @"/usr/bin/pmset -a disablesleep 0; "
        @"/bin/launchctl bootout system/%@ 2>/dev/null || true; "
        @"/bin/rm -f '%@' '%@'",
        HK_BOOTGUARD_LABEL, HK_SUDOERS_PATH, HK_BOOTGUARD_PLIST];

    int rc = system([[NSString stringWithFormat:@"/usr/bin/sudo /bin/sh -c \"%@\"", cmd] UTF8String]);
    if (rc != 0) {
        fprintf(stderr, "%s\n", HKStr(@"卸载系统组件失败", @"Failed to remove system components").UTF8String);
        return 1;
    }
    printf("%s\n", HKStr(@"已恢复 SleepDisabled=0 并移除全部合盖防休眠系统组件。",
                         @"Restored SleepDisabled=0 and removed all Clamshell Keep-Awake system hooks.").UTF8String);
    return 0;
}

#pragma mark - Signal Cleanup

static void hkSignalHandler(int sig) {
    // Async-signal-safe path: let GCD signal source handle ObjC cleanup cleanly (see main).
    (void)sig;
}

#pragma mark - Menu Bar UI (Bilingual zh-Hans / English)

@interface HKMenuBarApp : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (nonatomic, strong) HKController *ctrl;
@property (nonatomic, strong) HKPowerGuard *powerGuard;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *menu;
@property (nonatomic, copy) NSString *lastLog;
@property (nonatomic, strong) NSDate *lastLogAt;
@end

@implementation HKMenuBarApp

- (NSMenuItem *)addItem:(NSString *)title toMenu:(NSMenu *)m action:(SEL)action key:(NSString *)key {
    NSMenuItem *item = [m addItemWithTitle:title action:action keyEquivalent:key ?: @""];
    item.target = self;
    return item;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.menu = [NSMenu new];
    self.menu.delegate = self;
    self.menu.autoenablesItems = NO;
    self.statusItem.menu = self.menu;

    __weak HKMenuBarApp *weakSelf = self;
    self.ctrl.onStateChanged = ^{ [weakSelf refreshIcon]; };
    self.powerGuard.onStateChanged = ^{ [weakSelf refreshIcon]; };
    gOnLogLine = ^(NSString *line) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.lastLog = line;
            weakSelf.lastLogAt = NSDate.date;
        });
    };
    [self refreshIcon];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.powerGuard releaseForShutdownReason:HKStr(@"应用退出", @"App terminating")];
}

- (void)refreshIcon {
    BOOL paused = [hkPrefs() boolForKey:@"paused"];
    HKPhysicalLink *link = hkPrimaryPhysicalLink();
    BOOL clamshellArmed = (self.powerGuard.state == HKPowerStateArmedOnline || self.powerGuard.state == HKPowerStateArmedGrace);
    NSString *sym = @"wifi";
    NSString *tip = @"HotspotKeeper";

    if (self.ctrl.phase.length > 0) {
        sym = @"arrow.triangle.2.circlepath";
        tip = self.ctrl.phase;
    } else if (paused) {
        sym = @"pause.circle";
        tip = HKStr(@"已暂停自动重连热点", @"Auto-reconnect paused");
    } else if (!link) {
        sym = (self.powerGuard.state == HKPowerStateArmedGrace) ? @"bolt.horizontal.circle" : @"wifi.slash";
        tip = (self.powerGuard.state == HKPowerStateArmedGrace)
            ? HKStr(@"断网重连宽限保活中", @"Offline · Clamshell grace active")
            : HKStr(@"物理网络已断开（等待重连热点）", @"Offline (waiting to join hotspot)");
    } else if (link.isHotspot) {
        sym = @"personalhotspot";
        tip = [NSString stringWithFormat:HKStr(@"已连接热点 (%@ · %@)", @"On Hotspot (%@ · %@)"),
               hkTargetDisplayName(), link.ip];
    } else if (!self.ctrl.internetOK) {
        sym = @"wifi.exclamationmark";
        tip = [NSString stringWithFormat:HKStr(@"已连接 %@（外网异常）", @"On %@ (no internet)"), link.iface];
    } else {
        sym = clamshellArmed ? @"wifi.circle.fill" : @"wifi";
        tip = [NSString stringWithFormat:HKStr(@"已连接常规网络 (%@ · %@)", @"Online via %@ (%@)"), link.iface, link.ip];
    }

    if (clamshellArmed) {
        tip = [tip stringByAppendingString:HKStr(@" · 合盖防休眠开", @" · Clamshell ON")];
    }

    NSImage *img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:tip];
    img.template = YES;
    self.statusItem.button.image = img;
    self.statusItem.button.toolTip = tip;
}

- (void)menuNeedsUpdate:(NSMenu *)m {
    [m removeAllItems];
    [self refreshIcon];

    NSMenuItem *head = [self addItem:self.statusItem.button.toolTip toMenu:m action:nil key:nil];
    head.enabled = NO;
    head.attributedTitle = [[NSAttributedString alloc] initWithString:self.statusItem.button.toolTip
                                                           attributes:@{NSFontAttributeName: [NSFont boldSystemFontOfSize:13]}];

    NSString *target = hkTargetName();
    id matched = [self.ctrl matchingTargetDevice];
    NSString *phoneLine = nil;
    if (matched) {
        phoneLine = [NSString stringWithFormat:HKStr(@"目标就绪：%@", @"Ready: %@"), hkSafeDeviceSummary(matched)];
    } else if (target.length > 0) {
        phoneLine = [NSString stringWithFormat:HKStr(@"目标：%@（蓝牙暂未见，仍支持 Wi-Fi 直连）",
                                                     @"Target: %@ (not seen via BLE; Wi-Fi fallback ready)"), target];
    } else {
        phoneLine = HKStr(@"附近未发现支持即时热点的 iPhone", @"No Instant Hotspot iPhone nearby");
    }
    NSMenuItem *pItem = [self addItem:phoneLine toMenu:m action:nil key:nil];
    pItem.enabled = NO;
    pItem.image = [NSImage imageWithSystemSymbolName:(matched ? @"iphone" : @"iphone.slash") accessibilityDescription:nil];

    // Clamshell power status line
    NSMenuItem *cLine = [self addItem:[self.powerGuard menuStatusLine] toMenu:m action:nil key:nil];
    cLine.enabled = NO;
    BOOL armedNow = (self.powerGuard.state == HKPowerStateArmedOnline || self.powerGuard.state == HKPowerStateArmedGrace);
    cLine.image = [NSImage imageWithSystemSymbolName:(armedNow ? @"bolt.shield.fill" : @"moon.zzz") accessibilityDescription:nil];

    if (self.lastLog.length > 0) {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm:ss";
        NSString *s = self.lastLog.length > 52 ? [[self.lastLog substringToIndex:51] stringByAppendingString:@"…"] : self.lastLog;
        NSMenuItem *lItem = [self addItem:[NSString stringWithFormat:@"%@  %@", [f stringFromDate:self.lastLogAt], s]
                                   toMenu:m action:nil key:nil];
        lItem.enabled = NO;
    }

    [m addItem:NSMenuItem.separatorItem];

    // Quick actions
    NSString *joinLabel = target.length > 0
        ? [NSString stringWithFormat:HKStr(@"立即连接 %@", @"Connect to %@ Now"), target]
        : HKStr(@"立即连接 iPhone 热点", @"Connect to iPhone Hotspot Now");
    NSMenuItem *joinNow = [self addItem:joinLabel toMenu:m action:@selector(actionConnectNow) key:@"j"];
    joinNow.enabled = !self.ctrl.busy && !hkOnHotspot() && (matched != nil || target.length > 0);

    NSMenuItem *pauseItem = [self addItem:HKStr(@"暂停自动重连", @"Pause Auto-Reconnect")
                                   toMenu:m action:@selector(actionTogglePause) key:nil];
    pauseItem.state = [hkPrefs() boolForKey:@"paused"] ? NSControlStateValueOn : NSControlStateValueOff;

    [m addItem:NSMenuItem.separatorItem];

    // Independent Clamshell Keep-Awake controls
    NSMenuItem *clamshellItem = [self addItem:HKStr(@"合盖防休眠模式（联网保活 + 120s 断网宽限）",
                                                    @"Clamshell Keep-Awake (Online + 120s Grace)")
                                       toMenu:m action:@selector(actionToggleClamshell) key:nil];
    clamshellItem.state = [hkPrefs() boolForKey:@"clamshellKeepAwake"] ? NSControlStateValueOn : NSControlStateValueOff;

    NSMenuItem *sleepNowItem = [self addItem:HKStr(@"立即睡眠（释放防休眠）", @"Sleep Now (Release Keep-Awake)")
                                      toMenu:m action:@selector(actionSleepNow) key:@"s"];
    sleepNowItem.enabled = YES;

    [m addItem:NSMenuItem.separatorItem];

    // Target hotspot picker submenu
    NSMenuItem *targetMenuItem = [self addItem:HKStr(@"切换目标热点", @"Target Hotspot") toMenu:m action:nil key:nil];
    NSMenu *tSub = [NSMenu new];
    tSub.autoenablesItems = NO;
    targetMenuItem.submenu = tSub;

    NSMenuItem *autoItem = [self addItem:HKStr(@"自动（附近首台同账号 iPhone）", @"Auto (First Nearby iPhone)")
                                  toMenu:tSub action:@selector(actionPickTarget:) key:nil];
    autoItem.representedObject = @"";
    autoItem.state = (target.length == 0) ? NSControlStateValueOn : NSControlStateValueOff;

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (target.length > 0) [candidates addObject:target];
    for (NSString *n in [self.ctrl discoveredDeviceNames]) {
        BOOL exists = NO;
        for (NSString *c in candidates) { if (hkNamesMatch(c, n)) { exists = YES; break; } }
        if (!exists) [candidates addObject:n];
    }
    if (candidates.count > 0) [tSub addItem:NSMenuItem.separatorItem];
    for (NSString *c in candidates) {
        NSMenuItem *ci = [self addItem:c toMenu:tSub action:@selector(actionPickTarget:) key:nil];
        ci.representedObject = c;
        ci.state = (target.length > 0 && hkNamesMatch(c, target)) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [tSub addItem:NSMenuItem.separatorItem];
    [self addItem:HKStr(@"自定义目标热点名…", @"Set Custom Target Name…")
           toMenu:tSub action:@selector(actionCustomTarget) key:nil];

    // Options submenu
    NSMenuItem *optItem = [self addItem:HKStr(@"选项", @"Options") toMenu:m action:nil key:nil];
    NSMenu *sub = [NSMenu new];
    sub.autoenablesItems = NO;
    optItem.submenu = sub;

    NSMenuItem *deadItem = [self addItem:HKStr(@"Wi-Fi 无外网（30 秒）自动切热点", @"Switch When Wi-Fi Has No Internet (30s)")
                                  toMenu:sub action:@selector(actionToggleDeadWifi) key:nil];
    deadItem.state = [hkPrefs() boolForKey:@"deadWifi"] ? NSControlStateValueOn : NSControlStateValueOff;

    NSMenuItem *loginItem = [self addItem:HKStr(@"登录时自动启动", @"Start at Login")
                                   toMenu:sub action:@selector(actionToggleLogin) key:nil];
    loginItem.state = hkLoginItemEnabled() ? NSControlStateValueOn : NSControlStateValueOff;

    [sub addItem:NSMenuItem.separatorItem];
    [self addItem:HKStr(@"查看运行日志", @"Open Log") toMenu:sub action:@selector(actionOpenLog) key:nil];

    [m addItem:NSMenuItem.separatorItem];
    [self addItem:[NSString stringWithFormat:HKStr(@"退出 HotspotKeeper (v%@)", @"Quit HotspotKeeper (v%@)"), HK_VERSION]
           toMenu:m action:@selector(actionQuit) key:@"q"];
}

- (void)actionConnectNow {
    self.ctrl.loggedTargetMissing = NO;
    [self.ctrl connectNow:YES reason:HKStr(@"菜单栏手动触发", @"Menu bar manual trigger")];
}

- (void)actionTogglePause {
    BOOL next = ![hkPrefs() boolForKey:@"paused"];
    [hkPrefs() setBool:next forKey:@"paused"];
    HKLog(@"%@", next ? HKStr(@"已暂停自动重连", @"Auto-reconnect paused")
                      : HKStr(@"已恢复自动重连", @"Auto-reconnect resumed"));
    [self refreshIcon];
}

- (void)actionToggleClamshell {
    BOOL cur = [hkPrefs() boolForKey:@"clamshellKeepAwake"];
    if (cur) {
        [hkPrefs() setBool:NO forKey:@"clamshellKeepAwake"];
        [self.powerGuard evaluateWithPhysicalLink:hkHasPhysicalLink() internetOK:self.ctrl.internetOK];
        HKLog(@"%@", HKStr(@"用户已关闭合盖防休眠模式", @"Clamshell Keep-Awake disabled by user"));
        [self refreshIcon];
        return;
    }

    [NSApp activateIgnoringOtherApps:YES];
    if (hkIsAmphetamineRunning()) {
        NSAlert *a = [NSAlert new];
        a.alertStyle = NSAlertStyleWarning;
        a.messageText = HKStr(@"检测到 Amphetamine 正在运行", @"Amphetamine Is Currently Running");
        a.informativeText = HKStr(@"为避免两个软件互相覆盖系统睡眠设置，请先退出 Amphetamine 后再开启 HotspotKeeper 的合盖防休眠模式。",
                                  @"To avoid conflicting SleepDisabled toggles, please quit Amphetamine before enabling HotspotKeeper Clamshell Keep-Awake.");
        [a runModal];
        return;
    }
    if (!hkPowerSudoersReady()) {
        NSAlert *a = [NSAlert new];
        a.alertStyle = NSAlertStyleInformational;
        a.messageText = HKStr(@"需要先完成一次性电源安全组件安装", @"One-Time Power Guard Setup Required");
        a.informativeText = HKStr(
            @"合盖防休眠需要通过终端执行一次管理员授权，安装最小权限 sudoers、开机复位守护进程与崩溃租约看门狗。\n\n"
            @"请在终端运行：\n  hotspot-keeper --setup-clamshell\n\n"
            @"注意：生效期间「苹果菜单 → 睡眠」会被系统拦截，请使用 HotspotKeeper 菜单中的「立即睡眠」。",
            @"Clamshell Keep-Awake requires a one-time Terminal setup to install least-privilege sudoers, boot-reset daemon, and crash lease watchdog.\n\n"
            @"Run in Terminal:\n  hotspot-keeper --setup-clamshell\n\n"
            @"Note: While active, Apple Menu → Sleep is blocked by macOS; use HotspotKeeper's 'Sleep Now' instead."
        );
        [a runModal];
        return;
    }

    [hkPrefs() setBool:YES forKey:@"clamshellKeepAwake"];
    [self.powerGuard onFullWake];
    [self.powerGuard evaluateWithPhysicalLink:hkHasPhysicalLink() internetOK:self.ctrl.internetOK];
    HKLog(@"%@", HKStr(@"用户已开启合盖防休眠模式", @"Clamshell Keep-Awake enabled by user"));
    [self refreshIcon];
}

- (void)actionSleepNow {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self.powerGuard sleepNow];
    });
}

- (void)actionPickTarget:(NSMenuItem *)sender {
    NSString *name = sender.representedObject ?: @"";
    [hkPrefs() setObject:name forKey:@"targetName"];
    self.ctrl.loggedTargetMissing = NO;
    HKLog(HKStr(@"目标热点已切换为「%@」", @"Target hotspot set to \"%@\""), hkTargetDisplayName());
    [self refreshIcon];
}

- (void)actionCustomTarget {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = HKStr(@"设置目标热点名称", @"Set Target Hotspot Name");
    alert.informativeText = HKStr(@"输入要锁定的 iPhone 设备名或热点 SSID（留空则自动选择附近第一台同账号 iPhone）：",
                                  @"Enter the iPhone device name or hotspot SSID to pin (leave blank for Auto):");
    [alert addButtonWithTitle:HKStr(@"保存", @"Save")];
    [alert addButtonWithTitle:HKStr(@"取消", @"Cancel")];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    field.stringValue = hkTargetName();
    field.placeholderString = HKStr(@"例如：iPhone 16 Pro Max", @"e.g. My iPhone");
    alert.accessoryView = field;
    [alert.window setInitialFirstResponder:field];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *val = [field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [hkPrefs() setObject:val forKey:@"targetName"];
        self.ctrl.loggedTargetMissing = NO;
        HKLog(HKStr(@"目标热点已更新为「%@」", @"Target hotspot updated to \"%@\""), hkTargetDisplayName());
        [self refreshIcon];
    }
}

- (void)actionToggleDeadWifi {
    BOOL next = ![hkPrefs() boolForKey:@"deadWifi"];
    [hkPrefs() setBool:next forKey:@"deadWifi"];
    HKLog(HKStr(@"Wi-Fi 无外网自动切热点：%@", @"Dead Wi-Fi failover: %@"),
          next ? HKStr(@"开", @"on") : HKStr(@"关", @"off"));
}

- (void)actionToggleLogin {
    if (hkLoginItemEnabled()) {
        [[NSFileManager defaultManager] removeItemAtPath:hkPlistPath() error:nil];
        HKLog(@"%@", HKStr(@"已关闭登录自启", @"Start at login: off"));
    } else {
        hkWriteLoginItem();
        HKLog(@"%@", HKStr(@"已开启登录自启", @"Start at login: on"));
    }
}

- (void)actionOpenLog {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:hkLogPath()]];
}

- (void)actionQuit {
    [self.powerGuard releaseForShutdownReason:HKStr(@"用户从菜单栏退出", @"Quit from menu bar")];
    HKLog(@"%@", HKStr(@"用户从菜单栏退出", @"Quit from menu bar"));
    exit(0);
}

@end

#pragma mark - SCDynamicStore Live Network Callback

static void hkDynamicStoreCallback(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
    HKController *ctrl = (__bridge HKController *)info;
    [ctrl onNetworkEvent];
}

#pragma mark - main

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL modeStatus = NO, modeList = NO, modeTest = NO, modeForce = NO, modeHeadless = NO;
        BOOL modeInstallLogin = NO, modeUninstallLogin = NO;
        BOOL modeSetupClamshell = NO, modeTeardownClamshell = NO;
        BOOL modeEnableClamshell = NO, modeDisableClamshell = NO, modeSleepNow = NO;

        for (int i = 1; i < argc; i++) {
            NSString *arg = @(argv[i]);
            if ([arg isEqualToString:@"--version"]) {
                printf("HotspotKeeper %s\n", HK_VERSION.UTF8String);
                return 0;
            } else if ([arg isEqualToString:@"--help"] || [arg isEqualToString:@"-h"]) {
                printf("%s\n", HKStr(
                    @"用法: hotspot-keeper [--status|--list|--test|--force|--headless|--target <名称>\n"
                    @"                      |--setup-clamshell|--teardown-clamshell\n"
                    @"                      |--enable-clamshell|--disable-clamshell|--sleep-now\n"
                    @"                      |--install-login|--uninstall-login|--version]",
                    @"Usage: hotspot-keeper [--status|--list|--test|--force|--headless|--target <name>\n"
                    @"                       |--setup-clamshell|--teardown-clamshell\n"
                    @"                       |--enable-clamshell|--disable-clamshell|--sleep-now\n"
                    @"                       |--install-login|--uninstall-login|--version]"
                ).UTF8String);
                return 0;
            } else if ([arg isEqualToString:@"--status"]) {
                modeStatus = YES;
            } else if ([arg isEqualToString:@"--list"]) {
                modeList = YES;
            } else if ([arg isEqualToString:@"--test"]) {
                modeTest = YES;
            } else if ([arg isEqualToString:@"--force"]) {
                modeForce = YES;
            } else if ([arg isEqualToString:@"--headless"]) {
                modeHeadless = YES;
            } else if ([arg isEqualToString:@"--install-login"]) {
                modeInstallLogin = YES;
            } else if ([arg isEqualToString:@"--uninstall-login"]) {
                modeUninstallLogin = YES;
            } else if ([arg isEqualToString:@"--setup-clamshell"]) {
                modeSetupClamshell = YES;
            } else if ([arg isEqualToString:@"--teardown-clamshell"]) {
                modeTeardownClamshell = YES;
            } else if ([arg isEqualToString:@"--enable-clamshell"]) {
                modeEnableClamshell = YES;
            } else if ([arg isEqualToString:@"--disable-clamshell"]) {
                modeDisableClamshell = YES;
            } else if ([arg isEqualToString:@"--sleep-now"]) {
                modeSleepNow = YES;
            } else if ([arg isEqualToString:@"--target"] && i + 1 < argc) {
                gTargetOverride = @(argv[++i]);
            }
        }

        if (modeSetupClamshell) return hkSetupClamshellCLI();
        if (modeTeardownClamshell) return hkTeardownClamshellCLI();

        if (modeEnableClamshell) {
            if (!hkPowerSudoersReady()) {
                fprintf(stderr, "%s\n", HKStr(@"请先运行 'hotspot-keeper --setup-clamshell' 完成一次性授权安装。",
                                              @"Please run 'hotspot-keeper --setup-clamshell' first.").UTF8String);
                return 1;
            }
            if (hkIsAmphetamineRunning()) {
                fprintf(stderr, "%s\n", HKStr(@"检测到 Amphetamine 正在运行，请先退出 Amphetamine 再启用。",
                                              @"Amphetamine is running; please quit it first.").UTF8String);
                return 1;
            }
            [hkPrefs() setBool:YES forKey:@"clamshellKeepAwake"];
            [hkPrefs() synchronize];
            printf("%s\n", HKStr(@"已开启合盖防休眠模式（将在 5 秒内由后台服务接管生效）。",
                                 @"Clamshell Keep-Awake enabled (daemon will pick it up within 5s).").UTF8String);
            return 0;
        }

        if (modeDisableClamshell) {
            [hkPrefs() setBool:NO forKey:@"clamshellKeepAwake"];
            [hkPrefs() synchronize];
            if ([[NSFileManager defaultManager] fileExistsAtPath:hkLeasePath()] && hkPowerSudoersReady()) {
                hkRunCommandTimeout(@"/usr/bin/sudo", @[@"-n", @"/usr/bin/pmset", @"-a", @"disablesleep", @"0"], 8.0, NULL);
                [[NSFileManager defaultManager] removeItemAtPath:hkLeasePath() error:nil];
            }
            printf("%s\n", HKStr(@"已关闭合盖防休眠模式。", @"Clamshell Keep-Awake disabled.").UTF8String);
            return 0;
        }

        if (modeSleepNow) {
            HKPowerGuard *pg = [HKPowerGuard new];
            [pg sleepNow];
            return 0;
        }

        if (modeInstallLogin) {
            hkInstallAndBootstrapLoginItem();
            printf("%s %s\n", HKStr(@"已安装并启动开机自启服务：", @"Installed and started LaunchAgent:").UTF8String,
                   hkPlistPath().UTF8String);
            return 0;
        }
        if (modeUninstallLogin) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:hkLeasePath()] && hkPowerSudoersReady()) {
                hkRunCommandTimeout(@"/usr/bin/sudo", @[@"-n", @"/usr/bin/pmset", @"-a", @"disablesleep", @"0"], 8.0, NULL);
                [[NSFileManager defaultManager] removeItemAtPath:hkLeasePath() error:nil];
            }
            hkUninstallLoginItem();
            printf("%s\n", HKStr(@"已移除开机自启服务", @"Removed LaunchAgent").UTF8String);
            return 0;
        }

        if (modeStatus) {
            HKPhysicalLink *link = hkPrimaryPhysicalLink();
            NSString *target = hkTargetName();
            HKBatteryInfo b = hkBatteryInfo();
            printf("target=%s wifiOn=%d hasPhysicalLink=%d iface=%s ip=%s router=%s onHotspot=%d internet=%d "
                   "paused=%d deadWifi=%d loginItem=%d clamshellOptIn=%d clamshellReady=%d amphetamine=%d "
                   "lid=%s sleepDisabled=%d batt=%d%%(%s) thermal=%s\n",
                   (target.length > 0 ? target : @"<auto>").UTF8String,
                   hkWiFiPowerOn(),
                   link != nil,
                   (link.iface ?: @"-").UTF8String,
                   (link.ip ?: @"-").UTF8String,
                   (link.router ?: @"-").UTF8String,
                   hkOnHotspot(),
                   hkInternetOK(),
                   [hkPrefs() boolForKey:@"paused"],
                   [hkPrefs() boolForKey:@"deadWifi"],
                   hkLoginItemEnabled(),
                   [hkPrefs() boolForKey:@"clamshellKeepAwake"],
                   hkPowerSudoersReady(),
                   hkIsAmphetamineRunning(),
                   hkIsLidClosed() ? "closed" : "open",
                   hkReadSystemSleepDisabled() ? 1 : 0,
                   b.percent,
                   b.onAC ? "AC" : "BATT",
                   hkThermalName(NSProcessInfo.processInfo.thermalState).UTF8String);
            return 0;
        }

        BOOL cliOnce = modeList || modeTest || modeForce;

        int lockFd = -1;
        if (!cliOnce) {
            [[NSFileManager defaultManager] createDirectoryAtPath:[hkLockPath() stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
            lockFd = open(hkLockPath().fileSystemRepresentation, O_CREAT | O_RDWR, 0644);
            if (lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0) {
                fprintf(stderr, "%s\n", HKStr(@"HotspotKeeper 已在运行中", @"HotspotKeeper is already running").UTF8String);
                return 0;
            }
        }

        HKPowerGuard *powerGuard = [HKPowerGuard new];
        gPowerGuard = powerGuard;

        HKController *ctrl = [HKController new];
        ctrl.powerGuard = powerGuard;
        ctrl.cliOnce = cliOnce;
        ctrl.cliListOnly = modeList;
        ctrl.cliWakeOnly = modeTest;
        ctrl.cliForce = modeForce;
        [ctrl startBrowsing];

        if (modeList) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (ctrl.devices.count == 0) {
                    printf("%s\n", HKStr(@"8 秒内未发现支持即时热点的同账号 iPhone（请确认蓝牙已开且 iPhone 在附近）",
                                         @"No Instant Hotspot iPhone found within 8s (ensure Bluetooth is on and same Apple Account)").UTF8String);
                }
                exit(ctrl.devices.count > 0 ? 0 : 1);
            });
            [[NSRunLoop mainRunLoop] run];
            return 0;
        }

        if (modeTest || modeForce) {
            if (modeForce) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    if (!ctrl.busy) [ctrl connectNow:YES reason:HKStr(@"命令行强制连接", @"CLI force connect")];
                });
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                HKLog(@"%@", HKStr(@"命令行操作超时", @"CLI operation timed out"));
                exit(1);
            });
            [[NSRunLoop mainRunLoop] run];
            return 0;
        }

        HKLog(HKStr(@"HotspotKeeper v%@ 已启动（目标：%@，%@，合盖保活：%@）[%@]",
                    @"HotspotKeeper v%@ started (target: %@, %@, clamshell: %@) [%@]"),
              HK_VERSION,
              hkTargetDisplayName(),
              modeHeadless ? HKStr(@"纯后台", @"headless") : HKStr(@"菜单栏", @"menu bar"),
              [hkPrefs() boolForKey:@"clamshellKeepAwake"] ? HKStr(@"开", @"on") : HKStr(@"关", @"off"),
              hkTelemetryTag());

        static id activity = nil;
        activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                                  reason:@"HotspotKeeper network watcher"];
        (void)activity;

        dispatch_queue_t watchQueue = dispatch_queue_create("io.github.wangnov.hotspot-keeper.watch", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_t powerQueue = dispatch_queue_create("io.github.wangnov.hotspot-keeper.power", DISPATCH_QUEUE_SERIAL);

        // Clean SIGTERM / SIGINT handlers on GCD so SleepDisabled is ALWAYS released before exit.
        signal(SIGTERM, hkSignalHandler);
        signal(SIGINT, hkSignalHandler);
        static dispatch_source_t sigTermSrc = nil;
        static dispatch_source_t sigIntSrc = nil;
        void (^cleanShutdown)(NSString *) = ^(NSString *sigName) {
            dispatch_sync(powerQueue, ^{
                [powerGuard releaseForShutdownReason:sigName];
            });
            HKLog(HKStr(@"收到 %@，已安全释放电源锁并退出", @"Received %@; released power lock and exiting"), sigName);
            exit(0);
        };
        sigTermSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        dispatch_source_set_event_handler(sigTermSrc, ^{ cleanShutdown(@"SIGTERM"); });
        dispatch_resume(sigTermSrc);
        sigIntSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        dispatch_source_set_event_handler(sigIntSrc, ^{ cleanShutdown(@"SIGINT"); });
        dispatch_resume(sigIntSrc);

        // SCDynamicStore live network events
        SCDynamicStoreContext ctx = {0, (__bridge void *)ctrl, NULL, NULL, NULL};
        SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("HotspotKeeperWatch"), hkDynamicStoreCallback, &ctx);
        if (store) {
            CFStringRef patterns[] = {
                CFSTR("State:/Network/Service/.*/IPv4"),
                CFSTR("State:/Network/Interface/.*/Link"),
            };
            CFArrayRef patArray = CFArrayCreate(NULL, (const void **)patterns, 2, &kCFTypeArrayCallBacks);
            SCDynamicStoreSetNotificationKeys(store, NULL, patArray);
            CFRelease(patArray);
            SCDynamicStoreSetDispatchQueue(store, watchQueue);
        }

        // Network reconnect timer (every 3s)
        static dispatch_source_t netTimer = nil;
        netTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, watchQueue);
        dispatch_source_set_timer(netTimer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(netTimer, ^{
            [ctrl tick];
        });
        dispatch_resume(netTimer);

        // Independent Power Policy timer (every 5s — never blocked by network busy or Wi-Fi off)
        static dispatch_source_t powerTimer = nil;
        powerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, powerQueue);
        dispatch_source_set_timer(powerTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(powerTimer, ^{
            [powerGuard evaluateWithPhysicalLink:hkHasPhysicalLink() internetOK:ctrl.internetOK];
        });
        dispatch_resume(powerTimer);

        // Wake & power-off notifications
        NSNotificationCenter *wsNC = [[NSWorkspace sharedWorkspace] notificationCenter];
        [wsNC addObserverForName:NSWorkspaceDidWakeNotification
                          object:nil
                           queue:nil
                      usingBlock:^(NSNotification *note) {
                          dispatch_async(watchQueue, ^{ [ctrl onSystemWake]; });
                      }];
        [wsNC addObserverForName:NSWorkspaceWillPowerOffNotification
                          object:nil
                           queue:nil
                      usingBlock:^(NSNotification *note) {
                          dispatch_sync(powerQueue, ^{
                              [powerGuard releaseForShutdownReason:HKStr(@"系统关机/重启", @"System power-off")];
                          });
                      }];

        if (modeHeadless) {
            [[NSRunLoop mainRunLoop] run];
            return 0;
        }

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        static HKMenuBarApp *delegate = nil;
        delegate = [HKMenuBarApp new];
        delegate.ctrl = ctrl;
        delegate.powerGuard = powerGuard;
        app.delegate = delegate;
        [app run];
        return 0;
    }
}
