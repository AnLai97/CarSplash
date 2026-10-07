#import "CSPRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <rootless.h>

#define kPrefsDomain CFSTR("com.anlai.carsplash")
#define kVideosDir   ROOT_PATH_NS(@"/var/mobile/Library/CarSplash/Videos")

// AVFoundation can't load media inside CarPlay.app, so each video is extracted here into JPEG
// frames under Videos/.frames/<video>/ that the tweak plays as a flipbook.
static const int32_t kFrameRate     = 24;
static const double kMaxFrameSeconds = 60.0;
static const CGFloat kMaxFrameSide   = 1920.0;
// Bump when the extraction output changes so existing videos are re-extracted.
static const NSInteger kFramesVersion = 2;

@interface PSSpecifier (CarSplash)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

#pragma mark - Localization

// The app language is picked in the nav bar, so strings come from <lang>.lproj by hand
// instead of following the system language.
static NSDictionary<NSString *, NSString *> *sStrings;

static NSArray<NSString *> *CSPLanguages(void) {
	return @[@"vi", @"en"];
}

static NSString *CSPLanguageName(NSString *lang) {
	return [lang isEqualToString:@"vi"] ? @"Tiếng Việt" : @"English";
}

static NSString *CSPLanguage(void) {
	NSString *lang = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("language"), kPrefsDomain);
	if (lang && [CSPLanguages() containsObject:lang]) return lang;
	return [[NSLocale preferredLanguages].firstObject hasPrefix:@"vi"] ? @"vi" : @"en";
}

static void CSPLoadStrings(void) {
	NSString *bundlePath = [NSBundle bundleForClass:NSClassFromString(@"CSPRootListController")].bundlePath;
	NSString *path = [bundlePath stringByAppendingFormat:@"/%@.lproj/Localizable.strings", CSPLanguage()];
	sStrings = [NSDictionary dictionaryWithContentsOfFile:path] ?: @{};
}

static NSString *L(NSString *key) {
	return sStrings[key] ?: key;
}

#pragma mark - HarmonyOS theme

static UIColor *CSPDynamicColor(UInt32 light, UInt32 dark) {
	UIColor *(^rgb)(UInt32) = ^(UInt32 v) {
		return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1];
	};
	UIColor *l = rgb(light), *d = rgb(dark);
	return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
		return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? d : l;
	}];
}

static UIColor *CSPAccentColor(void)     { return CSPDynamicColor(0x0A59F7, 0x317AF7); }
static UIColor *CSPBackgroundColor(void) { return CSPDynamicColor(0xF1F3F5, 0x000000); }
static UIColor *CSPCardColor(void)       { return CSPDynamicColor(0xFFFFFF, 0x202224); }

static UIColor *CSPColorFromHex(NSString *hex) {
	unsigned int v = 0;
	[[NSScanner scannerWithString:[hex stringByReplacingOccurrencesOfString:@"#" withString:@""]] scanHexInt:&v];
	return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1];
}

// Row icon: a white SF Symbol on a rounded, softly lit color tile.
static UIImage *CSPIcon(NSString *symbol, UIColor *color) {
	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
	UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:config] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
	if (!glyph) return nil;

	const CGFloat side = 29;
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
	return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
		CGRect rect = CGRectMake(0, 0, side, side);
		UIBezierPath *tile = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:8.5];
		[color setFill];
		[tile fill];

		[tile addClip];
		CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
		NSArray *colors = @[(id)[UIColor colorWithWhite:1 alpha:0.22].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
		CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
		CGContextDrawLinearGradient(ctx.CGContext, gradient, CGPointZero, CGPointMake(0, side), 0);
		CGGradientRelease(gradient);
		CGColorSpaceRelease(space);

		CGSize s = glyph.size;
		[glyph drawInRect:CGRectMake((side - s.width) / 2, (side - s.height) / 2, s.width, s.height)];
	}];
}

@interface CSPRootListController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, assign) BOOL extracting;
@end

@implementation CSPRootListController

#pragma mark - Specifiers

- (NSArray *)specifiers {
	if (!_specifiers) {
		CSPLoadStrings();
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
		[self localizeSpecifiers:_specifiers];
		[self refreshVideoList];
	}
	return _specifiers;
}

