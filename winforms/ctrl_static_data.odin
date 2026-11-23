
// Created on 202-Apr-17 by kcvin

package winforms

// Tier-2: api.FillRect in wf_fill_3dface() below.
import api "core:sys/windows"

wcnForm := L("Winforms_Window_Class")
wcnMsgOnlyWin := L("Winforms_MsgForm_Class")
wcnButton := L("Button")
wcnCalendar:= L("SysMonthCal32")
wcnCombo:= L("ComboBox")
wcnDTP := L("SysDateTimePick32")
wcnStatic := L("Static")
wcnListBox := L("ListBox")
wcnListView := L("SysListView32")
wcnNumPick := L("msctls_updown32")
wcnPictureBox := L("Winforms_PictureBox")
wcnProgressBar := L("msctls_progress32")
wcnEdit := L("Edit")
wcnTrackBar := L("msctls_trackbar32")
wcnTreeView := L("SysTreeView32")
// Tier-2: comctl32 v6 classes (need ICC_TAB_CLASSES / ICC_BAR_CLASSES,
// requested by wf_ensure_tab_bar_classes(), defined in this file below).
wcnTabControl := L("SysTabControl32")
wcnStatusBar := L("msctls_statusbar32")

// =============================================================================
// Tier-2 constants + structs (formerly tier2_api.odin, merged here).
// WF_ prefix avoids colliding with the ~620 existing top-level names.
// Kept ABOVE the style constants below so WF_SBARS_SIZEGRIP is declared first.
// =============================================================================

// ---------- system colours / hit-test / show ----------

WF_COLOR_3DFACE       :: 15
WF_COLOR_3DSHADOW     :: 16
WF_COLOR_3DLIGHT      :: 22      // COLOR_3DLIGHT (17 is 3DGRAY, not a light color)
WF_COLOR_WINDOW       :: 5
WF_SW_SHOWNA          :: 8
WF_HTTRANSPARENT      :: -1
WF_HTCLIENT           :: 1

WF_ICC_BAR_CLASSES    :: 0x00000004
WF_ICC_TAB_CLASSES    :: 0x00000008


// ---------- TabControl (SysTabControl32) ----------

WF_TCS_TABS           :: 0x0000
WF_TCS_MULTILINE      :: 0x0200
WF_TCS_FIXEDWIDTH     :: 0x0400
WF_TCIF_TEXT          :: 0x0001
WF_TCIF_IMAGE         :: 0x0002
WF_TCIF_PARAM         :: 0x0008

WF_TCM_FIRST          :: 0x1300
WF_TCM_GETITEMCOUNT   :: (WF_TCM_FIRST + 5)
WF_TCM_DELETEITEM     :: (WF_TCM_FIRST + 8)
WF_TCM_DELETEALLITEMS :: (WF_TCM_FIRST + 9)
WF_TCM_GETCURSEL      :: (WF_TCM_FIRST + 11)
WF_TCM_SETCURSEL      :: (WF_TCM_FIRST + 12)
WF_TCM_HITTEST        :: (WF_TCM_FIRST + 13)
WF_TCM_ADJUSTRECT     :: (WF_TCM_FIRST + 40)
WF_TCM_GETROWCOUNT    :: (WF_TCM_FIRST + 44)
WF_TCM_GETITEMW       :: (WF_TCM_FIRST + 60)
WF_TCM_SETITEMW       :: (WF_TCM_FIRST + 61)
WF_TCM_INSERTITEMW    :: (WF_TCM_FIRST + 62)

// NMHDR.code is UINT (api_types.odin:418), so these MUST be the u32 form of
// the negative Win32 notification codes. Same trick as control_constants.odin
// (LVN_FIRST :: 4294967196) and the tier-1 NM_RCLICK fix (NM_FIRST - 4).
WF_TCN_FIRST          :: 4294966746   // -550
WF_TCN_SELCHANGING    :: 4294966744   // -552
WF_TCN_SELCHANGE      :: 4294966745   // -551
WF_NM_RCLICK          :: (NM_FIRST - 4)   // -5
WF_NM_RDBLCLK         :: (NM_FIRST - 5)   // -6

