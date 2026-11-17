// Objective-C wrapper over the linko-core typed message bodies
// (include/linko/messages.hpp): one class per protocol v1 body with typed
// properties, canonical JSON for building envelopes and a validating parser
// for reading them. session.ping and session.pong carry empty bodies and
// therefore have no class, mirroring the core. Every parse failure returns
// nil plus an NSError carrying the first core ValidationError's path and
// message; no C++ exception ever crosses the boundary.

#import <Foundation/Foundation.h>

#import "LKFileTransfer.h"

NS_ASSUME_NONNULL_BEGIN

/// Domain of the typed-body parse errors.
FOUNDATION_EXPORT NSString * const LKBodyErrorDomain;

/// userInfo keys of LKBodyErrorDomain errors: the JSON path (e.g. "body.sdp")
/// and the message (e.g. "missing") of the first validation problem.
FOUNDATION_EXPORT NSString * const LKBodyErrorPathKey;
FOUNDATION_EXPORT NSString * const LKBodyErrorMessageKey;

/// The typed body is not valid for its message type.
typedef NS_ERROR_ENUM(LKBodyErrorDomain, LKBodyErrorCode){
    LKBodyErrorInvalid = 1,
};

// --- session family ---

/// Body of session.hello.
@interface LKSessionHello : NSObject
@property (nonatomic, readonly, copy) NSString *user;
@property (nonatomic, readonly, copy) NSString *device;

- (instancetype)initWithUser:(NSString *)user device:(NSString *)device NS_DESIGNATED_INITIALIZER;

/// The body as canonical JSON, produced by the core's toBody().
@property (nonatomic, readonly, copy) NSString *bodyJSON;

/// linko::SessionHello::fromBody; nil plus an LKBodyErrorDomain error when the
/// body does not validate.
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Body of session.error.
@interface LKSessionError : NSObject
@property (nonatomic, readonly, copy) NSString *code;
@property (nonatomic, readonly, copy) NSString *detail;

- (instancetype)initWithCode:(NSString *)code detail:(NSString *)detail NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// --- presence family ---

/// Body of presence.changed.
@interface LKPresenceChanged : NSObject
@property (nonatomic, readonly, copy) NSString *user;
@property (nonatomic, readonly) BOOL online;

- (instancetype)initWithUser:(NSString *)user online:(BOOL)online NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// --- call family ---

/// Body of call.invite; media is "audio" or "video".
@interface LKCallInvite : NSObject
@property (nonatomic, readonly, copy) NSString *callId;
@property (nonatomic, readonly, copy) NSString *to;
@property (nonatomic, readonly, copy) NSString *media;

- (instancetype)initWithCallId:(NSString *)callId to:(NSString *)to media:(NSString *)media NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Body of call.ringing, call.accept and call.ice-restart.
@interface LKCallRef : NSObject
@property (nonatomic, readonly, copy) NSString *callId;

- (instancetype)initWithCallId:(NSString *)callId NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Body of call.offer and call.answer.
@interface LKCallSdp : NSObject
@property (nonatomic, readonly, copy) NSString *callId;
@property (nonatomic, readonly, copy) NSString *sdp;

- (instancetype)initWithCallId:(NSString *)callId sdp:(NSString *)sdp NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Body of call.ice.
@interface LKCallIce : NSObject
@property (nonatomic, readonly, copy) NSString *callId;
@property (nonatomic, readonly, copy) NSString *candidate;
@property (nonatomic, readonly, copy) NSString *sdpMid;
@property (nonatomic, readonly) int sdpMLineIndex;

- (instancetype)initWithCallId:(NSString *)callId
                     candidate:(NSString *)candidate
                        sdpMid:(NSString *)sdpMid
                 sdpMLineIndex:(int)sdpMLineIndex NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Body of call.reject, call.cancel, call.hangup and call.busy; reason is nil
/// when the body omits it.
@interface LKCallEnd : NSObject
@property (nonatomic, readonly, copy) NSString *callId;
@property (nonatomic, readonly, nullable, copy) NSString *reason;

- (instancetype)initWithCallId:(NSString *)callId reason:(nullable NSString *)reason NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// --- msg family ---