// Root.plist holds string keys; swap them for the chosen language and attach the row icons.
- (void)localizeSpecifiers:(NSArray<PSSpecifier *> *)specifiers {
	for (PSSpecifier *spec in specifiers) {
		if (spec.name.length) spec.name = L(spec.name);
		NSString *footer = [spec propertyForKey:@"footerText"];
		if (footer) [spec setProperty:L(footer) forKey:@"footerText"];

		if (spec.titleDictionary.count && ![spec.identifier isEqualToString:@"videoName"]) {
			NSMutableDictionary *titles = [NSMutableDictionary dictionary];
			[spec.titleDictionary enumerateKeysAndObjectsUsingBlock:^(id value, NSString *title, BOOL *stop) {
				titles[value] = L(title);
			}];
			spec.titleDictionary = titles;
		}

		NSString *symbol = [spec propertyForKey:@"symbol"];
		if (symbol) {
			UIImage *icon = CSPIcon(symbol, CSPColorFromHex([spec propertyForKey:@"symbolColor"] ?: @"#0A59F7"));
			if (icon) [spec setProperty:icon forKey:@"iconImage"];
		}
	}
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	// Videos added before frame extraction existed (or copied in by hand) still need converting.
	NSMutableArray *missing = [NSMutableArray array];
	for (NSString *file in [self videoFiles]) {
		if (![self hasFramesForVideo:file]) [missing addObject:file];
	}
	[self extractFramesForVideos:missing completion:nil];
}

- (NSArray<NSString *> *)videoFiles {
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm createDirectoryAtPath:kVideosDir withIntermediateDirectories:YES attributes:nil error:nil];
	NSMutableArray *files = [NSMutableArray array];
	for (NSString *file in [fm contentsOfDirectoryAtPath:kVideosDir error:nil]) {
		if (![file hasPrefix:@"."]) [files addObject:file];
	}
	return [files sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (void)refreshVideoList {
	PSSpecifier *spec = nil;
	for (PSSpecifier *s in _specifiers) {
		if ([s.identifier isEqualToString:@"videoName"]) { spec = s; break; }
	}
	if (!spec) return;

	NSArray *files = [self videoFiles];
	if (files.count) {
		NSMutableArray *titles = [NSMutableArray array];
		for (NSString *file in files) [titles addObject:[file stringByDeletingPathExtension]];
		[spec setValues:files titles:titles];
	} else {
		[spec setValues:@[@""] titles:@[L(@"NO_VIDEO")]];
	}
}

#pragma mark - Appearance

- (void)viewDidLoad {
	[super viewDidLoad];
	// Scoped to this controller so the rest of Settings keeps its own look.
	[UISwitch appearanceWhenContainedInInstancesOfClasses:@[[self class]]].onTintColor = CSPAccentColor();
	[UISlider appearanceWhenContainedInInstancesOfClasses:@[[self class]]].minimumTrackTintColor = CSPAccentColor();
	[self applyLanguage];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self reloadSpecifiers];
	self.table.backgroundColor = CSPBackgroundColor();
	self.table.tintColor = CSPAccentColor();
}

- (void)applyLanguage {
	CSPLoadStrings();
	self.title = @"CarSplash";
	self.table.tableHeaderView = [self headerView];
	self.table.tableFooterView = [self footerView];
	self.navigationItem.rightBarButtonItem = [self languageButton];
}

- (UIBarButtonItem *)languageButton {
	NSString *current = CSPLanguage();
	NSMutableArray *actions = [NSMutableArray array];
	for (NSString *lang in CSPLanguages()) {
		UIAction *action = [UIAction actionWithTitle:CSPLanguageName(lang) image:nil identifier:nil handler:^(UIAction *a) {
			[self setLanguage:lang];
		}];
		action.state = [lang isEqualToString:current] ? UIMenuElementStateOn : UIMenuElementStateOff;
		[actions addObject:action];
	}
	UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"globe"] style:UIBarButtonItemStylePlain target:nil action:nil];
	item.menu = [UIMenu menuWithTitle:L(@"LANGUAGE") children:actions];
	item.tintColor = CSPAccentColor();
	return item;
}

- (void)setLanguage:(NSString *)lang {
	CFPreferencesSetAppValue(CFSTR("language"), (__bridge CFStringRef)lang, kPrefsDomain);
	CFPreferencesAppSynchronize(kPrefsDomain);
	[self applyLanguage];
	_specifiers = nil;
	[self reloadSpecifiers];
}

