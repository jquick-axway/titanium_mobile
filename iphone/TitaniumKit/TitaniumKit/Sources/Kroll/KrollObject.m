/**
 * Appcelerator Titanium Mobile
 * Copyright (c) 2009-Present by Appcelerator, Inc. All Rights Reserved.
 * Licensed under the terms of the Apache Public License
 * Please see the LICENSE included with this distribution for details.
 */
#import "KrollObject.h"
#import "KrollBridge.h"
#import "KrollCallback.h"
#import "KrollContext.h"
#import "KrollMethod.h"
#import "KrollMethodDelegate.h"
#import "KrollPropertyDelegate.h"
#import "TiBindingTiValue.h"
#import "TiExceptionHandler.h"
#import <objc/runtime.h>

#import "TiApp.h"

JSClassRef KrollObjectClassRef = NULL;
JSClassRef JSObjectClassRef = NULL;

/*
 *	Since JSStringRefs are not tied to any particular context, and are
 *	immutable, they are threadsafe and more importantly, ones that are in
 *	constant use never need to garbage collected, but can be reused.
 */

JSStringRef kTiStringGetTime;
JSStringRef kTiStringLength;
JSStringRef kTiStringTiPropertyKey;
JSStringRef kTiStringPropertyKey;
JSStringRef kTiStringEventKey;
JSStringRef kTiStringExportsKey;

id TiValueToId(KrollContext *context, JSValueRef v);

//
// function to determine if the object passed is a JS Date
//
BOOL IsDateLike(JSContextRef jsContext, JSObjectRef object, JSValueRef *v)
{
  BOOL result = NO;
  if (JSObjectHasProperty(jsContext, object, kTiStringGetTime)) {
    JSValueRef fn = JSObjectGetProperty(jsContext, object, kTiStringGetTime, NULL);
    JSObjectRef fnObj = JSValueToObject(jsContext, fn, NULL);
    if (JSObjectIsFunction(jsContext, fnObj)) {
      *v = JSObjectCallAsFunction(jsContext, fnObj, object, 0, NULL, NULL);
      result = YES;
    }
  }
  return result;
}

//
// function for converting a JSValueRef into a NSDictionary*
//
NSDictionary *TiValueToDict(KrollContext *context, JSValueRef value)
{
  return TiBindingTiValueToNSDictionary([context context], value);
}

//
// function for converting a JSValueRef into a JSON string as NSString*
//
NSString *TiValueToJSON(KrollContext *context, JSValueRef value)
{
  return [TiUtils jsonStringify:TiValueToId(context, value)];
}

//
// function for converting a JSValueRef into an NSObject* (as ID)
//
id TiValueToId(KrollContext *context, JSValueRef v)
{
  return TiBindingTiValueToNSObject([context context], v);
}

/*!
 * Converts given array of JSValue objects to an array of NSObjects.
 * This method should be used to convert [JSContext currentArguments] when a proxy's method has been called.
 * @param jsContext JavaScript context needed to read the given JSValue objects.
 * @param jsArgs JSValue array received from JavaScript when a proxy's method has been called.
 * @result Returns a new array of NSObject derived types. Returns nil if given an empty/nil array.
 */
NSArray *TiNativeArgsFromJSArgs(JSContext *jsContext, NSArray *jsArgs)
{
  NSMutableArray *nativeArgs = nil;
  if (jsContext && jsArgs && ([jsArgs count] > 0)) {
    nativeArgs = [[[NSMutableArray alloc] initWithCapacity:[jsArgs count]] autorelease];
    for (JSValue *jsValue in jsArgs) {
      id valueId = TiBindingTiValueToNSObject([jsContext JSGlobalContextRef], [jsValue JSValueRef]);
      [nativeArgs addObject:(valueId ? valueId : [NSNull null])];
    }
  }
  return nativeArgs;
}

//
// function for converting a TiValue to an NSObject* (as ID)
//
JSValueRef ConvertIdTiValue(KrollContext *context, id obj)
{
  return TiBindingTiValueFromNSObject([context context], obj);
}

BOOL IsKindOfTiProxy(Class class)
{
  Class tiProxyClass = [TiProxy class];
  for (; class; class = class_getSuperclass(class)) {
    if (class == tiProxyClass) {
      return YES;
    }
  }
  return NO;
}

//
// callback for handling finalization (in JS land)
//
void KrollFinalizer(JSObjectRef ref)
{
  id o = (id)JSObjectGetPrivate(ref);

  if ((o == nil) || [o isKindOfClass:[KrollContext class]]) {
    return;
  }
  if (![o isKindOfClass:[KrollObject class]]) {
    DeveloperLog(@"[WARN] Object %@ was not a KrollObject during finalization, was: %@", o, [o class]);
    return;
  }
#if KOBJECT_MEMORY_DEBUG == 1
  NSLog(@"[KROLL DEBUG] KROLL FINALIZER: %@, retain:%d", o, [o retainCount]);
#endif

  [(KrollObject *)o setFinalized:YES];
  if ([o isMemberOfClass:[KrollObject class]]) {
    KrollBridge *ourBridge = [(KrollObject *)o bridge];
    if ([KrollBridge krollBridgeExists:ourBridge]) {
      TiProxy *ourTarget = [o target];
      if ((ourTarget != nil) && ([ourBridge krollObjectForProxy:ourTarget] == o)) {
        [ourBridge unregisterProxy:ourTarget];
      }
    }
  }

  [o release];
  o = nil;
}

bool KrollDeleteProperty(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName, JSValueRef *exception)
{
  id o = (id)JSObjectGetPrivate(object);
  if ([o isKindOfClass:[KrollObject class]]) {
    NSString *name = (NSString *)JSStringCopyCFString(kCFAllocatorDefault, propertyName);
    [o deleteKey:name];
    [o forgetObjectForTiString:propertyName context:ctx];

    [name release];
  }
  return true;
}

//
// callback for handling creation (in JS land)
//
void KrollInitializer(JSContextRef ctx, JSObjectRef object)
{
  id o = (id)JSObjectGetPrivate(object);
  if ([o isKindOfClass:[KrollContext class]]) {
    return;
  }
#if KOBJECT_MEMORY_DEBUG == 1
  NSLog(@"[KROLL DEBUG] KROLL RETAINER: %@ (%@), retain:%d", o, [o class], [o retainCount]);
#endif

  if ([o isKindOfClass:[KrollObject class]]) {
    [o retain];
  } else {
    DeveloperLog(@"[DEBUG] Initializer for %@", [o class]);
  }
}

bool KrollHasProperty(JSContextRef jsContext, JSObjectRef object, JSStringRef propertyName)
{
  // Debugger may actually try to get properties off global Kroll property (which is a special case KrollContext singleton)
  id privateObject = (id)JSObjectGetPrivate(object);
  if ([privateObject isKindOfClass:[KrollContext class]]) {
    return false;
  }

  if (JSStringIsEqual(propertyName, kTiStringTiPropertyKey)) {
    return false;
  }

  KrollObject *o = (KrollObject *)privateObject;
  JSObjectRef exports = [o objectForTiString:kTiStringExportsKey context:jsContext];
  if ((exports != NULL) && JSObjectHasProperty(jsContext, exports, propertyName)) {
    return true;
  }

  NSString *name = (NSString *)JSStringCopyCFString(kCFAllocatorDefault, propertyName);
  [name autorelease];

  // Let prototype chain handle property detection if defined.
  if ([o hasPropertyInPrototype:name]) {
    return false;
  }

  return [o hasProperty:name];
}

//
// callback for handling retrieving an objects property (in JS land)
//

//TODO: We should fetch from the props object and shortcut some of this. Especially now that callbacks are CURRENTLY write-only.
JSValueRef KrollGetProperty(JSContextRef jsContext, JSObjectRef object, JSStringRef prop, JSValueRef *exception)
{
  // Debugger may actually try to get properties off global Kroll property (which is a special case KrollContext singleton)
  id privateObject = (id)JSObjectGetPrivate(object);
  if ([privateObject isKindOfClass:[KrollContext class]]) {
    return NULL;
  }

  KrollObject *o = (KrollObject *)privateObject;
  @try {
    if (JSStringIsEqual(prop, kTiStringTiPropertyKey)) {
      return NULL;
    }

    // Attempt to retrieve the property from the exports, before going through
    // the routing
    JSObjectRef exports = [o objectForTiString:kTiStringExportsKey context:jsContext];
    if ((exports != NULL) && JSObjectHasProperty(jsContext, exports, prop)) {
      return JSObjectGetProperty(jsContext, exports, prop, NULL);
    }

    NSString *name = (NSString *)JSStringCopyCFString(kCFAllocatorDefault, prop);
    [name autorelease];

    // Fetch given property from prototype chain if defined.
    if ([o hasPropertyInPrototype:name]) {
      return NULL;
    }

    // Fetch property value directory from proxy.
    id nativeResult = [o valueForKey:name];
#if KOBJECT_DEBUG == 1
    NSLog(@"[KROLL DEBUG] KROLL GET PROPERTY: %@=%@", name, result);
#endif

    // Convert above result to a JS value and return it.
    JSValueRef jsResultRef = [o jsValueFrom:nativeResult forKey:name];
    [o noteObject:jsResultRef forKey:name isGetter:YES wrappingObject:nativeResult];
    return jsResultRef;
  }
  @catch (NSException *ex) {
    *exception = [KrollObject toValue:[o context] value:ex];
  }
  return JSValueMakeUndefined(jsContext);
}

