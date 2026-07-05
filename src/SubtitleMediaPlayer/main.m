#import <Cocoa/Cocoa.h>
#import <OpenGL/gl3.h>
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

static const double SMPMaxVolume = 125.0;
static const double SMPResumeMinimumPosition = 5.0;
static const double SMPResumeEndThreshold = 10.0;
static const double SMPPlaybackPositionSaveInterval = 5.0;

static BOOL SMPIsVideoURL(NSURL *url) {
    if (!url.isFileURL) { return NO; }
    NSString *ext = url.pathExtension.lowercaseString;
    return [@[@"mp4", @"mkv", @"mov", @"ts"] containsObject:ext];
}

static void *SMPGetOpenGLProcAddress(void *ctx, const char *name) {
    (void)ctx;
    CFStringRef symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
    void *address = CFBundleGetFunctionPointerForName(CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl")), symbol);
    CFRelease(symbol);
    return address;
}

@protocol SMPVideoDropDelegate <NSObject>
- (void)openVideoAtURL:(NSURL *)url;
@end

@interface SMPMPVView : NSOpenGLView <NSDraggingDestination>
@property (nonatomic, weak) id<SMPVideoDropDelegate> dropDelegate;
@property (nonatomic, assign) mpv_handle *mpv;
@property (nonatomic, assign) mpv_render_context *renderContext;
- (void)attachMPV:(mpv_handle *)mpv;
@end

@implementation SMPMPVView

static void SMPMPVRenderUpdate(void *ctx) {
    SMPMPVView *view = (__bridge SMPMPVView *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view setNeedsDisplay:YES];
    });
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
        NSOpenGLPFAColorSize, 24,
        NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAAccelerated,
        0
    };
    NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    self = [super initWithFrame:frameRect pixelFormat:format];
    if (self) {
        self.wantsBestResolutionOpenGLSurface = YES;
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (BOOL)isOpaque {
    return YES;
}

- (void)prepareOpenGL {
    [super prepareOpenGL];
    GLint swapInterval = 1;
    [self.openGLContext setValues:&swapInterval forParameter:NSOpenGLContextParameterSwapInterval];
    if (self.mpv && !self.renderContext) {
        [self createRenderContext];
    }
}

- (void)attachMPV:(mpv_handle *)mpv {
    self.mpv = mpv;
    if (self.openGLContext && !self.renderContext) {
        [self createRenderContext];
    }
}

- (void)createRenderContext {
    [self.openGLContext makeCurrentContext];
    mpv_opengl_init_params glInit = {
        .get_proc_address = SMPGetOpenGLProcAddress,
        .get_proc_address_ctx = NULL
    };
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &glInit },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    if (mpv_render_context_create(&_renderContext, self.mpv, params) < 0) {
        NSLog(@"SubtitleMediaPlayer: failed to create mpv render context");
        return;
    }
    mpv_render_context_set_update_callback(self.renderContext, SMPMPVRenderUpdate, (__bridge void *)self);
}

- (void)reshape {
    [super reshape];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [self.openGLContext makeCurrentContext];

    NSSize backingSize = [self convertSizeToBacking:self.bounds.size];
    GLint fboID = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fboID);

    if (!self.renderContext) {
        glViewport(0, 0, (GLsizei)backingSize.width, (GLsizei)backingSize.height);
        glClearColor(0.02, 0.02, 0.02, 1.0);
        glClear(GL_COLOR_BUFFER_BIT);
        [self.openGLContext flushBuffer];
        return;
    }

    mpv_opengl_fbo fbo = {
        .fbo = (int)fboID,
        .w = (int)backingSize.width,
        .h = (int)backingSize.height,
        .internal_format = 0
    };
    int flipY = 1;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flipY },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    mpv_render_context_render(self.renderContext, params);
    [self.openGLContext flushBuffer];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSArray<NSURL *> *urls = [sender.draggingPasteboard readObjectsForClasses:@[[NSURL class]]
                                                                       options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *url in urls) {
        if (SMPIsVideoURL(url)) { return NSDragOperationCopy; }
    }
    return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray<NSURL *> *urls = [sender.draggingPasteboard readObjectsForClasses:@[[NSURL class]]
                                                                       options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *url in urls) {
        if (SMPIsVideoURL(url)) {
            [self.dropDelegate openVideoAtURL:url];
            return YES;
        }
    }
    return NO;
}

- (void)dealloc {
    if (_renderContext) {
        mpv_render_context_free(_renderContext);
        _renderContext = NULL;
    }
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, SMPVideoDropDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) SMPMPVView *videoView;
@property (nonatomic, strong) NSButton *playButton;
@property (nonatomic, strong) NSSlider *progressSlider;
@property (nonatomic, strong) NSSlider *volumeSlider;
@property (nonatomic, strong) NSPopUpButton *speedPopup;
@property (nonatomic, strong) NSButton *subtitleButton;
@property (nonatomic, strong) NSButton *manualSubtitleButton;
@property (nonatomic, strong) NSButton *autoSubtitleButton;
@property (nonatomic, strong) NSTextField *timeLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTimer *redrawTimer;
@property (nonatomic, strong) id keyEventMonitor;
@property (nonatomic, assign) mpv_handle *mpv;
@property (nonatomic, strong) dispatch_queue_t eventQueue;
@property (nonatomic, strong) dispatch_queue_t subtitleQueue;
@property (nonatomic, assign) BOOL stopping;
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, assign) BOOL updatingSlider;
@property (nonatomic, assign) BOOL subtitleVisible;
@property (nonatomic, assign) BOOL subtitleGenerating;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) double position;
@property (nonatomic, assign) double pendingResumePosition;
@property (nonatomic, assign) BOOL hasPendingResumePosition;
@property (nonatomic, assign) double lastPlaybackPositionSaveTime;
@property (nonatomic, copy) NSString *currentVideoPath;
@property (nonatomic, copy) NSString *currentSubtitlePath;
@property (nonatomic, copy) NSString *pendingOpenPath;
@property (nonatomic, strong) NSURL *pendingOpenURL;
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *folderBookmarks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSURL *> *activeFolderAccessURLs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSURL *> *activeFileAccessURLs;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.defaults = [NSUserDefaults standardUserDefaults];
    self.eventQueue = dispatch_queue_create("com.subtitlemediaplayer.local.mpv-events", DISPATCH_QUEUE_SERIAL);
    self.subtitleQueue = dispatch_queue_create("com.subtitlemediaplayer.local.subtitles", DISPATCH_QUEUE_SERIAL);
    [self registerDefaultSettings];
    [self buildMenu];
    [self buildWindow];
    [self installKeyboardShortcuts];
    [self setupMPV];
    [self startRedrawTimer];
    [self openInitialArgumentIfNeeded];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)startRedrawTimer {
    self.redrawTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                        target:self
                                                      selector:@selector(redrawTick:)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)redrawTick:(NSTimer *)timer {
    (void)timer;
    if (self.currentVideoPath.length && self.videoView.renderContext) {
        [self.videoView setNeedsDisplay:YES];
    }
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    (void)app;
    return YES;
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    (void)application;
    BOOL useCurrentWindow = !self.currentVideoPath.length && !self.pendingOpenPath.length;
    for (NSURL *url in urls) {
        if (SMPIsVideoURL(url)) {
            if (useCurrentWindow) {
                [self openVideoAtURL:url];
                useCurrentWindow = NO;
            } else {
                [self rememberDirectoryAccessForFileURL:url];
                [self launchNewInstanceForVideoURL:url];
            }
        }
    }
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    (void)sender;
    NSURL *url = [NSURL fileURLWithPath:filename];
    if (SMPIsVideoURL(url)) {
        [self openVideoAtURL:url];
        return YES;
    }
    return NO;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    BOOL opened = NO;
    BOOL useCurrentWindow = !self.currentVideoPath.length && !self.pendingOpenPath.length;
    for (NSString *filename in filenames) {
        NSURL *url = [NSURL fileURLWithPath:filename];
        if (SMPIsVideoURL(url)) {
            if (useCurrentWindow) {
                [self openVideoAtURL:url];
                useCurrentWindow = NO;
            } else {
                [self rememberDirectoryAccessForFileURL:url];
                [self launchNewInstanceForVideoURL:url];
            }
            opened = YES;
        }
    }
    [sender replyToOpenOrPrint:opened ? NSApplicationDelegateReplySuccess : NSApplicationDelegateReplyFailure];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    self.stopping = YES;
    [self saveCurrentPlaybackPositionIfNeeded];
    [self.defaults synchronize];
    if (self.keyEventMonitor) {
        [NSEvent removeMonitor:self.keyEventMonitor];
        self.keyEventMonitor = nil;
    }
    for (NSURL *url in self.activeFolderAccessURLs.allValues) {
        [url stopAccessingSecurityScopedResource];
    }
    for (NSURL *url in self.activeFileAccessURLs.allValues) {
        [url stopAccessingSecurityScopedResource];
    }
    [self.activeFolderAccessURLs removeAllObjects];
    [self.activeFileAccessURLs removeAllObjects];
    if (self.mpv) {
        const char *cmd[] = { "quit", NULL };
        mpv_command_async(self.mpv, 0, cmd);
        mpv_wakeup(self.mpv);
    }
}

