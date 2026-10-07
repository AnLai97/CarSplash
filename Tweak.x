// CarSplash — play a short video over the CarPlay screen while CarPlay is starting.
//
// Injected into CarPlay.app (com.apple.CarPlayApp). Each time a car connects, a new UIScreen
// (and, depending on the iOS build, a UIWindowScene) is created for the car display. We put a
// high-level window on top of it, play the chosen video for the configured time, then fade it
// out to reveal the CarPlay home screen underneath.
//
// AVFoundation never finishes loading media inside CarPlay.app, so the settings pane extracts
// each video into JPEG frames (Videos/.frames/<video>/) and we play those as a flipbook.
//
// Logs are prefixed with "[CarSplash]" — filter for it in Console.app to debug.

#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <rootless.h>

#define kPrefsDomain CFSTR("com.anlai.carsplash")
#define kVideosDir   ROOT_PATH_NS(@"/var/mobile/Library/CarSplash/Videos")

static const NSTimeInterval kFadeDuration = 0.4;
static const NSTimeInterval kMaxFullPlay  = 60.0;
static const NSUInteger kFrameBufferSize  = 6;
static char kSplashKey;
static char kShownKey;

#pragma mark - Logging

// Logs go to syslog and to a file readable with Filza. If CarPlay's sandbox blocks the
// Documents folder, fall back to /var/tmp.
static NSString *const kLogPaths[] = { @"/var/mobile/Documents/CarSplash.log", @"/var/tmp/CarSplash.log" };

static void CSLogWrite(NSString *message) {
	NSLog(@"[CarSplash] %@", message);

	static dispatch_queue_t queue;
	static NSDateFormatter *df;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		queue = dispatch_queue_create("com.anlai.carsplash.log", DISPATCH_QUEUE_SERIAL);
		df = [NSDateFormatter new];
		df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
	});
	NSString *line = [NSString stringWithFormat:@"%@ [%d] %@\n", [df stringFromDate:[NSDate date]], getpid(), message];
	dispatch_async(queue, ^{
		for (size_t i = 0; i < sizeof(kLogPaths) / sizeof(kLogPaths[0]); i++) {
			FILE *f = fopen(kLogPaths[i].fileSystemRepresentation, "a");
			if (!f) continue;
			fputs(line.UTF8String, f);
			fclose(f);
			break;
		}
	});
}

#define CSLog(fmt, ...) CSLogWrite([NSString stringWithFormat:fmt, ##__VA_ARGS__])

#pragma mark - Preferences

static id CSPref(NSString *key, id fallback) {
	id value = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key, kPrefsDomain);
	return value ?: fallback;
}

static NSString *CSVideoName(void) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *name = CSPref(@"videoName", nil);
	if (name.length && [fm fileExistsAtPath:[kVideosDir stringByAppendingPathComponent:name]]) return name;
	// Fall back to the first video in the folder.
	NSError *error = nil;
	NSArray *files = [[fm contentsOfDirectoryAtPath:kVideosDir error:&error] sortedArrayUsingSelector:@selector(compare:)];
	if (error) CSLog(@"cannot list %@: %@", kVideosDir, error);
	for (NSString *file in files) {
		if (![file hasPrefix:@"."]) return file;
	}
	return nil;
}

static NSString *CSFramesDir(NSString *videoName) {
	return [[kVideosDir stringByAppendingPathComponent:@".frames"] stringByAppendingPathComponent:videoName];
}

#pragma mark - Frames

static UIImage *CSDecodeFrame(NSString *path) {
	CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
	if (!source) return nil;
	// Decode now, on the background queue, rather than lazily on the main thread at draw time.
	NSDictionary *options = @{(__bridge id)kCGImageSourceShouldCacheImmediately: @YES};
	CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)options);
	CFRelease(source);
	if (!cgImage) return nil;
	UIImage *image = [UIImage imageWithCGImage:cgImage];
	CGImageRelease(cgImage);
	return image;
}

#pragma mark - Splash

