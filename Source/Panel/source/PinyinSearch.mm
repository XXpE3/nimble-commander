// Copyright (C) 2013-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "PanelDataFilter.h"
#include <Foundation/Foundation.h>
#include <Base/CFPtr.h>
#include <Base/dispatch_cpp.h>
#include <Base/UnorderedUtil.h>
#include <algorithm>
#include <ankerl/unordered_dense.h>
#include <array>
#include <chrono>
#include <memory>
#include <memory_resource>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

namespace nc::panel::data {

// PinyinSearch() matches an ASCII alphanumeric query against the Hanyu Pinyin transliteration of
// the Han characters of a filename. Two expansions are built per filename: the full syllables,
// e.g. 科技内容.pdf -> "kejineirong.pdf", and the syllable initials, e.g. "kjnr.pdf". The first
// expansion producing a match wins and provides the highlighting, which is mapped back onto the
// ranges of the original filename. Non-Han parts of the filename, e.g. digits, dots and
// extensions, are carried over verbatim and remain matchable. The expansions are built with ICU
// via CFStringTransform( MandarinLatin + StripDiacritics ) and are cached per filename.

namespace {

using namespace std::chrono_literals;

// it was deliberately chosen to use the most dumb method to purge the cache, mirroring the
// approach of TextWidthsCache. Unlike TextWidthsCache, whose records are tiny, a record here
// comprises two CFStrings and two source vectors - hundreds of bytes or more per filename - so
// the capacity is set an order of magnitude lower to bound the resident memory.
static const auto g_MaxEntries = 1'000;
static const auto g_PurgeDelay = 20min;

// A backward mapping from a UTF-16 unit of an expansion to the range of the original filename
// which has produced this unit.
struct SourceRef {
    uint32_t offset; // the UTF-16 offset in the original filename
    uint8_t length; // the UTF-16 length in the original filename, either 1 or 2
    bool is_han; // true when this unit belongs to a pinyin syllable of a Han character
};

// An immutable pinyin expansion of a filename. Once published in the cache it is never modified.
struct Expansion {
    base::CFPtr<CFStringRef> text; // the expansion itself
    std::vector<SourceRef> sources; // one entry per each UTF-16 unit of 'text'
};

struct Expansions {
    Expansion full; // e.g. "kejineirong.pdf"
    Expansion initials; // e.g. "kjnr.pdf"
};

struct ExpansionsBuilder {
    void AppendRawUnit(UniChar _c, uint32_t _offset, uint8_t _length)
    {
        const SourceRef src{.offset = _offset, .length = _length, .is_han = false};
        full_chars.push_back(_c);
        full_sources.push_back(src);
        init_chars.push_back(_c);
        init_sources.push_back(src);
    }

    void AppendSyllable(std::string_view _syllable, uint32_t _offset, uint8_t _length)
    {
        assert(!_syllable.empty());
        for( const char c : _syllable ) {
            const SourceRef src{.offset = _offset, .length = _length, .is_han = true};
            full_chars.push_back(static_cast<UniChar>(c));
            full_sources.push_back(src);
        }
        init_chars.push_back(static_cast<UniChar>(_syllable.front()));
        init_sources.push_back(SourceRef{.offset = _offset, .length = _length, .is_han = true});
    }

    std::shared_ptr<const Expansions> Finish()
    {
        auto expansions = std::make_shared<Expansions>();
        expansions->full.text = base::CFPtr<CFStringRef>::adopt(
            CFStringCreateWithCharacters(nullptr, full_chars.data(), full_chars.size()));
        expansions->initials.text = base::CFPtr<CFStringRef>::adopt(
            CFStringCreateWithCharacters(nullptr, init_chars.data(), init_chars.size()));
        expansions->full.sources = std::move(full_sources);
        expansions->initials.sources = std::move(init_sources);
        if( !expansions->full.text || !expansions->initials.text )
            return nullptr;
        return expansions;
    }