- (void)registerDefaultSettings {
    [self.defaults registerDefaults:@{
        @"volume": @80.0,
        @"speed": @1.0,
        @"subtitlesEnabled": @NO
    }];
    self.subtitleVisible = [self.defaults boolForKey:@"subtitlesEnabled"];
    self.folderBookmarks = NSMutableDictionary.dictionary;
    NSDictionary<NSString *, NSData *> *fileBookmarks = [NSDictionary dictionaryWithContentsOfFile:[self folderBookmarksPath]];
    if (fileBookmarks) {
        [self.folderBookmarks addEntriesFromDictionary:fileBookmarks];
    }
    NSDictionary<NSString *, NSData *> *savedBookmarks = [self.defaults dictionaryForKey:@"folderBookmarks"];
    if (savedBookmarks) {
        [self.folderBookmarks addEntriesFromDictionary:savedBookmarks];
    }
    self.activeFolderAccessURLs = NSMutableDictionary.dictionary;
    self.activeFileAccessURLs = NSMutableDictionary.dictionary;
}

- (void)installKeyboardShortcuts {
    __weak AppDelegate *weakSelf = self;
    self.keyEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                                 handler:^NSEvent *(NSEvent *event) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf || event.window != strongSelf.window) {
            return event;
        }
        return [strongSelf handleKeyboardShortcut:event] ? nil : event;
    }];
}

- (BOOL)handleKeyboardShortcut:(NSEvent *)event {
    NSEventModifierFlags blockedModifiers = NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl;
    if ((event.modifierFlags & blockedModifiers) != 0) {
        return NO;
    }

    switch (event.keyCode) {
        case 49:
            [self togglePlay:nil];
            return YES;
        case 123:
            [self seekRelative:-15.0];
            return YES;
        case 124:
            [self seekRelative:15.0];
            return YES;
        default:
            return NO;
    }
}

- (void)buildMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"SubtitleMediaPlayer"];
    [appMenu addItemWithTitle:@"退出 SubtitleMediaPlayer" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"文件" action:nil keyEquivalent:@""];
    [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"文件"];
    [fileMenu addItemWithTitle:@"打开视频..." action:@selector(openVideoPanel:) keyEquivalent:@"o"].target = self;
    [fileMenu addItemWithTitle:@"选择字幕..." action:@selector(openSubtitlePanel:) keyEquivalent:@"s"].target = self;
    fileItem.submenu = fileMenu;
    NSApp.mainMenu = mainMenu;
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 960, 600);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled |
                                                         NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable |
                                                         NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"SubtitleMediaPlayer";
    self.window.minSize = NSMakeSize(720, 420);
    self.window.delegate = self;
    self.window.backgroundColor = NSColor.blackColor;
    [self.window center];

    NSView *content = self.window.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = NSColor.blackColor.CGColor;
    self.paused = YES;

    self.videoView = [[SMPMPVView alloc] initWithFrame:NSZeroRect];
    self.videoView.dropDelegate = self;
    self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.videoView];

    NSView *controls = [[NSView alloc] initWithFrame:NSZeroRect];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.wantsLayer = YES;
    controls.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.09 alpha:1.0].CGColor;
    [content addSubview:controls];

    self.progressSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.progressSlider.minValue = 0;
    self.progressSlider.maxValue = 1;
    self.progressSlider.target = self;
    self.progressSlider.action = @selector(progressChanged:);
    self.progressSlider.continuous = YES;
    self.progressSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [controls addSubview:self.progressSlider];

    self.playButton = [NSButton buttonWithTitle:@"播放" target:self action:@selector(togglePlay:)];
    self.playButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.playButton.translatesAutoresizingMaskIntoConstraints = NO;
    [controls addSubview:self.playButton];

    self.speedPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSNumber *speed in @[@0.75, @1.0, @1.25, @1.5, @2.0, @3.0]) {
        NSString *title = [NSString stringWithFormat:@"%@x", speed.stringValue];
        [self.speedPopup addItemWithTitle:title];
        self.speedPopup.lastItem.representedObject = speed;
    }
    self.speedPopup.target = self;
    self.speedPopup.action = @selector(speedChanged:);
    self.speedPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [controls addSubview:self.speedPopup];

    self.volumeSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.volumeSlider.minValue = 0;
    self.volumeSlider.maxValue = SMPMaxVolume;
    self.volumeSlider.doubleValue = MIN(MAX([self.defaults doubleForKey:@"volume"], 0.0), SMPMaxVolume);
    self.volumeSlider.toolTip = @"音量：VLC 风格最高 125%";
    self.volumeSlider.target = self;
    self.volumeSlider.action = @selector(volumeChanged:);
    self.volumeSlider.continuous = YES;
    self.volumeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [controls addSubview:self.volumeSlider];

    self.subtitleButton = [NSButton buttonWithTitle:@"字幕" target:self action:@selector(toggleSubtitle:)];
    self.subtitleButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.subtitleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [controls addSubview:self.subtitleButton];

    self.manualSubtitleButton = [NSButton buttonWithTitle:@"SRT" target:self action:@selector(openSubtitlePanel:)];
    self.manualSubtitleButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.manualSubtitleButton.toolTip = @"选择字幕文件";
    self.manualSubtitleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [controls addSubview:self.manualSubtitleButton];

    self.autoSubtitleButton = [NSButton buttonWithTitle:@"自动识别字幕" target:self action:@selector(generateSubtitle:)];
    self.autoSubtitleButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.autoSubtitleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [controls addSubview:self.autoSubtitleButton];

    self.timeLabel = [self labelWithText:@"00:00 / 00:00"];
    [controls addSubview:self.timeLabel];

    self.statusLabel = [self labelWithText:@"拖入视频开始播放"];
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [controls addSubview:self.statusLabel];

    NSDictionary *views = @{@"video": self.videoView, @"controls": controls};
    [content addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[video]|" options:0 metrics:nil views:views]];
    [content addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[controls]|" options:0 metrics:nil views:views]];
    [content addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[video][controls(72)]|" options:0 metrics:nil views:views]];

    [NSLayoutConstraint activateConstraints:@[
        [self.progressSlider.leadingAnchor constraintEqualToAnchor:controls.leadingAnchor constant:14],
        [self.progressSlider.trailingAnchor constraintEqualToAnchor:controls.trailingAnchor constant:-14],
        [self.progressSlider.topAnchor constraintEqualToAnchor:controls.topAnchor constant:8],

        [self.playButton.leadingAnchor constraintEqualToAnchor:controls.leadingAnchor constant:14],
        [self.playButton.topAnchor constraintEqualToAnchor:self.progressSlider.bottomAnchor constant:10],
        [self.playButton.widthAnchor constraintEqualToConstant:64],

        [self.speedPopup.leadingAnchor constraintEqualToAnchor:self.playButton.trailingAnchor constant:10],
        [self.speedPopup.centerYAnchor constraintEqualToAnchor:self.playButton.centerYAnchor],
        [self.speedPopup.widthAnchor constraintEqualToConstant:86],

        [self.volumeSlider.leadingAnchor constraintEqualToAnchor:self.speedPopup.trailingAnchor constant:10],
        [self.volumeSlider.centerYAnchor constraintEqualToAnchor:self.playButton.centerYAnchor],
        [self.volumeSlider.widthAnchor constraintEqualToConstant:120],

        [self.subtitleButton.leadingAnchor constraintEqualToAnchor:self.volumeSlider.trailingAnchor constant:10],
        [self.subtitleButton.centerYAnchor constraintEqualToAnchor:self.playButton.centerYAnchor],
        [self.subtitleButton.widthAnchor constraintEqualToConstant:66],

        [self.manualSubtitleButton.leadingAnchor constraintEqualToAnchor:self.subtitleButton.trailingAnchor constant:8],
        [self.manualSubtitleButton.centerYAnchor constraintEqualToAnchor:self.playButton.centerYAnchor],
        [self.manualSubtitleButton.widthAnchor constraintEqualToConstant:54],

        [self.autoSubtitleButton.leadingAnchor constraintEqualToAnchor:self.manualSubtitleButton.trailingAnchor constant:8],
        [self.autoSubtitleButton.centerYAnchor constraintEqualToAnchor:self.playButton.centerYAnchor],
        [self.autoSubtitleButton.widthAnchor constraintEqualToConstant:132],

        [self.timeLabel.leadingAnchor constraintEqualToAnchor:self.autoSubtitleButton.trailingAnchor constant:12],
        [self.timeLabel.centerYAnchor constraintEqualToAnchor:self.playButton.centerYAnchor],
        [self.timeLabel.widthAnchor constraintEqualToConstant:116],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.timeLabel.trailingAnchor constant:10],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:controls.trailingAnchor constant:-14],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.playButton.centerYAnchor]
    ]];

    double savedSpeed = [self.defaults doubleForKey:@"speed"];
    [self selectSpeed:savedSpeed];
    [self refreshSubtitleButton];
}

