// CarSplash — play a short video over the CarPlay screen while CarPlay is starting.
//
// Injected into CarPlay.app (com.apple.CarPlayApp). Each time a car connects, a new UIScreen
// (and, depending on the iOS build, a UIWindowScene) is created for the car display. We put a
// high-level window on top of it, play the chosen video for the configured time, then fade it
// out to reveal the CarPlay home screen underneath.
//
// Logs are prefixed with "[CarSplash]" — filter for it in Console.app to debug.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <rootless.h>

#define kPrefsDomain CFSTR("com.anlai.carsplash")
#define kVideosDir   ROOT_PATH_NS(@"/var/mobile/Library/CarSplash/Videos")

static const NSTimeInterval kFadeDuration = 0.4;
static const NSTimeInterval kMaxFullPlay  = 60.0;
static char kSplashKey;
static char kShownKey;

#define CSLog(fmt, ...) NSLog(@"[CarSplash] " fmt, ##__VA_ARGS__)

#pragma mark - Preferences

static id CSPref(NSString *key, id fallback) {
	id value = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key, kPrefsDomain);
	return value ?: fallback;
}

static NSURL *CSVideoURL(void) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *name = CSPref(@"videoName", nil);
	if (name.length) {
		NSString *path = [kVideosDir stringByAppendingPathComponent:name];
		if ([fm fileExistsAtPath:path]) return [NSURL fileURLWithPath:path];
	}
	// Fall back to the first video in the folder.
	NSError *error = nil;
	NSArray *files = [[fm contentsOfDirectoryAtPath:kVideosDir error:&error] sortedArrayUsingSelector:@selector(compare:)];
	if (error) CSLog(@"cannot list %@: %@", kVideosDir, error);
	for (NSString *file in files) {
		if ([file hasPrefix:@"."]) continue;
		return [NSURL fileURLWithPath:[kVideosDir stringByAppendingPathComponent:file]];
	}
	return nil;
}

#pragma mark - Player view

@interface CSPlayerView : UIView
@property (nonatomic, readonly) AVPlayerLayer *playerLayer;
@end

@implementation CSPlayerView
+ (Class)layerClass { return [AVPlayerLayer class]; }
- (AVPlayerLayer *)playerLayer { return (AVPlayerLayer *)self.layer; }
@end

#pragma mark - Splash

// Marker class so the window hook below ignores our own window.
@interface CSSplashWindow : UIWindow
@end

@implementation CSSplashWindow
@end

@interface CSSplash : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) id endObserver;
@property (nonatomic, weak) UIScreen *screen;
@property (nonatomic, assign) BOOL finished;
@end

@implementation CSSplash

- (instancetype)initWithScreen:(UIScreen *)screen scene:(UIWindowScene *)scene videoURL:(NSURL *)url {
	if ((self = [super init])) {
		_screen = screen;

		BOOL sound    = [CSPref(@"sound", @NO) boolValue];
		BOOL fit      = [CSPref(@"scaleMode", @0) integerValue] == 1;
		BOOL tapSkip  = [CSPref(@"tapToSkip", @YES) boolValue];
		BOOL playFull = [CSPref(@"playFull", @NO) boolValue];

		if (sound) {
			// Ambient: mix with whatever is playing instead of interrupting the car audio.
			[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient
			                                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
			                                       error:nil];
		}

		_player = [AVPlayer playerWithURL:url];
		_player.muted = !sound;
		// When a fixed duration is longer than the clip, loop it until time is up.
		_player.actionAtItemEnd = playFull ? AVPlayerActionAtItemEndPause : AVPlayerActionAtItemEndNone;

		CSPlayerView *playerView = [[CSPlayerView alloc] initWithFrame:screen.bounds];
		playerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		playerView.backgroundColor = [UIColor blackColor];
		playerView.playerLayer.player = _player;
		playerView.playerLayer.videoGravity = fit ? AVLayerVideoGravityResizeAspect : AVLayerVideoGravityResizeAspectFill;

		UIViewController *vc = [UIViewController new];
		vc.view = playerView;

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
			[playerView addGestureRecognizer:tap];
		}
	}
	return self;
}

- (void)start {
	self.window.hidden = NO;

	BOOL playFull = [CSPref(@"playFull", @NO) boolValue];
	double duration = MAX(1.0, [CSPref(@"duration", @5) doubleValue]);
	AVPlayerItem *item = self.player.currentItem;

	__weak __typeof(self) weakSelf = self;
	self.endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
	                                                                     object:item
	                                                                      queue:[NSOperationQueue mainQueue]
	                                                                 usingBlock:^(NSNotification *note) {
		if (playFull) [weakSelf dismiss];
		else [weakSelf.player seekToTime:kCMTimeZero];
	}];

	[self.player play];

	// Safety net: never block CarPlay longer than this, even if the video fails to load.
	NSTimeInterval limit = playFull ? kMaxFullPlay : duration;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[weakSelf dismiss];
	});
}

- (void)dismiss {
	if (self.finished) return;
	self.finished = YES;

	[UIView animateWithDuration:kFadeDuration animations:^{
		self.window.alpha = 0.0;
	} completion:^(BOOL done) {
		[self tearDown];
	}];
}

- (void)tearDown {
	[self.player pause];
	if (self.endObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.endObserver];
	self.endObserver = nil;
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

	NSURL *url = CSVideoURL();
	if (!url) { CSLog(@"no video found in %@", kVideosDir); return; }
	CSLog(@"playing %@", url.path);

	CSSplash *splash = [[CSSplash alloc] initWithScreen:screen scene:scene videoURL:url];
	objc_setAssociatedObject(screen, &kSplashKey, splash, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	[splash start];
}

static void CSHandleScene(UIScene *scene, NSString *source) {
	if (![scene isKindOfClass:[UIWindowScene class]]) return;
	UIWindowScene *windowScene = (UIWindowScene *)scene;
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
	if (!CSIsCarScreen(screen)) return;
	UIWindowScene *scene = self.windowScene;
	// Let CarPlay finish building its own windows first so ours ends up on top.
	dispatch_async(dispatch_get_main_queue(), ^{ CSShowSplash(screen, scene, @"window"); });
}

%end

%ctor {
	CSLog(@"loaded into %@", [NSBundle mainBundle].bundleIdentifier);
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
		CSLog(@"screen connected: %@", note.object);
	}];
	[nc addObserverForName:UIScreenDidDisconnectNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		CSTearDownScreen(note.object);
	}];
	[nc addObserverForName:UISceneDidDisconnectNotification object:nil queue:main usingBlock:^(NSNotification *note) {
		UIScene *scene = note.object;
		if ([scene isKindOfClass:[UIWindowScene class]]) CSTearDownScreen(((UIWindowScene *)scene).screen);
	}];
}