    std::vector<UniChar> full_chars, init_chars;
    std::vector<SourceRef> full_sources, init_sources;
};

bool IsHanScalar(uint32_t _s) noexcept
{
    return ( _s == 0x3007 ) ||                     // 〇
           ( _s >= 0x3400 && _s <= 0x4DBF ) ||     // U+3400..U+4DBF
           ( _s >= 0x4E00 && _s <= 0x9FFF ) ||     // U+4E00..U+9FFF
           ( _s >= 0xF900 && _s <= 0xFAFF ) ||     // U+F900..U+FAFF
           ( _s >= 0x20000 && _s <= 0x323AF );     // U+20000..U+323AF
}

struct DecodedScalar {
    uint32_t scalar;
    size_t units;
};

// Decodes a Unicode scalar value at _i, pairing surrogates when possible.
// Unpaired surrogates are reported as regular one-unit values.
DecodedScalar DecodeScalar(const std::vector<UniChar> &_chars, size_t _i) noexcept
{
    const UniChar c = _chars[_i];
    if( c >= 0xD800 && c <= 0xDBFF && _i + 1 < _chars.size() && _chars[_i + 1] >= 0xDC00 &&
        _chars[_i + 1] <= 0xDFFF ) {
        const auto hi = static_cast<uint32_t>(c) - 0xD800;
        const auto lo = static_cast<uint32_t>(_chars[_i + 1]) - 0xDC00;
        return DecodedScalar{.scalar = 0x10000 + ( hi << 10 ) + lo, .units = 2};
    }
    return DecodedScalar{.scalar = c, .units = 1};
}

// Applies the ICU transliteration to a copy of _string: first Mandarin Latin, then stripping the
// tone diacritics, e.g. 女 -> "nǚ" -> "nu". Returns the whitespace-separated tokens of the result.
// Characters outside of ASCII are folded into a '?' placeholder, so that they can never pass the
// letters-only validation of the callers.
std::vector<std::string> TransliterateToTokens(CFStringRef _string)
{
    const auto mut = base::CFPtr<CFMutableStringRef>::adopt(CFStringCreateMutableCopy(nullptr, 0, _string));
    if( !mut )
        return {};

    CFStringTransform(mut.get(), nullptr, kCFStringTransformMandarinLatin, false);
    CFStringTransform(mut.get(), nullptr, kCFStringTransformStripDiacritics, false);

    std::vector<std::string> tokens;
    std::string current;
    const auto length = CFStringGetLength(mut.get());
    for( long i = 0; i != length; ++i ) {
        const UniChar c = CFStringGetCharacterAtIndex(mut.get(), i);
        if( c == ' ' || c == '\t' || c == '\n' || c == '\r' ) {
            if( !current.empty() )
                tokens.push_back(std::move(current));
            current.clear();
        }
        else if( c >= 'A' && c <= 'Z' ) {
            current.push_back(static_cast<char>(c - 'A' + 'a'));
        }
        else if( c < 128 ) {
            current.push_back(static_cast<char>(c));
        }
        else {
            current.push_back('?');
        }
    }
    if( !current.empty() )
        tokens.push_back(std::move(current));
    return tokens;
}

bool IsASCIILetters(std::string_view _token) noexcept
{
    if( _token.empty() )
        return false;
    for( const char c : _token )
        if( c < 'a' || c > 'z' )
            return false;
    return true;
}

struct ScalarPos {
    uint32_t offset;
    uint8_t length;
};

// Appends the pinyin of a contiguous run of Han characters located at [_from, _to) of _chars.
void AppendHanRun(const std::vector<UniChar> &_chars, size_t _from, size_t _to, ExpansionsBuilder &_builder)
{
    // remember the position of every Unicode scalar of the run
    std::vector<ScalarPos> positions;
    positions.reserve(_to - _from);
    for( size_t i = _from; i != _to; ) {
        const auto d = DecodeScalar(_chars, i);
        positions.push_back(ScalarPos{.offset = static_cast<uint32_t>(i), .length = static_cast<uint8_t>(d.units)});
        i += d.units;
    }
    assert(!positions.empty());

    // 1st - try to transliterate the whole run at once, so that ICU can use the word context,
    // e.g. 重庆 -> "chong qing" instead of "zhong qing"
    const auto run = base::CFPtr<CFStringRef>::adopt(
        CFStringCreateWithCharacters(nullptr, _chars.data() + _from, _to - _from));
    if( run ) {
        const auto tokens = TransliterateToTokens(run.get());
        if( tokens.size() == positions.size() &&
            std::all_of(tokens.begin(), tokens.end(), [](const auto &_token) { return IsASCIILetters(_token); }) ) {
            for( size_t i = 0; i != positions.size(); ++i )
                _builder.AppendSyllable(tokens[i], positions[i].offset, positions[i].length);
            return;
        }
    }

    // 2nd - the context-sensitive conversion has failed the sanity checks - e.g. supplementary
    // plane characters can produce merged syllables, like 科技𠀀内容 -> "ke ji henei rong", which
    // would be misaligned by a naive whitespace mapping. Fall back to transliterating every
    // character on its own. When a character yields anything but a single ASCII letters-only
    // token, its original UTF-16 content is carried over verbatim instead, forming a boundary
    // which ASCII queries cannot match across.
    for( const auto &pos : positions ) {
        const auto single = base::CFPtr<CFStringRef>::adopt(
            CFStringCreateWithCharacters(nullptr, _chars.data() + pos.offset, pos.length));
        const auto tokens = single ? TransliterateToTokens(single.get()) : std::vector<std::string>{};
        if( tokens.size() == 1 && IsASCIILetters(tokens[0]) ) {
            _builder.AppendSyllable(tokens[0], pos.offset, pos.length);
        }
        else {
            for( uint8_t u = 0; u != pos.length; ++u )
                _builder.AppendRawUnit(_chars[pos.offset + u], pos.offset, pos.length);
        }
    }
}

std::shared_ptr<const Expansions> BuildExpansions(CFStringRef _filename)
{
    const auto length = CFStringGetLength(_filename);
    std::vector<UniChar> chars(length == 0 ? 0 : length, '\0');
    if( length != 0 )
        CFStringGetCharacters(_filename, CFRangeMake(0, length), chars.data());

    ExpansionsBuilder builder;
    for( size_t i = 0; i != chars.size(); ) {
        const auto d = DecodeScalar(chars, i);
        if( !IsHanScalar(d.scalar) ) {
            for( size_t u = 0; u != d.units; ++u )
                builder.AppendRawUnit(chars[i + u], static_cast<uint32_t>(i + u), 1);
            i += d.units;
            continue;
        }

        // extend the run of Han characters as far as possible
        size_t j = i;
        while( j != chars.size() ) {
            const auto dec = DecodeScalar(chars, j);
            if( !IsHanScalar(dec.scalar) )
                break;
            j += dec.units;
        }
        AppendHanRun(chars, i, j, builder);
        i = j;
    }
    return builder.Finish();
}

bool HasHan(CFStringRef _filename) noexcept
{
    const auto length = CFStringGetLength(_filename);
    for( long i = 0; i != length; ++i ) {
        const UniChar c = CFStringGetCharacterAtIndex(_filename, i);
        if( IsHanScalar(c) )
            return true;
        if( c >= 0xD800 && c <= 0xDBFF && i + 1 != length ) {
            const UniChar c2 = CFStringGetCharacterAtIndex(_filename, i + 1);
            if( c2 >= 0xDC00 && c2 <= 0xDFFF ) {
                const auto hi = static_cast<uint32_t>(c) - 0xD800;
                const auto lo = static_cast<uint32_t>(c2) - 0xDC00;
                if( IsHanScalar(0x10000 + ( hi << 10 ) + lo) )
                    return true;
                ++i; // skip the low surrogate as well
            }
        }
    }
    return false;
}

struct CFStringHashEqual {
    using is_transparent = void;