- (NSTextField *)labelWithText:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.textColor = [NSColor colorWithCalibratedWhite:0.82 alpha:1.0];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)setupMPV {
    self.mpv = mpv_create();
    if (!self.mpv) {
        self.statusLabel.stringValue = @"mpv 初始化失败";
        return;
    }

    mpv_set_option_string(self.mpv, "terminal", "no");
    mpv_set_option_string(self.mpv, "osc", "no");
    mpv_set_option_string(self.mpv, "input-default-bindings", "no");
    mpv_set_option_string(self.mpv, "sub-auto", "no");
    mpv_set_option_string(self.mpv, "keep-open", "yes");
    mpv_set_option_string(self.mpv, "hwdec", "auto-safe");
    mpv_set_option_string(self.mpv, "vo", "libmpv");
    mpv_set_option_string(self.mpv, "volume-max", "125");

    if (mpv_initialize(self.mpv) < 0) {
        self.statusLabel.stringValue = @"mpv 初始化失败";
        return;
    }

    double volume = self.volumeSlider.doubleValue;
    double speed = [self.defaults doubleForKey:@"speed"];
    int subVisible = self.subtitleVisible ? 1 : 0;
    mpv_set_property(self.mpv, "volume", MPV_FORMAT_DOUBLE, &volume);
    mpv_set_property(self.mpv, "speed", MPV_FORMAT_DOUBLE, &speed);
    mpv_set_property(self.mpv, "sub-visibility", MPV_FORMAT_FLAG, &subVisible);

    mpv_observe_property(self.mpv, 0, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(self.mpv, 0, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(self.mpv, 0, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(self.mpv, 0, "volume", MPV_FORMAT_DOUBLE);
    mpv_observe_property(self.mpv, 0, "speed", MPV_FORMAT_DOUBLE);
    mpv_observe_property(self.mpv, 0, "sub-visibility", MPV_FORMAT_FLAG);

    [self.videoView attachMPV:self.mpv];
    [self startEventLoop];

    if (self.pendingOpenURL) {
        NSURL *url = self.pendingOpenURL;
        self.pendingOpenURL = nil;
        self.pendingOpenPath = nil;
        [self openVideoAtURL:url];
    } else if (self.pendingOpenPath.length) {
        NSString *path = self.pendingOpenPath.copy;
        self.pendingOpenPath = nil;
        [self openVideoAtPath:path];
    }
}

- (void)openInitialArgumentIfNeeded {
    if (self.currentVideoPath.length) { return; }
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    for (NSUInteger i = 1; i < arguments.count; i++) {
        NSString *arg = arguments[i];
        NSURL *url = [NSURL fileURLWithPath:arg];
        if (SMPIsVideoURL(url)) {
            [self rememberDirectoryAccessForFileURL:url];
        }
        if (SMPIsVideoURL(url) && [[NSFileManager defaultManager] fileExistsAtPath:arg]) {
            [self openVideoAtURL:url];
            return;
        }
    }
}

- (void)startEventLoop {
    __weak AppDelegate *weakSelf = self;
    dispatch_async(self.eventQueue, ^{
        AppDelegate *strongSelf = weakSelf;
        while (strongSelf && !strongSelf.stopping) {
            mpv_event *event = mpv_wait_event(strongSelf.mpv, 1.0);
            if (event->event_id == MPV_EVENT_NONE) {
                continue;
            }
            [strongSelf handleMPVEvent:event];
            strongSelf = weakSelf;
        }
    });
}

- (void)handleMPVEvent:(mpv_event *)event {
    if (event->event_id == MPV_EVENT_PROPERTY_CHANGE) {
        mpv_event_property *prop = (mpv_event_property *)event->data;
        NSString *name = [NSString stringWithUTF8String:prop->name ?: ""];
        if (prop->format == MPV_FORMAT_DOUBLE && prop->data) {
            double value = *(double *)prop->data;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateDoubleProperty:name value:value];
            });
        } else if (prop->format == MPV_FORMAT_FLAG && prop->data) {
            BOOL flag = (*(int *)prop->data) != 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateFlagProperty:name value:flag];
            });
        }
    } else if (event->event_id == MPV_EVENT_FILE_LOADED) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.paused = NO;
            [self refreshPlayButton];
            [self.videoView setNeedsDisplay:YES];
            self.statusLabel.stringValue = self.currentVideoPath.lastPathComponent ?: @"播放中";
            [self applyPendingResumePositionIfNeeded];
            if (self.subtitleVisible) {
                [self loadSidecarSubtitleIfAvailable];
            }
        });
    } else if (event->event_id == MPV_EVENT_END_FILE) {
        mpv_event_end_file *endFile = (mpv_event_end_file *)event->data;
        BOOL reachedEOF = endFile && endFile->reason == MPV_END_FILE_REASON_EOF;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (reachedEOF) {
                [self clearSavedPlaybackPositionForPath:self.currentVideoPath];
            } else {
                [self saveCurrentPlaybackPositionIfNeeded];
            }
            [self refreshPlayButton];
        });
    } else if (event->event_id == MPV_EVENT_SHUTDOWN) {
        self.stopping = YES;
    }
}

- (void)updateDoubleProperty:(NSString *)name value:(double)value {
    if ([name isEqualToString:@"time-pos"]) {
        self.position = value;
        [self refreshTimeUI];
        [self saveCurrentPlaybackPositionThrottled];
    } else if ([name isEqualToString:@"duration"]) {
        self.duration = value;
        self.progressSlider.maxValue = MAX(value, 1.0);
        [self refreshTimeUI];
    } else if ([name isEqualToString:@"volume"]) {
        double clampedValue = MIN(MAX(value, 0.0), SMPMaxVolume);
        if (fabs(self.volumeSlider.doubleValue - clampedValue) > 0.5) {
            self.volumeSlider.doubleValue = clampedValue;
        }
    } else if ([name isEqualToString:@"speed"]) {
        [self selectSpeed:value];
    }
}

- (void)updateFlagProperty:(NSString *)name value:(BOOL)value {
    if ([name isEqualToString:@"pause"]) {
        self.paused = value;
        if (value) {
            [self saveCurrentPlaybackPositionIfNeeded];
        }
        [self refreshPlayButton];
    } else if ([name isEqualToString:@"sub-visibility"]) {
        self.subtitleVisible = value;
        [self.defaults setBool:value forKey:@"subtitlesEnabled"];
        [self refreshSubtitleButton];
    }
}

- (NSString *)bookmarkKeyForDirectoryPath:(NSString *)path {
    if (!path.length) { return nil; }
    return path.stringByStandardizingPath;
}

- (NSString *)directoryPathForFilePath:(NSString *)path {
    if (!path.length) { return nil; }
    return [self bookmarkKeyForDirectoryPath:path.stringByDeletingLastPathComponent];
}

