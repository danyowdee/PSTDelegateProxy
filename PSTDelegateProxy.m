//
// PSTDelegateProxy.m
//
// Copyright (c) 2013 Peter Steinberger (http://petersteinberger.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "PSTDelegateProxy.h"
#import <objc/runtime.h>
#import <libkern/OSAtomic.h>

typedef struct {
    size_t length;
    struct objc_method_description *firstDescription;
} method_description_list;

/// Helper function that walks the inheritance chain of a protocol, and builds a SEL => NSMethodSignature* map for all optional methods — either direct or inherited.
static CFDictionaryRef CopySignatureCacheForProtocol(Protocol *proto);

@interface PSTYESDefaultingDelegateProxy : PSTDelegateProxy @end

@implementation PSTDelegateProxy {
    CFDictionaryRef _cache;
    Protocol *_protocol;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSObject

- (id)initWithDelegate:(id)delegate forProtocol:(Protocol *)protocol {
    return [self initWithDelegate:delegate protocol:protocol forceCreation:NO];
}

- (id)initWithDelegate:(id)delegate protocol:(Protocol *)protocol forceCreation:(BOOL)forceCreation {
    NSParameterAssert(protocol);
    if (!delegate && !forceCreation) return nil; // Exit early if delegate is nil.
    if (self) {
        _delegate = delegate;
        _protocol = protocol;
        _cache = CopySignatureCacheForProtocol(protocol);
    }

    return self;
}

- (void)dealloc
{
    CFRelease(_cache);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ (Proxy for protocol %s): %p delegate:%@>", self.class, protocol_getName(_protocol), self, self.delegate];
}

- (BOOL)respondsToSelector:(SEL)selector {
    return [self.delegate respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    id delegate = self.delegate;
    return [delegate respondsToSelector:selector] ? delegate : self;
}

// Required for delegates that don't implement certain methods.
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return CFDictionaryGetValue(_cache, sel);
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    // ignore
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public

- (instancetype)YESDefault {
    // When we create a proxy delegate with a different return type, we need to force creation.
    // Else we would return NO in the end.
    return [[PSTYESDefaultingDelegateProxy alloc] initWithDelegate:self.delegate protocol:_protocol forceCreation:YES];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - PSTYESDelegateProxy

@implementation PSTYESDefaultingDelegateProxy

- (void)forwardInvocation:(NSInvocation *)invocation {
    // If method is a BOOL, return YES.
    if (strncmp(invocation.methodSignature.methodReturnType, @encode(BOOL), 1) == 0) {
        BOOL retValue = YES;
        [invocation setReturnValue:&retValue];
    }
}

@end


#pragma mark - Helper Functions:

static const size_t s_methodSize = sizeof(struct objc_method_description);

static inline void AppendMethodsFromDescriptionsToList(struct objc_method_description *methods, size_t methodCount, method_description_list list, BOOL freeWhenDone)
{
    if (!methods)
        return;

    if (!methodCount) {
        if (freeWhenDone)
            free(methods);

        return;
    }

    NSCAssert(list.firstDescription, @"list must have contain an allocated buffer that can be resized using realloc() as firstDescription!");
    const size_t offset = list.length;
    list.length += methodCount;
    list.firstDescription = realloc(list.firstDescription, list.length * s_methodSize);
    memcpy(list.firstDescription + offset, methods, methodCount * s_methodSize);

    if (freeWhenDone)
        free(methods);
}

static inline method_description_list CopyAllMethodDescriptionsForProtocol(Protocol *proto)
{
    // Make sure we can realloc() our list in AppendMethodsFromDescriptionsToList()
    method_description_list list = {.firstDescription = calloc(1, s_methodSize)};

    Protocol *__unsafe_unretained*inheritedProtocols = protocol_copyProtocolList(proto, NULL);
    if (inheritedProtocols) {
        Protocol *parent, *__unsafe_unretained*pointer = inheritedProtocols;
        while ((parent = *(pointer++))) {
            method_description_list methods = CopyAllMethodDescriptionsForProtocol(parent);
            AppendMethodsFromDescriptionsToList(methods.firstDescription, methods.length, list, YES);
        }

        free(inheritedProtocols);
    }

    size_t methodCount = 0;
    struct objc_method_description *firstDescription = protocol_copyMethodDescriptionList(proto, NO, YES, (unsigned int *)&methodCount);
    AppendMethodsFromDescriptionsToList(firstDescription, methodCount, list, YES);

    return list;
}

static CFDictionaryRef CopySignatureCacheForProtocol(Protocol *proto)
{
    method_description_list methods = CopyAllMethodDescriptionsForProtocol(proto);
    CFMutableDictionaryRef mutableSignatureCache = CFDictionaryCreateMutable(kCFAllocatorDefault, methods.length, NULL, &kCFTypeDictionaryValueCallBacks);
    for (struct objc_method_description *description = methods.firstDescription; description != NULL; description++) {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:description->types];
        CFDictionarySetValue(mutableSignatureCache, description->name, (__bridge void *)signature);
    }

    CFDictionaryRef cache = CFDictionaryCreateCopy(kCFAllocatorDefault, mutableSignatureCache);
    CFRelease(mutableSignatureCache);
    if (methods.length)
        free(methods.firstDescription);

    return cache;
}
