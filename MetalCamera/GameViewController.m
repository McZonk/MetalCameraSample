

#import "GameViewController.h"

@import Metal;
@import simd;
@import QuartzCore.CAMetalLayer;
@import AVFoundation;
#import <CoreVideoPlus/CoreVideoPlus.h>

// The max number of command buffers in flight
static const NSUInteger g_max_inflight_buffers = 3;


float cubeVertexData[16] =
{
	-1.0, -1.0,  0.0, 1.0,
	 1.0, -1.0,  1.0, 1.0,
	-1.0,  1.0,  0.0, 0.0,
	 1.0,  1.0,  1.0, 0.0,
};

typedef struct {
	matrix_float3x3 matrix;
	vector_float3 offset;
} ColorConversion;


@interface GameViewController () <AVCaptureVideoDataOutputSampleBufferDelegate>

@end


@implementation GameViewController
{
    // layer
    CAMetalLayer *_metalLayer;
    id <CAMetalDrawable> _currentDrawable;
    BOOL _layerSizeDidUpdate;
    MTLRenderPassDescriptor *_renderPassDescriptor;
    
    // controller
    CADisplayLink *_timer;
    BOOL _gameLoopPaused;
    dispatch_semaphore_t _inflight_semaphore;
	
    // renderer
    id <MTLDevice> _device;
    id <MTLCommandQueue> _commandQueue;
    id <MTLLibrary> _defaultLibrary;
    id <MTLRenderPipelineState> _pipelineState;
    id <MTLBuffer> _vertexBuffer;
    id <MTLDepthStencilState> _depthState;
	id <MTLTexture> _textureY;
	id <MTLTexture> _textureCbCr;
	id <MTLBuffer> _colorConversionBuffer;
	
	AVCaptureDevice *_captureDevice;
	AVCaptureSession *_captureSession;
	dispatch_queue_t _captureQueue;
	
	id<CVPMetalTextureCache> _textureCache;
}

- (void)dealloc
{
    [_timer invalidate];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    _inflight_semaphore = dispatch_semaphore_create(g_max_inflight_buffers);
    
    [self _setupMetal];
	[self _setupCapture];
    [self _loadAssets];
    
    _timer = [CADisplayLink displayLinkWithTarget:self selector:@selector(_gameloop)];
    [_timer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)_setupMetal
{
    // Find a usable device
    _device = MTLCreateSystemDefaultDevice();
    
    // Create a new command queue
    _commandQueue = [_device newCommandQueue];
    
    // Load all the shader files with a metal file extension in the project
    _defaultLibrary = [_device newDefaultLibrary];
    
    // Setup metal layer and add as sub layer to view
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    
    // Change this to NO if the compute encoder is used as the last pass on the drawable texture
    _metalLayer.framebufferOnly = YES;
    
    // Add metal layer to the views layer hierarchy
    [_metalLayer setFrame:self.view.layer.frame];
    [self.view.layer addSublayer:_metalLayer];
    
    self.view.opaque = YES;
    self.view.backgroundColor = nil;
    self.view.contentScaleFactor = [UIScreen mainScreen].scale;
}

- (void)_setupCapture
{
	_textureCache = [(id<CVPMetalDevice>)_device newTextureCacheWithAttributes:nil textureAttributes:nil error:nil];
	
	ColorConversion colorConversion = {
		.matrix = {
			.columns[0] = { 1.164,  1.164, 1.164, },
			.columns[1] = { 0.000, -0.392, 2.017, },
			.columns[2] = { 1.596, -0.813, 0.000, },
		},
		.offset = { -(16.0/255.0), -0.5, -0.5 },
	};
	
	_colorConversionBuffer = [_device newBufferWithBytes:&colorConversion length:sizeof(colorConversion) options:MTLResourceOptionCPUCacheModeDefault];

	_captureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	if(_captureDevice != nil)
	{
		_captureSession = [[AVCaptureSession alloc] init];
		
		AVCaptureInput *input = [[AVCaptureDeviceInput alloc] initWithDevice:_captureDevice error:nil];
		[_captureSession addInput:input];
		
		_captureQueue = dispatch_queue_create("captureQueue", DISPATCH_QUEUE_SERIAL);
		
		AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];
		videoOutput.videoSettings = @{
			(NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
		};
		[videoOutput setSampleBufferDelegate:self queue:_captureQueue];
		[_captureSession addOutput:videoOutput];

		[_captureSession startRunning];
	}
}

- (void)_loadAssets
{
    // Load the fragment program into the library
    id <MTLFunction> fragmentProgram = [_defaultLibrary newFunctionWithName:@"fragmentColorConversion"];
    
    // Load the vertex program into the library
    id <MTLFunction> vertexProgram = [_defaultLibrary newFunctionWithName:@"vertexPassthrough"];
    
    // Setup the vertex buffers
    _vertexBuffer = [_device newBufferWithBytes:cubeVertexData length:sizeof(cubeVertexData) options:MTLResourceOptionCPUCacheModeDefault];
    _vertexBuffer.label = @"Vertices";
    
    // Create a reusable pipeline state
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.label = @"MyPipeline";
    [pipelineStateDescriptor setSampleCount: 1];
    [pipelineStateDescriptor setVertexFunction:vertexProgram];
    [pipelineStateDescriptor setFragmentFunction:fragmentProgram];
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineStateDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    
    NSError* error = NULL;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
    if (!_pipelineState) {
        NSLog(@"Failed to created pipeline state, error %@", error);
    }
    
    MTLDepthStencilDescriptor *depthStateDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionAlways;
    depthStateDesc.depthWriteEnabled = NO;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];
}

