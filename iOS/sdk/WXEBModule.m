//
//  WXEBModule.m
//  Core
//
//  Created by 对象 on 2017/8/1.
//  Copyright © 2017年 taobao. All rights reserved.
//


#import "WXEBModule.h"
#import <WeexSDK/WeexSDK.h>
#import "WXExpressionHandler.h"
#import <pthread/pthread.h>
#import <WeexPluginLoader/WeexPluginLoader.h>

@interface WXEBModule ()

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, WXExpressionHandler *> *> *sourceMap;

@end

@implementation WXEBModule {
    pthread_mutex_t mutex;
}

@synthesize weexInstance;

WX_PlUGIN_EXPORT_MODULE(binding, WXEBModule)
WX_EXPORT_METHOD(@selector(prepare:))
WX_EXPORT_METHOD_SYNC(@selector(bind:callback:))
WX_EXPORT_METHOD(@selector(unbind:))
WX_EXPORT_METHOD(@selector(unbindAll))
WX_EXPORT_METHOD_SYNC(@selector(supportFeatures))
WX_EXPORT_METHOD_SYNC(@selector(getComputedStyle:))

- (instancetype)init {
    if (self = [super init]) {
        pthread_mutex_init(&mutex, NULL);
    }
    return self;
}

- (void)dealloc {
    [self unbindAll];
    pthread_mutex_destroy(&mutex);
}

- (void)prepare:(NSDictionary *)dictionary {
    if (!dictionary) {
        WX_LOG(WXLogFlagWarning, @"prepare params error, need json input");
        return;
    }
    
    NSString *anchor = dictionary[@"anchor"];
    NSString *eventType = dictionary[@"eventType"];
    
    if ([WXUtility isBlankString:anchor] || [WXUtility isBlankString:eventType]) {
        WX_LOG(WXLogFlagWarning, @"prepare binding params error");
        return;
    }
    
    WXExpressionType exprType = [WXExpressionHandler stringToExprType:eventType];
    if (exprType == WXExpressionTypeUndefined) {
        WX_LOG(WXLogFlagWarning, @"prepare binding eventType error");
        return;
    }
    
    __weak typeof(self) welf = self;
    WXPerformBlockOnComponentThread(^{
        // find sourceRef & targetRef
        WXComponent *sourceComponent = [weexInstance componentForRef:anchor];
        if (!sourceComponent && (exprType == WXExpressionTypePan || exprType == WXExpressionTypeScroll)) {
            WX_LOG(WXLogFlagWarning, @"prepare binding can't find component");
            return;
        }
        
        pthread_mutex_lock(&mutex);
        
        WXExpressionHandler *handler = [welf handlerForToken:anchor expressionType:exprType];
        if (!handler) {
            // create handler for key
            handler = [WXExpressionHandler handlerWithExpressionType:exprType WXInstance:welf.weexInstance source:sourceComponent];
            [welf putHandler:handler forToken:anchor expressionType:exprType];
        }
        
        pthread_mutex_unlock(&mutex);
    });
    
}

