//
//  SCNewCamera.m
//  SCAudioVideoRecorder
//
//  Created by Simon CORSIN on 27/03/14.
//  Copyright (c) 2014 rFlex. All rights reserved.
//

#import "SCRecorder.h"
#define dispatch_handler(x) if (x != nil) dispatch_async(dispatch_get_main_queue(), x)
#define SCRecorderFocusContext ((void*)0x1)

@interface SCRecorder() {
    AVCaptureVideoPreviewLayer *_previewLayer;
    AVCaptureSession *_captureSession;
    UIView *_previewView;
    AVCaptureVideoDataOutput *_videoOutput;
    AVCaptureAudioDataOutput *_audioOutput;
    AVCaptureStillImageOutput *_photoOutput;
    dispatch_queue_t _capture_queue;
    BOOL _hasVideo;
    BOOL _hasAudio;
    BOOL _usingMainQueue;
    int _beginSessionConfigurationCount;
}

@end

@implementation SCRecorder

- (id)init {
    self = [super init];
    
    if (self) {
        _capture_queue = dispatch_queue_create("me.corsin.SCRecorder", DISPATCH_QUEUE_SERIAL);
        
        _previewLayer = [[AVCaptureVideoPreviewLayer alloc] init];
        _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        
        _videoOutput = [[AVCaptureVideoDataOutput alloc] init];
        _videoOutput.alwaysDiscardsLateVideoFrames = NO;
        [_videoOutput setSampleBufferDelegate:self queue:_capture_queue];
        
        _audioOutput = [[AVCaptureAudioDataOutput alloc] init];
        [_audioOutput setSampleBufferDelegate:self queue:_capture_queue];
     
        _photoOutput = [[AVCaptureStillImageOutput alloc] init];
        _photoOutput.outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
        
        _videoOrientation = AVCaptureVideoOrientationPortrait;
        
        self.device = AVCaptureDevicePositionBack;
        self.videoEnabled = YES;
        self.audioEnabled = YES;
        self.photoEnabled = YES;
    }
    
    return self;
}

- (void)enqueueBlockOnSessionQueue:(void(^)())block
{
    dispatch_async(_capture_queue, block);
}

- (void)enqueueBlockOnMainQueue:(void(^)())block
{
    dispatch_async(dispatch_get_main_queue(), block);
}

- (void)dealloc {
//    [self closeSession];
}

+ (SCRecorder*)recorder {
    return [[SCRecorder alloc] init];
}

- (void)beginSessionConfiguration {
    if (_captureSession != nil) {
        _beginSessionConfigurationCount++;
        if (_beginSessionConfigurationCount == 1) {
            [_captureSession beginConfiguration];
        }
    }
}

- (void)commitSessionConfiguration {
    if (_captureSession != nil) {
        _beginSessionConfigurationCount--;
        if (_beginSessionConfigurationCount == 0) {
            [_captureSession commitConfiguration];
        }
    }
}

