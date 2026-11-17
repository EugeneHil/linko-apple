// LKEnvelope implementation: Objective-C++ over linko::parseEnvelope and
// linko::serialize (include/linko/envelope.hpp, submodule tag v0.1.0).
// Total conversions only: every C++ error path returns an error value, and
// no C++ exception ever escapes this file.

#import "LKEnvelope.h"

#include <exception>
#include <string>

#include <linko/envelope.hpp>

// The core only produces valid UTF-8, so this conversion is total; on the
// impossible path it yields an empty string instead of nil to honor the
// nonnull properties.
static NSString *NSStringFromStdString(const std::string &value) {
  NSString *converted = [[NSString alloc] initWithBytes:value.data()
                                                 length:value.size()
                                               encoding:NSUTF8StringEncoding];
  return converted ?: @"";
}

// Readwrite class extensions and the private initializers: instances are
// only created through the parsing entry points.
@interface LKValidationError ()
@property(nonatomic, copy, readwrite) NSString *path;
@property(nonatomic, copy, readwrite) NSString *message;
@end

@interface LKParseResult ()
@property(nonatomic, strong, readwrite, nullable) LKEnvelope *envelope;
@property(nonatomic, copy, readwrite) NSArray<LKValidationError *> *errors;
@property(nonatomic, readwrite) BOOL unsupportedVersion;
@end

@interface LKEnvelope ()
@property(nonatomic, readwrite) NSInteger v;
@property(nonatomic, readwrite) int64_t ts;
@property(nonatomic, copy, readwrite) NSString *type;
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, copy, readwrite) NSString *bodyJSON;
- (instancetype)initWithV:(NSInteger)v type:(NSString *)type id:(NSString *)identifier ts:(int64_t)ts bodyJSON:(NSString *)bodyJSON;
@end

@implementation LKValidationError

- (instancetype)initWithPath:(NSString *)path message:(NSString *)message {
  if ((self = [super init])) {
    _path = path;
    _message = message;
  }
  return self;
}

@end

@implementation LKParseResult

- (instancetype)initWithEnvelope:(nullable LKEnvelope *)envelope
                          errors:(NSArray<LKValidationError *> *)errors
              unsupportedVersion:(BOOL)unsupportedVersion {
  if ((self = [super init])) {
    _envelope = envelope;
    _errors = errors;
    _unsupportedVersion = unsupportedVersion;
  }
  return self;
}

@end

@implementation LKEnvelope

- (instancetype)initWithV:(NSInteger)v
                     type:(NSString *)type
                       id:(NSString *)identifier
                       ts:(int64_t)ts
                 bodyJSON:(NSString *)bodyJSON {
  if ((self = [super init])) {
    _v = v;
    _ts = ts;
    _type = type;
    _identifier = identifier;
    _bodyJSON = bodyJSON;
  }
  return self;
}

- (NSString *)wireJSON {
  linko::Envelope envelope;
  envelope.v = static_cast<int>(_v);
  envelope.type = _type.UTF8String ?: "";
  envelope.id = _identifier.UTF8String ?: "";
  envelope.ts = _ts;
  envelope.body = nlohmann::json::parse(_bodyJSON.UTF8String ?: "", nullptr,
                                        /*allow_exceptions=*/false);
  try {
    return NSStringFromStdString(linko::serialize(envelope));
  } catch (const std::exception &) {
    // serialize only throws on invalid UTF-8, which parsed envelopes cannot
    // contain; an empty string keeps the boundary exception-free.
    return @"";
  }
}

+ (LKParseResult *)parseJSONString:(NSString *)jsonString {
  const char *bytes = jsonString.UTF8String;
  const std::string input = bytes != nullptr ? std::string(bytes) : std::string();

  linko::ParseResult result = linko::parseEnvelope(input);

  NSMutableArray<LKValidationError *> *errors = [NSMutableArray array];
  for (const linko::ValidationError &error : result.errors) {
    LKValidationError *validationError = [[LKValidationError alloc]
        initWithPath:NSStringFromStdString(error.path)
             message:NSStringFromStdString(error.message)];
    [errors addObject:validationError];
  }

  LKEnvelope *envelope = nil;
  if (result.envelope.has_value()) {
    envelope = [[LKEnvelope alloc]
        initWithV:static_cast<NSInteger>(result.envelope->v)
             type:NSStringFromStdString(result.envelope->type)
               id:NSStringFromStdString(result.envelope->id)
               ts:result.envelope->ts
         bodyJSON:NSStringFromStdString(result.envelope->body.dump())];
  }

  LKParseResult *parsed = [[LKParseResult alloc]
      initWithEnvelope:envelope
                errors:[errors copy]
    unsupportedVersion:result.unsupportedVersion];
  return parsed;
}

@end