// A full-width table header/footer holding one rounded card: image on the left, text lines on the right.
// The card follows the table's layout margins so it lines up with the inset-grouped rows.
- (UIView *)cardContainerWithHeight:(CGFloat)height insets:(UIEdgeInsets)insets image:(UIImage *)image side:(CGFloat)side lines:(NSArray<UILabel *> *)lines {
	UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, height)];
	container.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	container.preservesSuperviewLayoutMargins = YES;

	UIView *card = [UIView new];
	card.backgroundColor = CSPCardColor();
	card.layer.cornerRadius = 20;
	card.layer.cornerCurve = kCACornerCurveContinuous;
	card.translatesAutoresizingMaskIntoConstraints = NO;
	[container addSubview:card];

	UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
	imageView.translatesAutoresizingMaskIntoConstraints = NO;

	UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:lines];
	text.axis = UILayoutConstraintAxisVertical;
	text.spacing = 3;

	UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[imageView, text]];
	row.alignment = UIStackViewAlignmentCenter;
	row.spacing = 14;
	row.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:row];

	UILayoutGuide *margins = container.layoutMarginsGuide;
	[NSLayoutConstraint activateConstraints:@[
		[card.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
		[card.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
		[card.topAnchor constraintEqualToAnchor:container.topAnchor constant:insets.top],
		[card.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-insets.bottom],
		[imageView.widthAnchor constraintEqualToConstant:side],
		[imageView.heightAnchor constraintEqualToConstant:side],
		[row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
		[row.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-16],
		[row.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
	]];
	return container;
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
	UILabel *label = [UILabel new];
	label.text = text;
	label.font = [UIFont systemFontOfSize:size weight:weight];
	label.textColor = color;
	label.numberOfLines = 0;
	return label;
}

// Top card: app icon, name and description. The enable switch follows as the first row.
- (UIView *)headerView {
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	UIImage *logo = [UIImage imageNamed:@"logo" inBundle:bundle compatibleWithTraitCollection:nil];
	return [self cardContainerWithHeight:128 insets:UIEdgeInsetsMake(16, 0, 0, 0) image:logo side:64 lines:@[
		[self labelWithText:@"CarSplash" size:20 weight:UIFontWeightBold color:[UIColor labelColor]],
		[self labelWithText:L(@"HEADER_TAGLINE") size:13 weight:UIFontWeightRegular color:[UIColor secondaryLabelColor]],
	]];
}

// Bottom card: author logo, app name, version/build and copyright.
- (UIView *)footerView {
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	UIImage *avatar = [UIImage imageNamed:@"avatar" inBundle:bundle compatibleWithTraitCollection:nil];
	return [self cardContainerWithHeight:136 insets:UIEdgeInsetsMake(8, 0, 32, 0) image:avatar side:56 lines:@[
		[self labelWithText:@"CarSplash" size:16 weight:UIFontWeightSemibold color:[UIColor labelColor]],
		[self labelWithText:[NSString stringWithFormat:L(@"VERSION_FORMAT"), @CSP_VERSION] size:13 weight:UIFontWeightRegular color:[UIColor secondaryLabelColor]],
		[self labelWithText:L(@"COPYRIGHT") size:13 weight:UIFontWeightRegular color:[UIColor secondaryLabelColor]],
	]];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
	cell.backgroundColor = CSPCardColor();
	cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

	// Action rows read as regular navigation rows; only the destructive one stays red.
	PSSpecifier *spec = [cell isKindOfClass:[PSTableCell class]] ? ((PSTableCell *)cell).specifier : nil;
	if (spec.cellType == PSButtonCell) {
		BOOL destructive = [[spec propertyForKey:@"isDestructive"] boolValue];
		cell.textLabel.textColor = destructive ? [UIColor systemRedColor] : [UIColor labelColor];
		cell.accessoryType = destructive ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
	if ([PSListController instancesRespondToSelector:_cmd]) [super tableView:tableView willDisplayHeaderView:view forSection:section];
	if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
	UILabel *label = ((UITableViewHeaderFooterView *)view).textLabel;
	label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
	label.textColor = [UIColor secondaryLabelColor];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
	if ([PSListController instancesRespondToSelector:_cmd]) [super tableView:tableView willDisplayFooterView:view forSection:section];
	if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
	UILabel *label = ((UITableViewHeaderFooterView *)view).textLabel;
	label.font = [UIFont systemFontOfSize:12];
	label.textColor = [UIColor secondaryLabelColor];
}

#pragma mark - Pref helpers

- (NSString *)selectedVideo {
	NSString *name = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("videoName"), kPrefsDomain);
	NSArray *files = [self videoFiles];
	if (name.length && [files containsObject:name]) return name;
	return files.firstObject;
}

- (void)setSelectedVideo:(NSString *)name {
	CFPreferencesSetAppValue(CFSTR("videoName"), (__bridge CFStringRef)name, kPrefsDomain);
	CFPreferencesAppSynchronize(kPrefsDomain);
	[self reloadSpecifiers];
}

- (void)showMessage:(NSString *)message {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CarSplash" message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:L(@"OK") style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Frames

- (NSString *)framesDirForVideo:(NSString *)name {
	return [[kVideosDir stringByAppendingPathComponent:@".frames"] stringByAppendingPathComponent:name];
}

- (BOOL)hasFramesForVideo:(NSString *)name {
	NSString *path = [[self framesDirForVideo:name] stringByAppendingPathComponent:@"info.plist"];
	NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:path];
	return [info[@"version"] integerValue] >= kFramesVersion;
}

// Exports the soundtrack to audio.m4a for SpringBoard to play. Returns NO only on a real failure;
// a video without audio is fine.
- (BOOL)extractAudioFromAsset:(AVAsset *)asset seconds:(double)seconds toDir:(NSString *)dir {
	if (![asset tracksWithMediaType:AVMediaTypeAudio].count) return YES;
	AVAssetExportSession *export = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
	if (!export) return NO;
	export.outputURL = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"audio.m4a"]];
	export.outputFileType = AVFileTypeAppleM4A;
	export.timeRange = CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(seconds, 600));
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	[export exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
	return export.status == AVAssetExportSessionStatusCompleted;
}

- (void)extractFramesForVideos:(NSArray<NSString *> *)names completion:(void (^)(void))completion {
	if (!names.count || self.extracting) {
		if (completion) completion();
		return;
	}
	self.extracting = YES;

	UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"CarSplash"
	                                                                  message:[L(@"PREPARING") stringByAppendingString:@"…"]
	                                                           preferredStyle:UIAlertControllerStyleAlert];
	[self presentViewController:progress animated:YES completion:nil];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableArray *failed = [NSMutableArray array];
		[names enumerateObjectsUsingBlock:^(NSString *name, NSUInteger idx, BOOL *stop) {
			NSString *label = names.count > 1 ? [NSString stringWithFormat:@" (%lu/%lu)", (unsigned long)idx + 1, (unsigned long)names.count] : @"";
			NSError *error = nil;
			BOOL ok = [self extractFramesForVideo:name error:&error progress:^(double fraction) {
				dispatch_async(dispatch_get_main_queue(), ^{
					progress.message = [NSString stringWithFormat:@"%@%@… %d%%", L(@"PREPARING"), label, (int)(fraction * 100)];
				});
			}];
			if (!ok) [failed addObject:[NSString stringWithFormat:@"%@: %@", name, error.localizedDescription ?: @"?"]];
		}];
		dispatch_async(dispatch_get_main_queue(), ^{
			self.extracting = NO;
			[progress dismissViewControllerAnimated:YES completion:^{
				if (failed.count) [self showMessage:[NSString stringWithFormat:L(@"PROCESS_FAILED"), [failed componentsJoinedByString:@"\n"]]];
				if (completion) completion();
			}];
		});
	});
}