- (void)openSession:(void(^)(NSError *sessionError, NSError * audioError, NSError * videoError, NSError *photoError))completionHandler {
    if (_captureSession != nil) {
        [NSException raise:@"SCCameraException" format:@"The session is already opened"];
    }
    
    [self enqueueBlockOnSessionQueue:^{
        
        // we set it to playback for the following reason:
        // if in the video feed you begin loading a video, then you quickly enter the capture session before the video loads, then you begin to record,
        // and midway in that video now completes loading, this causes an interruption in the capture session and halts the recording.
        // by setting to playback with mix with others, this addresses the issue.
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        
        NSError *sessionError = nil;
        NSError *audioError = nil;
        NSError *videoError = nil;
        NSError *photoError = nil;
        
        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        _beginSessionConfigurationCount = 0;
        _captureSession = session;
        
        session.usesApplicationAudioSession = NO;
        
        [self beginSessionConfiguration];
        
        if ([session canSetSessionPreset:self.sessionPreset]) {
            session.sessionPreset = self.sessionPreset;
        } else {
            sessionError = [SCRecorder createError:@"Cannot set session preset"];
        }
        
        _hasVideo = NO;
        if (_videoEnabled) {
            if ([session canAddOutput:_videoOutput]) {
                [session addOutput:_videoOutput];
                _hasVideo = YES;
            } else {
                videoError = [SCRecorder createError:@"Cannot add videoOutput inside the session"];
            }
            
            AVCaptureConnection *connection = [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
            if ([connection isVideoStabilizationSupported]) {
                [connection setEnablesVideoStabilizationWhenAvailable:YES];
            }
        }
        
        _hasAudio = NO;
        if (_audioEnabled) {
            if ([session canAddOutput:_audioOutput]) {
                [session addOutput:_audioOutput];
                _hasAudio = YES;
            } else {
                audioError = [SCRecorder createError:@"Cannot add audioOutput inside the sesssion"];
            }
        }
        if (_photoEnabled) {
            if ([session canAddOutput:_photoOutput]) {
                [session addOutput:_photoOutput];
            } else {
                photoError = [SCRecorder createError:@"Cannot add photoOutput inside the session"];
            }
        }
      
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if([device lockForConfiguration:nil]) {
            if([device isSmoothAutoFocusSupported]) {
                device.smoothAutoFocusEnabled = YES;
            }
            [device unlockForConfiguration];
        }
        
        _previewLayer.session = session;
        
        [self reconfigureInputs];
        
        [self commitSessionConfiguration];
        
        [self enqueueBlockOnMainQueue:^{
            if (completionHandler != nil) {
                completionHandler(nil, audioError, videoError, photoError);
            }
        }];
    }];
}

- (void)startRunningSession:(void (^)())completionHandler {
    [self enqueueBlockOnSessionQueue:^{
        if (_captureSession == nil) {
            [NSException raise:@"SCCamera" format:@"Session was not opened before"];
        }
        
        if (!_captureSession.isRunning) {
            [_captureSession startRunning];
            [self enqueueBlockOnMainQueue:^{
                if (completionHandler != nil) {
                    completionHandler();
                }
            }];
        } else {
            [self enqueueBlockOnMainQueue:^{
                if (completionHandler != nil) {
                    completionHandler();
                }
            }];
        }
    }];
}

- (void)endRunningSession {
    [self enqueueBlockOnSessionQueue:^{
        [_captureSession stopRunning];
        
        // after we complete our usage, we set the category back to solo ambient, the default category
        NSError *error = nil;
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategorySoloAmbient error:&error];
        NSAssert(!error, nil);
    }];
}

- (void)capturePhoto:(void(^)(NSError*, UIImage*))completionHandler {
    AVCaptureConnection *connection = [_photoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (connection != nil) {
        [_photoOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler:
         ^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
             
             if (imageDataSampleBuffer != nil && error == nil) {
                 NSData *jpegData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
                 if (jpegData) {
                     UIImage *image = [UIImage imageWithData:jpegData];
                     if (completionHandler != nil) {
                         completionHandler(nil, image);
                     }
                 } else {
                     if (completionHandler != nil) {
                         completionHandler([SCRecorder createError:@"Failed to create jpeg data"], nil);
                     }
                 }
             } else {
                 if (completionHandler != nil) {
                     completionHandler(error, nil);
                 }
             }
         }];
    } else {
        if (completionHandler != nil) {
            completionHandler([SCRecorder createError:@"Camera session not started or Photo disabled"], nil);
        }
    }
}

- (void)closeSession {
    [self enqueueBlockOnSessionQueue:^{
        if (_captureSession != nil) {
            for (AVCaptureDeviceInput *input in _captureSession.inputs) {
                [_captureSession removeInput:input];
                if ([input.device hasMediaType:AVMediaTypeVideo]) {
                    [self removeVideoObservers:input.device];
                }
                
            }
            for (AVCaptureOutput *output in _captureSession.outputs) {
                [_captureSession removeOutput:output];
            }
            
            _previewLayer.session = nil;
            _captureSession = nil;
        }
    }];
}

- (void)record {
    [self enqueueBlockOnSessionQueue:^{
        _isRecording = YES;
    }];
}

- (void)pause {
    [self pause:nil];
}

