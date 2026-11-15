// KAlertXC.m — 今日水印相机 (com.xhey.XCamera) tweak
//
// Mechanism: runtime method hooking, no binary patching.
//   - prefers MSHookMessageEx when a substrate/libhooker is already loaded (dlsym),
//   - otherwise falls back to the ObjC runtime (method_setImplementation),
//     so the dylib has NO link-time dependency on libsubstrate and builds with plain clang.
//
// Verified hook targets against the 3.0.496 main binary:
//   selector 'latestLocation'                                          0x107948f0d
//   selector 'setImage:'                                               0x107c4d7cb
//   selector 'capturedImage:mattePixelBuffer:time:imageOrientation:error:' 0x108635a92
//   method   XHCameraKit -capturedImage:...                            0x10744e2cc
//   selector 'stringFromDate:' / 'dateFromString:'                     0x1085439a2 / 0x108525608
//
// Build: see build.sh (clang, iphoneos SDK, arm64 + arm64e)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define DEFAULTS [NSUserDefaults standardUserDefaults]
#define LOG(fmt, ...) NSLog(@"[KAlertXC] " fmt, ##__VA_ARGS__)

// ------------------------------------------------------------ hook primitive
typedef void (*MSHookMessageEx_t)(Class, SEL, IMP, IMP *);

static MSHookMessageEx_t gMSHook = NULL;

static void hookMethod(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { LOG(@"%@ -%@ missing", NSStringFromClass(cls), NSStringFromSelector(sel)); return; }

    if (!gMSHook) {
        // substrate, libhooker (libhooker exposes MSHookMessageEx too) or ellekit
        gMSHook = (MSHookMessageEx_t)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    }
    if (gMSHook) {
        gMSHook(cls, sel, replacement, original);
        LOG(@"hooked(substrate) %@ -%@", NSStringFromClass(cls), NSStringFromSelector(sel));
    } else {
        if (original) *original = method_getImplementation(m);
        method_setImplementation(m, replacement);
        LOG(@"hooked(runtime) %@ -%@", NSStringFromClass(cls), NSStringFromSelector(sel));
    }
}

static void hookIfPresent(NSString *clsName, NSString *selName, IMP replacement, IMP *original) {
    Class c = NSClassFromString(clsName);
    if (!c) { LOG(@"class %@ not found", clsName); return; }
    hookMethod(c, NSSelectorFromString(selName), replacement, original);
}

// ------------------------------------------------------------ state
static BOOL kEnableLoc(void)  { return [DEFAULTS boolForKey:@"KAlert.XC.enableLoc"]; }
static double kLat(void)      { return [DEFAULTS doubleForKey:@"KAlert.XC.lat"]; }
static double kLng(void)      { return [DEFAULTS doubleForKey:@"KAlert.XC.lng"]; }
static BOOL kEnableDate(void) { return [DEFAULTS boolForKey:@"KAlert.XC.enableDate"]; }
static double kDateTS(void)   { return [DEFAULTS doubleForKey:@"KAlert.XC.dateTS"]; }
static NSString *kPhotoPath(void)   { return [DEFAULTS stringForKey:@"KAlert.XC.photoPath"]; }
static double kPhotoWindowEnd(void) { return [DEFAULTS doubleForKey:@"KAlert.XC.photoWindowEnd"]; }

static CLLocation *kFakeLocation(void) {
    if (!kEnableLoc()) return nil;
    CLLocationCoordinate2D c = CLLocationCoordinate2DMake(kLat(), kLng());
    if (!CLLocationCoordinate2DIsValid(c)) return nil;
    NSDate *ts = kEnableDate() ? [NSDate dateWithTimeIntervalSince1970:kDateTS()] : [NSDate date];
    return [[CLLocation alloc] initWithCoordinate:c
                                         altitude:0
                               horizontalAccuracy:5
                                 verticalAccuracy:5
                                        timestamp:ts];
}

static UIImage *kFakeImage(void) {
    NSString *p = kPhotoPath();
    if (p.length == 0) return nil;
    double end = kPhotoWindowEnd();
    if (end > 0 && [NSDate date].timeIntervalSince1970 > end) return nil;   // outside swap window
    return [UIImage imageWithContentsOfFile:p];
}

// ------------------------------------------------------------ feature 1: location
static id (*orig_latestLocation)(id, SEL);
static id hook_latestLocation(id self, SEL _cmd) {
    CLLocation *fake = kFakeLocation();
    if (fake) {
        LOG(@"latestLocation -> %.6f,%.6f", fake.coordinate.latitude, fake.coordinate.longitude);
        return fake;
    }
    return orig_latestLocation ? orig_latestLocation(self, _cmd) : nil;
}

static void (*orig_didUpdateLocations)(id, SEL, CLLocationManager *, NSArray *);
static void hook_didUpdateLocations(id self, SEL _cmd, CLLocationManager *m, NSArray *locs) {
    CLLocation *fake = kFakeLocation();
    if (fake) locs = @[fake];
    if (orig_didUpdateLocations) orig_didUpdateLocations(self, _cmd, m, locs);
}

