// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include "DefaultAction.h"

namespace nc::panel::actions {

// Flips the global filePanel.general.topBottomPanelsLayout config setting; all windows observe it.
struct TogglePanelsOrientation final : StateAction {
    [[nodiscard]] bool ValidateMenuItem(MainWindowFilePanelState *_target, NSMenuItem *_item) const override;
    void Perform(MainWindowFilePanelState *_target, id _sender) const override;
};

} // namespace nc::panel::actions
