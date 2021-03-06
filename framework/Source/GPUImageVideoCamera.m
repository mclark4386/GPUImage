
#import "GPUImageVideoCamera.h"
#import "GPUImageMovieWriter.h"

#pragma mark -
#pragma mark Private methods and instance variables

@interface GPUImageVideoCamera () 
{
	AVCaptureDeviceInput *videoInput;
	AVCaptureDeviceInput *audioInput;
	AVCaptureVideoDataOutput *videoOutput;
	AVCaptureAudioDataOutput *audioOutput;
    NSDate *startingCaptureTime;
    
    dispatch_queue_t audioProcessingQueue;
}

@end

@implementation GPUImageVideoCamera

@synthesize captureSession = _captureSession;
@synthesize inputCamera = _inputCamera;
@synthesize runBenchmark = _runBenchmark;

#pragma mark -
#pragma mark Initialization and teardown

- (id)init;
{
    if (!(self = [self initWithSessionPreset:AVCaptureSessionPreset640x480 cameraPosition:AVCaptureDevicePositionBack]))
    {
		return nil;
    }
    
    return self;
}

- (id)initWithSessionPreset:(NSString *)sessionPreset cameraPosition:(AVCaptureDevicePosition)cameraPosition; 
{
	if (!(self = [super init]))
    {
		return nil;
    }
    
	audioProcessingQueue = dispatch_queue_create("com.sunsetlakesoftware.GPUImage.processingQueue", NULL);
    
    
    _runBenchmark = NO;
    
    if ([GPUImageOpenGLESContext supportsFastTextureUpload])
    {
        [GPUImageOpenGLESContext useImageProcessingContext];
#if defined(__IPHONE_6_0)
        CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, [[GPUImageOpenGLESContext sharedImageProcessingOpenGLESContext] context], NULL, &coreVideoTextureCache);
#else
        CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, (__bridge void *)[[GPUImageOpenGLESContext sharedImageProcessingOpenGLESContext] context], NULL, &coreVideoTextureCache);
#endif
        if (err)
        {
            NSAssert(NO, @"Error at CVOpenGLESTextureCacheCreated");
        }
        
        // Need to remove the initially created texture
        [self deleteOutputTexture];
    }
    
	// Grab the back-facing or front-facing camera
    _inputCamera = nil;
	NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
	for (AVCaptureDevice *device in devices) 
	{
		if ([device position] == cameraPosition)
		{
			_inputCamera = device;
		}
	}
    
	// Create the capture session
	_captureSession = [[AVCaptureSession alloc] init];
	
    [_captureSession beginConfiguration];
    
	// Add the video input	
	NSError *error = nil;
	videoInput = [[AVCaptureDeviceInput alloc] initWithDevice:_inputCamera error:&error];
	if ([_captureSession canAddInput:videoInput]) 
	{
		[_captureSession addInput:videoInput];
	}
	
	// Add the video frame output	
	videoOutput = [[AVCaptureVideoDataOutput alloc] init];
	[videoOutput setAlwaysDiscardsLateVideoFrames:YES];
    
	[videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    //	dispatch_queue_t videoQueue = dispatch_queue_create("com.sunsetlakesoftware.colortracking.videoqueue", NULL);
    //	[videoOutput setSampleBufferDelegate:self queue:videoQueue];
    
	//[videoOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
	//this should be on the same queue as the audio
    [videoOutput setSampleBufferDelegate:self queue:audioProcessingQueue];
	if ([_captureSession canAddOutput:videoOutput])
	{
		[_captureSession addOutput:videoOutput];
	}
	else
	{
		NSLog(@"Couldn't add video output");
	}
    
    [_captureSession setSessionPreset:sessionPreset];
    
    [_captureSession commitConfiguration];
    
    //    inputTextureSize
    
	return self;
}