//
// callback for handling a setter (in JS land)
//
bool KrollSetProperty(JSContextRef jsContext, JSObjectRef object, JSStringRef prop, JSValueRef value, JSValueRef *exception)
{
  id privateObject = (id)JSObjectGetPrivate(object);
  if ([privateObject isKindOfClass:[KrollContext class]]) {
    return false;
  }

  KrollObject *o = (KrollObject *)privateObject;
  @try {
    if (JSStringIsEqual(prop, kTiStringTiPropertyKey)) {
      return false;
    }
    NSString *name = (NSString *)JSStringCopyCFString(kCFAllocatorDefault, prop);
    [name autorelease];

    // Assign property via class' prototype chain if defined.
    if ([o hasPropertyInPrototype:name]) {
      return false;
    }

    id v = TiValueToId([o context], value);
#if KOBJECT_DEBUG == 1
    NSLog(@"[KROLL DEBUG] KROLL SET PROPERTY: %@=%@ against %@", name, v, o);
#endif
    [o noteObject:value forKey:name isGetter:NO wrappingObject:v];
    TiThreadPerformOnMainThread(
        ^{
          [o setValue:v forKey:name];
        },
        YES);
    return true;
  }
  @catch (NSException *ex) {
    *exception = [KrollObject toValue:[o context] value:ex];
  }
  return false;
}

//
// handle property names which makes the object iterable
//
void KrollPropertyNames(JSContextRef ctx, JSObjectRef object, JSPropertyNameAccumulatorRef propertyNames)
{
  id privateObject = (id)JSObjectGetPrivate(object);
  if ([privateObject isKindOfClass:[KrollContext class]]) {
    return;
  }

  KrollObject *o = (KrollObject *)privateObject;
  if (o) {
    id target = [o target];

    if ([target isKindOfClass:[TiProxy class]]) {
      for (NSString *key in [target allKeys]) {
        JSStringRef value = JSStringCreateWithUTF8CString([key UTF8String]);
        JSPropertyNameAccumulatorAddName(propertyNames, value);
        JSStringRelease(value);
      }
    }
  }
}

//
// support casting
//
bool KrollHasInstance(JSContextRef ctx, JSObjectRef constructor, JSValueRef possibleInstance, JSValueRef *exception)
{
  id privateObject = (id)JSObjectGetPrivate(constructor);
  if ([privateObject isKindOfClass:[KrollContext class]]) {
    return false;
  }

  KrollObject *o1 = (KrollObject *)privateObject;
  if (o1) {
    JSValueRef ex = NULL;
    JSObjectRef objTarget = JSValueToObject(ctx, possibleInstance, &ex);
    if (!ex) {
      KrollObject *o2 = (KrollObject *)JSObjectGetPrivate(objTarget);
      if (o2) {
        id t1 = [o1 target];
        id t2 = [o2 target];
        Class c1 = [t1 class];
        Class c2 = [t2 class];
        Class ti = [TiProxy class];
        while (c1 != c2 && c1 != nil && c2 != nil && c1 != ti && c2 != ti) {
          // if the proxies are the same class, we can cast
          if (c1 == c2) {
            return true;
          }
          // if the target is a kind of class that matches this superclass, we can cast
          if ([t2 isKindOfClass:c1]) {
            return true;
          }
          c1 = [c1 superclass];
          c2 = [c2 superclass];
        }
      }
    }
  }
  return false;
}

@interface KrollObject ()

/**
 Boolean flag indicating whether the underlying JSObjectRef was protected from JSC GC.
 */
@property (nonatomic, assign, getter=isGcSafeguarded) BOOL gcSafeguarded;

@end

@implementation KrollObject

@synthesize finalized, bridge;

+ (void)initialize
{
  if (KrollObjectClassRef == NULL) {
    JSClassDefinition classDef = kJSClassDefinitionEmpty;
    classDef.className = "Object";
    classDef.initialize = KrollInitializer;
    classDef.finalize = KrollFinalizer;
    classDef.hasProperty = KrollHasProperty;
    classDef.setProperty = KrollSetProperty;
    classDef.getProperty = KrollGetProperty;
    classDef.deleteProperty = KrollDeleteProperty;
    classDef.getPropertyNames = KrollPropertyNames;
    classDef.hasInstance = KrollHasInstance;
    KrollObjectClassRef = JSClassCreate(&classDef);

    kTiStringGetTime = JSStringCreateWithUTF8CString("getTime");
    kTiStringLength = JSStringCreateWithUTF8CString("length");
    kTiStringTiPropertyKey = JSStringCreateWithUTF8CString("__TI");
    kTiStringPropertyKey = JSStringCreateWithUTF8CString("__PR");
    kTiStringEventKey = JSStringCreateWithUTF8CString("__EV");
    kTiStringExportsKey = JSStringCreateWithUTF8CString("__EX");
  }
}

+ (JSClassRef)jsClassRef
{
  return KrollObjectClassRef;
}

- (id)initWithTarget:(id)target_ context:(KrollContext *)context_
{
  if (self = [self init]) {
#if DEBUG
    //TODO: See if this actually happens, and if not, remove this extra check.
    if ([(KrollBridge *)[context_ delegate] usesProxy:target_] && [self isMemberOfClass:[KrollObject class]]) {
      DeveloperLog(@"[WARN] Bridge %@ already has target %@!", [context_ delegate], target_);
    }

    if (![context_ isKJSThread]) {
      DeveloperLog(@"[WARN] %@->%@ is being made in a thread not owned by %@.", self, target_, context_);
    }
#endif
    target = [target_ retain];
    context = context_; // don't retain
    jsContext = [context context];
    bridge = (KrollBridge *)[context_ delegate];
    targetable = [target conformsToProtocol:@protocol(KrollTargetable)];

    self.gcSafeguarded = NO;
  }
  return self;
}

- (JSObjectRef)jsobject
{
  if (_jsobject == NULL && !finalized) {
    _jsobject = JSObjectMake(jsContext, [[self class] jsClassRef], self);
  }
  return _jsobject;
}

- (JSObjectRef)propsObject
{
  if (_propsObject == NULL && !finalized) {
    JSObjectRef propsObject = JSObjectMake(jsContext, NULL, NULL);
    JSObjectSetProperty(jsContext, self.jsobject, kTiStringTiPropertyKey, propsObject, kJSPropertyAttributeDontEnum, NULL);
    _propsObject = propsObject;
  }
  return _propsObject;
}

- (BOOL)isEqual:(id)anObject
{
  if ([anObject isKindOfClass:[KrollObject class]]) {
    JSObjectRef ref1 = self.jsobject;
    JSObjectRef ref2 = [(KrollObject *)anObject jsobject];
    return JSValueIsStrictEqual(jsContext, ref1, ref2);
  }
  return NO;
}

- (void)dealloc
{
#if KOBJECT_MEMORY_DEBUG == 1
  NSLog(@"[KROLL DEBUG] DEALLOC KROLLOBJECT: %@", [self description]);
#endif
  RELEASE_TO_NIL(properties);
  RELEASE_TO_NIL(target);
  RELEASE_TO_NIL(statics);
  RELEASE_TO_NIL(innerClasses);
  //	[[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
  [super dealloc];
}

#if KOBJECT_MEMORY_DEBUG == 1
- (id)description
{
  return [NSString stringWithFormat:@"[KROLL DEBUG] KrollObject[%@] held:%d", target, [target retainCount]];
}
#endif

@synthesize context, jsContext;

- (id)target
{
  return target;
}

//
// create a JS JSValueRef from a NSObject* (as ID)
//
+ (JSValueRef)create:(id)object context:(KrollContext *)context
{
  KrollObject *krollObject = [[[KrollObject alloc] initWithTarget:object context:context] autorelease];
  return [krollObject jsobject];
}