- (void)pause:(void(^)())completionHandler {
    [self enqueueBlockOnSessionQueue:^{
        _isRecording = NO;
        SCRecordSession *recordSession = _recordSession;
        
        if (recordSession != nil) {
            if (recordSession.shouldTrackRecordSegments) {
                if (recordSession.recordSegmentReady) {
                    [recordSession endRecordSegment:^(NSInteger segmentIndex, NSError *error) {
                        id<SCRecorderDelegate> delegate = self.delegate;
                        if ([delegate respondsToSelector:@selector(recorder:didEndRecordSegment:segmentIndex:error:)]) {
                            [delegate recorder:self didEndRecordSegment:recordSession segmentIndex:segmentIndex error:error];
                        }
                        if (completionHandler != nil) {
                            completionHandler();
                        }
                    }];
                } else {
                    dispatch_handler(completionHandler);
                }
            } else {
                [recordSession makeTimeOffsetDirty];
                dispatch_handler(completionHandler);
            }
        } else {
            dispatch_handler(completionHandler);
        }
    }];
}

+ (NSError*)createError:(NSString*)errorDescription {
    return [NSError errorWithDomain:@"SCRecorder" code:200 userInfo:@{NSLocalizedDescriptionKey : errorDescription}];
}

- (void)beginRecordSegmentIfNeeded:(SCRecordSession *)recordSession {
    if (!recordSession.recordSegmentBegan) {
        NSError *error = nil;
        [recordSession beginRecordSegment:&error];
        
        id<SCRecorderDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(recorder:didBeginRecordSegment:error:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [delegate recorder:self didBeginRecordSegment:recordSession error:error];
            });
        }
    }
}

- (void)checkRecordSessionDuration:(SCRecordSession *)recordSession {
    CMTime currentRecordDuration = recordSession.currentRecordDuration;
    CMTime suggestedMaxRecordDuration = recordSession.suggestedMaxRecordDuration;
    
    if (CMTIME_IS_VALID(suggestedMaxRecordDuration)) {
        if (CMTIME_COMPARE_INLINE(currentRecordDuration, >=, suggestedMaxRecordDuration)) {
            _isRecording = NO;
            
            [recordSession endRecordSegment:^(NSInteger segmentIndex, NSError *error) {
                id<SCRecorderDelegate> delegate = self.delegate;
                if ([delegate respondsToSelector:@selector(recorder:didEndRecordSegment:segmentIndex:error:)]) {
                    [delegate recorder:self didEndRecordSegment:recordSession segmentIndex:segmentIndex error:error];
                }
                
                if ([delegate respondsToSelector:@selector(recorder:didCompleteRecordSession:)]) {
                    [delegate recorder:self didCompleteRecordSession:recordSession];
                }
            }];
        }
    }
}