/// File metadata for a transferred file; nested under "file" in msg.send and
/// message records. transport is "p2p" or "server"; fileId is the lowercase
/// hex file id string.
@interface LKFileMeta : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) int64_t size;
@property (nonatomic, readonly, copy) NSString *sha256;
@property (nonatomic, readonly, copy) NSString *transport;
@property (nonatomic, readonly, copy) NSString *fileId;

- (instancetype)initWithName:(NSString *)name
                        size:(int64_t)size
                      sha256:(NSString *)sha256
                   transport:(NSString *)transport
                      fileId:(NSString *)fileId NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// A stored chat message; nested under "message" in msg.deliver bodies.
/// identifier is the wire field "id".
@interface LKMessageRecord : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *from;
@property (nonatomic, readonly, copy) NSString *to;
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly, nullable, strong) LKFileMeta *file;
@property (nonatomic, readonly) int64_t seq;
@property (nonatomic, readonly) int64_t ts;

- (instancetype)initWithIdentifier:(NSString *)identifier
                              from:(NSString *)from
                                to:(NSString *)to
                              text:(NSString *)text
                              file:(nullable LKFileMeta *)file
                              seq:(int64_t)seq
                               ts:(int64_t)ts NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Body of msg.send; file is nil when the body omits it.
@interface LKMsgSend : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *to;
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly, nullable, strong) LKFileMeta *file;

- (instancetype)initWithIdentifier:(NSString *)identifier
                                to:(NSString *)to
                              text:(NSString *)text
                              file:(nullable LKFileMeta *)file NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Body of msg.stored.
@interface LKMsgStored : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly) int64_t seq;
@property (nonatomic, readonly) int64_t ts;

- (instancetype)initWithIdentifier:(NSString *)identifier seq:(int64_t)seq ts:(int64_t)ts NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Body of msg.deliver.
@interface LKMsgDeliver : NSObject
@property (nonatomic, readonly, strong) LKMessageRecord *message;

- (instancetype)initWithMessage:(LKMessageRecord *)message NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Body of msg.ack-delivered and msg.ack-read.
@interface LKMsgAck : NSObject
@property (nonatomic, readonly, copy) NSString *conversation;
@property (nonatomic, readonly) int64_t uptoSeq;

- (instancetype)initWithConversation:(NSString *)conversation uptoSeq:(int64_t)uptoSeq NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Body of msg.sync.
@interface LKMsgSync : NSObject
@property (nonatomic, readonly, copy) NSString *conversation;
@property (nonatomic, readonly) int64_t afterSeq;

- (instancetype)initWithConversation:(NSString *)conversation afterSeq:(int64_t)afterSeq NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// --- file family (in-call transfers; metadata only, bytes go over the data
// channel) ---

/// Body of file.offer: the call and file ids plus the transfer manifest.
@interface LKFileOffer : NSObject
@property (nonatomic, readonly, copy) NSString *callId;
@property (nonatomic, readonly, copy) NSString *fileId;
@property (nonatomic, readonly, strong) LKFileManifest *manifest;

- (instancetype)initWithCallId:(NSString *)callId
                        fileId:(NSString *)fileId
                      manifest:(LKFileManifest *)manifest NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Body of file.accept.
@interface LKFileAccept : NSObject
@property (nonatomic, readonly, copy) NSString *callId;
@property (nonatomic, readonly, copy) NSString *fileId;

- (instancetype)initWithCallId:(NSString *)callId fileId:(NSString *)fileId NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Body of file.cancel.
@interface LKFileCancel : NSObject
@property (nonatomic, readonly, copy) NSString *callId;
@property (nonatomic, readonly, copy) NSString *fileId;
@property (nonatomic, readonly, copy) NSString *reason;

- (instancetype)initWithCallId:(NSString *)callId fileId:(NSString *)fileId reason:(NSString *)reason NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly, copy) NSString *bodyJSON;
+ (nullable instancetype)fromBodyJSONString:(NSString *)bodyJSON
                                      error:(NSError **)error NS_SWIFT_NAME(from(bodyJSON:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
