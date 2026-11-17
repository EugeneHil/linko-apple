// LKMessages implementation: Objective-C++ over the typed bodies in
// include/linko/messages.hpp (submodule tag v0.1.0). Building uses the core's
// toBody() (canonical JSON); reading uses the core's fromBody() with its
// ValidationError paths surfaced through NSError userInfo. Total conversions
// only: every C++ error path returns nil + an error value, and no C++
// exception ever escapes this file.

#import "LKMessages.h"

#include <optional>
#include <string>
#include <vector>

#include <linko/messages.hpp>

NSString * const LKBodyErrorDomain = @"io.github.eugenehil.linko.CoreBridge.body";
NSString * const LKBodyErrorPathKey = @"path";
NSString * const LKBodyErrorMessageKey = @"message";

// --- string/JSON conversion helpers ---

// The core only produces valid UTF-8, so these conversions are total; on the
// impossible path they yield an empty string instead of nil to honor the
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

static std::optional<std::string> OptionalStdStringFromNSString(
    NSString *value) {
  return value != nil ? std::optional<std::string>(StdStringFromNSString(value))
                      : std::nullopt;
}

static NSString *OptionalNSStringFromStdString(
    const std::optional<std::string> &value) {
  return value.has_value() ? NSStringFromStdString(*value) : nil;
}

// dump() only throws on invalid UTF-8, which NSString-backed strings cannot
// contain; an empty string keeps the boundary exception-free.
static NSString *JsonStringFromValue(const nlohmann::json &value) {
  try {
    return NSStringFromStdString(value.dump());
  } catch (const std::exception &) {
    return @"";
  }
}

static void FillError(NSError **error, const char *path, const char *message,
                      NSString *description) {
  if (error == nullptr) {
    return;
  }
  *error = [NSError
      errorWithDomain:LKBodyErrorDomain
                 code:LKBodyErrorInvalid
             userInfo:@{
               NSLocalizedDescriptionKey : description ?: @"invalid body",
               LKBodyErrorPathKey : path != nullptr ? @(path) : @"",
               LKBodyErrorMessageKey : message != nullptr ? @(message) : @"",
             }];
}

// Surfaces the core's validation errors: the first error's path and message
// land in the userInfo keys, all errors join into the description.
static void FillErrorFromValidations(
    NSError **error, const std::vector<linko::ValidationError> &errors) {
  if (error == nullptr) {
    return;
  }
  NSMutableString *description = [NSMutableString string];
  for (const linko::ValidationError &validationError : errors) {
    if (description.length > 0) {
      [description appendString:@"; "];
    }
    [description appendFormat:@"%@: %@", NSStringFromStdString(validationError.path),
                              NSStringFromStdString(validationError.message)];
  }
  if (errors.empty()) {
    FillError(error, "", "invalid body", description);
    return;
  }
  FillError(error, errors.front().path.c_str(),
            errors.front().message.c_str(), description);
}

// Parses a body JSON string; nil plus an error when the input is not JSON.
static std::optional<nlohmann::json> ParseBodyJSON(NSString *bodyJSON,
                                                   NSError **error) {
  const std::string input = StdStringFromNSString(bodyJSON);
  nlohmann::json parsed = nlohmann::json::parse(input.begin(), input.end(),
                                                /*callback=*/nullptr,
                                                /*allow_exceptions=*/false);
  if (parsed.is_discarded()) {
    FillError(error, "", "invalid JSON", nil);
    return std::nullopt;
  }
  return parsed;
}

// Parses and validates through the core's fromBody; nil plus an error when
// anything failed. `parse` is the per-class fromBody lambda.
template <typename T>
static std::optional<T> ValidateBody(NSString *bodyJSON, NSError **error) {
  const std::optional<nlohmann::json> parsed = ParseBodyJSON(bodyJSON, error);
  if (!parsed.has_value()) {
    return std::nullopt;
  }
  std::vector<linko::ValidationError> errors;
  std::optional<T> body = T::fromBody(*parsed, errors);
  if (!body.has_value() || !errors.empty()) {
    FillErrorFromValidations(error, errors);
    return std::nullopt;
  }
  return body;
}

// --- FileMeta / MessageRecord / FileManifest shared conversions ---

