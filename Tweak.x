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
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <rootless.h>

#define kPrefsDomain CFSTR("com.anlai.carsplash")
#define kVideosDir   ROOT_PATH_NS(@"/var/mobile/Library/CarSplash/Videos")

static const NSTimeInterval kFadeDuration = 0.4;
static const NSTimeInterval kMaxFullPlay  = 60.0;
static const NSTimeInterval kLoadTimeout  = 10.0;
static char kSplashKey;
static char kShownKey;
static char kStatusContext;

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

#pragma mark - Resource loader

// iOS opens media in mediaserverd, whose sandbox can't read the jailbreak prefix, so a plain
// file URL loads forever. Serve the bytes from our own process through a custom scheme instead.
static NSString *const kLoaderScheme = @"carsplash";

@interface CSVideoLoader : NSObject <AVAssetResourceLoaderDelegate>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) BOOL loggedFirstRequest;
- (instancetype)initWithPath:(NSString *)path;
- (AVURLAsset *)asset;
@end

@implementation CSVideoLoader

- (instancetype)initWithPath:(NSString *)path {
	if ((self = [super init])) {
		_path = [path copy];
		_queue = dispatch_queue_create("com.anlai.carsplash.loader", DISPATCH_QUEUE_SERIAL);
	}
	return self;
}

- (AVURLAsset *)asset {
	NSURLComponents *components = [NSURLComponents new];
	components.scheme = kLoaderScheme;
	components.host = @"video";
	components.path = [@"/" stringByAppendingString:self.path.lastPathComponent];
	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:components.URL options:nil];
	[asset.resourceLoader setDelegate:self queue:self.queue];
	return asset;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)loader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request {
	NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:self.path];
	if (!file) {
		CSLog(@"loader: cannot open %@", self.path);
		[request finishLoadingWithError:[NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil]];
		return YES;
	}
	unsigned long long size = [file seekToEndOfFile];

	AVAssetResourceLoadingContentInformationRequest *info = request.contentInformationRequest;
	if (info) {
		UTType *type = [UTType typeWithFilenameExtension:self.path.pathExtension];
		info.contentType = type.identifier ?: AVFileTypeQuickTimeMovie;
		info.contentLength = (long long)size;
		info.byteRangeAccessSupported = YES;
	}

	AVAssetResourceLoadingDataRequest *dataRequest = request.dataRequest;
	if (!self.loggedFirstRequest) {
		self.loggedFirstRequest = YES;
		CSLog(@"loader: first request size=%llu type=%@ offset=%lld length=%ld", size, info.contentType,
			dataRequest.requestedOffset, (long)dataRequest.requestedLength);
	}
	if (dataRequest) {
		unsigned long long offset = (unsigned long long)dataRequest.requestedOffset;
		unsigned long long end = dataRequest.requestsAllDataToEndOfResource ? size
			: MIN(size, offset + (unsigned long long)dataRequest.requestedLength);
		[file seekToFileOffset:offset];
		while (offset < end && !request.isCancelled) {
			NSUInteger chunk = (NSUInteger)MIN(end - offset, 1024 * 1024ULL);
			NSData *data = [file readDataOfLength:chunk];
			if (!data.length) break;
			[dataRequest respondWithData:data];
			offset += data.length;
		}
	}
	[file closeFile];
	[request finishLoading];
	return YES;
}

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
// The resource loader only holds its delegate weakly.
@property (nonatomic, strong) CSVideoLoader *loader;
@property (nonatomic, strong) id endObserver;
@property (nonatomic, weak) UIScreen *screen;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL countdownStarted;
@property (nonatomic, assign) BOOL observingItem;
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

		_loader = [[CSVideoLoader alloc] initWithPath:url.path];
		_player = [AVPlayer playerWithPlayerItem:[AVPlayerItem playerItemWithAsset:[_loader asset]]];
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
	AVPlayerItem *item = self.player.currentItem;

	__weak __typeof(self) weakSelf = self;
	self.endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
	                                                                     object:item
	                                                                      queue:[NSOperationQueue mainQueue]
	                                                                 usingBlock:^(NSNotification *note) {
		if (playFull) [weakSelf dismiss];
		else [weakSelf.player seekToTime:kCMTimeZero];
	}];

	[item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial context:&kStatusContext];
	self.observingItem = YES;
	[self.player play];
	CSLog(@"splash window shown: frame=%@ level=%.0f scene=%@", NSStringFromCGRect(self.window.frame),
		self.window.windowLevel, self.window.windowScene.session.persistentIdentifier);
	[self logAsset:item.asset];

	// CarPlay's main thread can stall for seconds while it starts up, so the countdown only
	// begins once the video is ready. Give up if it never loads.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLoadTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (weakSelf && !weakSelf.countdownStarted) {
			CSLog(@"video not ready after %.0fs (status=%ld error=%@), giving up", kLoadTimeout,
				(long)weakSelf.player.currentItem.status, weakSelf.player.currentItem.error);
			[weakSelf dismiss];
		}
	});
}

- (void)logAsset:(AVAsset *)asset {
	NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.loader.path error:nil];
	CSLog(@"video file size=%@ asset=%@", attrs[NSFileSize], [asset isKindOfClass:[AVURLAsset class]] ? ((AVURLAsset *)asset).URL : asset);
	[asset loadValuesAsynchronouslyForKeys:@[@"playable", @"tracks"] completionHandler:^{
		NSError *error = nil;
		AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&error];
		CSLog(@"asset tracks status=%ld playable=%d error=%@", (long)status, asset.playable, error);
		for (AVAssetTrack *track in [asset tracksWithMediaType:AVMediaTypeVideo]) {
			CMFormatDescriptionRef desc = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
			FourCharCode codec = desc ? CMFormatDescriptionGetMediaSubType(desc) : 0;
			CSLog(@"video track codec=%c%c%c%c size=%@ fps=%.1f", (char)(codec >> 24), (char)(codec >> 16),
				(char)(codec >> 8), (char)codec, NSStringFromCGSize(track.naturalSize), track.nominalFrameRate);
		}
	}];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if (context != &kStatusContext) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}
	AVPlayerItem *item = object;
	dispatch_async(dispatch_get_main_queue(), ^{
		CSLog(@"player item status=%ld error=%@", (long)item.status, item.error);
		if (item.status == AVPlayerItemStatusReadyToPlay) [self startCountdown];
		else if (item.status == AVPlayerItemStatusFailed) [self dismiss];
	});
}

- (void)startCountdown {
	if (self.countdownStarted || self.finished) return;
	self.countdownStarted = YES;

	BOOL playFull = [CSPref(@"playFull", @NO) boolValue];
	double duration = MAX(1.0, [CSPref(@"duration", @5) doubleValue]);
	// Safety net: never block CarPlay longer than this, even if playback stalls.
	NSTimeInterval limit = playFull ? kMaxFullPlay : duration;
	CSLog(@"video ready, showing for %.0fs", limit);

	__weak __typeof(self) weakSelf = self;
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
	if (self.observingItem) [self.player.currentItem removeObserver:self forKeyPath:@"status" context:&kStatusContext];
	self.observingItem = NO;
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