- (CMTime)frameDurationFromConnection:(AVCaptureConnection *)connection {
    AVCaptureDevice *device = [self currentVideoDeviceInput].device;
    
    if ([device respondsToSelector:@selector(activeVideoMaxFrameDuration)]) {
        return device.activeVideoMinFrameDuration;
    }
    
    return connection.videoMinFrameDuration;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    SCRecordSession *recordSession = _recordSession;
    
    if (recordSession != nil) {
        if (captureOutput == _videoOutput) {
            if (!recordSession.videoInitializationFailed && !recordSession.shouldIgnoreVideo) {
                if (!recordSession.videoInitialized) {
                    NSError *error = nil;
                    [recordSession initializeVideoUsingSampleBuffer:sampleBuffer hasAudio:_hasAudio error:&error];
                    
                    id<SCRecorderDelegate> delegate = self.delegate;
                    if ([delegate respondsToSelector:@selector(recorder:didInitializeVideoInRecordSession:error:)]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [delegate recorder:self didInitializeVideoInRecordSession:recordSession error:error];
                        });
                    }
                }
                
                
                if (!_hasAudio || recordSession.audioInitialized || recordSession.shouldIgnoreAudio) {
                    [self beginRecordSegmentIfNeeded:recordSession];
                    
                    if (_isRecording && recordSession.recordSegmentReady) {
                        id<SCRecorderDelegate> delegate = self.delegate;
                        if ([recordSession appendVideoSampleBuffer:sampleBuffer frameDuration:[self frameDurationFromConnection:connection]]) {
                            if ([delegate respondsToSelector:@selector(recorder:didAppendVideoSampleBuffer:)]) {
                            
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [delegate recorder:self didAppendVideoSampleBuffer:recordSession];
                                });
                            }
                            
                            [self checkRecordSessionDuration:recordSession];
                        } else {
                            if ([delegate respondsToSelector:@selector(recorder:didSkipVideoSampleBuffer:)]) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [delegate recorder:self didSkipVideoSampleBuffer:recordSession];
                                });
                            }
                        }
                        
                    }
                }
            }
        } else if (captureOutput == _audioOutput) {
            if (!recordSession.audioInitializationFailed && !recordSession.shouldIgnoreAudio) {
                if (!recordSession.audioInitialized) {
                    NSError * error = nil;
                    [recordSession initializeAudioUsingSampleBuffer:sampleBuffer hasVideo:_hasVideo error:&error];
                    
                    id<SCRecorderDelegate> delegate = self.delegate;
                    if ([delegate respondsToSelector:@selector(recorder:didInitializeAudioInRecordSession:error:)]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [delegate recorder:self didInitializeAudioInRecordSession:recordSession error:error];
                        });
                    }
                }
                
                if (!_hasVideo || recordSession.videoInitialized || recordSession.shouldIgnoreVideo) {
                    [self beginRecordSegmentIfNeeded:recordSession];
                    
                    if (_isRecording && recordSession.recordSegmentReady) {
                        id<SCRecorderDelegate> delegate = self.delegate;
                        if ([recordSession appendAudioSampleBuffer:sampleBuffer]) {
                            if ([delegate respondsToSelector:@selector(recorder:didAppendAudioSampleBuffer:)]) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [delegate recorder:self didAppendAudioSampleBuffer:recordSession];
                                });
                            }
                            
                            [self checkRecordSessionDuration:recordSession];
                        } else {
                            if ([delegate respondsToSelector:@selector(recorder:didSkipAudioSampleBuffer:)]) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [delegate recorder:self didSkipAudioSampleBuffer:recordSession];
                                });
                            }
                        }
                    }
                }
            }
        }
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    id<SCRecorderDelegate> delegate = self.delegate;
    
    if (context == SCRecorderFocusContext) {
        BOOL isFocusing = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        if (isFocusing) {
            if ([delegate respondsToSelector:@selector(recorderDidStartFocus:)]) {
                [delegate recorderDidStartFocus:self];
            }
        } else {
            if ([delegate respondsToSelector:@selector(recorderDidEndFocus:)]) {
                [delegate recorderDidEndFocus:self];
            }
        }
    }
}

- (void)addVideoObservers:(AVCaptureDevice*)videoDevice {
    [videoDevice addObserver:self forKeyPath:@"adjustingFocus" options:NSKeyValueObservingOptionNew context:SCRecorderFocusContext];
}

- (void)removeVideoObservers:(AVCaptureDevice*)videoDevice {
    [videoDevice removeObserver:self forKeyPath:@"adjustingFocus"];
}

- (void)configureDevice:(AVCaptureDevice*)newDevice mediaType:(NSString*)mediaType error:(NSError**)error {
    AVCaptureDeviceInput *currentInput = [self currentDeviceInputForMediaType:mediaType];
    AVCaptureDevice *currentUsedDevice = currentInput.device;
    
    if (currentUsedDevice != newDevice) {
        AVCaptureDeviceInput *newInput = nil;
        
        if (newDevice != nil) {
            newInput = [[AVCaptureDeviceInput alloc] initWithDevice:newDevice error:error];
        }
        
        if (*error == nil) {
            if (currentInput != nil) {
                [_captureSession removeInput:currentInput];
                if ([currentInput.device hasMediaType:AVMediaTypeVideo]) {
                    [self removeVideoObservers:currentInput.device];
                }
            }
            
            if (newInput != nil) {
                if ([_captureSession canAddInput:newInput]) {
                    [_captureSession addInput:newInput];
                    if ([newInput.device hasMediaType:AVMediaTypeVideo]) {
                        [self addVideoObservers:newInput.device];
                    }
                } else {
                    *error = [SCRecorder createError:@"Failed to add input to capture session"];
                }
            }
        }
    }
}

