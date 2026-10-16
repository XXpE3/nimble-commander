// Copyright (C) 2013-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include <NimbleCommander/States/FilePanels/PanelView.h>
#include <NimbleCommander/Bootstrap/AppDelegate.h>
#include <NimbleCommander/Core/Theming/Theme.h>
#include <NimbleCommander/Core/Theming/ThemesManager.h>
#include "FilePanelsTabbedHolder.h"
#include "FilePanelMainSplitView.h"
#include <Utility/ActionsShortcutsManager.h>
#include <Utility/ObjCpp.h>
#include <Base/dispatch_cpp.h>
#include <cmath>

static constexpr double g_MidGuideGap = 24.;
static constexpr double g_MinPanelExtent = 120.;
static constexpr double g_ResizingGran = 14.;
static constexpr double g_DividerThickness = 1.;

@implementation FilePanelMainSplitView {
    // if there's no overlays - these will be nils
    // if any part becomes overlayed - basic view is backed up in this array
    FilePanelsTabbedHolder *m_BasicViews[2];
    nc::ThemesManager::ObservationTicket m_ThemeChangesObservation;
    double m_PreCollapseProp; // full split-axis extent minus divider divided by the first panel extent
    const nc::utility::ActionsShortcutsManager *m_ActionsShortcutsManager;
}

- (id)initWithFrame:(NSRect)_frame
    actionsShortcutsManager:(const nc::utility::ActionsShortcutsManager &)_actions_shortcuts_manager
{
    self = [super initWithFrame:_frame];
    if( self ) {
        m_ActionsShortcutsManager = &_actions_shortcuts_manager;
        m_PreCollapseProp = 0.5;
        self.vertical = true;
        self.dividerStyle = NSSplitViewDividerStyleThin;
        self.delegate = self;

        FilePanelsTabbedHolder *th1 = [[FilePanelsTabbedHolder alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)
                                                            actionsShortcutsManager:*m_ActionsShortcutsManager
                                                                      themesManager:NCAppDelegate.me.themesManager];
        [self addSubview:th1];
        FilePanelsTabbedHolder *th2 = [[FilePanelsTabbedHolder alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)
                                                            actionsShortcutsManager:*m_ActionsShortcutsManager
                                                                      themesManager:NCAppDelegate.me.themesManager];
        [self addSubview:th2];

        __weak FilePanelMainSplitView *weak_self = self;
        m_ThemeChangesObservation = NCAppDelegate.me.themesManager.ObserveChanges(
            nc::ThemesManager::Notifications::FilePanelsGeneral, [=] { [weak_self setNeedsDisplay:true]; });
    }
    return self;
}

- (bool)topBottomPanelsLayout
{
    return !self.vertical; // NSSplitView.vertical == YES means a vertical divider, i.e. side-by-side panes
}

- (void)setTopBottomPanelsLayout:(bool)_stacked
{
    if( self.vertical == !_stacked )
        return;
    const double prop = m_PreCollapseProp; // capture BEFORE any relayout: adjustSubviews fires
                                           // splitViewDidResizeSubviews which rewrites it on the new axis
    self.vertical = !_stacked;
    if( self.anyCollapsed )
        // The captured proportion describes the old split axis and a possibly different extent,
        // so it's meaningless after the flip - fall back to an even split on the next expansion.
        m_PreCollapseProp = 2.;
    [self adjustSubviews]; // arrange subviews along the new axis; collapsed subviews stay collapsed and the visible one fills the view
    if( !self.anyCollapsed && self.subviews.count == 2 && !NSIsEmptyRect(self.frame) ) {
        const double full = _stacked ? self.frame.size.height : self.frame.size.width;
        if( full > g_DividerThickness )
            [self setPosition:std::round((full - g_DividerThickness) / prop) ofDividerAtIndex:0];
    }
    [self display];
}

- (CGFloat)dividerThickness
{
    return g_DividerThickness;
}

- (BOOL)isOpaque
{
    return true;
}

- (CGFloat)splitView:(NSSplitView *) [[maybe_unused]] _split_view
    constrainSplitPosition:(CGFloat)_proposed_position
               ofSubviewAt:(NSInteger) [[maybe_unused]] _divider_index
{
    if( _divider_index != 0 )
        return _proposed_position;

    auto mid = std::floor((self.vertical ? self.frame.size.width : self.frame.size.height) / 2.);
    if( _proposed_position > mid - g_MidGuideGap && _proposed_position < mid + g_MidGuideGap )
        return mid;

    // Explicitly floor the proposed position, since it can income with fractions, e.g. 275.50,
    // which causes interesting layout effects in the subviews.
    return std::floor(_proposed_position);
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    // I've no idea why this isn't triggered automatically.
    // Without this adjustment the subviews sometimes end up with .5 coords when switching between
    // Retina and non-Retina.
    [self adjustSubviews];
}

