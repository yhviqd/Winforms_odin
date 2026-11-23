// =============================================================================
// statusbar.odin -- msctls_statusbar32 with SB_SETPARTS / SB_SETTEXTW.
//
// Ported from winforms-zig/controls.zig:1486. The Odin original has NO
// statusbar.odin (confirmed against tree.json); SB_SETPARTS (1028) and
// SB_SETTEXTW (1035) are already declared in api_message.odin, so this file
// needs no new Win32 bindings beyond wf_ensure_tab_bar_classes()'s class setup.
//
// CCS_NORESIZE is essential: without it comctl32 repositions/resizes the bar
// on every parent WM_SIZE and fights the flex bridge.
// =============================================================================

package winforms


StatusBar :: struct
{
    using control : Control,
    parts  : [dynamic]i32,       // right edge of each part; -1 = "to the end"
    texts  : [dynamic]string,
    simple : bool,
}


new_statusbar :: proc(parent: ^Control, x, y, w, h: i32) -> ^StatusBar
{
    wf_ensure_tab_bar_classes()          // ICC_BAR_CLASSES, before CreateWindowEx
    this := new(StatusBar)
    this.kind = .Status_Bar
    control_base_init(this, parent, x, y, w, h, &wf_sb_count)
    this._createHandleProc = wf_sb_create_handle
    this.parts = make([dynamic]i32)
    this.texts = make([dynamic]string)
    return this
}

// `right_edges` holds each part's right edge in client pixels; use -1 for the
// last part to mean "stretch to the end". Example: {220, 480, -1}.
statusbar_set_parts :: proc(sb: ^StatusBar, right_edges: []i32)
{
    fresh := make([dynamic]i32)
    for e in right_edges do append(&fresh, e)
    delete(sb.parts)
    sb.parts = fresh
    for len(sb.texts) < len(sb.parts) do append(&sb.texts, "")
    if sb.handle != nil do wf_sb_apply_parts(sb)
}

statusbar_set_text :: proc(sb: ^StatusBar, index: i32, text: string)
{
    if index < 0 do return
    for len(sb.texts) <= int(index) do append(&sb.texts, "")
    sb.texts[index] = text
    if sb.handle == nil do return
    if len(sb.parts) == 0 {
        // A status bar with no explicit parts is one full-width part.
        append(&sb.parts, -1)
        wf_sb_apply_parts(sb)
    }
    SendMessage(sb.handle, SB_SETTEXTW, WPARAM(index),
                to_lparam(to_wstring(text)))
}

statusbar_set_simple :: proc(sb: ^StatusBar, on: bool)
{
    sb.simple = on
    if sb.handle != nil do SendMessage(sb.handle, SB_SIMPLE, WPARAM(on ? 1 : 0), 0)
}


// ------------------------------ private ------------------------------

@private wf_sb_count : int = 1

@private wf_sb_apply_parts :: proc(sb: ^StatusBar)
{
    if len(sb.parts) == 0 do return
    SendMessage(sb.handle, SB_SETPARTS, WPARAM(len(sb.parts)),
                dir_cast(&sb.parts[0], LPARAM))
}

@private wf_sb_create_handle :: proc(ctl: ^Control)
{
    this := cast(^StatusBar) ctl
    create_control(ctl, this.width, this.height)
    set_subclass(this, wf_sb_wnd_proc)
    if len(this.parts) == 0 {
        append(&this.parts, -1)
        for len(this.texts) < 1 do append(&this.texts, "")
    }
    wf_sb_apply_parts(this)
    for t, i in this.texts {
        if len(t) > 0 {
            SendMessage(this.handle, SB_SETTEXTW, WPARAM(i),
                        to_lparam(to_wstring(t)))
        }
    }
    if this.simple do SendMessage(this.handle, SB_SIMPLE, WPARAM(1), 0)
}

@private wf_sb_finalize :: proc(this: ^StatusBar)
{
    delete(this.parts)
    delete(this.texts)
    control_base_dtor(this)
    free(this)
}

// StatusBar needs no subclass for drawing, but it DOES need WM_NCDESTROY to
// release its dynamic arrays (the original library never destroys controls
// individually, so this is a best-effort cleanup).
@private wf_sb_wnd_proc :: proc "stdcall" (hw: HWND, msg: u32, wp: WPARAM, lp: LPARAM,
                                           sc_id: UINT_PTR, ref_data: DWORD_PTR) -> LRESULT
{
    context = global_context
    if msg == WM_NCDESTROY {
        this := control_cast(StatusBar, ref_data)
        RemoveWindowSubclass(hw, wf_sb_wnd_proc, sc_id)
        wf_sb_finalize(this)
        return 0
    }
    return DefSubclassProc(hw, msg, wp, lp)
}
