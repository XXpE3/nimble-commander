// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "TogglePanelsOrientation.h"
#include <NimbleCommander/Bootstrap/Config.h>

namespace nc::panel::actions {

static const auto g_ConfigTopBottomPanelsLayout = "filePanel.general.topBottomPanelsLayout";
static const auto g_SwitchToTopBottomTitle = NSLocalizedString(
    @"Arrange Panels Top and Bottom", "Menu item title for switching the panels into a top-bottom layout");
static const auto g_SwitchToSideBySideTitle = NSLocalizedString(
    @"Arrange Panels Side by Side", "Menu item title for switching the panels into a side-by-side layout");

bool TogglePanelsOrientation::ValidateMenuItem(MainWindowFilePanelState * /*_target*/, NSMenuItem *_item) const
{
    _item.title = GlobalConfig().GetBool(g_ConfigTopBottomPanelsLayout) ? g_SwitchToSideBySideTitle
                                                                        : g_SwitchToTopBottomTitle;
    return true;
}

void TogglePanelsOrientation::Perform(MainWindowFilePanelState * /*_target*/, id /*_sender*/) const
{
    const auto top_bottom = GlobalConfig().GetBool(g_ConfigTopBottomPanelsLayout);
    GlobalConfig().Set(g_ConfigTopBottomPanelsLayout, !top_bottom);
}

} // namespace nc::panel::actions
