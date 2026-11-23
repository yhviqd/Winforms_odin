// =============================================================================
// virtual_list.odin -- LVS_OWNERDATA virtual ListView for kcvinker/Winforms.
//
// This is the ONE capability the Zig port had and the Odin library did not:
// 100 000 rows with ZERO row storage. comctl32 owns only a row COUNT; every
// visible cell is produced on demand via LVN_GETDISPINFOW.
//
// HOW IT PLUGS INTO THE EXISTING LIBRARY (no original file is modified):
//   * Build a normal ^ListView, but OR LVS_OWNERDATA into ctl._style BEFORE
//     the HWND is created (control_base_init copies ControlStaticData style).
//   * forms.odin:646 forwards the parent's WM_NOTIFY to the control itself as
//     CM_NOTIFY (WM_APP+2). We install ONE EXTRA subclass on the ListView
//     HWND and handle CM_NOTIFY / LVN_GETDISPINFOW there. Other codes are
//     passed down with DefSubclassProc so the stock lv_wnd_proc (custom draw,
//     header painting, tier-1 column sort on CLASSIC lists) still runs.
//   * wf_virtual_init_all() is called from the Form's onLoad (WM_SHOWWINDOW),
//     by which time EVERY child HWND exists. It sends LVM_SETITEMCOUNT and
//     installs the subclass.
//
// DESIGN NOTES
//   * display row -> data row `row_map` is what sorting changes. The data
//     source is never touched, exactly like the Zig port.
//   * pszText must stay valid until comctl32 finishes painting. One [256]u16
//     buffer per list is enough: comctl32 asks for ONE cell at a time. The
//     UTF-8 -> UTF-16 conversion below handles the full BMP + surrogate pairs.
//   * Column sorting DOES generate one key per row (100k cell calls) before
//     comparing, so no formatting happens inside the comparator -- same trick
//     as the Zig port, otherwise ~1.7M formatter calls freeze the UI.
//
// NOT COMPILED HERE: no Odin toolchain in the sandbox. See PORT_GUIDE.md.
// =============================================================================

package winforms


// LVN_FIRST is declared in control_constants.odin:272 (4294967196 == -100
// as u32). LVN_GETDISPINFOW = LVN_FIRST - 77. NMHDR.code is UINT, so these
// u32 values compare directly.
WF_LVN_GETDISPINFOW :: LVN_FIRST - 77
WF_LVM_SETCOLUMNW   :: 4192          // api_message.odin:936 is commented out
WF_LVCF_TEXT        :: 0x0004

WF_LVDispInfo :: struct {
    hdr  : NMHDR,
    item : LVITEM,                   // api_types.odin:224, pszText is `wstring`
}

// The cell provider. The returned string is copied into a stable UTF-16
// buffer IMMEDIATELY, so a temp-allocator string is safe.
WF_VirtualCell :: proc(row: i32, col: i32) -> string

WF_VirtualList :: struct {
    lv        : ^ListView,
    cell      : WF_VirtualCell,
    rows      : i32,
    cols      : int,
    // `map` is an ODIN KEYWORD -- it cannot be a field name. All 17 compile
    // errors in the original build came from this one declaration.
    row_map   : [dynamic]i32,       // display row -> data row
    sort_col  : i32,
    sort_asc  : bool,
    base      : [dynamic]string,    // original column titles (no ^ / v)
    wbuf      : [256]u16,
    attached  : bool,
}

@private wf_vlists     : [dynamic]^WF_VirtualList
// Absolute fallback: even if the WF_VirtualList record cannot be found,
// CM_NOTIFY must NEVER reach the stock lv_wnd_proc (its items array is empty).
@private wf_vl_empty   : [1]u16 = {0}


// -----------------------------------------------------------------------------
// PUBLIC API
// -----------------------------------------------------------------------------