- (void)adjustSubviews
{
    [super adjustSubviews];

    NSArray<__kindof NSView *> *subviews = self.subviews;
    if( subviews.count < 2 ||                    //
        [self isSubviewCollapsed:subviews[0]] || //
        [self isSubviewCollapsed:subviews[1]] )
        return;

    if( NSView *left = [subviews objectAtIndex:0] ) {
        NSRect left_frame = left.frame;
        CGFloat &left_extent = self.vertical ? left_frame.size.width : left_frame.size.height;
        const double rounded_extent = std::round(left_extent);
        if( std::abs(left_extent - rounded_extent) > 0.05 ) {
            // The subviews have fractional extents, re-position them to get rid of this.
            // Find the fractional part and redistribute it amoung the two views.
            const double fraction = left_extent - rounded_extent;
            left_extent = rounded_extent;

            NSView *right = [subviews objectAtIndex:1];
            NSRect right_frame = right.frame;
            CGFloat &right_origin = self.vertical ? right_frame.origin.x : right_frame.origin.y;
            CGFloat &right_extent = self.vertical ? right_frame.size.width : right_frame.size.height;
            right_origin -= fraction;
            right_extent += fraction;

            left.frame = left_frame;
            right.frame = right_frame;
        }
    }
}

- (CGFloat)splitView:(NSSplitView *)splitView
    constrainMaxCoordinate:(CGFloat) [[maybe_unused]] proposedMaximumPosition
               ofSubviewAt:(NSInteger) [[maybe_unused]] dividerIndex
{
    return (self.vertical ? splitView.frame.size.width : splitView.frame.size.height) - g_MinPanelExtent;
}

- (CGFloat)splitView:(NSSplitView *) [[maybe_unused]] splitView
    constrainMinCoordinate:(CGFloat) [[maybe_unused]] proposedMinimumPosition
               ofSubviewAt:(NSInteger) [[maybe_unused]] dividerIndex
{
    return g_MinPanelExtent;
}

- (void)drawDividerInRect:(NSRect)rect
{
    if( auto c = nc::CurrentTheme().FilePanelsGeneralSplitterColor() ) {
        [c set];
        if( c.alphaComponent == 1. )
            NSRectFill(rect);
        else
            NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
    }
    else
        NSDrawWindowBackground(rect);
}

- (BOOL)splitView:(NSSplitView *) [[maybe_unused]] splitView canCollapseSubview:(NSView *) [[maybe_unused]] subview
{
    return true;
}

- (bool)isLeftCollapsed
{
    if( self.subviews.count == 0 )
        return false;
    return [self isSubviewCollapsed:[self.subviews objectAtIndex:0]];
}

- (bool)isRightCollapsed
{
    if( self.subviews.count < 2 )
        return false;
    return [self isSubviewCollapsed:[self.subviews objectAtIndex:1]];
}

- (bool)anyCollapsed
{
    NSArray<__kindof NSView *> *subviews = self.subviews;
    unsigned long count = subviews.count;
    return (count > 0 && [self isSubviewCollapsed:subviews[0]]) || //
           (count > 1 && [self isSubviewCollapsed:subviews[1]]);
}

- (bool)anyCollapsedOrOverlayed
{
    if( m_BasicViews[0] != nil || m_BasicViews[1] != nil )
        return true;

    if( self.subviews.count == 0 )
        return false;
    return [self isSubviewCollapsed:self.subviews[0]] || [self isSubviewCollapsed:self.subviews[1]];
}

- (void)swapViews
{
    NSView *left = self.subviews[0];
    NSView *right = self.subviews[1];

    NSRect leftrect = left.frame;
    NSRect rightrect = right.frame;

    self.subviews = @[right, left];

    left.frame = rightrect;
    right.frame = leftrect;

    std::swap(m_BasicViews[0], m_BasicViews[1]);
    m_BasicViews[0].frame = leftrect;
    m_BasicViews[1].frame = rightrect;
}

- (FilePanelsTabbedHolder *)leftTabbedHolder
{
    if( m_BasicViews[0] )
        return m_BasicViews[0];
    assert(self.subviews.count == 2);
    assert(nc::objc_cast<FilePanelsTabbedHolder>(self.subviews[0]));
    return self.subviews[0];
}

- (FilePanelsTabbedHolder *)rightTabbedHolder
{
    if( m_BasicViews[1] )
        return m_BasicViews[1];
    assert(self.subviews.count == 2);
    assert(nc::objc_cast<FilePanelsTabbedHolder>(self.subviews[1]));
    return self.subviews[1];
}

- (NSView *)leftOverlay
{
    if( m_BasicViews[0] == nil )
        return nil;
    return self.subviews[0];
}

- (NSView *)rightOverlay
{
    if( m_BasicViews[1] == nil )
        return nil;
    return self.subviews[1];
}

