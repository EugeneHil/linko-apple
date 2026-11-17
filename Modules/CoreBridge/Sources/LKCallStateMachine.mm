// LKCallStateMachine implementation: Objective-C++ over linko::applyEvent
// (include/linko/call_state_machine.hpp, submodule tag v0.1.0). Total
// conversions only; no C++ exception ever escapes this file.

#import "LKCallStateMachine.h"

#include <string>
#include <vector>

#include <linko/call_state_machine.hpp>

@interface LKCallState ()
@property(nonatomic, readwrite) LKCallStateKind kind;
@property(nonatomic, copy, readwrite) NSString *callId;
@property(nonatomic, copy, readwrite) NSString *peer;
@property(nonatomic, readwrite) BOOL video;
@property(nonatomic, readwrite) LKEndReason endReason;
@end

@interface LKCallEvent ()
@property(nonatomic, readwrite) LKCallEventKind kind;
@property(nonatomic, copy, readwrite) NSString *callId;
@property(nonatomic, copy, readwrite) NSString *peer;
@property(nonatomic, readwrite) BOOL video;
@end

@interface LKEffect ()
@property(nonatomic, readwrite) LKEffectKind kind;
@property(nonatomic, copy, readwrite) NSString *messageType;
@property(nonatomic, readwrite) NSInteger timeoutMs;
@property(nonatomic, readwrite) LKEndReason reason;
- (instancetype)initWithCoreEffect:(const linko::Effect &)effect;
@end

// The core only produces valid UTF-8, so this conversion is total; on the
// impossible path it yields an empty string instead of nil to honor the
// nonnull properties.
static NSString *NSStringFromStdString(const std::string &value) {
  NSString *converted = [[NSString alloc] initWithBytes:value.data()
                                                 length:value.size()
                                               encoding:NSUTF8StringEncoding];
  return converted ?: @"";
}

static std::string StdStringFromNSString(NSString *value) {
  const char *bytes = value.UTF8String;
  return bytes != nullptr ? std::string(bytes) : std::string();
}

static LKCallStateKind LKCallStateKindFromCore(linko::CallStateKind kind) {
  switch (kind) {
  case linko::CallStateKind::Idle:
    return LKCallStateKindIdle;
  case linko::CallStateKind::OutgoingRinging:
    return LKCallStateKindOutgoingRinging;
  case linko::CallStateKind::IncomingRinging:
    return LKCallStateKindIncomingRinging;
  case linko::CallStateKind::Connecting:
    return LKCallStateKindConnecting;
  case linko::CallStateKind::Active:
    return LKCallStateKindActive;
  case linko::CallStateKind::Reconnecting:
    return LKCallStateKindReconnecting;
  case linko::CallStateKind::Ended:
    return LKCallStateKindEnded;
  }
  return LKCallStateKindIdle;
}

static linko::CallStateKind CoreCallStateKindFromWrapper(LKCallStateKind kind) {
  switch (kind) {
  case LKCallStateKindIdle:
    return linko::CallStateKind::Idle;
  case LKCallStateKindOutgoingRinging:
    return linko::CallStateKind::OutgoingRinging;
  case LKCallStateKindIncomingRinging:
    return linko::CallStateKind::IncomingRinging;
  case LKCallStateKindConnecting:
    return linko::CallStateKind::Connecting;
  case LKCallStateKindActive:
    return linko::CallStateKind::Active;
  case LKCallStateKindReconnecting:
    return linko::CallStateKind::Reconnecting;
  case LKCallStateKindEnded:
    return linko::CallStateKind::Ended;
  }
  return linko::CallStateKind::Idle;
}

static LKEndReason LKEndReasonFromCore(linko::EndReason reason) {
  switch (reason) {
  case linko::EndReason::Normal:
    return LKEndReasonNormal;
  case linko::EndReason::Busy:
    return LKEndReasonBusy;
  case linko::EndReason::Rejected:
    return LKEndReasonRejected;
  case linko::EndReason::Cancelled:
    return LKEndReasonCancelled;
  case linko::EndReason::Missed:
    return LKEndReasonMissed;
  case linko::EndReason::Timeout:
    return LKEndReasonTimeout;
  case linko::EndReason::Error:
    return LKEndReasonError;
  }
  return LKEndReasonNormal;
}

static linko::EndReason CoreEndReasonFromWrapper(LKEndReason reason) {
  switch (reason) {
  case LKEndReasonNormal:
    return linko::EndReason::Normal;
  case LKEndReasonBusy:
    return linko::EndReason::Busy;
  case LKEndReasonRejected:
    return linko::EndReason::Rejected;
  case LKEndReasonCancelled:
    return linko::EndReason::Cancelled;
  case LKEndReasonMissed:
    return linko::EndReason::Missed;
  case LKEndReasonTimeout:
    return linko::EndReason::Timeout;
  case LKEndReasonError:
    return linko::EndReason::Error;
  }
  return linko::EndReason::Normal;
}

