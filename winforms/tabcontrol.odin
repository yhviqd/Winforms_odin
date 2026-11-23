// =============================================================================
// tabcontrol.odin -- SysTabControl32 + real TabPage HWNDs (sibling panels).
//
// Win32 fact (from winforms-zig/controls.zig:1142): SysTabControl32 ONLY draws
// the tab strip; it does NOT host child windows. Each page is an independent
// STATIC child of the tab's PARENT, shown/hidden on TCN_SELCHANGE. Using real
// HWNDs keeps the flex bridge's "nearest ancestor box with a HWND" rule
// working for controls created with a page as their parent.
//
// The tab control is sized to the STRIP ONLY (height from TCM_ADJUSTRECT), and
// the pages sit directly below it -- the two never overlap. That avoids the
// whole "opaque white body / 5px white line" class of bugs from the Zig port.
//
// NOT COMPILED HERE: no Odin toolchain in the sandbox. See TIER2_GUIDE.md.
// =============================================================================

package winforms

import api "core:sys/windows"


WF_TabCloseScope :: enum { One, Others, All }

TabControl :: struct
{
    using control : Control,
    pages    : [dynamic]^TabPage,
    selected : i32,
    onSelectedIndexChanged : proc(tab: ^TabControl, index: i32),
    // Called ONCE per right-click command, BEFORE any page is removed.
    // Return false to cancel the whole operation (use msgbox with Yes_No).
    onBeforeClose : proc(tab: ^TabControl, index: i32,
                         scope: WF_TabCloseScope, will_close: i32) -> bool,
    // Called for EACH page just before its HWND is destroyed. The port uses
    // it to detach that page's flex subtree (wf_tag_int(page) holds the box).
    onPageClosing : proc(tab: ^TabControl, page: ^TabPage, index: i32),
    _closeMenu : HMENU,
    _strip     : i32,
}

TabPage :: struct
{
    using control : Control,
    owner : ^TabControl,
    title : string,
    index : i32,
    _bkBrush : HBRUSH,
}


new_tabcontrol :: proc(parent: ^Control, x, y, w, h: i32) -> ^TabControl
{
    wf_ensure_tab_bar_classes()          // BEFORE any CreateWindowEx
    this := new(TabControl)
    this.kind = .Tab_Control
    control_base_init(this, parent, x, y, w, h, &wf_tab_count)
    this._createHandleProc = wf_tab_create_handle
    this.pages = make([dynamic]^TabPage)
    this.selected = 0
    this._strip = 26                     // overwritten by TCM_ADJUSTRECT
    return this
}

// Add a tab and return its page. Create child controls with the returned page
// as parent: `new_button(page, "OK", 10, 10, 90, 26)`.
// `title` should be a string literal (stored by reference, not duped).
tabcontrol_add_page :: proc(tab: ^TabControl, title: string) -> ^TabPage
{
    p := new(TabPage)
    p.kind = .Tab_Page
    px := tab.xpos
    py := tab.ypos + tab._strip
    pw := tab.width
    ph := tab.height - tab._strip
    if ph < 0 do ph = 0
    control_base_init(p, tab.parent, px, py, pw, ph, &wf_tabpage_count)
    p._createHandleProc = wf_tabpage_create_handle
    p.owner = tab
    p.title = title
    p.index = i32(len(tab.pages))
    append(&tab.pages, p)

    if tab.handle != nil do wf_tab_insert_item(tab, p)   // runtime addition
    return p
}

tabcontrol_page_count :: proc(tab: ^TabControl) -> int { return len(tab.pages) }

tabcontrol_get_selected :: proc(tab: ^TabControl) -> i32
{
    if tab.handle == nil do return tab.selected
    s := i32(SendMessage(tab.handle, WF_TCM_GETCURSEL, 0, 0))
    if s < 0 do return tab.selected
    tab.selected = s
    return s
}

