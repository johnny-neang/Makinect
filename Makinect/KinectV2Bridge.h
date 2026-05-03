#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MKKinectVersion) {
    MKKinectVersionNone = 0,
    MKKinectVersionKinectV1 = 1,
    MKKinectVersionKinectV2 = 2,
};

/// Represents a Kinect device detected on the USB bus
@interface MKDetectedKinect : NSObject
@property (nonatomic) MKKinectVersion version;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) int usbProductId;
@end

/// Bridge to libfreenect2 for Kinect v2 streaming, plus USB detection for all versions
@interface KinectV2Bridge : NSObject

/// Scan USB bus for any connected Kinect devices (v1 and v2)
+ (NSArray<MKDetectedKinect *> *)detectConnectedKinects;

/// Number of Kinect v2 devices found by libfreenect2
- (int)enumerateDevices;

/// Open a Kinect v2 device by index
- (BOOL)openDevice:(int)index;

/// Start both color (1920x1080 BGRX) and depth (512x424 float mm) streams
- (BOOL)startStreaming;

/// Stop streaming
- (void)stopStreaming;

/// Close device and free resources
- (void)closeDevice;

/// Copy latest color frame. Buffer must be at least 1920*1080*4 bytes. Returns YES if new frame.
- (BOOL)copyColorFrame:(unsigned char *)outBuffer;

/// Copy latest depth frame. Buffer must be at least 512*424*sizeof(float) bytes. Returns YES if new frame.
- (BOOL)copyDepthFrame:(float *)outBuffer;

/// Copy latest IR frame. Buffer must be at least 512*424*sizeof(float) bytes. Returns YES if new frame.
- (BOOL)copyIRFrame:(float *)outBuffer;

/// Copy registered depth aligned to color camera. Buffer must be at least 1920*1082*sizeof(float) bytes.
/// Output is 1920x1082 (one blank row top/bottom per libfreenect2 convention). Returns YES if new frame.
- (BOOL)copyRegisteredDepthFrame:(float *)outBuffer;

@property (nonatomic, readonly) BOOL isStreaming;
@property (nonatomic, readonly, nullable) NSString *serialNumber;
@property (nonatomic, readonly, nullable) NSString *firmwareVersion;

@end

NS_ASSUME_NONNULL_END
