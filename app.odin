// =============================================================================
// app_zig_port.odin -- FULL port of winforms-zig/src/app.zig to Odin/Winforms.
//
//   +---------------------------------------------------------------+
//   | topBar: b1 b2 b3  ComboBox  DateTimePicker(time)              |
//   +----------+----------------------------------------------------+
//   | NAVBAR   | TabControl strip                                   |
//   | [btn]    +----------------------------------------------------+
//   | [btn]    | active page (a "view")                            |
//   | ...      |                                                    |
//   +----------+----------------------------------------------------+
//   | StatusBar: Ready | active tab | message                       |
//   +---------------------------------------------------------------+
//
// Build from the REPO ROOT (next to app.odin):
//     odin build .\app_zig_port.odin -file
// Keep app_zig_port.exe.manifest next to the exe (copy app.exe.manifest).
//
// What is ported, one-for-one:
//   * Original Odin demo widgets, all living inside the Home tab page.
//   * Two-pane shell: navbar / draggable splitter / workspace / statusbar.
//   * 8 runtime views (Dashboard, Widgets, Users, Settings, About, Big Data,
//     Components[modal], Panel) created at RUNTIME via flex_host_*_at().
//   * 100 000-row LVS_OWNERDATA virtual ListView (virtual_list.odin).
//   * Component-rich modal dialog + a "new user" input modal.
//   * Tab right-click Close / Close Others / Close All with one confirmation.
//   * Column sorting with ^ / v markers on both classic AND virtual lists.
//   * ListView check boxes, right-click menu, multi-select ListBox,
//     TrayIcon + balloon, two-level MenuBar, file dialog, Timer, mouse
//     enter/leave/hover handlers, gradient / flat buttons.
//
// See PORT_GUIDE.md for the exact Zig -> Odin API mapping and the honest
// list of degradations. NOT COMPILED HERE (no Odin toolchain in sandbox).
// =============================================================================

#+feature using-stmt
package main

import "core:fmt"
import "core:mem"
import "base:runtime"
import ui "winforms"

print :: fmt.println
ptf  :: fmt.printf


// -----------------------------------------------------------------------------
// Globals. Odin procedures do not capture locals, so every callback needs
// package-level state -- exactly why the original app.odin uses globals too.
// -----------------------------------------------------------------------------
frm   : ^ui.Form
pgb   : ^ui.ProgressBar
tk    : ^ui.TrackBar
tmr   : ^ui.Timer
ti    : ^ui.TrayIcon
cmb   : ^ui.ComboBox
np1   : ^ui.NumberPicker
lb2   : ^ui.Label
tb    : ^ui.TextBox
tv    : ^ui.TreeView

tabc          : ^ui.TabControl
sbar          : ^ui.StatusBar
split_bar     : ^ui.Splitter
g_flex        : ui.Flex_Host
workspace_box : int = -1
navbar_box    : int = -1
view_seq      : i32 = 0
tab_strip     : f32 = 26.0

cnt_me : int = 1
cnt_ml : int = 1
cnt_mh : int = 1

nav_titles := [?]string{
    "Dashboard", "Widgets", "Users", "Settings",
    "About", "Big Data", "Components", "Panel",
}

big_rows : i32 = 100_000
big_seed : i32 = 0

// modal windows
g_components : ^ui.Form
g_comp_flex  : ui.Flex_Host
g_comp_name  : ^ui.TextBox
g_comp_dept  : ^ui.ComboBox
g_comp_ctab  : ^ui.TabControl
g_comp_tab_box : int = -1
g_adduser    : ^ui.Form
g_add_name   : ^ui.TextBox
g_add_role   : ^ui.TextBox
g_add_target : rawptr = nil        // the ListBox of the page that opened it


// -----------------------------------------------------------------------------
// Small string helpers. Avoids any dependency on fmt.tprintf / bufprintf
// (their names vary across Odin releases) and avoids the default " " separator
// of multi-arg fmt.tprint.
// -----------------------------------------------------------------------------
i2s :: proc(v: i32) -> string { return fmt.tprint(v) }

cat :: proc(parts: ..string) -> string {
    n := 0
    for p in parts do n += len(p)
    b := make([]u8, n)
    k := 0
    for p in parts {
        if len(p) > 0 {
            copy(b[k : k + len(p)], p)
            k += len(p)
        }
    }
    return string(b)
}

pad :: proc(v: i32, width: int) -> string {
    s := i2s(v)
    if len(s) >= width do return s
    out := make([]u8, width)
    for i in 0..<width {
        out[i] = '0'
    }
    copy(out[width - len(s) : width], s)
    return string(out)
}


// -----------------------------------------------------------------------------
// Virtual list cell provider. 100 000 rows, ZERO storage.
//
// ZERO ALLOCATION IS REQUIRED HERE. The original version used cat()/pad()/
// i2s() (fmt.tprint), i.e. 2-3 heap allocations PER CELL. Painting one screen
// is ~80 calls, but a column sort calls this 100 000 times and then dup'es
// every key -- that was 300 000+ tiny allocations plus 100 000 keys, enough
// to stall / exhaust the heap. The provider's result is copied IMMEDIATELY
// (into vl.wbuf by the dispinfo handler, or into a dup'ed key by the sorter),
// so one shared scratch buffer is safe even during a full sort.
// -----------------------------------------------------------------------------
big_put :: proc(buf: []u8, at: int, s: string) -> int {
    if len(s) > 0 do copy(buf[at : at + len(s)], s)
    return at + len(s)
}

big_int :: proc(buf: []u8, at: int, v_in: i32) -> int {
    v := v_in
    k := at
    if v < 0 {
        buf[k] = '-'; k += 1
        v = -v
    }
    if v == 0 {
        buf[k] = u8('0'); k += 1
        return k
    }
    tmp : [12]u8
    n := 0
    for v > 0 {
        tmp[n] = u8(v % 10) + u8('0')
        v /= 10
        n += 1
    }
    for i in 0..<n {
        buf[k + i] = tmp[n - 1 - i]
    }
    return k + n
}

big_pad :: proc(buf: []u8, at: int, v_in: i32, width: int) -> int {
    v := v_in
    for i in 0..<width {
        buf[at + width - 1 - i] = u8(v % 10) + u8('0')
        v /= 10
    }
    return at + width
}

big_data_cell :: proc(row: i32, col: i32) -> string {
    @static buf : [96]u8
    k := 0
    switch col {
    case 0:
        k = big_put(buf[:], k, "ID-")
        k = big_pad(buf[:], k, row, 6)
    case 1:
        k = big_put(buf[:], k, "Record ")
        k = big_int(buf[:], k, row)
    case 2:
        a := (row * 37 + big_seed) % 900
        b := (row * 7) % 100
        k = big_int(buf[:], k, a)
        k = big_put(buf[:], k, ".")
        k = big_pad(buf[:], k, b, 2)
        k = big_put(buf[:], k, " MB")
    case 3:
        switch (row + big_seed) % 3 {
        case 0: k = big_put(buf[:], k, "Active")
        case 1: k = big_put(buf[:], k, "Idle")
        case:   k = big_put(buf[:], k, "Archived")
        }
    }
    return string(buf[0:k])
}