tabcontrol_set_selected :: proc(tab: ^TabControl, idx: i32)
{
    if idx < 0 || idx >= i32(len(tab.pages)) do return
    if tab.handle != nil do SendMessage(tab.handle, WF_TCM_SETCURSEL, WPARAM(idx), 0)
    wf_tab_show_page(tab, idx)
    if tab.onSelectedIndexChanged != nil do tab.onSelectedIndexChanged(tab, idx)
}

// Real strip height. Feed TCM_ADJUSTRECT a FIXED 1000x1000 rect so the answer
// depends only on font + DPI + row count, not on how tall the ctl was built.
tabcontrol_strip_height :: proc(tab: ^TabControl) -> i32
{
    if tab.handle == nil do return 26
    rc : RECT
    SetRect(&rc, 0, 0, 1000, 1000)
    SendMessage(tab.handle, WF_TCM_ADJUSTRECT, 0, dir_cast(&rc, LPARAM))
    h := i32(rc.top)
    if h >= 16 && h <= 60 do return h
    return 26
}

// Re-position all pages under the strip using the REAL strip height. Call from
// onLoad (all HWNDs exist by then). Safe to call more than once.
tabcontrol_layout_pages :: proc(tab: ^TabControl)
{
    strip := tabcontrol_strip_height(tab)
    tab._strip = strip
    for p in tab.pages {
        p.xpos   = tab.xpos
        p.ypos   = tab.ypos + strip
        p.width  = tab.width
        p.height = tab.height - strip
        if p.height < 0 do p.height = 0
        if p.handle != nil {
            SetWindowPos(p.handle, nil, p.xpos, p.ypos, p.width, p.height,
                         SWP_NOZORDER | SWP_NOACTIVATE)
        }
    }
}

tabcontrol_close_page :: proc(tab: ^TabControl, idx: i32)
{
    if idx < 0 || idx >= i32(len(tab.pages)) do return
    if tab.onBeforeClose != nil {
        if !tab.onBeforeClose(tab, idx, WF_TabCloseScope.One, 1) do return
    }
    if tab.onPageClosing != nil do tab.onPageClosing(tab, tab.pages[idx], idx)
    wf_tab_remove_one(tab, idx)
}

// Close every page EXCEPT `keep`. One confirmation question for the batch.
tabcontrol_close_others :: proc(tab: ^TabControl, keep: i32)
{
    n := i32(len(tab.pages))
    if keep < 0 || keep >= n do return
    will := n - 1
    if will < 1 do return
    if tab.onBeforeClose != nil {
        if !tab.onBeforeClose(tab, keep, WF_TabCloseScope.Others, will) do return
    }
    // Delete from the END so indices below the cursor stay valid, and call
    // onPageClosing with each page's ORIGINAL index.
    for i := n - 1; i >= 0; i -= 1 {
        if i == keep {
            continue
        }
        if tab.onPageClosing != nil {
            tab.onPageClosing(tab, tab.pages[i], i)
        }
        wf_tab_remove_one(tab, i)
    }
    tabcontrol_set_selected(tab, 0)
}

tabcontrol_close_all :: proc(tab: ^TabControl)
{
    n := i32(len(tab.pages))
    if n < 1 do return
    if tab.onBeforeClose != nil {
        if !tab.onBeforeClose(tab, -1, WF_TabCloseScope.All, n) do return
    }
    for i := n - 1; i >= 0; i -= 1 {
        if tab.onPageClosing != nil {
            tab.onPageClosing(tab, tab.pages[i], i)
        }
        wf_tab_remove_one(tab, i)
    }
    tab.selected = 0
}

@private wf_tab_remove_one :: proc(tab: ^TabControl, idx: i32)
{
    if idx < 0 || idx >= i32(len(tab.pages)) do return
    if tab.handle != nil do SendMessage(tab.handle, WF_TCM_DELETEITEM, WPARAM(idx), 0)

    doomed := tab.pages[idx]
    fresh := make([dynamic]^TabPage)
    for p, i in tab.pages {
        if i32(i) == idx do continue
        p.index = i32(len(fresh))
        append(&fresh, p)
    }
    delete(tab.pages)
    tab.pages = fresh
    if doomed.handle != nil do DestroyWindow(doomed.handle)

    sel := tabcontrol_get_selected(tab)
    if sel >= i32(len(tab.pages)) do sel = i32(len(tab.pages)) - 1
    if sel < 0 do sel = 0
    tabcontrol_set_selected(tab, sel)
}


