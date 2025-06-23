#import "FilePickerPlugin.h"
#import "FileUtils.h"
#import "ImageUtils.h"
#import <Flutter/Flutter.h>

@interface FilePickerPlugin()
@property (nonatomic) FlutterResult result;
@property (nonatomic) FlutterEventSink eventSink;
#ifdef PICKER_DOCUMENT
@property (nonatomic) UIDocumentPickerViewController *documentPickerController;
@property (nonatomic) UIDocumentInteractionController *interactionController;
#endif
@property (nonatomic) MPMediaPickerController *audioPickerController;
@property (nonatomic) NSArray<NSString *> * allowedExtensions;
@property (nonatomic) BOOL loadDataToMemory;
@property (nonatomic) int compressionQuality;
@property (nonatomic) BOOL allowCompression;
@property (nonatomic) dispatch_group_t group;
@property (nonatomic) MediaType type;
@property (nonatomic) BOOL isSaveFile;
@end

@implementation FilePickerPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    
    FlutterMethodChannel* channel = [FlutterMethodChannel
                                     methodChannelWithName:@"miguelruivo.flutter.plugins.filepicker"
                                     binaryMessenger:[registrar messenger]];
    
    FlutterEventChannel* eventChannel = [FlutterEventChannel
                                         eventChannelWithName:@"miguelruivo.flutter.plugins.filepickerevent"
                                         binaryMessenger:[registrar messenger]];
    
    FilePickerPlugin* instance = [[FilePickerPlugin alloc] init];
    
    [registrar addMethodCallDelegate:instance channel:channel];
    [eventChannel setStreamHandler:instance];
}

- (instancetype)init {
    self = [super init];
    
    return self;
}

- (UIViewController *)viewControllerWithWindow:(UIWindow *)window {
    UIWindow *windowToUse = window;
    if (windowToUse == nil) {
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (window.isKeyWindow) {
                windowToUse = window;
                break;
            }
        }
    }
    
    UIViewController *topController = windowToUse.rootViewController;
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    return topController;
}

- (FlutterError *)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
    _eventSink = events;
    return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
    _eventSink = nil;
    return nil;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if (_result) {
        result([FlutterError errorWithCode:@"multiple_request"
                                   message:@"Cancelled by a second request"
                                   details:nil]);
        return;
    }
    
    _result = result;
    
    if([call.method isEqualToString:@"clear"]) {
        _result([NSNumber numberWithBool: [FileUtils clearTemporaryFiles]]);
        _result = nil;
        return;
    }
    
    if([call.method isEqualToString:@"dir"]) {
        if (@available(iOS 13, *)) {
#ifdef PICKER_DOCUMENT
            [self resolvePickDocumentWithMultiPick:NO pickDirectory:YES];
#else
            _result([FlutterError errorWithCode:@"Unsupported picker type"
                                        message:@"Support for the Document picker is not compiled in. Remove the Pod::PICKER_DOCUMENT=false statement from your Podfile."
                                        details:nil]);
#endif
        } else {
            _result([self getDocumentDirectory]);
            _result = nil;
        }
        return;
    }
    
    NSDictionary * arguments = call.arguments;
    BOOL isMultiplePick = ((NSNumber*)[arguments valueForKey:@"allowMultipleSelection"]).boolValue;

    self.compressionQuality = [[arguments valueForKey:@"compressionQuality"] intValue];
    self.allowCompression = self.compressionQuality > 0;
    self.loadDataToMemory = ((NSNumber*)[arguments valueForKey:@"withData"]).boolValue;
    
    if([call.method isEqualToString:@"any"] || [call.method containsString:@"custom"]) {
        self.allowedExtensions = [FileUtils resolveType:call.method withAllowedExtensions: [arguments valueForKey:@"allowedExtensions"]];
        if(self.allowedExtensions == nil) {
            _result([FlutterError errorWithCode:@"Unsupported file extension"
                                        message:@"If you are providing extension filters make sure that you are only using FileType.custom and the extension are provided without the dot, (ie., jpg instead of .jpg). This could also have happened because you are using an unsupported file extension. If the problem persists, you may want to consider using FileType.any instead."
                                        details:nil]);
            _result = nil;
        } else if(self.allowedExtensions != nil) {
#ifdef PICKER_DOCUMENT
            [self resolvePickDocumentWithMultiPick:isMultiplePick pickDirectory:NO];
#else
            _result([FlutterError errorWithCode:@"Unsupported picker type"
                                        message:@"Support for the Document picker is not compiled in. Remove the Pod::PICKER_DOCUMENT=false statement from your Podfile."
                                        details:nil]);
#endif
        }
    } else if([call.method isEqualToString:@"video"] || [call.method isEqualToString:@"image"] || [call.method isEqualToString:@"media"]) {
        _result([FlutterError errorWithCode:@"Unsupported picker type"
                                    message:@"Support for the Media picker is not compiled in. Remove the Pod::PICKER_MEDIA=false statement from your Podfile."
                                    details:nil]);
    } else if([call.method isEqualToString:@"audio"]) {
        _result([FlutterError errorWithCode:@"Unsupported picker type"
                                    message:@"Support for the Audio picker is not compiled in. Remove the Pod::PICKER_AUDIO=false statement from your Podfile."
                                    details:nil]);
    } else if([call.method isEqualToString:@"save"]) {
#ifdef PICKER_DOCUMENT
        NSString *fileName = [arguments valueForKey:@"fileName"];
        NSString *fileType = [arguments valueForKey:@"fileType"];
        NSString *initialDirectory = [arguments valueForKey:@"initialDirectory"];
        FlutterStandardTypedData *bytes = [arguments valueForKey:@"bytes"];
        [self saveFileWithName:fileName fileType:fileType initialDirectory:initialDirectory bytes: bytes];
#else
        _result([FlutterError errorWithCode:@"Unsupported function"
                                    message:@"The save function requires the document picker to be compiled in. Remove the Pod::PICKER_DOCUMENT=false statement from your Podfile."
                                    details:nil]);
#endif
    } else {
        result(FlutterMethodNotImplemented);
        _result = nil;
    }
}

