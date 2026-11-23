// =============================================================================
// splitter.odin -- a draggable 6px divider, ported from
// winforms-zig/splitter.zig (which registers a custom WNDCLASSEXW).
//
// Here it is a plain "Static" child + set_subclass(), same as Panel. Win32 has
// NO splitter class. Two modes, exactly like the Zig port:
//
//   live = false (flex mode, app_zig_port.odin): during the drag we draw a
//          DrawFocusRect XOR rubber band on the SCREEN DC and darken the whole
//          bar. NO HWND moves until mouse-up, where onPositionChanged fires
//          ONCE and the app calls flex_host_set_width() + relayout.
//   live = true  (standalone, splitter_set_panels): move two panels + the bar.
//
// VISIBILITY: the bar is painted in WM_PAINT with COLOR_3DFACE (NOT the form's
// backColor -- using that made the 6px bar indistinguishable from the window),
// a 1px shadow + 1px light bevel in the middle, and the WHOLE bar goes dark
// while dragging. WM_ERASEBKGND returns 1 to avoid flicker.
//
// Drag loop needs SetCapture / ReleaseCapture / SetCursor / DrawFocusRect,
// which are NOT in the original api_procs.odin -- four @(link_name) bindings
// live in its foreign user32 block (tier-2 +8 lines).
// =============================================================================

package winforms

import api "core:sys/windows"


WF_SplitterDirection :: enum { Vertical, Horizontal }   // Vertical = left|right

Splitter :: struct
{
    using control : Control,
    direction : WF_SplitterDirection,
    left_panel, right_panel : ^Control,
    min_left, min_right : i32,
    pos         : i32,          // x / y in the PARENT's client coords
    dragging    : bool,
    // XOR rubber band (screen coordinates). DrawFocusRect is XOR: drawing the
    // identical rect a second time erases it.
    rubber_on   : bool,
    rubber      : RECT,
    // live=false: do NOTHING during WM_MOUSEMOVE; fire onPositionChanged once
    // on WM_LBUTTONUP. This is the flex-tree mode (the Zig port's XOR
    // rubber-band behaviour): one relayout per drag, not one per mouse move,
    // which matters when the workspace holds a 100k-row virtual ListView.
    live        : bool,
    drag_start  : i32,
    pos_start   : i32,
    _thickness  : i32,
    _bkBrush    : HBRUSH,
    onPositionChanged : proc(sp: ^Splitter, pos: i32),
}


new_splitter :: proc(parent: ^Control, x, y, w, h: i32,
                     dir: WF_SplitterDirection = .Vertical) -> ^Splitter
{
    this := new(Splitter)
    this.kind = .Splitter_Bar
    control_base_init(this, parent, x, y, w, h, &wf_sp_count)
    this._createHandleProc = wf_sp_create_handle
    this.direction = dir
    this.min_left = 48
    this.min_right = 48
    this.pos = dir == .Vertical ? x : y
    this._thickness = w > 0 ? w : 6
    this.live = true
    return this
}

splitter_set_panels :: proc(sp: ^Splitter, left, right: ^Control)
{
    sp.left_panel = left
    sp.right_panel = right
    if sp.handle != nil do wf_sp_apply(sp)
}

splitter_set_range :: proc(sp: ^Splitter, min_left, min_right: i32)
{
    sp.min_left = min_left
    sp.min_right = min_right
}

splitter_get_position :: proc(sp: ^Splitter) -> i32 { return sp.pos }

// true  = move panels + fire onPositionChanged on every WM_MOUSEMOVE (default,
//         standalone mode with splitter_set_panels).
// false = fire ONCE on WM_LBUTTONUP (flex-tree / rubber-band mode).
splitter_set_live :: proc(sp: ^Splitter, live: bool) { sp.live = live }

splitter_set_position :: proc(sp: ^Splitter, pos: i32)
{
    sp.pos = pos
    if sp.handle != nil do wf_sp_apply(sp)
    if sp.onPositionChanged != nil do sp.onPositionChanged(sp, sp.pos)
}


// ------------------------------ private ------------------------------

@private wf_sp_count : int = 1

// COLOR_3DLIGHT needs its own cached brush: wf_sys_brush() only caches the
// FACE and SHADOW brushes (any other index returns the FACE one).
@private wf_sp_light : HBRUSH = nil