// -----------------------------------------------------------------------------
// Event handlers
// -----------------------------------------------------------------------------
timer_on_tick :: proc(_: rawptr, _: ^ui.EventArgs) {
    // Deliberately silent: the "Flat Color" button starts the 400 ms timer,
    // but the Zig port stopped flooding the console on every tick.
}

track_change :: proc(_: rawptr, _: ^ui.EventArgs) {
    ui.progressbar_set_value(pgb, tk.value)
}

new_client_menu_click :: proc(_: rawptr, _: ^ui.EventArgs) {
    print("New Client selected")
}

context_menu_click :: proc(_: rawptr, _: ^ui.EventArgs) {
    print("Compile option is selected")
}

on_column_click :: proc(sender: ^ui.ListView, column: i32) {
    ptf("ListView column %d clicked (sorted + marker updated)\n", column)
    ui.statusbar_set_text(sbar, 2, cat("sorted column ", i2s(column)))
}

on_windows_menu :: proc(_: rawptr, _: ^ui.EventArgs) {
    print("Windows menu selected")
}

open_file_proc :: proc(_: rawptr, _: ^ui.EventArgs) {
    ofd := ui.file_open_dialog(initFolder = "D:\\Work\\Shashikumar\\2023\\Jack Ryan",
                               filterStr = "PDF Files|*.pdf")
    ui.dialog_show(ofd, frm.handle)
    ptf("Dialog result: %s\n", ofd.selectedPath)
    ui.dialog_destroy(ofd)
}

b2_click_proc :: proc(_: rawptr, _: ^ui.EventArgs) {
    ui.timer_start(tmr)
    print("duuuup")
}

tv_event_test :: proc(c: ^ui.TreeView, e: ^ui.TreeEventArgs) {
    ptf("tree event happened %s\n", e.nodeText)
}

frm_click_proc :: proc(_: rawptr, _: ^ui.EventArgs) {
    ui.tray_show_balloon(ti, "Winforms", "Info from Winforms", 3000)
}

on_mouse_enter :: proc(_: rawptr, _: ^ui.EventArgs) {
    ptf("[%d] Mouse entered Numpic\n", cnt_me)
    cnt_me += 1
}
on_mouse_leave :: proc(_: rawptr, _: ^ui.EventArgs) {
    ptf("[%d] Mouse left from Numpic\n", cnt_ml)
    cnt_ml += 1
}
on_mouse_hover :: proc(_: rawptr, _: ^ui.EventArgs) {
    ptf("[%d] Mouse hovered Numpic\n", cnt_mh)
    cnt_mh += 1
}

tab_changed :: proc(tab: ^ui.TabControl, index: i32) {
    ptf("Tab selected: %d\n", index)
    ui.statusbar_set_text(sbar, 1, cat("active tab = ", i2s(index)))
}

split_moved :: proc(sp: ^ui.Splitter, pos: i32) {
    if navbar_box < 0 do return
    ui.flex_host_set_width(&g_flex, navbar_box, f32(pos))
    ui.flex_host_apply(&g_flex)
    ui.statusbar_set_text(sbar, 2, cat("navbar width = ", i2s(pos), "px"))
    ptf("Splitter released: navbar width = %dpx\n", pos)
}

view_action :: proc(_: rawptr, _: ^ui.EventArgs) {
    print("View action clicked")
}

listbox_changed :: proc(sender: rawptr, _: ^ui.EventArgs) {
    lbx := cast(^ui.ListBox) sender
    idx := ui.listbox_get_selected_indices(lbx)
    defer { if len(idx) > 0 do delete(idx) }
    ptf("ListBox: %d item(s) selected\n", len(idx))
    for i in idx {
        ptf("  [%d] %s\n", i, ui.listbox_get_item(lbx, i))
    }
}

listview_check_changed :: proc(sender: ^ui.ListView, e: ^ui.LVItemCheckEventArgs) {
    // `b32` is Odin's 32-bit BOOLEAN type: it works as an `if` condition
    // (fonts.odin:59 uses `if !usePrimary`), but comparing it to the untyped
    // integer 0 is a type error. Do not write `!= 0`.
    word : string = "unchecked"
    if e.isChecked {
        word = "checked"
    }
    ui.statusbar_set_text(sbar, 2, cat("row ", i2s(e.index), ": ", word))
    ptf("ListView row %d %s\n", e.index, word)
}

tab_confirm_close :: proc(tab: ^ui.TabControl, index: i32,
                          scope: ui.WF_TabCloseScope, will_close: i32) -> bool {
    msg : string = "确定要关闭这个标签页吗？"
    switch scope {
    case .One:
        name := "这个标签页"
        if index >= 0 && index < i32(len(tab.pages)) {
            name = tab.pages[index].title
        }
        msg = cat("确定要关闭「", name, "」吗？  该页面里的内容不会被保存。")
    case .Others:
        msg = cat("确定要关闭其它 ", i2s(will_close), " 个标签页吗？")
    case .All:
        msg = cat("确定要关闭全部 ", i2s(will_close), " 个标签页吗？")
    }
    // Button2 = "No" has focus, so a stray Enter cannot delete a page.
    r := ui.msgbox(msg, "关闭确认", ui.MsgBoxButtons.Yes_No,
                   ui.MsgBoxIcons.Question, ui.MsgBoxDefButton.Button2)
    if r != ui.MsgResult.Yes {
        ui.statusbar_set_text(sbar, 2, "关闭已取消")
        return false
    }
    return true
}

tab_page_closing :: proc(tab: ^ui.TabControl, page: ^ui.TabPage, index: i32) {
    box := ui.wf_tag_int(cast(^ui.Control) page)
    if box >= 0 do ui.flex_host_detach(&g_flex, int(box))
    ui.statusbar_set_text(sbar, 2, "tab closed")
    ptf("TabControl: closing tab %d, detached flex box %d\n", index, box)
}


// -----------------------------------------------------------------------------
// "Add user..." modal: a plain ^Form with 2 TextBoxes + OK / Cancel.
// Replaces Zig's showModal(ModalSpec) with the component-style modal window.
// -----------------------------------------------------------------------------
add_user_ok :: proc(_: rawptr, _: ^ui.EventArgs) {
    name := ui.control_get_text(g_add_name.control)
    role := ui.control_get_text(g_add_role.control)
    ui.close_modal(g_adduser, 1)
    if len(name) == 0 {
        ui.msgbox("姓名不能为空。", "输入有误")
        ui.statusbar_set_text(sbar, 2, "姓名为空，未添加")
        return
    }
    if g_add_target != nil {
        ui.listbox_add_item(cast(^ui.ListBox) g_add_target, name)
    }
    ui.statusbar_set_text(sbar, 2, cat("added ", name, " (", role, ")"))
    ptf("Modal: confirmed -> name='%s' role='%s'\n", name, role)
}

add_user_cancel :: proc(_: rawptr, _: ^ui.EventArgs) {
    ui.close_modal(g_adduser, 0)
}