static LKFileMeta *LKFileMetaFromCore(const linko::FileMeta &meta) {
  return [[LKFileMeta alloc] initWithName:NSStringFromStdString(meta.name)
                                     size:meta.size
                                   sha256:NSStringFromStdString(meta.sha256)
                                transport:NSStringFromStdString(meta.transport)
                                   fileId:NSStringFromStdString(meta.fileId)];
}

static linko::FileMeta CoreFileMetaFromWrapper(LKFileMeta *meta) {
  linko::FileMeta core;
  core.name = StdStringFromNSString(meta.name);
  core.size = meta.size;
  core.sha256 = StdStringFromNSString(meta.sha256);
  core.transport = StdStringFromNSString(meta.transport);
  core.fileId = StdStringFromNSString(meta.fileId);
  return core;
}

static LKMessageRecord *LKMessageRecordFromCore(
    const linko::MessageRecord &record) {
  return [[LKMessageRecord alloc]
      initWithIdentifier:NSStringFromStdString(record.id)
                    from:NSStringFromStdString(record.from)
                      to:NSStringFromStdString(record.to)
                    text:NSStringFromStdString(record.text)
                    file:record.file.has_value()
                             ? LKFileMetaFromCore(*record.file)
                             : nil
                    seq:record.seq
                     ts:record.ts];
}

static linko::MessageRecord CoreMessageRecordFromWrapper(
    LKMessageRecord *record) {
  linko::MessageRecord core;
  core.id = StdStringFromNSString(record.identifier);
  core.from = StdStringFromNSString(record.from);
  core.to = StdStringFromNSString(record.to);
  core.text = StdStringFromNSString(record.text);
  core.file = record.file != nil
                  ? std::optional<linko::FileMeta>(
                        CoreFileMetaFromWrapper(record.file))
                  : std::nullopt;
  core.seq = record.seq;
  core.ts = record.ts;
  return core;
}

static linko::FileManifest CoreFileManifestFromWrapper(LKFileManifest *manifest) {
  linko::FileManifest core;
  core.name = StdStringFromNSString(manifest.name);
  core.size = manifest.size;
  core.sha256Hex = StdStringFromNSString(manifest.sha256Hex);
  core.chunkSize = manifest.chunkSize;
  core.chunkCount = manifest.chunkCount;
  return core;
}

// --- session family ---

@interface LKSessionHello ()
@property(nonatomic, copy, readwrite) NSString *user;
@property(nonatomic, copy, readwrite) NSString *device;
@end

@implementation LKSessionHello

- (instancetype)initWithUser:(NSString *)user device:(NSString *)device {
  if ((self = [super init])) {
    _user = user;
    _device = device;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::SessionHello body;
  body.user = StdStringFromNSString(_user);
  body.device = StdStringFromNSString(_device);
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::SessionHello> body =
      ValidateBody<linko::SessionHello>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithUser:NSStringFromStdString(body->user)
                             device:NSStringFromStdString(body->device)];
}

@end

@interface LKSessionError ()
@property(nonatomic, copy, readwrite) NSString *code;
@property(nonatomic, copy, readwrite) NSString *detail;
@end

@implementation LKSessionError

- (instancetype)initWithCode:(NSString *)code detail:(NSString *)detail {
  if ((self = [super init])) {
    _code = code;
    _detail = detail;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::SessionError body;
  body.code = StdStringFromNSString(_code);
  body.detail = StdStringFromNSString(_detail);
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::SessionError> body =
      ValidateBody<linko::SessionError>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithCode:NSStringFromStdString(body->code)
                             detail:NSStringFromStdString(body->detail)];
}

@end

// --- presence family ---

@interface LKPresenceChanged ()
@property(nonatomic, copy, readwrite) NSString *user;
@property(nonatomic, readwrite) BOOL online;
@end

@implementation LKPresenceChanged

- (instancetype)initWithUser:(NSString *)user online:(BOOL)online {
  if ((self = [super init])) {
    _user = user;
    _online = online;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::PresenceChanged body;
  body.user = StdStringFromNSString(_user);
  body.online = _online;
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::PresenceChanged> body =
      ValidateBody<linko::PresenceChanged>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithUser:NSStringFromStdString(body->user)
                             online:body->online ? YES : NO];
}

@end

// --- call family ---

@interface LKCallInvite ()
@property(nonatomic, copy, readwrite) NSString *callId;
@property(nonatomic, copy, readwrite) NSString *to;
@property(nonatomic, copy, readwrite) NSString *media;
@end

@implementation LKCallInvite