// TCITEMW / TCHITTESTINFO are not in api_types.odin.
// 64-bit layout: UINT mask, DWORD state, DWORD stateMask, LPWSTR pszText,
//                int cchTextMax, int iImage, LPARAM lParam  (40 bytes).
WF_TCITEMW :: struct {
    mask:        UINT,
    dwState:     DWORD,
    dwStateMask: DWORD,
    pszText:     ^WCHAR,
    cchTextMax:  i32,
    iImage:      i32,
    lParam:      LPARAM,
}

WF_TCHITTESTINFO :: struct {
    pt:    POINT,
    flags: UINT,
}


// ---------- StatusBar (msctls_statusbar32) ----------
// SB_SETPARTS (1028) and SB_SETTEXTW (1035) already exist in api_message.odin.
WF_SBARS_SIZEGRIP     :: 0x0100
WF_SB_SETTEXTW        :: SB_SETTEXTW
WF_SB_SETPARTS        :: SB_SETPARTS


// ---------- right-click menu (TrackPopupMenu via core:sys/windows) ----------
WF_MF_STRING          :: 0x0000
WF_MF_SEPARATOR       :: 0x0800
WF_TPM_RETURNCMD      :: 0x0100
WF_TPM_LEFTALIGN      :: 0x0000
WF_TPM_RIGHTBUTTON    :: 0x0002

WF_TAB_CMD_CLOSE      :: 61001
WF_TAB_CMD_OTHERS     :: 61002
WF_TAB_CMD_ALL        :: 61003

COMM_CTRL_STYLES : UINT : WS_CHILD | WS_VISIBLE | WS_TABSTOP

// Tier-2 control styles. Panel / TabPage / Splitter are plain "Static" child
// windows + subclass (see groupbox.odin for the same pattern).
// WS_CLIPCHILDREN stops the Static's WM_ERASEBKGND from wiping children.
// SS_NOTIFY is not strictly needed for a container but matches GroupBox.
WF_STYLE_PANEL      : DWORD : WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS | SS_NOTIFY
// TabPage deliberately has NO WS_VISIBLE: wf_tab_show_page() reveals only the
// selected page, so the initial paint cannot flash all pages at once.
WF_STYLE_TABPAGE    : DWORD : WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS | SS_NOTIFY
WF_STYLE_TABCTRL    : DWORD : WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_CLIPSIBLINGS
WF_STYLE_STATUSBAR  : DWORD : WS_CHILD | WS_VISIBLE | CCS_NORESIZE | WF_SBARS_SIZEGRIP
WF_STYLE_SPLITTER   : DWORD : WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | SS_NOTIFY
wstyleButton : DWORD : COMM_CTRL_STYLES | BS_NOTIFY
wstyleCalendar : DWORD : COMM_CTRL_STYLES
wstyleCheckBox : DWORD :  COMM_CTRL_STYLES | BS_AUTOCHECKBOX
wxstyleCheckBox : DWORD : WS_EX_LTRREADING | WS_EX_LEFT
wstyleComboBox : DWORD : COMM_CTRL_STYLES | CBS_DROPDOWN
wxstyleComboBox : DWORD : WS_EX_CLIENTEDGE
wstyleDtp : DWORD : 0x52000004
wxstyleDtp : DWORD : WS_EX_LEFT
wstyleLabel : DWORD : COMM_CTRL_STYLES | WS_CLIPCHILDREN | WS_CLIPSIBLINGS | SS_NOTIFY
wstyleListBox : DWORD : COMM_CTRL_STYLES | LBS_HASSTRINGS | WS_VSCROLL | WS_BORDER | LBS_NOTIFY
wstyleListView : DWORD : COMM_CTRL_STYLES | LVS_REPORT | WS_BORDER | LVS_ALIGNLEFT | LVS_SINGLESEL
wstyleNumPick : DWORD : COMM_CTRL_STYLES | UDS_ALIGNRIGHT | UDS_ARROWKEYS  | UDS_HOTTRACK | WS_CLIPSIBLINGS
wstylePgb : DWORD : COMM_CTRL_STYLES | PBS_SMOOTH
wxstylePgb : DWORD : WS_EX_STATICEDGE
wstyleRadio : DWORD : COMM_CTRL_STYLES | BS_AUTORADIOBUTTON | WS_CLIPCHILDREN
wstyleTB : DWORD : COMM_CTRL_STYLES | TBSTYLE
wxstyleTB : DWORD : WS_EX_LEFT | WS_EX_LTRREADING  | WS_EX_CLIENTEDGE
wstyleTkbar : DWORD : COMM_CTRL_STYLES | TBS_AUTOTICKS
wstyleTV : DWORD : COMM_CTRL_STYLES | WS_BORDER | TVS_HASLINES | TVS_HASBUTTONS | TVS_LINESATROOT | TVS_DISABLEDRAGDROP

