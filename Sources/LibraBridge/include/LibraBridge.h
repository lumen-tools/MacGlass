// MacGlass - Objective-C bridge to the librashader C API (Metal runtime).
// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// A shader parameter as reported by librashader.
@interface MGShaderParameter : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *label;
@property (nonatomic) float initial;
@property (nonatomic) float minimum;
@property (nonatomic) float maximum;
@property (nonatomic) float step;
@end

/// Loads librashader.dylib (through librashader_ld.h) and checks its ABI.
@interface MGLibrashader : NSObject
/// Load the library from an absolute path. Returns nil on success, or an error message.
+ (nullable NSString *)loadLibraryAtPath:(NSString *)path NS_SWIFT_NAME(loadLibrary(path:));
+ (BOOL)isLoaded;
+ (NSUInteger)abiVersion;
+ (NSUInteger)apiVersion;
@end

/// A librashader Metal filter chain.
///
/// The Metal runtime is not thread-safe: create, render and release a chain on one serial queue.
/// Only -setParameter:value: may be called from any thread.
@interface MGFilterChain : NSObject

/// Loads a preset, reads its parameters (before the chain takes ownership of the preset) and
/// creates the filter chain. Returns nil and sets `error` on failure.
+ (nullable instancetype)chainWithPresetPath:(NSString *)path
                                       queue:(id<MTLCommandQueue>)queue
                                  parameters:(NSArray<MGShaderParameter *> *_Nullable *_Nullable)parameters
                                       error:(NSString *_Nullable *_Nullable)error
    NS_SWIFT_NAME(make(presetPath:queue:parameters:error:));

/// Reads only the parameters of a preset (no filter chain is created).
+ (nullable NSArray<MGShaderParameter *> *)parametersOfPresetAtPath:(NSString *)path
                                                              error:(NSString *_Nullable *_Nullable)error
    NS_SWIFT_NAME(parameters(presetPath:error:));

/// Records the passes into `commandBuffer` (which must not contain other commands).
- (BOOL)renderWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                     frameCount:(NSUInteger)frameCount
                          input:(id<MTLTexture>)input
                         output:(id<MTLTexture>)output
                   framesPerSec:(float)fps
                  frameTimeDelta:(uint32_t)frameTimeDelta
                          error:(NSString *_Nullable *_Nullable)error
    NS_SWIFT_NAME(render(commandBuffer:frameCount:input:output:framesPerSec:frameTimeDelta:error:));

/// Thread-safe.
- (BOOL)setParameter:(NSString *)name value:(float)value NS_SWIFT_NAME(setParameter(_:value:));

@end

NS_ASSUME_NONNULL_END