- (instancetype)initWithCallId:(NSString *)callId to:(NSString *)to media:(NSString *)media {
  if ((self = [super init])) {
    _callId = callId;
    _to = to;
    _media = media;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::CallInvite body;
  body.callId = StdStringFromNSString(_callId);
  body.to = StdStringFromNSString(_to);
  body.media = StdStringFromNSString(_media);
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::CallInvite> body =
      ValidateBody<linko::CallInvite>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithCallId:NSStringFromStdString(body->callId)
                                   to:NSStringFromStdString(body->to)
                                media:NSStringFromStdString(body->media)];
}

@end

@interface LKCallRef ()
@property(nonatomic, copy, readwrite) NSString *callId;
@end

@implementation LKCallRef

- (instancetype)initWithCallId:(NSString *)callId {
  if ((self = [super init])) {
    _callId = callId;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::CallRef body;
  body.callId = StdStringFromNSString(_callId);
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::CallRef> body =
      ValidateBody<linko::CallRef>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithCallId:NSStringFromStdString(body->callId)];
}

@end

@interface LKCallSdp ()
@property(nonatomic, copy, readwrite) NSString *callId;
@property(nonatomic, copy, readwrite) NSString *sdp;
@end

@implementation LKCallSdp

- (instancetype)initWithCallId:(NSString *)callId sdp:(NSString *)sdp {
  if ((self = [super init])) {
    _callId = callId;
    _sdp = sdp;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::CallSdp body;
  body.callId = StdStringFromNSString(_callId);
  body.sdp = StdStringFromNSString(_sdp);
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::CallSdp> body =
      ValidateBody<linko::CallSdp>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithCallId:NSStringFromStdString(body->callId)
                                  sdp:NSStringFromStdString(body->sdp)];
}

@end

@interface LKCallIce ()
@property(nonatomic, copy, readwrite) NSString *callId;
@property(nonatomic, copy, readwrite) NSString *candidate;
@property(nonatomic, copy, readwrite) NSString *sdpMid;
@property(nonatomic, readwrite) int sdpMLineIndex;
@end

@implementation LKCallIce

- (instancetype)initWithCallId:(NSString *)callId
                     candidate:(NSString *)candidate
                        sdpMid:(NSString *)sdpMid
                 sdpMLineIndex:(int)sdpMLineIndex {
  if ((self = [super init])) {
    _callId = callId;
    _candidate = candidate;
    _sdpMid = sdpMid;
    _sdpMLineIndex = sdpMLineIndex;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::CallIce body;
  body.callId = StdStringFromNSString(_callId);
  body.candidate = StdStringFromNSString(_candidate);
  body.sdpMid = StdStringFromNSString(_sdpMid);
  body.sdpMLineIndex = _sdpMLineIndex;
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::CallIce> body =
      ValidateBody<linko::CallIce>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithCallId:NSStringFromStdString(body->callId)
                            candidate:NSStringFromStdString(body->candidate)
                               sdpMid:NSStringFromStdString(body->sdpMid)
                        sdpMLineIndex:body->sdpMLineIndex];
}

@end

@interface LKCallEnd ()
@property(nonatomic, copy, readwrite) NSString *callId;
@property(nonatomic, copy, readwrite, nullable) NSString *reason;
@end

@implementation LKCallEnd

- (instancetype)initWithCallId:(NSString *)callId reason:(NSString *)reason {
  if ((self = [super init])) {
    _callId = callId;
    _reason = reason;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::CallEnd body;
  body.callId = StdStringFromNSString(_callId);
  body.reason = OptionalStdStringFromNSString(_reason);
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::CallEnd> body =
      ValidateBody<linko::CallEnd>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithCallId:NSStringFromStdString(body->callId)
                               reason:OptionalNSStringFromStdString(body->reason)];
}

@end

// --- msg family ---

@interface LKFileMeta ()
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, readwrite) int64_t size;
@property(nonatomic, copy, readwrite) NSString *sha256;
@property(nonatomic, copy, readwrite) NSString *transport;
@property(nonatomic, copy, readwrite) NSString *fileId;
@end

@implementation LKFileMeta

- (instancetype)initWithName:(NSString *)name
                        size:(int64_t)size
                      sha256:(NSString *)sha256
                   transport:(NSString *)transport
                      fileId:(NSString *)fileId {
  if ((self = [super init])) {
    _name = name;
    _size = size;
    _sha256 = sha256;
    _transport = transport;
    _fileId = fileId;
  }
  return self;
}