- (void)setLeftOverlay:(NSView *)_o
{
    NSRect leftRect = [self.subviews[0] frame];
    if( _o != nil ) {
        _o.frame = leftRect;
        if( m_BasicViews[0] ) {
            [self replaceSubview:self.subviews[0] with:_o];
        }
        else {
            m_BasicViews[0] = self.subviews[0];
            [self replaceSubview:m_BasicViews[0] with:_o];
        }
    }
    else {
        if( m_BasicViews[0] != nil ) {
            m_BasicViews[0].frame = leftRect;
            [self replaceSubview:self.subviews[0] with:m_BasicViews[0]];
            m_BasicViews[0] = nil;
        }
    }
}

- (void)setRightOverlay:(NSView *)_o
{
    NSRect rightRect = [self.subviews[1] frame];
    if( _o != nil ) {
        _o.frame = rightRect;

        if( m_BasicViews[1] ) {
            [self replaceSubview:self.subviews[1] with:_o];
        }
        else {
            m_BasicViews[1] = self.subviews[1];
            [self replaceSubview:m_BasicViews[1] with:_o];
        }
    }
    else {
        if( m_BasicViews[1] != nil ) {
            m_BasicViews[1].frame = rightRect;
            [self replaceSubview:self.subviews[1] with:m_BasicViews[1]];
            m_BasicViews[1] = nil;
        }
    }
}

- (bool)anyOverlayed
{
    return m_BasicViews[0] != nil || m_BasicViews[1] != nil;
}

- (bool)isLeftOverlayed
{
    return m_BasicViews[0] != nil;
}

- (bool)isRightOverlayed
{
    return m_BasicViews[1] != nil;
}

- (bool)isViewCollapsedOrOverlayed:(NSView *)_v
{
    if( m_BasicViews[0] == _v || m_BasicViews[1] == _v )
        return true;

    return [self isSubviewCollapsed:_v];
}

- (BOOL)performKeyEquivalent:(NSEvent *)_event
{
    struct Tags {
        int move_left = -1;
        int move_right = -1;
    };
    static const Tags tags = [&] {
        Tags t;
        t.move_left = m_ActionsShortcutsManager->TagFromAction("menu.view.panels_position.move_left").value();
        t.move_right = m_ActionsShortcutsManager->TagFromAction("menu.view.panels_position.move_right").value();
        return t;
    }();

    const std::optional<int> event_action_tag = m_ActionsShortcutsManager->FirstOfActionTagsFromShortcut(
        {reinterpret_cast<const int *>(&tags), sizeof(tags) / sizeof(int)},
        nc::utility::ActionShortcut::EventData(_event));

    if( event_action_tag == tags.move_left ) {
        [self OnViewPanelsPositionMoveLeft:self];
        return true;
    }

    if( event_action_tag == tags.move_right ) {
        [self OnViewPanelsPositionMoveRight:self];
        return true;
    }

    return [super performKeyEquivalent:_event];
}

- (IBAction)OnViewPanelsPositionMoveLeft:(id) [[maybe_unused]] sender
{
    dispatch_assert_main_queue();
    if( self.isLeftCollapsed ) {
        NSBeep();
        return;
    }
    if( self.isRightCollapsed ) {
        [self expandRightView];
        return;
    }

    NSView *v1 = self.subviews[0];
    NSView *v2 = self.subviews[1];
    NSRect left = v1.frame;
    NSRect right = v2.frame;

    CGFloat &left_extent = self.vertical ? left.size.width : left.size.height;
    CGFloat &right_origin = self.vertical ? right.origin.x : right.origin.y;
    CGFloat &right_extent = self.vertical ? right.size.width : right.size.height;

    auto gran = g_ResizingGran;

    left_extent -= gran;
    right_origin -= gran;
    right_extent += gran;
    if( left_extent < 0 ) {
        right_origin -= left_extent;
        right_extent += left_extent;
        left_extent = 0;
    }

    if( left_extent < g_MinPanelExtent ) {
        [self collapseLeftView];
        if( auto h = nc::objc_cast<FilePanelsTabbedHolder>(v2) )
            [self.window makeFirstResponder:h.current];
        else
            [self.window makeFirstResponder:v2];
        return;
    }

    v1.frame = left;
    v2.frame = right;
    [self display];
}