//
// convert JSValueRef to ID
//
+ (id)toID:(KrollContext *)context value:(JSValueRef)ref
{
  return TiValueToId(context, ref);
}

+ (id)nonNull:(id)value
{
  if (value == nil || value == [NSNull null]) {
    return nil;
  }
  return value;
}

//
// convert ID to JSValueRef
//
+ (JSValueRef)toValue:(KrollContext *)context value:(id)obj
{
  return ConvertIdTiValue(context, obj);
}

- (NSString *)propercase:(NSString *)name index:(int)index
{
  if (index > 0) {
    NSString *result = [name substringFromIndex:index];
    return [NSString stringWithFormat:@"%@%@", [[result substringToIndex:1] lowercaseString], [result length] > 1 ? [result substringFromIndex:1] : @""];
  } else {
    return [NSString stringWithFormat:@"%@%@", [[name substringToIndex:1] uppercaseString], [name length] > 1 ? [name substringFromIndex:1] : @""];
  }
}

- (NSString *)_propertyGetterSetterKey:(NSString *)key
{
  NSString *newkey = [key substringFromIndex:3];
  return [NSString stringWithFormat:@"%@%@", [[newkey substringToIndex:1] lowercaseString], [newkey length] > 1 ? [newkey substringFromIndex:1] : @""];
}

- (id)convertValueToDelegate:(id)result forKey:(NSString *)key
{
  if ([result isKindOfClass:[KrollMethodDelegate class]]) {
    int argcount = [result args] ? 1 : 0;
    return [[[KrollMethod alloc] initWithTarget:[result target]
                                       selector:[result selector]
                                       argcount:argcount
                                           type:KrollMethodInvoke
                                           name:key
                                        context:[self context]] autorelease];
  } else if ([result isKindOfClass:[KrollPropertyDelegate class]]) {
    KrollPropertyDelegate *d = (KrollPropertyDelegate *)result;
    return [[d target] performSelector:[d selector]];
  }
  return result;
}

- (id)_valueForKey:(NSString *)key
{
  //TODO: need to consult property_getAttributes to make sure we're not hitting readonly, etc. but do this
  //only for non-production builds

  // TODO: We do a significant amount of magic here (set/get routing, and additionally "automatic"
  // get/set based on what we assume the user is doing) that may need to be removed.

  if ([key hasPrefix:@"set"] && ([key length] >= 4) &&
      [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[key characterAtIndex:3]]) {
    // This is PROBABLY a request for an internal setter (either setX('a') or setX('a','b')). But
    // it could also be:
    // * Pulling a user-defined property prefixed with 'set'
    // * Autogenerating a getter/setter
    // In the event of the former, we actually have to actually pull a jump to
    // returning the property's appropriate type, as below in the general case.

    SEL selector;

    NSString *propertyKey = [self _propertyGetterSetterKey:key];
    KrollMethod *result = [[KrollMethod alloc] initWithTarget:target context:[self context]];

    [result setArgcount:1];
    [result setPropertyKey:propertyKey];
    [result setType:KrollMethodSetter];
    [result setUpdatesProperty:[(TiProxy *)target retainsJsObjectForKey:propertyKey]];

    selector = NSSelectorFromString([key stringByAppendingString:@":withObject:"]);
    if ([target respondsToSelector:selector]) {
      [result setArgcount:2];
      [result setSelector:selector];
    } else {
      selector = NSSelectorFromString([key stringByAppendingString:@":"]);
      if ([target respondsToSelector:selector]) {
        // Assume that if there's a getter with same property name, that this is just exposing the property's setter method to JS when it shouldn't be
        if ([target respondsToSelector:NSSelectorFromString(propertyKey)]) {
          // This is the code path for delegating something like Ti.Filesystem.File#setHidden(), see KrollMethod for other cases (when type is KrollMethodPropertySetter, the last option in this if block below)
          // Spit out a deprecation warning to use normal property setter!
          DebugLog(@"[WARN] Automatic setter methods for properties are deprecated in SDK 8.0.0 and will be removed in SDK 10.0.0. Please modify the property in standard JS style: obj.%@ = value; or obj['%@'] = value;", propertyKey, propertyKey);
        }
        [result setSelector:selector];
      } else {
        // Either a custom property, OR a request for an autogenerated setter
        id value = [target valueForKey:key];
        if (value != nil) {
          [result release];
          return [self convertValueToDelegate:value forKey:key];
        } else {
          [result setType:KrollMethodPropertySetter];
          [result setName:propertyKey];
        }
      }
    }

    return [result autorelease]; // we simply return a method delegator  against the target to set the property directly on the target
  } else if ([key hasPrefix:@"get"]) {
    KrollMethod *result = [[KrollMethod alloc] initWithTarget:target context:[self context]];
    NSString *propertyKey = [self _propertyGetterSetterKey:key];
    [result setPropertyKey:propertyKey];
    [result setArgcount:1];
    [result setUpdatesProperty:[(TiProxy *)target retainsJsObjectForKey:propertyKey]];

    //first make sure we don't have a method with the fullname
    SEL fullSelector = NSSelectorFromString([NSString stringWithFormat:@"%@:", key]);
    if ([target respondsToSelector:fullSelector]) {
      [result setSelector:fullSelector];
      [result setType:KrollMethodInvoke];
      return [result autorelease];
    }

    // this is a request for a getter method
    // a.getFoo()
    NSString *partkey = [self propercase:key index:3];
    SEL selector = NSSelectorFromString(partkey);
    if ([target respondsToSelector:selector]) {
      // Spit out a deprecation warning to use normal property accessor!
      // This is the code path for delegating something like Ti.Filesystem.File#getHidden(), see KrollMethod for other cases (when type is KrollMethodPropertyGetter, the last option in this if block below)
      DebugLog(@"[WARN] Automatic getter methods for properties are deprecated in SDK 8.0.0 and will be removed in SDK 10.0.0. Please access the property in standard JS style: obj.%@ or obj['%@']", partkey, partkey);
      [result setSelector:selector];
      [result setType:KrollMethodGetter];
      return [result autorelease];
    }
    // see if its an actual method that takes an arg instead
    selector = NSSelectorFromString([NSString stringWithFormat:@"%@:", partkey]);
    if ([target respondsToSelector:selector]) {
      [result setSelector:selector];
      [result setType:KrollMethodGetter];
      return [result autorelease];
    }

    // Check for custom property before returning the autogenerated getter
    id value = [target valueForKey:key];
    if (value != nil) {
      [result release];
      return [self convertValueToDelegate:value forKey:key];
    }

    [result setName:propertyKey];
    [result setArgcount:0];
    [result setType:KrollMethodPropertyGetter];
    return [result autorelease];
  } else {
    // property accessor - need to determine if its a objc property of method
    objc_property_t p = class_getProperty([target class], [key UTF8String]);
    if (p == NULL) {
      if ([key isEqualToString:@"toString"] || [key isEqualToString:@"valueOf"]) {
        return [[[KrollMethod alloc] initWithTarget:target selector:@selector(toString:) argcount:0 type:KrollMethodInvoke name:nil context:[self context]] autorelease];
      }

      // For something like TiUiTextWidgetProxy focused:(id)unused - this will assume it's a function/method
      // So to work around this, we need to explicitly declare a property named "focused" with a different underlying getter
      // to expose it as a property to JS
      SEL selector = NSSelectorFromString([NSString stringWithFormat:@"%@:", key]);
      if ([target respondsToSelector:selector]) {
        return [[[KrollMethod alloc] initWithTarget:target
                                           selector:selector
                                           argcount:1
                                               type:KrollMethodInvoke
                                               name:nil
                                            context:[self context]] autorelease];
      }
      // Special handling for className due to conflict with NSObject private API
      if ([key isEqualToString:@"className"]) {
        return [target valueForUndefinedKey:key];
      }
      // attempt a function that has no args (basically a non-property property)
      selector = NSSelectorFromString([NSString stringWithFormat:@"%@", key]);
      if ([target respondsToSelector:selector]) {
        return [target performSelector:selector];
      }
      id result = [target valueForKey:key];
      if (result != nil) {
        return [self convertValueToDelegate:result forKey:key];
      }

      // Create and return a JS class constructor if referencing an inner class or create function.
      // For example, "Window" or "createWindow" if this is a "Ti.UI" module.
      JSValue *jsInnerClass = [self getInnerJSClassForApiName:key];
      if (jsInnerClass) {
        if ([key hasPrefix:@"create"] && [jsInnerClass hasProperty:@"_create"]) {
          return jsInnerClass[@"_create"];
        } else {
          return jsInnerClass;
        }
      }
    } else {
      NSString *attributes = [NSString stringWithCString:property_getAttributes(p) encoding:NSUTF8StringEncoding];
      // look up getter name from the property attributes
      SEL selector;
      const char *getterName = property_copyAttributeValue(p, "G");
      if (getterName != nil) {
        selector = sel_getUid(getterName);
      } else {
        // not set, so use the property name
        selector = NSSelectorFromString([NSString stringWithCString:property_getName(p) encoding:NSUTF8StringEncoding]);
      }

      if ([attributes hasPrefix:@"T@"]) {
        // this means its a return type of id
        return [target performSelector:selector];
      } else {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[target methodSignatureForSelector:selector]];
        [invocation setSelector:selector];
        [invocation invokeWithTarget:target];
        if ([attributes hasPrefix:@"Td,"]) {
          double d;
          [invocation getReturnValue:&d];
          return [NSNumber numberWithDouble:d];
        } else if ([attributes hasPrefix:@"Tf,"]) {
          float f;
          [invocation getReturnValue:&f];
          return [NSNumber numberWithFloat:f];
        } else if ([attributes hasPrefix:@"Ti,"]) {
          int i;
          [invocation getReturnValue:&i];
          return [NSNumber numberWithInt:i];
        } else if ([attributes hasPrefix:@"TI,"]) {
          unsigned int ui;
          [invocation getReturnValue:&ui];
          return [NSNumber numberWithUnsignedInt:ui];
        } else if ([attributes hasPrefix:@"Tl,"]) {
          long l;
          [invocation getReturnValue:&l];
          return [NSNumber numberWithLong:l];
        } else if ([attributes hasPrefix:@"TL,"]) {
          unsigned long ul;
          [invocation getReturnValue:&ul];
          return [NSNumber numberWithUnsignedLong:ul];
        } else if ([attributes hasPrefix:@"Tc,"]) {
          char c;
          [invocation getReturnValue:&c];
          return [NSNumber numberWithChar:c];
        } else if ([attributes hasPrefix:@"TC,"]) {
          unsigned char uc;
          [invocation getReturnValue:&uc];
          return [NSNumber numberWithUnsignedChar:uc];
        } else if ([attributes hasPrefix:@"Ts,"]) {
          short s;
          [invocation getReturnValue:&s];
          return [NSNumber numberWithShort:s];
        } else if ([attributes hasPrefix:@"TS,"]) {
          unsigned short us;
          [invocation getReturnValue:&us];
          return [NSNumber numberWithUnsignedShort:us];
        } else if ([attributes hasPrefix:@"Tq,"]) {
          long long ll;
          [invocation getReturnValue:&ll];
          return [NSNumber numberWithLongLong:ll];
        } else if ([attributes hasPrefix:@"TQ,"]) {
          unsigned long long ull;
          [invocation getReturnValue:&ull];
          return [NSNumber numberWithUnsignedLongLong:ull];
        } else if ([attributes hasPrefix:@"TB,"] || [attributes hasPrefix:@"Tb,"]) {
          bool b;
          [invocation getReturnValue:&b];
          return [NSNumber numberWithBool:b];
        } else {
          // let it fall through and return undefined
          DebugLog(@"[WARN] Unsupported property: %@ for %@, attributes = %@", key, target, attributes);
        }
      }
    }
  }
  return nil;
}