- (NSString *)bodyJSON {
  return JsonStringFromValue(CoreFileMetaFromWrapper(self).toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::FileMeta> body =
      ValidateBody<linko::FileMeta>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return LKFileMetaFromCore(*body);
}

@end

@interface LKMessageRecord ()
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, copy, readwrite) NSString *from;
@property(nonatomic, copy, readwrite) NSString *to;
@property(nonatomic, copy, readwrite) NSString *text;
@property(nonatomic, strong, readwrite, nullable) LKFileMeta *file;
@property(nonatomic, readwrite) int64_t seq;
@property(nonatomic, readwrite) int64_t ts;
@end

@implementation LKMessageRecord

- (instancetype)initWithIdentifier:(NSString *)identifier
                              from:(NSString *)from
                                to:(NSString *)to
                              text:(NSString *)text
                              file:(LKFileMeta *)file
                              seq:(int64_t)seq
                               ts:(int64_t)ts {
  if ((self = [super init])) {
    _identifier = identifier;
    _from = from;
    _to = to;
    _text = text;
    _file = file;
    _seq = seq;
    _ts = ts;
  }
  return self;
}

- (NSString *)bodyJSON {
  return JsonStringFromValue(CoreMessageRecordFromWrapper(self).toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::MessageRecord> body =
      ValidateBody<linko::MessageRecord>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return LKMessageRecordFromCore(*body);
}

@end

@interface LKMsgSend ()
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, copy, readwrite) NSString *to;
@property(nonatomic, copy, readwrite) NSString *text;
@property(nonatomic, strong, readwrite, nullable) LKFileMeta *file;
@end

@implementation LKMsgSend

- (instancetype)initWithIdentifier:(NSString *)identifier
                                to:(NSString *)to
                              text:(NSString *)text
                              file:(LKFileMeta *)file {
  if ((self = [super init])) {
    _identifier = identifier;
    _to = to;
    _text = text;
    _file = file;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::MsgSend body;
  body.id = StdStringFromNSString(_identifier);
  body.to = StdStringFromNSString(_to);
  body.text = StdStringFromNSString(_text);
  body.file = _file != nil ? std::optional<linko::FileMeta>(
                                 CoreFileMetaFromWrapper(_file))
                           : std::nullopt;
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::MsgSend> body =
      ValidateBody<linko::MsgSend>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc]
      initWithIdentifier:NSStringFromStdString(body->id)
                      to:NSStringFromStdString(body->to)
                    text:NSStringFromStdString(body->text)
                    file:body->file.has_value() ? LKFileMetaFromCore(*body->file)
                                                : nil];
}

@end

@interface LKMsgStored ()
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, readwrite) int64_t seq;
@property(nonatomic, readwrite) int64_t ts;
@end

@implementation LKMsgStored

- (instancetype)initWithIdentifier:(NSString *)identifier seq:(int64_t)seq ts:(int64_t)ts {
  if ((self = [super init])) {
    _identifier = identifier;
    _seq = seq;
    _ts = ts;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::MsgStored body;
  body.id = StdStringFromNSString(_identifier);
  body.seq = _seq;
  body.ts = _ts;
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::MsgStored> body =
      ValidateBody<linko::MsgStored>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithIdentifier:NSStringFromStdString(body->id)
                                     seq:body->seq
                                      ts:body->ts];
}

@end

@interface LKMsgDeliver ()
@property(nonatomic, strong, readwrite) LKMessageRecord *message;
@end

@implementation LKMsgDeliver

- (instancetype)initWithMessage:(LKMessageRecord *)message {
  if ((self = [super init])) {
    _message = message;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::MsgDeliver body;
  body.message = CoreMessageRecordFromWrapper(_message);
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::MsgDeliver> body =
      ValidateBody<linko::MsgDeliver>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithMessage:LKMessageRecordFromCore(body->message)];
}

@end

@interface LKMsgAck ()
@property(nonatomic, copy, readwrite) NSString *conversation;
@property(nonatomic, readwrite) int64_t uptoSeq;
@end

@implementation LKMsgAck