- (NSDictionary *)bind:(NSDictionary *)dictionary
          callback:(WXKeepAliveCallback)callback {
    
    if (!dictionary) {
        WX_LOG(WXLogFlagWarning, @"bind params error, need json input");
        return nil;
    }
    
    NSString *eventType =  dictionary[@"eventType"];
    NSArray *targetExpression = dictionary[@"props"];
    NSString *token = dictionary[@"anchor"];
    NSString *exitExpression = dictionary[@"exitExpression"];
    NSDictionary *options = dictionary[@"options"];
    
    if ([WXUtility isBlankString:eventType] || !targetExpression || targetExpression.count == 0) {
        WX_LOG(WXLogFlagWarning, @"bind params error");
        callback(@{@"state":@"error",@"msg":@"bind params error"}, NO);
        return nil;
    }
    
    WXExpressionType exprType = [WXExpressionHandler stringToExprType:eventType];
    if (exprType == WXExpressionTypeUndefined) {
        WX_LOG(WXLogFlagWarning, @"bind params handler error");
        callback(@{@"state":@"error",@"msg":@"bind params handler error"}, NO);
        return nil;
    }
    
    if ([WXUtility isBlankString:token]){
        if ((exprType == WXExpressionTypePan || exprType == WXExpressionTypeScroll)) {
            WX_LOG(WXLogFlagWarning, @"bind params handler error");
            callback(@{@"state":@"error",@"msg":@"anchor cannot be blank when type is pan or scroll"}, NO);
            return nil;
        } else {
            token = [[NSUUID UUID] UUIDString];
        }
    }
    
    __weak typeof(self) welf = self;
    WXPerformBlockOnComponentThread(^{
        
        // find sourceRef & targetRef
        WXComponent *sourceComponent = nil;
        NSString *instanceId = dictionary[@"instanceId"];
        if (instanceId) {
            WXSDKInstance *instance = [WXSDKManager instanceForID:instanceId];
            sourceComponent = [instance componentForRef:token];
        } else {
            sourceComponent = [weexInstance componentForRef:token];
        }
        if (!sourceComponent && (exprType == WXExpressionTypePan || exprType == WXExpressionTypeScroll)) {
            WX_LOG(WXLogFlagWarning, @"bind can't find source component");
            callback(@{@"state":@"error",@"msg":@"bind can't find source component"}, NO);
            return;
        }
        
        NSMapTable<NSString *, WXComponent *> *weakMap = [NSMapTable strongToWeakObjectsMapTable];
        NSMutableDictionary<NSString *, NSDictionary *> *expressionDic = [NSMutableDictionary dictionary];
        for (NSDictionary *targetDic in targetExpression) {
            NSString *targetRef = targetDic[@"element"];
            NSString *property = targetDic[@"property"];
            NSString *expression = targetDic[@"expression"];
            NSString *instanceId = targetDic[@"instanceId"];
            
            WXComponent *targetComponent = nil;
            if (instanceId) {
                WXSDKInstance *instance = [WXSDKManager instanceForID:instanceId];
                targetComponent = [instance componentForRef:targetRef];
            } else {
                targetComponent = [weexInstance componentForRef:targetRef];
            }
            if (targetComponent) {
                
                if ([targetComponent isViewLoaded]) {
                    WXPerformBlockOnMainThread(^{
                        [targetComponent.view.layer removeAllAnimations];
                    });
                }
                
                [weakMap setObject:targetComponent forKey:targetRef];
                NSMutableDictionary *propertyDic = [expressionDic[targetRef] mutableCopy];
                if (!propertyDic) {
                    propertyDic = [NSMutableDictionary dictionary];
                }
                NSMutableDictionary *expDict = [NSMutableDictionary dictionary];
                expDict[@"expression"] = expression;
                if( targetDic[@"config"] )
                {
                    expDict[@"config"] = targetDic[@"config"];
                }
                propertyDic[property] = expDict;
                expressionDic[targetRef] = propertyDic;
            }
        }
        
        // find handler for key
        pthread_mutex_lock(&mutex);
        
        WXExpressionHandler *handler = [welf handlerForToken:token expressionType:exprType];
        if (!handler) {
            // create handler for key
            handler = [WXExpressionHandler handlerWithExpressionType:exprType WXInstance:self.weexInstance source:sourceComponent];
            [welf putHandler:handler forToken:token expressionType:exprType];
        }
        
        [handler updateTargets:weakMap
                    expression:expressionDic
                  options:options
                exitExpression:exitExpression
                      callback:callback];
        
        pthread_mutex_unlock(&mutex);
    });
    return  [NSDictionary dictionaryWithObject:token forKey:@"token"];
}

- (void)unbind:(NSDictionary *)dictionary {
    
    if (!dictionary) {
        WX_LOG(WXLogFlagWarning, @"unbind params error, need json input");
        return;
    }
    NSString* token = dictionary[@"token"];
    NSString* eventType = dictionary[@"eventType"];
    
    if ([WXUtility isBlankString:token] || [WXUtility isBlankString:eventType]) {
        WX_LOG(WXLogFlagWarning, @"disableBinding params error");
        return;
    }
    
    WXExpressionType exprType = [WXExpressionHandler stringToExprType:eventType];
    if (exprType == WXExpressionTypeUndefined) {
        WX_LOG(WXLogFlagWarning, @"disableBinding params handler error");
        return;
    }
    
    pthread_mutex_lock(&mutex);
    
    WXExpressionHandler *handler = [self handlerForToken:token expressionType:exprType];
    if (!handler) {
        WX_LOG(WXLogFlagWarning, @"disableBinding can't find handler handler");
        return;
    }
    
    [handler removeExpressionBinding];
    [self removeHandler:handler forToken:token expressionType:exprType];
    
    pthread_mutex_unlock(&mutex);
}

- (void)unbindAll {
    pthread_mutex_lock(&mutex);
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"WXExpressionBindingRemove" object:nil];
    [self.sourceMap removeAllObjects];
    
    pthread_mutex_unlock(&mutex);
}

