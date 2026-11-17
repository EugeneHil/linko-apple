// Objective-C wrapper over the linko-core call state machine
// (include/linko/call_state_machine.hpp): a pure, total transition table
// from (CallState, CallEvent) to effects. The machine owns no clocks,
// sockets or randomness — timer expiries arrive as events and message sends,
// CallKit reports and ICE restarts leave as effects for the host to execute.
// No C++ exception ever crosses the boundary.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Lifecycle states of one call. Ended is terminal: start a fresh machine in
/// Idle for the next call instead of reviving an ended one.
typedef NS_ENUM(NSInteger, LKCallStateKind) {
    LKCallStateKindIdle,
    LKCallStateKindOutgoingRinging,
    LKCallStateKindIncomingRinging,
    LKCallStateKindConnecting,
    LKCallStateKindActive,
    LKCallStateKindReconnecting,
    LKCallStateKindEnded,
};

/// Why a call ended; meaningful only while kind is ended.
typedef NS_ENUM(NSInteger, LKEndReason) {
    LKEndReasonNormal,
    LKEndReasonBusy,
    LKEndReasonRejected,
    LKEndReasonCancelled,
    LKEndReasonMissed,
    LKEndReasonTimeout,
    LKEndReasonError,
};

/// Snapshot of one call. endReason is meaningful only in the ended state;
/// video records the media mode the call was set up with.
@interface LKCallState : NSObject
@property (nonatomic, readonly) LKCallStateKind kind;
@property (nonatomic, readonly, copy) NSString *callId;
@property (nonatomic, readonly, copy) NSString *peer;
@property (nonatomic, readonly) BOOL video;
@property (nonatomic, readonly) LKEndReason endReason;

- (instancetype)initWithKind:(LKCallStateKind)kind
                      callId:(NSString *)callId
                        peer:(NSString *)peer
                       video:(BOOL)video
                   endReason:(LKEndReason)endReason NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// The fresh machine's state: Idle with no call id, no peer, audio only.
+ (LKCallState *)idle NS_SWIFT_NAME(idle());
@end

/// One input to the machine: a local user action, a remote signaling message,
/// an ICE connection state change or a timer expiry.
typedef NS_ENUM(NSInteger, LKCallEventKind) {
    LKCallEventKindLocalInvite,
    LKCallEventKindLocalAccept,
    LKCallEventKindLocalReject,
    LKCallEventKindLocalCancel,
    LKCallEventKindLocalHangup,
    LKCallEventKindRemoteInvite,
    LKCallEventKindRemoteRinging,
    LKCallEventKindRemoteAccept,
    LKCallEventKindRemoteReject,
    LKCallEventKindRemoteBusy,
    LKCallEventKindRemoteCancel,
    LKCallEventKindRemoteOffer,
    LKCallEventKindRemoteAnswer,
    LKCallEventKindRemoteIce,
    LKCallEventKindRemoteIceRestart,
    LKCallEventKindRemoteHangup,
    LKCallEventKindIceConnected,
    LKCallEventKindIceFailed,
    LKCallEventKindNetworkChanged,
    LKCallEventKindTimerRingExpired,
    LKCallEventKindTimerConnectExpired,
    LKCallEventKindTimerReconnectExpired,
};

@interface LKCallEvent : NSObject
@property (nonatomic, readonly) LKCallEventKind kind;
/// Call the event belongs to. An event whose callId is set and differs from
/// the state's callId is ignored; glare (outgoingRinging + remoteInvite) is
/// the single exception. An empty callId is foreign to every call.
@property (nonatomic, readonly, copy) NSString *callId;
/// Peer username and media mode; read only for invite events.
@property (nonatomic, readonly, copy) NSString *peer;
@property (nonatomic, readonly) BOOL video;

- (instancetype)initWithKind:(LKCallEventKind)kind
                      callId:(NSString *)callId
                        peer:(NSString *)peer
                       video:(BOOL)video NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// One output for the host to execute; the effects of a transition run in
/// order. sendMessage carries the message-type constant in messageType
/// (an LKTypes value); startTimer and cancelTimer carry which timer they
/// address in timeoutMs (a k*TimeoutMs constant); reportEnded carries its
/// end reason in reason.
typedef NS_ENUM(NSInteger, LKEffectKind) {
    LKEffectKindSendMessage,
    LKEffectKindStartRinging,
    LKEffectKindStopRinging,
    LKEffectKindStartTimer,
    LKEffectKindCancelTimer,
    LKEffectKindReportIncoming,
    LKEffectKindReportEnded,
    LKEffectKindStartIceRestart,
};

@interface LKEffect : NSObject
@property (nonatomic, readonly) LKEffectKind kind;
@property (nonatomic, readonly, copy) NSString *messageType;
@property (nonatomic, readonly) NSInteger timeoutMs;
@property (nonatomic, readonly) LKEndReason reason;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Value wrapper around linko::applyEvent: holds the current linko::CallState
/// and produces the next state plus the effects the host must run.
@interface LKCallStateMachine : NSObject
- (instancetype)initWithState:(LKCallState *)state NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(state:));

/// The current call state snapshot.
@property (nonatomic, readonly, strong) LKCallState *state;

/// Applies `event` to the current state, stores the next state and returns
/// the effects to execute. Events a state does not list are ignored (the
/// state is returned unchanged with no effects), as are events that address a
/// different call; glare resolution is the one exception.
- (NSArray<LKEffect *> *)applyWithEvent:(LKCallEvent *)event NS_SWIFT_NAME(apply(event:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
