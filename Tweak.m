// EeveeImmersive v5: Apple Music (iOS 27) style immersive cover for Spotify's Now Playing screen.
//
// Layers, back to front:
//   1. Background: darkened color sampled from the very bottom edge of the cover
//   2. Art group (masked so it fades smoothly into the background at its bottom):
//        - sharp cover, edge to edge from the top of the screen, crisp until the fade zone
//        - 4 Gaussian-blurred copies (increasing radius) that ramp in one after another
//          in the fade zone = a progressive blur, only BELOW the artwork, never above it
//
// No method hooks and no Substrate: a 0.5s timer finds the big square cover on screen.
// Needs CoreImage (see Makefile).

#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>

#define EV_DEBUG 0            // set to 1 to show small "loaded / attached" toasts

// ---- Tunables (fractions of the cover height unless noted) ----
#define EV_COVER_HEIGHT 0.625 // cover area height as a fraction of screen height
#define EV_FADE_START   0.76  // artwork stays fully crisp above this line
#define EV_FADE_END     0.985 // artwork has fully faded into the background here

static const void *kBDKey      = &kBDKey;
static const void *kOursKey    = &kOursKey;
static const void *kToastedKey = &kToastedKey;

// ---- Gradient helpers ------------------------------------------------------

// Smoothstep ramp mask. rising: alpha 0 -> 1 between start..end. Otherwise 1 -> 0.
static CAGradientLayer *EVRamp(CGFloat start, CGFloat end, BOOL rising) {
    const int N = 14;
    NSMutableArray *locs = [NSMutableArray array];
    NSMutableArray *cols = [NSMutableArray array];
    void (^add)(CGFloat, CGFloat) = ^(CGFloat loc, CGFloat a) {
        [locs addObject:@(loc)];
        [cols addObject:(id)[UIColor colorWithWhite:0 alpha:a].CGColor];
    };
    add(0.0, rising ? 0.0 : 1.0);
    for (int i = 0; i <= N; i++) {
        CGFloat t = (CGFloat)i / N;
        CGFloat s = t * t * (3 - 2 * t);
        add(start + (end - start) * t, rising ? s : 1.0 - s);
    }
    add(1.0, rising ? 1.0 : 0.0);
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors = cols;
    g.locations = locs;
    g.startPoint = CGPointMake(0.5, 0);
    g.endPoint = CGPointMake(0.5, 1);
    return g;
}

// ---- Image processing ------------------------------------------------------

static CIContext *EVCIContext(void) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    return ctx;
}

static UIImage *EVBlurImage(CGImageRef cg, CGFloat radius) {
    CIImage *input = [CIImage imageWithCGImage:cg];
    CIFilter *f = [CIFilter filterWithName:@"CIGaussianBlur"];
    [f setValue:[input imageByClampingToExtent] forKey:kCIInputImageKey];
    [f setValue:@(radius) forKey:kCIInputRadiusKey];
    CIImage *out = [f.outputImage imageByCroppingToRect:input.extent];
    CGImageRef r = [EVCIContext() createCGImage:out fromRect:input.extent];
    if (!r) return nil;
    UIImage *img = [UIImage imageWithCGImage:r];
    CGImageRelease(r);
    return img;
}

// Color of the very bottom edge of the cover (center area), mapped to a dark tint.
// Dark covers give near-black; bright covers give a rich dark tint (like Apple's).
static UIColor *EVBackgroundColorFor(CGImageRef cg) {
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 8 || h < 8) return UIColor.blackColor;
    CGFloat x0 = floor(w * 0.13), cw = floor(w * 0.74);
    CGFloat y0 = floor(h * 0.92);
    CGImageRef sub = CGImageCreateWithImageInRect(cg, CGRectMake(x0, y0, cw, h - y0));
    if (!sub) return UIColor.blackColor;

    enum { N = 8 };
    uint8_t px[N * N * 4];
    memset(px, 0, sizeof(px));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, N, N, 8, N * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { CGImageRelease(sub); return UIColor.blackColor; }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, N, N), sub);
    CGContextRelease(ctx);
    CGImageRelease(sub);

    double r = 0, g = 0, b = 0;
    for (int i = 0; i < N * N; i++) {
        r += px[i * 4]; g += px[i * 4 + 1]; b += px[i * 4 + 2];
    }
    double d = N * N * 255.0;
    UIColor *avg = [UIColor colorWithRed:r / d green:g / d blue:b / d alpha:1];
    CGFloat hh, ss, bb, aa;
    [avg getHue:&hh saturation:&ss brightness:&bb alpha:&aa];
    bb = MIN(0.42, MAX(0.03, 0.9 * pow(bb, 1.6)));
    ss = MIN(ss * 1.05, 1.0);
    return [UIColor colorWithHue:hh saturation:ss brightness:bb alpha:1];
}

