// CarSplash — play a short video over the CarPlay screen while CarPlay is starting.
//
// Injected into CarPlay.app (com.apple.CarPlayApp). Each time a car connects, CarPlay.app
// connects a new UIWindowScene for the car display. We put a high-level window on top of
// that scene, play the chosen video for the configured time, then fade it out to reveal
// the CarPlay home screen underneath.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <rootless.h>

#define kPrefsDomain CFSTR("com.innova.carsplash")
#define kVideosDir   ROOT_PATH_NS(@"/var/mobile/Library/CarSplash/Videos")

static const NSTimeInterval kFadeDuration = 0.4;
static const NSTimeInterval kMaxFullPlay  = 60.0;
static char kSplashKey;
static char kShownKey;

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
	NSArray *files = [[fm contentsOfDirectoryAtPath:kVideosDir error:nil] sortedArrayUsingSelector:@selector(compare:)];
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

@interface CSSplash : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) id endObserver;
@property (nonatomic, weak) UIWindowScene *scene;
@property (nonatomic, assign) BOOL finished;
@end

@implementation CSSplash

- (instancetype)initWithScene:(UIWindowScene *)scene videoURL:(NSURL *)url {
	if ((self = [super init])) {
		_scene = scene;

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

		CSPlayerView *playerView = [[CSPlayerView alloc] initWithFrame:scene.coordinateSpace.bounds];
		playerView.backgroundColor = [UIColor blackColor];
		playerView.playerLayer.player = _player;
		playerView.playerLayer.videoGravity = fit ? AVLayerVideoGravityResizeAspect : AVLayerVideoGravityResizeAspectFill;

		UIViewController *vc = [UIViewController new];
		vc.view = playerView;

		_window = [[UIWindow alloc] initWithWindowScene:scene];
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
	UIWindowScene *scene = self.scene;
	if (scene) objc_setAssociatedObject(scene, &kSplashKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

#pragma mark - Scene handling

static BOOL CSIsCarScene(UIWindowScene *scene) {
	if (![scene isKindOfClass:[UIWindowScene class]]) return NO;
	if (scene.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomCarPlay) return YES;
	return scene.screen && scene.screen != [UIScreen mainScreen];
}

static void CSShowSplash(UIWindowScene *scene) {
	if (!CSIsCarScene(scene)) return;
	// One splash per connection: a new scene object is created every time the car connects.
	if (objc_getAssociatedObject(scene, &kShownKey)) return;
	objc_setAssociatedObject(scene, &kShownKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	CFPreferencesAppSynchronize(kPrefsDomain);
	if (![CSPref(@"enabled", @YES) boolValue]) return;

	NSURL *url = CSVideoURL();
	if (!url) return;

	CSSplash *splash = [[CSSplash alloc] initWithScene:scene videoURL:url];
	objc_setAssociatedObject(scene, &kSplashKey, splash, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	[splash start];
}

%ctor {
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	void (^handler)(NSNotification *) = ^(NSNotification *note) {
		UIWindowScene *scene = note.object;
		// Let CarPlay finish building its own windows first so ours ends up on top.
		dispatch_async(dispatch_get_main_queue(), ^{ CSShowSplash(scene); });
	};
	[nc addObserverForName:UISceneWillConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:handler];
	// Trait collection may not be resolved at connect time; retry once the scene activates.
	[nc addObserverForName:UISceneDidActivateNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:handler];
	[nc addObserverForName:UISceneDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		CSSplash *splash = objc_getAssociatedObject(note.object, &kSplashKey);
		[splash tearDown];
	}];
}