- (NSString *)folderBookmarksPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSURL *supportURL = [fm URLForDirectory:NSApplicationSupportDirectory
                                   inDomain:NSUserDomainMask
                          appropriateForURL:nil
                                     create:YES
                                      error:&error];
    if (!supportURL) {
        NSLog(@"SubtitleMediaPlayer: failed to locate Application Support: %@", error.localizedDescription);
        return nil;
    }
    NSString *appSupport = [supportURL.path stringByAppendingPathComponent:@"SubtitleMediaPlayer"];
    NSError *createError = nil;
    if (![fm createDirectoryAtPath:appSupport withIntermediateDirectories:YES attributes:nil error:&createError]) {
        NSLog(@"SubtitleMediaPlayer: failed to create Application Support directory: %@", createError.localizedDescription);
        return nil;
    }
    return [appSupport stringByAppendingPathComponent:@"FolderBookmarks.plist"];
}

- (void)persistFolderBookmarks {
    [self.defaults setObject:self.folderBookmarks forKey:@"folderBookmarks"];
    [self.defaults synchronize];

    NSString *path = [self folderBookmarksPath];
    if (!path.length) { return; }

    NSError *plistError = nil;
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:self.folderBookmarks
                                                                    format:NSPropertyListBinaryFormat_v1_0
                                                                   options:0
                                                                     error:&plistError];
    if (!plistData) {
        NSLog(@"SubtitleMediaPlayer: failed to encode folder bookmarks: %@", plistError.localizedDescription);
        return;
    }

    NSError *writeError = nil;
    if (![plistData writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        NSLog(@"SubtitleMediaPlayer: failed to persist folder bookmarks at %@: %@", path, writeError.localizedDescription);
    }
}

- (void)rememberDirectoryAccessForFileURL:(NSURL *)fileURL {
    if (!fileURL.isFileURL) { return; }
    NSString *fileKey = fileURL.path.stringByStandardizingPath;
    if (fileKey.length && !self.activeFileAccessURLs[fileKey]) {
        [fileURL startAccessingSecurityScopedResource];
        self.activeFileAccessURLs[fileKey] = fileURL;
    }

    NSURL *directoryURL = [fileURL URLByDeletingLastPathComponent];
    NSString *key = [self bookmarkKeyForDirectoryPath:directoryURL.path];
    if (!key.length || self.folderBookmarks[key]) {
        [self startAccessForDirectoryPath:key];
        return;
    }

    NSError *error = nil;
    NSData *bookmark = [directoryURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                              includingResourceValuesForKeys:nil
                                               relativeToURL:nil
                                                       error:&error];
    if (!bookmark) {
        bookmark = [directoryURL bookmarkDataWithOptions:0
                          includingResourceValuesForKeys:nil
                                           relativeToURL:nil
                                                   error:&error];
    }
    if (!bookmark) {
        NSLog(@"SubtitleMediaPlayer: failed to save folder bookmark for %@: %@", key, error.localizedDescription);
        return;
    }

    self.folderBookmarks[key] = bookmark;
    [self persistFolderBookmarks];
    [self startAccessForDirectoryPath:key];
}

- (BOOL)startAccessForDirectoryOfFilePath:(NSString *)path {
    NSString *directoryPath = [self directoryPathForFilePath:path];
    return [self startAccessForDirectoryPath:directoryPath];
}

- (BOOL)startAccessForDirectoryPath:(NSString *)directoryPath {
    NSString *key = [self bookmarkKeyForDirectoryPath:directoryPath];
    if (!key.length) { return NO; }
    if (self.activeFolderAccessURLs[key]) { return YES; }

    NSData *bookmark = self.folderBookmarks[key];
    if (!bookmark) { return NO; }

    BOOL stale = NO;
    NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                           options:NSURLBookmarkResolutionWithSecurityScope
                                     relativeToURL:nil
                               bookmarkDataIsStale:&stale
                                             error:&error];
    if (!url) {
        error = nil;
        url = [NSURL URLByResolvingBookmarkData:bookmark
                                        options:0
                                  relativeToURL:nil
                            bookmarkDataIsStale:&stale
                                          error:&error];
    }
    if (!url) {
        NSLog(@"SubtitleMediaPlayer: failed to restore folder bookmark for %@: %@", key, error.localizedDescription);
        [self.folderBookmarks removeObjectForKey:key];
        [self persistFolderBookmarks];
        return NO;
    }

    [url startAccessingSecurityScopedResource];
    self.activeFolderAccessURLs[key] = url;

    if (stale) {
        NSError *bookmarkError = nil;
        NSData *freshBookmark = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                              includingResourceValuesForKeys:nil
                                               relativeToURL:nil
                                                       error:&bookmarkError];
        if (!freshBookmark) {
            freshBookmark = [url bookmarkDataWithOptions:0
                          includingResourceValuesForKeys:nil
                                           relativeToURL:nil
                                                   error:&bookmarkError];
        }
        if (freshBookmark) {
            self.folderBookmarks[key] = freshBookmark;
            [self persistFolderBookmarks];
        } else {
            NSLog(@"SubtitleMediaPlayer: failed to refresh folder bookmark for %@: %@", key, bookmarkError.localizedDescription);
        }
    }

    return YES;
}

- (void)openVideoPanel:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedFileTypes = @[@"mp4", @"mkv", @"mov", @"ts"];
    if ([panel runModal] == NSModalResponseOK) {
        [self openVideoAtURL:panel.URL];
    }
}

- (void)openSubtitlePanel:(id)sender {
    (void)sender;
    if (!self.currentVideoPath) {
        self.statusLabel.stringValue = @"请先打开视频";
        return;
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedFileTypes = @[@"srt"];
    if ([panel runModal] == NSModalResponseOK) {
        [self rememberDirectoryAccessForFileURL:panel.URL];
        [self loadSubtitleAtPath:panel.URL.path show:YES];
    }
}

- (void)openVideoAtURL:(NSURL *)url {
    if (!self.mpv || !self.folderBookmarks || !self.activeFolderAccessURLs) {
        self.pendingOpenURL = url;
        self.pendingOpenPath = url.path;
        return;
    }
    [self rememberDirectoryAccessForFileURL:url];
    if (self.currentVideoPath.length && [self launchNewInstanceForVideoURL:url]) {
        return;
    }
    [self openVideoAtPath:url.path];
}

- (BOOL)launchNewInstanceForVideoURL:(NSURL *)url {
    if (!url.path.length) { return NO; }
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    if (!bundlePath.length) { return NO; }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = @[@"-n", bundlePath, @"--args", url.path];
    NSFileHandle *nullDevice = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = nullDevice;
    task.standardError = nullDevice;

    NSError *error = nil;
    BOOL launched = [task launchAndReturnError:&error];
    if (!launched) {
        NSLog(@"SubtitleMediaPlayer: failed to launch another instance: %@", error.localizedDescription);
    }
    return launched;
}

- (void)openVideoAtPath:(NSString *)path {
    if (!self.mpv) {
        self.pendingOpenPath = path;
        return;
    }
    if (self.folderBookmarks && self.activeFolderAccessURLs) {
        [self rememberDirectoryAccessForFileURL:[NSURL fileURLWithPath:path]];
    }
    [self startAccessForDirectoryOfFilePath:path];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        self.statusLabel.stringValue = @"视频不存在";
        return;
    }
    [self saveCurrentPlaybackPositionIfNeeded];
    self.currentVideoPath = path;
    self.currentSubtitlePath = nil;
    self.duration = 0;
    self.position = 0;
    self.hasPendingResumePosition = NO;
    self.pendingResumePosition = [self savedPlaybackPositionForPath:path];
    if (self.pendingResumePosition >= SMPResumeMinimumPosition) {
        self.hasPendingResumePosition = YES;
    }
    self.progressSlider.doubleValue = 0;
    self.progressSlider.maxValue = 1;
    self.statusLabel.stringValue = path.lastPathComponent;
    self.window.title = [NSString stringWithFormat:@"SubtitleMediaPlayer - %@", path.lastPathComponent];
    [self command:@[@"loadfile", path, @"replace"]];
    [self applyVolumeFromSliderValue:self.volumeSlider.doubleValue];
    [self setDoubleProperty:"speed" value:[self selectedSpeed]];
    [self setFlagProperty:"pause" value:NO];
    self.paused = NO;
    [self refreshPlayButton];
}

- (void)togglePlay:(id)sender {
    (void)sender;
    if (!self.currentVideoPath) {
        [self openVideoPanel:nil];
        return;
    }
    [self setFlagProperty:"pause" value:!self.paused];
}