- (BOOL)hasProperty:(NSString *)propertyName
{
  if (statics != nil && statics[propertyName] != nil) {
    return YES;
  }

  if (properties != nil && properties[propertyName] != nil) {
    return YES;
  }

  // Check if name references an inner class or create function such as "Ti.UI.Window" or "Ti.UI.createWindow".
  if ([self getInnerJSClassForApiName:propertyName]) {
    return YES;
  }

  if (([propertyName hasPrefix:@"get"] || [propertyName hasPrefix:@"set"]) && (propertyName.length >= 4) &&
      [NSCharacterSet.uppercaseLetterCharacterSet characterIsMember:[propertyName characterAtIndex:3]]) {
    return YES;
  }

  objc_property_t p = class_getProperty([target class], propertyName.UTF8String);
  if (p != NULL) {
    return YES;
  }

  if ([propertyName isEqualToString:@"toString"] || [propertyName isEqualToString:@"valueOf"]) {
    return YES;
  }

  if ([propertyName isEqualToString:@"className"]) {
    return YES;
  }

  SEL selector = NSSelectorFromString([NSString stringWithFormat:@"%@:", propertyName]);
  if ([target respondsToSelector:selector]) {
    return YES;
  }

  selector = NSSelectorFromString([NSString stringWithFormat:@"%@", propertyName]);
  if ([target respondsToSelector:selector]) {
    return YES;
  }

  id result = [target valueForKey:propertyName];
  if (result != nil) {
    return YES;
  }

  return NO;
}

- (BOOL)hasPropertyInPrototype:(NSString *)propertyName
{
  // Fetch the proxy's prototype assigned to hidden a property.
  JSContext *objcContext = [JSContext contextWithJSGlobalContextRef:[self jsContext]];
  JSValue *jsThis = [JSValue valueWithJSValueRef:[self jsobject] inContext:objcContext];
  JSValue *jsObject = objcContext[@"Object"];
  JSValue *jsPrototype = [jsObject invokeMethod:@"getPrototypeOf" withArguments:@[jsThis]];
  JSValue *jsProxyPrototype = jsPrototype[@"_tiProxyPrototype"];
  if (![jsProxyPrototype isObject]) {
    return NO;
  }

  // Check if given property is defined in proxy's prototype. (This does not check the chain.)
  if ([jsProxyPrototype hasProperty:propertyName]) {
    return YES;
  }

  // Check if property is defined in prototype chain. If not, then stop here.
  if (![jsPrototype isObject] || ![jsPrototype hasProperty:propertyName]) {
    return NO;
  }

  // Propert is defined by either a derived JS class or the base JS "Object" class.
  // Define property in proxy's prototype in case it references an API that cannot be found via introspection
  // such as "backgroundColor", "layout", etc. (These property are written to NSObject's dictionary.)
  do {
    NSArray *descriptorArgs = @[jsPrototype, propertyName];
    JSValue *jsDescriptor = [jsObject invokeMethod:@"getOwnPropertyDescriptor" withArguments:descriptorArgs];
    if ([jsDescriptor isObject]) {
      KrollJSCallback callback = [self createJSCallbackForPropertyName:propertyName isMethod:NO];
      if ([jsDescriptor hasProperty:@"value"]) {
        [jsProxyPrototype defineProperty:propertyName descriptor:@{
          JSPropertyDescriptorGetKey: callback,
          JSPropertyDescriptorEnumerableKey: @NO,
          JSPropertyDescriptorConfigurableKey: @YES
        }];
      } else {
        [jsProxyPrototype defineProperty:propertyName descriptor:@{
          JSPropertyDescriptorGetKey: callback,
          JSPropertyDescriptorSetKey: callback,
          JSPropertyDescriptorEnumerableKey: @NO,
          JSPropertyDescriptorConfigurableKey: @YES
        }];
      }
      break;
    }
    jsPrototype = [jsObject invokeMethod:@"getPrototypeOf" withArguments:@[jsPrototype]];
  } while([jsPrototype isObject]);

  // The property is defined in prototype chain.
  return YES;
}

