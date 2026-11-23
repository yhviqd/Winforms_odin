// =============================================================================
// panel.odin -- a plain grouping container, ported from winforms-zig/panel.zig.
//
// Win32 has NO Panel class. The Zig port registers a custom WNDCLASSEXW
// ("ZigWinformsPanel"); here we reuse ControlKind.Panel, which the original
// Odin library already reserved in enums.odin but left as a dead placeholder
// ("Button" class, style = 0, no constructor). We point its table entry at
// "Static" and subclass it, exactly like GroupBox.
//
// Why not a custom class: control_base_init() + create_control() +
// set_subclass() already give us font inheritance, _ownerForm, the flat
// _controls table and the message chain. Zero changes to winforms_main.odin.
//
// Why WS_CLIPCHILDREN: without it the Static's WM_ERASEBKGND wipes child
// windows on every repaint. GroupBox does not need it (it draws into a memDC),
// we do.
// =============================================================================

package winforms


WF_PanelBorder :: enum { None, Single, Sunken }

Panel :: struct
{
    using control : Control,
    border   : WF_PanelBorder,
    _bkBrush : HBRUSH,
}


new_panel :: proc(parent: ^Control, x, y, w, h: i32,
                  border: WF_PanelBorder = .None,
                  back_color: uint = 0) -> ^Panel
{
    this := new(Panel)
    this.kind = .Panel
    control_base_init(this, parent, x, y, w, h, &wf_panel_count)
    this._createHandleProc = wf_panel_create_handle
    this.border = border
    if back_color != 0 do this.backColor = back_color

    switch border {
    case .None:    break
    case .Single:  this._style |= WS_BORDER
    case .Sunken:  this._exStyle |= WS_EX_STATICEDGE
    }
    return this
}

// Panels are containers: children are created with the returned ^Panel as
// their parent, i.e. `new_button(panel, "OK", 8, 8, 90, 26)`.
panel_set_backcolor :: proc(this: ^Panel, clr: uint)
{
    this.backColor = clr
    if this._bkBrush != nil do delete_gdi_object(this._bkBrush)
    this._bkBrush = get_solid_brush(clr)
    if this._isCreated do InvalidateRect(this.handle, nil, true)
}

panel_set_border :: proc(this: ^Panel, border: WF_PanelBorder)
{
    if this._isCreated do return       // WS_* styles must be set before creation
    this.border = border
    switch border {
    case .None:    break
    case .Single:  this._style |= WS_BORDER
    case .Sunken:  this._exStyle |= WS_EX_STATICEDGE
    }
}


// ------------------------------ private ------------------------------

@private wf_panel_count : int = 1

@private wf_panel_create_handle :: proc(ctl: ^Control)
{
    this := cast(^Panel) ctl
    this._bkBrush = get_solid_brush(this.backColor)
    create_control(ctl, this.width, this.height)
    set_subclass(this, wf_panel_wnd_proc)
}

@private wf_panel_finalize :: proc(this: ^Panel)
{
    delete_gdi_object(this._bkBrush)
    control_base_dtor(this)
    free(this)
}

@private wf_panel_wnd_proc :: proc "stdcall" (hw: HWND, msg: u32, wp: WPARAM, lp: LPARAM,
                                             sc_id: UINT_PTR, ref_data: DWORD_PTR) -> LRESULT
{
    context = global_context
    this := control_cast(Panel, ref_data)

    res := ctrl_common_msg_handler(this, hw, msg, wp, lp)
    #partial switch res {
        case .Call_Def_Proc: return DefSubclassProc(hw, msg, wp, lp)
        case .Immediate_Return: return 1
    }

    // Children of this Panel send WM_COMMAND / WM_NOTIFY / WM_CTLCOLOR* to
    // their DIRECT parent (= us). Forward them back to the originating child,
    // matching what forms.odin / groupbox.odin do.
    fwd, handled := wf_forward_container_msg(this, hw, msg, wp, lp)
    if handled do return fwd

    // Static returns HTTRANSPARENT from WM_NCHITTEST; turn it into HTCLIENT.
    hit, hhandled := wf_fix_static_hittest(hw, msg, wp, lp)
    if hhandled do return hit

    switch msg {
    case WM_NCDESTROY:
        RemoveWindowSubclass(hw, wf_panel_wnd_proc, sc_id)
        wf_panel_finalize(this)
        return 0

    case WM_ERASEBKGND:
        return wf_fill_3dface(dir_cast(wp, HDC), hw, this._bkBrush)

    // The Form asks US for the brush used to paint this Static.
    case CM_STATIC_COLOR:
        return dir_cast(this._bkBrush, LRESULT)
    }

    return DefSubclassProc(hw, msg, wp, lp)
}
