// LKConversationHistory implementation: Objective-C++ over
// linko::ConversationHistory (include/linko/sync.hpp, submodule tag v0.1.0).
// Total conversions only; no C++ exception ever escapes this file.

#import "LKConversationHistory.h"

#include <optional>
#include <string>
#include <vector>

#include <linko/sync.hpp>

@interface LKReceiptState ()
@property(nonatomic, readwrite) BOOL delivered;
@property(nonatomic, readwrite) BOOL read;
- (instancetype)initWithDelivered:(BOOL)delivered read:(BOOL)read;
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

// Shared with LKMessages.mm's conversion pair by value, not by linkage: the
// plan's file contract keeps one implementation unit per wrapper header, so
// this file converts MessageRecord locally.
static LKMessageRecord *LKMessageRecordFromCore(
    const linko::MessageRecord &record) {
  LKFileMeta *meta = nil;
  if (record.file.has_value()) {
    meta = [[LKFileMeta alloc]
        initWithName:NSStringFromStdString(record.file->name)
                size:record.file->size
              sha256:NSStringFromStdString(record.file->sha256)
           transport:NSStringFromStdString(record.file->transport)
              fileId:NSStringFromStdString(record.file->fileId)];
  }
  return [[LKMessageRecord alloc]
      initWithIdentifier:NSStringFromStdString(record.id)
                    from:NSStringFromStdString(record.from)
                      to:NSStringFromStdString(record.to)
                    text:NSStringFromStdString(record.text)
                    file:meta
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
  if (record.file != nil) {
    linko::FileMeta meta;
    meta.name = StdStringFromNSString(record.file.name);
    meta.size = record.file.size;
    meta.sha256 = StdStringFromNSString(record.file.sha256);
    meta.transport = StdStringFromNSString(record.file.transport);
    meta.fileId = StdStringFromNSString(record.file.fileId);
    core.file = std::optional<linko::FileMeta>(std::move(meta));
  }
  core.seq = record.seq;
  core.ts = record.ts;
  return core;
}

@implementation LKConversationHistory {
  linko::ConversationHistory _core;
}

- (instancetype)init {
  if ((self = [super init])) {
  }
  return self;
}

- (BOOL)addWithRecord:(LKMessageRecord *)record {
  return _core.add(CoreMessageRecordFromWrapper(record)) ? YES : NO;
}

- (LKAddError)lastError {
  switch (_core.lastError()) {
  case linko::AddError::None:
    return LKAddErrorNone;
  case linko::AddError::DuplicateId:
    return LKAddErrorDuplicateId;
  case linko::AddError::InvalidSeq:
    return LKAddErrorInvalidSeq;
  }
  return LKAddErrorNone;
}

- (BOOL)hasGapAfterSeq:(int64_t)seq {
  return _core.hasGapAfter(seq) ? YES : NO;
}

- (NSArray<LKMessageRecord *> *)recordsAfterSeq:(int64_t)seq {
  const std::vector<linko::MessageRecord> records = _core.afterSeq(seq);
  NSMutableArray<LKMessageRecord *> *result =
      [NSMutableArray arrayWithCapacity:records.size()];
  for (const linko::MessageRecord &record : records) {
    [result addObject:LKMessageRecordFromCore(record)];
  }
  return [result copy];
}

- (void)markDeliveredUpToSeq:(int64_t)uptoSeq {
  _core.markDelivered(uptoSeq);
}

- (void)markReadUpToSeq:(int64_t)uptoSeq {
  _core.markRead(uptoSeq);
}

- (LKReceiptState *)receiptForMessageId:(NSString *)messageId {
  const std::optional<linko::ReceiptState> receipt =
      _core.receiptFor(StdStringFromNSString(messageId));
  if (!receipt.has_value()) {
    return nil;
  }
  return [[LKReceiptState alloc] initWithDelivered:receipt->delivered ? YES : NO
                                              read:receipt->read ? YES : NO];
}

@end

@implementation LKReceiptState

- (instancetype)initWithDelivered:(BOOL)delivered read:(BOOL)read {
  if ((self = [super init])) {
    _delivered = delivered;
    _read = read;
  }
  return self;
}

@end