BLK_FGC : bool : true
NO_FGC : bool : false
TXTABLE : bool : true
NO_TXT : bool : false
FONTABLE : bool : true
NO_FONT : bool : false

ControlInfo :: struct
{
	prefix : string,	
	clsName : [^]u16,	
	style : DWORD,
	exStyle : DWORD,
	bkMode : BackColorMode,
	blackFGC : bool,
	isTextable : bool,
	hasFont : bool,
	
}

ControlStaticData := [ControlKind]ControlInfo {
	.Form = {"Form_", wcnForm, 0, 0, .None, NO_FGC, NO_TXT, NO_FONT},

	.Button = {"Button_", wcnButton, wstyleButton, 0,.None, NO_FGC, TXTABLE, FONTABLE},

	.Calendar = {"Calendar_", wcnCalendar, wstyleCalendar, 0, .None, NO_FGC, NO_TXT, NO_FONT},

	.Check_Box = {"Check_Box_", wcnButton, wstyleCheckBox, wxstyleCheckBox, .Inherit_BGC, BLK_FGC, TXTABLE, FONTABLE},

	.Combo_Box = {"Combo_Box_", wcnCombo, wstyleComboBox, wxstyleComboBox, .White_BGC, BLK_FGC, NO_TXT, FONTABLE},

	.Date_Time_Picker = {"Date_Time_Picker_", wcnDTP, wstyleDtp, wxstyleDtp, .White_BGC, BLK_FGC, NO_TXT, FONTABLE},

	.Group_Box = {"Group_Box_", wcnButton, gbstyleFlag, gbexstyle, .Inherit_BGC, BLK_FGC, TXTABLE, FONTABLE},

	.Label = {"Label_", wcnStatic, wstyleLabel, 0, .Inherit_BGC, BLK_FGC, TXTABLE, FONTABLE},

	.List_Box = {"List_Box_", wcnListBox, wstyleListBox, 0, .White_BGC, BLK_FGC, NO_TXT, FONTABLE},

	.List_View = {"List_View_", wcnListView, wstyleListView, 0, .White_BGC, BLK_FGC, NO_TXT, FONTABLE},

	.Number_Picker = {"Number_Picker_", wcnNumPick, wstyleNumPick, 0, .White_BGC, BLK_FGC, TXTABLE, FONTABLE},

	// Was a dead placeholder: {"Panel_", wcnButton, 0, 0, ...}. Now a real
	// Static-based container (panel.odin).
	.Panel = {"Panel_", wcnStatic, WF_STYLE_PANEL, 0, .Inherit_BGC, NO_FGC, NO_TXT, FONTABLE},

    .Picture_Box = {"Picture_Box_", wcnPictureBox, COMM_CTRL_STYLES, 0, .None, NO_FGC, NO_TXT, NO_FONT},

	.Progress_Bar = {"Progress_Bar_", wcnProgressBar, wstylePgb, wxstylePgb, .None, BLK_FGC, TXTABLE, FONTABLE},

	.Radio_Button = {"Radio_Button_", wcnButton, wstyleRadio, 0, .Inherit_BGC, BLK_FGC, TXTABLE, FONTABLE},

	.Text_Box = {"Text_Box_", wcnEdit, wstyleTB, wxstyleTB, .White_BGC, BLK_FGC, TXTABLE, FONTABLE},

	.Track_Bar = {"Track_Bar_", wcnTrackBar, wstyleTkbar, 0, .Inherit_BGC, NO_FGC, NO_TXT, NO_FONT},

	.Tree_View = {"Tree_View_", wcnTreeView, wstyleTV, 0, .White_BGC, BLK_FGC, NO_TXT, FONTABLE},

	// ---- Tier-2 (ported from winforms-zig) ----
	.Tab_Control  = {"Tab_Control_", wcnTabControl, WF_STYLE_TABCTRL, WS_EX_CONTROLPARENT, .None, NO_FGC, NO_TXT, FONTABLE},
	.Tab_Page     = {"Tab_Page_",    wcnStatic,      WF_STYLE_TABPAGE, 0, .Inherit_BGC, NO_FGC, NO_TXT, FONTABLE},
	.Status_Bar   = {"Status_Bar_",  wcnStatusBar,   WF_STYLE_STATUSBAR, 0, .None, NO_FGC, NO_TXT, FONTABLE},
	.Splitter_Bar = {"Splitter_",    wcnStatic,      WF_STYLE_SPLITTER, 0, .Inherit_BGC, NO_FGC, NO_TXT, NO_FONT},
}