- (void)setupRenderPassDescriptorForTexture:(id <MTLTexture>) texture
{
    if (_renderPassDescriptor == nil)
        _renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    
    _renderPassDescriptor.colorAttachments[0].texture = texture;
    _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    _renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.65f, 0.65f, 0.65f, 1.0f);
    _renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
}

- (void)_render
{
    dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
    
    [self _update];
    
    // Create a new command buffer for each renderpass to the current drawable
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"MyCommand";
    
    // obtain a drawable texture for this render pass and set up the renderpass descriptor for the command encoder to render into
    id <CAMetalDrawable> drawable = [self currentDrawable];
    [self setupRenderPassDescriptorForTexture:drawable.texture];
    
    // Create a render command encoder so we can render into something
    id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
    renderEncoder.label = @"MyRenderEncoder";
    [renderEncoder setDepthStencilState:_depthState];
    
    // Set context state
	if(_textureY != nil && _textureCbCr != nil)
	{
		[renderEncoder pushDebugGroup:@"DrawCube"];
		[renderEncoder setRenderPipelineState:_pipelineState];
		[renderEncoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
		[renderEncoder setFragmentTexture:_textureY atIndex:0];
		[renderEncoder setFragmentTexture:_textureCbCr atIndex:1];
		[renderEncoder setFragmentBuffer:_colorConversionBuffer offset:0 atIndex:0];
		
		// Tell the render context we want to draw our primitives
		[renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:1];
		[renderEncoder popDebugGroup];
	}
	
    // We're done encoding commands
    [renderEncoder endEncoding];
    
    // Call the view's completion handler which is required by the view since it will signal its semaphore and set up the next buffer
    __block dispatch_semaphore_t block_sema = _inflight_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        dispatch_semaphore_signal(block_sema);
    }];
	
    // Schedule a present once the framebuffer is complete
    [commandBuffer presentDrawable:drawable];
    
    // Finalize rendering here & push the command buffer to the GPU
    [commandBuffer commit];
}

- (void)_reshape
{
}

- (void)_update
{
}

// The main game loop called by the CADisplayLine timer
- (void)_gameloop
{
    @autoreleasepool {
        if (_layerSizeDidUpdate)
        {
            CGSize drawableSize = self.view.bounds.size;
            drawableSize.width *= self.view.contentScaleFactor;
            drawableSize.height *= self.view.contentScaleFactor;
            _metalLayer.drawableSize = drawableSize;
            
            [self _reshape];
            _layerSizeDidUpdate = NO;
        }
        
        // draw
        [self _render];
        
        _currentDrawable = nil;
    }
}

// Called whenever view changes orientation or layout is changed
- (void)viewDidLayoutSubviews
{
    _layerSizeDidUpdate = YES;
    [_metalLayer setFrame:self.view.layer.frame];
}

#pragma mark Utilities

- (id <CAMetalDrawable>)currentDrawable
{
    while (_currentDrawable == nil)
    {
        _currentDrawable = [_metalLayer nextDrawable];
        if (!_currentDrawable)
        {
            NSLog(@"CurrentDrawable is nil");
        }
    }
    
    return _currentDrawable;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
	CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
	
	id<MTLTexture> textureY = [_textureCache textureWithImageBuffer:pixelBuffer planeIndex:0 error:nil];
	id<MTLTexture> textureCbCr = [_textureCache textureWithImageBuffer:pixelBuffer planeIndex:1 error:nil];
	
	if(textureY != nil && textureCbCr != nil)
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			// always assign the textures atomic
			_textureY = textureY;
			_textureCbCr = textureCbCr;
		});
	}
}

@end
