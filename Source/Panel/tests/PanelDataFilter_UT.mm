// Copyright (C) 2023-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include "PanelDataFilter.h"
#include <Base/dispatch_cpp.h>
#include "Tests.h"

#define PREFIX "PanelDataFilter "

namespace {

using namespace nc;
using namespace nc::panel::data;

TEST_CASE(PREFIX "Fuzzy search")
{
    using RIL = std::initializer_list<QuickSearchHighlight::Range>;
    struct TC {
        NSString *filename;
        NSString *text;
        std::optional<QuickSearchHighlight> expected;
    } test_cases[] = {
        {.filename = @"", .text = @"", .expected = QuickSearchHighlight{}},
        {.filename = @"", .text = @"a", .expected = std::nullopt},
        {.filename = @"a", .text = @"", .expected = QuickSearchHighlight{}},
        {.filename = @"a", .text = @"b", .expected = std::nullopt},
        {.filename = @"a", .text = @"a", .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}}}},
        {.filename = @"a", .text = @"ab", .expected = std::nullopt},
        {.filename = @"ab", .text = @"ab", .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"ba", .text = @"ab", .expected = std::nullopt},
        {.filename = @"aaa", .text = @"a", .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}}}},
        {.filename = @"aaa", .text = @"aa", .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"aaa", .text = @"aaa", .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 3}}}},
        {.filename = @"abc",
         .text = @"ac",
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}, {.offset = 2, .length = 1}}}},
        {.filename = @"aab", .text = @"ab", .expected = QuickSearchHighlight{RIL{{.offset = 1, .length = 2}}}},
        {.filename = @"abcabc", .text = @"abc", .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 3}}}},
        {.filename = @"abcabc",
         .text = @"abab",
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}, {.offset = 3, .length = 2}}}},
        {.filename = @"abcabc", .text = @"cabc", .expected = QuickSearchHighlight{RIL{{.offset = 2, .length = 4}}}},
        {.filename = @"abcabc",
         .text = @"bbc",
         .expected = QuickSearchHighlight{RIL{{.offset = 1, .length = 1}, {.offset = 4, .length = 2}}}},
        {.filename = @"abcabc",
         .text = @"acc",
         .expected = QuickSearchHighlight{RIL{
             {.offset = 0, .length = 1}, {.offset = 2, .length = 1}, {.offset = 5, .length = 1}}}},
        {.filename = @"Calculator.app",
         .text = @"calap",
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 3}, {.offset = 11, .length = 2}}}},
        {.filename = @"Calculator.app",
         .text = @"calapp",
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 3}, {.offset = 11, .length = 3}}}},
        {.filename = @"Calculator.app",
         .text = @"calcapp",
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 4}, {.offset = 11, .length = 3}}}},
        {.filename = @"Calculator.app",
         .text = @"culap",
         .expected = QuickSearchHighlight{RIL{{.offset = 3, .length = 4}, {.offset = 12, .length = 1}}}},
        {.filename = @"Calculator.app",
         .text = @"app",
         .expected = QuickSearchHighlight{RIL{{.offset = 11, .length = 3}}}},
    };
    for( auto &tc : test_cases ) {
        auto hl = FuzzySearch(tc.filename, tc.text);
        CHECK(hl == tc.expected);
    }
}