// Marker class so the window hook below ignores our own window.
@interface CSSplashWindow : UIWindow
@end

@implementation CSSplashWindow
@end

@interface CSSplash : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, weak) UIScreen *screen;
@property (nonatomic, copy) NSString *framesDir;
@property (nonatomic, assign) NSUInteger frameCount;
@property (nonatomic, assign) double fps;
@property (nonatomic, assign) BOOL loop;
@property (nonatomic, strong) NSMutableArray<UIImage *> *buffer;
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, assign) BOOL decoding;
@property (nonatomic, assign) NSUInteger queuedFrames;
@property (nonatomic, assign) NSUInteger shownFrames;
@property (nonatomic, assign) NSUInteger failedFrames;
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL finished;
@end

@implementation CSSplash

- (instancetype)initWithScreen:(UIScreen *)screen scene:(UIWindowScene *)scene framesDir:(NSString *)framesDir
                    frameCount:(NSUInteger)frameCount fps:(double)fps {
	if ((self = [super init])) {
		_screen = screen;
		_framesDir = [framesDir copy];
		_frameCount = frameCount;
		_fps = fps;
		// Loop the clip until the configured duration is up, unless it should play exactly once.
		_loop = ![CSPref(@"playFull", @NO) boolValue];
		_buffer = [NSMutableArray array];
		_decodeQueue = dispatch_queue_create("com.anlai.carsplash.decode", DISPATCH_QUEUE_SERIAL);

		BOOL fit     = [CSPref(@"scaleMode", @0) integerValue] == 1;
		BOOL tapSkip = [CSPref(@"tapToSkip", @YES) boolValue];

		_imageView = [[UIImageView alloc] initWithFrame:screen.bounds];
		_imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		_imageView.backgroundColor = [UIColor blackColor];
		_imageView.contentMode = fit ? UIViewContentModeScaleAspectFit : UIViewContentModeScaleAspectFill;
		_imageView.clipsToBounds = YES;
		_imageView.userInteractionEnabled = YES;

		UIViewController *vc = [UIViewController new];
		vc.view = _imageView;

		// CarPlay may or may not drive the car display through a UIWindowScene.
		if (scene) {
			_window = [[CSSplashWindow alloc] initWithWindowScene:scene];
		} else {
			_window = [[CSSplashWindow alloc] initWithFrame:screen.bounds];
			// No scene to attach to, so setScreen: is the only way onto the car display.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			_window.screen = screen;
#pragma clang diagnostic pop
		}
		_window.windowLevel = UIWindowLevelAlert + 1000;
		_window.backgroundColor = [UIColor blackColor];
		_window.rootViewController = vc;

		if (tapSkip) {
			UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)];
			[_imageView addGestureRecognizer:tap];
		}
	}
	return self;
}

- (void)start {
	self.window.hidden = NO;
	CSLog(@"splash window shown: frame=%@ level=%.0f scene=%@ frames=%lu fps=%.0f loop=%d",
		NSStringFromCGRect(self.window.frame), self.window.windowLevel,
		self.window.windowScene.session.persistentIdentifier, (unsigned long)self.frameCount, self.fps, self.loop);

	self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
	[self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	[self decodeMore];

	// Safety net in case no frame ever decodes: never block CarPlay for long.
	__weak __typeof(self) weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (weakSelf && !weakSelf.shownFrames) {
			CSLog(@"no frame shown after 10s (failed=%lu), giving up", (unsigned long)weakSelf.failedFrames);
			[weakSelf dismiss];
		}
	});
}