static linko::CallEvent::Kind CoreCallEventKindFromWrapper(
    LKCallEventKind kind) {
  switch (kind) {
  case LKCallEventKindLocalInvite:
    return linko::CallEvent::LocalInvite;
  case LKCallEventKindLocalAccept:
    return linko::CallEvent::LocalAccept;
  case LKCallEventKindLocalReject:
    return linko::CallEvent::LocalReject;
  case LKCallEventKindLocalCancel:
    return linko::CallEvent::LocalCancel;
  case LKCallEventKindLocalHangup:
    return linko::CallEvent::LocalHangup;
  case LKCallEventKindRemoteInvite:
    return linko::CallEvent::RemoteInvite;
  case LKCallEventKindRemoteRinging:
    return linko::CallEvent::RemoteRinging;
  case LKCallEventKindRemoteAccept:
    return linko::CallEvent::RemoteAccept;
  case LKCallEventKindRemoteReject:
    return linko::CallEvent::RemoteReject;
  case LKCallEventKindRemoteBusy:
    return linko::CallEvent::RemoteBusy;
  case LKCallEventKindRemoteCancel:
    return linko::CallEvent::RemoteCancel;
  case LKCallEventKindRemoteOffer:
    return linko::CallEvent::RemoteOffer;
  case LKCallEventKindRemoteAnswer:
    return linko::CallEvent::RemoteAnswer;
  case LKCallEventKindRemoteIce:
    return linko::CallEvent::RemoteIce;
  case LKCallEventKindRemoteIceRestart:
    return linko::CallEvent::RemoteIceRestart;
  case LKCallEventKindRemoteHangup:
    return linko::CallEvent::RemoteHangup;
  case LKCallEventKindIceConnected:
    return linko::CallEvent::IceConnected;
  case LKCallEventKindIceFailed:
    return linko::CallEvent::IceFailed;
  case LKCallEventKindNetworkChanged:
    return linko::CallEvent::NetworkChanged;
  case LKCallEventKindTimerRingExpired:
    return linko::CallEvent::TimerRingExpired;
  case LKCallEventKindTimerConnectExpired:
    return linko::CallEvent::TimerConnectExpired;
  case LKCallEventKindTimerReconnectExpired:
    return linko::CallEvent::TimerReconnectExpired;
  }
  return linko::CallEvent::LocalInvite;
}

static linko::CallState CoreCallStateFromWrapper(LKCallState *state) {
  linko::CallState core;
  core.kind = CoreCallStateKindFromWrapper(state.kind);
  core.callId = StdStringFromNSString(state.callId);
  core.peer = StdStringFromNSString(state.peer);
  core.video = state.video ? true : false;
  core.reason = CoreEndReasonFromWrapper(state.endReason);
  return core;
}

static LKCallState *LKCallStateFromCore(const linko::CallState &state) {
  return [[LKCallState alloc]
      initWithKind:LKCallStateKindFromCore(state.kind)
             callId:NSStringFromStdString(state.callId)
               peer:NSStringFromStdString(state.peer)
              video:state.video ? YES : NO
          endReason:LKEndReasonFromCore(state.reason)];
}

@implementation LKCallState

- (instancetype)initWithKind:(LKCallStateKind)kind
                      callId:(NSString *)callId
                        peer:(NSString *)peer
                       video:(BOOL)video
                   endReason:(LKEndReason)endReason {
  if ((self = [super init])) {
    _kind = kind;
    _callId = callId;
    _peer = peer;
    _video = video;
    _endReason = endReason;
  }
  return self;
}

+ (LKCallState *)idle {
  return [[LKCallState alloc] initWithKind:LKCallStateKindIdle
                                     callId:@""
                                       peer:@""
                                      video:NO
                                  endReason:LKEndReasonNormal];
}

@end

@implementation LKCallEvent

- (instancetype)initWithKind:(LKCallEventKind)kind
                      callId:(NSString *)callId
                        peer:(NSString *)peer
                       video:(BOOL)video {
  if ((self = [super init])) {
    _kind = kind;
    _callId = callId;
    _peer = peer;
    _video = video;
  }
  return self;
}

@end

@implementation LKEffect

- (instancetype)initWithCoreEffect:(const linko::Effect &)effect {
  if ((self = [super init])) {
    _kind = static_cast<LKEffectKind>(effect.kind);
    _messageType = NSStringFromStdString(effect.messageType);
    _timeoutMs = effect.timeoutMs;
    _reason = LKEndReasonFromCore(effect.reason);
  }
  return self;
}

@end

@implementation LKCallStateMachine {
  linko::CallState _coreState;
}

- (instancetype)initWithState:(LKCallState *)state {
  if ((self = [super init])) {
    _coreState = CoreCallStateFromWrapper(state);
  }
  return self;
}

- (LKCallState *)state {
  return LKCallStateFromCore(_coreState);
}

- (NSArray<LKEffect *> *)applyWithEvent:(LKCallEvent *)event {
  linko::CallEvent coreEvent;
  coreEvent.kind = CoreCallEventKindFromWrapper(event.kind);
  coreEvent.callId = StdStringFromNSString(event.callId);
  coreEvent.peer = StdStringFromNSString(event.peer);
  coreEvent.video = event.video ? true : false;

  const linko::Transition transition =
      linko::applyEvent(_coreState, coreEvent);
  _coreState = transition.next;

  NSMutableArray<LKEffect *> *effects =
      [NSMutableArray arrayWithCapacity:transition.effects.size()];
  for (const linko::Effect &effect : transition.effects) {
    [effects addObject:[[LKEffect alloc] initWithCoreEffect:effect]];
  }
  return [effects copy];
}

@end
