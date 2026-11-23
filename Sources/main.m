// HotspotKeeper — Automatically wake and connect your Mac to a pinned iPhone Personal Hotspot
// when your physical network drops. Designed to work cleanly alongside Surge Enhanced Mode,
// Clash/Mihomo TUN, Tailscale, and remote desktop workflows like Sill.
//
// Usage:
//   hotspot-keeper                      Run menu bar app (default)
//   hotspot-keeper --headless           Run background daemon without menu bar icon
//   hotspot-keeper --status             Print physical link, internet, and hotspot status
//   hotspot-keeper --list               Scan and list nearby same-Apple-Account iPhones
//   hotspot-keeper --test               Test waking the target iPhone hotspot over Bluetooth (no Wi-Fi switch)
//   hotspot-keeper --force              Immediately connect to the target hotspot (BLE wake + Wi-Fi fallback)
//   hotspot-keeper --target <name>      Override target iPhone / hotspot SSID (empty = first nearby iPhone)
//   hotspot-keeper --install-login      Install & start LaunchAgent for Start at Login
//   hotspot-keeper --uninstall-login    Remove LaunchAgent
//   hotspot-keeper --version            Print version

#import <AppKit/AppKit.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreWLAN/CoreWLAN.h>
#import <dlfcn.h>
#import <sys/file.h>
#import <objc/message.h>

#define HK_BUNDLE_ID @"io.github.wangnov.hotspot-keeper"
#define HK_VERSION   @"1.1.0"

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

#pragma mark - Paths & Logging

static NSString *hkLogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/HotspotKeeper.log"];
}

static NSString *hkLockPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/.HotspotKeeper.lock"];
}

static NSString *hkPlistPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/" HK_BUNDLE_ID ".plist"];
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
            @"targetName": @"",       // Empty = auto-pick first nearby same-Apple-Account iPhone
            @"paused": @NO,
            @"deadWifi": @NO,         // Also switch if Wi-Fi has no internet for 30s
            @"offlineSeconds": @6,    // Seconds offline before auto-connecting
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
    NSArray *prefixes = @[@"utun", @"lo", @"ipsec", @"ppp", @"bridge", @"awdl", @"llw", @"anpi", @"ap", @"gif", @"stf", @"feth", @"vmenet"];
    for (NSString *p in prefixes) {
        if ([iface hasPrefix:p]) return YES;
    }
    return NO;
}

