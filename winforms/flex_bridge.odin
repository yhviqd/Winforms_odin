// =============================================================================
// flex_bridge.odin -- turns flex.odin rectangles into Win32 child-window
// positions for kcvinker/Winforms (Odin).
//
// ADDITIVE: this file does NOT modify any existing library file. It only adds
// two new files to winforms/ and uses public-ish package-level symbols that
// already exist (Control, Form, SetWindowPos, GetClientRect, SWP_*).
//
// HOW IT WORKS
//   * A Flex_Host owns one Flex_Tree (pure geometry) plus a parallel
//     `controls` array. Box index i <-> controls[i]. nil means a pure layout
//     box with no HWND of its own.
//   * flex_host_apply() reads the form's client rect, runs flex_layout(),
//     then for every box with a control converts its absolute rect into
//     coordinates relative to the NEAREST ANCESTOR BOX THAT HAS A CONTROL
//     (a GroupBox, or the Form at the root). That matches Win32: child
//     coordinates are always relative to the direct parent HWND, and pure
//     layout boxes have no HWND at all.
//   * It also writes xpos/ypos/width/height back onto the ^Control so the
//     library's own helpers (cright, cbottom, control_get_rect, ...) stay
//     consistent after a relayout.
//
// WHY ODIN NEEDS A GLOBAL HOST
//   EventHandler :: proc(sender: rawptr, ea: ^EventArgs). Odin procedures do
//   NOT capture local variables, so the onLoad / onSizeChanged callbacks that
//   call flex_host_apply() must reference a package-level (global) Flex_Host.
//   The original app.odin does exactly this for pgb / tk / tmr / ti.
//
// UNITS: f32 PIXELS. No DPI scaling -- correct at 100%, off at 125%/150%.
//        (app.sysDPI exists in fonts.odin; wiring it in is a later step.)
//
// NOT COMPILED HERE: no Odin toolchain in the sandbox. Static checks and a
// Python port of the two-pass arithmetic are in README_FLEX.txt.
// =============================================================================

package winforms

Flex_Host :: struct {
    tree:     Flex_Tree,
    controls: [dynamic]^Control,   // parallel to tree.boxes; nil = pure box
    form:     ^Form,
}

// Round a non-negative f32 pixel value to i32. Layout coordinates are never
// negative in normal use; adding 0.5 gives round-half-up without core:math.
flex_i32 :: proc(v: f32) -> i32 { return i32(v + 0.5) }

flex_host_init :: proc(host: ^Flex_Host, frm: ^Form) {
    flex_tree_init(&host.tree)
    host.controls = make([dynamic]^Control)
    host.form = frm
}

flex_host_destroy :: proc(host: ^Flex_Host) {
    delete(host.controls)
    flex_tree_destroy(&host.tree)
    host.form = nil
}

// Open a PURE layout box (no HWND of its own). Children until flex_host_close.
flex_host_box :: proc(host: ^Flex_Host, st: Flex_Style) -> int {
    idx := flex_begin(&host.tree, st)
    append(&host.controls, nil)
    return idx
}

// Open a container box BOUND TO A REAL HWND (GroupBox, Panel-like control).
// Its children will be positioned relative to this control's client rect.
flex_host_container :: proc(host: ^Flex_Host, ctl: ^Control, st: Flex_Style) -> int {
    idx := flex_begin(&host.tree, st)
    append(&host.controls, ctl)
    return idx
}

// Add a leaf control. Its intrinsic size is LATCHED from ctl.width/height at
// registration time, so a later relayout cannot feed its own output back in.
flex_host_leaf :: proc(host: ^Flex_Host, ctl: ^Control, st: Flex_Style) -> int {
    sz := Flex_Size{f32(ctl.width), f32(ctl.height)}
    idx := flex_add(&host.tree, st, sz)
    append(&host.controls, ctl)
    return idx
}

// A pure spacer: a LEAF box with no control, typically `Flex_Style{grow = 1}`
// to absorb the free space at the end of a row/column. Unlike flex_host_box()
// it is already closed, so no flex_host_close() is needed.
// (flex_add() restores `open` to the parent, so the builder stack stays put.)
flex_host_spacer :: proc(host: ^Flex_Host, st: Flex_Style) -> int {
    idx := flex_add(&host.tree, st, Flex_Size{})
    append(&host.controls, nil)
    return idx
}

// Close the box opened by flex_host_box / flex_host_container.
flex_host_close :: proc(host: ^Flex_Host) {
    flex_end(&host.tree)
}

// Runtime override of one box's Style.width. Added for the tier-2 Splitter:
// in onPositionChanged, call this with the box index returned by
// flex_host_leaf()/flex_host_box() and then flex_host_apply(host), so the new
// divider position survives a later window resize instead of being reset.
flex_host_set_width :: proc(host: ^Flex_Host, idx: int, w: f32) {
    if idx < 0 do return
    if idx >= len(host.tree.boxes) do return
    host.tree.boxes[idx].style.width = flex_px(w)
}

// ---------- runtime tree editing (tier-4) ----------
// Save the index returned by flex_host_init's root/workspace box, then call
// these AFTER the static tree has been closed. They save/restore the builder
// stack, so no flex_host_close() is needed and no t.end() must follow.
// Every child must be appended with flex_host_*_at(parent = returned_idx).