- (IBAction)OnViewPanelsPositionMoveRight:(id) [[maybe_unused]] sender
{
    dispatch_assert_main_queue();
    if( self.isRightCollapsed ) {
        NSBeep();
        return;
    }
    if( self.isLeftCollapsed ) {
        [self expandLeftView];
        return;
    }

    NSView *v1 = self.subviews[0];
    NSView *v2 = self.subviews[1];
    NSRect left = v1.frame;
    NSRect right = v2.frame;

    CGFloat &left_extent = self.vertical ? left.size.width : left.size.height;
    CGFloat &right_origin = self.vertical ? right.origin.x : right.origin.y;
    CGFloat &right_extent = self.vertical ? right.size.width : right.size.height;

    auto gran = g_ResizingGran;

    left_extent += gran;
    right_origin += gran;
    right_extent -= gran;
    if( right_extent < 0 ) {
        left_extent += right_extent;
        right_origin -= right_extent;
        right_extent = 0;
    }

    if( right_extent < g_MinPanelExtent ) {
        [self collapseRightView];
        if( auto h = nc::objc_cast<FilePanelsTabbedHolder>(v1) )
            [self.window makeFirstResponder:h.current];
        else
            [self.window makeFirstResponder:v1];
        return;
    }

    v1.frame = left;
    v2.frame = right;
    [self display];
}

- (void)collapseLeftView
{
    dispatch_assert_main_queue();
    if( self.isLeftCollapsed )
        return;
    NSView *right = [self.subviews objectAtIndex:1];
    NSView *left = [self.subviews objectAtIndex:0];
    left.hidden = true;
    right.frameSize = self.vertical ? NSMakeSize(self.frame.size.width, right.frame.size.height)
                                    : NSMakeSize(right.frame.size.width, self.frame.size.height);
    [self display];
}

- (void)expandLeftView
{
    dispatch_assert_main_queue();
    if( !self.isLeftCollapsed )
        return;

    NSView *left = [self.subviews objectAtIndex:0];
    NSView *right = [self.subviews objectAtIndex:1];
    left.hidden = false;

    NSRect left_frame = left.frame;
    NSRect right_frame = right.frame;
    const double full_extent = self.vertical ? self.frame.size.width : self.frame.size.height;
    CGFloat &left_extent = self.vertical ? left_frame.size.width : left_frame.size.height;
    CGFloat &right_origin = self.vertical ? right_frame.origin.x : right_frame.origin.y;
    CGFloat &right_extent = self.vertical ? right_frame.size.width : right_frame.size.height;
    left_extent = std::round(full_extent - g_DividerThickness) / m_PreCollapseProp;
    right_origin = left_extent + g_DividerThickness;
    right_extent = full_extent - right_origin;

    left.frameSize = left_frame.size;
    right.frame = right_frame;
    [self display];
}

- (void)collapseRightView
{
    dispatch_assert_main_queue();
    if( self.isRightCollapsed )
        return;
    NSView *right = [self.subviews objectAtIndex:1];
    NSView *left = [self.subviews objectAtIndex:0];
    right.hidden = true;
    left.frameSize = self.vertical ? NSMakeSize(self.frame.size.width, left.frame.size.height)
                                   : NSMakeSize(left.frame.size.width, self.frame.size.height);
    [self display];
}

- (void)expandRightView
{
    dispatch_assert_main_queue();
    if( !self.isRightCollapsed )
        return;
    NSView *left = [self.subviews objectAtIndex:0];
    NSView *right = [self.subviews objectAtIndex:1];
    right.hidden = false;

    NSRect left_frame = left.frame;
    NSRect right_frame = right.frame;
    const double full_extent = self.vertical ? self.frame.size.width : self.frame.size.height;
    CGFloat &left_extent = self.vertical ? left_frame.size.width : left_frame.size.height;
    CGFloat &right_origin = self.vertical ? right_frame.origin.x : right_frame.origin.y;
    CGFloat &right_extent = self.vertical ? right_frame.size.width : right_frame.size.height;
    left_extent = std::round(full_extent - g_DividerThickness) / m_PreCollapseProp;
    right_origin = left_extent + g_DividerThickness;
    right_extent = full_extent - right_origin;

    left.frameSize = left_frame.size;
    right.frame = right_frame;
    [self display];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)_item
{
    static const int move_left_tag =
        m_ActionsShortcutsManager->TagFromAction("menu.view.panels_position.move_left").value();
    static const int move_right_tag =
        m_ActionsShortcutsManager->TagFromAction("menu.view.panels_position.move_right").value();

    const long item_tag = _item.tag;
    if( item_tag == move_left_tag ) {
        return !self.isLeftCollapsed;
    }
    if( item_tag == move_right_tag ) {
        return !self.isRightCollapsed;
    }

    return true;
}

- (void)splitViewDidResizeSubviews:(NSNotification *)_notification
{
    if( !self.isLeftCollapsed && !self.isRightCollapsed ) {
        NSView *left = [self.subviews objectAtIndex:0];
        const auto left_extent = self.vertical ? left.frame.size.width : left.frame.size.height;
        const auto full_extent = self.vertical ? self.frame.size.width : self.frame.size.height;
        if( left_extent > 0. ) {
            m_PreCollapseProp = (full_extent - g_DividerThickness) / left_extent;
        }
    }
}

@end