- (void)reconfigureInputs {
    [self beginSessionConfiguration];
    
    NSError *videoError = nil;
    [self configureDevice:[self videoDevice] mediaType:AVMediaTypeVideo error:&videoError];
    self.videoOrientation = _videoOrientation;
    
    NSError *audioError = nil;
    [self configureDevice:[self audioDevice] mediaType:AVMediaTypeAudio error:&audioError];
    
    [self commitSessionConfiguration];
    
    id<SCRecorderDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(recorder:didReconfigureInputs:audioInputError:)]) {
        [delegate recorder:self didReconfigureInputs:videoError audioInputError:audioError];
    }
}

- (void)switchCaptureDevices {
    [self enqueueBlockOnSessionQueue:^{
        if (self.device == AVCaptureDevicePositionBack) {
            self.device = AVCaptureDevicePositionFront;
        } else {
            self.device = AVCaptureDevicePositionBack;
        }
    }];
}


#pragma mark - FOCUS

// Convert from view coordinates to camera coordinates, where {0,0} represents the top left of the picture area, and {1,1} represents
// the bottom right in landscape mode with the home button on the right.
- (CGPoint)convertToPointOfInterestFromViewCoordinates:(CGPoint)viewCoordinates
{
    CGPoint pointOfInterest = CGPointMake(.5f, .5f);
    CGSize frameSize = self.previewView.frame.size;
    
    if ([self.previewLayer.connection isVideoMirrored]) {
        viewCoordinates.x = frameSize.width - viewCoordinates.x;
    }
    
    if ( [[self.previewLayer videoGravity] isEqualToString:AVLayerVideoGravityResize] ) {
		// Scale, switch x and y, and reverse x
        pointOfInterest = CGPointMake(viewCoordinates.y / frameSize.height, 1.f - (viewCoordinates.x / frameSize.width));
    } else {
        CGRect cleanAperture;
        for (AVCaptureInputPort *port in [self.currentVideoDeviceInput ports]) {
            if ([port mediaType] == AVMediaTypeVideo) {
                cleanAperture = CMVideoFormatDescriptionGetCleanAperture([port formatDescription], YES);
                CGSize apertureSize = cleanAperture.size;
                CGPoint point = viewCoordinates;
                
                CGFloat apertureRatio = apertureSize.height / apertureSize.width;
                CGFloat viewRatio = frameSize.width / frameSize.height;
                CGFloat xc = .5f;
                CGFloat yc = .5f;
                
                if ( [[self.previewLayer videoGravity] isEqualToString:AVLayerVideoGravityResizeAspect] ) {
                    if (viewRatio > apertureRatio) {
                        CGFloat y2 = frameSize.height;
                        CGFloat x2 = frameSize.height * apertureRatio;
                        CGFloat x1 = frameSize.width;
                        CGFloat blackBar = (x1 - x2) / 2;
						// If point is inside letterboxed area, do coordinate conversion; otherwise, don't change the default value returned (.5,.5)
                        if (point.x >= blackBar && point.x <= blackBar + x2) {
							// Scale (accounting for the letterboxing on the left and right of the video preview), switch x and y, and reverse x
                            xc = point.y / y2;
                            yc = 1.f - ((point.x - blackBar) / x2);
                        }
                    } else {
                        CGFloat y2 = frameSize.width / apertureRatio;
                        CGFloat y1 = frameSize.height;
                        CGFloat x2 = frameSize.width;
                        CGFloat blackBar = (y1 - y2) / 2;
						// If point is inside letterboxed area, do coordinate conversion. Otherwise, don't change the default value returned (.5,.5)
                        if (point.y >= blackBar && point.y <= blackBar + y2) {
							// Scale (accounting for the letterboxing on the top and bottom of the video preview), switch x and y, and reverse x
                            xc = ((point.y - blackBar) / y2);
                            yc = 1.f - (point.x / x2);
                        }
                    }
                } else if ([[self.previewLayer videoGravity] isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
					// Scale, switch x and y, and reverse x
                    if (viewRatio > apertureRatio) {
                        CGFloat y2 = apertureSize.width * (frameSize.width / apertureSize.height);
                        xc = (point.y + ((y2 - frameSize.height) / 2.f)) / y2; // Account for cropped height
                        yc = (frameSize.width - point.x) / frameSize.width;
                    } else {
                        CGFloat x2 = apertureSize.height * (frameSize.height / apertureSize.width);
                        yc = 1.f - ((point.x + ((x2 - frameSize.width) / 2)) / x2); // Account for cropped width
                        xc = point.y / frameSize.height;
                    }
                }
                
                pointOfInterest = CGPointMake(xc, yc);
                break;
            }
        }
    }
    
    return pointOfInterest;
}

// Perform an auto focus at the specified point. The focus mode will automatically change to locked once the auto focus is complete.
- (void)autoFocusAtPoint:(CGPoint)point {
    AVCaptureDevice *device = [self.currentVideoDeviceInput device];
    if ([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
        NSError *error;
        if ([device lockForConfiguration:&error]) {
            [device setFocusPointOfInterest:point];
            [device setFocusMode:AVCaptureFocusModeAutoFocus];
            [device unlockForConfiguration];
            
            id<SCRecorderDelegate> delegate = self.delegate;
            if ([delegate respondsToSelector:@selector(recorderWillStartFocus:)]) {
                [delegate recorderWillStartFocus:self];
            }
        }
    }
}

// Switch to continuous auto focus mode at the specified point
- (void)continuousFocusAtPoint:(CGPoint)point {
    AVCaptureDevice *device = [self.currentVideoDeviceInput device];
	
    if ([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
		NSError *error;
		if ([device lockForConfiguration:&error]) {
			[device setFocusPointOfInterest:point];
			[device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
			[device unlockForConfiguration];
            
            id<SCRecorderDelegate> delegate = self.delegate;
            if ([delegate respondsToSelector:@selector(recorderWillStartFocus:)]) {
                [delegate recorderWillStartFocus:self];
            }
		}
	}
}

- (BOOL)focusSupported {
    return [self currentVideoDeviceInput].device.isFocusPointOfInterestSupported;
}

- (AVCaptureDeviceInput*)currentAudioDeviceInput {
    return [self currentDeviceInputForMediaType:AVMediaTypeAudio];
}

- (AVCaptureDeviceInput*)currentVideoDeviceInput {
    return [self currentDeviceInputForMediaType:AVMediaTypeVideo];
}

- (AVCaptureDeviceInput*)currentDeviceInputForMediaType:(NSString*)mediaType {
    for (AVCaptureDeviceInput* deviceInput in _captureSession.inputs) {
        if ([deviceInput.device hasMediaType:mediaType]) {
            return deviceInput;
        }
    }
    
    return nil;
}

- (AVCaptureDevice*)audioDevice {
    if (!self.audioEnabled) {
        return nil;
    }
    
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
}

- (AVCaptureDevice*)videoDevice {
    if (!self.videoEnabled) {
        return nil;
    }
    
	NSArray * videoDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
	
	for (AVCaptureDevice * device in videoDevices) {
		if (device.position == (AVCaptureDevicePosition)_device) {
			return device;
		}
	}
	
	return nil;
}

- (AVCaptureSession*)captureSession {
    return _captureSession;
}

- (void)setPreviewView:(UIView *)previewView {
    [_previewLayer removeFromSuperlayer];
    
    _previewView = previewView;
    
    if (_previewView != nil) {
        _previewLayer.frame = _previewView.bounds;
        [_previewView.layer insertSublayer:_previewLayer atIndex:0];
        
    }
}

- (UIView*)previewView {
    return _previewView;
}

- (NSDictionary*)photoOutputSettings {
    return _photoOutput.outputSettings;
}

- (void)setPhotoOutputSettings:(NSDictionary *)photoOutputSettings {
    _photoOutput.outputSettings = photoOutputSettings;
}

- (void)setDevice:(AVCaptureDevicePosition)device {
    [self enqueueBlockOnSessionQueue:^{
        _device = device;
        if (_captureSession != nil) {
            [self reconfigureInputs];
        }
    }];
}

- (void)setFlashMode:(SCFlashMode)flashMode {
    AVCaptureDevice *currentDevice = [self videoDevice];
    NSError *error = nil;
    
    if (currentDevice.hasFlash) {
        if ([currentDevice lockForConfiguration:&error]) {
            if (flashMode == SCFlashModeLight) {
                if ([currentDevice isTorchModeSupported:AVCaptureTorchModeOn]) {
                    [currentDevice setTorchMode:AVCaptureTorchModeOn];
                }
                if ([currentDevice isFlashModeSupported:AVCaptureFlashModeOff]) {
                    [currentDevice setFlashMode:AVCaptureFlashModeOff];
                }
            } else {
                if ([currentDevice isTorchModeSupported:AVCaptureTorchModeOff]) {
                    [currentDevice setTorchMode:AVCaptureTorchModeOff];
                }
                if ([currentDevice isFlashModeSupported:(AVCaptureFlashMode)flashMode]) {
                    [currentDevice setFlashMode:(AVCaptureFlashMode)flashMode];
                }
            }
            
            [currentDevice unlockForConfiguration];
        }
    } else {
        error = [SCRecorder createError:@"Current device does not support flash"];
    }
    
    id<SCRecorderDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(recorder:didChangeFlashMode:error:)]) {
        [delegate recorder:self didChangeFlashMode:flashMode error:error];
    }
    
    if (error == nil) {
        _flashMode = flashMode;
    }
}

- (AVCaptureVideoPreviewLayer*)previewLayer {
    return _previewLayer;
}

- (BOOL)isCaptureSessionOpened {
    return _captureSession != nil;
}

- (void)setSessionPreset:(NSString *)sessionPreset {
    if (_captureSession != nil) {
        NSError *error = nil;
        if ([_captureSession canSetSessionPreset:sessionPreset]) {
            [_captureSession beginConfiguration];
            _captureSession.sessionPreset = sessionPreset;
            [_captureSession commitConfiguration];
        } else {
            error = [SCRecorder createError:@"Failed to set session preset"];
        }
        
        if (error == nil) {
            _sessionPreset = [sessionPreset copy];
        }
        
        id<SCRecorderDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(recorder:didChangeSessionPreset:error:)]) {
            [delegate recorder:self didChangeSessionPreset:sessionPreset error:error];
        }
    } else {
        _sessionPreset = [sessionPreset copy];
    }
}