TEST_CASE(PREFIX "Pinyin search")
{
    using RIL = std::initializer_list<QuickSearchHighlight::Range>;
    using Where = TextualFilter::Where;
    struct TC {
        NSString *filename;
        NSString *text;
        Where type;
        bool has_extension;
        std::optional<QuickSearchHighlight> expected;
    } test_cases[] = {
        {.filename = @"科技内容.pdf",
         .text = @"keji",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"科技内容.pdf",
         .text = @"kejineirong",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 4}}}},
        {.filename = @"科技内容.pdf",
         .text = @"kj",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"科技内容.pdf",
         .text = @"kjnr",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 4}}}},
        {.filename = @"科技内容.pdf",
         .text = @"kej",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"科技内容.pdf",
         .text = @"neirong",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 2, .length = 2}}}},
        {.filename = @"科技内容.pdf",
         .text = @"neirong",
         .type = Where::Beginning,
         .has_extension = true,
         .expected = std::nullopt},
        {.filename = @"科技内容.pdf",
         .text = @"keji",
         .type = Where::Beginning,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"科技内容.pdf",
         .text = @"neirong",
         .type = Where::Ending,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 2, .length = 2}}}},
        {.filename = @"科技内容.pdf",
         .text = @"keji",
         .type = Where::Ending,
         .has_extension = true,
         .expected = std::nullopt},
        {.filename = @"科技内容.pdf",
         .text = @"neirong",
         .type = Where::BeginningOrEnding,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 2, .length = 2}}}},
        {.filename = @"科技内容.pdf",
         .text = @"kjo",
         .type = Where::Fuzzy,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}, {.offset = 3, .length = 1}}}},
        {.filename = @"这里.pdf",
         .text = @"zheli",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"这里.pdf",
         .text = @"zl",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"的.pdf",
         .text = @"de",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}}}},
        {.filename = @"科技2.pdf",
         .text = @"keji2",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 3}}}},
        {.filename = @"編輯.pdf",
         .text = @"bianji",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"重庆.pdf",
         .text = @"chongqing",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"女.pdf",
         .text = @"nv",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}}}},
        {.filename = @"女.pdf",
         .text = @"nu",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}}}},
        {.filename = @"绿.pdf",
         .text = @"lv",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}}}},
        {.filename = @"绿.pdf",
         .text = @"lu",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}}}},
        {.filename = @"略.pdf",
         .text = @"lve",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}}}},
        {.filename = @"略.pdf",
         .text = @"lue",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}}}},
        {.filename = @"v科技.pdf",
         .text = @"vkeji",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 3}}}},
        {.filename = @"u科技.pdf",
         .text = @"vkeji",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = std::nullopt},
        {.filename = @"科技𠀀内容.pdf",
         .text = @"kejihe",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 4}}}},
        {.filename = @"科技𠀀内容.pdf",
         .text = @"neirong",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 4, .length = 2}}}},
        {.filename = @"科技内容.pdf",
         .text = @"xyz",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = std::nullopt},
        {.filename = @"keji.txt",
         .text = @"keji",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = std::nullopt},
        {.filename = @"科技ke-ji.pdf",
         .text = @"ke-ji",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = std::nullopt},
        {.filename = @"科技2026.pdf",
         .text = @"2026",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = std::nullopt},
        {.filename = @"科技内容.pdf",
         .text = @"",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = std::nullopt},
        {.filename = @"科技内容.pdf",
         .text = @"KEJI",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"科技内容.pdf",
         .text = @"kejineirongpdfxx",
         .type = Where::Anywhere,
         .has_extension = true,
         .expected = std::nullopt},
        {.filename = @"科技内容",
         .text = @"neirong",
         .type = Where::Ending,
         .has_extension = false,
         .expected = QuickSearchHighlight{RIL{{.offset = 2, .length = 2}}}},
        {.filename = @"科技.pdf",
         .text = @"keji",
         .type = Where::Ending,
         .has_extension = true,
         .expected = std::nullopt},
        {.filename = @"科技内容.pdf",
         .text = @"keji",
         .type = Where::BeginningOrEnding,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"科技内容.pdf",
         .text = @"kjnr",
         .type = Where::Beginning,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 4}}}},
        {.filename = @"科技内容.pdf",
         .text = @"nr",
         .type = Where::Ending,
         .has_extension = true,
         .expected = QuickSearchHighlight{RIL{{.offset = 2, .length = 2}}}},
    };
    for( auto &tc : test_cases ) {
        auto hl = PinyinSearch(tc.filename, tc.text, tc.type, tc.has_extension);
        CHECK(hl == tc.expected);
    }
}

TEST_CASE(PREFIX "Pinyin search highlight capacity")
{
    // nine disjoint source ranges have to be lossily packed into the 8-segment QuickSearchHighlight,
    // without turning the engaged match into a no-match
    NSString *const filename = @"科 技 内 容 这 里 记 录 每.pdf";
    auto hl = PinyinSearch(filename, @"kjnrzljlm", TextualFilter::Where::Fuzzy, true);
    REQUIRE(hl.has_value());
    CHECK(!hl->empty());
    const auto ranges = hl->unpack();
    CHECK(ranges.count != 0);
    CHECK(ranges.count <= QuickSearchHighlight::max_len);
    for( size_t i = 0; i != ranges.count; ++i ) {
        CHECK(ranges.segments[i].length != 0);
        CHECK(ranges.segments[i].offset + ranges.segments[i].length <= filename.length);
    }
}

TEST_CASE(PREFIX "Pinyin search concurrent cache")
{
    constexpr size_t names_count = 32;
    constexpr size_t rounds_per_name = 64;

    std::vector<NSString *> names;
    for( size_t i = 0; i != names_count; ++i )
        names.emplace_back([NSString stringWithFormat:@"科技内容%02zu.pdf", i]);

    const size_t total = names_count * rounds_per_name;
    std::vector<std::optional<QuickSearchHighlight>> results(total);
    dispatch_apply(total, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), [&](size_t _iteration) {
        results[_iteration] =
            PinyinSearch(names[_iteration % names_count], @"keji", TextualFilter::Where::Anywhere, true);
    });

    const QuickSearchHighlight expected{std::initializer_list<QuickSearchHighlight::Range>{{.offset = 0, .length = 2}}};
    for( auto &result : results )
        CHECK(result == expected);
}

} // namespace

#undef PREFIX