    // hashes
    size_t operator()(const base::CFPtr<CFStringRef> &_string) const noexcept { return (*this)(_string.get()); }
    size_t operator()(CFStringRef _string) const noexcept
    {
        assert(_string != nullptr);
        return CFHash(_string);
    }

    // equality
    bool operator()(const base::CFPtr<CFStringRef> &_lhs, const base::CFPtr<CFStringRef> &_rhs) const noexcept
    {
        return (*this)(_lhs.get(), _rhs.get());
    }
    bool operator()(const base::CFPtr<CFStringRef> &_lhs, CFStringRef _rhs) const noexcept
    {
        return (*this)(_lhs.get(), _rhs);
    }
    bool operator()(CFStringRef _lhs, const base::CFPtr<CFStringRef> &_rhs) const noexcept
    {
        return (*this)(_lhs, _rhs.get());
    }
    bool operator()(CFStringRef _lhs, CFStringRef _rhs) const noexcept
    {
        return ( _lhs == _rhs ) || ( CFStringCompare(_lhs, _rhs, 0) == kCFCompareEqualTo );
    }
};

struct Cache {
    using ExpansionsMap = ankerl::unordered_dense::
        map<base::CFPtr<CFStringRef>, std::shared_ptr<const Expansions>, CFStringHashEqual, CFStringHashEqual>;
    ExpansionsMap expansions;
    std::mutex lock;
    bool purge_scheduled = false; // guarded by 'lock'
};

Cache &CacheInstance()
{
    [[clang::no_destroy]] static Cache inst;
    return inst;
}

void PurgeCache(Cache &_cache)
{
    {
        const auto lock = std::lock_guard{_cache.lock};
        _cache.expansions.clear();
        _cache.purge_scheduled = false;
    }
}

void PurgeCacheIfNeeded(Cache &_cache)
{
    const auto lock = std::lock_guard{_cache.lock};
    if( _cache.expansions.size() >= g_MaxEntries && !_cache.purge_scheduled ) {
        _cache.purge_scheduled = true;
        dispatch_to_background_after(g_PurgeDelay, [&_cache] { PurgeCache(_cache); });
    }
}

// Returns the expansions of _filename, building and caching them when necessary.
// Returns nullptr when the expansions could not be built.
std::shared_ptr<const Expansions> GetExpansions(CFStringRef _filename)
{
    auto &cache = CacheInstance();
    {
        const auto lock = std::lock_guard{cache.lock};
        if( const auto it = cache.expansions.find(_filename); it != cache.expansions.end() )
            return it->second;
    }

    auto expansions = BuildExpansions(_filename);
    if( !expansions )
        return nullptr;

    {
        const auto lock = std::lock_guard{cache.lock};
        const auto [it, inserted] = cache.expansions.emplace(base::CFPtr<CFStringRef>(_filename), expansions);
        static_cast<void>(inserted);
        expansions = it->second; // a concurrent build might have won the race - use the stored one
    }
    PurgeCacheIfNeeded(cache);
    return expansions;
}

UniChar FoldASCIILower(UniChar _c) noexcept
{
    return ( _c >= 'A' && _c <= 'Z' ) ? static_cast<UniChar>(_c - 'A' + 'a') : _c;
}

// The equivalence rule of the query and the expansion characters: ASCII case-insensitive
// comparison, plus the query 'v' can match the 'u' of a pinyin syllable, i.e. both "nv" and "nu"
// match 女, both "lv" and "lu" match 绿, both "lve" and "lue" match 略. A literal 'u' of the
// filename is matched only by 'u' queries.
bool CharsMatch(UniChar _query, UniChar _expansion, bool _expansion_is_han) noexcept
{
    const UniChar q = FoldASCIILower(_query);
    const UniChar e = FoldASCIILower(_expansion);
    if( q == e )
        return true;
    return q == 'v' && e == 'u' && _expansion_is_han;
}

constexpr size_t g_NoMatch = std::numeric_limits<size_t>::max();

// Tries to continuously match _query at _at. Returns the end (exclusive) index or g_NoMatch.
size_t MatchAt(const Expansion &_expansion, NSString *_query, size_t _at) noexcept
{
    const auto qlen = _query.length;
    if( qlen > _expansion.sources.size() || _at > _expansion.sources.size() - qlen )
        return g_NoMatch;
    for( size_t q = 0; q != qlen; ++q ) {
        const size_t e = _at + q;
        const UniChar c = CFStringGetCharacterAtIndex(_expansion.text.get(), e);
        if( !CharsMatch([_query characterAtIndex:q], c, _expansion.sources[e].is_han) )
            return g_NoMatch;
    }
    return _at + qlen;
}

using OptMatch = std::optional<std::pair<size_t, size_t>>; // [begin, end) within the expansion

OptMatch SearchBeginning(const Expansion &_expansion, NSString *_query) noexcept
{
    const auto end = MatchAt(_expansion, _query, 0);
    if( end == g_NoMatch )
        return {};
    return std::make_pair(size_t{0}, end);
}

OptMatch SearchAnywhere(const Expansion &_expansion, NSString *_query) noexcept
{
    const auto qlen = _query.length;
    if( qlen == 0 || qlen > _expansion.sources.size() )
        return {};
    for( size_t at = 0; at <= _expansion.sources.size() - qlen; ++at ) {
        if( const auto end = MatchAt(_expansion, _query, at); end != g_NoMatch )
            return std::make_pair(at, end);
    }
    return {};
}

OptMatch SearchEnding(const Expansion &_expansion, NSString *_query, bool _has_extension) noexcept
{
    const auto qlen = _query.length;
    if( qlen == 0 || qlen > _expansion.sources.size() )
        return {};

    if( _has_extension ) {
        // slow path here - look before the extension. The last '.' of the expansion can only
        // originate from the filename itself, as pinyin syllables consist of letters only.
        auto dot = g_NoMatch;
        for( long i = static_cast<long>(_expansion.sources.size()) - 1; i >= 0; --i ) {
            if( CFStringGetCharacterAtIndex(_expansion.text.get(), i) == '.' ) {
                dot = static_cast<size_t>(i);
                break;
            }
        }
        if( dot != g_NoMatch && dot > qlen && MatchAt(_expansion, _query, dot - qlen) != g_NoMatch )
            return std::make_pair(dot - qlen, dot);
    }

    // look at the very end at last
    const size_t begin = _expansion.sources.size() - qlen;
    if( MatchAt(_expansion, _query, begin) != g_NoMatch )
        return std::make_pair(begin, _expansion.sources.size());

    return {};
}

// Greedily finds _query as a subsequence of the expansion, recording the index of every hit.
bool SearchFuzzy(const Expansion &_expansion, NSString *_query, std::pmr::vector<size_t> &_hits) noexcept
{
    const size_t elen = _expansion.sources.size();
    const auto qlen = _query.length;
    size_t at = 0;
    for( size_t q = 0; q != qlen; ++q ) {
        while( true ) {
            if( at == elen )
                return false;
            const UniChar c = CFStringGetCharacterAtIndex(_expansion.text.get(), at);
            if( CharsMatch([_query characterAtIndex:q], c, _expansion.sources[at].is_han) )
                break;
            ++at;
        }
        _hits.push_back(at++);
    }
    return true;
}

// Merges the source ranges of the given expansion indices, which must be in ascending order,
// collapsing overlapping and adjacent ranges.
template <typename TIndexProducer>
QuickSearchHighlight BuildHighlightImpl(const Expansion &_expansion, TIndexProducer _produce)
{
    std::array<char, 16384> mem_buffer;
    std::pmr::monotonic_buffer_resource mem_resource(mem_buffer.data(), mem_buffer.size());
    std::pmr::vector<QuickSearchHighlight::Range> ranges(&mem_resource);

    _produce([&](size_t _expansion_index) {
        const SourceRef &src = _expansion.sources[_expansion_index];
        if( !ranges.empty() && ranges.back().offset + ranges.back().length >= src.offset ) {
            const size_t end = std::max(ranges.back().offset + ranges.back().length, size_t{src.offset} + src.length);
            ranges.back().length = end - ranges.back().offset;
        }
        else {
            ranges.push_back(QuickSearchHighlight::Range{.offset = src.offset, .length = src.length});
        }
    });

    // QuickSearchHighlight packing is lossy - it might discard some segments, but this must not
    // change the outcome of the matching itself.
    return QuickSearchHighlight({ranges.data(), ranges.size()});
}

QuickSearchHighlight BuildHighlight(const Expansion &_expansion, const OptMatch &_match)
{
    return BuildHighlightImpl(_expansion, [&_match](auto &&_sink) {
        for( size_t i = _match->first; i != _match->second; ++i )
            _sink(i);
    });
}

QuickSearchHighlight BuildHighlight(const Expansion &_expansion, const std::pmr::vector<size_t> &_hits)
{
    return BuildHighlightImpl(_expansion, [&_hits](auto &&_sink) {
        for( const size_t i : _hits )
            _sink(i);
    });
}

std::optional<QuickSearchHighlight> SearchExpansion(const Expansion &_expansion,
                                                    NSString *_query,
                                                    TextualFilter::Where _type,
                                                    bool _has_extension) noexcept
{
    switch( _type ) {
        case TextualFilter::Anywhere: {
            const auto match = SearchAnywhere(_expansion, _query);
            if( !match )
                return {};
            return BuildHighlight(_expansion, match);
        }
        case TextualFilter::Beginning: {
            const auto match = SearchBeginning(_expansion, _query);
            if( !match )
                return {};
            return BuildHighlight(_expansion, match);
        }
        case TextualFilter::Ending: {
            const auto match = SearchEnding(_expansion, _query, _has_extension);
            if( !match )
                return {};
            return BuildHighlight(_expansion, match);
        }
        case TextualFilter::BeginningOrEnding: {
            if( const auto match = SearchBeginning(_expansion, _query) )
                return BuildHighlight(_expansion, match);
            const auto match = SearchEnding(_expansion, _query, _has_extension);
            if( !match )
                return {};
            return BuildHighlight(_expansion, match);
        }
        case TextualFilter::Fuzzy: {
            std::array<char, 16384> mem_buffer;
            std::pmr::monotonic_buffer_resource mem_resource(mem_buffer.data(), mem_buffer.size());
            std::pmr::vector<size_t> hits(&mem_resource);
            if( !SearchFuzzy(_expansion, _query, hits) )
                return {};
            return BuildHighlight(_expansion, hits);
        }
    }
    return {};
}

} // namespace

std::optional<QuickSearchHighlight> PinyinSearch(NSString *_filename,
                                                 NSString *_text,
                                                 TextualFilter::Where _type,
                                                 bool _has_extension) noexcept
{
    assert(_filename != nil);
    assert(_text != nil);

    // the query has to be a non-empty ASCII alphanumeric string with at least one letter,
    // otherwise only the literal search applies
    const auto query_len = _text.length;
    if( query_len == 0 )
        return {};
    bool has_letter = false;
    for( size_t i = 0; i != query_len; ++i ) {
        const UniChar c = [_text characterAtIndex:i];
        if( ( c >= 'a' && c <= 'z' ) || ( c >= 'A' && c <= 'Z' ) ) {
            has_letter = true;
        }
        else if( !( c >= '0' && c <= '9' ) ) {
            return {};
        }
    }
    if( !has_letter )
        return {};

    // filenames without Han characters are not pinyin-searchable
    const base::CFPtr<CFStringRef> filename =
        base::CFPtr<CFStringRef>::adopt(static_cast<CFStringRef>(CFBridgingRetain(_filename)));
    if( !HasHan(filename.get()) )
        return {};

    const auto expansions = GetExpansions(filename.get());
    if( !expansions )
        return {};

    // the first expansion producing a match wins and provides the highlighting
    if( auto hl = SearchExpansion(expansions->full, _text, _type, _has_extension) )
        return hl;
    if( auto hl = SearchExpansion(expansions->initials, _text, _type, _has_extension) )
        return hl;
    return {};
}

} // namespace nc::panel::data