@private wf_sp_light_brush :: proc() -> HBRUSH
{
    if wf_sp_light == nil {
        wf_sp_light = CreateSolidBrush(GetSysColor(WF_COLOR_3DLIGHT))
    }
    return wf_sp_light
}

@private wf_sp_create_handle :: proc(ctl: ^Control)
{
    this := cast(^Splitter) ctl
    // Do NOT use the form's backColor: it would make the 6px bar invisible.
    // A system 3D-face brush gives a real contrast against a white form.
    this._bkBrush = CreateSolidBrush(GetSysColor(WF_COLOR_3DFACE))
    create_control(ctl, this.width, this.height)
    set_subclass(this, wf_sp_wnd_proc)
}

// Clamp is INDEPENDENT of the panels. The old wf_sp_apply() returned early
// when left/right panels were nil (flex mode), so the position was never
// clamped there -- the rubber band could be dragged outside the window.
// Mirrors Zig's clampPos(), including the "client rect not ready yet" guard.
@private wf_sp_clamp :: proc(this: ^Splitter, raw: i32) -> i32
{
    rc : RECT = {}
    if this.parent != nil && this.parent.handle != nil {
        GetClientRect(this.parent.handle, &rc)
    }
    edge := this.direction == .Vertical ? (rc.right - rc.left) : (rc.bottom - rc.top)
    if edge <= 0 {
        return raw < this.min_left ? this.min_left : raw
    }
    // Root padding + row gaps + slack: the flex engine has no shrink pass.
    margin : i32 = 48
    hi := edge - this._thickness - this.min_right - margin
    if hi < this.min_left do hi = this.min_left
    p := raw
    if p < this.min_left do p = this.min_left
    if p > hi do p = hi
    return p
}

// -------------------- XOR rubber band (screen DC) --------------------

@private wf_sp_rubber_erase :: proc(this: ^Splitter)
{
    if !this.rubber_on do return
    dc := GetDC(nil)
    if dc != nil {
        wf_draw_focus_rect(dc, &this.rubber)
        ReleaseDC(nil, dc)
    }
    this.rubber_on = false
}

@private wf_sp_rubber_draw :: proc(this: ^Splitter, rc_in: RECT)
{
    // Odin proc parameters are CONST -- taking the address of a parameter
    // is rejected with "Cannot take the pointer address of 'rc' which is a
    // procedure parameter". Copy into a mutable local first, then take its
    // address. (Same rule as wf_virtual_set_row_count's `rows := rows_in`.)
    rc := rc_in
    dc := GetDC(nil)
    if dc != nil {
        wf_draw_focus_rect(dc, &rc)
        ReleaseDC(nil, dc)
    }
    this.rubber = rc
    this.rubber_on = true
}

@private wf_sp_rubber_rect :: proc(this: ^Splitter, hw: HWND, delta: i32) -> RECT
{
    rc : RECT = {}
    GetWindowRect(hw, &rc)
    if this.direction == .Vertical {
        rc.left  += delta
        rc.right += delta
    } else {
        rc.top    += delta
        rc.bottom += delta
    }
    return rc
}

// -------------------- WM_PAINT --------------------