- (void)progressChanged:(NSSlider *)sender {
    if (!self.currentVideoPath || self.duration <= 0) { return; }
    [self seekToSeconds:sender.doubleValue];
}

- (void)seekRelative:(double)delta {
    if (!self.currentVideoPath || self.duration <= 0) { return; }
    [self seekToSeconds:self.position + delta];
}

- (void)seekToSeconds:(double)seconds {
    if (!self.currentVideoPath || self.duration <= 0) { return; }
    double clamped = MIN(MAX(seconds, 0.0), self.duration);
    self.position = clamped;
    self.progressSlider.doubleValue = clamped;
    [self refreshTimeUI];
    [self command:@[@"seek", [NSString stringWithFormat:@"%.3f", clamped], @"absolute", @"exact"]];
    [self saveCurrentPlaybackPositionIfNeeded];
}

- (NSString *)playbackPositionDefaultsKeyForPath:(NSString *)path {
    if (!path.length) { return nil; }
    return [@"playbackPosition:" stringByAppendingString:path.stringByStandardizingPath];
}

- (double)savedPlaybackPositionForPath:(NSString *)path {
    NSString *key = [self playbackPositionDefaultsKeyForPath:path];
    if (!key.length || ![self.defaults objectForKey:key]) { return 0; }
    return [self.defaults doubleForKey:key];
}

- (void)saveCurrentPlaybackPositionThrottled {
    double now = CFAbsoluteTimeGetCurrent();
    if (now - self.lastPlaybackPositionSaveTime < SMPPlaybackPositionSaveInterval) {
        return;
    }
    self.lastPlaybackPositionSaveTime = now;
    [self saveCurrentPlaybackPositionIfNeeded];
}

- (void)saveCurrentPlaybackPositionIfNeeded {
    if (!self.currentVideoPath.length || self.hasPendingResumePosition) { return; }

    BOOL nearEnd = self.duration > 30.0 && self.position >= self.duration - SMPResumeEndThreshold;
    if (self.position < SMPResumeMinimumPosition || nearEnd) {
        [self clearSavedPlaybackPositionForPath:self.currentVideoPath];
        return;
    }

    NSString *key = [self playbackPositionDefaultsKeyForPath:self.currentVideoPath];
    if (!key.length) { return; }
    [self.defaults setDouble:self.position forKey:key];
}

- (void)clearSavedPlaybackPositionForPath:(NSString *)path {
    NSString *key = [self playbackPositionDefaultsKeyForPath:path];
    if (!key.length) { return; }
    [self.defaults removeObjectForKey:key];
}

- (void)applyPendingResumePositionIfNeeded {
    if (!self.hasPendingResumePosition) { return; }

    double target = self.pendingResumePosition;
    self.hasPendingResumePosition = NO;
    self.pendingResumePosition = 0;

    BOOL nearEnd = self.duration > 30.0 && target >= self.duration - SMPResumeEndThreshold;
    if (target < SMPResumeMinimumPosition || nearEnd) {
        [self clearSavedPlaybackPositionForPath:self.currentVideoPath];
        return;
    }

    if (self.duration > 0) {
        target = MIN(MAX(target, 0), self.duration);
    }
    self.position = target;
    self.progressSlider.doubleValue = target;
    [self refreshTimeUI];
    [self command:@[@"seek", [NSString stringWithFormat:@"%.3f", target], @"absolute", @"exact"]];
    [self saveCurrentPlaybackPositionIfNeeded];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"已恢复到 %@", [self formatSeconds:target]];
}

- (void)volumeChanged:(NSSlider *)sender {
    double value = sender.doubleValue;
    [self.defaults setDouble:value forKey:@"volume"];
    [self applyVolumeFromSliderValue:value];
}

- (void)applyVolumeFromSliderValue:(double)value {
    [self setDoubleProperty:"volume" value:MIN(MAX(value, 0.0), SMPMaxVolume)];
}

- (void)speedChanged:(id)sender {
    (void)sender;
    double speed = [self selectedSpeed];
    [self.defaults setDouble:speed forKey:@"speed"];
    [self setDoubleProperty:"speed" value:speed];
}

- (void)toggleSubtitle:(id)sender {
    (void)sender;
    if (!self.currentVideoPath) {
        self.statusLabel.stringValue = @"请先打开视频";
        return;
    }
    if (self.subtitleVisible) {
        [self setFlagProperty:"sub-visibility" value:NO];
        self.statusLabel.stringValue = @"字幕已关闭";
        return;
    }
    if (!self.currentSubtitlePath) {
        NSString *sidecar = [self sidecarSubtitleForVideo:self.currentVideoPath];
        if (sidecar) {
            [self loadSubtitleAtPath:sidecar show:YES];
            return;
        }
        [self openSubtitlePanel:nil];
        return;
    }
    [self setFlagProperty:"sub-visibility" value:YES];
    self.statusLabel.stringValue = @"字幕已开启";
}

- (void)loadSidecarSubtitleIfAvailable {
    NSString *sidecar = [self sidecarSubtitleForVideo:self.currentVideoPath];
    if (sidecar) {
        [self loadSubtitleAtPath:sidecar show:YES];
    }
}

- (NSString *)sidecarSubtitleForVideo:(NSString *)videoPath {
    if (!videoPath) { return nil; }
    [self startAccessForDirectoryOfFilePath:videoPath];
    NSString *dir = videoPath.stringByDeletingLastPathComponent;
    NSString *base = videoPath.lastPathComponent.stringByDeletingPathExtension;
    for (NSString *ext in @[@"srt", @"SRT"]) {
        NSString *candidate = [[dir stringByAppendingPathComponent:base] stringByAppendingPathExtension:ext];
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

- (void)loadSubtitleAtPath:(NSString *)path show:(BOOL)show {
    if (!path) { return; }
    [self startAccessForDirectoryOfFilePath:path];
    self.currentSubtitlePath = path;
    [self command:@[@"sub-add", path, @"select"]];
    [self setFlagProperty:"sub-visibility" value:show];
    self.subtitleVisible = show;
    [self.defaults setBool:show forKey:@"subtitlesEnabled"];
    [self refreshSubtitleButton];
    self.statusLabel.stringValue = show ? @"字幕已加载" : @"字幕已加载但隐藏";
}

- (void)generateSubtitle:(id)sender {
    (void)sender;
    if (!self.currentVideoPath) {
        self.statusLabel.stringValue = @"请先打开视频";
        return;
    }
    if (self.subtitleGenerating) { return; }
    NSString *model = [self findWhisperModel];
    if (!model) {
        self.statusLabel.stringValue = @"缺少 whisper 模型";
        return;
    }
    NSString *ffmpeg = [self executablePath:@"ffmpeg"];
    NSString *ffprobe = [self executablePath:@"ffprobe"];
    NSString *whisper = [self executablePath:@"whisper-cli"];
    if (!ffmpeg || !ffprobe || !whisper) {
        self.statusLabel.stringValue = @"缺少 ffmpeg/ffprobe 或 whisper-cli";
        return;
    }

    self.subtitleGenerating = YES;
    self.autoSubtitleButton.enabled = NO;
    self.statusLabel.stringValue = @"生成中：抽音频";

    NSString *videoPath = self.currentVideoPath.copy;
    double mediaDuration = self.duration;
    [self startAccessForDirectoryOfFilePath:videoPath];
    NSString *targetSRT = [[videoPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"srt"];
    NSString *tempRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *audioPath = [tempRoot stringByAppendingPathComponent:@"audio.wav"];
    NSString *outputBase = [tempRoot stringByAppendingPathComponent:@"subtitle"];
    NSString *tempSRT = [outputBase stringByAppendingPathExtension:@"srt"];

    dispatch_async(self.subtitleQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *dirError = nil;
        [fm createDirectoryAtPath:tempRoot withIntermediateDirectories:YES attributes:nil error:&dirError];
        if (dirError) {
            [self finishSubtitleGenerationWithError:@"创建临时目录失败" tempRoot:tempRoot];
            return;
        }

        int audioStatus = [self runTask:ffmpeg arguments:@[@"-hide_banner", @"-loglevel", @"error", @"-y", @"-i", videoPath, @"-vn", @"-ac", @"1", @"-ar", @"16000", @"-c:a", @"pcm_s16le", audioPath]];
        if (audioStatus != 0) {
            [self finishSubtitleGenerationWithError:@"抽音频失败" tempRoot:tempRoot];
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.stringValue = @"生成中：识别中英字幕";
        });

        double audioDuration = [self mediaDurationAtPath:audioPath ffprobe:ffprobe];
        double videoDuration = [self mediaDurationAtPath:videoPath ffprobe:ffprobe];
        double transcriptionDuration = audioDuration > 0 ? audioDuration : MAX(mediaDuration, videoDuration);
        double timelineOffset = MAX([self firstAudioStreamStartTimeAtPath:videoPath ffprobe:ffprobe], 0.0);

        NSString *prompt = @"以下是中英混合课程字幕。中文请使用简体中文；英文单词、术语和英文句子请保留英文原文。不要把中文翻译成英文。";
        int whisperStatus = [self transcribeAudioAtPath:audioPath
                                                  model:model
                                                 ffmpeg:ffmpeg
                                                whisper:whisper
                                                 prompt:prompt
                                             outputBase:outputBase
                                           mediaDuration:transcriptionDuration
                                          timelineOffset:timelineOffset];
        if (whisperStatus == -2) {
            [self finishSubtitleGenerationWithError:@"没有识别到语音" tempRoot:tempRoot];
            return;
        }
        if (whisperStatus != 0 || ![fm fileExistsAtPath:tempSRT]) {
            [self finishSubtitleGenerationWithError:@"识别字幕失败" tempRoot:tempRoot];
            return;
        }

        [self simplifySubtitleAtPath:tempSRT];
        [self removeRepeatedSubtitleRunsAtPath:tempSRT];

        [fm removeItemAtPath:targetSRT error:nil];
        NSError *moveError = nil;
        [fm moveItemAtPath:tempSRT toPath:targetSRT error:&moveError];
        if (moveError) {
            [self finishSubtitleGenerationWithError:@"保存字幕失败" tempRoot:tempRoot];
            return;
        }

        [fm removeItemAtPath:tempRoot error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.subtitleGenerating = NO;
            self.autoSubtitleButton.enabled = YES;
            self.statusLabel.stringValue = @"字幕生成完成";
            [self loadSubtitleAtPath:targetSRT show:YES];
        });
    });
}