// Decodes frames one at a time on a background queue, keeping a few ready ahead of playback.
- (void)decodeMore {
	if (self.decoding || self.finished || self.buffer.count >= kFrameBufferSize) return;
	if (!self.loop && self.queuedFrames >= self.frameCount) return;
	// Every frame failing would otherwise spin forever.
	if (self.failedFrames >= self.frameCount) return;

	self.decoding = YES;
	NSUInteger index = self.queuedFrames % self.frameCount;
	self.queuedFrames++;
	NSString *path = [self.framesDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%05lu.jpg", (unsigned long)index]];
	dispatch_async(self.decodeQueue, ^{
		UIImage *image = CSDecodeFrame(path);
		dispatch_async(dispatch_get_main_queue(), ^{
			self.decoding = NO;
			if (self.finished) return;
			if (image) {
				[self.buffer addObject:image];
			} else if (self.failedFrames++ == 0) {
				CSLog(@"cannot decode %@", path);
			}
			[self decodeMore];
		});
	});
}

- (void)tick {
	if (self.finished || !self.buffer.count) return;

	CFTimeInterval now = CACurrentMediaTime();
	if (!self.shownFrames) {
		self.startTime = now;
		[self startCountdown];
	} else if (self.shownFrames > (NSUInteger)((now - self.startTime) * self.fps)) {
		return; // Next frame isn't due yet.
	}

	self.imageView.image = self.buffer.firstObject;
	[self.buffer removeObjectAtIndex:0];
	self.shownFrames++;

	if (!self.loop && self.shownFrames >= self.frameCount) {
		[self.displayLink invalidate];
		__weak __typeof(self) weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / self.fps)), dispatch_get_main_queue(), ^{
			[weakSelf dismiss];
		});
		return;
	}
	[self decodeMore];
}

// CarPlay's main thread can stall for seconds while it starts up, so the countdown only
// begins once the first frame is on screen.
- (void)startCountdown {
	NSTimeInterval limit = self.loop ? MAX(1.0, [CSPref(@"duration", @5) doubleValue]) : kMaxFullPlay;
	CSLog(@"first frame shown, playing for up to %.0fs", limit);

	__weak __typeof(self) weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[weakSelf dismiss];
	});
}

- (void)dismiss {
	if (self.finished) return;
	self.finished = YES;
	CSLog(@"dismissing after %lu frames", (unsigned long)self.shownFrames);

	[UIView animateWithDuration:kFadeDuration animations:^{
		self.window.alpha = 0.0;
	} completion:^(BOOL done) {
		[self tearDown];
	}];
}