// Create a virtual ListView. `col_names` and `col_widths` MUST have the same
// length. Call this BEFORE start_mainloop() / show_modal().
new_virtual_listview :: proc(parent: ^Control, x, y, w, h: i32,
                             col_names: []string, col_widths: []int,
                             rows: i32, cell: WF_VirtualCell) -> ^ListView
{
    // Call lv_constructor7 DIRECTLY. Going through the `new_listview`
    // procedure group with a []^ListViewColumn slice would ALSO match
    // lv_constructor6(coldata: ..any) and be reported as ambiguous.
    // lv_constructor7 is @private to the package, which this file is in.
    cols := make([dynamic]^ListViewColumn)
    defer delete(cols)
    n := len(col_names)
    if len(col_widths) < n do n = len(col_widths)
    for i in 0..<n {
        append(&cols, new_listview_column(col_names[i], col_widths[i],
                                          ColumnAlignment.Center))
    }

    lv := lv_constructor7(parent, x, y, w, h, cols[:])
    // Owner-data is a plain style bit, not LVS_EX_*. lv_adjust_styles() only
    // ORs extra bits in, so this survives handle creation.
    lv._style = lv._style | LVS_OWNERDATA

    vl := new(WF_VirtualList)
    vl.lv       = lv
    vl.cell     = cell
    vl.rows     = rows
    vl.cols     = n
    vl.sort_col = -1
    vl.sort_asc = true
    vl.attached = false
    vl.row_map      = make([dynamic]i32)
    vl.base     = make([dynamic]string)
    for i in 0..<n {
        append(&vl.base, wf_dup_string(col_names[i]))
    }
    wf_virtual_resize_map(vl, rows)
    append(&wf_vlists, vl)
    return lv
}

// Call ONCE from the Form's onLoad (or right before a nested modal loop).
// Sends LVM_SETITEMCOUNT and installs the dispinfo subclass for every
// virtual list created so far.
wf_virtual_init_all :: proc()
{
    for vl in wf_vlists {
        if vl.attached do continue
        if vl.lv.handle == nil do continue

        // HARD GUARD: LVS_OWNERDATA must be in the style that CreateWindowEx
        // used. If it is missing, LVM_SETITEMCOUNT would make comctl32 try to
        // materialise 100 000 real items (a multi-second freeze / OOM), and
        // lv_wnd_proc would index an empty `items` array. Skip + report
        // instead of hanging the process.
        if (vl.lv._style & LVS_OWNERDATA) == 0 {
            ptf("VirtualList: LVS_OWNERDATA missing, skip SETITEMCOUNT\n")
            continue
        }

        // *** ORDER IS CRITICAL ***
        // LVM_SETITEMCOUNT is SYNCHRONOUS: comctl32 immediately sends
        // LVN_GETDISPINFOW + NM_CUSTOMDRAW for the first visible rows while
        // the SendMessage is still on the stack. The OLD code sent the count
        // BEFORE installing the subclass, so those notifications reached the
        // stock lv_wnd_proc, whose CM_NOTIFY branch does
        //     pitem := this.items[lvcd.nmcd.dwItemSpec]
        // A virtual list has ZERO items -> out-of-bounds -> crash on page
        // open. Install FIRST, then publish the row count.
        fn : SUBCLASSPROC = wf_vl_wnd_proc
        set_subclass(vl.lv, fn)
        vl.attached = true

        SendMessage(vl.lv.handle, LVM_SETITEMCOUNT, WPARAM(vl.rows), 0)
        // Reuse the LIBRARY's helper (controls.odin:455): it allocates a
        // unique sub-class id and passes to_dwptr(ctl). ^ListView implicitly
        // converts to ^Control (`using control: Control`, same address), so
        // control_cast(ListView, ref_data) recovers the exact same pointer.
        // Installed LAST => newest callback runs FIRST in the subclass chain.
    }
}

wf_virtual_find :: proc(lv: ^ListView) -> ^WF_VirtualList
{
    if lv == nil do return nil
    for vl in wf_vlists {
        if vl.lv == lv do return vl
    }
    return nil
}

wf_virtual_set_row_count :: proc(lv: ^ListView, rows_in: i32)
{
    vl := wf_virtual_find(lv)
    if vl == nil do return
    // Odin proc parameters are CONST. Copy into a local before clamping.
    rows := rows_in
    if rows < 0 do rows = 0
    vl.rows = rows
    wf_virtual_resize_map(vl, rows)
    if vl.attached do SendMessage(lv.handle, LVM_SETITEMCOUNT, WPARAM(rows), 0)
}

wf_virtual_refresh :: proc(lv: ^ListView)
{
    if lv.handle == nil do return
    InvalidateRect(lv.handle, nil, false)
}

wf_virtual_ensure_visible :: proc(lv: ^ListView, display_row: i32)
{
    if lv.handle == nil do return
    SendMessage(lv.handle, LVM_ENSUREVISIBLE, WPARAM(display_row), LPARAM(0))
}