- (instancetype)initWithConversation:(NSString *)conversation uptoSeq:(int64_t)uptoSeq {
  if ((self = [super init])) {
    _conversation = conversation;
    _uptoSeq = uptoSeq;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::MsgAck body;
  body.conversation = StdStringFromNSString(_conversation);
  body.uptoSeq = _uptoSeq;
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::MsgAck> body =
      ValidateBody<linko::MsgAck>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithConversation:NSStringFromStdString(body->conversation)
                                     uptoSeq:body->uptoSeq];
}

@end

@interface LKMsgSync ()
@property(nonatomic, copy, readwrite) NSString *conversation;
@property(nonatomic, readwrite) int64_t afterSeq;
@end

@implementation LKMsgSync

- (instancetype)initWithConversation:(NSString *)conversation afterSeq:(int64_t)afterSeq {
  if ((self = [super init])) {
    _conversation = conversation;
    _afterSeq = afterSeq;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::MsgSync body;
  body.conversation = StdStringFromNSString(_conversation);
  body.afterSeq = _afterSeq;
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::MsgSync> body =
      ValidateBody<linko::MsgSync>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithConversation:NSStringFromStdString(body->conversation)
                                    afterSeq:body->afterSeq];
}

@end

// --- file family ---

@interface LKFileOffer ()
@property(nonatomic, copy, readwrite) NSString *callId;
@property(nonatomic, copy, readwrite) NSString *fileId;
@property(nonatomic, strong, readwrite) LKFileManifest *manifest;
@end

@implementation LKFileOffer

- (instancetype)initWithCallId:(NSString *)callId
                        fileId:(NSString *)fileId
                      manifest:(LKFileManifest *)manifest {
  if ((self = [super init])) {
    _callId = callId;
    _fileId = fileId;
    _manifest = manifest;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::FileOffer body;
  body.callId = StdStringFromNSString(_callId);
  body.fileId = StdStringFromNSString(_fileId);
  body.manifest = CoreFileManifestFromWrapper(_manifest);
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::FileOffer> body =
      ValidateBody<linko::FileOffer>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  const linko::FileManifest &manifest = body->manifest;
  return [[self alloc]
      initWithCallId:NSStringFromStdString(body->callId)
              fileId:NSStringFromStdString(body->fileId)
            manifest:[[LKFileManifest alloc]
                         initWithName:NSStringFromStdString(manifest.name)
                                 size:manifest.size
                            sha256Hex:NSStringFromStdString(manifest.sha256Hex)
                            chunkSize:manifest.chunkSize
                           chunkCount:manifest.chunkCount]];
}

@end

@interface LKFileAccept ()
@property(nonatomic, copy, readwrite) NSString *callId;
@property(nonatomic, copy, readwrite) NSString *fileId;
@end

@implementation LKFileAccept

- (instancetype)initWithCallId:(NSString *)callId fileId:(NSString *)fileId {
  if ((self = [super init])) {
    _callId = callId;
    _fileId = fileId;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::FileAccept body;
  body.callId = StdStringFromNSString(_callId);
  body.fileId = StdStringFromNSString(_fileId);
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::FileAccept> body =
      ValidateBody<linko::FileAccept>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithCallId:NSStringFromStdString(body->callId)
                               fileId:NSStringFromStdString(body->fileId)];
}

@end

@interface LKFileCancel ()
@property(nonatomic, copy, readwrite) NSString *callId;
@property(nonatomic, copy, readwrite) NSString *fileId;
@property(nonatomic, copy, readwrite) NSString *reason;
@end

@implementation LKFileCancel

- (instancetype)initWithCallId:(NSString *)callId fileId:(NSString *)fileId reason:(NSString *)reason {
  if ((self = [super init])) {
    _callId = callId;
    _fileId = fileId;
    _reason = reason;
  }
  return self;
}

- (NSString *)bodyJSON {
  linko::FileCancel body;
  body.callId = StdStringFromNSString(_callId);
  body.fileId = StdStringFromNSString(_fileId);
  body.reason = StdStringFromNSString(_reason);
  return JsonStringFromValue(body.toBody());
}

+ (instancetype)fromBodyJSONString:(NSString *)bodyJSON error:(NSError **)error {
  const std::optional<linko::FileCancel> body =
      ValidateBody<linko::FileCancel>(bodyJSON, error);
  if (!body.has_value()) {
    return nil;
  }
  return [[self alloc] initWithCallId:NSStringFromStdString(body->callId)
                               fileId:NSStringFromStdString(body->fileId)
                               reason:NSStringFromStdString(body->reason)];
}

@end
