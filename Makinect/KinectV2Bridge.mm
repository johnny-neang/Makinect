#import "KinectV2Bridge.h"
#include <libfreenect2/libfreenect2.hpp>
#include <libfreenect2/frame_listener_impl.h>
#include <libfreenect2/packet_pipeline.h>
#import <IOKit/IOKitLib.h>

// MARK: - Known Kinect USB Product IDs (Vendor 0x045e = Microsoft)

struct KinectUSBInfo {
    int productId;
    MKKinectVersion version;
    const char *name;
};

static const KinectUSBInfo kKnownKinects[] = {
    // Kinect v1 - Xbox 360
    { 0x02AE, MKKinectVersionKinectV1, "Kinect v1 Camera (Xbox 360)" },
    { 0x02AD, MKKinectVersionKinectV1, "Kinect v1 Audio (Xbox 360)" },
    { 0x02B0, MKKinectVersionKinectV1, "Kinect v1 Motor (Xbox 360)" },
    // Kinect v1 - Kinect for Windows
    { 0x02BF, MKKinectVersionKinectV1, "Kinect v1 Camera (K4W)" },
    { 0x02BE, MKKinectVersionKinectV1, "Kinect v1 Audio (K4W)" },
    { 0x02C2, MKKinectVersionKinectV1, "Kinect v1 Audio Alt (K4W)" },
    { 0x02C3, MKKinectVersionKinectV1, "Kinect v1 Audio Alt2 (K4W)" },
    // Kinect v2 - Xbox One / Kinect for Windows v2
    { 0x02C4, MKKinectVersionKinectV2, "Kinect v2 (Preview/Dev)" },
    { 0x02D8, MKKinectVersionKinectV2, "Kinect v2 (Production)" },
    { 0x02D9, MKKinectVersionKinectV2, "Kinect v2 (Variant)" },
};

static const int kKnownKinectsCount = sizeof(kKnownKinects) / sizeof(kKnownKinects[0]);

// Frame dimensions
static const int kColorWidth = 1920;
static const int kColorHeight = 1080;
static const int kColorBytes = kColorWidth * kColorHeight * 4; // BGRX
static const int kDepthWidth = 512;
static const int kDepthHeight = 424;
static const int kDepthFloats = kDepthWidth * kDepthHeight;

// MARK: - MKDetectedKinect

@implementation MKDetectedKinect
@end

// MARK: - KinectV2Bridge

@interface KinectV2Bridge () {
    libfreenect2::Freenect2 *_freenect2;
    libfreenect2::Freenect2Device *_device;
    libfreenect2::SyncMultiFrameListener *_listener;

    NSThread *_frameThread;
    BOOL _running;

    NSLock *_frameLock;
    unsigned char *_colorBuffer;
    float *_depthBuffer;
    BOOL _hasNewColor;
    BOOL _hasNewDepth;

    NSString *_serialNumber;
    NSString *_firmwareVersion;
}
@end

@implementation KinectV2Bridge

// MARK: USB Detection (IOKit)

+ (NSArray<MKDetectedKinect *> *)detectConnectedKinects {
    NSMutableArray<MKDetectedKinect *> *results = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seenVersions = [NSMutableSet set];

    CFMutableDictionaryRef matchDict = IOServiceMatching("IOUSBHostDevice");
    if (!matchDict) return results;

    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iter);
    if (kr != KERN_SUCCESS) return results;

    io_service_t service;
    while ((service = IOIteratorNext(iter)) != 0) {
        CFNumberRef vendorRef = (CFNumberRef)IORegistryEntryCreateCFProperty(
            service, CFSTR("idVendor"), kCFAllocatorDefault, 0);
        CFNumberRef productRef = (CFNumberRef)IORegistryEntryCreateCFProperty(
            service, CFSTR("idProduct"), kCFAllocatorDefault, 0);
        CFStringRef nameRef = (CFStringRef)IORegistryEntryCreateCFProperty(
            service, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);

        int vendor = 0, product = 0;
        if (vendorRef) {
            CFNumberGetValue(vendorRef, kCFNumberIntType, &vendor);
            CFRelease(vendorRef);
        }
        if (productRef) {
            CFNumberGetValue(productRef, kCFNumberIntType, &product);
            CFRelease(productRef);
        }

        if (vendor == 0x045e) {
            // Microsoft USB device — check against known Kinect IDs
            for (int i = 0; i < kKnownKinectsCount; i++) {
                if (kKnownKinects[i].productId == product) {
                    MKKinectVersion ver = kKnownKinects[i].version;
                    // Only add one entry per version (v1 has multiple sub-devices)
                    if (![seenVersions containsObject:@(ver)]) {
                        [seenVersions addObject:@(ver)];
                        MKDetectedKinect *dk = [[MKDetectedKinect alloc] init];
                        dk.version = ver;
                        dk.usbProductId = product;
                        if (nameRef) {
                            dk.name = (__bridge NSString *)nameRef;
                        } else {
                            dk.name = [NSString stringWithUTF8String:kKnownKinects[i].name];
                        }
                        [results addObject:dk];
                    }
                    break;
                }
            }
        }

        if (nameRef) CFRelease(nameRef);
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);

    return results;
}

