// EeveeImmersive v3: Apple Music-style player backdrop for Spotify's Now Playing screen.
// Layers (back to front): blurred color wash of the cover, sharp full-width square cover
// that fades out at the bottom, and a dark scrim for text/control readability.
// No method hooks and no Substrate: a 0.5s timer finds the big square cover on screen.
// Set EV_DEBUG to 0 to remove the small status toasts.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define EV_DEBUG 1

// ---- Tunables ----
#define EV_FADE_START 0.60   // fraction of the cover height where the fade to blur begins
#define EV_BLUR_SIZE  32     // downsample size used for the blurred wash (smaller = softer)

static const void *kBDKey      = &kBDKey;
static const void *kOursKey    = &kOursKey;
static const void *kToastedKey = &kToastedKey;

@interface EVBackdrop : UIView
@property (nonatomic, strong) UIImageView *blurView;
@property (nonatomic, strong) UIImageView *sharpView;
@property (nonatomic, strong) UIView *scrim;
@property (nonatomic, strong) CAGradientLayer *maskLayer;
@property (nonatomic, strong) CAGradientLayer *scrimLayer;
@property (nonatomic, strong) id lastCG;
- (void)setCGImage:(CGImageRef)cg;
@end

@implementation EVBackdrop

- (instancetype)init {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = UIColor.blackColor;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;

        _blurView = [[UIImageView alloc] init];
        _blurView.contentMode = UIViewContentModeScaleAspectFill;
        _blurView.clipsToBounds = YES;
        _blurView.alpha = 0.9;
        [self addSubview:_blurView];

        _sharpView = [[UIImageView alloc] init];
        _sharpView.contentMode = UIViewContentModeScaleAspectFill;
        _sharpView.clipsToBounds = YES;
        _maskLayer = [CAGradientLayer layer];
        _maskLayer.colors = @[(id)UIColor.blackColor.CGColor,
                              (id)UIColor.blackColor.CGColor,
                              (id)UIColor.clearColor.CGColor];
        _maskLayer.locations = @[@0.0, @(EV_FADE_START), @1.0];
        _sharpView.layer.mask = _maskLayer;
        [self addSubview:_sharpView];

        _scrim = [[UIView alloc] init];
        _scrim.userInteractionEnabled = NO;
        _scrimLayer = [CAGradientLayer layer];
        _scrimLayer.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.35].CGColor,
                               (id)[UIColor colorWithWhite:0 alpha:0.00].CGColor,
                               (id)[UIColor colorWithWhite:0 alpha:0.10].CGColor,
                               (id)[UIColor colorWithWhite:0 alpha:0.65].CGColor];
        _scrimLayer.locations = @[@0.0, @0.15, @0.50, @1.0];
        [_scrim.layer addSublayer:_scrimLayer];
        [self addSubview:_scrim];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    self.blurView.frame = self.bounds;
    self.sharpView.frame = CGRectMake(0, 0, s.width, s.width); // square, edge to edge
    self.scrim.frame = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.maskLayer.frame = self.sharpView.bounds;
    self.scrimLayer.frame = self.scrim.bounds;
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
    void (^apply)(void) = ^{
        self.sharpView.image = sharp;
        self.blurView.image = blur;
    };
    if (animate) {
        [UIView transitionWithView:self duration:0.35
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
        EVToast(@"Immersive v3: attached");
    }
}

static BOOL gLoadedToast = NO;

static void EVTick(void) {
    NSArray *wins = EVWindows();
    if (!wins.count) return;
    if (!gLoadedToast) { gLoadedToast = YES; EVToast(@"EeveeImmersive v3 loaded"); }

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
