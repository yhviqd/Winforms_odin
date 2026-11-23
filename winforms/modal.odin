// =============================================================================
// modal.odin -- component-style modal windows for kcvinker/Winforms (Odin).
//
// THE KEY INSIGHT: this library ALREADY supports multiple forms, so NO second
// control table is needed (unlike the Zig port's dialog_controls[256]).
//
//   * window_proc()  (forms.odin:440) finds its ^Form from GWLP_USERDATA,
//     which WM_NCCREATE fills from CREATESTRUCTW.lpCreateParams. Every Form
//     therefore gets its own independent wndProc context.
//   * control_base_init() (controls.odin:242) appends every control to
//     `parent._ownerForm._controls`. A modal Form owns its OWN [dynamic] list.
//   * WM_COMMAND / WM_NOTIFY / WM_CTLCOLOR* are routed by THAT form's
//     window_proc to the originating child via CM_* messages. So buttons,
//     TabControl, ListView, TreeView, Panel, Splitter... all just work.
//   * forms.odin:657 only calls PostQuitMessage when hw == app.mainHandle,
//     so closing a modal does NOT kill the outer message loop.
//
// What this file adds is only the MODAL part:
//   1. CreateWindowEx with the owner as hWndParent, Fixed_Dialog style
//      (already has WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT).
//   2. EnableWindow(owner, false) + a nested GetMessage loop.
//   3. IsDialogMessage for Tab navigation between child controls.
//   4. A subclass that turns WM_CLOSE / Esc into close_modal() instead of
//      DestroyWindow -> the HWND and all child HWNDs are kept for re-use.
//
// TIER-3 additions: modal_add_timer() for a Timer scoped to the modal window
// (started/stopped on each show/close), plus multi-selection and time-only
// DateTimePicker helpers in ctrl_static_data.odin.
//
// NOT SUPPORTED (by request): MenuBar (HMENU + _menuItemMap, bound to the
// top-level window in start_mainloop) and StatusBar (needs parent WM_SIZE
// cooperation; meaningless on a fixed dialog). Everything else works.
//
// NOT COMPILED HERE: no Odin toolchain in the sandbox. See MODAL_GUIDE.md.
// =============================================================================

package winforms

import api "core:sys/windows"


// Private message used to wake the nested GetMessage loop on close_modal().
// WM_APP = 32768; the library's CM_* messages occupy WM_APP+2 .. WM_APP+25.
WF_MODAL_EXIT :: WM_APP + 60
WF_VK_ESCAPE  :: 27


// ---------- global modal state ----------
// Odin procedures do not capture locals, and all controls / callbacks are
// package-level in this library anyway. One modal at a time (no nesting).

@private wf_modal_owners  : map[^Form]^Form          // modal form -> owner form
@private wf_modal_hosts   : map[^Form]^Flex_Host     // optional flex layout
@private wf_modal_hw      : HWND = nil
@private wf_modal_owner   : HWND = nil
@private wf_modal_running : bool = false
@private wf_modal_result  : i32 = 0
@private wf_modal_host    : ^Flex_Host = nil
@private wf_modal_scid    : UINT_PTR = 47000
// Timers registered through modal_add_timer(). SetTimer is HWND-bound, so a
// hidden (but not destroyed) modal keeps ticking unless we stop them on exit.
@private wf_modal_timers  : [dynamic]^Timer


// -----------------------------------------------------------------------------
// PUBLIC API
// -----------------------------------------------------------------------------

// Create a modal window. It is a plain ^Form, so EVERY ui.new_xxx(frm, ...)
// works exactly as on the main form. `owner` is disabled while it is shown.
// Do NOT call start_mainloop() on it, and do NOT attach a MenuBar.
new_modal_form :: proc(owner: ^Form, title: string, w: i32 = 560, h: i32 = 420) -> ^Form
{
    f := new_form(title, w, h)          // new_form2(txt, w, h)
    f.style = .Fixed_Dialog
    f.minimizeBox = false
    f.maximizeBox = false

    if wf_modal_owners == nil do wf_modal_owners = make(map[^Form]^Form)
    if wf_modal_hosts  == nil do wf_modal_hosts  = make(map[^Form]^Flex_Host)
    wf_modal_owners[f] = owner
    return f
}

