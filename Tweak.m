// EeveeImmersive (no-Substrate build): full-screen album art on Spotify's Now Playing screen.
// Uses plain Objective-C runtime method replacement, so the dylib has NO dependency
// on CydiaSubstrate / libsubstrate and needs no path fixing.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const void *kBackdropKey = &kBackdropKey;
static const void *kScrimKey    = &kScrimKey;
static const void *kArtKey      = &kArtKey;
static const void *kArtBDKey    = &kArtBDKey;

static NSArray<NSString *> *EVExcluded(void) {
    static NSArray *a;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        a = @[@"Mini", @"Bar", @"Footer", @"Queue", @"Lyrics", @"Sheet",
              @"Button", @"Controls", @"Header", @"Transport", @"Settings"];
    });
    return a;
}

static BOOL EVIsPlayerVC(UIViewController *vc) {
    if (!vc.isViewLoaded || !vc.view.window) return NO;
    NSString *name = NSStringFromClass([vc class]);
    if (![name containsString:@"NowPlaying"]) return NO;
    for (NSString *bad in EVExcluded()) {
        if ([name containsString:bad]) return NO;
    }
    CGRect w = vc.view.window.bounds;
    CGRect f = vc.view.bounds;
    return f.size.width >= w.size.width - 1.0 && f.size.height >= w.size.height * 0.6;
}

static BOOL EVAncestorHasBackdrop(UIViewController *vc) {
    for (UIViewController *p = vc.parentViewController; p; p = p.parentViewController) {
        if (objc_getAssociatedObject(p, kBackdropKey)) return YES;
    }
    return NO;
}

static BOOL EVLooksLikeCover(UIImageView *iv, CGFloat screenW) {
    if (!iv.image) return NO;
    CGSize s = iv.bounds.size;
    if (s.width < screenW * 0.6 || s.height <= 0) return NO;
    CGFloat r = s.width / s.height;
    return r > 0.9 && r < 1.1;
}

static UIImageView *EVFindCover(UIView *root, CGFloat screenW, UIView *skipA, UIView *skipB) {
    UIImageView *best = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (v == skipA || v == skipB) continue;
        if ([v isKindOfClass:[UIImageView class]] && EVLooksLikeCover((UIImageView *)v, screenW)) {
            if (!best || v.bounds.size.width > best.bounds.size.width) best = (UIImageView *)v;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return best;
}

static void EVSetBackdropImage(UIImageView *bd, UIImage *img) {
    if (!bd || !img || bd.image == img) return;
    [UIView transitionWithView:bd duration:0.35
                       options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                    animations:^{ bd.image = img; } completion:nil];
}

static void EVInstall(UIViewController *vc) {
    UIView *root = vc.view;
    UIImageView *bd = objc_getAssociatedObject(vc, kBackdropKey);
    UIView *scrim   = objc_getAssociatedObject(vc, kScrimKey);

    if (!bd) {
        bd = [[UIImageView alloc] init];
        bd.contentMode = UIViewContentModeScaleAspectFill;
        bd.clipsToBounds = YES;
        bd.userInteractionEnabled = NO;
        bd.backgroundColor = UIColor.blackColor;

        scrim = [[UIView alloc] init];
        scrim.userInteractionEnabled = NO;
        CAGradientLayer *g = [CAGradientLayer layer];
        g.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.30].CGColor,
                     (id)[UIColor colorWithWhite:0 alpha:0.00].CGColor,
                     (id)[UIColor colorWithWhite:0 alpha:0.35].CGColor,
                     (id)[UIColor colorWithWhite:0 alpha:0.90].CGColor];
        g.locations = @[@0.0, @0.25, @0.55, @1.0];
        [scrim.layer addSublayer:g];

        [root insertSubview:bd atIndex:0];
        [root insertSubview:scrim aboveSubview:bd];
        objc_setAssociatedObject(vc, kBackdropKey, bd, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, kScrimKey, scrim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    bd.frame = root.bounds;
    scrim.frame = root.bounds;
    scrim.layer.sublayers.firstObject.frame = scrim.bounds;

    if (root.subviews.firstObject != bd || root.subviews.count < 2 || root.subviews[1] != scrim) {
        [root sendSubviewToBack:scrim];
        [root sendSubviewToBack:bd];
    }

    vc.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    root.backgroundColor = UIColor.clearColor;

    for (UIView *sub in root.subviews) {
        if (sub == bd || sub == scrim) continue;
        if ([sub isKindOfClass:[UIImageView class]]) continue;
        if (sub.subviews.count == 0 &&
            fabs(sub.frame.size.width - root.bounds.size.width) < 2 &&
            fabs(sub.frame.size.height - root.bounds.size.height) < 2) {
            sub.alpha = 0;
        }
    }

    CGFloat sw = root.window.bounds.size.width;
    UIImageView *art = EVFindCover(root, sw, bd, scrim);
    if (art) {
        objc_setAssociatedObject(art, kArtKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(art, kArtBDKey, bd, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        EVSetBackdropImage(bd, art.image);
        art.alpha = 0;
    }
}

static UIImageView *EVBackdropForView(UIView *v) {
    UIResponder *r = v;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) {
            for (UIViewController *p = (UIViewController *)r; p; p = p.parentViewController) {
                UIImageView *bd = objc_getAssociatedObject(p, kBackdropKey);
                if (bd) return bd;
            }
        }
        r = r.nextResponder;
    }
    return nil;
}

// ---- Replacement implementations (plain runtime swizzle, no Substrate) ----

static void (*orig_viewDidLayoutSubviews)(id, SEL);
static void new_viewDidLayoutSubviews(UIViewController *self, SEL _cmd) {
    orig_viewDidLayoutSubviews(self, _cmd);
    if (!EVIsPlayerVC(self)) return;
    if (EVAncestorHasBackdrop(self)) return;
    EVInstall(self);
}

static void (*orig_setImage)(id, SEL, UIImage *);
static void new_setImage(UIImageView *self, SEL _cmd, UIImage *image) {
    orig_setImage(self, _cmd, image);
    if (!image) return;

    UIImageView *bd = nil;
    if (objc_getAssociatedObject(self, kArtKey)) {
        bd = objc_getAssociatedObject(self, kArtBDKey);
    } else if (self.window && self.bounds.size.width >= self.window.bounds.size.width * 0.6) {
        CGFloat r = self.bounds.size.height > 0 ? self.bounds.size.width / self.bounds.size.height : 0;
        if (r > 0.9 && r < 1.1) {
            bd = EVBackdropForView(self);
            if (bd && bd != self) {
                objc_setAssociatedObject(self, kArtKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self, kArtBDKey, bd, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                self.alpha = 0;
            }
        }
    }
    if (bd && bd != self) EVSetBackdropImage(bd, image);
}

__attribute__((constructor))
static void EVInit(void) {
    Method m1 = class_getInstanceMethod([UIViewController class], @selector(viewDidLayoutSubviews));
    if (m1) {
        orig_viewDidLayoutSubviews = (void (*)(id, SEL))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)new_viewDidLayoutSubviews);
    }
    Method m2 = class_getInstanceMethod([UIImageView class], @selector(setImage:));
    if (m2) {
        orig_setImage = (void (*)(id, SEL, UIImage *))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)new_setImage);
    }
}
