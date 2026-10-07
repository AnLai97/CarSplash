#import "CSPRootListController.h"
#import <Preferences/PSSpecifier.h>
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

@interface CSPRootListController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, assign) BOOL extracting;
@end

@implementation CSPRootListController

#pragma mark - Specifiers

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
		[self refreshVideoList];
	}
	return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self reloadSpecifiers];
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
		[spec setValues:@[@""] titles:@[@"(Chưa có video)"]];
	}
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
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
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
	                                                                  message:@"Đang chuẩn bị video cho CarPlay…"
	                                                           preferredStyle:UIAlertControllerStyleAlert];
	[self presentViewController:progress animated:YES completion:nil];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableArray *failed = [NSMutableArray array];
		[names enumerateObjectsUsingBlock:^(NSString *name, NSUInteger idx, BOOL *stop) {
			NSString *label = names.count > 1 ? [NSString stringWithFormat:@" (%lu/%lu)", (unsigned long)idx + 1, (unsigned long)names.count] : @"";
			NSError *error = nil;
			BOOL ok = [self extractFramesForVideo:name error:&error progress:^(double fraction) {
				dispatch_async(dispatch_get_main_queue(), ^{
					progress.message = [NSString stringWithFormat:@"Đang chuẩn bị video cho CarPlay%@… %d%%", label, (int)(fraction * 100)];
				});
			}];
			if (!ok) [failed addObject:[NSString stringWithFormat:@"%@: %@", name, error.localizedDescription ?: @"?"]];
		}];
		dispatch_async(dispatch_get_main_queue(), ^{
			self.extracting = NO;
			[progress dismissViewControllerAnimated:YES completion:^{
				if (failed.count) [self showMessage:[NSString stringWithFormat:@"Không xử lý được video:\n%@", [failed componentsJoinedByString:@"\n"]]];
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
		[self showMessage:[NSString stringWithFormat:@"Không thể lưu video: %@", error.localizedDescription]];
		return;
	}
	[fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:dest error:nil];
	[self setSelectedVideo:dest.lastPathComponent];
	[self extractFramesForVideos:@[dest.lastPathComponent] completion:nil];
}

#pragma mark - Preview / delete

- (void)previewVideo {
	NSString *name = [self selectedVideo];
	if (!name) { [self showMessage:@"Chưa có video nào. Hãy thêm video trước."]; return; }

	AVPlayerViewController *vc = [AVPlayerViewController new];
	vc.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:[kVideosDir stringByAppendingPathComponent:name]]];
	[self presentViewController:vc animated:YES completion:^{ [vc.player play]; }];
}

- (void)deleteVideo {
	NSString *name = [self selectedVideo];
	if (!name) { [self showMessage:@"Chưa có video nào để xoá."]; return; }

	NSString *message = [NSString stringWithFormat:@"Xoá \"%@\"?", [name stringByDeletingPathExtension]];
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xoá video" message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Xoá" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
		[[NSFileManager defaultManager] removeItemAtPath:[kVideosDir stringByAppendingPathComponent:name] error:nil];
		[[NSFileManager defaultManager] removeItemAtPath:[self framesDirForVideo:name] error:nil];
		[self setSelectedVideo:[self videoFiles].firstObject];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end