build_add_user_modal :: proc() {
    g_adduser = ui.new_modal_form(frm, "新建用户", 380, 220)
    ui.new_label(g_adduser, "填写下面的信息，点「确定」加入列表；「取消」或 Esc 放弃。",
                 16, 14, 340, 20)
    ui.new_label(g_adduser, "姓名", 16, 48, 60, 22)
    g_add_name = ui.new_textbox(g_adduser, 84, 46, 260, 26)
    ui.new_label(g_adduser, "角色", 16, 86, 60, 22)
    g_add_role = ui.new_textbox(g_adduser, 84, 84, 260, 26)
    ui.control_set_text(cast(^ui.Control) g_add_role, "Viewer")
    ok := ui.new_button(g_adduser, "确定", 170, 132, 90, 30)
    ok.onClick = add_user_ok
    cancel := ui.new_button(g_adduser, "取消", 270, 132, 90, 30)
    cancel.onClick = add_user_cancel
}

add_user_dialog :: proc(sender: rawptr, _: ^ui.EventArgs) {
    g_add_target = ui.wf_tag_ptr(ui.wf_tag_from_sender(sender))
    r := ui.show_modal(g_adduser)          // BLOCKS
    if r == 0 do ui.statusbar_set_text(sbar, 2, "已取消新建用户")
}


// -----------------------------------------------------------------------------
// "Components" modal: a component-rich window hosting almost every control,
// with its OWN Flex_Host. Replaces Zig's showDialog(.build/.collect).
// -----------------------------------------------------------------------------
component_ok :: proc(_: rawptr, _: ^ui.EventArgs) {
    name := ui.control_get_text(g_comp_name.control)
    ui.close_modal(g_components, 1)
    ui.statusbar_set_text(sbar, 2, cat("组件演示：确认，姓名=", name))
}
component_cancel :: proc(_: rawptr, _: ^ui.EventArgs) {
    ui.close_modal(g_components, 0)
}