// Optional: let the modal window participate in the flex layout engine.
// Build the tree with flex_host_init(host, frm) + flex_host_box/leaf/close,
// then call this. flex_host_apply() runs on WM_SIZE and at every show_modal().
modal_set_flex_host :: proc(frm: ^Form, host: ^Flex_Host)
{
    if wf_modal_hosts == nil do wf_modal_hosts = make(map[^Form]^Flex_Host)
    wf_modal_hosts[frm] = host
}

// Blocking display. Returns the value passed to close_modal() (default 0).
// Safe to call repeatedly: the window and its children are hidden, not
// destroyed, so a second call re-shows the same HWNDs instantly.
show_modal :: proc(frm: ^Form) -> i32
{
    if frm == nil do return -1
    if wf_modal_running do return -1          // nested modals not supported

    owner_hw : HWND = nil
    if wf_modal_owners != nil {
        owner := wf_modal_owners[frm]
        if owner != nil do owner_hw = owner.handle
    }
    if owner_hw == nil do owner_hw = app.mainHandle
    if owner_hw == nil do return -1

    if frm.handle == nil {
        wf_modal_create_handle(frm, owner_hw)
        if frm.handle == nil do return -1
    }

    wf_modal_hw      = frm.handle
    wf_modal_owner   = owner_hw
    wf_modal_running = true
    wf_modal_result  = 0
    wf_modal_host    = nil
    if wf_modal_hosts != nil do wf_modal_host = wf_modal_hosts[frm]

    // form_addTimer() stores `frm.handle` as _parentHwnd, which is nil until
    // the first show_modal(). Correct it here, then start every registered
    // timer; stop them all on exit (see below).
    for tm in wf_modal_timers {
        tm._parentHwnd = frm.handle
        timer_start(tm)
    }

    api.EnableWindow(owner_hw, false)
    ShowWindow(frm.handle, SW_SHOW)
    SetForegroundWindow(frm.handle)
    if wf_modal_host != nil do flex_host_apply(wf_modal_host)

    ms : MSG
    for wf_modal_running && GetMessage(&ms, nil, 0, 0) != 0 {
        // IsDialogMessage handles Tab / Shift+Tab / arrow / Enter for default
        // buttons. It must be called BEFORE TranslateMessage.
        // wf_is_dialog_message returns BOOL (a distinct type), so an untyped
        // `0` cannot be compared to it directly. Same pattern as the original
        // library: dialogs.odin:243 uses `cast(int) GetSaveFileName(&ofn)`.
        handled := cast(int) wf_is_dialog_message(frm.handle, &ms)
        if handled == 0 {
            TranslateMessage(&ms)
            DispatchMessage(&ms)
        }
    }

    // If the loop ended because the thread got WM_QUIT, re-post it so the
    // OUTER main loop (start_mainloop) also terminates cleanly.
    // WPARAM is distinct too; cast instead of i32(...).
    if ms.message == WM_QUIT do PostQuitMessage(cast(i32) ms.wparam)

    wf_modal_running = false
    for tm in wf_modal_timers {
        timer_stop(tm)
    }
    ShowWindow(frm.handle, SW_HIDE)
    api.EnableWindow(owner_hw, true)
    SetForegroundWindow(owner_hw)

    wf_modal_hw   = nil
    wf_modal_host = nil
    return wf_modal_result
}

// Call from any event handler (button onClick, menu, ...), or from the X
// button / Esc key which the subclass routes here.
close_modal :: proc(frm: ^Form, result: i32 = 0)
{
    if !wf_modal_running do return
    wf_modal_result = result
    wf_modal_running = false
    // Wake the blocking GetMessage(). The message is harmless: our subclass
    // and the form's window_proc both ignore it, DefWindowProc drops it.
    PostMessage(wf_modal_hw, WF_MODAL_EXIT, 0, 0)
}

modal_is_open   :: proc() -> bool { return wf_modal_running }
modal_get_result :: proc() -> i32 { return wf_modal_result }

// Register a Timer INSIDE the modal window. WM_TIMER is dispatched by that
// Form's own window_proc -> form_timer_handler -> this Form's _timerMap, so
// the main form's timers are completely independent.
//
// Unlike form_addTimer() alone, this also manages the lifecycle: started on
// every show_modal(), stopped on every exit. Call it any time before/after
// show_modal(); _parentHwnd is corrected at show time (the HWND does not
// exist until the first show_modal()).
modal_add_timer :: proc(frm: ^Form, interval: u32, on_tick: EventHandler) -> ^Timer
{
    tm := form_addTimer(frm, interval, on_tick)
    append(&wf_modal_timers, tm)
    return tm
}


