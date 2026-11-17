// Objective-C wrapper over the linko-core message sync helpers
// (include/linko/sync.hpp): ConversationHistory holds the messages of one
// conversation ordered by the server-assigned seq, makes adds idempotent by
// id and tracks receipts as monotonic watermarks (read implies delivered,
// receipts never regress). Every C++ error path returns nil/false here; no
// C++ exception ever crosses the boundary.

#import <Foundation/Foundation.h>

#import "LKMessages.h"

NS_ASSUME_NONNULL_BEGIN

/// linko::ReceiptState — receipt snapshot for one message, derived from the
/// conversation's delivered/read watermarks.
@interface LKReceiptState : NSObject
@property (nonatomic, readonly) BOOL delivered;
@property (nonatomic, readonly) BOOL read;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Why the most recent add returned NO.
typedef NS_ENUM(NSInteger, LKAddError) {
    LKAddErrorNone,
    LKAddErrorDuplicateId, // id already stored; the first record wins
    LKAddErrorInvalidSeq,  // seq <= 0; a server seq starts at 1
};

/// linko::ConversationHistory — the messages of one conversation plus its
/// receipt watermarks. A pure value wrapper: no I/O, no clocks.
@interface LKConversationHistory : NSObject
- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// Stores `record`, keeping the conversation ordered by seq. Returns NO — and
/// stores nothing — when a record with the same id is already present
/// (idempotent sends: the first record wins) or when record.seq <= 0;
/// lastError says which.
- (BOOL)addWithRecord:(LKMessageRecord *)record NS_SWIFT_NAME(add(_:));

/// Why the most recent add returned NO.
@property (nonatomic, readonly) LKAddError lastError;

/// True when something is known to be missing above `seq`: the records above
/// seq do not form the contiguous run seq+1, seq+2, ... up to the highest seq
/// seen. True for 1,2,4 (3 is missing); false for a contiguous history, for
/// an empty history and when nothing is stored above seq.
- (BOOL)hasGapAfterSeq:(int64_t)seq NS_SWIFT_NAME(hasGapAfter(_:));

/// The records with seq > seq, ordered by seq — the reply to an "everything
/// after seq N" sync request.
- (NSArray<LKMessageRecord *> *)recordsAfterSeq:(int64_t)seq NS_SWIFT_NAME(afterSeq(_:));

/// Advances the delivered watermark to uptoSeq. Lower values are ignored
/// (receipts never regress).
- (void)markDeliveredUpToSeq:(int64_t)uptoSeq NS_SWIFT_NAME(markDelivered(uptoSeq:));

/// Advances the read watermark to uptoSeq and, because reading implies
/// delivery, the delivered watermark with it. Lower values are ignored.
- (void)markReadUpToSeq:(int64_t)uptoSeq NS_SWIFT_NAME(markRead(uptoSeq:));

/// Receipt snapshot for the stored message with id messageId; nil when no
/// such message exists.
- (nullable LKReceiptState *)receiptForMessageId:(NSString *)messageId NS_SWIFT_NAME(receiptFor(_:));
@end

NS_ASSUME_NONNULL_END