build_components_modal :: proc() {
    // ------------------------------------------------------------------
    // ONE coordinate system for the WHOLE dialog.
    //
    // The v2.7 version registered only 5 controls (gb / lb / lv / ctv /
    // ctab) in a flex tree and left ~20 others at hard-coded x,y. Because
    // modal_set_flex_host() makes show_modal() call flex_host_apply(), those
    // 5 were re-positioned while the rest stayed put -> the inner TabControl
    // landed ON TOP of row 3 (progress / slider / Gradient / Flat), its page
    // panels never followed the strip, a big blank band appeared, and the
    // OK/Cancel pair stayed at absolute y=500 glued to the client bottom.
    // That is exactly what the two red boxes showed.
    //
    // Now EVERY control is a leaf/container in one tree. Constructors still
    // take 0,0 as a placeholder (the library signatures require x,y); only
    // flex_host_apply() decides positions. Fixed_Dialog cannot be resized,
    // but keeping one system avoids any chance of the two drifting apart.
    // ------------------------------------------------------------------
    g_components = ui.new_modal_form(frm, "组件演示 — 模态窗口", 580, 600)
    d := g_components

    // ---- row 1: fields + GroupBox ----
    cap := ui.new_label(d, "姓名 / 部门 / 时间", 0, 0, 210, 20)
    g_comp_name = ui.new_textbox(d, 0, 0, 210, 26)
    g_comp_dept = ui.new_combobox(d, 0, 0, 210, 26, .Tb_Combo)
    ui.combo_add_items(g_comp_dept, "研发", "测试", "产品", "运维")
    ui.set_property(g_comp_dept, ui.ComboProps.Selected_Index, 0)
    dtp := ui.new_datetimepicker(d, 0, 0, 210, 26)
    ui.wf_datetimepicker_set_time_only(dtp)

    gb := ui.new_groupbox(d, "选项 (GroupBox)", 0, 0, 310, 136)
    chk := ui.new_checkbox(gb, "启用日志", 0, 0)
    rdo := ui.new_radiobutton(gb, "高优先级", 0, 0, 180, 24)
    ui.control_set_forecolor(rdo, uint(0xd90429))
    np := ui.new_numberpicker(gb, 0, 0, 90, 26, deciPrec = 2, step = 1.5)

    // ---- row 2: three collection controls ----
    lb := ui.new_listbox(d, 0, 0, 160, 110)
    ui.wf_listbox_enable_multi_select(lb)
    ui.listbox_add_items(lb, "Alice", "Bob", "Carol", "Dave")

    lv := ui.new_listview(d, 0, 0, 220, 110, "OS", "Kernel", 110, 100)
    ui.listview_add_row(lv, "Windows", "NT")
    ui.listview_add_row(lv, "Linux", "LTS")
    ui.listview_add_row(lv, "ReactOS", "NT-like")

    ctv := ui.new_treeview(d, 0, 0, 140, 110)
    ui.treeview_add_nodes(ctv, "Windows", "MacOS", "Linux")

    // ---- row 3: progress / slider / styled buttons ----
    cpg := ui.new_progressbar(d, 0, 0, 150, 24, perc = false)
    ui.progressbar_set_value(cpg, 65)
    ctk := ui.new_trackbar(d, 0, 0, 170, 28)
    // The library sets customDraw = true in tkb_ctor. In that mode
    // tkb_wnd_proc answers NM_CUSTOMDRAW with CDRF_SKIPDEFAULT and paints
    // ONLY the blue tic dots -- no channel, no thumb. That is the "thin
    // frame + row of dots" in the first red box. Turn it off here so
    // comctl32 draws the native track + slider. (The Home page keeps its
    // customDraw = true on purpose, as a demo of that feature.)
    ctk.customDraw = false
    grad := ui.new_button(d, "Gradient", 0, 0, 100, 28)
    ui.button_set_gradient_colors(grad, 0xfb8500, 0xffbe0b)
    flat := ui.new_button(d, "Flat", 0, 0, 90, 28)
    ui.set_property(flat, ui.CommonProps.Back_Color, 0x94d2bd)

    // ---- row 4: a TabControl INSIDE the modal dialog ----
    g_comp_ctab = ui.new_tabcontrol(d, 0, 0, 540, 26)
    p1 := ui.tabcontrol_add_page(g_comp_ctab, "Info")
    l1 := ui.new_label(p1, "Page 1 — Label + TextBox", 0, 0, 260, 20)
    box1 := ui.new_textbox(p1, 0, 0, 220, 26)
    p2 := ui.tabcontrol_add_page(g_comp_ctab, "Options")
    ck2 := ui.new_checkbox(p2, "Enable feature", 0, 0)
    rb2 := ui.new_radiobutton(p2, "Option B", 0, 0, 160, 24)
    btn2 := ui.new_button(p2, "Page 2 button", 0, 0, 140, 28)
    btn2.onClick = view_action

    ok := ui.new_button(d, "OK", 0, 0, 90, 30)
    ok.onClick = component_ok
    cancel := ui.new_button(d, "Cancel", 0, 0, 90, 30)
    cancel.onClick = component_cancel

    // ---- ONE flex tree for all 25 controls ---------------------------
    ui.flex_host_init(&g_comp_flex, d)
    ui.flex_host_box(&g_comp_flex, ui.Flex_Style{
        direction = .Column, gap = 8,
        padding = ui.flex_edges_all(10), align_items = .Stretch,
    })

    // row 1: left fields | GroupBox
    ui.flex_host_box(&g_comp_flex, ui.Flex_Style{
        direction = .Row, gap = 8, height = ui.flex_px(136), align_items = .Stretch,
    })
    ui.flex_host_box(&g_comp_flex, ui.Flex_Style{
        direction = .Column, gap = 6, width = ui.flex_px(210),
    })
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) cap,
                      ui.Flex_Style{width = ui.flex_px(210), height = ui.flex_px(20)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) g_comp_name,
                      ui.Flex_Style{width = ui.flex_px(210), height = ui.flex_px(26)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) g_comp_dept,
                      ui.Flex_Style{width = ui.flex_px(210), height = ui.flex_px(26)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) dtp,
                      ui.Flex_Style{width = ui.flex_px(210), height = ui.flex_px(26)})
    ui.flex_host_close(&g_comp_flex)                       // left column

    ui.flex_host_container(&g_comp_flex, cast(^ui.Control) gb, ui.Flex_Style{
        direction = .Column, gap = 6, grow = 1,
        height = ui.flex_px(136),
        padding = ui.Flex_Edges{22, 8, 8, 10}, align_items = .Stretch,
    })
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) chk,
                      ui.Flex_Style{width = ui.flex_fill(), height = ui.flex_px(24)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) rdo,
                      ui.Flex_Style{width = ui.flex_fill(), height = ui.flex_px(24)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) np,
                      ui.Flex_Style{width = ui.flex_px(90), height = ui.flex_px(26)})
    ui.flex_host_close(&g_comp_flex)                       // GroupBox
    ui.flex_host_close(&g_comp_flex)                       // row 1

    // row 2: ListBox | ListView | TreeView
    ui.flex_host_box(&g_comp_flex, ui.Flex_Style{
        direction = .Row, gap = 8, height = ui.flex_px(110),
    })
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) lb,
                      ui.Flex_Style{width = ui.flex_px(160), height = ui.flex_px(110)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) lv,
                      ui.Flex_Style{width = ui.flex_px(220), height = ui.flex_px(110)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) ctv,
                      ui.Flex_Style{width = ui.flex_px(140), height = ui.flex_px(110)})
    ui.flex_host_close(&g_comp_flex)                       // row 2

    // row 3: progress / native slider / gradient / flat
    ui.flex_host_box(&g_comp_flex, ui.Flex_Style{
        direction = .Row, gap = 8, height = ui.flex_px(30), align_items = .Center,
    })
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) cpg,
                      ui.Flex_Style{width = ui.flex_px(150), height = ui.flex_px(24)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) ctk,
                      ui.Flex_Style{width = ui.flex_px(170), height = ui.flex_px(28)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) grad,
                      ui.Flex_Style{width = ui.flex_px(100), height = ui.flex_px(28)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) flat,
                      ui.Flex_Style{width = ui.flex_px(90), height = ui.flex_px(28)})
    ui.flex_host_close(&g_comp_flex)                       // row 3

    // row 4 workspace: the strip owns ONLY its own height; the two pages
    // are ABSOLUTE boxes stacked exactly below it (same shape as Home).
    ui.flex_host_box(&g_comp_flex, ui.Flex_Style{
        direction = .Column, gap = 0, height = ui.flex_px(180),
        align_items = .Stretch,
    })
    g_comp_tab_box = ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) g_comp_ctab,
                      ui.Flex_Style{width = ui.flex_fill(), height = ui.flex_px(26)})

    ui.flex_host_container(&g_comp_flex, cast(^ui.Control) p1, ui.Flex_Style{
        absolute = true, offset_y = 26,
        width = ui.flex_fill(), height = ui.flex_fill(),
        direction = .Column, gap = 4, padding = ui.flex_edges_all(6),
    })
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) l1,
                      ui.Flex_Style{width = ui.flex_px(260), height = ui.flex_px(20)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) box1,
                      ui.Flex_Style{width = ui.flex_px(220), height = ui.flex_px(26)})
    ui.flex_host_close(&g_comp_flex)                       // page 1

    ui.flex_host_container(&g_comp_flex, cast(^ui.Control) p2, ui.Flex_Style{
        absolute = true, offset_y = 26,
        width = ui.flex_fill(), height = ui.flex_fill(),
        direction = .Column, gap = 4, padding = ui.flex_edges_all(6),
    })
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) ck2,
                      ui.Flex_Style{width = ui.flex_px(160), height = ui.flex_px(24)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) rb2,
                      ui.Flex_Style{width = ui.flex_px(160), height = ui.flex_px(24)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) btn2,
                      ui.Flex_Style{width = ui.flex_px(140), height = ui.flex_px(28)})
    ui.flex_host_close(&g_comp_flex)                       // page 2
    ui.flex_host_close(&g_comp_flex)                       // workspace

    // footer: a spacer pushes OK / Cancel to the right, on their OWN row.
    // No more absolute y=500 glued to the client bottom.
    ui.flex_host_box(&g_comp_flex, ui.Flex_Style{
        direction = .Row, gap = 8, height = ui.flex_px(36), align_items = .Center,
    })
    ui.flex_host_spacer(&g_comp_flex, ui.Flex_Style{grow = 1})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) ok,
                      ui.Flex_Style{width = ui.flex_px(90), height = ui.flex_px(30)})
    ui.flex_host_leaf(&g_comp_flex, cast(^ui.Control) cancel,
                      ui.Flex_Style{width = ui.flex_px(90), height = ui.flex_px(30)})
    ui.flex_host_close(&g_comp_flex)                       // footer
    ui.flex_host_close(&g_comp_flex)                       // root

    // WM_SHOWWINDOW -> frm.onLoad fires INSIDE ShowWindow(), i.e. BEFORE
    // show_modal()'s own flex_host_apply(). Use it to replace the guessed
    // 26px strip with the REAL TCM_ADJUSTRECT height on every absolute page
    // box and on the strip leaf, then lay out once. show_modal() applies
    // again immediately afterwards; flex_host_apply() is idempotent.
    d.onLoad = proc(sender: rawptr, ea: ^ui.EventArgs) {
        strip := f32(ui.tabcontrol_strip_height(g_comp_ctab))
        for i in 0..<len(g_comp_flex.tree.boxes) {
            if g_comp_flex.tree.boxes[i].style.absolute {
                g_comp_flex.tree.boxes[i].style.offset_y = strip
            }
        }
        if g_comp_tab_box >= 0 {
            g_comp_flex.tree.boxes[g_comp_tab_box].style.height = ui.flex_px(strip)
        }
        ui.tabcontrol_set_selected(g_comp_ctab, 0)   // only ShowWindow, never MoveWindow
        ui.flex_host_apply(&g_comp_flex)
    }

    ui.modal_set_flex_host(d, &g_comp_flex)
}


open_components_dialog :: proc() {
    ui.statusbar_set_text(sbar, 2, "打开组件演示模态窗...")
    r := ui.show_modal(g_components)       // BLOCKS
    if r == 0 do ui.statusbar_set_text(sbar, 2, "组件演示：已取消")
}


