// Copyright (C) 2017-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <VFS/VFSDeclarations.h>
#include <CoreFoundation/CoreFoundation.h>

#include "PanelDataItemVolatileData.h"

#include <compare>
#include <optional>

namespace nc::panel::data {

struct TextualFilter {
    enum Where : int8_t // persistancy-bound values, don't change it
    {
        Anywhere = 0,
        Beginning = 1,
        Ending = 2, // handling extensions somehow
        BeginningOrEnding = 3,
        Fuzzy = 4
    };

    NSString *text;
    Where type = Where::Anywhere;

    // will not apply filter on dot-dot entries
    bool ignore_dot_dot : 1 = true;

    // if true then PanelData will automatically set text to nil on Load method call
    bool clear_on_new_listing : 1 = false;

    // option for PanelData to mark QS hightlight
    bool hightlight_results : 1 = true;

    constexpr TextualFilter() noexcept = default;
    bool operator==(const TextualFilter &_r) const noexcept;
    bool operator!=(const TextualFilter &_r) const noexcept;
    static Where WhereFromInt(int _v) noexcept;
    static TextualFilter NoFilter() noexcept;
    bool IsValidItem(const VFSListingItem &_item, QuickSearchHighlight &_found_range) const;
    [[nodiscard]] bool IsValidItem(const VFSListingItem &_item) const;
    void OnPanelDataLoad();
    [[nodiscard]] bool IsFiltering() const noexcept;
} __attribute__((packed));

struct HardFilter {
    TextualFilter text = TextualFilter::NoFilter();
    bool show_hidden = true;
    bool IsValidItem(const VFSListingItem &_item, QuickSearchHighlight &_found_range) const;
    [[nodiscard]] bool IsFiltering() const noexcept;
    bool operator==(const HardFilter &_r) const noexcept = default;
    bool operator!=(const HardFilter &_r) const noexcept = default;
};

std::optional<QuickSearchHighlight> FuzzySearch(NSString *_filename, NSString *_text) noexcept;

// Matches an ASCII alphanumeric query (with at least one letter) against the Hanyu Pinyin
// transliteration of the Han characters of the filename, searching either the full syllables,
// e.g. "keji" for 科技, or the syllable initials, e.g. "kj". Non-Han parts of the filename are
// carried over verbatim and remain matchable. Returns no value when the query is not eligible,
// when the filename has no Han characters, or when there is no match.
std::optional<QuickSearchHighlight> PinyinSearch(NSString *_filename,
                                                 NSString *_text,
                                                 TextualFilter::Where _type,
                                                 bool _has_extension) noexcept;

} // namespace nc::panel::data