@private wf_sp_paint_bar :: proc(this: ^Splitter, hw: HWND, hdc: HDC)
{
    rc : RECT = {}
    GetClientRect(hw, &rc)
    if rc.right <= rc.left || rc.bottom <= rc.top do return

    // 1) Base = system 3D face, NOT the form's backColor.
    face := this._bkBrush
    if face == nil do face = wf_sys_brush(WF_COLOR_3DFACE)
    if face != nil do api.FillRect(hdc, &rc, face)

    // 2) Dragging: the WHOLE bar goes dark. This is visible even while the
    //    mouse is captured and no relayout happens (Zig's paintBar does this).
    if this.dragging {
        dark := wf_sys_brush(WF_COLOR_3DSHADOW)
        if dark != nil do api.FillRect(hdc, &rc, dark)
        return
    }

    // 3) Idle: classic bevelled grip = 1px shadow + 1px light in the middle.
    dark_brush := wf_sys_brush(WF_COLOR_3DSHADOW)
    light_brush := wf_sp_light_brush()
    if dark_brush == nil || light_brush == nil do return

    if this.direction == .Vertical {
        mid := rc.left + (rc.right - rc.left) / 2
        d : RECT = {}
        d.left = mid;       d.top = rc.top + 2
        d.right = mid + 1;  d.bottom = rc.bottom - 2
        l : RECT = {}
        l.left = mid + 1;   l.top = rc.top + 2
        l.right = mid + 2;  l.bottom = rc.bottom - 2
        if d.bottom > d.top {
            api.FillRect(hdc, &d, dark_brush)
            api.FillRect(hdc, &l, light_brush)
        }
    } else {
        mid := rc.top + (rc.bottom - rc.top) / 2
        d : RECT = {}
        d.left = rc.left + 2;  d.top = mid
        d.right = rc.right - 2; d.bottom = mid + 1
        l : RECT = {}
        l.left = rc.left + 2;  l.top = mid + 1
        l.right = rc.right - 2; l.bottom = mid + 2
        if d.right > d.left {
            api.FillRect(hdc, &d, dark_brush)
            api.FillRect(hdc, &l, light_brush)
        }
    }
}

@private wf_sp_finalize :: proc(this: ^Splitter)
{
    delete_gdi_object(this._bkBrush)
    control_base_dtor(this)
    free(this)
}

// Clamp `pos` and move exactly three HWNDs: left panel, the bar, right panel.
// DeferWindowPos would be nicer (one atomic commit) but that binding is not
// declared in api_procs.odin; three SetWindowPos calls are visually fine for a
// 6px bar and avoid adding three more extern declarations.
@private wf_sp_apply :: proc(this: ^Splitter)
{
    if this.handle == nil do return
    if this.parent == nil do return
    if this.parent.handle == nil do return

    // Clamp FIRST (also in flex mode, where the panels are nil).
    this.pos = wf_sp_clamp(this, this.pos)

    if this.left_panel == nil || this.right_panel == nil do return

    rc : RECT
    GetClientRect(this.parent.handle, &rc)
    edge := this.direction == .Vertical ? rc.right : rc.bottom

    lx : i32 = 0
    if this.left_panel != nil do lx = this.direction == .Vertical ? this.left_panel.xpos : this.left_panel.ypos

    p := this.pos

    if this.direction == .Vertical {
        this.xpos = p
        this.width = this._thickness
        SetWindowPos(this.handle, nil, p, this.ypos, this._thickness, this.height,
                     SWP_NOZORDER | SWP_NOACTIVATE)

        lp := this.left_panel
        if lp.handle != nil {
            lw := p - lx
            if lw < 0 do lw = 0
            SetWindowPos(lp.handle, nil, lx, lp.ypos, lw, lp.height,
                         SWP_NOZORDER | SWP_NOACTIVATE)
            lp.width = lw
        }
        rp := this.right_panel
        if rp.handle != nil {
            rx := p + this._thickness
            rw := edge - rx
            if rw < 0 do rw = 0
            SetWindowPos(rp.handle, nil, rx, rp.ypos, rw, rp.height,
                         SWP_NOZORDER | SWP_NOACTIVATE)
            rp.xpos = rx
            rp.width = rw
        }
    } else {
        this.ypos = p
        this.height = this._thickness
        SetWindowPos(this.handle, nil, this.xpos, p, this.width, this._thickness,
                     SWP_NOZORDER | SWP_NOACTIVATE)

        lp := this.left_panel
        if lp.handle != nil {
            lh := p - lx
            if lh < 0 do lh = 0
            SetWindowPos(lp.handle, nil, lp.xpos, lx, lp.width, lh,
                         SWP_NOZORDER | SWP_NOACTIVATE)
            lp.height = lh
        }
        rp := this.right_panel
        if rp.handle != nil {
            ry := p + this._thickness
            rh := edge - ry
            if rh < 0 do rh = 0
            SetWindowPos(rp.handle, nil, rp.xpos, ry, rp.width, rh,
                         SWP_NOZORDER | SWP_NOACTIVATE)
            rp.ypos = ry
            rp.height = rh
        }
    }
}