// ---- Backdrop view ---------------------------------------------------------

#define EV_LEVELS 4

@interface EVBackdrop : UIView
@property (nonatomic, strong) UIView *bgView;
@property (nonatomic, strong) UIView *artGroup;
@property (nonatomic, strong) UIImageView *sharpView;
@property (nonatomic, strong) NSArray<UIImageView *> *blurViews;
@property (nonatomic, strong) NSArray<CAGradientLayer *> *blurMasks;
@property (nonatomic, strong) CAGradientLayer *groupMask;
@property (nonatomic, strong) id lastCG;
@property (nonatomic, assign) NSUInteger token;
@property (nonatomic, assign) BOOL hasImage;
- (void)setCGImage:(CGImageRef)cg;
@end

@implementation EVBackdrop

- (instancetype)init {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = UIColor.blackColor;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;

        _bgView = [[UIView alloc] init];
        _bgView.backgroundColor = UIColor.blackColor;
        [self addSubview:_bgView];

        _artGroup = [[UIView alloc] init];
        _artGroup.clipsToBounds = YES;
        _groupMask = EVRamp(EV_FADE_START, EV_FADE_END, NO);
        _artGroup.layer.mask = _groupMask;
        [self addSubview:_artGroup];

        _sharpView = [[UIImageView alloc] init];
        _sharpView.contentMode = UIViewContentModeScaleAspectFill;
        _sharpView.clipsToBounds = YES;
        [_artGroup addSubview:_sharpView];

        // Progressive blur: each level ramps in over its own band, lowest bands blur the most.
        static const CGFloat bands[EV_LEVELS][2] = {
            {0.74, 0.84}, {0.79, 0.89}, {0.84, 0.94}, {0.89, 0.985}
        };
        NSMutableArray *views = [NSMutableArray array];
        NSMutableArray *masks = [NSMutableArray array];
        for (int i = 0; i < EV_LEVELS; i++) {
            UIImageView *v = [[UIImageView alloc] init];
            v.contentMode = UIViewContentModeScaleAspectFill;
            v.clipsToBounds = YES;
            CAGradientLayer *m = EVRamp(bands[i][0], bands[i][1], YES);
            v.layer.mask = m;
            [_artGroup addSubview:v];
            [views addObject:v];
            [masks addObject:m];
        }
        _blurViews = views;
        _blurMasks = masks;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, S = self.bounds.size.height;
    CGFloat H = MIN(S, round(S * EV_COVER_HEIGHT));
    CGRect cover = CGRectMake(0, 0, W, H);

    self.bgView.frame = self.bounds;
    self.artGroup.frame = cover;
    self.sharpView.frame = self.artGroup.bounds;
    for (UIImageView *v in self.blurViews) v.frame = self.artGroup.bounds;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.groupMask.frame = self.artGroup.bounds;
    for (NSUInteger i = 0; i < self.blurViews.count; i++) {
        self.blurMasks[i].frame = self.blurViews[i].bounds;
    }
    [CATransaction commit];
}

- (void)setCGImage:(CGImageRef)cg {
    if (!cg) return;
    if (self.lastCG && (__bridge CGImageRef)self.lastCG == cg) return;
    self.lastCG = (__bridge id)cg;
    NSUInteger token = ++self.token;
    BOOL animate = self.hasImage;

    UIImage *sharp = [UIImage imageWithCGImage:cg];
    UIColor *bg = EVBackgroundColorFor(cg);

    // First attach: show the sharp cover and background immediately, blur follows.
    if (!self.hasImage) {
        self.hasImage = YES;
        self.sharpView.image = sharp;
        self.bgView.backgroundColor = bg;
    }

    CGImageRef kept = CGImageRetain(cg);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CGFloat scale = MAX(1.0, (CGFloat)CGImageGetWidth(kept) / 640.0);
        static const CGFloat radii[EV_LEVELS] = {2.5, 6.0, 12.0, 22.0};
        NSMutableArray *blurs = [NSMutableArray array];
        for (int i = 0; i < EV_LEVELS; i++) {
            UIImage *b = EVBlurImage(kept, radii[i] * scale);
            [blurs addObject:b ?: sharp];
        }
        CGImageRelease(kept);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self.token) return;
            void (^apply)(void) = ^{
                self.sharpView.image = sharp;
                self.bgView.backgroundColor = bg;
                for (NSUInteger i = 0; i < self.blurViews.count; i++) {
                    self.blurViews[i].image = blurs[i];
                }
            };
            if (animate) {
                [UIView transitionWithView:self duration:0.45
                                   options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                                animations:apply completion:nil];
            } else {
                apply();
            }
        });
    });
}