- (JSValue *)getInnerJSClassForApiName:(NSString *)name
{
  // Validate argument.
  if (!name) {
    return nil;
  }

  // Do not continue if this proxy is not a module derived class such as "Ti.UI".
  // This method is only intended to fetch inner clases under a module such as "Ti.UI.Window", "Ti.UI.View", etc.
  if (![target isKindOfClass:[TiModule class]]) {
    return nil;
  }

  // Do not continue unless API name starts with "create*" or an uppercase letter.
  // This is an optimization. Avoids introspection when given lowercase property names.
  NSString *createPrefix = @"create";
  BOOL isCreateFunction = [name hasPrefix:createPrefix];
  if (!isCreateFunction && ![[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[name characterAtIndex:0]]) {
    return nil;
  }

  // Fetch the potential class name from the API name.
  NSString *innerClassName;
  if (isCreateFunction) {
    innerClassName = [name substringFromIndex:createPrefix.length];
  } else {
    innerClassName = name;
  }

  // If this method has already defined a JS class constructor for the given API name, then return it.
  JSValue *jsConstructor = innerClasses ? innerClasses[innerClassName] : nil;
  if (jsConstructor) {
    return jsConstructor;
  }

  // Fetch the native class type for the given API name from module.
  // Will return nil if API does not reference an inner class.
  Class proxyClass = [target getProxyClassForApiName:innerClassName];
  if (!proxyClass) {
    return nil;
  }

  // If inner class implements the "JSExport", then JavaScriptCore will define its constructor and properties for us.
  JSContext *objcContext = [JSContext contextWithJSGlobalContextRef:jsContext];
  if ([proxyClass conformsToProtocol:@protocol(JSExport)]) {
    jsConstructor = [JSValue valueWithObject:proxyClass inContext:objcContext];
    jsConstructor[@"_create"] = ^() {
      // The module's create<Proxy>() method for this inner class was called.
      return [jsConstructor constructWithArguments:[JSContext currentArguments]];
    };
    innerClasses = innerClasses ? innerClasses : [[NSMutableDictionary alloc] initWithCapacity:16];
    innerClasses[innerClassName] = jsConstructor;
    return jsConstructor;
  }

  // Create a JS constructor used to create a native proxy instance.
  jsConstructor = [JSValue valueWithObject: [[^() {
    // The construct or create function was called.
    // Create a native proxy instance with the given JS arguments.
    JSContext *currentContext = [JSContext currentContext];
    @try {
      NSArray *args = TiNativeArgsFromJSArgs(currentContext, [JSContext currentArguments]);
      id proxy = [target createProxy:args forName:innerClassName context:[self bridge]];
      if (proxy && [proxy isKindOfClass:[TiProxy class]]) {
        JSObjectRef jsProxyRef = [[proxy krollObjectForContext:context] jsobject];
        JSValueRef jsPrototypeRef = [innerClasses[innerClassName][@"prototype"] JSValueRef];
        JSObjectSetPrototype(jsContext, jsProxyRef, jsPrototypeRef);
        return [JSValue valueWithJSValueRef:jsProxyRef inContext:currentContext];
      }
    }
    @catch (NSException *ex) {
      JSValueRef jsExceptionRef = TiBindingTiValueFromNSObject(jsContext, ex);
      currentContext.exception = [JSValue valueWithJSValueRef:jsExceptionRef inContext:currentContext];
    }
    return [JSValue valueWithNullInContext:currentContext];
  } copy] autorelease] inContext:objcContext];

  // Create method/property name collections.
  NSMutableSet *methodNameSet = [[NSMutableSet alloc] initWithCapacity:256];
  NSMutableSet *getterPropertyNameSet = [[NSMutableSet alloc] initWithCapacity:256];
  NSMutableSet *setterPropertyNameSet = [[NSMutableSet alloc] initWithCapacity:256];

  // Fetch all methods and properties from the proxy class and its super classes.
  for (Class nextClass = proxyClass; IsKindOfTiProxy(nextClass); nextClass = class_getSuperclass(nextClass)) {
    // Traverse all proxy methods.
    unsigned int methodCount = 0;
    Method *methodArray = class_copyMethodList(nextClass, &methodCount);
    for (unsigned int index = 0; index < methodCount; index++) {
      // Fetch the next native method name from proxy.
      Method method = methodArray[index];
      NSString *methodName = [NSString stringWithUTF8String:sel_getName(method_getName(method))];
      if (!methodName) {
        continue;
      }

      // Check if method has any aguments.
      if (([methodName characterAtIndex:[methodName length] - 1]) == ':') {
        // Only define method in JS class if:
        // - It has only 1 argument.
        // - It has only 2 arguemnts where 2nd arg is named "withObject". Ex: Ti.UI.ScrollView.setContentOffset()
        NSRange range;
        range.location = 0;
        range.length = [methodName length] - 1;
        methodName = [methodName substringWithRange:range];
        if ([methodName hasPrefix:@"set"] && [methodName hasSuffix:@":withObject"]) {
          methodName = [methodName substringToIndex:(methodName.length - @":withObject".length)];
        }
        if ([methodName containsString:@":"]) {
          continue;
        }
        [methodNameSet addObject:methodName];
      } else {
        // A method without arguments and with a return type should be defined as a getter property.
        // If it's a getter, we must add a setter since proxy's target class might have a "set<Property>_()" method.
        char *typeName = method_copyReturnType(method);
        bool isVoid = (!typeName || ((typeName[0] == _C_VOID) && (typeName[1] == '\0')));
        if (!isVoid) {
          [getterPropertyNameSet addObject:methodName];
          if (![methodName isEqualToString:@"apiName"]) {
            [setterPropertyNameSet addObject:methodName];
          }
        }
        free(typeName);
      }

      // If this is a "get*()" or "set*()" method, then add an equivalent property name for it.
      if (methodName.length > 3) {
        if ([methodName hasPrefix:@"get"]) {
          [getterPropertyNameSet addObject:[self _propertyGetterSetterKey:methodName]];
        } else if ([methodName hasPrefix:@"set"]) {
          [setterPropertyNameSet addObject:[self _propertyGetterSetterKey:methodName]];
        }
      }
    }
    free(methodArray);
    methodArray = NULL;

    // Traverse all proxy properties.
    unsigned int propertyCount = 0;
    objc_property_t *propertyArray = class_copyPropertyList(nextClass, &propertyCount);
    for (unsigned int index = 0; index < propertyCount; index++) {
      // Fetch the next property name.
      objc_property_t property = propertyArray[index];
      NSString *propertyName = [NSString stringWithUTF8String:property_getName(property)];
      if (!propertyName) {
        continue;
      }

      // Add property getter to collection. (Objective-C and Swift do not support write-only properties.)
      [getterPropertyNameSet addObject:propertyName];

      // If native property is not flagged read-only, then define a JS property setter for it.
      char *readOnlyString = property_copyAttributeValue(property, "R");
      if (readOnlyString) {
        free(readOnlyString);
      } else {
        [setterPropertyNameSet addObject:propertyName];
      }
    }
    free(propertyArray);
    propertyArray = NULL;
  }

  // Create a "prototype" object and add it to the JS class constructor.
  JSValue *jsPrototype = jsConstructor[@"prototype"];

  // Add hidden property storing this prototype instance.
  [jsPrototype defineProperty:@"_tiProxyPrototype" descriptor:@{
    JSPropertyDescriptorValueKey: jsPrototype,
    JSPropertyDescriptorEnumerableKey: @NO,
    JSPropertyDescriptorWritableKey: @NO,
    JSPropertyDescriptorConfigurableKey: @NO
  }];

  // Add constructor to prototype.
  [jsPrototype defineProperty:@"constructor" descriptor:@{
    JSPropertyDescriptorValueKey: jsConstructor,
    JSPropertyDescriptorEnumerableKey: @NO,
    JSPropertyDescriptorWritableKey: @NO,
    JSPropertyDescriptorConfigurableKey: @NO
  }];

  // Add proxy methods to prototype.
  for (NSString *methodName in methodNameSet) {
    [jsPrototype defineProperty:methodName descriptor:@{
      JSPropertyDescriptorValueKey: [self createJSCallbackForPropertyName:methodName isMethod:YES],
      JSPropertyDescriptorEnumerableKey: @NO,
      JSPropertyDescriptorWritableKey: @NO,
      JSPropertyDescriptorConfigurableKey: @YES
    }];
  }

  // Add proxy getter/setter properties to prototype.
  for (NSString *propertyName in getterPropertyNameSet) {
    KrollJSCallback callback = [self createJSCallbackForPropertyName:propertyName isMethod:NO];
    BOOL hasSetter = [setterPropertyNameSet containsObject:propertyName];
    if (hasSetter) {
      [jsPrototype defineProperty:propertyName descriptor:@{
        JSPropertyDescriptorGetKey: callback,
        JSPropertyDescriptorSetKey: callback,
        JSPropertyDescriptorEnumerableKey: @NO,
        JSPropertyDescriptorConfigurableKey: @YES
      }];
    } else {
      [jsPrototype defineProperty:propertyName descriptor:@{
        JSPropertyDescriptorGetKey: callback,
        JSPropertyDescriptorEnumerableKey: @NO,
        JSPropertyDescriptorConfigurableKey: @YES
      }];
    }
  }

  // Assign prototype to JS constructor object.
  JSObjectRef jsConstructorRef = JSValueToObject(jsContext, [jsConstructor JSValueRef], NULL);
  JSObjectSetPrototype(jsContext, jsConstructorRef, [jsPrototype JSValueRef]);

  // Release method/property name collections.
  [methodNameSet release];
  [getterPropertyNameSet release];
  [setterPropertyNameSet release];

  // Add inner class constructor to dictionary for fast access later.
  innerClasses = innerClasses ? innerClasses : [[NSMutableDictionary alloc] initWithCapacity:16];
  innerClasses[innerClassName] = jsConstructor;

  return jsConstructor;
}

- (KrollJSCallback)createJSCallbackForPropertyName:(NSString *)name isMethod:(BOOL)isMethod
{
  if (!name) {
    return nil;
  }

  KrollJSCallback callback = ^(){
    // Fetch the KrollObject assigned to the JS object being accessed.
    JSContext *currentContext = [JSContext currentContext];
    JSValue *thisValue = [JSContext currentThis];
    JSObjectRef thisObject = thisValue ? JSValueToObject(jsContext, [thisValue JSValueRef], NULL) : NULL;
    id privateObject = thisObject ? (id)JSObjectGetPrivate(thisObject) : nil;
    if (!privateObject || ![privateObject isKindOfClass:[KrollObject class]]) {
      return [JSValue valueWithUndefinedInContext:currentContext];
    }

    // Read the proxy's property or invoke its callback.
    @try {
      // Fetch method arguments or setter value, if applicable.
      NSArray *jsArgsArray = [JSContext currentArguments];
      NSArray *nativeArgsArray = TiNativeArgsFromJSArgs(currentContext, jsArgsArray);

      // Handle the property.
      if (!isMethod && nativeArgsArray && ([nativeArgsArray count] >= 1)) {
        // This is a setter property. Write argument to property.
        JSValueRef jsValueRef = [[jsArgsArray firstObject] JSValueRef];
        id nativeValue = [nativeArgsArray firstObject];
        [privateObject noteObject:jsValueRef forKey:name isGetter:NO wrappingObject:nativeValue];
        TiThreadPerformOnMainThread(^{ [privateObject setValue:nativeValue forKey:name]; }, YES);
      } else {
        // This is a getter property or method. Fetch the property's value/callback.
        id nativeValue = [privateObject valueForKey:name];

        // If a callback was returned, then invoke it immediately and replace above result.
        if (isMethod && nativeValue && [nativeValue isKindOfClass:[KrollMethod class]]) {
          nativeValue = [nativeValue call:nativeArgsArray];
        }

        // Return the property/method's result if provided.
        // Note: To return null to JavaScript, the above must return an [NSNull null] object.
        JSValueRef jsValueRef = [privateObject jsValueFrom:nativeValue forKey:name];
        [privateObject noteObject:jsValueRef forKey:name isGetter:YES wrappingObject:nativeValue];
        if (jsValueRef) {
          return [JSValue valueWithJSValueRef:jsValueRef inContext:currentContext];
        }
      }
    }
    @catch (NSException *ex) {
      // Throw the native exception as a JS exception.
      JSValueRef jsExceptionRef = TiBindingTiValueFromNSObject([currentContext JSGlobalContextRef], ex);
      currentContext.exception = [JSValue valueWithJSValueRef:jsExceptionRef inContext:currentContext];
    }

    // Return undefined if a result was not returned or an exception was thrown.
    return [JSValue valueWithUndefinedInContext:currentContext];
  };
  return [[callback copy] autorelease];
}

- (JSValueRef)jsValueFrom:(id)nativeValue forKey:(NSString *)key
{
  // Fetch the JS context.
  JSContext *objcContext = [JSContext contextWithJSGlobalContextRef:jsContext];

  // If given a JSValue, then return it as-is.
  // Note: This happens for inner classes and create functions such as Ti.UI.Window and Ti.UI.createWindow().
  if ([nativeValue isKindOfClass:[JSValue class]]) {
    return [nativeValue JSValueRef];
  }

  // Native classes implementing JSExport will be automatically convertd to JS classes/instances for us.
  if ([nativeValue conformsToProtocol:@protocol(JSExport)]) {
    return [[JSValue valueWithObject:nativeValue inContext:objcContext] JSValueRef];
  }

  // Handling natively wrapped objects such as JS listeners.
  if ([nativeValue isKindOfClass:[KrollWrapper class]]) {
    if (![KrollBridge krollBridgeExists:[(KrollWrapper *)nativeValue bridge]]) {
      //This remote object no longer exists.
      [self deleteKey:key];
      nativeValue = nil;
    } else {
      return [(KrollWrapper *)nativeValue jsobject];
    }
  }

  // The value is likely a primitive type or proxy instance. Get its JS value equivalent.
  JSValueRef jsValueRef = TiBindingTiValueFromNSObject(jsContext, nativeValue);
  if (!nativeValue) {
    JSValueRef jsValueForUndefinedRef = [self jsvalueForUndefinedKey:key];
    if (!jsValueForUndefinedRef) {
      jsValueRef = jsValueForUndefinedRef;
    }
  }
  if (!jsValueRef) {
    jsValueRef = JSValueMakeUndefined(jsContext);
  }
  return jsValueRef;
}

- (id)valueForKey:(NSString *)key
{
  BOOL executionSet = NO;
  @try {
    // first consult our statics
    if (statics != nil) {
      id result = [statics objectForKey:key];
      if (result != nil) {
        return result;
      }
    }
    // second consult our fixed properties dictionary if we have one
    if (properties != nil) {
      id result = [properties objectForKey:key];
      if (result != nil) {
        return result;
      }
    }
    if (targetable) {
      executionSet = YES;
      [target setExecutionContext:context.delegate];
    }
    id result = [self _valueForKey:key];
    // we can safely cache method objects
    if ([result isKindOfClass:[KrollObject class]]) {
      [self setStaticValue:result forKey:key purgable:YES];
    }
    return result;
  }
  @finally {
    if (executionSet) {
      [target setExecutionContext:nil];
    }
  }
}

- (JSValueRef)jsvalueForUndefinedKey:(NSString *)key
{
  return NULL;
}

- (void)deleteKey:(NSString *)key
{
  [target deleteKey:key];
}

- (void)setValue:(id)value forKey:(NSString *)key
{
  BOOL executionSet = NO;
  if ([target conformsToProtocol:@protocol(KrollTargetable)]) {
    executionSet = YES;
    [target setExecutionContext:context.delegate];
  }

  @try {
    if (value == [NSNull null]) {
      value = nil;
    }

    NSString *name = [self propercase:key index:0];
    SEL selector = NSSelectorFromString([NSString stringWithFormat:@"set%@:withObject:", name]);
    if ([target respondsToSelector:selector]) {
      [target performSelector:selector withObject:value withObject:nil];
      return;
    }
    selector = NSSelectorFromString([NSString stringWithFormat:@"set%@:", name]);
    if ([target respondsToSelector:selector] && ![name isEqualToString:@"ZIndex"]) //TODO: Quick hack is quick.
    {
      [target performSelector:selector withObject:value];
    } else {
      [target setValue:value forKey:key];
    }
  }
  @finally {
    if (executionSet) {
      [target setExecutionContext:nil];
    }
  }
}

- (void)setStaticValue:(id)value forKey:(NSString *)key purgable:(BOOL)purgable
{
  if (purgable) {
    if (properties == nil) {
      properties = [[NSMutableDictionary alloc] initWithCapacity:3];
    }
    [properties setValue:value forKey:key];
  } else {
    if (statics == nil) {
      statics = [[NSMutableDictionary alloc] initWithCapacity:2];
    }
    [statics setValue:value forKey:key];
  }
}

- (void)protectJsobject
{
  if (protecting) {
    return;
  }

  JSContextRef jscontext = [context context];
  if (finalized || (jscontext == NULL) || (self.jsobject == NULL)) {
    return;
  }

  protecting = YES;
  JSValueProtect(jscontext, self.jsobject);
}

- (void)unprotectJsobject
{
  if (!protecting) {
    return;
  }
  JSContextRef jscontext = [context context];
  if (finalized || (jscontext == NULL) || (self.jsobject == NULL)) {
    return;
  }

  protecting = NO;
  JSValueUnprotect(jscontext, self.jsobject);
}

TI_INLINE JSStringRef TiStringCreateWithPointerValue(int value)
{
  /*
	 *	When we note proxies, we need to come up with a property name
	 *	that is unique. We previously did an nsstring with format
	 *	of __PX%X, but this method is so often called, and allocating a string
	 *	can be a waste, so it's better to jump straight to something hardwired
	 *
	 *	No sense in doing hex when so many more characters are valid property
	 *	characters. So we do it in chunks of 6 bits, from '<' (60) to '{' (123)
	 */
  char result[10];
  result[0] = '_';
  result[1] = '_';
  result[2] = ':';
  result[3] = '<' + (value & 0x3F);
  result[4] = '<' + ((value >> 6) & 0x3F);
  result[5] = '<' + ((value >> 12) & 0x3F);
  result[6] = '<' + ((value >> 18) & 0x3F);
  result[7] = '<' + ((value >> 24) & 0x3F);
  result[8] = '<' + ((value >> 30) & 0x3F);
  result[9] = 0;
  return JSStringCreateWithUTF8CString(result);
}

- (void)noteKeylessKrollObject:(KrollObject *)value
{
  if ([value finalized]) {
    return;
  }

  // TODO: Enquing safeProtect here may not be enough to guarantee that the object is actually
  // safely protected "in time" (i.e. it may be GC'd before the safe protect is evaluated
  // by the queue processor). We need to seriously re-evaluate the memory model and thread
  // interactions during such.

  JSStringRef nameRef = TiStringCreateWithPointerValue((int)value);
  [self noteObject:[value jsobject] forTiString:nameRef context:[context context]];
  JSStringRelease(nameRef);
}

- (void)forgetKeylessKrollObject:(KrollObject *)value
{
  JSStringRef nameRef = TiStringCreateWithPointerValue((int)value);
  [self forgetObjectForTiString:nameRef context:[context context]];
  JSStringRelease(nameRef);
}

- (void)noteCallback:(KrollCallback *)eventCallback forKey:(NSString *)key
{
  JSStringRef nameRef = JSStringCreateWithCFString((CFStringRef)key);
  [self noteObject:[eventCallback function] forTiString:nameRef context:[context context]];
  JSStringRelease(nameRef);
}

- (void)forgetCallbackForKey:(NSString *)key
{
  JSStringRef nameRef = JSStringCreateWithCFString((CFStringRef)key);
  [self forgetObjectForTiString:nameRef context:[context context]];
  JSStringRelease(nameRef);
}

- (void)invokeCallbackForKey:(NSString *)key withObject:(NSDictionary *)eventData thisObject:(KrollObject *)thisObject
{
  [self invokeCallbackForKey:key withObject:eventData thisObject:thisObject onDone:nil];
}
- (void)invokeCallbackForKey:(NSString *)key withObject:(NSDictionary *)eventData thisObject:(KrollObject *)thisObject onDone:(void (^)(id result))block
{
  if (finalized) {
    return;
  }

  __block id _thisObject = thisObject;
  void (^mainBlock)(void) = ^{
    if (finalized) {
      return;
    }

    if (![_thisObject isKindOfClass:[KrollObject class]]) {
      _thisObject = [(KrollBridge *)[context delegate] registerProxy:thisObject];
    }

    JSValueRef exception = NULL;

    JSObjectRef jsProxyHash = (JSObjectRef)JSObjectGetProperty(jsContext, self.propsObject, kTiStringPropertyKey, &exception);

    jsProxyHash = JSValueToObject(jsContext, jsProxyHash, &exception);
    if ((jsProxyHash == NULL) || (JSValueGetType(jsContext, jsProxyHash) != kJSTypeObject)) {
      if (block != nil) {
        block(nil);
      }
      return;
    }

    JSStringRef nameRef = JSStringCreateWithCFString((CFStringRef)key);
    JSObjectRef jsCallback = (JSObjectRef)JSObjectGetProperty(jsContext, jsProxyHash, nameRef, NULL);
    JSStringRelease(nameRef);

    if ((jsCallback == NULL) || (JSValueGetType(jsContext, jsCallback) != kJSTypeObject)) {
      if (block != nil) {
        block(nil);
      }
      return;
    }

    JSValueRef jsEventData = ConvertIdTiValue(context, eventData);
    JSValueRef result = JSObjectCallAsFunction(jsContext, jsCallback, [_thisObject jsobject], 1, &jsEventData, &exception);
    if (exception != NULL) {
      [TiExceptionHandler.defaultExceptionHandler reportScriptError:exception inKrollContext:context];
    }

    if (block != nil) {
      block(TiValueToId(context, result));
    };
  };
  TiThreadPerformOnMainThread(mainBlock, NO);
}

- (void)noteKrollObject:(KrollObject *)value forKey:(NSString *)key
{

  if ([value finalized]) {
    return;
  }

  JSStringRef nameRef = JSStringCreateWithCFString((CFStringRef)key);
  [self noteObject:[value jsobject] forTiString:nameRef context:[context context]];
  JSStringRelease(nameRef);
}

- (void)forgetKrollObjectforKey:(NSString *)key;
{
  JSStringRef nameRef = JSStringCreateWithCFString((CFStringRef)key);
  [self forgetObjectForTiString:nameRef context:[context context]];
  JSStringRelease(nameRef);
}

- (void)noteObject:(JSValueRef)jsValueRef forKey:(NSString*)name isGetter:(BOOL)isGetter wrappingObject:(id)nativeObject
{
  if ((self.propsObject == NULL) || finalized || !name) {
    return;
  }

  BOOL shouldNote = NO;
  if (nativeObject && jsValueRef && JSValueIsObject([self jsContext], jsValueRef)) {
    if ([nativeObject isKindOfClass:[TiProxy class]]) {
      shouldNote = YES;
    } else if (isGetter) {
      if ([nativeObject isKindOfClass:[KrollWrapper class]]) {
        shouldNote = YES;
      } else if ([nativeObject isKindOfClass:[KrollObject class]]
                 && ![nativeObject isKindOfClass:[KrollCallback class]]
                 && [[nativeObject target] isKindOfClass:[TiProxy class]]) {
        shouldNote = YES;
      }
    }
  }

  JSStringRef jsNameRef = JSStringCreateWithCFString((CFStringRef)name);
  if (shouldNote) {
    JSObjectRef jsObjectRef = JSValueToObject([self jsContext], jsValueRef, NULL);
    [self noteObject:jsObjectRef forTiString:jsNameRef context:[self jsContext]];
  } else {
    [self forgetObjectForTiString:jsNameRef context:[self jsContext]];
  }
  JSStringRelease(jsNameRef);
}

- (void)noteObject:(JSObjectRef)storedJSObject forTiString:(JSStringRef)keyString context:(JSContextRef)jsContextRef
{
  if ((self.propsObject == NULL) || finalized) {
    return;
  }

  if (storedJSObject == NULL) {
    [self forgetObjectForTiString:keyString context:jsContextRef];
    return;
  }

  JSValueRef exception = NULL;
  JSObjectRef jsProxyHash = (JSObjectRef)JSObjectGetProperty(jsContextRef, self.propsObject, kTiStringPropertyKey, &exception);

  if ((jsProxyHash == NULL) || (JSValueGetType(jsContextRef, jsProxyHash) != kJSTypeObject)) {
    jsProxyHash = JSObjectMake(jsContextRef, NULL, &exception);
    JSObjectSetProperty(jsContextRef, self.propsObject, kTiStringPropertyKey, jsProxyHash,
        kJSPropertyAttributeDontEnum, &exception);
  }

  JSObjectSetProperty(jsContextRef, jsProxyHash, keyString, storedJSObject,
      kJSPropertyAttributeDontEnum, &exception);
}

- (void)forgetObjectForTiString:(JSStringRef)keyString context:(JSContextRef)jsContextRef
{
  if ((self.propsObject == NULL) || finalized) {
    return;
  }
  JSValueRef exception = NULL;

  JSObjectRef jsProxyHash = (JSObjectRef)JSObjectGetProperty(jsContextRef, self.propsObject, kTiStringPropertyKey, &exception);

  if ((jsProxyHash == NULL) || (JSValueGetType(jsContextRef, jsProxyHash) != kJSTypeObject)) {
    return;
  }

  JSObjectDeleteProperty(jsContextRef, jsProxyHash, keyString, &exception);
}

- (JSObjectRef)objectForTiString:(JSStringRef)keyString context:(JSContextRef)jsContextRef
{
  if (finalized) {
    return NULL;
  }

  JSValueRef exception = NULL;

  JSObjectRef jsProxyHash = (JSObjectRef)JSObjectGetProperty(jsContextRef, self.propsObject, kTiStringPropertyKey, &exception);

  if ((jsProxyHash == NULL) || (JSValueGetType(jsContextRef, jsProxyHash) != kJSTypeObject)) {
    return NULL;
  }

  JSObjectRef result = (JSObjectRef)JSObjectGetProperty(jsContextRef, jsProxyHash, keyString, NULL);
  if ((result == NULL) || (JSValueGetType(jsContextRef, result) != kJSTypeObject)) {
    return NULL;
  }

  return result;
}

- (void)storeListener:(id)eventCallbackOrWrapper forEvent:(NSString *)eventName
{
  if ((self.propsObject == NULL) || finalized) {
    return;
  }

  JSValueRef exception = NULL;

  JSValueRef jsEventValue = JSObjectGetProperty(jsContext, self.propsObject, kTiStringEventKey, &exception);

  // Grab event JSObject. Default to NULL if it isn't an object
  JSObjectRef jsEventHash = NULL;
  if (JSValueGetType(jsContext, jsEventValue) == kJSTypeObject) {
    jsEventHash = JSValueToObject(jsContext, jsEventValue, &exception);
  }

  // Value wasn't an object (undefined, likely) - or conversion to JSObjectRef failed
  if (jsEventHash == NULL) {
    jsEventHash = JSObjectMake(jsContext, NULL, &exception);
    JSObjectSetProperty(jsContext, self.propsObject, kTiStringEventKey, jsEventHash,
        kJSPropertyAttributeDontEnum, &exception);
  }

  // Grab the event callback we're adding
  JSObjectRef callbackFunction = nil;
  if ([eventCallbackOrWrapper isKindOfClass:[KrollCallback class]]) {
    callbackFunction = [(KrollCallback *)eventCallbackOrWrapper function];
  } else if ([eventCallbackOrWrapper isKindOfClass:[KrollWrapper class]]) {
    callbackFunction = [(KrollWrapper *)eventCallbackOrWrapper jsobject];
  }

  // Grab the array of callbacks for our event type from global event hash
  JSStringRef jsEventTypeString = JSStringCreateWithCFString((CFStringRef)eventName);
  JSValueRef jsCallbackArrayValue = JSObjectGetProperty(jsContext, jsEventHash, jsEventTypeString, &exception);

  // Default to NULL array object, if value doesn't exist or isn't an object
  JSObjectRef jsCallbackArray = NULL;
  if (JSValueGetType(jsContext, jsCallbackArrayValue) == kJSTypeObject) {
    jsCallbackArray = JSValueToObject(jsContext, jsCallbackArrayValue, &exception);
  }

  // No callback array existed for this event type, or it wasn't an object
  if (jsCallbackArray == NULL) {
    // Make a new array, add the first callback function to it
    jsCallbackArray = JSObjectMakeArray(jsContext, 1, (JSValueRef *)&callbackFunction, &exception);
    // Store the array under the event name in our global event hash
    JSObjectSetProperty(jsContext, jsEventHash, jsEventTypeString, jsCallbackArray,
        kJSPropertyAttributeDontEnum, &exception);
  } else {
    // An array of callbacks already exists for this event type
    // Add the callback to it, unless it's already in the array
    JSValueRef jsCallbackArrayLength = JSObjectGetProperty(jsContext, jsCallbackArray, kTiStringLength, &exception);
    int arrayLength = (int)JSValueToNumber(jsContext, jsCallbackArrayLength, &exception);

    for (uint i = 0; i < arrayLength; ++i) {
      JSValueRef valueRef = JSObjectGetPropertyAtIndex(jsContext, jsCallbackArray, i, NULL);
      if (valueRef == callbackFunction) {
        JSStringRelease(jsEventTypeString);
        return;
      }
    }

    JSObjectSetPropertyAtIndex(jsContext, jsCallbackArray, arrayLength, callbackFunction, &exception);
  }

  //TODO: Call back to the proxy?
  JSStringRelease(jsEventTypeString);
}

- (JSObjectRef)callbacksForEvent:(JSStringRef)jsEventTypeString
{
  if (finalized || (self.propsObject == NULL)) {
    return NULL;
  }

  JSObjectRef jsEventHash = (JSObjectRef)JSObjectGetProperty(jsContext, self.propsObject, kTiStringEventKey, NULL);
  if ((jsEventHash == NULL) || (JSValueGetType(jsContext, jsEventHash) != kJSTypeObject)) { //We did not have any event listeners on this proxy. Perfectly normal.
    return NULL;
  }

  JSObjectRef jsCallbackArray = (JSObjectRef)JSObjectGetProperty(jsContext, jsEventHash, jsEventTypeString, NULL);

  if ((jsCallbackArray == NULL) || (JSValueGetType(jsContext, jsCallbackArray) != kJSTypeObject)) {
    return NULL;
  }

  return jsCallbackArray;
}

- (void)removeListener:(KrollCallback *)eventCallback forEvent:(NSString *)eventName
{
  JSStringRef jsEventTypeString = JSStringCreateWithCFString((CFStringRef)eventName);
  JSObjectRef jsCallbackArray = [self callbacksForEvent:jsEventTypeString];
  JSStringRelease(jsEventTypeString);

  if (jsCallbackArray == NULL) {
    return;
  }

  JSObjectRef callbackFunction = [eventCallback function];

  JSValueRef jsCallbackArrayLength = JSObjectGetProperty(jsContext, jsCallbackArray, kTiStringLength, NULL);
  int arrayLength = (int)JSValueToNumber(jsContext, jsCallbackArrayLength, NULL);

  if (arrayLength < 1) {
    return;
  }

  for (int currentCallbackIndex = 0; currentCallbackIndex < arrayLength; currentCallbackIndex++) {
    JSValueRef currentCallback = JSObjectGetPropertyAtIndex(jsContext, jsCallbackArray, currentCallbackIndex, NULL);
    if (currentCallback == callbackFunction) {
      JSValueRef undefined = JSValueMakeUndefined(jsContext);
      JSObjectSetPropertyAtIndex(jsContext, jsCallbackArray, currentCallbackIndex, undefined, NULL);
    }
  }
}

- (void)triggerEvent:(NSString *)eventName withObject:(NSDictionary *)eventData thisObject:(KrollObject *)thisObject
{
  if (self.propsObject == NULL) {
    return;
  }

  JSStringRef jsEventTypeString = JSStringCreateWithCFString((CFStringRef)eventName);
  JSObjectRef jsCallbackArray = [self callbacksForEvent:jsEventTypeString];
  JSStringRelease(jsEventTypeString);

  if (jsCallbackArray == NULL) {
    return;
  }

  JSValueRef jsCallbackArrayLength = JSObjectGetProperty(jsContext, jsCallbackArray, kTiStringLength, NULL);
  int arrayLength = (int)JSValueToNumber(jsContext, jsCallbackArrayLength, NULL);

  if (arrayLength < 1) {
    return;
  }

  JSValueRef jsEventData = ConvertIdTiValue(context, eventData);

  for (int currentCallbackIndex = 0; currentCallbackIndex < arrayLength; currentCallbackIndex++) {
    JSValueRef currentCallback = JSObjectGetPropertyAtIndex(jsContext, jsCallbackArray, currentCallbackIndex, NULL);
    currentCallback = JSValueToObject(jsContext, currentCallback, NULL);
    if ((currentCallback == NULL) || !JSObjectIsFunction(jsContext, (JSObjectRef)currentCallback)) {
      continue;
    }
    JSValueRef exception = NULL;
    JSObjectCallAsFunction(jsContext, (JSObjectRef)currentCallback, [thisObject jsobject], 1, &jsEventData, &exception);
    if (exception != NULL) {
      [TiExceptionHandler.defaultExceptionHandler reportScriptError:exception inKrollContext:context];
    }
  }
}

/**
 Protects the underlying JSObjectRef from being accidentally GC'ed.
 
 The KrollObject's JSObjectRef is stored on the heap and therefore not automatically
 protected against GC unless it is referenced via a variable on the stack or inside
 the JS object graph!
 
 If JSC's garbage collection runs while the JSObjectRef is not protected it is lost and
 eventually leads to crashes inside the JSC runtime.
 */
- (void)applyGarbageCollectionSafeguard
{
  if (self.isGcSafeguarded == YES) {
    return;
  }

  if (finalized == YES || jsContext == NULL || self.jsobject == NULL) {
    return;
  }

  JSValueProtect(jsContext, self.jsobject);
  self.gcSafeguarded = YES;
}

/**
 Removes the garbage collection safeguard by unprotecting the JSObjectRef again.
 
 This may only be called when the JSObjectRef is referenced on the stack or in the
 JS object graph.
 */
- (void)removeGarbageCollectionSafeguard
{
  if (self.isGcSafeguarded == NO) {
    return;
  }

  if (finalized == YES || jsContext == NULL || self.jsobject == NULL) {
    return;
  }

  JSValueUnprotect(jsContext, self.jsobject);
  self.gcSafeguarded = NO;
}

@end