- (void)tearDown {
	self.finished = YES;
	[self.displayLink invalidate];
	self.displayLink = nil;
	[self.buffer removeAllObjects];
	self.window.hidden = YES;
	self.window = nil;
	UIScreen *screen = self.screen;
	if (screen) objc_setAssociatedObject(screen, &kSplashKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

#pragma mark - Car display detection

static BOOL CSIsCarScreen(UIScreen *screen) {
	if (!screen) return NO;
	if (screen.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomCarPlay) return YES;
	return screen != [UIScreen mainScreen];
}

// Keyed on the car UIScreen: a new screen object is created every time the car connects,
// so this gives one splash per connection whether CarPlay uses scenes or plain windows.
static void CSShowSplash(UIScreen *screen, UIWindowScene *scene, NSString *source) {
	if (!CSIsCarScreen(screen)) return;
	if (objc_getAssociatedObject(screen, &kShownKey)) return;
	objc_setAssociatedObject(screen, &kShownKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	CSLog(@"car display detected via %@: screen=%@ scene=%@", source, screen, scene);

	CFPreferencesAppSynchronize(kPrefsDomain);
	if (![CSPref(@"enabled", @YES) boolValue]) { CSLog(@"disabled in settings"); return; }

	NSString *name = CSVideoName();
	if (!name) { CSLog(@"no video found in %@", kVideosDir); return; }

	NSString *framesDir = CSFramesDir(name);
	NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[framesDir stringByAppendingPathComponent:@"info.plist"]];
	NSUInteger count = [info[@"count"] unsignedIntegerValue];
	double fps = [info[@"fps"] doubleValue];
	if (!count || fps <= 0) {
		CSLog(@"no frames for %@ — open Settings > CarSplash to convert it", name);
		return;
	}
	CSLog(@"playing %@ (%lu frames @ %.0ffps)", name, (unsigned long)count, fps);

	CSSplash *splash = [[CSSplash alloc] initWithScreen:screen scene:scene framesDir:framesDir frameCount:count fps:fps];
	objc_setAssociatedObject(screen, &kSplashKey, splash, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	[splash start];
}

static NSString *CSDescribeScreen(UIScreen *screen) {
	if (!screen) return @"(nil)";
	return [NSString stringWithFormat:@"<%@ %p main=%d idiom=%ld bounds=%@>", NSStringFromClass([screen class]), screen,
		screen == [UIScreen mainScreen], (long)screen.traitCollection.userInterfaceIdiom, NSStringFromCGRect(screen.bounds)];
}

static void CSHandleScene(UIScene *scene, NSString *source) {
	CSLog(@"%@: %@ role=%@", source, NSStringFromClass([scene class]), scene.session.role);
	if (![scene isKindOfClass:[UIWindowScene class]]) return;
	UIWindowScene *windowScene = (UIWindowScene *)scene;
	CSLog(@"%@: idiom=%ld screen=%@", source, (long)windowScene.traitCollection.userInterfaceIdiom,
		CSDescribeScreen(windowScene.screen));
	CSShowSplash(windowScene.screen, windowScene, source);
}

static void CSTearDownScreen(UIScreen *screen) {
	if (!screen) return;
	CSSplash *splash = objc_getAssociatedObject(screen, &kSplashKey);
	[splash tearDown];
}

%hook UIWindow

// Fallback for CarPlay builds that put windows straight onto the car UIScreen without
// posting the UIScene lifecycle notifications.
- (void)setHidden:(BOOL)hidden {
	%orig;
	if (hidden || [self isKindOfClass:[CSSplashWindow class]]) return;
	UIScreen *screen = self.screen;

	// Diagnostics: record the first windows CarPlay shows and where they live.
	static int logged = 0;
	if (logged < 40) {
		logged++;
		CSLog(@"window shown: %@ level=%.0f scene=%@ %p %@ screen=%@", NSStringFromClass([self class]), self.windowLevel,
			self.windowScene ? NSStringFromClass([self.windowScene class]) : @"(nil)", self.windowScene,
			self.windowScene.session.persistentIdentifier, CSDescribeScreen(screen));
	}

	if (!CSIsCarScreen(screen)) return;
	UIWindowScene *scene = self.windowScene;
	// Let CarPlay finish building its own windows first so ours ends up on top.
	dispatch_async(dispatch_get_main_queue(), ^{ CSShowSplash(screen, scene, @"window"); });
}

%end

%ctor {
	CSLog(@"loaded into %@ (%@)", [NSBundle mainBundle].bundleIdentifier, [NSProcessInfo processInfo].processName);
	for (UIScreen *screen in [UIScreen screens]) CSLog(@"existing screen: %@", CSDescribeScreen(screen));
	CSLog(@"videos dir %@ readable=%d", kVideosDir, [[NSFileManager defaultManager] isReadableFileAtPath:kVideosDir]);

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	NSOperationQueue *main = [NSOperationQueue mainQueue];
	[nc addObserverForName:UISceneWillConnectNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		UIScene *scene = note.object;
		dispatch_async(dispatch_get_main_queue(), ^{ CSHandleScene(scene, @"sceneConnect"); });
	}];
	// Trait collection may not be resolved at connect time; retry once the scene activates.
	[nc addObserverForName:UISceneDidActivateNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		CSHandleScene(note.object, @"sceneActivate");
	}];
	[nc addObserverForName:UIScreenDidConnectNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		CSLog(@"screen connected: %@", CSDescribeScreen(note.object));
	}];
	[nc addObserverForName:UIScreenDidDisconnectNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		CSLog(@"screen disconnected: %@", CSDescribeScreen(note.object));
		CSTearDownScreen(note.object);
	}];
	[nc addObserverForName:UISceneDidDisconnectNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		UIScene *scene = note.object;
		if ([scene isKindOfClass:[UIWindowScene class]]) CSTearDownScreen(((UIWindowScene *)scene).screen);
	}];
}
