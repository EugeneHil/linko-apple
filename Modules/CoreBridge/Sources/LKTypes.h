// LKTypes: the protocol v1 message-type names (include/linko/messages.hpp
// kType* constants) exposed to Swift as static properties. The values come
// from the core at runtime, so the constants stay the single source of truth
// and a core bump flows through without editing this file.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_SENDABLE
@interface LKTypes : NSObject
// session family
@property (class, nonatomic, readonly, copy) NSString *sessionHello;
@property (class, nonatomic, readonly, copy) NSString *sessionPing;
@property (class, nonatomic, readonly, copy) NSString *sessionPong;
@property (class, nonatomic, readonly, copy) NSString *sessionError;
// presence family
@property (class, nonatomic, readonly, copy) NSString *presenceChanged;
// call family
@property (class, nonatomic, readonly, copy) NSString *callInvite;
@property (class, nonatomic, readonly, copy) NSString *callRinging;
@property (class, nonatomic, readonly, copy) NSString *callAccept;
@property (class, nonatomic, readonly, copy) NSString *callReject;
@property (class, nonatomic, readonly, copy) NSString *callBusy;
@property (class, nonatomic, readonly, copy) NSString *callCancel;
@property (class, nonatomic, readonly, copy) NSString *callOffer;
@property (class, nonatomic, readonly, copy) NSString *callAnswer;
@property (class, nonatomic, readonly, copy) NSString *callIce;
@property (class, nonatomic, readonly, copy) NSString *callIceRestart;
@property (class, nonatomic, readonly, copy) NSString *callHangup;
// msg family
@property (class, nonatomic, readonly, copy) NSString *msgSend;
@property (class, nonatomic, readonly, copy) NSString *msgStored;
@property (class, nonatomic, readonly, copy) NSString *msgDeliver;
@property (class, nonatomic, readonly, copy) NSString *msgAckDelivered;
@property (class, nonatomic, readonly, copy) NSString *msgAckRead;
@property (class, nonatomic, readonly, copy) NSString *msgSync;
// file family
@property (class, nonatomic, readonly, copy) NSString *fileOffer;
@property (class, nonatomic, readonly, copy) NSString *fileAccept;
@property (class, nonatomic, readonly, copy) NSString *fileCancel;
// wire limits
/// The envelope size limit (linko::kMaxEnvelopeBytes): frames above it are
/// rejected as oversized before any JSON parsing, client and server alike.
@property (class, nonatomic, readonly) NSUInteger maxEnvelopeBytes;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