- (NSString *)findWhisperModel {
    NSString *envModel = NSProcessInfo.processInfo.environment[@"WHISPER_MODEL"];
    if (envModel.length && [[NSFileManager defaultManager] fileExistsAtPath:envModel]) {
        return envModel;
    }
    NSArray<NSString *> *names = @[
        @"ggml-large-v3-turbo.bin",
        @"ggml-large-v3.bin",
        @"ggml-medium.bin",
        @"ggml-small.bin",
        @"ggml-base.bin",
        @"ggml-tiny.bin"
    ];
    NSString *home = NSHomeDirectory();
    NSArray<NSString *> *dirs = @[
        [home stringByAppendingPathComponent:@"Library/Application Support/SubtitleMediaPlayer/models"],
        [home stringByAppendingPathComponent:@"models"],
        @"/opt/homebrew/share/whisper-cpp/models",
        @"/usr/local/share/whisper-cpp/models"
    ];
    for (NSString *dir in dirs) {
        for (NSString *name in names) {
            NSString *path = [dir stringByAppendingPathComponent:name];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                return path;
            }
        }
    }
    NSURL *resourceURL = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"models"];
    for (NSString *name in names) {
        NSString *path = [resourceURL.path stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

- (int)transcribeAudioAtPath:(NSString *)audioPath
                       model:(NSString *)model
                      ffmpeg:(NSString *)ffmpeg
                     whisper:(NSString *)whisper
                      prompt:(NSString *)prompt
                  outputBase:(NSString *)outputBase
               mediaDuration:(double)mediaDuration
              timelineOffset:(double)timelineOffset {
    double chunkSeconds = 300.0;
    double overlapSeconds = 15.0;
    if (mediaDuration <= chunkSeconds * 2.0) {
        int status = [self runTask:whisper arguments:[self whisperArgumentsWithModel:model
                                                                           audioPath:audioPath
                                                                             prompt:prompt
                                                                          outputBase:outputBase
                                                                            offsetMS:0
                                                                          durationMS:0]];
        if (status != 0) { return status; }
        NSString *srtPath = [outputBase stringByAppendingPathExtension:@"srt"];
        if ([self subtitleFileHasUsableContentAtPath:srtPath] && timelineOffset > 0) {
            if (![self shiftSubtitleFileAtPath:srtPath bySeconds:timelineOffset]) {
                return -1;
            }
        }
        return [self subtitleFileHasUsableContentAtPath:srtPath] ? 0 : -2;
    }

    NSUInteger chunkCount = (NSUInteger)ceil(mediaDuration / chunkSeconds);
    NSMutableArray<NSString *> *chunkSRTs = NSMutableArray.array;
    for (NSUInteger index = 0; index < chunkCount; index++) {
        double coreStartSeconds = (double)index * chunkSeconds;
        double coreEndSeconds = MIN(coreStartSeconds + chunkSeconds, mediaDuration);
        double offsetSeconds = MAX(coreStartSeconds - overlapSeconds, 0.0);
        double endSeconds = MIN(coreEndSeconds + overlapSeconds, mediaDuration);
        double durationSeconds = endSeconds - offsetSeconds;
        if (durationSeconds <= 0) { continue; }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.stringValue = [NSString stringWithFormat:@"生成中：识别中英字幕 %lu/%lu",
                                            (unsigned long)(index + 1),
                                            (unsigned long)chunkCount];
        });

        NSString *chunkBase = [outputBase stringByAppendingFormat:@"-%03lu", (unsigned long)(index + 1)];
        NSString *chunkAudio = [chunkBase stringByAppendingPathExtension:@"wav"];
        int audioStatus = [self runTask:ffmpeg arguments:@[
            @"-hide_banner",
            @"-loglevel", @"error",
            @"-y",
            @"-ss", [NSString stringWithFormat:@"%.3f", offsetSeconds],
            @"-t", [NSString stringWithFormat:@"%.3f", durationSeconds],
            @"-i", audioPath,
            @"-ac", @"1",
            @"-ar", @"16000",
            @"-c:a", @"pcm_s16le",
            chunkAudio
        ]];
        if (audioStatus != 0 || ![[NSFileManager defaultManager] fileExistsAtPath:chunkAudio]) {
            return audioStatus == 0 ? -1 : audioStatus;
        }

        int status = [self runTask:whisper arguments:[self whisperArgumentsWithModel:model
                                                                           audioPath:chunkAudio
                                                                             prompt:prompt
                                                                          outputBase:chunkBase
                                                                            offsetMS:0
                                                                          durationMS:0]];
        NSString *chunkSRT = [chunkBase stringByAppendingPathExtension:@"srt"];
        if (status != 0) {
            return status;
        }
        if ([self subtitleFileHasUsableContentAtPath:chunkSRT]) {
            double timelineShift = timelineOffset + offsetSeconds;
            double keepStart = timelineOffset + coreStartSeconds;
            double keepEnd = timelineOffset + coreEndSeconds;
            if (![self shiftAndCropSubtitleFileAtPath:chunkSRT
                                             bySeconds:timelineShift
                                             keepStart:keepStart
                                               keepEnd:keepEnd]) {
                return -1;
            }
            if ([self subtitleFileHasUsableContentAtPath:chunkSRT]) {
                [chunkSRTs addObject:chunkSRT];
            }
        }
    }

    if (chunkSRTs.count == 0) { return -2; }
    return [self mergeSubtitleFiles:chunkSRTs toPath:[outputBase stringByAppendingPathExtension:@"srt"]] ? 0 : -1;
}

- (NSArray<NSString *> *)whisperArgumentsWithModel:(NSString *)model
                                         audioPath:(NSString *)audioPath
                                           prompt:(NSString *)prompt
                                        outputBase:(NSString *)outputBase
                                          offsetMS:(NSInteger)offsetMS
                                        durationMS:(NSInteger)durationMS {
    NSMutableArray<NSString *> *arguments = [@[
        @"-m", model,
        @"-f", audioPath,
        @"-l", @"zh",
        @"--prompt", prompt,
        @"-mc", @"0",
        @"-ml", @"96",
        @"-sow",
        @"-bs", @"8",
        @"-bo", @"8",
        @"-osrt",
        @"-of", outputBase,
        @"-np"
    ] mutableCopy];
    if (offsetMS > 0) {
        [arguments addObjectsFromArray:@[@"-ot", [NSString stringWithFormat:@"%ld", (long)offsetMS]]];
    }
    if (durationMS > 0) {
        [arguments addObjectsFromArray:@[@"-d", [NSString stringWithFormat:@"%ld", (long)durationMS]]];
    }
    return arguments;
}

