// Objective-C wrapper over the linko-core file chunking and reassembly API
// (include/linko/file_transfer.hpp): the manifest, the wire framing of a
// single chunk, the reassembly state machine and the ack tracker. This
// framework is the only Objective-C++ surface in the repo; every C++ error
// path returns nil here and no C++ exception ever crosses the boundary.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// linko::FileManifest — what a file looks like before any byte moves.
/// sha256Hex is the lowercase hex digest of the whole file.
@interface LKFileManifest : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) uint64_t size;
@property (nonatomic, readonly, copy) NSString *sha256Hex;
@property (nonatomic, readonly) uint32_t chunkSize;
@property (nonatomic, readonly) uint32_t chunkCount;

/// Full-field initializer, e.g. for a manifest decoded from a file.offer body.
- (instancetype)initWithName:(NSString *)name
                        size:(uint64_t)size
                   sha256Hex:(NSString *)sha256Hex
                   chunkSize:(uint32_t)chunkSize
                  chunkCount:(uint32_t)chunkCount NS_DESIGNATED_INITIALIZER;

/// linko::makeManifest: computes chunkCount = ceil(size / chunkSize); an
/// empty file yields chunkCount 0; a chunkSize of 0 falls back to the core's
/// kDefaultChunkSize (16 KiB).
+ (instancetype)makeWithName:(NSString *)name
                        size:(uint64_t)size
                   sha256Hex:(NSString *)sha256Hex
                   chunkSize:(uint32_t)chunkSize NS_SWIFT_NAME(make(name:size:sha256Hex:chunkSize:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// linko::ChunkFrame — a parsed chunk frame; fileId is the raw 16 bytes from
/// the wire.
@interface LKChunkFrame : NSObject
@property (nonatomic, readonly, strong) NSData *fileId;
@property (nonatomic, readonly) uint32_t index;
@property (nonatomic, readonly, strong) NSData *payload;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Stateless framing helpers over linko::frameChunk and linko::parseChunkFrame.
@interface LKFileChunker : NSObject
/// Frames `payload` as chunk `index` of `fileId`. Returns nil when fileId is
/// not exactly 16 bytes (the core answers an empty vector, which cannot be a
/// real frame: a real frame is always at least the 25-byte header).
+ (nullable NSData *)frameChunkWithFileId:(NSData *)fileId
                                    index:(uint32_t)index
                                  payload:(NSData *)payload NS_SWIFT_NAME(frameChunk(fileId:index:payload:));

/// Parses a frame; nil for a wrong version byte, a truncated input, or a
/// length field that does not exactly match the remaining bytes.
+ (nullable LKChunkFrame *)parseFrame:(NSData *)frame NS_SWIFT_NAME(parse(frame:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Outcome of LKFileReassembler.addChunk.
typedef NS_ENUM(NSInteger, LKAddResult) {
    LKAddResultAccepted,
    LKAddResultDuplicate,
    LKAddResultUnexpected,
};

/// linko::Reassembler — reassembles one file from its chunks. Chunks may
/// arrive in any order; the assembled bytes are handed out only when every
/// index is present AND the SHA-256 of the assembly equals the manifest
/// digest (incomplete or corrupt yields nil, never wrong bytes).
@interface LKFileReassembler : NSObject
- (instancetype)initWithManifest:(LKFileManifest *)manifest NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(manifest:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Stores chunk `index`. Duplicate: the index is already stored (the stored
/// bytes stand; nothing changes). Unexpected: the index is at or beyond the
/// manifest's chunkCount, or the payload size does not match the manifest's
/// expectation for that index.
- (LKAddResult)addChunkWithIndex:(uint32_t)index payload:(NSData *)payload NS_SWIFT_NAME(addChunk(index:payload:));

/// Payload bytes accepted so far; duplicates and rejects never count.
@property (nonatomic, readonly) uint64_t receivedBytes;

/// The assembled file, but only when every chunk index is present and the
/// SHA-256 of the assembled bytes equals the manifest digest; nil otherwise.
- (nullable NSData *)takeIfCompleteAndValid NS_SWIFT_NAME(takeIfCompleteAndValid());

/// The lowest missing chunk index; equals chunkCount when nothing is missing.
@property (nonatomic, readonly) uint32_t nextIndexNeeded;
@end

/// linko::AckTracker — tracks which chunks the receiver has acknowledged, so
/// a sender resuming after a drop continues from the resume point: the first
/// chunk index that has not been acknowledged.
@interface LKAckTracker : NSObject

/// Records that the receiver has chunk `index`. Duplicate acks (at or behind
/// the resume point) change nothing; an ack ahead of a gap waits until the
/// gap closes, so no chunk is skipped.
- (void)ackWithIndex:(uint32_t)index NS_SWIFT_NAME(ack(index:));

/// The resume point: the next chunk index to send.
@property (nonatomic, readonly) uint32_t nextToSend;
@end

NS_ASSUME_NONNULL_END