- (void)setVideoOrientation:(AVCaptureVideoOrientation)videoOrientation {
    _videoOrientation = videoOrientation;
    [[_videoOutput connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:videoOrientation];
}

- (void)setRecordSession:(SCRecordSession *)recordSession {
    [self enqueueBlockOnSessionQueue:^{
        if (_recordSession != recordSession) {
            [recordSession makeTimeOffsetDirty];
            _recordSession = recordSession;
        }
    }];
}

- (AVCaptureFocusMode)focusMode {
    return [self currentVideoDeviceInput].device.focusMode;
}

- (BOOL)formatInRange:(AVCaptureDeviceFormat*)format frameRate:(CMTimeScale)frameRate dimensions:(CMVideoDimensions)dimensions {
    CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    
    if (size.width >= dimensions.width && size.height >= dimensions.height) {
        for (AVFrameRateRange * range in format.videoSupportedFrameRateRanges) {
            if ((CMTimeScale)range.minFrameRate <= frameRate && (CMTimeScale)range.maxFrameRate >= frameRate) {
                return YES;
            }
        }
    }
    
    return NO;
}

- (AVCaptureConnection*) getVideoConnection {
	for (AVCaptureConnection * connection in _videoOutput.connections) {
		for (AVCaptureInputPort * port in connection.inputPorts) {
			if ([port.mediaType isEqual:AVMediaTypeVideo]) {
				return connection;
			}
		}
	}
	
	return nil;
}

- (CMTimeScale)frameRate {
    AVCaptureDeviceInput * deviceInput = [self currentVideoDeviceInput];
    
    CMTimeScale framerate = 0;
    
    if (deviceInput != nil) {
        if ([deviceInput.device respondsToSelector:@selector(activeVideoMaxFrameDuration)]) {
            framerate = deviceInput.device.activeVideoMaxFrameDuration.timescale;
        } else {
            AVCaptureConnection * videoConnection = [self getVideoConnection];
            framerate = videoConnection.videoMaxFrameDuration.timescale;
        }
    }
    
    return framerate;
}

- (void)setFrameRate:(CMTimeScale)framePerSeconds {
    CMTime fps = CMTimeMake(1, framePerSeconds);
    
    AVCaptureDevice * device = [self videoDevice];
    
    if (device != nil) {
        NSError * error = nil;
        BOOL formatSupported = NO;
        for (AVFrameRateRange * frameRateRange in device.activeFormat.videoSupportedFrameRateRanges) {
            if (((NSInteger)frameRateRange.minFrameRate <= framePerSeconds) && (framePerSeconds <= (NSInteger)frameRateRange.maxFrameRate)) {
                formatSupported = YES;
                break;
            }
        }
        
        if (formatSupported) {
            if ([device respondsToSelector:@selector(activeVideoMinFrameDuration)]) {
                if ([device lockForConfiguration:&error]) {
                    device.activeVideoMaxFrameDuration = fps;
                    device.activeVideoMinFrameDuration = fps;
                    [device unlockForConfiguration];
                } else {
                    NSLog(@"Failed to set FramePerSeconds into camera device: %@", error.description);
                }
            } else {
                AVCaptureConnection * connection = [self getVideoConnection];
                if (connection.isVideoMaxFrameDurationSupported) {
                    connection.videoMaxFrameDuration = fps;
                } else {
                    NSLog(@"Failed to set FrameRate into camera device");
                }
                if (connection.isVideoMinFrameDurationSupported) {
                    connection.videoMinFrameDuration = fps;
                } else {
                    NSLog(@"Failed to set FrameRate into camera device");
                }
                
            }
        } else {
            NSLog(@"Unsupported frame rate %ld on current device format.", (long)framePerSeconds);
        }
    }
}

- (BOOL)setActiveFormatThatSupportsFrameRate:(CMTimeScale)frameRate width:(int)width andHeight:(int)height error:(NSError *__autoreleasing *)error {
    AVCaptureDevice * device = [self videoDevice];
    CMVideoDimensions dimensions;
    dimensions.width = width;
    dimensions.height = height;
    
    BOOL foundSupported = NO;
    
    if (device != nil) {
        if (device.activeFormat != nil) {
            foundSupported = [self formatInRange:device.activeFormat frameRate:frameRate dimensions:dimensions];
        }
        
        if (!foundSupported) {
            for (AVCaptureDeviceFormat * format in device.formats) {
                if ([self formatInRange:format frameRate:frameRate dimensions:dimensions]) {
                    CMTimeScale oldFrameRate = self.frameRate;
                    if ([device lockForConfiguration:error]) {
                        device.activeFormat = format;
                        [device unlockForConfiguration];
                        foundSupported = YES;
                        self.frameRate = oldFrameRate;
                        break;
                    }
                }
            }
            
            if (!foundSupported && error != nil) {
                *error = [SCRecorder createError:[NSString stringWithFormat:@"No format that supports framerate %d and dimensions %d/%d was found", (int)frameRate, dimensions.width, dimensions.height]];
            }
        }
    } else {
        if (error != nil) {
            *error = [SCRecorder createError:@"The camera must be initialized before setting active format"];
        }
    }
    
    if (foundSupported && error != nil) {
        *error = nil;
    }
    
    return foundSupported;
}

- (AVCaptureVideoDataOutput *)videoOutput {
    return _videoOutput;
}

- (AVCaptureAudioDataOutput *)audioOutput {
    return _audioOutput;
}

- (AVCaptureStillImageOutput *)photoOutput {
    return _photoOutput;
}

@end