static CGImagePropertyOrientation CSOrientationForTransform(CGAffineTransform t) {
	if (t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0) return kCGImagePropertyOrientationRight;
	if (t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0) return kCGImagePropertyOrientationLeft;
	if (t.a == -1 && t.d == -1) return kCGImagePropertyOrientationDown;
	return kCGImagePropertyOrientationUp;
}

// Decodes the video sequentially and writes one JPEG per 1/kFrameRate seconds, plus info.plist.
- (BOOL)extractFramesForVideo:(NSString *)name error:(NSError **)error progress:(void (^)(double fraction))progress {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *dir = [self framesDirForVideo:name];
	[fm removeItemAtPath:dir error:nil];
	if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) return NO;

	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[kVideosDir stringByAppendingPathComponent:name]] options:nil];
	AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
	AVAssetReader *reader = track ? [AVAssetReader assetReaderWithAsset:asset error:error] : nil;
	if (!reader) {
		[fm removeItemAtPath:dir error:nil];
		return NO;
	}

	NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
	AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
	output.alwaysCopiesSampleData = NO;
	[reader addOutput:output];
	double seconds = MIN(CMTimeGetSeconds(asset.duration), kMaxFrameSeconds);
	reader.timeRange = CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(seconds, 600));
	if (![reader startReading]) {
		if (error) *error = reader.error;
		[fm removeItemAtPath:dir error:nil];
		return NO;
	}

	CIContext *context = [CIContext contextWithOptions:nil];
	CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGImagePropertyOrientation orientation = CSOrientationForTransform(track.preferredTransform);
	NSDictionary *jpegOptions = @{(id)kCGImageDestinationLossyCompressionQuality: @0.9};
	NSUInteger count = 0;
	double nextTime = 0;

	CMSampleBufferRef sample;
	while ((sample = [output copyNextSampleBuffer])) {
		@autoreleasepool {
			double time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
			CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
			// Keep only the frames that land on our output frame rate.
			if (pixels && time + 0.001 >= nextTime) {
				CIImage *image = [[CIImage imageWithCVPixelBuffer:pixels] imageByApplyingCGOrientation:orientation];
				CGFloat scale = MIN(1.0, kMaxFrameSide / MAX(image.extent.size.width, image.extent.size.height));
				image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
				NSData *jpeg = [context JPEGRepresentationOfImage:image colorSpace:sRGB options:jpegOptions];
				NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%05lu.jpg", (unsigned long)count]];
				if ([jpeg writeToFile:path atomically:NO]) count++;
				nextTime += 1.0 / kFrameRate;
				if (seconds > 0) progress(MIN(1.0, time / seconds));
			}
			CFRelease(sample);
		}
	}
	CGColorSpaceRelease(sRGB);

	if (reader.status == AVAssetReaderStatusFailed || !count) {
		if (error) *error = reader.error;
		[fm removeItemAtPath:dir error:nil];
		return NO;
	}
	// info.plist is written last: its presence marks the frames as complete.
	if (![self extractAudioFromAsset:asset seconds:seconds toDir:dir]) {
		// Keep the frames; the splash just plays silently.
		NSLog(@"[CarSplash] audio export failed for %@", name);
	}
	NSDictionary *info = @{@"fps": @(kFrameRate), @"count": @(count), @"version": @(kFramesVersion)};
	return [info writeToURL:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"info.plist"]] error:error];
}