// Open a PURE layout box under an explicit parent.
flex_host_box_at :: proc(host: ^Flex_Host, parent: int, st: Flex_Style) -> int {
    idx := flex_begin_at(&host.tree, parent, st)
    if idx == FLEX_NONE do return FLEX_NONE
    append(&host.controls, nil)
    return idx
}

// Open a container box BOUND TO A REAL HWND under an explicit parent
// (a TabPage / Panel created at runtime).
flex_host_container_at :: proc(host: ^Flex_Host, parent: int,
                               ctl: ^Control, st: Flex_Style) -> int {
    idx := flex_begin_at(&host.tree, parent, st, ctl)
    if idx == FLEX_NONE do return FLEX_NONE
    append(&host.controls, ctl)
    return idx
}

// Add a leaf under an explicit parent.
flex_host_leaf_at :: proc(host: ^Flex_Host, parent: int,
                          ctl: ^Control, st: Flex_Style) -> int {
    sz := Flex_Size{f32(ctl.width), f32(ctl.height)}
    idx := flex_add_to(&host.tree, parent, st, sz, ctl)
    if idx == FLEX_NONE do return FLEX_NONE
    append(&host.controls, ctl)
    return idx
}

// Detach the page subtree when the user closes a tab. Call BEFORE destroying
// the page HWND; flex_host_apply() will then skip every box under it.
flex_host_detach :: proc(host: ^Flex_Host, idx: int) {
    if idx < 0 do return
    flex_detach(&host.tree, idx)
}

// Recompute and apply. Call once at onLoad, and again on every onSizeChanged.
flex_host_apply :: proc(host: ^Flex_Host) {
    if host.form == nil do return
    if host.form.handle == nil do return
    if host.tree.root == FLEX_NONE do return

    rc: RECT
    GetClientRect(host.form.handle, &rc)
    bounds := Flex_Rect{0, 0, f32(rc.right), f32(rc.bottom)}
    flex_layout(&host.tree, bounds)

    for i in 0..<len(host.tree.boxes) {
        // A closed tab page was unlinked by flex_host_detach(). The box and
        // its stale children still live in the dynamic array; never move a
        // hidden / destroyed HWND again.
        if flex_box_detached(&host.tree, i) do continue
        ctl := host.controls[i]
        if ctl == nil do continue
        if ctl.kind == .Form do continue          // never move the top-level window
        if ctl.handle == nil do continue           // not created yet (e.g. early WM_SIZE)

        r := host.tree.boxes[i].rect

        // Find the nearest ancestor box that owns a control; its rect origin
        // is the Win32 parent client origin. Pure layout boxes are skipped.
        ox: f32 = 0
        oy: f32 = 0
        // C-style for has a precedent in the original sources
        // (trackbar.odin:330); a bare `for cond { }` does not.
        for p := host.tree.boxes[i].parent; p != FLEX_NONE; p = host.tree.boxes[p].parent {
            if host.controls[p] != nil {
                ox = host.tree.boxes[p].rect.x
                oy = host.tree.boxes[p].rect.y
                break
            }
        }

        x  := flex_i32(r.x - ox)
        y  := flex_i32(r.y - oy)
        w  := flex_i32(r.w)
        hh := flex_i32(r.h)

        ctl.xpos   = x
        ctl.ypos   = y
        ctl.width  = w
        ctl.height = hh

        // SWP_NOZORDER keeps the existing z-order; SWP_NOACTIVATE avoids
        // stealing focus during a resize. Both constants are already in
        // api_constants.odin (:256 / :261).

        // ---- NumberPicker is a COMPOSITE, not one HWND ------------------
        // np_create_handle() creates a 0x0 UpDown (ctl.handle) and then, in
        // np_after_creation() (numberpicker.odin:317-349), an INDEPENDENT
        // buddy EDIT that is a SIBLING under ctl.parent, positioned from
        // ctl.xpos/ypos/width/height. UDM_SETBUDDY links the two and makes
        // the UpDown auto-align beside the edit.
        //
        // Therefore we must NEVER SetWindowPos(ctl.handle, ..., w, hh):
        // that stretches the 0x0 arrow window into a full rectangle and
        // produces the mangled "three horizontal lines + squashed arrows"
        // look. Instead move the BUDDY to the flex rect and re-issue
        // UDM_SETBUDDY so the arrows follow it.
        //
        // UDM_GETBUDDY / UDM_SETBUDDY are plain messages (api_message.odin
        // :659 / :655), so no private NumberPicker field is touched.
        if ctl.kind == .Number_Picker {
            buddy := dir_cast(SendMessage(ctl.handle, UDM_GETBUDDY, 0, 0), HWND)
            if buddy != nil {
                SetWindowPos(buddy, nil, x, y, w, hh,
                             SWP_NOZORDER | SWP_NOACTIVATE)
                SendMessage(ctl.handle, UDM_SETBUDDY, WPARAM(buddy), 0)
            }
            continue
        }

        SetWindowPos(ctl.handle, nil, x, y, w, hh,
                     SWP_NOZORDER | SWP_NOACTIVATE)
    }
}