// MARK: Lifecycle

- (instancetype)init {
    self = [super init];
    if (self) {
        _freenect2 = new libfreenect2::Freenect2();
        _frameLock = [[NSLock alloc] init];
        _colorBuffer = (unsigned char *)calloc(kColorBytes, 1);
        _depthBuffer = (float *)calloc(kDepthFloats, sizeof(float));
        _running = NO;
    }
    return self;
}

- (void)dealloc {
    [self closeDevice];
    if (_freenect2) {
        delete _freenect2;
        _freenect2 = nullptr;
    }
    free(_colorBuffer);
    free(_depthBuffer);
}

- (int)enumerateDevices {
    if (!_freenect2) return 0;
    return _freenect2->enumerateDevices();
}

- (BOOL)openDevice:(int)index {
    if (!_freenect2) return NO;

    _device = _freenect2->openDevice(index);
    if (!_device) return NO;

    _serialNumber = [NSString stringWithUTF8String:_device->getSerialNumber().c_str()];
    _firmwareVersion = [NSString stringWithUTF8String:_device->getFirmwareVersion().c_str()];

    return YES;
}

- (BOOL)startStreaming {
    if (!_device || _running) return NO;

    unsigned int types = libfreenect2::Frame::Color | libfreenect2::Frame::Depth;
    _listener = new libfreenect2::SyncMultiFrameListener(types);

    _device->setColorFrameListener(_listener);
    _device->setIrAndDepthFrameListener(_listener);

    if (!_device->start()) {
        delete _listener;
        _listener = nullptr;
        return NO;
    }

    _running = YES;
    _isStreaming = YES;
    _frameThread = [[NSThread alloc] initWithTarget:self
                                           selector:@selector(frameLoop)
                                             object:nil];
    _frameThread.name = @"KinectV2FrameLoop";
    _frameThread.qualityOfService = NSQualityOfServiceUserInteractive;
    [_frameThread start];

    return YES;
}

- (void)frameLoop {
    libfreenect2::FrameMap frames;

    while (_running) {
        if (!_listener->waitForNewFrame(frames, 1000)) {
            continue;
        }

        libfreenect2::Frame *color = frames[libfreenect2::Frame::Color];
        libfreenect2::Frame *depth = frames[libfreenect2::Frame::Depth];

        [_frameLock lock];
        if (color && color->data) {
            memcpy(_colorBuffer, color->data, kColorBytes);
            _hasNewColor = YES;
        }
        if (depth && depth->data) {
            memcpy(_depthBuffer, depth->data, kDepthFloats * sizeof(float));
            _hasNewDepth = YES;
        }
        [_frameLock unlock];

        _listener->release(frames);
    }
}

- (void)stopStreaming {
    if (!_running) return;
    _running = NO;

    // Wait for frame thread to exit
    while (_frameThread && !_frameThread.finished) {
        [NSThread sleepForTimeInterval:0.05];
    }
    _frameThread = nil;

    if (_device) {
        _device->stop();
    }
    if (_listener) {
        delete _listener;
        _listener = nullptr;
    }
    _isStreaming = NO;
}

- (void)closeDevice {
    [self stopStreaming];
    if (_device) {
        _device->close();
        _device = nullptr;
    }
    _serialNumber = nil;
    _firmwareVersion = nil;
}

// MARK: Frame Access

- (BOOL)copyColorFrame:(unsigned char *)outBuffer {
    [_frameLock lock];
    BOOL hasNew = _hasNewColor;
    if (hasNew) {
        memcpy(outBuffer, _colorBuffer, kColorBytes);
        _hasNewColor = NO;
    }
    [_frameLock unlock];
    return hasNew;
}

- (BOOL)copyDepthFrame:(float *)outBuffer {
    [_frameLock lock];
    BOOL hasNew = _hasNewDepth;
    if (hasNew) {
        memcpy(outBuffer, _depthBuffer, kDepthFloats * sizeof(float));
        _hasNewDepth = NO;
    }
    [_frameLock unlock];
    return hasNew;
}

@end