// =============================================================================
// Tier-2 shared helpers (formerly tier2_api.odin, merged here).
// NOTE: the three bare `---` extern declarations are NOT here -- they MUST
// stay inside api_procs.odin's `foreign user32 { ... }` block (see §10).
// =============================================================================

// ---------- extra Win32 bindings ----------
// SetCapture / ReleaseCapture / SetCursor are NOT in the original
// api_procs.odin. The patched api_procs.odin shipped with this package adds
// exactly three lines INSIDE the existing `foreign user32 { ... }` block:
//
//     @(link_name="SetCapture")     wf_set_capture     :: proc(hwnd: HWND) -> HWND ---
//     @(link_name="ReleaseCapture") wf_release_capture :: proc() -> BOOL ---
//     @(link_name="SetCursor")      wf_set_cursor      :: proc(hcursor: HCURSOR) -> HCURSOR ---
//
// They MUST live inside that block: Odin rejects a bodyless `---` procedure
// declared at package scope ("Only a foreign procedure cannot have a body").
// Do NOT re-declare them here. Same-package symbols are directly visible.


// ---------- Common Controls v6 ----------
// Must run BEFORE CreateWindowEx("SysTabControl32" / "msctls_statusbar32").
// initFormDefaults() only asks for ICC_STANDARD_CLASSES (0x4000).
wf_ensure_tab_bar_classes :: proc() {
    @static inited : bool = false
    if inited do return
    icex : INITCOMMONCONTROLSEX
    icex.dwSize = size_of(icex)
    icex.dwIcc = WF_ICC_TAB_CLASSES | WF_ICC_BAR_CLASSES
    InitCommonControlsEx(&icex)
    inited = true
}


// ---------- shared container message forwarding ----------
// Panel and TabPage are real HWNDs and therefore become the DIRECT PARENT of
// their children: WM_COMMAND / WM_NOTIFY / WM_CTLCOLOR* land here, not on the
// Form. GroupBox already solved this (groupbox.odin:362-389); this helper is
// the same set of cases, plus WM_COMMAND routed to CM_CTLCOMMAND.
//
// Returns (result, handled). When handled is true the caller must return the
// result directly, so DefSubclassProc cannot ALSO forward the message to the
// Form and fire the same onClick twice.
wf_forward_container_msg :: proc(this: ^Control, hw: HWND, msg: u32,
                                 wp: WPARAM, lp: LPARAM) -> (LRESULT, bool)
{
    switch msg {
    case WM_COMMAND:
        ctl_hwnd := dir_cast(lp, HWND)
        if ctl_hwnd != nil {
            return SendMessage(ctl_hwnd, CM_CTLCOMMAND, wp, lp), true
        }
        // lp == nil means a menu / accelerator command: let it bubble up.
        return 0, false

    case WM_NOTIFY:
        nm := dir_cast(lp, ^NMHDR)
        if nm != nil && nm.hwndFrom != nil {
            return SendMessage(nm.hwndFrom, CM_NOTIFY, wp, lp), true
        }
        return 0, false

    case WM_CTLCOLORSTATIC:
        ctl_hwnd := dir_cast(lp, HWND)
        return SendMessage(ctl_hwnd, CM_STATIC_COLOR, wp, lp), true

    case WM_CTLCOLOREDIT:
        ctl_hwnd := dir_cast(lp, HWND)
        return SendMessage(ctl_hwnd, CM_EDIT_COLOR, wp, lp), true

    case WM_CTLCOLORLISTBOX:
        ctl_hwnd := dir_cast(lp, HWND)
        cmb_hwnd, okay := find_combo_data(this._ownerForm, ctl_hwnd)
        if okay {
            return SendMessage(cmb_hwnd, CM_COMBOLBCOLOR, wp, lp), true
        }
        return SendMessage(ctl_hwnd, CM_LIST_COLOR, wp, lp), true
    }
    return 0, false
}


