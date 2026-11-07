// MacGlass - Objective-C bridge to the librashader C API (Metal runtime).
// SPDX-License-Identifier: GPL-3.0-only
//
// librashader is loaded at runtime through librashader_ld.h. That header opens
// "librashader.dylib" from the default search path; MacGlass ships the library inside
// the app bundle, so dlopen is redirected to the absolute path given to +loadLibraryAtPath:.

#import "LibraBridge.h"
#include <dlfcn.h>

static void *mg_librashader_dlopen(const char *name, int mode);
#define dlopen(path, mode) mg_librashader_dlopen(path, mode)
#ifndef LIBRA_RUNTIME_METAL
#define LIBRA_RUNTIME_METAL
#endif
#include "librashader_ld.h"
#undef dlopen

static char gLibraryPath[4096];
static libra_instance_t gInstance;
static BOOL gLoaded = NO;

static void *mg_librashader_dlopen(const char *name, int mode) {
    (void)name;
    if (gLibraryPath[0] == 0) {
        return NULL;
    }
    return dlopen(gLibraryPath, mode);
}

/// Converts a librashader error into a string and frees it. Returns nil for "no error".
static NSString *MGTakeError(libra_error_t err) {
    if (err == NULL) {
        return nil;
    }
    NSString *message = @"Unknown librashader error";
    char *text = NULL;
    if (gInstance.error_write(err, &text) == 0 && text != NULL) {
        message = [NSString stringWithUTF8String:text] ?: message;
        gInstance.error_free_string(&text);
    }
    gInstance.error_free(&err);
    return message;
}

@implementation MGShaderParameter
@end

@implementation MGLibrashader

+ (NSString *)loadLibraryAtPath:(NSString *)path {
    if (gLoaded) {
        return nil;
    }
    const char *fs = path.fileSystemRepresentation;
    if (fs == NULL || strlen(fs) >= sizeof(gLibraryPath)) {
        return @"Invalid librashader path.";
    }
    strncpy(gLibraryPath, fs, sizeof(gLibraryPath) - 1);
    void *probe = dlopen(gLibraryPath, RTLD_LAZY);
    if (probe == NULL) {
        const char *why = dlerror();
        return [NSString stringWithFormat:@"Could not load librashader (%@): %s", path, why ? why : "unknown error"];
    }
    gInstance = librashader_load_instance();
    if (gInstance.instance_abi_version() != LIBRASHADER_CURRENT_ABI) {
        return [NSString stringWithFormat:@"librashader ABI mismatch: library has ABI %zu, MacGlass was built for ABI %d.",
                                          (size_t)gInstance.instance_abi_version(), LIBRASHADER_CURRENT_ABI];
    }
    if (!gInstance.instance_loaded) {
        return @"librashader could not be loaded (missing functions).";
    }
    gLoaded = YES;
    return nil;
}

+ (BOOL)isLoaded {
    return gLoaded;
}

+ (NSUInteger)abiVersion {
    return gLoaded ? (NSUInteger)gInstance.instance_abi_version() : 0;
}

+ (NSUInteger)apiVersion {
    return gLoaded ? (NSUInteger)gInstance.instance_api_version() : 0;
}

@end

@implementation MGFilterChain {
    libra_mtl_filter_chain_t _chain;
}

/// Loads a preset for the Metal runtime.
static NSString *MGLoadPreset(NSString *path, libra_shader_preset_t *outPreset) {
    libra_preset_ctx_t ctx = NULL;
    NSString *error = MGTakeError(gInstance.preset_ctx_create(&ctx));
    if (error != nil) {
        return error;
    }
    gInstance.preset_ctx_set_runtime(&ctx, LIBRA_PRESET_CTX_RUNTIME_METAL);
    gInstance.preset_ctx_set_core_name(&ctx, "MacGlass");

    libra_preset_opt_t options;
    memset(&options, 0, sizeof(options));
    options.version = LIBRASHADER_CURRENT_VERSION;
    options.original_aspect_uniforms = false;
    options.frametime_uniforms = true;

    // The context is consumed by this call.
    return MGTakeError(gInstance.preset_create_with_options(path.fileSystemRepresentation, &ctx, &options, outPreset));
}

