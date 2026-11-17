// LKFileTransfer implementation: Objective-C++ over linko::makeManifest,
// linko::frameChunk, linko::parseChunkFrame, linko::Reassembler and
// linko::AckTracker (include/linko/file_transfer.hpp, submodule tag v0.1.0).
// Total conversions only: every C++ error path returns nil, and no C++
// exception ever escapes this file.

#import "LKFileTransfer.h"

#include <optional>
#include <string>
#include <vector>

#include <linko/file_transfer.hpp>

// Readwrite class extensions and the private initializers: instances are
// only created through the wrapper entry points.
@interface LKFileManifest ()
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, readwrite) uint64_t size;
@property(nonatomic, copy, readwrite) NSString *sha256Hex;
@property(nonatomic, readwrite) uint32_t chunkSize;
@property(nonatomic, readwrite) uint32_t chunkCount;
@end

@interface LKChunkFrame ()
- (instancetype)initWithFileId:(NSData *)fileId index:(uint32_t)index payload:(NSData *)payload;
@property(nonatomic, strong, readwrite) NSData *fileId;
@property(nonatomic, readwrite) uint32_t index;
@property(nonatomic, strong, readwrite) NSData *payload;
@end

// Text fields (name, sha256Hex): the core only produces valid UTF-8, so this
// conversion is total; on the impossible path it yields an empty string
// instead of nil to honor the nonnull properties.
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

// Raw byte fields (fileId, payloads, frames): no UTF-8 interpretation.
static std::string RawBytesFromNSData(NSData *data) {
  const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
  if (bytes == nullptr || data.length == 0) {
    return {};
  }
  return std::string(reinterpret_cast<const char *>(bytes), data.length);
}

static std::vector<uint8_t> BytesFromNSData(NSData *data) {
  const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
  if (bytes == nullptr || data.length == 0) {
    return {};
  }
  return std::vector<uint8_t>(bytes, bytes + data.length);
}

static NSData *NSDataFromBytes(const std::vector<uint8_t> &bytes) {
  return [NSData dataWithBytes:bytes.data() length:bytes.size()];
}

@implementation LKFileManifest

- (instancetype)initWithName:(NSString *)name
                        size:(uint64_t)size
                   sha256Hex:(NSString *)sha256Hex
                   chunkSize:(uint32_t)chunkSize
                  chunkCount:(uint32_t)chunkCount {
  if ((self = [super init])) {
    _name = name;
    _size = size;
    _sha256Hex = sha256Hex;
    _chunkSize = chunkSize;
    _chunkCount = chunkCount;
  }
  return self;
}

+ (instancetype)makeWithName:(NSString *)name
                        size:(uint64_t)size
                   sha256Hex:(NSString *)sha256Hex
                   chunkSize:(uint32_t)chunkSize {
  const linko::FileManifest manifest = linko::makeManifest(
      StdStringFromNSString(name), size, StdStringFromNSString(sha256Hex),
      chunkSize);
  return [[LKFileManifest alloc]
      initWithName:NSStringFromStdString(manifest.name)
              size:manifest.size
         sha256Hex:NSStringFromStdString(manifest.sha256Hex)
         chunkSize:manifest.chunkSize
        chunkCount:manifest.chunkCount];
}

@end

@implementation LKChunkFrame

- (instancetype)initWithFileId:(NSData *)fileId
                         index:(uint32_t)index
                       payload:(NSData *)payload {
  if ((self = [super init])) {
    _fileId = fileId;
    _index = index;
    _payload = payload;
  }
  return self;
}

@end

@implementation LKFileChunker

+ (NSData *)frameChunkWithFileId:(NSData *)fileId
                           index:(uint32_t)index
                         payload:(NSData *)payload {
  const std::vector<uint8_t> frame =
      linko::frameChunk(RawBytesFromNSData(fileId), index,
                        BytesFromNSData(payload));
  if (frame.empty()) {
    // A real frame is at least the 25-byte header; empty means the core
    // refused the input (a fileId that is not 16 bytes).
    return nil;
  }
  return NSDataFromBytes(frame);
}

+ (LKChunkFrame *)parseFrame:(NSData *)frame {
  const std::optional<linko::ChunkFrame> parsed =
      linko::parseChunkFrame(BytesFromNSData(frame));
  if (!parsed.has_value()) {
    return nil;
  }
  return [[LKChunkFrame alloc]
      initWithFileId:NSDataFromBytes(std::vector<uint8_t>(parsed->fileId.begin(),
                                                          parsed->fileId.end()))
               index:parsed->index
             payload:NSDataFromBytes(parsed->payload)];
}

@end

@implementation LKFileReassembler {
  std::optional<linko::Reassembler> _core;
}

- (instancetype)initWithManifest:(LKFileManifest *)manifest {
  if ((self = [super init])) {
    const linko::FileManifest coreManifest{
        StdStringFromNSString(manifest.name),
        manifest.size,
        StdStringFromNSString(manifest.sha256Hex),
        manifest.chunkSize,
        manifest.chunkCount,
    };
    _core.emplace(coreManifest);
  }
  return self;
}

- (LKAddResult)addChunkWithIndex:(uint32_t)index payload:(NSData *)payload {
  if (!_core.has_value()) {
    return LKAddResultUnexpected;
  }
  const linko::AddResult result =
      _core->addChunk(index, BytesFromNSData(payload));
  switch (result) {
  case linko::AddResult::Accepted:
    return LKAddResultAccepted;
  case linko::AddResult::Duplicate:
    return LKAddResultDuplicate;
  case linko::AddResult::Unexpected:
    return LKAddResultUnexpected;
  }
  return LKAddResultUnexpected;
}

- (uint64_t)receivedBytes {
  return _core.has_value() ? _core->receivedBytes() : 0;
}

- (NSData *)takeIfCompleteAndValid {
  if (!_core.has_value()) {
    return nil;
  }
  const std::optional<std::vector<uint8_t>> file =
      _core->takeIfCompleteAndValid();
  return file.has_value() ? NSDataFromBytes(*file) : nil;
}

- (uint32_t)nextIndexNeeded {
  return _core.has_value() ? _core->nextIndexNeeded() : 0;
}

@end

@implementation LKAckTracker {
  linko::AckTracker _core;
}

- (void)ackWithIndex:(uint32_t)index {
  _core.ack(index);
}

- (uint32_t)nextToSend {
  return _core.nextToSend();
}

@end
