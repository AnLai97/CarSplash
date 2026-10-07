#import "CSPRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <rootless.h>

#define kPrefsDomain CFSTR("com.innova.carsplash")
#define kVideosDir   ROOT_PATH_NS(@"/var/mobile/Library/CarSplash/Videos")

@interface PSSpecifier (CarSplash)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

@interface CSPRootListController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
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
		[self setSelectedVideo:[self videoFiles].firstObject];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end