wf_virtual_get_selected_row :: proc(lv: ^ListView) -> i32
{
    if lv.handle == nil do return -1
    // LVM_GETNEXTITEM: -1 means "start from the beginning". WPARAM is an
    // unsigned uintptr, so a NEGATIVE UNTYPED literal is rejected; a typed
    // i32 variable is converted at runtime (wraps to all-ones) and is allowed.
    // Same shape as wf_listview_get_selected_indices in ctrl_static_data.odin.
    start : i32 = -1
    return cast(i32) SendMessage(lv.handle, LVM_GETNEXTITEM,
                                 WPARAM(start), LPARAM(WF_LVNI_SELECTED))
}

wf_virtual_get_top_index :: proc(lv: ^ListView) -> i32
{
    if lv.handle == nil do return 0
    return cast(i32) SendMessage(lv.handle, LVM_GETTOPINDEX, 0, 0)
}

wf_virtual_get_visible_count :: proc(lv: ^ListView) -> i32
{
    if lv.handle == nil do return 0
    return cast(i32) SendMessage(lv.handle, LVM_GETCOUNTPERPAGE, 0, 0)
}

wf_virtual_get_row_count :: proc(lv: ^ListView) -> i32
{
    vl := wf_virtual_find(lv)
    return vl == nil ? 0 : vl.rows
}


// -----------------------------------------------------------------------------
// PRIVATE
// -----------------------------------------------------------------------------

@private wf_dup_string :: proc(s: string, alloc := context.allocator) -> string
{
    b := make([]u8, len(s), alloc)
    if len(s) > 0 do copy(b[:], s)
    return string(b)
}

// Grow = append identity ids. Shrink = keep only still-valid ids in their
// existing relative order, then append any missing ids. The result is always
// a permutation of 0..rows-1, so LVN_GETDISPINFOW can never feed an out-of
// range data row to the cell provider.
@private wf_virtual_resize_map :: proc(vl: ^WF_VirtualList, rows: i32)
{
    if rows == i32(len(vl.row_map)) do return
    if rows < 0 do return

    if rows < i32(len(vl.row_map)) {
        seen := make([dynamic]bool, int(rows))
        defer delete(seen)
        for i in 0..<len(seen) {
            seen[i] = false
        }
        kept := make([dynamic]i32)
        for id in vl.row_map {
            if id >= 0 && id < rows && !seen[int(id)] {
                seen[int(id)] = true
                append(&kept, id)
            }
        }
        delete(vl.row_map)
        vl.row_map = kept
        for i in 0..<int(rows) {
            if !seen[i] {
                append(&vl.row_map, i32(i))
            }
        }
    } else {
        for i := i32(len(vl.row_map)); i < rows; i += 1 {
            append(&vl.row_map, i)
        }
    }
}

// UTF-8 -> UTF-16 into the per-list stable buffer. Handles 1..4 byte
// sequences and emits surrogate pairs for code points above the BMP.
// ASCII-only data takes the fast first branch.
@private wf_utf8_to_utf16 :: proc(s: string, buf: []u16) -> int
{
    n : int = 0
    i : int = 0
    limit := len(buf) - 1
    for i < len(s) && n < limit {
        b := s[i]
        cp : u32 = 0
        step := 1
        if b < 0x80 {
            cp = u32(b)
        } else if (b & 0xE0) == 0xC0 && i + 1 < len(s) {
            cp = (u32(b & 0x1F) << 6) | u32(s[i+1] & 0x3F)
            step = 2
        } else if (b & 0xF0) == 0xE0 && i + 2 < len(s) {
            cp = (u32(b & 0x0F) << 12) | (u32(s[i+1] & 0x3F) << 6) | u32(s[i+2] & 0x3F)
            step = 3
        } else if (b & 0xF8) == 0xF0 && i + 3 < len(s) {
            cp = (u32(b & 0x07) << 18) | (u32(s[i+1] & 0x3F) << 12) |
                 (u32(s[i+2] & 0x3F) << 6) | u32(s[i+3] & 0x3F)
            step = 4
        } else {
            cp = u32(b)      // malformed byte: pass through
        }
        i += step
        if cp > 0xFFFF && n + 1 < limit {
            cp -= 0x10000
            buf[n] = u16(0xD800 + (cp >> 10)); n += 1
            buf[n] = u16(0xDC00 + (cp & 0x3FF)); n += 1
        } else {
            buf[n] = u16(cp); n += 1
        }
    }
    buf[n] = 0
    return n
}