- (BOOL)mergeSubtitleFiles:(NSArray<NSString *> *)paths toPath:(NSString *)targetPath {
    NSMutableString *output = NSMutableString.string;
    NSUInteger sequence = 1;
    for (NSString *path in paths) {
        NSError *readError = nil;
        NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
        if (!content.length || readError) { return NO; }
        NSString *normalizedContent = [[content stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
        NSArray<NSString *> *lines = [normalizedContent componentsSeparatedByString:@"\n"];
        NSMutableArray<NSString *> *current = NSMutableArray.array;
        for (NSString *line in lines) {
            if (line.length == 0) {
                if (current.count > 0) {
                    sequence = [self appendSubtitleBlock:current toString:output sequence:sequence];
                    [current removeAllObjects];
                }
            } else {
                [current addObject:line];
            }
        }
        if (current.count > 0) {
            sequence = [self appendSubtitleBlock:current toString:output sequence:sequence];
        }
    }
    return [output writeToFile:targetPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)subtitleFileHasUsableContentAtPath:(NSString *)path {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) { return NO; }
    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    if (!content.length || readError) { return NO; }
    return [content containsString:@"-->"];
}

- (BOOL)shiftSubtitleFileAtPath:(NSString *)path bySeconds:(double)offsetSeconds {
    if (offsetSeconds <= 0) { return YES; }

    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    if (!content.length || readError) { return NO; }

    NSString *normalizedContent = [[content stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray<NSString *> *lines = [normalizedContent componentsSeparatedByString:@"\n"];
    NSMutableString *output = NSMutableString.string;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        double start = 0;
        double end = 0;
        if ([line containsString:@"-->"] && [self parseSRTTimeLine:line start:&start end:&end]) {
            line = [NSString stringWithFormat:@"%@ --> %@",
                    [self formatSRTTimestamp:start + offsetSeconds],
                    [self formatSRTTimestamp:end + offsetSeconds]];
        }
        [output appendString:line];
        if (i + 1 < lines.count) {
            [output appendString:@"\n"];
        }
    }

    return [output writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)shiftAndCropSubtitleFileAtPath:(NSString *)path
                             bySeconds:(double)offsetSeconds
                             keepStart:(double)keepStart
                               keepEnd:(double)keepEnd {
    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    if (!content.length || readError) { return NO; }

    NSString *normalizedContent = [[content stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray<NSString *> *lines = [normalizedContent componentsSeparatedByString:@"\n"];
    NSMutableArray<NSArray<NSString *> *> *blocks = NSMutableArray.array;
    NSMutableArray<NSString *> *current = NSMutableArray.array;
    for (NSString *line in lines) {
        if (line.length == 0) {
            if (current.count > 0) {
                [blocks addObject:current.copy];
                [current removeAllObjects];
            }
        } else {
            [current addObject:line];
        }
    }
    if (current.count > 0) {
        [blocks addObject:current.copy];
    }

    NSMutableString *output = NSMutableString.string;
    NSUInteger sequence = 1;
    for (NSArray<NSString *> *blockLines in blocks) {
        NSUInteger timeIndex = NSNotFound;
        for (NSUInteger i = 0; i < blockLines.count; i++) {
            if ([blockLines[i] containsString:@"-->"]) {
                timeIndex = i;
                break;
            }
        }
        if (timeIndex == NSNotFound || timeIndex + 1 >= blockLines.count) { continue; }

        double start = 0;
        double end = 0;
        if (![self parseSRTTimeLine:blockLines[timeIndex] start:&start end:&end]) { continue; }

        start += offsetSeconds;
        end += offsetSeconds;
        double midpoint = (start + end) / 2.0;
        if (midpoint < keepStart || midpoint >= keepEnd) { continue; }

        start = MAX(start, keepStart);
        end = MIN(end, keepEnd);
        if (end <= start) {
            end = start + 0.2;
        }

        NSArray<NSString *> *textLines = [blockLines subarrayWithRange:NSMakeRange(timeIndex + 1, blockLines.count - timeIndex - 1)];
        [output appendFormat:@"%lu\n%@ --> %@\n%@\n\n",
         (unsigned long)sequence++,
         [self formatSRTTimestamp:start],
         [self formatSRTTimestamp:end],
         [textLines componentsJoinedByString:@"\n"]];
    }

    return [output writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (double)mediaDurationAtPath:(NSString *)path ffprobe:(NSString *)ffprobe {
    if (!path.length || !ffprobe.length) { return 0; }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ffprobe];
    task.arguments = @[
        @"-v", @"error",
        @"-show_entries", @"format=duration",
        @"-of", @"default=noprint_wrappers=1:nokey=1",
        path
    ];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"SubtitleMediaPlayer: ffprobe failed to launch: %@", error.localizedDescription);
        return 0;
    }
    [task waitUntilExit];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    if (task.terminationStatus != 0 || data.length == 0) { return 0; }

    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return output.doubleValue;
}

- (double)firstAudioStreamStartTimeAtPath:(NSString *)path ffprobe:(NSString *)ffprobe {
    if (!path.length || !ffprobe.length) { return 0; }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ffprobe];
    task.arguments = @[
        @"-v", @"error",
        @"-select_streams", @"a:0",
        @"-show_entries", @"stream=start_time",
        @"-of", @"default=noprint_wrappers=1:nokey=1",
        path
    ];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"SubtitleMediaPlayer: ffprobe failed to launch: %@", error.localizedDescription);
        return 0;
    }
    [task waitUntilExit];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    if (task.terminationStatus != 0 || data.length == 0) { return 0; }

    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return output.doubleValue;
}

- (NSUInteger)appendSubtitleBlock:(NSArray<NSString *> *)blockLines
                         toString:(NSMutableString *)output
                         sequence:(NSUInteger)sequence {
    NSUInteger timeIndex = NSNotFound;
    for (NSUInteger i = 0; i < blockLines.count; i++) {
        if ([blockLines[i] containsString:@"-->"]) {
            timeIndex = i;
            break;
        }
    }
    if (timeIndex == NSNotFound || timeIndex + 1 >= blockLines.count) {
        return sequence;
    }
    NSArray<NSString *> *payload = [blockLines subarrayWithRange:NSMakeRange(timeIndex, blockLines.count - timeIndex)];
    [output appendFormat:@"%lu\n%@\n\n", (unsigned long)sequence, [payload componentsJoinedByString:@"\n"]];
    return sequence + 1;
}

- (void)simplifySubtitleAtPath:(NSString *)path {
    if (!path.length) { return; }

    NSString *opencc = [self executablePath:@"opencc"];
    if (opencc) {
        NSString *convertedPath = [path.stringByDeletingPathExtension stringByAppendingPathExtension:@"simplified.srt"];
        int status = [self runTask:opencc arguments:@[@"-c", @"t2s.json", @"-i", path, @"-o", convertedPath]];
        if (status == 0 && [[NSFileManager defaultManager] fileExistsAtPath:convertedPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:convertedPath toPath:path error:nil];
            return;
        }
        [[NSFileManager defaultManager] removeItemAtPath:convertedPath error:nil];
    }

    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    if (!content.length || readError) { return; }

    NSMutableString *simplified = content.mutableCopy;
    CFStringTransform((__bridge CFMutableStringRef)simplified, NULL, CFSTR("Hant-Hans"), false);
    CFStringTransform((__bridge CFMutableStringRef)simplified, NULL, CFSTR("Traditional-Simplified"), false);
    [simplified writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)removeRepeatedSubtitleRunsAtPath:(NSString *)path {
    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    if (!content.length || readError) { return; }

    NSString *normalizedContent = [[content stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray<NSString *> *lines = [normalizedContent componentsSeparatedByString:@"\n"];
    NSMutableArray<NSArray<NSString *> *> *rawBlocks = NSMutableArray.array;
    NSMutableArray<NSString *> *current = NSMutableArray.array;
    for (NSString *line in lines) {
        if (line.length == 0) {
            if (current.count > 0) {
                [rawBlocks addObject:current.copy];
                [current removeAllObjects];
            }
        } else {
            [current addObject:line];
        }
    }
    if (current.count > 0) {
        [rawBlocks addObject:current.copy];
    }

    NSMutableArray<NSMutableDictionary *> *blocks = NSMutableArray.array;
    for (NSArray<NSString *> *blockLines in rawBlocks) {
        NSInteger timeIndex = NSNotFound;
        for (NSUInteger i = 0; i < blockLines.count; i++) {
            if ([blockLines[i] containsString:@"-->"]) {
                timeIndex = (NSInteger)i;
                break;
            }
        }
        if (timeIndex == NSNotFound || timeIndex + 1 >= (NSInteger)blockLines.count) {
            [blocks addObject:[@{@"parsed": @NO, @"lines": blockLines, @"remove": @NO} mutableCopy]];
            continue;
        }

        double start = 0;
        double end = 0;
        if (![self parseSRTTimeLine:blockLines[(NSUInteger)timeIndex] start:&start end:&end]) {
            [blocks addObject:[@{@"parsed": @NO, @"lines": blockLines, @"remove": @NO} mutableCopy]];
            continue;
        }

        NSArray<NSString *> *textLines = [blockLines subarrayWithRange:NSMakeRange((NSUInteger)timeIndex + 1, blockLines.count - (NSUInteger)timeIndex - 1)];
        NSString *text = [textLines componentsJoinedByString:@"\n"];
        [blocks addObject:[@{
            @"parsed": @YES,
            @"start": @(start),
            @"end": @(end),
            @"text": text,
            @"norm": [self normalizedSubtitleText:text],
            @"remove": @NO
        } mutableCopy]];
    }

    NSUInteger removed = 0;
    NSUInteger i = 0;
    while (i < blocks.count) {
        NSMutableDictionary *first = blocks[i];
        if (![first[@"parsed"] boolValue] || [first[@"norm"] length] == 0) {
            i++;
            continue;
        }
        NSUInteger j = i + 1;
        while (j < blocks.count &&
               [blocks[j][@"parsed"] boolValue] &&
               [blocks[j][@"norm"] isEqualToString:first[@"norm"]]) {
            j++;
        }

        NSUInteger runCount = j - i;
        double runStart = [blocks[i][@"start"] doubleValue];
        double runEnd = [blocks[j - 1][@"end"] doubleValue];
        if (runCount >= 10 && runEnd - runStart >= 30.0) {
            NSUInteger keep = 3;
            for (NSUInteger k = i + keep; k < j; k++) {
                blocks[k][@"remove"] = @YES;
                removed++;
            }
        }
        i = j;
    }

    BOOL fixedDuration = NO;
    NSMutableString *output = NSMutableString.string;
    NSUInteger sequence = 1;
    for (NSMutableDictionary *block in blocks) {
        if ([block[@"remove"] boolValue]) { continue; }
        if (![block[@"parsed"] boolValue]) {
            NSArray<NSString *> *blockLines = block[@"lines"];
            [output appendFormat:@"%@\n\n", [blockLines componentsJoinedByString:@"\n"]];
            continue;
        }
        double start = [block[@"start"] doubleValue];
        double end = [block[@"end"] doubleValue];
        if (end <= start) {
            end = start + 0.5;
            fixedDuration = YES;
        }
        [output appendFormat:@"%lu\n%@ --> %@\n%@\n\n",
         (unsigned long)sequence++,
         [self formatSRTTimestamp:start],
         [self formatSRTTimestamp:end],
         block[@"text"]];
    }

    if (removed > 0 || fixedDuration) {
        [output writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

- (BOOL)parseSRTTimeLine:(NSString *)line start:(double *)start end:(double *)end {
    int sh = 0, sm = 0, ss = 0, sms = 0, eh = 0, em = 0, es = 0, ems = 0;
    int matched = sscanf(line.UTF8String, "%d:%d:%d,%d --> %d:%d:%d,%d", &sh, &sm, &ss, &sms, &eh, &em, &es, &ems);
    if (matched != 8) { return NO; }
    if (start) { *start = (double)(sh * 3600 + sm * 60 + ss) + ((double)sms / 1000.0); }
    if (end) { *end = (double)(eh * 3600 + em * 60 + es) + ((double)ems / 1000.0); }
    return YES;
}

- (NSString *)formatSRTTimestamp:(double)seconds {
    int totalMilliseconds = (int)llround(MAX(seconds, 0.0) * 1000.0);
    int hours = totalMilliseconds / 3600000;
    totalMilliseconds %= 3600000;
    int minutes = totalMilliseconds / 60000;
    totalMilliseconds %= 60000;
    int secs = totalMilliseconds / 1000;
    int millis = totalMilliseconds % 1000;
    return [NSString stringWithFormat:@"%02d:%02d:%02d,%03d", hours, minutes, secs, millis];
}

- (NSString *)normalizedSubtitleText:(NSString *)text {
    NSMutableCharacterSet *allowed = NSCharacterSet.letterCharacterSet.mutableCopy;
    [allowed formUnionWithCharacterSet:NSCharacterSet.decimalDigitCharacterSet];
    NSArray<NSString *> *parts = [[text lowercaseString] componentsSeparatedByCharactersInSet:allowed.invertedSet];
    return [parts componentsJoinedByString:@""];
}

- (NSString *)executablePath:(NSString *)name {
    NSArray<NSString *> *dirs = @[@"/opt/homebrew/bin", @"/usr/local/bin", @"/usr/bin", @"/bin"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in dirs) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

- (int)runTask:(NSString *)path arguments:(NSArray<NSString *> *)arguments {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    NSFileHandle *nullDevice = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = nullDevice;
    task.standardError = nullDevice;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return -1;
    }
    [task waitUntilExit];
    return task.terminationStatus;
}

- (void)finishSubtitleGenerationWithError:(NSString *)message tempRoot:(NSString *)tempRoot {
    [[NSFileManager defaultManager] removeItemAtPath:tempRoot error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.subtitleGenerating = NO;
        self.autoSubtitleButton.enabled = YES;
        self.statusLabel.stringValue = message;
    });
}

- (void)command:(NSArray<NSString *> *)arguments {
    if (!self.mpv) { return; }
    NSUInteger count = arguments.count;
    char **cmd = calloc(count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < count; i++) {
        cmd[i] = strdup(arguments[i].UTF8String);
    }
    cmd[count] = NULL;
    mpv_command(self.mpv, (const char **)cmd);
    for (NSUInteger i = 0; i < count; i++) {
        free(cmd[i]);
    }
    free(cmd);
}

- (void)setDoubleProperty:(const char *)name value:(double)value {
    if (!self.mpv) { return; }
    double copy = value;
    mpv_set_property(self.mpv, name, MPV_FORMAT_DOUBLE, &copy);
}

- (void)setFlagProperty:(const char *)name value:(BOOL)value {
    if (!self.mpv) { return; }
    int flag = value ? 1 : 0;
    mpv_set_property(self.mpv, name, MPV_FORMAT_FLAG, &flag);
}

- (double)selectedSpeed {
    NSNumber *speed = self.speedPopup.selectedItem.representedObject;
    return speed ? speed.doubleValue : 1.0;
}

- (void)selectSpeed:(double)speed {
    NSArray<NSMenuItem *> *items = self.speedPopup.itemArray;
    NSInteger bestIndex = 1;
    double bestDelta = DBL_MAX;
    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        double itemSpeed = [items[i].representedObject doubleValue];
        double delta = fabs(itemSpeed - speed);
        if (delta < bestDelta) {
            bestDelta = delta;
            bestIndex = i;
        }
    }
    [self.speedPopup selectItemAtIndex:bestIndex];
}

- (void)refreshPlayButton {
    self.playButton.title = self.paused ? @"播放" : @"暂停";
}

- (void)refreshSubtitleButton {
    self.subtitleButton.title = self.subtitleVisible ? @"字幕开" : @"字幕";
}

- (void)refreshTimeUI {
    if (self.duration > 0) {
        self.progressSlider.maxValue = self.duration;
        self.progressSlider.doubleValue = MIN(MAX(self.position, 0), self.duration);
    }
    self.timeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@",
                                  [self formatSeconds:self.position],
                                  [self formatSeconds:self.duration]];
}

- (NSString *)formatSeconds:(double)seconds {
    if (!isfinite(seconds) || seconds < 0) { seconds = 0; }
    NSInteger total = (NSInteger)llround(seconds);
    NSInteger h = total / 3600;
    NSInteger m = (total % 3600) / 60;
    NSInteger s = total % 60;
    if (h > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)m, (long)s];
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