// Fix STATIC's default HTTRANSPARENT: without this a Static-based Panel or
// Splitter never receives WM_LBUTTONDOWN (GroupBox does the same at :303).
wf_fix_static_hittest :: proc(hw: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> (LRESULT, bool) {
    if msg != WM_NCHITTEST do return 0, false
    hit := DefSubclassProc(hw, msg, wp, lp)
    if hit == WF_HTTRANSPARENT do return WF_HTCLIENT, true
    return hit, true
}


// System-colour brush, cached. GetSysColorBrush is NOT declared in the
// original api_procs.odin; instead of adding another foreign binding we build
// the brush from CreateSolidBrush(GetSysColor(idx)), BOTH of which the library
// already declares. Cached so WM_ERASEBKGND does not leak a brush per repaint.
@private wf_brush_face   : HBRUSH = nil
@private wf_brush_shadow : HBRUSH = nil

wf_sys_brush :: proc(idx: i32) -> HBRUSH {
    if idx == WF_COLOR_3DSHADOW {
        if wf_brush_shadow == nil do wf_brush_shadow = CreateSolidBrush(GetSysColor(idx))
        return wf_brush_shadow
    }
    if wf_brush_face == nil do wf_brush_face = CreateSolidBrush(GetSysColor(idx))
    return wf_brush_face
}

// Paint a flat 3D-face background (used by Panel / TabPage / Splitter).
wf_fill_3dface :: proc(hdc: HDC, hw: HWND, brush: HBRUSH) -> LRESULT {
    rc : RECT
    GetClientRect(hw, &rc)
    hbr := brush
    if hbr == nil do hbr = wf_sys_brush(WF_COLOR_3DFACE)
    if hbr != nil do api.FillRect(hdc, &rc, hbr)
    return 1
}


// =============================================================================
// Tier-3 helpers: multi-selection + time-only DateTimePicker.
//
// All three MUST be called BEFORE the HWND is created (i.e. right after the
// constructor, before start_mainloop / show_modal). control_base_init() copies
// `ControlStaticData[.kind].style` into ctl._style, and every *_adjust_styles()
// proc only ORs extra bits in -- it never re-adds LVS_SINGLESEL.
// =============================================================================

// ---------- ListView multi-selection ----------
// The stock library hard-codes LVS_SINGLESEL in wstyleListView (:33) and even
// left a `//this.multiSelection = true` commented out in lv_constructor.
// Clearing that one bit lets comctl32 do Ctrl/Shift multi-select natively.
// NOTE: this is a win32 STYLE bit, not an extended style; LVS_EX_* is separate.

WF_LVNI_SELECTED :: 0x0002      // LVM_GETNEXTITEM flag (not declared upstream)

wf_listview_enable_multi_select :: proc(lv: ^ListView)
{
    lv._style = lv._style ~ LVS_SINGLESEL
}

wf_listview_get_selected_count :: proc(lv: ^ListView) -> i32
{
    if lv.handle == nil do return 0
    return cast(i32) SendMessage(lv.handle, LVM_GETSELECTEDCOUNT, 0, 0)
}

// Returns the SELECTED ROW INDICES (not item ids). For a virtual list these
// are display rows; map them through your own lv_sort_index if applicable.
wf_listview_get_selected_indices :: proc(lv: ^ListView,
                                         alloc := context.allocator) -> [dynamic]i32
{
    result := make([dynamic]i32, 0, alloc)
    if lv.handle == nil do return result
    prev : i32 = -1
    for {
        idx := cast(i32) SendMessage(lv.handle, LVM_GETNEXTITEM,
                               WPARAM(prev), LPARAM(WF_LVNI_SELECTED))
        if idx < 0 do break
        append(&result, idx)
        prev = idx
        if len(result) > 100000 do break   // hard guard against a broken loop
    }
    return result
}


// ---------- ListBox multi-selection ----------
// The stock library ALREADY has all of this:
//   multiSelection : b64                         (listbox.odin:59)
//   LBS_EXTENDEDSEL | LBS_MULTIPLESEL           (:334)
//   listbox_get_selected_indices / _items      (:125 / :159)
//   listbox_set_items_selected / select_all /
//   clear_selection                            (:192 / :182 / :203)
// The only trap: control_property_setter() has `case .Multi_Selection: break`
// (:395) -- an EMPTY implementation. So `set_property(lbx, .Multi_Selection,
// true)` silently does nothing. Set the FIELD directly, before HWND creation.

wf_listbox_enable_multi_select :: proc(lbx: ^ListBox)
{
    lbx.multiSelection = true
}


// ---------- DateTimePicker: time-only ----------
// DtpFormat.Time is already in enums.odin:72 and set_dtp_style_internal()
// (datetimepicker.odin:155) maps it to DTS_TIMEFORMAT. Just set the field
// before the handle is created. For a custom string use dtp_set_custom_format().
wf_datetimepicker_set_time_only :: proc(dtp: ^DateTimePicker)
{
    dtp.format = DtpFormat.Time   // fully qualified: `Time` is ALSO a struct name (enums.odin:61)
}


// =============================================================================
// Tier-4 helper: callback context tags.
//
// The Zig port gave every Control `user_ptr` / `user_int` so ONE shared
// handler could tell WHICH page's button was clicked ("Select all" on an old
// tab must not select a different, hidden tab). The Odin Control struct has
// no such field, and modifying controls.odin is deliberately avoided.
//
// A package-level map keyed by the control pointer gives the same thing with
// zero changes to the original library. EventHandler passes `sender` as the
// control pointer, so wf_tag_from_sender() recovers it.
// =============================================================================

WF_Tag :: struct {
    ptr : rawptr,
    n   : i32,
}

@private wf_tags : map[rawptr]WF_Tag

wf_tag_set :: proc(ctl: ^Control, p: rawptr, n: i32) {
    if wf_tags == nil do wf_tags = make(map[rawptr]WF_Tag)
    wf_tags[rawptr(ctl)] = WF_Tag{p, n}
}

wf_tag_ptr :: proc(ctl: ^Control) -> rawptr {
    if ctl == nil do return nil
    if wf_tags == nil do return nil
    v, ok := wf_tags[rawptr(ctl)]
    if !ok do return nil
    return v.ptr
}

wf_tag_int :: proc(ctl: ^Control) -> i32 {
    if ctl == nil do return 0
    if wf_tags == nil do return 0
    v, ok := wf_tags[rawptr(ctl)]
    if !ok do return 0
    return v.n
}

// `Control` is the FIRST field of every derived control (`using control`),
// so ^Button / ^ListView / ^TabPage and ^Control share the same address.
wf_tag_from_sender :: proc(sender: rawptr) -> ^Control {
    return cast(^Control) sender
}


// =============================================================================
// Tier-4 helper: PictureBox inside a TabPage / Panel.
//
// The stock `new_picturebox` hard-codes `p: ^Form` in its PUBLIC signature,
// while its internal `pbox_ctor` actually takes `^Control`. That mismatch is
// why the original demo only ever put a PictureBox on the Form itself.
// This wrapper replicates the 4-line public constructor with a ^Control
// parent, so the ported demo can keep the picture on its Home tab page.
// =============================================================================

wf_new_picturebox :: proc(parent: ^Control, x, y, w, h: i32,
                          img_path: string, mode: PictureSizeMode) -> ^PictureBox
{
    this := pbox_ctor(parent, x, y, w, h)
    this.sizeMode = mode
    this._imgPath = img_path
    return this
}
