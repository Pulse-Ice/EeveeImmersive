// EeveeImmersive v4: Apple Music (iOS 27) style immersive cover for Spotify's Now Playing screen.
//
// Layers, back to front:
//   1. Solid color sampled from the bottom of the cover, darkened (like Apple's tinted background)
//   2. Softly blurred copy of the cover, fading in toward the bottom
//   3. Sharp cover, edge to edge from the very top of the screen, fading out toward the bottom
//   4. Light scrim under the status bar
//
// No method hooks and no Substrate: a 0.5s timer finds the big square cover on screen.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define EV_DEBUG 0            // set to 1 to show small "loaded / attached" toasts

// ---- Tunables ----
#define EV_COVER_HEIGHT 0.58  // cover area height as a fraction of screen height
#define EV_BG_DARKEN    0.50  // how much the sampled bottom color is darkened (lower = darker)
#define EV_BLUR_SIZE    48    // downsample size for the blurred layer (smaller = softer)

static const void *kBDKey      = &kBDKey;
static const void *kOursKey    = &kOursKey;
static const void *kToastedKey = &kToastedKey;

static CAGradientLayer *EVMask(NSArray<NSNumber *> *locs, NSArray<NSNumber *> *alphas) {
    CAGradientLayer *g = [CAGradientLayer layer];
    NSMutableArray *cols = [NSMutableArray array];
    for (NSNumber *a in alphas) {
        [cols addObject:(id)[UIColor colorWithWhite:0 alpha:a.doubleValue].CGColor];
    }
    g.colors = cols;
    g.locations = locs;
    g.startPoint = CGPointMake(0.5, 0);
    g.endPoint = CGPointMake(0.5, 1);
    return g;
}

// Average color of the bottom 20% of the cover, darkened and slightly saturated.
static UIColor *EVBackgroundColorFor(CGImageRef cg) {
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 2 || h < 2) return UIColor.blackColor;
    CGFloat y0 = floor(h * 0.80);
    CGImageRef sub = CGImageCreateWithImageInRect(cg, CGRectMake(0, y0, w, h - y0));
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
    bb = MIN(MAX(bb * EV_BG_DARKEN, 0.07), 0.38);
    ss = MIN(ss * 1.1, 1.0);
    return [UIColor colorWithHue:hh saturation:ss brightness:bb alpha:1];
}

@interface EVBackdrop : UIView
@property (nonatomic, strong) UIView *bgView;
@property (nonatomic, strong) UIImageView *blurView;
@property (nonatomic, strong) UIImageView *sharpView;
@property (nonatomic, strong) UIView *topScrim;
@property (nonatomic, strong) CAGradientLayer *blurMask;
@property (nonatomic, strong) CAGradientLayer *sharpMask;
@property (nonatomic, strong) CAGradientLayer *topLayer;
@property (nonatomic, strong) id lastCG;
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

        _blurView = [[UIImageView alloc] init];
        _blurView.contentMode = UIViewContentModeScaleAspectFill;
        _blurView.clipsToBounds = YES;
        _blurMask = EVMask(@[@0.0, @0.40, @0.62, @0.85, @1.0],
                           @[@0.0, @0.0,  @0.90, @0.60, @0.0]);
        _blurView.layer.mask = _blurMask;
        [self addSubview:_blurView];

        _sharpView = [[UIImageView alloc] init];
        _sharpView.contentMode = UIViewContentModeScaleAspectFill;
        _sharpView.clipsToBounds = YES;
        _sharpMask = EVMask(@[@0.0, @0.48, @0.60, @0.70, @0.80, @0.90],
                            @[@1.0, @1.0,  @0.80, @0.45, @0.18, @0.0]);
        _sharpView.layer.mask = _sharpMask;
        [self addSubview:_sharpView];

        _topScrim = [[UIView alloc] init];
        _topScrim.userInteractionEnabled = NO;
        _topLayer = [CAGradientLayer layer];
        _topLayer.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.40].CGColor,
                             (id)[UIColor colorWithWhite:0 alpha:0.0].CGColor];
        [_topScrim.layer addSublayer:_topLayer];
        [self addSubview:_topScrim];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, S = self.bounds.size.height;
    CGFloat H = MIN(S, round(S * EV_COVER_HEIGHT));
    CGRect cover = CGRectMake(0, 0, W, H);

    self.bgView.frame = self.bounds;
    self.blurView.frame = cover;
    self.sharpView.frame = cover;
    self.topScrim.frame = CGRectMake(0, 0, W, H * 0.28);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.blurMask.frame = self.blurView.bounds;
    self.sharpMask.frame = self.sharpView.bounds;
    self.topLayer.frame = self.topScrim.bounds;
    [CATransaction commit];
}

- (UIImage *)blurredFrom:(CGImageRef)cg {
    CGSize s = CGSizeMake(EV_BLUR_SIZE, EV_BLUR_SIZE);
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1;
    f.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:s format:f];
    UIImage *src = [UIImage imageWithCGImage:cg];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextSetInterpolationQuality(ctx.CGContext, kCGInterpolationHigh);
        [src drawInRect:CGRectMake(0, 0, s.width, s.height)];
    }];
}

- (void)setCGImage:(CGImageRef)cg {
    if (!cg) return;
    if (self.lastCG && (__bridge CGImageRef)self.lastCG == cg) return;
    BOOL animate = (self.lastCG != nil);
    self.lastCG = (__bridge id)cg;

    UIImage *sharp = [UIImage imageWithCGImage:cg];
    UIImage *blur = [self blurredFrom:cg];
    UIColor *bg = EVBackgroundColorFor(cg);

    void (^apply)(void) = ^{
        self.sharpView.image = sharp;
        self.blurView.image = blur;
        self.bgView.backgroundColor = bg;
    };
    if (animate) {
        [UIView transitionWithView:self duration:0.45
                           options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                        animations:apply completion:nil];
    } else {
        apply();
    }
}

@end

// ---------------------------------------------------------------------------

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
        EVToast(@"Immersive v4: attached");
    }
}

static BOOL gLoadedToast = NO;

static void EVTick(void) {
    NSArray *wins = EVWindows();
    if (!wins.count) return;
    if (!gLoadedToast) { gLoadedToast = YES; EVToast(@"EeveeImmersive v4 loaded"); }

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
        if (best && bestCG) EVApply(best, bestCG, w);
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