- (NSArray *)supportFeatures {
    return @[@"pan",@"scroll",@"orientation",@"timing"];
}

- (NSDictionary *)getComputedStyle:(NSString *)sourceRef {
    if ([WXUtility isBlankString:sourceRef]) {
        WX_LOG(WXLogFlagWarning, @"createBinding params error");
        return nil;
    }
    
    __block NSMutableDictionary *styles = [NSMutableDictionary new];
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    WXPerformBlockOnComponentThread(^{
        // find sourceRef & targetRef
        WXComponent *sourceComponent = [weexInstance componentForRef:sourceRef];
        if (!sourceComponent) {
            WX_LOG(WXLogFlagWarning, @"createBinding can't find source component");
            return;
        }
        WXPerformBlockSyncOnMainThread(^{
            CALayer *layer = sourceComponent.view.layer;
            styles[@"translateX"] = [self transformFactor:@"transform.translation.x" layer:layer];
            styles[@"translateY"] = [self transformFactor:@"transform.translation.y" layer:layer];
            styles[@"scaleX"] = [self transformFactor:@"transform.scale.x" layer:layer];
            styles[@"scaleY"] = [self transformFactor:@"transform.scale.y" layer:layer];
            styles[@"rotateX"] = [self transformFactor:@"transform.rotation.x" layer:layer];
            styles[@"rotateY"] = [self transformFactor:@"transform.rotation.y" layer:layer];
            styles[@"rotateZ"] = [self transformFactor:@"transform.rotation.z" layer:layer];
            styles[@"opacity"] = [layer valueForKeyPath:@"opacity"];
            
            styles[@"background-color"] = [self colorAsString:layer.backgroundColor];;
            if ([sourceComponent isKindOfClass:NSClassFromString(@"WXTextComponent")]) {
                Ivar ivar = class_getInstanceVariable(NSClassFromString(@"WXTextComponent"), "_color");
                UIColor *color = (UIColor *)object_getIvar(sourceComponent, ivar);
                if (color) {
                    styles[@"color"] = [self colorAsString:color.CGColor];
                }
            }
            
            dispatch_semaphore_signal(semaphore);
        });
    });
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return styles;
}

- (NSNumber *)transformFactor:(NSString *)key layer:(CALayer* )layer {
    CGFloat factor = [WXUtility defaultPixelScaleFactor];
    id value = [layer valueForKeyPath:key];
    if(value){
        return [NSNumber numberWithDouble:([value doubleValue] / factor)];
    }
    return nil;
}

- (NSString *)colorAsString:(CGColorRef)cgColor
{
    const CGFloat *components = CGColorGetComponents(cgColor);
    return [NSString stringWithFormat:@"rgba(%d,%d,%d,%f)", (int)(components[0]*255), (int)(components[1]*255), (int)(components[2]*255), components[3]];
}


#pragma mark - Handler Map
- (NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, WXExpressionHandler *> *> *)sourceMap {
    if (!_sourceMap) {
        _sourceMap = [NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, WXExpressionHandler *> *> dictionary];
    }
    return _sourceMap;
}

- (NSMutableDictionary<NSNumber *, WXExpressionHandler *> *)handlerMapForToken:(NSString *)token {
    return [self.sourceMap objectForKey:token];
}

- (WXExpressionHandler *)handlerForToken:(NSString *)token expressionType:(WXExpressionType)exprType {
    return [[self handlerMapForToken:token] objectForKey:[NSNumber numberWithInteger:exprType]];
}

- (void)putHandler:(WXExpressionHandler *)handler forToken:(NSString *)token expressionType:(WXExpressionType)exprType {
    NSMutableDictionary<NSNumber *, WXExpressionHandler *> *handlerMap = [self handlerMapForToken:token];
    if (!handlerMap) {
        handlerMap = [NSMutableDictionary<NSNumber *, WXExpressionHandler *> dictionary];
        self.sourceMap[token] = handlerMap;
    }
    handlerMap[[NSNumber numberWithInteger:exprType]] = handler;
}

- (void)removeHandler:(WXExpressionHandler *)handler forToken:(NSString *)token expressionType:(WXExpressionType)exprType {
    NSMutableDictionary<NSNumber *, WXExpressionHandler *> *handlerMap = [self handlerMapForToken:token];
    if (handlerMap) {
        [handlerMap removeObjectForKey:[NSNumber numberWithInteger:exprType]];
    }
}


@end