// -----------------------------------------------------------------------------
// Big Data button commands
// -----------------------------------------------------------------------------
big_data_button :: proc(sender: rawptr, _: ^ui.EventArgs) {
    c := ui.wf_tag_from_sender(sender)
    vl := cast(^ui.ListView) ui.wf_tag_ptr(c)
    if vl == nil do return
    switch ui.wf_tag_int(c) {
    case 0:
        ui.wf_virtual_ensure_visible(vl, 50_000)
        ui.statusbar_set_text(sbar, 2, "jumped to row 50000 of 100000")
    case 1:
        big_rows += 10_000
        ui.wf_virtual_set_row_count(vl, big_rows)
        ui.statusbar_set_text(sbar, 2, cat("rows=", i2s(big_rows)))
    case 2:
        big_seed += 1
        ui.wf_virtual_refresh(vl)
        ui.statusbar_set_text(sbar, 2, "data refreshed")
    case 3:
        sel := ui.wf_virtual_get_selected_row(vl)
        top := ui.wf_virtual_get_top_index(vl)
        ui.statusbar_set_text(sbar, 2, cat("selected row = ", i2s(sel)))
        ptf("BigData: selected row %d, visible from %d\n", sel, top)
    }
}

users_select_all :: proc(sender: rawptr, _: ^ui.EventArgs) {
    c := ui.wf_tag_from_sender(sender)
    lbx := cast(^ui.ListBox) ui.wf_tag_ptr(c)
    if lbx == nil do return
    ui.listbox_select_all(lbx)
    ui.statusbar_set_text(sbar, 2, "Users: selected all")
}


// -----------------------------------------------------------------------------
// Runtime control creation. The stock library only builds HWNDs ONCE, inside
// start_mainloop() -> create_child_handles(). Controls created later must be
// built explicitly, in the order they were appended to frm._controls
// (containers BEFORE their children).
// -----------------------------------------------------------------------------
build_runtime_hwnds :: proc(start_at: int) {
    // Odin proc parameters are CONST -- copy into a local before clamping.
    from := start_at
    if from < 0 do from = 0
    for i in from..<len(frm._controls) {
        c := frm._controls[i]
        if c.handle == nil {
            c._createHandleProc(c)
        }
    }
}

home_page_style :: proc() -> ui.Flex_Style {
    return ui.Flex_Style{
        absolute = true, offset_y = tab_strip,
        width = ui.flex_fill(), height = ui.flex_fill(),
        direction = .Row, gap = 10,
        padding = ui.flex_edges_all(8), align_items = .Stretch,
    }
}

view_page_style :: proc() -> ui.Flex_Style {
    return ui.Flex_Style{
        absolute = true, offset_y = tab_strip,
        width = ui.flex_fill(), height = ui.flex_fill(),
        direction = .Column, gap = 8,
        padding = ui.flex_edges_all(10),
    }
}

view_label :: proc(page: ^ui.TabPage, txt: string, w: i32) -> ^ui.Label {
    return ui.new_label(page, txt, 0, 0, w, 24)
}


// -----------------------------------------------------------------------------
// Fill a newly created tab page with the interface for `view`. Every control
// is created at (0,0) as a placeholder; flex_host_apply() supplies the real
// position. Children MUST be appended via flex_host_leaf_at(page_box, ...).
// -----------------------------------------------------------------------------
build_view_content :: proc(view: i32, page: ^ui.TabPage, box: int, seq: i32) {
    h := view_label(page, cat(nav_titles[int(view)], " view #", i2s(seq)), 300)
    ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) h,
                         ui.Flex_Style{width = ui.flex_px(300), height = ui.flex_px(26)})
    d := view_label(page, "This tab was created at runtime by the navbar.", 380)
    ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) d,
                         ui.Flex_Style{width = ui.flex_px(380), height = ui.flex_px(24)})

    switch view {
    case 0:     // Dashboard: progress + action
        bar := ui.new_progressbar(page, 0, 0, 260, 24, perc = false)
        ui.progressbar_set_value(bar, 65)
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) bar,
                             ui.Flex_Style{width = ui.flex_px(260), height = ui.flex_px(24)})
        b := ui.new_button(page, "Refresh", 0, 0, 120, 30)
        b.onClick = view_action
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) b,
                             ui.Flex_Style{width = ui.flex_px(120), height = ui.flex_px(30)})

    case 1:     // Widgets: combo + action
        c := ui.new_combobox(page, 0, 0, 180, 26, .Tb_Combo)
        ui.combo_add_items(c, "Button", "Label", "ListView", "TrackBar")
        ui.set_property(c, ui.ComboProps.Selected_Index, 0)
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) c,
                             ui.Flex_Style{width = ui.flex_px(180), height = ui.flex_px(26)})
        b := ui.new_button(page, "Add widget", 0, 0, 140, 30)
        b.onClick = view_action
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) b,
                             ui.Flex_Style{width = ui.flex_px(140), height = ui.flex_px(30)})

    case 2:     // Users: multi-select ListBox + select-all + add-user modal
        l := ui.new_listbox(page, 0, 0, 180, 110)
        ui.wf_listbox_enable_multi_select(l)
        ui.listbox_add_items(l, "Alice", "Bob", "Carol", "Dave")
        l.onSelectionChanged = listbox_changed
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) l,
                             ui.Flex_Style{width = ui.flex_px(180), height = ui.flex_px(110)})
        b := ui.new_button(page, "Select all", 0, 0, 140, 30)
        b.onClick = users_select_all
        ui.wf_tag_set(cast(^ui.Control) b, l, 0)
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) b,
                             ui.Flex_Style{width = ui.flex_px(140), height = ui.flex_px(30)})
        add := ui.new_button(page, "Add user...", 0, 0, 140, 30)
        add.onClick = add_user_dialog
        ui.wf_tag_set(cast(^ui.Control) add, l, 0)
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) add,
                             ui.Flex_Style{width = ui.flex_px(140), height = ui.flex_px(30)})

    case 3:     // Settings: check + radio + action
        ck := ui.new_checkbox(page, "Enable logging", 0, 0)
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) ck,
                             ui.Flex_Style{width = ui.flex_px(180), height = ui.flex_px(24)})
        rb := ui.new_radiobutton(page, "Dark theme", 0, 0, 180, 24)
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) rb,
                             ui.Flex_Style{width = ui.flex_px(180), height = ui.flex_px(24)})
        b := ui.new_button(page, "Save", 0, 0, 120, 30)
        b.onClick = view_action
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) b,
                             ui.Flex_Style{width = ui.flex_px(120), height = ui.flex_px(30)})

    case 4:     // About: text + picture
        t := ui.new_textbox(page, 0, 0, 300, 26)
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) t,
                             ui.Flex_Style{width = ui.flex_px(300), height = ui.flex_px(26)})
        p := ui.wf_new_picturebox(cast(^ui.Control) page, 0, 0, 270, 140,
                                  "gbil.jpg", .Stretch)
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) p,
                             ui.Flex_Style{width = ui.flex_px(270), height = ui.flex_px(140)})

    case 5:     // Big Data: 100 000 rows, ZERO storage
        info := view_label(page, "Virtual list: 100000 rows, cells generated on demand.", 420)
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) info,
                             ui.Flex_Style{width = ui.flex_px(420), height = ui.flex_px(22)})
        vl := ui.new_virtual_listview(
            cast(^ui.Control) page, 0, 0, 420, 300,
            []string{"ID", "Name", "Size", "State"},
            []int{110, 150, 100, 90},
            big_rows, big_data_cell)
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) vl,
                             ui.Flex_Style{width = ui.flex_px(420), height = ui.flex_px(300)})
        actions := ui.flex_host_box_at(&g_flex, box, ui.Flex_Style{
            direction = .Row, gap = 8, height = ui.flex_px(28),
        })
        cmds := [?]string{"Jump to 50000", "+10000 rows", "Refresh data", "Show selection"}
        for txt, ci in cmds {
            b := ui.new_button(page, txt, 0, 0, 130, 28)
            b.onClick = big_data_button
            ui.wf_tag_set(cast(^ui.Control) b, vl, i32(ci))
            ui.flex_host_leaf_at(&g_flex, actions, cast(^ui.Control) b,
                                 ui.Flex_Style{width = ui.flex_px(130), height = ui.flex_px(28)})
        }

    case 7:     // Panel: a real WS_CHILD container with a flex sub-tree
        pi := view_label(page, "Panel = custom HWND container; children use it as parent.", 420)
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) pi,
                             ui.Flex_Style{width = ui.flex_px(420), height = ui.flex_px(22)})
        pn := ui.new_panel(cast(^ui.Control) page, 0, 0, 420, 170, .Single)
        pb := ui.flex_host_container_at(&g_flex, box, cast(^ui.Control) pn, ui.Flex_Style{
            direction = .Column, gap = 8,
            padding = ui.flex_edges_all(12),
            width = ui.flex_px(420), height = ui.flex_px(170),
        })
        lbl := ui.new_label(pn, "Label inside the panel", 0, 0, 300, 20)
        ui.flex_host_leaf_at(&g_flex, pb, cast(^ui.Control) lbl,
                             ui.Flex_Style{width = ui.flex_px(300), height = ui.flex_px(20)})
        ed := ui.new_textbox(pn, 0, 0, 260, 26)
        ui.flex_host_leaf_at(&g_flex, pb, cast(^ui.Control) ed,
                             ui.Flex_Style{width = ui.flex_px(260), height = ui.flex_px(26)})
        btn := ui.new_button(pn, "Button inside panel", 0, 0, 170, 28)
        btn.onClick = view_action
        ui.flex_host_leaf_at(&g_flex, pb, cast(^ui.Control) btn,
                             ui.Flex_Style{width = ui.flex_px(170), height = ui.flex_px(28)})
        ck := ui.new_checkbox(pn, "Check inside panel", 0, 0)
        ui.flex_host_leaf_at(&g_flex, pb, cast(^ui.Control) ck,
                             ui.Flex_Style{width = ui.flex_px(180), height = ui.flex_px(24)})
        pn2 := ui.new_panel(cast(^ui.Control) page, 0, 0, 420, 80, .Sunken)
        pb2 := ui.flex_host_container_at(&g_flex, box, cast(^ui.Control) pn2, ui.Flex_Style{
            direction = .Row, gap = 10,
            padding = ui.flex_edges_all(12),
            width = ui.flex_px(420), height = ui.flex_px(80),
        })
        l2 := ui.new_label(pn2, "Sunken panel:", 0, 0, 120, 20)
        ui.flex_host_leaf_at(&g_flex, pb2, cast(^ui.Control) l2,
                             ui.Flex_Style{width = ui.flex_px(120), height = ui.flex_px(20)})
        r2 := ui.new_radiobutton(pn2, "option A", 0, 0, 140, 24)
        ui.control_set_forecolor(r2, uint(0xd90429))
        ui.flex_host_leaf_at(&g_flex, pb2, cast(^ui.Control) r2,
                             ui.Flex_Style{width = ui.flex_px(140), height = ui.flex_px(24)})

    case:
        b := ui.new_button(page, "OK", 0, 0, 100, 30)
        b.onClick = view_action
        ui.flex_host_leaf_at(&g_flex, box, cast(^ui.Control) b,
                             ui.Flex_Style{width = ui.flex_px(100), height = ui.flex_px(30)})
    }
}