@end

// ---- Finding the cover and attaching --------------------------------------

static NSArray<UIWindow *> *EVWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) return out;
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) [out addObject:w];
    }
    return out;
}

static void EVToast(NSString *text) {
#if EV_DEBUG
    UIWindow *w = nil;
    NSArray *ws = EVWindows();
    for (UIWindow *x in ws) { if (x.isKeyWindow) { w = x; break; } }
    if (!w) w = ws.firstObject;
    if (!w) return;
    UILabel *l = [[UILabel alloc] init];
    l.text = [NSString stringWithFormat:@"  %@  ", text];
    l.font = [UIFont boldSystemFontOfSize:12];
    l.textColor = UIColor.whiteColor;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    l.layer.cornerRadius = 10;
    l.clipsToBounds = YES;
    l.userInteractionEnabled = NO;
    [l sizeToFit];
    CGRect f = l.frame;
    f.size.height += 8;
    f.origin.x = (w.bounds.size.width - f.size.width) / 2;
    f.origin.y = w.safeAreaInsets.top + 4;
    l.frame = f;
    [w addSubview:l];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ l.alpha = 0; }
                         completion:^(BOOL done) { [l removeFromSuperview]; }];
    });
#endif
}

// Cover must be roughly square, nearly screen-wide, and near the top of the screen.
static BOOL EVSizeOK(UIView *v, UIWindow *w) {
    CGRect r = [v convertRect:v.bounds toView:w];
    CGSize ws = w.bounds.size;
    if (r.size.height <= 0) return NO;
    CGFloat ratio = r.size.width / r.size.height;
    if (ratio < 0.9 || ratio > 1.1) return NO;
    if (r.size.width < ws.width * 0.78 || r.size.width > ws.width * 1.05) return NO;
    if (r.origin.y < -4 || r.origin.y > ws.height * 0.45) return NO;
    if (CGRectGetMidX(r) < 0 || CGRectGetMidX(r) > ws.width) return NO;
    return YES;
}

static CGImageRef EVCGImage(UIView *v) {
    if ([v isKindOfClass:[UIImageView class]]) {
        CGImageRef c = ((UIImageView *)v).image.CGImage;
        if (c) return c;
    }
    id contents = v.layer.contents;
    if (contents && CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID()) {
        return (__bridge CGImageRef)contents;
    }
    return NULL;
}

// Nearest full-screen ancestor that is not a scroll view (so the backdrop doesn't scroll).
static UIView *EVContainerFor(UIView *cover, UIWindow *w) {
    CGSize ws = w.bounds.size;
    for (UIView *p = cover.superview; p && p != w; p = p.superview) {
        if ([p isKindOfClass:[UIScrollView class]]) continue;
        CGRect r = [p convertRect:p.bounds toView:w];
        if (r.size.width >= ws.width - 1 && r.size.height >= ws.height * 0.9) return p;
    }
    return nil;
}

static BOOL EVHasContent(UIView *root) {
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:root];
    int n = 0;
    while (q.count && n++ < 60) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]] || [v isKindOfClass:[UIControl class]] ||
            [v isKindOfClass:[UITextView class]]) return YES;
        [q addObjectsFromArray:v.subviews];
    }
    return NO;
}

