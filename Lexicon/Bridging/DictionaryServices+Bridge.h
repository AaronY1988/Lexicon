//
//  DictionaryServices+Bridge.h
//  Lexicon
//
//  Forward-declares the private symbols from
//      /System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework
//  so we can call them from Swift. Linking against CoreServices.framework is
//  enough — no extra linker flags required.
//
//  These APIs have been stable since macOS 10.5 (they power Dictionary.app and
//  the system ⌃⌘D shortcut), but they are not part of the public SDK. Apps
//  using them cannot ship via the Mac App Store; direct distribution (DMG,
//  Homebrew Cask) works fine.
//
//  This file is intentionally kept minimal:
//    * no `CF_EXTERN_C_BEGIN` / `CF_ASSUME_NONNULL_BEGIN` (those are private
//      CoreFoundation macros that can fail to parse in newer SDKs and cause
//      SwiftGeneratePch to fail);
//    * plain `extern "C"` guard;
//    * explicit `_Nullable` on every pointer return so Swift sees Optional;
//    * no `CF_IMPLICIT_BRIDGING_*` — Swift gets `Unmanaged<CFXxx>?` and we
//      use `.takeRetainedValue()` / `.takeUnretainedValue()` at every call
//      site to be explicit about retain semantics.
//

#ifndef DictionaryServices_Bridge_h
#define DictionaryServices_Bridge_h

#import <CoreFoundation/CoreFoundation.h>

#if defined(__cplusplus)
extern "C" {
#endif

typedef CFTypeRef DCSDictionaryRef;
typedef CFTypeRef DCSRecordRef;

/// All dictionaries the user has installed (active + inactive).
extern CFArrayRef _Nullable DCSCopyAvailableDictionaries(void);

/// The user's currently active dictionaries (subset of available).
extern CFArrayRef _Nullable DCSGetActiveDictionaries(void);

/// Human-readable name of the dictionary (e.g. "New Oxford American Dictionary").
extern CFStringRef _Nullable DCSDictionaryGetName(DCSDictionaryRef dictionary);

/// Short identifier (e.g. "com.apple.dictionary.NOAD").
extern CFStringRef _Nullable DCSDictionaryGetShortName(DCSDictionaryRef dictionary);

/// Returns an array of DCSRecordRef matching the search string.
/// Pass NULL for the dictionary to search all active dictionaries.
extern CFArrayRef _Nullable DCSCopyRecordsForSearchString(DCSDictionaryRef _Nullable dictionary,
                                                          CFStringRef searchString,
                                                          CFTypeRef _Nullable options,
                                                          CFTypeRef _Nullable language);

/// Headword of the record (the term being defined).
extern CFStringRef _Nullable DCSRecordGetHeadword(DCSRecordRef record);

/// The dictionary that owns this record.
extern DCSDictionaryRef _Nullable DCSRecordGetDictionary(DCSRecordRef record);

/// Raw XML definition body (rich content — parts of speech, senses, etc.).
extern CFStringRef _Nullable DCSRecordCopyData(DCSRecordRef record);

/// Convenience: plain-text definition for the given text.
/// Pass NULL for the dictionary to search all active dictionaries.
extern CFStringRef _Nullable DCSCopyTextDefinition(DCSDictionaryRef _Nullable dictionary,
                                                   CFStringRef textString,
                                                   CFRange range);

#if defined(__cplusplus)
}
#endif

#endif /* DictionaryServices_Bridge_h */