// ------------------------------ private ------------------------------

@private wf_tab_count      : int = 1
@private wf_tabpage_count  : int = 1

@private wf_tab_insert_item :: proc(tab: ^TabControl, p: ^TabPage)
{
    item : WF_TCITEMW = {}
    item.mask = WF_TCIF_TEXT
    item.pszText = to_wstring(p.title)
    SendMessage(tab.handle, WF_TCM_INSERTITEMW, WPARAM(p.index),
                dir_cast(&item, LPARAM))
}

@private wf_tab_create_handle :: proc(ctl: ^Control)
{
    this := cast(^TabControl) ctl
    create_control(ctl, this.width, this.height)
    set_subclass(this, wf_tab_wnd_proc)
    for p in this.pages do wf_tab_insert_item(this, p)
    SendMessage(this.handle, WF_TCM_SETCURSEL, WPARAM(this.selected), 0)
    this._strip = tabcontrol_strip_height(this)

    // SysTabControl32 paints an OPAQUE background over its WHOLE rectangle.
    // The caller's `height` is the height of the whole TAB AREA (strip +
    // pages), not of the strip. Shrink the HWND to the strip so no white body
    // is left under the titles; the pages are separate sibling windows that
    // start at ypos + _strip. This is the "two windows never overlap" form of
    // the fix, so the v6 bottom border cannot show as a stray line.
    // `this.height` keeps the logical area height for tabcontrol_layout_pages.
    SetWindowPos(this.handle, nil, this.xpos, this.ypos, this.width, this._strip,
                 SWP_NOZORDER | SWP_NOACTIVATE)
}

@private wf_tabpage_create_handle :: proc(ctl: ^Control)
{
    this := cast(^TabPage) ctl
    this._bkBrush = get_solid_brush(this.backColor)
    create_control(ctl, this.width, this.height)
    set_subclass(this, wf_tabpage_wnd_proc)
    if this.owner != nil {
        wf_tab_show_page(this.owner, tabcontrol_get_selected(this.owner))
    }
}

@private wf_tab_show_page :: proc(tab: ^TabControl, sel: i32)
{
    tab.selected = sel
    for p, i in tab.pages {
        if p.handle == nil do continue
        show := i32(i) == sel
        ShowWindow(p.handle, show ? SW_SHOW : SW_HIDE)
        if show do InvalidateRect(p.handle, nil, true)
    }
}

@private wf_tab_finalize :: proc(this: ^TabControl)
{
    delete(this.pages)
    if this._closeMenu != nil do DestroyMenu(this._closeMenu)
    control_base_dtor(this)
    free(this)
}

@private wf_tabpage_finalize :: proc(this: ^TabPage)
{
    delete_gdi_object(this._bkBrush)
    control_base_dtor(this)
    free(this)
}

@private wf_tab_ensure_menu :: proc(this: ^TabControl) -> HMENU
{
    if this._closeMenu != nil do return this._closeMenu
    m := CreatePopupMenu()
    api.AppendMenuW(m, WF_MF_STRING, UINT_PTR(WF_TAB_CMD_CLOSE),
                    cast(LPCWSTR) to_wstring("Close Tab"))
    api.AppendMenuW(m, WF_MF_STRING, UINT_PTR(WF_TAB_CMD_OTHERS),
                    cast(LPCWSTR) to_wstring("Close Others"))
    api.AppendMenuW(m, WF_MF_STRING, UINT_PTR(WF_TAB_CMD_ALL),
                    cast(LPCWSTR) to_wstring("Close All"))
    this._closeMenu = m
    return m
}

