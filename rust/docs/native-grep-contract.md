# Native Grep contract

Grep extends the explicit macOS core capability selector. Existing constructors
still select ls only, unsupported platforms reject Grep before offering tools,
and app/default tool enablement and project authority are unchanged. Roots are
path-resolution context, not a filesystem sandbox. No credential, Keychain or
real-project access is part of these fixtures.

## Shared scan and source ordering

Grep reuses Find's Foundation path resolver, canonical-Unicode root deduplication,
directory enumerator, pre-sort 20,000-candidate cap, normalized path ordering,
relative grapheme slicing and output footer. Each candidate retains the original
NSURL in its blocking job so the later directory query observes Foundation's
prefetched resource cache. Objective-C values remain inside the autorelease pool.

The source schema requires pattern and allows path, limit, literal and ignoreCase.
Preparation preserves raw calls. Optional null fields disappear; required null
pattern becomes an empty string. Boolean strings true/false and numbers 1/0
coerce exactly as in PiProviderRules; other values remain unchanged. Only actual
boolean true enables a native option. Key validation still occurs before worker
admission, followed by path, pattern and limit validation inside the worker.

The complete bounded scan occurs before regex compilation. NSRegularExpression
uses Foundation literal escaping when requested, only its case-insensitive option
when requested, and firstMatch with a UTF-16 NSString range for each entire line.
There is no Rust-regex approximation. Native compilation errors retain an owned
NSError domain/code/message for direct callers. The session runtime emits the
source's generic non-AgentError failure text, and cancellation takes precedence
over a simultaneous native error. Historical failures are never replayed.

## Bounded reads and exact line behavior

The private reader follows Support.readBounded: nonblocking close-on-exec open,
fstat of the opened descriptor, regular-file and 2 MiB size checks, a single
Foundation read of at most maximum + 1 bytes, a returned-size check, and close on
every exit. Foundation performs UTF-8 decoding. Open/type/size/read/decoding
failures skip the candidate. The final target may be a symlink as in the source;
this is not an O_NOFOLLOW restriction or a prior path-based metadata check.
Embedded NUL follows source C-string termination, and valid UTF-8 containing NUL
remains searchable. Directories are not read.

Lines split only on LF, preserve CR, and include empty-file and trailing-LF empty
lines. Each line produces at most one hit, formatted as relative-path:line-number:
followed by a space and a 1,000-byte source preview. Matching uses the complete
bounded line before previewing. The joined output receives the existing
32,768-byte preview and exact source footer. No stats or invented match totals
are added.

Native validation accepts limit zero. A directory reaches the outer limit check;
a readable file evaluates its first line; a skipped read continues before that
check. Matching exactly the limit reports limited without looking ahead. These
quirks are tested rather than simplified.

Cancellation is cooperative between enumeration entries, candidates and lines.
Synchronous Foundation reads and regex matches are not forcibly interrupted;
worker occupancy is retained until the operation returns. No hard regex-time
bound is claimed and pathological regexes are not executed by the fixtures.

## Validation boundary

Pure scanner/reader/matcher fixtures exercise ordering, read-failure continuation,
zero limits, Unicode, line boundaries, previews and cancellation. Focused schema,
capability and runtime-error cases cover admission and truthful failure rendering.
The shared native Swift oracle uses current checked-in source and disposable
fixtures, including bounded text/invalid UTF-8, native regex features and errors,
UTF-16, size limits and a FIFO. Its entire test runs in a bounded subprocess so a
nonblocking-open regression cannot hang the runner indefinitely. A loopback
provider fixture checks a mixed ls/find/grep batch, raw arguments, error text,
durable continuation and reopen without reexecution.

Darwin metadata compilation checks API compatibility only. Actual macOS Swift
oracle and runtime execution remain required before native parity is claimed.
Mount creation, permission mutation, user-home expansion and GUI enablement are
outside this fixture scope. Only existing locked dependency versions are used.