static void (*orig_amap_didUpdate)(id, SEL, id, id);
static void hook_amap_didUpdate(id self, SEL _cmd, id mgr, id loc) {
    CLLocation *fake = kFakeLocation();
    if (fake) loc = fake;
    if (orig_amap_didUpdate) orig_amap_didUpdate(self, _cmd, mgr, loc);
}

// ------------------------------------------------------------ feature 2: date
static NSString *(*orig_stringFromDate)(id, SEL, NSDate *);
static NSString *hook_stringFromDate(id self, SEL _cmd, NSDate *d) {
    if (kEnableDate()) d = [NSDate dateWithTimeIntervalSince1970:kDateTS()];
    return orig_stringFromDate ? orig_stringFromDate(self, _cmd, d) : [d description];
}

static NSDate *(*orig_dateFromString)(id, SEL, NSString *);
static NSDate *hook_dateFromString(id self, SEL _cmd, NSString *s) {
    if (kEnableDate()) return [NSDate dateWithTimeIntervalSince1970:kDateTS()];
    return orig_dateFromString ? orig_dateFromString(self, _cmd, s) : nil;
}

// ------------------------------------------------------------ feature 3: photo
static void (*orig_setImage)(id, SEL, UIImage *);
static void hook_setImage(id self, SEL _cmd, UIImage *img) {
    UIImage *fake = kFakeImage();
    if (fake) {
        if (img) LOG(@"UIImageView setImage swap %.0fx%.0f -> %.0fx%.0f",
                     img.size.width, img.size.height, fake.size.width, fake.size.height);
        img = fake;
    }
    if (orig_setImage) orig_setImage(self, _cmd, img);
}

typedef void (*CapturedImageFn)(id, SEL, CVPixelBufferRef, CVPixelBufferRef, CMTime, int, NSError **);
static CapturedImageFn orig_capturedImage;

static void hook_capturedImage(id self, SEL _cmd, CVPixelBufferRef img, CVPixelBufferRef matte,
                               CMTime t, int orient, NSError **err) {
    UIImage *fake = kFakeImage();
    if (fake && img) {
        // Draw IN PLACE into the original pixel buffer: downstream holders must keep the same
        // pointer, otherwise they touch freed memory (the reference mod logs the same invariant).
        CVPixelBufferLockBaseAddress(img, 0);
        void *base = CVPixelBufferGetBaseAddress(img);
        size_t w = CVPixelBufferGetWidth(img), h = CVPixelBufferGetHeight(img);
        if (base && w && h) {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, CVPixelBufferGetBytesPerRow(img),
                                                     cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            if (ctx) {
                CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), fake.CGImage);
                CGContextRelease(ctx);
                LOG(@"in-place draw ok %zux%zu", w, h);
            }
            CGColorSpaceRelease(cs);
        }
        CVPixelBufferUnlockBaseAddress(img, 0);

        if (kEnableDate()) {
            NSDate *fd = [NSDate dateWithTimeIntervalSince1970:kDateTS()];
            t = CMTimeMakeWithSeconds(fd.timeIntervalSince1970, 1000);
        }
    }
    if (orig_capturedImage) orig_capturedImage(self, _cmd, img, matte, t, orient, err);
}

// ------------------------------------------------------------ install
__attribute__((constructor)) static void kalert_init(void) {
    @autoreleasepool {
        LOG(@"loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);

        // location
        for (NSString *cls in @[@"XHLocationManager", @"XCameraCommonBiz.XHLocationManager"]) {
            hookIfPresent(cls, @"latestLocation", (IMP)hook_latestLocation, (IMP *)&orig_latestLocation);
        }
        hookIfPresent(@"CLLocationManager", @"locationManager:didUpdateLocations:",
                      (IMP)hook_didUpdateLocations, (IMP *)&orig_didUpdateLocations);
        hookIfPresent(@"AMapLocationManager", @"amapLocationManager:didUpdateLocation:reGeocode:",
                      (IMP)hook_amap_didUpdate, (IMP *)&orig_amap_didUpdate);

        // date
        hookIfPresent(@"NSDateFormatter", @"stringFromDate:", (IMP)hook_stringFromDate, (IMP *)&orig_stringFromDate);
        hookIfPresent(@"NSDateFormatter", @"dateFromString:", (IMP)hook_dateFromString, (IMP *)&orig_dateFromString);

        // photo
        hookIfPresent(@"UIImageView", @"setImage:", (IMP)hook_setImage, (IMP *)&orig_setImage);
        for (NSString *cls in @[@"XHCameraKit", @"XHMultiCameraKit"]) {
            Class c = NSClassFromString(cls);
            if (!c) continue;
            SEL s = NSSelectorFromString(@"capturedImage:mattePixelBuffer:time:imageOrientation:error:");
            if (class_getInstanceMethod(c, s)) {
                hookMethod(c, s, (IMP)hook_capturedImage, (IMP *)&orig_capturedImage);
            }
        }
    }
}