@private wf_vl_set_title :: proc(vl: ^WF_VirtualList, col: int, marked: bool, asc: bool)
{
    if col < 0 || col >= len(vl.base) do return
    txt : string = vl.base[col]
    if marked {
        txt = asc ? wf_cat2(vl.base[col], " ^") : wf_cat2(vl.base[col], " v")
    }
    // LVCOLUMN.pszText is `wstring` (i.e. [^]u16). Build a small local
    // wide buffer for the duration of the synchronous SendMessage.
    wb : [128]u16
    wf_utf8_to_utf16(txt, wb[:])
    lvc : LVCOLUMN = {}
    lvc.mask    = WF_LVCF_TEXT
    lvc.pszText = &wb[0]
    SendMessage(vl.lv.handle, WF_LVM_SETCOLUMNW, WPARAM(col), dir_cast(&lvc, LPARAM))
}

// Lexicographic compare. Kept local (no core:strings dependency, so it works
// across Odin releases). `asc` reverses the comparison for descending order.
@private wf_vl_less :: proc(a, b: string, asc: bool) -> bool {
    m := len(a) < len(b) ? len(a) : len(b)
    for i in 0..<m {
        if a[i] != b[i] {
            return asc ? (a[i] < b[i]) : (a[i] > b[i])
        }
    }
    return asc ? (len(a) < len(b)) : (len(a) > len(b))
}

@private wf_vl_better :: proc(keys: []string, idx: []i32, x, y: int, asc: bool) -> bool {
    return !wf_vl_less(keys[idx[x]], keys[idx[y]], asc)
}

@private wf_cat2 :: proc(a, b: string) -> string {
    out := make([]u8, len(a) + len(b), context.temp_allocator)
    if len(a) > 0 do copy(out[0:len(a)], a)
    if len(b) > 0 do copy(out[len(a):], b)
    return string(out)
}

// Stable-enough heap sort over an index array, comparing pre-generated keys.
// A max-heap is required (ascending result); picking the SMALLER child would
// silently reverse the order. Same bug the Zig port had to fix.
@private wf_vl_heap_sort :: proc(keys: []string, idx: []i32, asc: bool)
{
    n := len(idx)
    if n < 2 do return

    for start := n / 2 - 1; start >= 0; start -= 1 {
        root := start
        for {
            child := root * 2 + 1
            if child >= n do break
            if child + 1 < n && wf_vl_better(keys, idx, child + 1, child, asc) do child += 1
            if wf_vl_better(keys, idx, root, child, asc) do break
            tmp := idx[root]; idx[root] = idx[child]; idx[child] = tmp
            root = child
        }
    }
    for end := n - 1; end > 0; end -= 1 {
        tmp := idx[0]; idx[0] = idx[end]; idx[end] = tmp
        root : int = 0
        for {
            child := root * 2 + 1
            if child >= end do break
            if child + 1 < end && wf_vl_better(keys, idx, child + 1, child, asc) do child += 1
            if wf_vl_better(keys, idx, root, child, asc) do break
            t2 := idx[root]; idx[root] = idx[child]; idx[child] = t2
            root = child
        }
    }
}

@private wf_vl_sort_column :: proc(vl: ^WF_VirtualList, col: i32)
{
    if col < 0 || col >= i32(vl.cols) do return
    if vl.rows < 1 do return
    vl.sort_asc = (col == vl.sort_col) ? !vl.sort_asc : true
    vl.sort_col = col

    n := int(vl.rows)
    keys := make([dynamic]string, 0, n)
    defer {
        for k in keys {
            delete(k)
        }
        delete(keys)
    }
    idx := make([dynamic]i32, 0, n)
    defer delete(idx)
    for r in 0..<n {
        s := vl.cell(wf_virtual_data_row(vl, i32(r)), col)
        append(&keys, wf_dup_string(s))
        append(&idx, i32(r))
    }
    wf_vl_heap_sort(keys[:], idx[:], vl.sort_asc)

    delete(vl.row_map)
    vl.row_map = make([dynamic]i32, 0, n)
    for i in 0..<n {
        append(&vl.row_map, idx[i])
    }

    for c in 0..<vl.cols {
        wf_vl_set_title(vl, c, c == int(col), vl.sort_asc)
    }
    InvalidateRect(vl.lv.handle, nil, false)
}

@private wf_virtual_data_row :: proc(vl: ^WF_VirtualList, display_row: i32) -> i32
{
    if display_row < 0 || display_row >= i32(len(vl.row_map)) do return display_row
    return vl.row_map[int(display_row)]
}


// -----------------------------------------------------------------------------
// The subclass: answer LVN_GETDISPINFOW, sort on LVN_COLUMNCLICK.
// -----------------------------------------------------------------------------