// -----------------------------------------------------------------------------
// PRIVATE
// -----------------------------------------------------------------------------

@private wf_modal_create_handle :: proc(frm: ^Form, owner_hw: HWND)
{
    // Fixed_Dialog already includes WS_EX_DLGMODALFRAME, WS_EX_CONTROLPARENT
    // (needed by IsDialogMessage), WS_CAPTION, WS_SYSMENU, WS_CLIPCHILDREN.
    frm._exStyle = fixed_dialog_ex_style
    frm._style   = fixed_dialog_style
    frm._style   = frm._style ~ WS_MAXIMIZEBOX
    frm._style   = frm._style ~ WS_MINIMIZEBOX

    // Centre over the owner in SCREEN coordinates.
    rc : RECT
    GetWindowRect(owner_hw, &rc)
    ow := rc.right - rc.left
    oh := rc.bottom - rc.top
    frm.xpos = rc.left + (ow - frm.width)  / 2
    frm.ypos = rc.top  + (oh - frm.height) / 2

    if frm.font.handle == nil do font_create_handle(&frm.font, false)

    // hWndParent = owner: gives correct Z-order / taskbar grouping.
    // lpCreateParams = frm: WM_NCCREATE in window_proc stores it in
    // GWLP_USERDATA, which is what makes this a fully independent Form.
    frm.handle = CreateWindowEx(frm._exStyle, wcnForm,
                                to_wstring(frm.text), frm._style,
                                frm.xpos, frm.ypos, frm.width, frm.height,
                                owner_hw, nil, app.hInstance, frm)
    if frm.handle == nil {
        ptf("Modal: CreateWindowEx failed, error %d\n", GetLastError())
        return
    }
    frm._isCreated = true

    wf_modal_scid += 1
    // SUBCLASSPROC is a distinct #type in api_types.odin; bind to a typed
    // local first, exactly like set_subclass() does in controls.odin:455.
    fn : SUBCLASSPROC = wf_modal_wnd_proc
    api.SetWindowSubclass(frm.handle, fn, wf_modal_scid, to_dwptr(&frm.control))

    // Same sequence as start_mainloop()/create_child_handles(), but scoped to
    // THIS form's _controls list. Container controls (GroupBox / Panel /
    // TabPage) must be constructed before their children, which is the normal
    // order in app.odin anyway.
    for ctl in frm._controls {
        if ctl.handle == nil {
            ctl._createHandleProc(ctl)
            if ctl.onHandleCreated != nil {
                ea := new_event_args()
                ctl.onHandleCreated(ctl, &ea)
            }
        }
    }
}


@private wf_modal_wnd_proc :: proc "stdcall" (hw: HWND, msg: u32, wp: WPARAM, lp: LPARAM,
                                              sc_id: UINT_PTR, ref_data: DWORD_PTR) -> LRESULT
{
    context = global_context
    frm := control_cast(Form, ref_data)

    switch msg {
    case WM_CLOSE:
        // Do NOT let DefWindowProc destroy the window: we re-use the HWND and
        // all child HWNDs on the next show_modal(). Manually fire onClosing
        // because the underlying window_proc's WM_CLOSE branch is skipped.
        if frm != nil && frm.onClosing != nil {
            ea := new_event_args()
            frm.onClosing(frm, &ea)
            if ea.cancel do return 0
        }
        close_modal(frm, 0)
        return 0

    case WM_KEYDOWN:
        // WPARAM is a distinct type; comparing it with an untyped integer
        // constant is fine (numberpicker.odin:563 does `if wp == 1`), but
        // u32(wp) is a narrowing conversion that Odin rejects. Compare
        // directly with the untyped constant instead.
        if wp == WF_VK_ESCAPE {
            close_modal(frm, 0)
            return 0
        }

    case WM_SIZE:
        if wf_modal_running && wf_modal_host != nil do flex_host_apply(wf_modal_host)

    case WM_NCDESTROY:
        // Fallback: somebody called DestroyWindow() directly.
        // RemoveWindowSubclass IS declared at package scope
        // (api_procs.odin:337); SetWindowSubclass is NOT (it is commented
        // out at :335), which is why the two calls use different prefixes.
        rfn : SUBCLASSPROC = wf_modal_wnd_proc
        RemoveWindowSubclass(hw, rfn, sc_id)
        for tm in wf_modal_timers {
            timer_stop(tm)
        }
        wf_modal_running = false
    }

    return DefSubclassProc(hw, msg, wp, lp)
}