/// Reads the runtime parameters of a loaded preset. Must be called before the filter chain is
/// created, because the chain takes ownership of the preset.
static NSArray<MGShaderParameter *> *MGReadParameters(libra_shader_preset_t *preset) {
    NSMutableArray<MGShaderParameter *> *result = [NSMutableArray array];
    // Some presets (e.g. crt-geom-deluxe) make this call fail without touching the list:
    // start from a zeroed list and only free it when the call succeeded.
    libra_preset_param_list_t list;
    memset(&list, 0, sizeof(list));
    libra_error_t err = gInstance.preset_get_runtime_params(preset, &list);
    if (err != NULL) {
        NSLog(@"MacGlass: could not read shader parameters: %@", MGTakeError(err));
        return result;
    }
    for (uint64_t i = 0; i < list.length && list.parameters != NULL; i++) {
        const libra_preset_param_t *p = &list.parameters[i];
        MGShaderParameter *param = [MGShaderParameter new];
        param.name = p->name ? ([NSString stringWithUTF8String:p->name] ?: @"") : @"";
        param.label = p->description ? ([NSString stringWithUTF8String:p->description] ?: param.name) : param.name;
        param.initial = p->initial;
        param.minimum = p->minimum;
        param.maximum = p->maximum;
        param.step = p->step;
        [result addObject:param];
    }
    gInstance.preset_free_runtime_params(list);
    return result;
}

+ (NSArray<MGShaderParameter *> *)parametersOfPresetAtPath:(NSString *)path error:(NSString **)error {
    if (!gLoaded) {
        if (error) *error = @"librashader is not loaded.";
        return nil;
    }
    libra_shader_preset_t preset = NULL;
    NSString *loadError = MGLoadPreset(path, &preset);
    if (loadError != nil) {
        if (error) *error = loadError;
        return nil;
    }
    NSArray *params = MGReadParameters(&preset);
    gInstance.preset_free(&preset);
    return params;
}

+ (instancetype)chainWithPresetPath:(NSString *)path
                              queue:(id<MTLCommandQueue>)queue
                         parameters:(NSArray<MGShaderParameter *> **)parameters
                              error:(NSString **)error {
    if (!gLoaded) {
        if (error) *error = @"librashader is not loaded.";
        return nil;
    }
    libra_shader_preset_t preset = NULL;
    NSString *loadError = MGLoadPreset(path, &preset);
    if (loadError != nil) {
        if (error) *error = loadError;
        return nil;
    }

    NSArray *params = MGReadParameters(&preset);

    filter_chain_mtl_opt_t options;
    memset(&options, 0, sizeof(options));
    options.version = LIBRASHADER_CURRENT_VERSION;
    options.force_no_mipmaps = false;

    libra_mtl_filter_chain_t chain = NULL;
    // Takes ownership of the preset, also on failure.
    NSString *chainError = MGTakeError(gInstance.mtl_filter_chain_create(&preset, queue, &options, &chain));
    if (chainError != nil || chain == NULL) {
        if (error) *error = chainError ?: @"The filter chain could not be created.";
        return nil;
    }

    MGFilterChain *result = [MGFilterChain new];
    result->_chain = chain;
    if (parameters) *parameters = params;
    return result;
}

- (BOOL)renderWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                     frameCount:(NSUInteger)frameCount
                          input:(id<MTLTexture>)input
                         output:(id<MTLTexture>)output
                   framesPerSec:(float)fps
                 frameTimeDelta:(uint32_t)frameTimeDelta
                          error:(NSString **)error {
    if (_chain == NULL) {
        if (error) *error = @"No filter chain.";
        return NO;
    }
    frame_mtl_opt_t opt;
    memset(&opt, 0, sizeof(opt));
    opt.version = LIBRASHADER_CURRENT_VERSION;
    opt.clear_history = false;
    opt.frame_direction = 1;
    opt.rotation = 0;
    opt.total_subframes = 1;
    opt.current_subframe = 1;
    opt.aspect_ratio = 0;
    opt.frames_per_second = fps;
    opt.frametime_delta = frameTimeDelta;

    libra_viewport_t viewport;
    viewport.x = 0;
    viewport.y = 0;
    viewport.width = (uint32_t)output.width;
    viewport.height = (uint32_t)output.height;

    // ABI 2: the viewport is passed as a pointer after the output texture.
    NSString *frameError = MGTakeError(
        gInstance.mtl_filter_chain_frame(&_chain, commandBuffer, frameCount, input, output, &viewport, NULL, &opt));
    if (frameError != nil) {
        if (error) *error = frameError;
        return NO;
    }
    return YES;
}

- (BOOL)setParameter:(NSString *)name value:(float)value {
    if (_chain == NULL) {
        return NO;
    }
    libra_error_t err = gInstance.mtl_filter_chain_set_param(&_chain, name.UTF8String, value);
    if (err != NULL) {
        MGTakeError(err);
        return NO;
    }
    return YES;
}

- (void)dealloc {
    if (_chain != NULL) {
        gInstance.mtl_filter_chain_free(&_chain);
        _chain = NULL;
    }
}

@end