nav_click :: proc(sender: rawptr, _: ^ui.EventArgs) {
    c := ui.wf_tag_from_sender(sender)
    v := ui.wf_tag_int(c)
    if v == 6 {
        open_components_dialog()
        return
    }
    open_view_by_index(v)
}

open_view_by_index :: proc(view: i32) {
    if view < 0 || view >= i32(len(nav_titles)) do return
    if ui.tabcontrol_page_count(tabc) >= 16 {
        ui.statusbar_set_text(sbar, 2, "tab limit reached (16 pages)")
        return
    }
    view_seq += 1
    title := cat(nav_titles[int(view)], " #", i32_to_str(view_seq))

    start := len(frm._controls)
    page := ui.tabcontrol_add_page(tabc, title)
    page_box := ui.flex_host_container_at(&g_flex, workspace_box,
                                          cast(^ui.Control) page, view_page_style())
    if page_box < 0 do return
    ui.wf_tag_set(cast(^ui.Control) page, nil, i32(page_box))

    build_view_content(view, page, page_box, view_seq)
    // HWNDs for ALL controls appended since `start`, containers first.
    build_runtime_hwnds(start)
    // Virtual lists created at runtime were not alive during onLoad.
    ui.wf_virtual_init_all()

    idx := i32(ui.tabcontrol_page_count(tabc)) - 1
    ui.tabcontrol_set_selected(tabc, idx)
    ui.flex_host_apply(&g_flex)
    ui.statusbar_set_text(sbar, 1, title)
    ui.statusbar_set_text(sbar, 2, cat("tabs=", i2s(idx + 1), " | ", title))
    ptf("opened view %d: '%s' -> tab %d\n", view, title, idx)
}

// Small alias so the call site above reads naturally.
i32_to_str :: proc(v: i32) -> string { return i2s(v) }