#pragma mark - Import

- (void)importFromPhotos {
	UIImagePickerController *picker = [UIImagePickerController new];
	picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
	picker.mediaTypes = @[UTTypeMovie.identifier];
	picker.videoExportPreset = AVAssetExportPresetPassthrough;
	picker.delegate = self;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
	NSURL *url = info[UIImagePickerControllerMediaURL];
	[picker dismissViewControllerAnimated:YES completion:^{
		if (!url) return;
		NSDateFormatter *df = [NSDateFormatter new];
		df.dateFormat = @"yyyyMMdd-HHmmss";
		NSString *ext = url.pathExtension.length ? url.pathExtension : @"mov";
		NSString *name = [NSString stringWithFormat:@"Video %@.%@", [df stringFromDate:[NSDate date]], ext];
		[self copyVideoAtURL:url name:name];
	}];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
	[picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)importFromFiles {
	UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie] asCopy:YES];
	picker.delegate = self;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	NSURL *url = urls.firstObject;
	if (url) [self copyVideoAtURL:url name:url.lastPathComponent];
}

- (void)copyVideoAtURL:(NSURL *)source name:(NSString *)name {
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm createDirectoryAtPath:kVideosDir withIntermediateDirectories:YES attributes:nil error:nil];

	// Avoid overwriting an existing video with the same name.
	NSString *base = [name stringByDeletingPathExtension];
	NSString *ext = name.pathExtension;
	NSString *dest = [kVideosDir stringByAppendingPathComponent:name];
	for (int i = 2; [fm fileExistsAtPath:dest]; i++) {
		dest = [kVideosDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d.%@", base, i, ext]];
	}

	NSError *error = nil;
	if (![fm copyItemAtPath:source.path toPath:dest error:&error]) {
		[self showMessage:[NSString stringWithFormat:L(@"SAVE_FAILED"), error.localizedDescription]];
		return;
	}
	[fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:dest error:nil];
	[self setSelectedVideo:dest.lastPathComponent];
	[self extractFramesForVideos:@[dest.lastPathComponent] completion:nil];
}

#pragma mark - Preview / delete

- (void)previewVideo {
	NSString *name = [self selectedVideo];
	if (!name) { [self showMessage:L(@"NO_VIDEO_PREVIEW")]; return; }

	AVPlayerViewController *vc = [AVPlayerViewController new];
	vc.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:[kVideosDir stringByAppendingPathComponent:name]]];
	[self presentViewController:vc animated:YES completion:^{ [vc.player play]; }];
}

- (void)deleteVideo {
	NSString *name = [self selectedVideo];
	if (!name) { [self showMessage:L(@"NO_VIDEO_DELETE")]; return; }

	NSString *message = [NSString stringWithFormat:L(@"DELETE_CONFIRM"), [name stringByDeletingPathExtension]];
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"DELETE_TITLE") message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:L(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:L(@"DELETE_ACTION") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
		[[NSFileManager defaultManager] removeItemAtPath:[kVideosDir stringByAppendingPathComponent:name] error:nil];
		[[NSFileManager defaultManager] removeItemAtPath:[self framesDirForVideo:name] error:nil];
		[self setSelectedVideo:[self videoFiles].firstObject];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end
