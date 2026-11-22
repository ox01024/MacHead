//
//  VirtualDisplayBridge.h
//  MacHead
//
//  CoreGraphics 私有 CGVirtualDisplay 类声明（macOS 11+，DeskPad / BetterDisplay /
//  vdisplay 等均基于同一私有 API 创建虚拟显示器）。
//  接口声明参照 DeskPad（MIT License, https://github.com/Stengo/DeskPad）。
//

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayMode : NSObject

@property(readonly, nonatomic) CGFloat refreshRate;
@property(readonly, nonatomic) NSUInteger width;
@property(readonly, nonatomic) NSUInteger height;

- (instancetype)initWithWidth:(NSUInteger)arg1 height:(NSUInteger)arg2 refreshRate:(CGFloat)arg3;

@end

@interface CGVirtualDisplaySettings : NSObject

@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;

@end

@interface CGVirtualDisplayDescriptor : NSObject

@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);

- (void)setDispatchQueue:(dispatch_queue_t)queue;

@end

@interface CGVirtualDisplay : NSObject

@property(readonly, nonatomic) CGDirectDisplayID displayID;
@property(readonly, nonatomic) NSString *name;

- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;

@end

NS_ASSUME_NONNULL_END