// -----------------------------------------------------------------------------
// Main window
// -----------------------------------------------------------------------------
MakeWindow :: proc()
{
    using ui

    frm = new_form(txt = "Odin is fun")
    frm.width = 1100
    frm.height = 660
    frm.font = new_font("Tahoma", 13)
    print_points(frm)
    frm.start_pos = .Center
    frm.onClick = frm_click_proc

    // ---- Tray icon + context menu ----
    ti = new_tray_icon("Winforms tray icon!", "winforms-icon.ico")
    tray_add_context_menu(ti, false, .Any_Click, "Windows", "|", "Linux", "ReactOS")
    ti.contextMenu.menus[0].onClick = on_windows_menu

    // ---- 400 ms timer (started in onLoad, once the HWND exists) ----
    tmr = form_addTimer(frm, 400, timer_on_tick)

    // ---- Menu bar with two levels of submenus ----
    mbar := new_menubar(frm, false, "File", "Edit", "Format")
    menubar_add_items(mbar, mbar.menus[0], "New Work", "New Client", "|", "Exit")
    menubar_add_items(mbar, mbar.menus[1], "New Client", "Copy", "Delete")
    menubar_add_items(mbar, mbar.menus[2], "Font", "Line Space", "Para Spce")
    menubar_add_items(mbar, mbar.menus[0].menus[0],
                      "Contract Work", "Carriage Work", "Transmission Work")
    mbar.menus[0].menus[1].onClick = new_client_menu_click
    mbar.menus[0].menus[1].menuState = .Checked

    // ---- 1. Top bar ----
    b1 := new_button(frm, "Normal", 0, 0, 110, 35)
    b1.onClick = open_file_proc
    b2 := new_button(frm, "Flat Color", 0, 0, 120, 35)
    set_property(b2, CommonProps.Back_Color, 0x94d2bd)
    b2.onClick = b2_click_proc
    b3 := new_button(frm, "Gradient", 0, 0, 110, 35)
    button_set_gradient_colors(b3, 0xfb8500, 0xffbe0b)

    cmb = new_combobox(frm, 0, 0, 140, 26, .Tb_Combo)
    combo_add_items(cmb, "Windows", "MacOS", "Linux", "ReactOS")
    set_property(cmb, ComboProps.Selected_Index, 0)

    dtp := new_datetimepicker(frm, 0, 0, 160, 26)
    wf_datetimepicker_set_time_only(dtp)

    // ---- 2. Left navbar ----
    nav_head := new_label(frm, "NAVIGATION", 0, 0, 130, 24)
    nav_buttons : [dynamic]^Button
    for name, i in nav_titles {
        nb := new_button(frm, name, 0, 0, 130, 32)
        wf_tag_set(cast(^Control) nb, nil, i32(i))
        nb.onClick = nav_click
        append(&nav_buttons, nb)
    }

    // ---- 3. Splitter (flex mode: ONE relayout on mouse-up) ----
    split_bar = new_splitter(frm, 0, 0, 6, 40, .Vertical)
    splitter_set_range(split_bar, 120, 340)
    splitter_set_position(split_bar, 150)
    splitter_set_live(split_bar, false)
    split_bar.onPositionChanged = split_moved

    // ---- 4. Workspace: ONE TabControl + overlapping page panels ----
    tabc = new_tabcontrol(frm, 0, 0, 800, 26)
    tabc.onSelectedIndexChanged = tab_changed
    tabc.onBeforeClose = tab_confirm_close
    tabc.onPageClosing = tab_page_closing
    home := tabcontrol_add_page(tabc, "Home")

    // ---- Home page: ALL original demo widgets ----
    gb := new_groupbox(home, "Format Options1", 0, 0, 230, 110)
    gb.style = GroupBoxStyle.Overriden
    gb.lineColor = 0x0000ff
    lb_line := new_label(gb, "Line_Space", 0, 0, 90, 24)
    rb_show := new_radiobutton(gb, "Show Timings", 0, 0, 180, 24)
    np1 = new_numberpicker(gb, 0, 0, 100, 27, deciPrec = 2, step = 1.5)
    np1.backColor = 0xddAA45

    gb2 := new_groupbox(home, "Compiler Options", 0, 0, 210, 200)
    cb2 := new_checkbox(gb2, "No Entry Point", 0, 0)
    // Keep BOTH radios THEMED (v6 large hollow circle). Do NOT recolour only
    // one: setForeColor() strips the theme and switches to the classic dot.
    rb1 := new_radiobutton(gb2, "SubSystem:Windows", 0, 0, 180, 24)
    rb2 := new_radiobutton(gb2, "SubSystem:Console", 0, 0, 180, 24)
    lb2 = new_label(gb2, "Threads:", 0, 0, 70, 24)
    np2 := new_numberpicker(gb2, 0, 0, 80, 27, btnLeft = true)
    np2.backColor = 0xcaffbf
    np2.textAlignment = .Center
    set_property(cb2, CheckBoxProps.Checked, true)

    lbx := new_listbox(home, 0, 0, 150, 150)
    wf_listbox_enable_multi_select(lbx)
    listbox_add_items(lbx, "Windows", "MacOS", "Linux", "ReactOS")
    lbx.onSelectionChanged = listbox_changed
    listbox_set_items_selected(lbx, true, 0)

    lv := new_listview(home, 0, 0, 340, 150,
                       "Windows", "MacOS", "Linux", 100, 120, 100)
    listview_add_row(lv, "XP", "Mountain Lion", "RedHat")
    listview_add_row(lv, "Vista", "Mavericks", "Mint")
    listview_add_row(lv, "Win7", "Mavericks", "Ubuntu")
    listview_add_row(lv, "Win8", "Catalina", "Debian")
    listview_add_row(lv, "Win10", " Big Sur", "Kali")
    // Classic-list check boxes are BUILT INTO the stock library.
    lv.hasCheckBoxes = true
    lv.onItemCheckChanged = listview_check_changed
    control_add_contextmenu(lv, false, "Compile", "Link Only", "|", "Make Console")
    lv.contextMenu.menus[0].onClick = context_menu_click
    lv.contextMenu.menus[0].menuState = MenuState.Checked
    // Tier-1 patch: click a header -> sort + " ^" / " v" marker.
    lv.onColumnClick = on_column_click

    tb = new_textbox(home, 0, 0, 260, 26)
    pbx := wf_new_picturebox(cast(^Control) home, 0, 0, 270, 140,
                             "gbil.jpg", .Stretch)

    pgb = new_progressbar(home, 0, 0, 200, 30, perc = true)
    tk = new_trackbar(home, 0, 0, 200, 40)
    tk.customDraw = true
    tk.onValueChanged = track_change

    tv = new_treeview(home, 0, 0, 250, 220)
    treeview_add_nodes(tv, "Windows", "MacOS", "Linux", "ReactOS")
    treeview_add_childnodes(tv, 0, "XP", "Vista", "Win7", "Win8", "Win10", "Win11")
    treeview_add_childnodes(tv, 1, "Mountain Lion", "Mavericks", "Catalina", "Big Sur", "Monterey")
    treeview_add_childnodes(tv, 2, "RedHat", "Mint", "Ubuntu", "Debian", "Kali")
    treeview_add_node_with_children(tv, "BSD", "VersionA", "VersionB", "VersionC")
    tv.onBeforeCollapse = tv_event_test
    tv.editable = true

    cal := new_calendar(home, 0, 0)

    ctrl_set_mouse_enter_handler(np1, on_mouse_enter)
    ctrl_set_mouse_leave_handler(np1, on_mouse_leave)
    ctrl_set_mouse_hover_handler(np1, on_mouse_hover)

    // ---- 5. StatusBar ----
    sbar = new_statusbar(frm, 0, 0, 800, 24)
    statusbar_set_parts(sbar, []i32{160, 320, -1})
    statusbar_set_text(sbar, 0, "Ready")
    statusbar_set_text(sbar, 1, "Home")
    statusbar_set_text(sbar, 2, "click a navbar button to open a view")

    // ---- 6. Modal windows (built now, HWNDs created on first show) ----
    build_add_user_modal()
    build_components_modal()

    // ---- 7. Flex tree ----
    flex_host_init(&g_flex, frm)

    flex_host_box(&g_flex, Flex_Style{
        direction = .Column, gap = 10,
        padding = Flex_Edges{10, 10, 0, 10}, align_items = .Stretch,
    })

    // top bar
    flex_host_box(&g_flex, Flex_Style{
        direction = .Row, gap = 20, height = flex_px(35), align_items = .Center,
    })
    flex_host_leaf(&g_flex, cast(^Control) b1, Flex_Style{width = flex_px(110), height = flex_px(35)})
    flex_host_leaf(&g_flex, cast(^Control) b2, Flex_Style{width = flex_px(120), height = flex_px(35)})
    flex_host_leaf(&g_flex, cast(^Control) b3, Flex_Style{width = flex_px(110), height = flex_px(35)})
    flex_host_leaf(&g_flex, cast(^Control) cmb, Flex_Style{width = flex_px(140), height = flex_px(26)})
    flex_host_leaf(&g_flex, cast(^Control) dtp, Flex_Style{width = flex_px(160), height = flex_px(26)})
    flex_host_close(&g_flex)

    // main row: navbar | splitter | workspace
    flex_host_box(&g_flex, Flex_Style{
        direction = .Row, gap = 10, grow = 1, align_items = .Stretch,
    })
    navbar_box = flex_host_box(&g_flex, Flex_Style{
        direction = .Column, gap = 6, width = flex_px(150),
        padding = Flex_Edges{6, 8, 6, 8}, align_items = .Stretch,
    })
    flex_host_leaf(&g_flex, cast(^Control) nav_head,
                   Flex_Style{width = flex_px(130), height = flex_px(24)})
    for nb in nav_buttons {
        flex_host_leaf(&g_flex, cast(^Control) nb,
                       Flex_Style{height = flex_px(32)})
    }
    flex_host_close(&g_flex)                       // navbar

    flex_host_leaf(&g_flex, cast(^Control) split_bar,
                   Flex_Style{width = flex_px(6)})

    workspace_box = flex_host_box(&g_flex, Flex_Style{
        direction = .Column, gap = 0, grow = 1, align_items = .Stretch,
    })
    flex_host_leaf(&g_flex, cast(^Control) tabc,
                   Flex_Style{height = flex_px(tab_strip)})

    home_box := flex_host_container(&g_flex, cast(^Control) home, home_page_style())
    wf_tag_set(cast(^Control) home, nil, i32(home_box))

    // left column: GroupBoxes
    flex_host_box(&g_flex, Flex_Style{
        direction = .Column, gap = 10, width = flex_px(230),
    })
    flex_host_container(&g_flex, cast(^Control) gb, Flex_Style{
        direction = .Column, gap = 6,
        width = flex_px(230), height = flex_px(110),
        padding = Flex_Edges{24, 8, 8, 12},
    })
    flex_host_box(&g_flex, Flex_Style{direction = .Row, gap = 8, align_items = .Center})
    flex_host_leaf(&g_flex, cast(^Control) lb_line,
                   Flex_Style{width = flex_px(90), height = flex_px(24)})
    flex_host_leaf(&g_flex, cast(^Control) np1,
                   Flex_Style{width = flex_px(100), height = flex_px(27)})
    flex_host_close(&g_flex)
    flex_host_leaf(&g_flex, cast(^Control) rb_show,
                   Flex_Style{height = flex_px(24)})
    flex_host_close(&g_flex)                       // gb

    flex_host_container(&g_flex, cast(^Control) gb2, Flex_Style{
        direction = .Column, gap = 6,
        width = flex_px(210), height = flex_px(200),
        padding = Flex_Edges{24, 8, 8, 12},
    })
    flex_host_leaf(&g_flex, cast(^Control) cb2,
                   Flex_Style{width = flex_px(180), height = flex_px(24)})
    flex_host_leaf(&g_flex, cast(^Control) rb1,  Flex_Style{height = flex_px(24)})
    flex_host_leaf(&g_flex, cast(^Control) rb2,  Flex_Style{height = flex_px(24)})
    flex_host_box(&g_flex, Flex_Style{direction = .Row, gap = 8, align_items = .Center})
    flex_host_leaf(&g_flex, cast(^Control) lb2,
                   Flex_Style{width = flex_px(70), height = flex_px(24)})
    flex_host_leaf(&g_flex, cast(^Control) np2,
                   Flex_Style{width = flex_px(80), height = flex_px(27)})
    flex_host_close(&g_flex)
    flex_host_close(&g_flex)                       // gb2
    flex_host_close(&g_flex)                       // leftCol

    // centre column
    flex_host_box(&g_flex, Flex_Style{
        direction = .Column, gap = 10, grow = 1,
    })
    flex_host_box(&g_flex, Flex_Style{direction = .Row, gap = 10})
    flex_host_leaf(&g_flex, cast(^Control) lbx,
                   Flex_Style{width = flex_px(150), height = flex_px(150)})
    flex_host_leaf(&g_flex, cast(^Control) lv,
                   Flex_Style{width = flex_px(340), height = flex_px(150)})
    flex_host_close(&g_flex)
    flex_host_leaf(&g_flex, cast(^Control) tb,
                   Flex_Style{width = flex_px(300), height = flex_px(26)})
    flex_host_leaf(&g_flex, cast(^Control) pbx,
                   Flex_Style{width = flex_px(270), height = flex_px(140)})
    flex_host_leaf(&g_flex, cast(^Control) pgb,
                   Flex_Style{width = flex_px(340), height = flex_px(30)})
    flex_host_leaf(&g_flex, cast(^Control) tk,
                   Flex_Style{width = flex_px(200), height = flex_px(40)})
    flex_host_close(&g_flex)                       // centerCol

    // right column
    flex_host_box(&g_flex, Flex_Style{
        direction = .Column, gap = 10, width = flex_px(250),
    })
    flex_host_leaf(&g_flex, cast(^Control) tv,
                   Flex_Style{width = flex_px(250), height = flex_px(220)})
    flex_host_leaf(&g_flex, cast(^Control) cal,
                   Flex_Style{width = flex_px(250), height = flex_px(180)})
    flex_host_close(&g_flex)                       // rightCol

    flex_host_close(&g_flex)                       // home page
    flex_host_close(&g_flex)                       // workspace
    flex_host_close(&g_flex)                       // mainRow

    flex_host_leaf(&g_flex, cast(^Control) sbar,
                   Flex_Style{height = flex_px(24)})
    flex_host_close(&g_flex)                       // root

    // ---- 8. onLoad: all HWNDs exist ----
    frm.onLoad = proc(sender: rawptr, ea: ^ui.EventArgs) {
        using ui
        // TCM_ADJUSTRECT gives the REAL strip height (21..24px on v6), not 26.
        strip := f32(tabcontrol_strip_height(tabc))
        tab_strip = strip
        for i in 0..<len(g_flex.tree.boxes) {
            if g_flex.tree.boxes[i].style.absolute {
                g_flex.tree.boxes[i].style.offset_y = strip
            }
            if g_flex.controls[i] == cast(^Control) tabc {
                g_flex.tree.boxes[i].style.height = flex_px(strip)
            }
        }
        statusbar_set_parts(sbar, []i32{160, 320, -1})
        tabcontrol_layout_pages(tabc)
        tabcontrol_set_selected(tabc, 0)
        wf_virtual_init_all()
        timer_start(tmr)
        flex_host_apply(&g_flex)
        print("Ready. Click a navbar button to open a view.")
    }
    frm.onSizeChanged = proc(sender: rawptr, ea: ^ui.EventArgs) {
        ui.flex_host_apply(&g_flex)
    }

    start_mainloop(frm)
    flex_host_destroy(&g_comp_flex)
}


main :: proc()
{
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)
    context.user_index = 225
    defer mem.tracking_allocator_destroy(&track)
    MakeWindow()
    ui.show_memory_report(&track)
}