- (void)dealloc 
{
    [self stopCameraCapture];
    //    [videoOutput setSampleBufferDelegate:nil queue:dispatch_get_main_queue()];    
    
    [self removeInputsAndOutputs];
    
    if ([GPUImageOpenGLESContext supportsFastTextureUpload])
    {
        CFRelease(coreVideoTextureCache);
    }
    
    if (audioProcessingQueue != NULL)
    {
        dispatch_release(audioProcessingQueue);
    }
}

- (void)removeInputsAndOutputs;
{
    [_captureSession removeInput:videoInput];
    [_captureSession removeOutput:videoOutput];
    if (_microphone != nil)
    {
        [_captureSession removeInput:audioInput];
        [_captureSession removeOutput:audioOutput];
    }
}

#pragma mark -
#pragma mark Manage the camera video stream

- (void)startCameraCapture;
{
    if (![_captureSession isRunning])
	{
        startingCaptureTime = [NSDate date];
		[_captureSession startRunning];
	};
}

- (void)stopCameraCapture;
{
    if ([_captureSession isRunning])
    {
        [_captureSession stopRunning];
    }
}

- (void)rotateCamera
{
    NSError *error;
    AVCaptureDeviceInput *newVideoInput;
    AVCaptureDevicePosition currentCameraPosition = [[videoInput device] position];
    
    if(currentCameraPosition == AVCaptureDevicePositionBack)
    {
        currentCameraPosition = AVCaptureDevicePositionFront;
    }
    else
    {
        currentCameraPosition = AVCaptureDevicePositionBack;
    }
    
    AVCaptureDevice *backFacingCamera = nil;
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
	for (AVCaptureDevice *device in devices) 
	{
		if ([device position] == currentCameraPosition)
		{
			backFacingCamera = device;
		}
	}
    newVideoInput = [[AVCaptureDeviceInput alloc] initWithDevice:backFacingCamera error:&error];
    
    if (newVideoInput != nil)
    {
        [_captureSession beginConfiguration];
        
        [_captureSession removeInput:videoInput];
        if ([_captureSession canAddInput:newVideoInput])
        {
            [_captureSession addInput:newVideoInput];
            videoInput = newVideoInput;
        }
        else
        {
            [_captureSession addInput:videoInput];
        }
        //captureSession.sessionPreset = oriPreset;
        [_captureSession commitConfiguration];
    }
}

- (AVCaptureDevicePosition)getCameraPosition {
    return [[videoInput device] position];
}

- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
{
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    CVImageBufferRef cameraFrame = CMSampleBufferGetImageBuffer(sampleBuffer);
    int bufferWidth = CVPixelBufferGetWidth(cameraFrame);
    int bufferHeight = CVPixelBufferGetHeight(cameraFrame);
    
	CMTime currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    if ([GPUImageOpenGLESContext supportsFastTextureUpload])
    {
        CVPixelBufferLockBaseAddress(cameraFrame, 0);
        
        [GPUImageOpenGLESContext useImageProcessingContext];
        CVOpenGLESTextureRef texture = NULL;
        CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, coreVideoTextureCache, cameraFrame, NULL, GL_TEXTURE_2D, GL_RGBA, bufferWidth, bufferHeight, GL_BGRA, GL_UNSIGNED_BYTE, 0, &texture);
        
        if (!texture || err) {
            NSLog(@"Camera CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err);
            return;
        }
        
//        NSLog(@"Good frame");
        
        outputTexture = CVOpenGLESTextureGetName(texture);
        //        glBindTexture(CVOpenGLESTextureGetTarget(texture), outputTexture);
        glBindTexture(GL_TEXTURE_2D, outputTexture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        for (id<GPUImageInput> currentTarget in targets)
        {
            [currentTarget setInputSize:CGSizeMake(bufferWidth, bufferHeight)];
            
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            [currentTarget setInputTexture:outputTexture atIndex:[[targetTextureIndices objectAtIndex:indexOfObject] integerValue]];
            
            [currentTarget newFrameReadyAtTime:currentTime];
        }
        
        CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
        
        // Flush the CVOpenGLESTexture cache and release the texture
        CVOpenGLESTextureCacheFlush(coreVideoTextureCache, 0);
        CFRelease(texture);
        outputTexture = 0;
        
        if (_runBenchmark)
        {
            CFAbsoluteTime currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime);
            totalFrameTimeDuringCapture += currentFrameTime;
            numberOfFramesCaptured++;
            NSLog(@"Average frame time : %f ms", 1000.0 * (totalFrameTimeDuringCapture / numberOfFramesCaptured));
            NSLog(@"Current frame time : %f ms", 1000.0 * currentFrameTime);
        }
    }
    else
    {
        // Upload to texture
        CVPixelBufferLockBaseAddress(cameraFrame, 0);
        
        glBindTexture(GL_TEXTURE_2D, outputTexture);
        
        //        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, bufferWidth, bufferHeight, 0, GL_BGRA, GL_UNSIGNED_BYTE, CVPixelBufferGetBaseAddress(cameraFrame));
        
        // Using BGRA extension to pull in video frame data directly
        // The use of bytesPerRow / 4 accounts for a display glitch present in preview video frames when using the photo preset on the camera
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(cameraFrame);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, bytesPerRow / 4, bufferHeight, 0, GL_BGRA, GL_UNSIGNED_BYTE, CVPixelBufferGetBaseAddress(cameraFrame));
        
        for (id<GPUImageInput> currentTarget in targets)
        {
            [currentTarget setInputSize:CGSizeMake(bufferWidth, bufferHeight)];
            [currentTarget newFrameReadyAtTime:currentTime];
        }
        
        CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
        
        if (_runBenchmark)
        {
            CFAbsoluteTime currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime);
            totalFrameTimeDuringCapture += currentFrameTime;
            numberOfFramesCaptured++;
            //        NSLog(@"Average frame time : %f ms", 1000.0 * (totalFrameTimeDuringCapture / numberOfFramesCaptured));
            //        NSLog(@"Current frame time : %f ms", 1000.0 * currentFrameTime);
        }
    }  
}

- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;
{
    [self.audioEncodingTarget processAudioBuffer:sampleBuffer]; 
}

#pragma mark -
#pragma mark Benchmarking

- (CGFloat)averageFrameDurationDuringCapture;
{
    NSLog(@"Number of frames: %d", numberOfFramesCaptured);
    return (totalFrameTimeDuringCapture / (CGFloat)numberOfFramesCaptured) * 1000.0;
}

#pragma mark -
#pragma mark AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
	//This may help keep memory footprint low
	@autoreleasepool 
	{
		//these need to be on the main thread for proper timing
		if (captureOutput == audioOutput)
		{
			runOnMainQueueWithoutDeadlocking(^{ 
                [self processAudioSampleBuffer:sampleBuffer]; 
            });
		}
		else
		{
			runOnMainQueueWithoutDeadlocking(^{ 
                [self processVideoSampleBuffer:sampleBuffer]; 
            });
		}
	}
}

#pragma mark -
#pragma mark Accessors

- (void)setAudioEncodingTarget:(GPUImageMovieWriter *)newValue;
{    
    [_captureSession beginConfiguration];
    
    _microphone = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    audioInput = [AVCaptureDeviceInput deviceInputWithDevice:_microphone error:nil];
    if ([_captureSession canAddInput:audioInput]) 
    {
        [_captureSession addInput:audioInput];
    }
    audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    
    audioProcessingQueue = dispatch_queue_create("com.sunsetlakesoftware.GPUImage.audioProcessingQueue", NULL);
    
    //    [audioOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    if ([_captureSession canAddOutput:audioOutput])
    {
        [_captureSession addOutput:audioOutput];
    }
    else
    {
        NSLog(@"Couldn't add audio output");
    }
    [audioOutput setSampleBufferDelegate:self queue:audioProcessingQueue];
    
    [_captureSession commitConfiguration];
    
    [super setAudioEncodingTarget:newValue];
}

@end