@private wf_sp_wnd_proc :: proc "stdcall" (hw: HWND, msg: u32, wp: WPARAM, lp: LPARAM,
                                           sc_id: UINT_PTR, ref_data: DWORD_PTR) -> LRESULT
{
    context = global_context
    this := control_cast(Splitter, ref_data)

    // IMPORTANT: ctrl_common_msg_handler returns .Call_Def_Proc for
    // WM_LBUTTONDOWN / WM_MOUSEMOVE / WM_LBUTTONUP. The other controls'
    // wnd_procs return DefSubclassProc immediately in that case; here we must
    // NOT, or the whole drag loop would be unreachable. .Continue and
    // .Call_Def_Proc both fall through to our own switch, which ends with
    // DefSubclassProc anyway -- identical default behaviour.
    res := ctrl_common_msg_handler(this, hw, msg, wp, lp)
    if res == .Immediate_Return do return 1

    hit, hhandled := wf_fix_static_hittest(hw, msg, wp, lp)
    if hhandled do return hit

    switch msg {
    case WM_NCDESTROY:
        wf_sp_rubber_erase(this)
        RemoveWindowSubclass(hw, wf_sp_wnd_proc, sc_id)
        wf_sp_finalize(this)
        return 0

    case WM_SETCURSOR:
        idc := this.direction == .Vertical ? IDC_SIZEWE : IDC_SIZENS
        wf_set_cursor(LoadCursor(nil, idc))
        return 1

    // Everything is painted in WM_PAINT. WM_ERASEBKGND must return 1 so the
    // Static class does not wipe our bevel (and to avoid flicker on drag).
    case WM_PAINT:
        ps : PAINTSTRUCT = {}
        hdc := BeginPaint(hw, &ps)
        if hdc != nil do wf_sp_paint_bar(this, hw, hdc)
        EndPaint(hw, &ps)
        return 0

    case WM_ERASEBKGND:
        return 1

    case WM_LBUTTONDOWN:
        this.dragging = true
        this.rubber_on = false
        wf_set_capture(hw)
        pt : POINT
        GetCursorPos(&pt)
        ScreenToClient(this.parent.handle, &pt)
        this.drag_start = this.direction == .Vertical ? pt.x : pt.y
        this.pos_start = this.pos
        // Repaint: the whole bar goes dark immediately (visible feedback even
        // before the first MOUSEMOVE).
        InvalidateRect(hw, nil, true)
        return 0

    case WM_MOUSEMOVE:
        if this.dragging {
            pt : POINT
            GetCursorPos(&pt)
            ScreenToClient(this.parent.handle, &pt)
            cur := this.direction == .Vertical ? pt.x : pt.y
            wanted := this.pos_start + (cur - this.drag_start)
            new_pos := wf_sp_clamp(this, wanted)
            total := new_pos - this.pos_start
            this.pos = new_pos

            if this.live {
                wf_sp_apply(this)
                if this.onPositionChanged != nil do this.onPositionChanged(this, this.pos)
            } else {
                // Zig-port behaviour: XOR rubber band only, NO HWND moves.
                // Erasing with the identical rect removes the previous frame.
                wf_sp_rubber_erase(this)
                wf_sp_rubber_draw(this, wf_sp_rubber_rect(this, hw, total))
            }
        }
        return 0

    case WM_LBUTTONUP:
        if this.dragging {
            this.dragging = false
            wf_sp_rubber_erase(this)
            wf_release_capture()
            // Restore the light idle bevel.
            InvalidateRect(hw, nil, true)
            if !this.live {
                // ONE relayout for the whole drag. wf_sp_apply() clamps pos
                // even with nil panels (flex mode), then the callback updates
                // the flex box width and re-runs layout.
                wf_sp_apply(this)
                if this.onPositionChanged != nil do this.onPositionChanged(this, this.pos)
            }
        }
        return 0

    // Alt+Tab / another window stealing the capture must not leave a ghost
    // XOR frame on the screen, nor leave the bar permanently dark.
    case WM_CAPTURECHANGED:
        wf_sp_rubber_erase(this)
        this.dragging = false
        InvalidateRect(hw, nil, true)
        return 0

    case CM_STATIC_COLOR:
        // If anything still asks the parent for a background brush, give it
        // the SAME 3D-face brush we paint with, never the form's backColor.
        return dir_cast(this._bkBrush, LRESULT)
    }

    return DefSubclassProc(hw, msg, wp, lp)
}