@private wf_tab_right_click :: proc(this: ^TabControl)
{
    if len(this.pages) == 0 do return
    pt : POINT
    GetCursorPos(&pt)
    hti : WF_TCHITTESTINFO = {}
    hti.pt = pt
    ScreenToClient(this.handle, &hti.pt)
    idx := i32(SendMessage(this.handle, WF_TCM_HITTEST, 0, dir_cast(&hti, LPARAM)))
    if idx < 0 || idx >= i32(len(this.pages)) do return

    owner : HWND = this.handle
    if this._ownerForm != nil do owner = this._ownerForm.handle
    // api.TrackPopupMenu returns BOOL2 (distinct i32); cast before comparing
    // with the untyped menu-ID constant. Flags are u32 in the SDK binding.
    flags := u32(WF_TPM_RETURNCMD | WF_TPM_LEFTALIGN | WF_TPM_RIGHTBUTTON)
    cmd := api.TrackPopupMenu(wf_tab_ensure_menu(this),
                flags, pt.x, pt.y, 0, owner, nil)
    switch int(cmd) {
    case WF_TAB_CMD_CLOSE:  tabcontrol_close_page(this, idx)
    case WF_TAB_CMD_OTHERS: tabcontrol_close_others(this, idx)
    case WF_TAB_CMD_ALL:    tabcontrol_close_all(this)
    }
}


@private wf_tab_wnd_proc :: proc "stdcall" (hw: HWND, msg: u32, wp: WPARAM, lp: LPARAM,
                                            sc_id: UINT_PTR, ref_data: DWORD_PTR) -> LRESULT
{
    context = global_context
    this := control_cast(TabControl, ref_data)

    res := ctrl_common_msg_handler(this, hw, msg, wp, lp)
    #partial switch res {
        case .Call_Def_Proc: return DefSubclassProc(hw, msg, wp, lp)
        case .Immediate_Return: return 1
    }

    switch msg {
    case WM_NCDESTROY:
        RemoveWindowSubclass(hw, wf_tab_wnd_proc, sc_id)
        wf_tab_finalize(this)
        return 0

    // forms.odin:646 forwards WM_NOTIFY to nm.hwndFrom as CM_NOTIFY.
    case CM_NOTIFY:
        nm := dir_cast(lp, ^NMHDR)
        if nm != nil {
            if nm.code == WF_TCN_SELCHANGE {
                sel := i32(SendMessage(this.handle, WF_TCM_GETCURSEL, 0, 0))
                wf_tab_show_page(this, sel)
                if this.onSelectedIndexChanged != nil {
                    this.onSelectedIndexChanged(this, sel)
                }
                return 0
            }
            if nm.code == WF_NM_RCLICK || nm.code == WF_NM_RDBLCLK {
                wf_tab_right_click(this)
                return 0
            }
        }
        return 0
    }

    return DefSubclassProc(hw, msg, wp, lp)
}


@private wf_tabpage_wnd_proc :: proc "stdcall" (hw: HWND, msg: u32, wp: WPARAM, lp: LPARAM,
                                                sc_id: UINT_PTR, ref_data: DWORD_PTR) -> LRESULT
{
    context = global_context
    this := control_cast(TabPage, ref_data)

    res := ctrl_common_msg_handler(this, hw, msg, wp, lp)
    #partial switch res {
        case .Call_Def_Proc: return DefSubclassProc(hw, msg, wp, lp)
        case .Immediate_Return: return 1
    }

    fwd, handled := wf_forward_container_msg(this, hw, msg, wp, lp)
    if handled do return fwd

    hit, hhandled := wf_fix_static_hittest(hw, msg, wp, lp)
    if hhandled do return hit

    switch msg {
    case WM_NCDESTROY:
        RemoveWindowSubclass(hw, wf_tabpage_wnd_proc, sc_id)
        wf_tabpage_finalize(this)
        return 0

    case WM_ERASEBKGND:
        return wf_fill_3dface(dir_cast(wp, HDC), hw, this._bkBrush)

    case CM_STATIC_COLOR:
        return dir_cast(this._bkBrush, LRESULT)
    }

    return DefSubclassProc(hw, msg, wp, lp)
}