- (NSString*)getDocumentDirectory {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject;
}

#pragma mark - Resolvers

#ifdef PICKER_DOCUMENT
- (void)saveFileWithName:(NSString*)fileName fileType:(NSString *)fileType initialDirectory:(NSString*)initialDirectory bytes:(FlutterStandardTypedData*)bytes{
    self.isSaveFile = YES;
    NSFileManager* fm = [NSFileManager defaultManager];
    NSURL* documentsDirectory = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    NSURL* destinationPath = [documentsDirectory URLByAppendingPathComponent:fileName];
    NSError* error;
    if ([fm fileExistsAtPath:destinationPath.path]) {
        [fm removeItemAtURL:destinationPath error:&error];
        if (error != nil) {
            _result([FlutterError errorWithCode:@"Failed to remove file" message:[error debugDescription] details:nil]);
            error = nil;
        }
    }
    if(bytes != nil){
        [bytes.data writeToURL:destinationPath options:NSDataWritingAtomic error:&error];
        if (error != nil) {
            _result([FlutterError errorWithCode:@"Failed to write file" message:[error debugDescription] details:nil]);
            error = nil;
        }
    }
    self.documentPickerController = [[UIDocumentPickerViewController alloc] initWithURL:destinationPath inMode:UIDocumentPickerModeExportToService];
    self.documentPickerController.delegate = self;
    self.documentPickerController.presentationController.delegate = self;
    if(@available(iOS 13, *)){
       if(![[NSNull null] isEqual:initialDirectory] && ![@"" isEqualToString:initialDirectory]){
            self.documentPickerController.directoryURL = [NSURL URLWithString:initialDirectory];
        }
    }
    [[self viewControllerWithWindow:nil] presentViewController:self.documentPickerController animated:YES completion:nil];
}
#endif // PICKER_DOCUMENT

#ifdef PICKER_DOCUMENT
- (void)resolvePickDocumentWithMultiPick:(BOOL)allowsMultipleSelection pickDirectory:(BOOL)isDirectory {
    self.isSaveFile = NO;
    @try{
        self.documentPickerController = [[UIDocumentPickerViewController alloc]
                                         initWithDocumentTypes: isDirectory ? @[@"public.folder"] : self.allowedExtensions
                                         inMode: isDirectory ? UIDocumentPickerModeOpen : UIDocumentPickerModeImport];
    } @catch (NSException * e) {
        Log(@"Couldn't launch documents file picker. Probably due to iOS version being below 11.0 and not having the iCloud entitlement. If so, just make sure to enable it for your app in Xcode. Exception was: %@", e);
        _result = nil;
        return;
    }
    
    self.documentPickerController.allowsMultipleSelection = allowsMultipleSelection;    
    self.documentPickerController.delegate = self;
    self.documentPickerController.presentationController.delegate = self;
    
    [[self viewControllerWithWindow:nil] presentViewController:self.documentPickerController animated:YES completion:nil];
}
#endif // PICKER_DOCUMENT

- (void) handleResult:(id) files {
    _result([FileUtils resolveFileInfo: [files isKindOfClass: [NSArray class]] ? files : @[files] withData:self.loadDataToMemory]);
    _result = nil;
}

#pragma mark - Delegates

#ifdef PICKER_DOCUMENT
// DocumentPicker delegate
- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls{
    
    if(_result == nil) {
        return;
    }
    if(self.isSaveFile){
        _result(urls[0].path);
        _result = nil;
        return;
    }
    NSMutableArray<NSURL *> *newUrls;
    if(controller.documentPickerMode == UIDocumentPickerModeOpen) {
        newUrls = urls;
    }
    if(controller.documentPickerMode == UIDocumentPickerModeImport) {
        newUrls = [NSMutableArray new];
        for (NSURL *url in urls) {
            // Create file URL to temporary folder
            NSURL *tempURL = [NSURL fileURLWithPath:NSTemporaryDirectory()];
            // Append filename (name+extension) to URL
            tempURL = [tempURL URLByAppendingPathComponent:url.lastPathComponent];
            NSError *error;
            // If file with same name exists remove it (replace file with new one)
            if ([[NSFileManager defaultManager] fileExistsAtPath:tempURL.path]) {
                [[NSFileManager defaultManager] removeItemAtPath:tempURL.path error:&error];
                if (error) {
                    NSLog(@"%@", error.localizedDescription);
                }
            }
            // Move file from app_id-Inbox to tmp/filename
            [[NSFileManager defaultManager] moveItemAtPath:url.path toPath:tempURL.path error:&error];
            if (error) {
                NSLog(@"%@", error.localizedDescription);
            } else {
                [newUrls addObject:tempURL];
            }
        }
    }
    
    [self.documentPickerController dismissViewControllerAnimated:YES completion:nil];
    
    if(controller.documentPickerMode == UIDocumentPickerModeOpen) {
        _result([newUrls objectAtIndex:0].path);
        _result = nil;
        return;
    }
    
    [self handleResult: newUrls];
}
#endif // PICKER_DOCUMENT

#pragma mark - Actions canceled

#ifdef PICKER_DOCUMENT
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    Log(@"FilePicker canceled");
    _result(nil);
    _result = nil;
    [controller dismissViewControllerAnimated:YES completion:NULL];
}
#endif // PICKER_DOCUMENT

#pragma mark - Alert dialog

@end
