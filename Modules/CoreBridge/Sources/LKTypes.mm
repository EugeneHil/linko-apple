// LKTypes implementation: every getter reads the matching kType* constant
// from include/linko/messages.hpp (submodule tag v0.1.0). A class-property
// interface needs an implementation translation unit, so this file exists
// next to the plan's LKTypes.h.

#import "LKTypes.h"

#include <string_view>

#include <linko/envelope.hpp>
#include <linko/messages.hpp>

// The core only produces valid UTF-8, so this conversion is total; on the
// impossible path it yields an empty string instead of nil to honor the
// nonnull properties.
static NSString *NSStringFromStdString(std::string_view value) {
  NSString *converted = [[NSString alloc] initWithBytes:value.data()
                                                 length:value.size()
                                               encoding:NSUTF8StringEncoding];
  return converted ?: @"";
}

#define LK_TYPE_GETTER(property, constant)      \
  + (NSString *)property {                      \
    return NSStringFromStdString(constant);     \
  }

@implementation LKTypes

LK_TYPE_GETTER(sessionHello, linko::kTypeSessionHello)
LK_TYPE_GETTER(sessionPing, linko::kTypeSessionPing)
LK_TYPE_GETTER(sessionPong, linko::kTypeSessionPong)
LK_TYPE_GETTER(sessionError, linko::kTypeSessionError)
LK_TYPE_GETTER(presenceChanged, linko::kTypePresenceChanged)
LK_TYPE_GETTER(callInvite, linko::kTypeCallInvite)
LK_TYPE_GETTER(callRinging, linko::kTypeCallRinging)
LK_TYPE_GETTER(callAccept, linko::kTypeCallAccept)
LK_TYPE_GETTER(callReject, linko::kTypeCallReject)
LK_TYPE_GETTER(callBusy, linko::kTypeCallBusy)
LK_TYPE_GETTER(callCancel, linko::kTypeCallCancel)
LK_TYPE_GETTER(callOffer, linko::kTypeCallOffer)
LK_TYPE_GETTER(callAnswer, linko::kTypeCallAnswer)
LK_TYPE_GETTER(callIce, linko::kTypeCallIce)
LK_TYPE_GETTER(callIceRestart, linko::kTypeCallIceRestart)
LK_TYPE_GETTER(callHangup, linko::kTypeCallHangup)
LK_TYPE_GETTER(msgSend, linko::kTypeMsgSend)
LK_TYPE_GETTER(msgStored, linko::kTypeMsgStored)
LK_TYPE_GETTER(msgDeliver, linko::kTypeMsgDeliver)
LK_TYPE_GETTER(msgAckDelivered, linko::kTypeMsgAckDelivered)
LK_TYPE_GETTER(msgAckRead, linko::kTypeMsgAckRead)
LK_TYPE_GETTER(msgSync, linko::kTypeMsgSync)
LK_TYPE_GETTER(fileOffer, linko::kTypeFileOffer)
LK_TYPE_GETTER(fileAccept, linko::kTypeFileAccept)
LK_TYPE_GETTER(fileCancel, linko::kTypeFileCancel)

+ (NSUInteger)maxEnvelopeBytes {
  return linko::kMaxEnvelopeBytes;
}

@end