@private wf_vl_wnd_proc :: proc "stdcall" (hw: HWND, msg: u32, wp: WPARAM, lp: LPARAM,
                                           sc_id: UINT_PTR, ref_data: DWORD_PTR) -> LRESULT
{
    context = global_context
    lv := control_cast(ListView, ref_data)
    vl := wf_virtual_find(lv)

    // ------------------------------------------------------------------
    // A virtual ListView has ZERO entries in `ListView.items`. The stock
    // lv_wnd_proc's ENTIRE CM_NOTIFY branch is written against that array:
    //
    //   NM_CUSTOMDRAW / CDDS_PREPAINT   -> CDRF_NOTIFYITEMDRAW
    //   NM_CUSTOMDRAW / ITEMPREPAINT   -> this.items[dwItemSpec]  <-- OOB
    //   NM_CLICK / NM_DBLCLK           -> this.items[nmia.iItem]   <-- OOB
    //   LVN_ITEMCHANGED                -> this.items[nmlv.iItem]   <-- OOB
    //
    // comctl32 sends NM_CUSTOMDRAW and LVN_ITEMCHANGED for the first visible
    // rows the moment the list paints -- and SYNCHRONOUSLY from inside
    // LVM_SETITEMCOUNT. Letting ANY of them reach DefSubclassProc crashes the
    // process. This is exactly why "opening Big Data kills the app".
    //
    // Therefore this subclass (installed LAST, so it runs FIRST) owns EVERY
    // CM_NOTIFY for a virtual list. Nothing is passed down the chain.
    // Non-CM_NOTIFY messages (WM_NOTIFY from the Header for column painting,
    // WM_ERASEBKGND, WM_NCDESTROY, ...) still go to DefSubclassProc.
    // ------------------------------------------------------------------
    if msg == CM_NOTIFY {
        nm := dir_cast(lp, ^NMHDR)
        if nm == nil do return 0

        if nm.code == WF_LVN_GETDISPINFOW {
            di := dir_cast(lp, ^WF_LVDispInfo)
            // Mirrors the working Zig port: only touch the structure when
            // comctl32 actually asked for text (LVIF_TEXT). If the code were
            // ever mis-matched, writing into the struct would corrupt it.
            if (di.item.mask & LVIF_TEXT) == 0 do return 0

            if vl != nil &&
               di.item.iItem >= 0 && di.item.iItem < vl.rows &&
               di.item.iSubItem >= 0 && di.item.iSubItem < i32(vl.cols) {
                s := vl.cell(wf_virtual_data_row(vl, di.item.iItem),
                             di.item.iSubItem)
                wf_utf8_to_utf16(s, vl.wbuf[:])
                di.item.pszText = &vl.wbuf[0]
            } else {
                // Valid, NUL-terminated buffer -- never let comctl32 read NULL.
                di.item.pszText = &wf_vl_empty[0]
            }
            return 0
        }

        if vl != nil && nm.code == LVN_COLUMNCLICK {
            nmlv := dir_cast(lp, ^NMLISTVIEW)
            wf_vl_sort_column(vl, nmlv.iSubItem)
            return 0
        }

        // Tier-1 right-click menu: the classic list handles NM_RCLICK inside
        // lv_wnd_proc, but that handler is now unreachable for virtual lists.
        // Mirror it here so a virtual ListView keeps the same context-menu
        // behaviour. contextmenu_show is @private but same-package visible.
        if vl != nil && nm.code == WF_NM_RCLICK {
            if lv.contextMenu != nil do contextmenu_show(lv.contextMenu, 0)
            return 0
        }

        // NM_CUSTOMDRAW: return CDRF_DODEFAULT (== 0) at PREPAINT so comctl32
        // draws natively and does NOT request CDDS_ITEMPREPAINT.
        // LVN_ODCACHEHINT / LVN_ITEMCHANGED / NM_CLICK / NM_DBLCLK /
        // LVN_ITEMACTIVATE / tier-1's classic-list sorter / ... : ALL
        // swallowed. None may reach the stock lv_wnd_proc.
        return 0
    }

    // Remove OUR subclass entry but keep the chain alive: the stock
    // lv_wnd_proc still needs WM_NCDESTROY for its own dtor / subclass cleanup.
    if msg == WM_NCDESTROY {
        rfn : SUBCLASSPROC = wf_vl_wnd_proc
        RemoveWindowSubclass(hw, rfn, sc_id)
    }
    return DefSubclassProc(hw, msg, wp, lp)
}
