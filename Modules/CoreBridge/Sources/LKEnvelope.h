// CoreBridge (Plan 4 Task 1): the minimal Objective-C wrapper over the
// linko-core envelope API (include/linko/envelope.hpp). This framework is
// the only Objective-C++ surface in the repo — the single Swift<->C++ seam
// (spec 4.3). Every C++ error path returns an error value here; no C++
// exception ever crosses the boundary.

#import <Foundation/Foundation.h>

@class LKEnvelope;

NS_ASSUME_NONNULL_BEGIN

/// One validation problem reported by the core; path is a JSON path such as
/// "v" or "body.sdp" (core ValidationError).
@interface LKValidationError : NSObject
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSString *message;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Outcome of parsing a wire-format envelope (core ParseResult): envelope is
/// present only when errors is empty; unsupportedVersion flags any v != 1 so
/// callers can answer with session.error{code:"unsupported_version"}.
@interface LKParseResult : NSObject
@property (nonatomic, readonly, strong, nullable) LKEnvelope *envelope;
@property (nonatomic, readonly, copy) NSArray<LKValidationError *> *errors;
@property (nonatomic, readonly) BOOL unsupportedVersion;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Protocol v1 envelope (spec 4.2) wrapping linko::Envelope. body stays raw
/// JSON in canonical form; typed per-family accessors come in later tasks.
@interface LKEnvelope : NSObject
@property (nonatomic, readonly) NSInteger v;
@property (nonatomic, readonly, copy) NSString *type;
/// Wire field "id".
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly) int64_t ts;
/// The envelope body as canonical JSON.
@property (nonatomic, readonly, copy) NSString *bodyJSON;
/// The full envelope re-serialized to wire format by the core.
@property (nonatomic, readonly, copy) NSString *wireJSON;

/// Parses wire-format JSON through the core (size, strict UTF-8 and nesting
/// checks happen before any JSON parsing). Never throws: a parse failure
/// surfaces in the returned result's errors.
+ (LKParseResult *)parseJSONString:(NSString *)jsonString NS_SWIFT_NAME(parse(jsonString:));
@end

NS_ASSUME_NONNULL_END