static void EVApply(UIView *cover, CGImageRef cg, UIWindow *w) {
    UIView *container = EVContainerFor(cover, w);
    if (!container) return;

    EVBackdrop *bd = objc_getAssociatedObject(container, kBDKey);
    BOOL fresh = NO;
    if (!bd) {
        bd = [[EVBackdrop alloc] init];
        objc_setAssociatedObject(bd, kOursKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [container insertSubview:bd atIndex:0];
        objc_setAssociatedObject(container, kBDKey, bd, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        fresh = YES;
    }

    if (!CGRectEqualToRect(bd.frame, container.bounds)) bd.frame = container.bounds;
    if (container.subviews.firstObject != bd) [container sendSubviewToBack:bd];

    container.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    container.backgroundColor = UIColor.clearColor;

    // Hide plain full-size background views (no text/controls) that sit above our backdrop.
    for (UIView *sub in container.subviews) {
        if (sub == bd) continue;
        if ([cover isDescendantOfView:sub]) continue;
        if (sub.hidden) continue;
        if (fabs(sub.frame.size.width - container.bounds.size.width) < 2 &&
            fabs(sub.frame.size.height - container.bounds.size.height) < 2 &&
            !EVHasContent(sub)) {
            sub.alpha = 0;
        }
    }

    [bd setCGImage:cg];
    cover.alpha = 0; // keep it in layout, just invisible

    if (fresh && !objc_getAssociatedObject(container, kToastedKey)) {
        objc_setAssociatedObject(container, kToastedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        EVToast(@"Immersive v5: attached");
    }
}

// Foreground square cover (the smaller rounded one Spotify draws on top, ~70-75% of the
// screen width). EVSizeOK rejects it (too narrow), so it was never hidden and showed up
// over our backdrop. Hide every such square image, plus plain wrapper views around it.
static void EVHideForegroundCovers(UIWindow *w, UIView *main) {
    CGSize ws = w.bounds.size;
    CGRect mainRect = [main convertRect:main.bounds toView:w];
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
    while (q.count) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (objc_getAssociatedObject(v, kOursKey)) continue; // skip our backdrop + children
        if (v != w && v != main && !v.hidden) {
            CGRect r = [v convertRect:v.bounds toView:w];
            if (r.size.height > 0 && !CGRectEqualToRect(r, mainRect)) {
                CGFloat ratio = r.size.width / r.size.height;
                BOOL square = ratio > 0.9 && ratio < 1.1;
                BOOL bigEnough = r.size.width >= ws.width * 0.45 && r.size.width <= ws.width * 0.95;
                BOOL nearTop = r.origin.y >= -4 && r.origin.y < ws.height * 0.45;
                if (square && bigEnough && nearTop && EVCGImage(v)) {
                    v.alpha = 0;
                    // Also hide plain same-size wrappers (shadow / rounded container, no text/controls).
                    for (UIView *p = v.superview; p && p != w; p = p.superview) {
                        CGRect pr = [p convertRect:p.bounds toView:w];
                        if (fabs(pr.size.width - r.size.width) > 2 ||
                            fabs(pr.size.height - r.size.height) > 2) break;
                        if (EVHasContent(p) && ![p isKindOfClass:[UIImageView class]]) {
                            // wrapper has real content besides the image: leave it alone
                            BOOL onlyImage = YES;
                            for (UIView *sv in p.subviews) {
                                if (sv != v && EVHasContent(sv)) { onlyImage = NO; break; }
                            }
                            if (!onlyImage) break;
                        }
                        p.alpha = 0;
                    }
                }
            }
        }
        [q addObjectsFromArray:v.subviews];
    }
}

static BOOL gLoadedToast = NO;

static void EVTick(void) {
    NSArray *wins = EVWindows();
    if (!wins.count) return;
    if (!gLoadedToast) { gLoadedToast = YES; EVToast(@"EeveeImmersive v5 loaded"); }

    for (UIWindow *w in wins) {
        UIView *best = nil;
        CGImageRef bestCG = NULL;
        CGFloat bestScore = -1e9;
        CGFloat midScreen = w.bounds.size.width / 2;

        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        while (q.count) {
            UIView *v = q.firstObject;
            [q removeObjectAtIndex:0];
            if (v.hidden) continue;
            if (objc_getAssociatedObject(v, kOursKey)) continue;
            if (v != w && EVSizeOK(v, w)) {
                CGImageRef cg = EVCGImage(v);
                if (cg) {
                    CGRect r = [v convertRect:v.bounds toView:w];
                    CGFloat score = r.size.width * 1000 - fabs(CGRectGetMidX(r) - midScreen);
                    if (score > bestScore) { bestScore = score; best = v; bestCG = cg; }
                }
            }
            [q addObjectsFromArray:v.subviews];
        }
        if (best && bestCG) {
            EVApply(best, bestCG, w);
            EVHideForegroundCovers(w, best);
        }
    }
}

__attribute__((constructor))
static void EVInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            @autoreleasepool { EVTick(); }
        }];
    });
}