static BOOL hkIsLinkActive(SCDynamicStoreRef store, NSString *iface) {
    NSString *key = [NSString stringWithFormat:@"State:/Network/Interface/%@/Link", iface];
    NSDictionary *d = (__bridge_transfer NSDictionary *)SCDynamicStoreCopyValue(store, (__bridge CFStringRef)key);
    if (![d isKindOfClass:NSDictionary.class]) return YES;
    NSNumber *active = d[@"Active"];
    return active ? active.boolValue : YES;
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

#pragma mark - Subprocess Helper (Never Logs Passwords)

static NSString *hkRunCommand(NSString *path, NSArray<NSString *> *args, int *outStatus) {
    NSTask *task = [NSTask new];
    task.launchPath = path;
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    @try {
        [task launch];
    } @catch (NSException *ex) {
        if (outStatus) *outStatus = -1;
        return ex.reason ?: @"launch failed";
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (outStatus) *outStatus = task.terminationStatus;
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL hkJoinWiFiSSID(NSString *ssid, NSString *password, NSString **outMsg) {
    if (!ssid.length) return NO;
    NSString *iface = hkWiFiIfaceName();
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-setairportnetwork", iface, ssid, nil];
    if (password.length > 0) {
        [args addObject:password];
    }
    int status = 0;
    NSString *out = hkRunCommand(@"/usr/sbin/networksetup", args, &status);
    if (outMsg) *outMsg = out;
    if (status != 0) return NO;
    if ([out localizedCaseInsensitiveContainsString:@"Could not find"] ||
        [out localizedCaseInsensitiveContainsString:@"Failed to join"] ||
        [out localizedCaseInsensitiveContainsString:@"Error:"]) {
        return NO;
    }
    return YES;
}

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
@property (atomic, copy) NSArray *devices;
@property (atomic) BOOL busy;
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
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *memPasswords; // RAM-only cache, never persisted or logged
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

// 重建 SFRemoteHotspotSession：解决长连接/休眠唤醒/刚断开热点后 BLE 设备列表陈旧不刷新的问题
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
    switch (self.consecutiveFails) {
        case 0: return 8;
        case 1: return 15;
        case 2: return 30;
        case 3: return 60;
        default: return 120;
    }
}

- (void)onSystemWake {
    HKLog(@"%@", HKStr(@"系统已唤醒，刷新蓝牙扫描并重置冷却计数", @"System woke up; refreshing BLE browse & resetting backoff"));
    self.lastAttemptAt = nil;
    self.consecutiveFails = 0;
    self.loggedTargetMissing = NO;
    self.downTicks = 1;
    self.deadWifiTicks = 0;
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
        // 刚刚掉线：提前刷新 BLE 扫描，避免原连接的热点仍被 Sharing 框架隐藏
        [self restartBrowsingForce:NO];
    }
    self.lastKnownHasLink = nowHasLink;
    [self notifyUI];
}

- (void)tick {
    if (self.busy) return;
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
    // 定时器每 3 秒一次，offlineSeconds 默认 6 秒（连续 2 次断网触发）
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
        if (self.tickCount % 5 == 0) { // 每 15 秒探测一次外网
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

// Dual-channel reconnect:
// 1. BLE Instant Hotspot (SFRemoteHotspotSession) first — if target missing from cache, restart BLE browse and wait up to 3.5s.
// 2. Direct Wi-Fi fallback using in-memory cached hotspot credentials (avoids Error -3900) or macOS Keychain.
- (void)connectNow:(BOOL)force reason:(NSString *)reason {
    if (self.busy) return;
    self.busy = YES;
    self.lastAttemptAt = NSDate.date;

    NSString *target = hkTargetName();
    HKLog(HKStr(@"%@ -> 准备连接目标热点「%@」", @"%@ -> connecting to target hotspot \"%@\""),
          reason, hkTargetDisplayName());

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (![self matchingTargetDevice]) {
            // 主动刷新一次 BLE 扫描并最多等 3.5 秒，解决刚断开热点或长时间运行后扫描缓存陈旧问题
            [self setPhaseAndNotify:[NSString stringWithFormat:HKStr(@"刷新蓝牙扫描 %@…", @"Scanning BLE for %@…"),
                                     hkTargetDisplayName()]];
            [self restartBrowsingForce:YES];
            for (int w = 0; w < 14; w++) {
                if ([self matchingTargetDevice]) break;
                if (!force && !self.cliWakeOnly && hkHasPhysicalLink()) break;
                usleep(250000); // 250ms
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
                HKLog(HKStr(@"蓝牙附近未发现目标设备「%@」", @"Target device \"%@\" not found nearby over Bluetooth"),
                      hkTargetDisplayName());
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

    // 若内存里缓存了上次蓝牙唤醒拿到的密码，优先带密码直连，规避 macOS networksetup 无密码报 Error -3900
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
            HKLog(HKStr(@"已通过 Wi-Fi 直连接入热点「%@」", @"Joined \"%@\" via direct Wi-Fi"), target);
            [self finishAttemptWithSuccess:YES];
            return;
        }
    } else if (joinOut.length > 0) {
        HKLog(HKStr(@"Wi-Fi 直连未命中：%@", @"Direct Wi-Fi join missed: %@"), joinOut);
    }

    // 如果 Wi-Fi 直连耗时期间蓝牙刚刷出了目标设备，立即补一次蓝牙唤醒
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
    HKLog(HKStr(@"蓝牙请求唤醒「%@」热点（第 %d 次）", @"Requesting hotspot on \"%@\" via BLE (attempt %d)"),
          devName, attempt);

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
                HKLog(HKStr(@"已成功接入热点「%@」", @"Connected to hotspot \"%@\""), ssid);
            } else if (!force && hkHasPhysicalLink()) {
                HKLog(@"%@", HKStr(@"常规网络已恢复，保持在常规网络", @"Regular network returned; staying on it"));
            } else {
                HKLog(HKStr(@"未能完成接入热点「%@」，稍后退避重试", @"Could not join \"%@\"; backing off"), ssid);
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
    [self setPhaseAndNotify:nil];
    if (self.cliOnce) {
        exit(ok ? 0 : 1);
    }
}

@end

#pragma mark - LaunchAgent Management

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

#pragma mark - Menu Bar UI (Bilingual zh-Hans / English)

@interface HKMenuBarApp : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (nonatomic, strong) HKController *ctrl;
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
    gOnLogLine = ^(NSString *line) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.lastLog = line;
            weakSelf.lastLogAt = NSDate.date;
        });
    };
    [self refreshIcon];
}

- (void)refreshIcon {
    BOOL paused = [hkPrefs() boolForKey:@"paused"];
    HKPhysicalLink *link = hkPrimaryPhysicalLink();
    NSString *sym = @"wifi";
    NSString *tip = @"HotspotKeeper";

    if (self.ctrl.phase.length > 0) {
        sym = @"arrow.triangle.2.circlepath";
        tip = self.ctrl.phase;
    } else if (paused) {
        sym = @"pause.circle";
        tip = HKStr(@"已暂停自动重连热点", @"Auto-reconnect paused");
    } else if (!link) {
        sym = @"wifi.slash";
        tip = HKStr(@"物理网络已断开（等待重连热点）", @"Offline (waiting to join hotspot)");
    } else if (link.isHotspot) {
        tip = [NSString stringWithFormat:HKStr(@"已连接热点 (%@ · %@)", @"On Hotspot (%@ · %@)"),
               hkTargetDisplayName(), link.ip];
        sym = @"personalhotspot";
    } else if (!self.ctrl.internetOK) {
        sym = @"wifi.exclamationmark";
        tip = [NSString stringWithFormat:HKStr(@"已连接 %@（外网异常）", @"On %@ (no internet)"), link.iface];
    } else {
        sym = @"wifi";
        tip = [NSString stringWithFormat:HKStr(@"已连接常规网络 (%@ · %@)", @"Online via %@ (%@)"), link.iface, link.ip];
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

    if (self.lastLog.length > 0) {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm:ss";
        NSString *s = self.lastLog.length > 52 ? [[self.lastLog substringToIndex:51] stringByAppendingString:@"…"] : self.lastLog;
        NSMenuItem *lItem = [self addItem:[NSString stringWithFormat:@"%@  %@", [f stringFromDate:self.lastLogAt], s]
                                   toMenu:m action:nil key:nil];
        lItem.enabled = NO;
    }

    [m addItem:NSMenuItem.separatorItem];

    NSString *joinLabel = target.length > 0
        ? [NSString stringWithFormat:HKStr(@"立即连接 %@", @"Connect to %@ Now"), target]
        : HKStr(@"立即连接 iPhone 热点", @"Connect to iPhone Hotspot Now");
    NSMenuItem *joinNow = [self addItem:joinLabel toMenu:m action:@selector(actionConnectNow) key:@"j"];
    joinNow.enabled = !self.ctrl.busy && !hkOnHotspot() && (matched != nil || target.length > 0);

    NSMenuItem *pauseItem = [self addItem:HKStr(@"暂停自动重连", @"Pause Auto-Reconnect")
                                   toMenu:m action:@selector(actionTogglePause) key:nil];
    pauseItem.state = [hkPrefs() boolForKey:@"paused"] ? NSControlStateValueOn : NSControlStateValueOff;

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
    field.placeholderString = HKStr(@"例如：iPhone 15 Pro Max", @"e.g. My iPhone");
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

        for (int i = 1; i < argc; i++) {
            NSString *arg = @(argv[i]);
            if ([arg isEqualToString:@"--version"]) {
                printf("HotspotKeeper %s\n", HK_VERSION.UTF8String);
                return 0;
            } else if ([arg isEqualToString:@"--help"] || [arg isEqualToString:@"-h"]) {
                printf("%s\n", HKStr(
                    @"用法: hotspot-keeper [--status|--list|--test|--force|--headless|--install-login|--uninstall-login|--target <名称>|--version]",
                    @"Usage: hotspot-keeper [--status|--list|--test|--force|--headless|--install-login|--uninstall-login|--target <name>|--version]"
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
            } else if ([arg isEqualToString:@"--target"] && i + 1 < argc) {
                gTargetOverride = @(argv[++i]);
            }
        }

        if (modeInstallLogin) {
            hkInstallAndBootstrapLoginItem();
            printf("%s %s\n", HKStr(@"已安装并启动开机自启服务：", @"Installed and started LaunchAgent:").UTF8String,
                   hkPlistPath().UTF8String);
            return 0;
        }
        if (modeUninstallLogin) {
            hkUninstallLoginItem();
            printf("%s\n", HKStr(@"已移除开机自启服务", @"Removed LaunchAgent").UTF8String);
            return 0;
        }

        if (modeStatus) {
            HKPhysicalLink *link = hkPrimaryPhysicalLink();
            NSString *target = hkTargetName();
            printf("target=%s wifiOn=%d hasPhysicalLink=%d iface=%s ip=%s router=%s onHotspot=%d internet=%d paused=%d deadWifi=%d loginItem=%d\n",
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
                   hkLoginItemEnabled());
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

        HKController *ctrl = [HKController new];
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

        HKLog(HKStr(@"HotspotKeeper v%@ 已启动（目标：%@，%@）", @"HotspotKeeper v%@ started (target: %@, %@)"),
              HK_VERSION, hkTargetDisplayName(), modeHeadless ? HKStr(@"纯后台", @"headless") : HKStr(@"菜单栏", @"menu bar"));

        static id activity = nil;
        activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                                  reason:@"HotspotKeeper network watcher"];
        (void)activity;

        dispatch_queue_t watchQueue = dispatch_queue_create("io.github.wangnov.hotspot-keeper.watch", DISPATCH_QUEUE_SERIAL);

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

        static dispatch_source_t timer = nil;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, watchQueue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            [ctrl tick];
        });
        dispatch_resume(timer);

        [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserverForName:NSWorkspaceDidWakeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
                        dispatch_async(watchQueue, ^{ [ctrl onSystemWake]; });
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
        app.delegate = delegate;
        [app run];
        return 0;
    }
}
