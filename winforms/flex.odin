// =============================================================================
// flex.odin -- pure two-pass flexbox layout, ported from nanoui's layout.zig
// (MIT) via the Zig port in winforms-zig/src/flex.zig.
//
// This file has NO Win32 dependency: no HWND, no CreateWindow, no messages.
// It only computes rectangles. flex_bridge.odin turns them into SetWindowPos.
//
// WHAT IT KEEPS: measure() bottom-up + arrange() top-down, with grow / shrink
// (via grow) / justify / align_items / gap / padding / fill / min / max /
// absolute placement. All arithmetic is verbatim from layout.zig.
//
// WHAT WAS REMOVED (Win32 HWNDs draw themselves): measure()'s text path
// (glyph atlas / wrapping / lineHeight), motion/settle_y, scroll offsets,
// the "re-measure because width changed" pass, and hit-testing Context.
// A leaf's size comes from `intrinsic`, supplied by the bridge.
//
// UNITS: f32 PIXELS (not points). No DPI scaling is done; correct at 100%.
//
// ---------- ODIN PORTING NOTES ----------
// * Every name is prefixed (Flex_ / flex_ / FLEX_) so that adding this file
//   to package winforms cannot collide with the 620 existing top-level names,
//   nor pollute a `using ui` scope with generic verbs like add/end/layout.
// * Odin structs cannot have field defaults. `Flex_Style{}` is the default:
//   Direction's zero value is .Column, Len_Kind's is .Auto, Align/Justify's
//   are .Start, and max_width/max_height == 0 means "unbounded" (mapped to
//   FLEX_INF by flex_style_max_w/h at every read site).
// * Box index fields MUST be set to FLEX_NONE (-1) in flex_begin(); zero is a
//   valid box index and would make the root point at itself -> infinite loop.
// * flex_measure() returns nothing and writes b.measured; Odin has no
//   established "_ = f()" idiom in this codebase.
// * FLEX_AUTO / FLEX_FILL became procs (flex_auto() / flex_fill()) because
//   `Name :: Type{...}` compound-literal constants have no precedent here.
// * C-style `for init; cond; post` IS valid Odin (trackbar.odin:330 uses it).
// * The absolute-placement double-add of offset_x/offset_y is FIXED here.
//
// NOT COMPILED HERE: no Odin toolchain in the sandbox (release download is
// blocked). See README_FLEX.txt for the static checks and Python verification.
// =============================================================================

package winforms


// ---------- geometry ----------

Flex_Rect :: struct { x, y, w, h: f32 }
Flex_Size :: struct { w, h: f32 }

Flex_Edges :: struct { top, right, bottom, left: f32 }

flex_edges_all :: proc(v: f32) -> Flex_Edges { return Flex_Edges{v, v, v, v} }
flex_edges_xy  :: proc(x, y: f32) -> Flex_Edges { return Flex_Edges{y, x, y, x} }

flex_rect_inset :: proc(r: Flex_Rect, e: Flex_Edges) -> Flex_Rect {
    return Flex_Rect{
        x = r.x + e.left,
        y = r.y + e.top,
        w = flex_max(0, r.w - e.left - e.right),
        h = flex_max(0, r.h - e.top - e.bottom),
    }
}

flex_max :: proc(a, b: f32) -> f32 { return a > b ? a : b }
flex_min :: proc(a, b: f32) -> f32 { return a < b ? a : b }
flex_clamp :: proc(v, lo, hi: f32) -> f32 { return flex_max(lo, flex_min(v, flex_max(lo, hi))) }

FLEX_INF :: 3.0e38   // stand-in for inf(f32); safely below f32 max

// ---------- style (only the layout fields survive) ----------

// NOTE: Column first, so the zero value of Flex_Direction is the old default.
Flex_Direction :: enum { Column, Row }
Flex_Align     :: enum { Start, Center, End, Stretch }
Flex_Justify   :: enum { Start, Center, End, Space_Between }
Flex_Len_Kind  :: enum { Auto, Px, Fill }

Flex_Length :: struct {
    kind: Flex_Len_Kind,
    px:   f32,
}

flex_auto :: proc() -> Flex_Length { return Flex_Length{kind = .Auto, px = 0} }
flex_fill :: proc() -> Flex_Length { return Flex_Length{kind = .Fill, px = 0} }
flex_px   :: proc(v: f32) -> Flex_Length { return Flex_Length{kind = .Px, px = v} }

Flex_Style :: struct {
    direction:   Flex_Direction,
    gap:         f32,
    padding:     Flex_Edges,
    width:       Flex_Length,
    height:      Flex_Length,
    min_width:   f32,
    min_height:  f32,
    max_width:   f32,       // 0 == no limit (see flex_style_max_w)
    max_height:  f32,       // 0 == no limit (see flex_style_max_h)
    grow:        f32,
    align_items: Flex_Align,
    justify:     Flex_Justify,
    absolute:    bool,
    offset_x:    f32,       // equivalent of layout.zig's Style.offset.x (motion-free)
    offset_y:    f32,
}

// Optional explicit default; `Flex_Style{}` is equivalent and is fine to use.
flex_style_default :: proc() -> Flex_Style {
    return Flex_Style{
        direction  = .Column,
        padding    = Flex_Edges{},
        width      = flex_auto(),
        height     = flex_auto(),
        max_width  = FLEX_INF,
        max_height = FLEX_INF,
        align_items = .Start,
        justify     = .Start,
    }
}

// Zero means "unbounded", matching the old `= FLEX_INF` field default.
flex_style_max_w :: proc(st: Flex_Style) -> f32 { return st.max_width  == 0 ? FLEX_INF : st.max_width }
flex_style_max_h :: proc(st: Flex_Style) -> f32 { return st.max_height == 0 ? FLEX_INF : st.max_height }

// ---------- the box tree ----------
//
// INDEX, NOT POINTER: children are ints into Flex_Tree.boxes. A [dynamic] array
// reallocates on append, so ^Flex_Box pointers would dangle -- this is the single
// most important difference from nanoui's packed ArrayList(Node) + u32 indices
// (it uses indices for exactly the same reason).

FLEX_NONE :: -1

Flex_Box :: struct {
    parent:      int,
    first_child: int,
    last_child:  int,
    next:        int,
    child_count: int,

    style:       Flex_Style,
    intrinsic:   Flex_Size,     // leaf's own size, supplied by the app/bridge
    measured:    Flex_Size,
    rect:        Flex_Rect,

    // Bridge-only payload. The layout engine never reads it.
    hwnd:        rawptr,
    tag:         int,
    // Set by flex_detach() on the sub-tree ROOT. flex_box_detached() walks
    // the parent chain, so children need no marking -- this keeps detach
    // O(1) and avoids recursive procedures (Odin has no forward decl).
    detached:    bool,
}

Flex_Tree :: struct {
    boxes: [dynamic]Flex_Box,
    root:  int,           // call flex_tree_init() -- zero is NOT a valid "no root"
    open:  int,           // builder stack top, retained-mode style
}

flex_tree_init :: proc(t: ^Flex_Tree) {
    t.boxes = make([dynamic]Flex_Box)
    t.root  = FLEX_NONE
    t.open  = FLEX_NONE
}

flex_tree_destroy :: proc(t: ^Flex_Tree) {
    delete(t.boxes)
    t.root = FLEX_NONE
}

// Open a container. Children added until `flex_end`.
flex_begin :: proc(t: ^Flex_Tree, s: Flex_Style, hwnd: rawptr = nil) -> int {
    i := len(t.boxes)
    // Every index field must be FLEX_NONE explicitly. Flex_Box{style = s} alone would
    // zero them to 0, which is a valid box index, not "no child".
    append(&t.boxes, Flex_Box{
        parent      = FLEX_NONE,
        first_child = FLEX_NONE,
        last_child  = FLEX_NONE,
        next        = FLEX_NONE,
        child_count = 0,
        style       = s,
        intrinsic   = Flex_Size{},
        measured    = Flex_Size{},
        rect        = Flex_Rect{},
        hwnd        = hwnd,
        tag         = 0,
        detached    = false,
    })
    parent := t.open
    if parent != FLEX_NONE {
        b := &t.boxes[i]
        b.parent = parent
        p := &t.boxes[parent]
        p.child_count += 1
        if p.last_child == FLEX_NONE {
            p.first_child = i
        } else {
            t.boxes[p.last_child].next = i
        }
        p.last_child = i
    } else {
        t.root = i
    }
    t.open = i
    return i
}

// A leaf: one Win32 control.
flex_add :: proc(t: ^Flex_Tree, s: Flex_Style, intrinsic: Flex_Size, hwnd: rawptr = nil) -> int {
    idx := flex_begin(t, s, hwnd)
    t.boxes[idx].intrinsic = intrinsic
    t.open = t.boxes[idx].parent
    return idx
}

flex_end :: proc(t: ^Flex_Tree) {
    if t.open != FLEX_NONE do t.open = t.boxes[t.open].parent
}

// ---------- runtime tree editing (tier-4: dynamic views) ----------
// The static tree is CLOSED before start_mainloop(). To insert a brand-new
// tab page at runtime we must attach it under a SAVED parent box index
// without disturbing the builder stack. Both helpers save/restore `open`.
// They mirror Zig's flexBeginControlAt / flexAddTo exactly.

// Open a container under an explicit parent. The returned box stays open in
// the TREE sense (children may be added), but `t.open` is restored, so every
// later child MUST be added with flex_add_to(t, returned_idx, ...).
flex_begin_at :: proc(t: ^Flex_Tree, parent: int, s: Flex_Style, hwnd: rawptr = nil) -> int {
    if parent < 0 || parent >= len(t.boxes) do return FLEX_NONE
    saved := t.open
    t.open = parent
    idx := flex_begin(t, s, hwnd)
    t.open = saved
    return idx
}

// Add a leaf under an explicit parent (same save/restore rule).
flex_add_to :: proc(t: ^Flex_Tree, parent: int, s: Flex_Style,
                    intrinsic: Flex_Size, hwnd: rawptr = nil) -> int {
    if parent < 0 || parent >= len(t.boxes) do return FLEX_NONE
    saved := t.open
    t.open = parent
    idx := flex_add(t, s, intrinsic, hwnd)
    t.open = saved
    return idx
}

// Unlink a box (and, implicitly, its whole subtree) from its parent's child
// chain and mark it detached. flex_layout() walks from root via first_child /
// next, so unlinking alone removes it from geometry; the flag lets the Win32
// bridge skip the stale boxes that still sit in the dynamic array.
// O(1), no recursion: flex_box_detached() walks the parent chain instead.
flex_detach :: proc(t: ^Flex_Tree, index: int) {
    if index < 0 || index >= len(t.boxes) do return
    b := &t.boxes[index]
    if b.detached do return
    if index == t.root do return               // never detach the root

    p := b.parent
    if p != FLEX_NONE {
        par := &t.boxes[p]
        prev := FLEX_NONE
        for c := par.first_child; c != FLEX_NONE; c = t.boxes[c].next {
            if c == index do break
            prev = c
        }
        if prev == FLEX_NONE {
            par.first_child = b.next
        } else {
            t.boxes[prev].next = b.next
        }
        if par.last_child == index do par.last_child = prev
        par.child_count -= 1
        if par.child_count < 0 do par.child_count = 0
    }
    b.next = FLEX_NONE
    b.detached = true
    b.rect = Flex_Rect{}
}

flex_box_detached :: proc(t: ^Flex_Tree, index: int) -> bool {
    for p := index; p != FLEX_NONE; p = t.boxes[p].parent {
        if t.boxes[p].detached do return true
    }
    return false
}

// ---------- pass 1: flex_measure (bottom-up) ----------

flex_main_of  :: proc(d: Flex_Direction, s: Flex_Size) -> f32 { return d == .Row ? s.w : s.h }
flex_cross_of :: proc(d: Flex_Direction, s: Flex_Size) -> f32 { return d == .Row ? s.h : s.w }
flex_main_len :: proc(d: Flex_Direction, s: Flex_Style) -> Flex_Length { return d == .Row ? s.width : s.height }
flex_cross_len:: proc(d: Flex_Direction, s: Flex_Style) -> Flex_Length { return d == .Row ? s.height : s.width }

flex_measure :: proc(t: ^Flex_Tree, index: int, avail_w: f32) {
    b := &t.boxes[index]
    st := b.style

    box_w := st.width.kind == .Px ? st.width.px : avail_w
    box_w = flex_min(box_w, flex_style_max_w(st))
    inner_w := flex_max(0, box_w - st.padding.left - st.padding.right)

    content := Flex_Size{}
    if b.first_child == FLEX_NONE {
        // LEAF: the control reports its own size. No glyph atlas, no wrapping.
        content = b.intrinsic
    } else {
        // BRANCH: sum children along main axis, max along cross axis.
        count: f32 = 0
        for child := b.first_child; child != FLEX_NONE; child = t.boxes[child].next {
            // Absolute children still need their measured size (their rect is
            // computed in arrange from measured.w/h when not .Fill), but they
            // must not contribute to the flow's main-axis sum.
            flex_measure(t, child, inner_w)
            if t.boxes[child].style.absolute do continue
            s := t.boxes[child].measured
            if st.direction == .Row {
                content.w += s.w
                content.h = flex_max(content.h, s.h)
            } else {
                content.h += s.h
                content.w = flex_max(content.w, s.w)
            }
            count += 1
        }
        if count > 1 {
            if st.direction == .Row do content.w += st.gap * (count - 1)
            else                      do content.h += st.gap * (count - 1)
        }
    }

    size := Flex_Size{
        w = content.w + st.padding.left + st.padding.right,
        h = content.h + st.padding.top + st.padding.bottom,
    }
    if st.width.kind  == .Px do size.w = st.width.px
    if st.height.kind == .Px do size.h = st.height.px
    size.w = flex_clamp(size.w, st.min_width,  flex_max(st.min_width,  flex_style_max_w(st)))
    size.h = flex_clamp(size.h, st.min_height, flex_max(st.min_height, flex_style_max_h(st)))
    b.measured = size
}

// ---------- pass 2: flex_arrange (top-down) ----------

flex_grow_of :: proc(d: Flex_Direction, st: Flex_Style) -> f32 {
    if st.grow > 0 do return st.grow
    return flex_main_len(d, st).kind == .Fill ? 1 : 0
}

flex_arrange :: proc(t: ^Flex_Tree, index: int, rect_in: Flex_Rect) {
    b := &t.boxes[index]
    st := b.style

    r := rect_in
    r.x += st.offset_x
    r.y += st.offset_y
    b.rect = r
    if b.first_child == FLEX_NONE do return

    dir := st.direction
    inner := flex_rect_inset(r, st.padding)
    inner_main  := dir == .Row ? inner.w : inner.h
    inner_cross := dir == .Row ? inner.h : inner.w

    // Base sizes along main axis, and the total share of growth.
    used: f32 = 0
    grow_total: f32 = 0
    count: f32 = 0
    for child := b.first_child; child != FLEX_NONE; child = t.boxes[child].next {
        ch := &t.boxes[child]
        if ch.style.absolute do continue
        used += flex_main_len(dir, ch.style).kind == .Fill ? 0 : flex_main_of(dir, ch.measured)
        grow_total += flex_grow_of(dir, ch.style)
        count += 1
    }
    used += st.gap * flex_max(0, count - 1)
    free := inner_main - used

    pos: f32 = 0
    spacing := st.gap
    if grow_total == 0 && free > 0 {
        switch st.justify {
        case .Start: break
        case .Center:       pos = free / 2
        case .End:          pos = free
        case .Space_Between:
            if count > 1 do spacing += free / (count - 1)
        }
    }

    for child := b.first_child; child != FLEX_NONE; child = t.boxes[child].next {
        ch := &t.boxes[child]

        // Absolute: placed at the parent's content origin, out of the flow.
        if ch.style.absolute {
            // flex_arrange() already applies offset_x/offset_y at its top.
            // Pass the raw content origin ONCE; adding the offset here as well
            // would shift the child twice (the "offset_y double-add" bug).
            w := ch.style.width.kind  == .Fill ? flex_max(0, inner.w - ch.style.offset_x) : ch.measured.w
            h := ch.style.height.kind == .Fill ? flex_max(0, inner.h - ch.style.offset_y) : ch.measured.h
            flex_arrange(t, child, Flex_Rect{inner.x, inner.y, w, h})
            continue
        }

        m := flex_main_len(dir, ch.style).kind == .Fill ? 0 : flex_main_of(dir, ch.measured)
        if free > 0 && grow_total > 0 do m += free * flex_grow_of(dir, ch.style) / grow_total

        clen := flex_cross_len(dir, ch.style)
        stretch := clen.kind == .Fill || (st.align_items == .Stretch && clen.kind == .Auto)
        x := stretch ? inner_cross : flex_cross_of(dir, ch.measured)
        if dir == .Row do m = flex_min(m, flex_style_max_w(ch.style))
        else            do x = flex_min(x, flex_style_max_w(ch.style))
        if dir == .Column do m = flex_min(m, flex_style_max_h(ch.style))
        else              do x = flex_min(x, flex_style_max_h(ch.style))

        cpos: f32 = 0
        switch st.align_items {
        case .Start, .Stretch: break
        case .Center: cpos = (inner_cross - x) / 2
        case .End:    cpos = inner_cross - x
        }

        // A ternary must stay one expression; splitting `?` / `:` onto their
        // own lines leaves `cr := dir == .Row` as a complete statement.
        cr: Flex_Rect
        if dir == .Row {
            cr = Flex_Rect{inner.x + pos, inner.y + cpos, m, x}
        } else {
            cr = Flex_Rect{inner.x + cpos, inner.y + pos, x, m}
        }
        flex_arrange(t, child, cr)
        pos += m + spacing
    }
}

// ---------- one-call layout ----------

// `bounds` is the parent window's CLIENT area, in PIXELS.
flex_layout :: proc(t: ^Flex_Tree, bounds: Flex_Rect) {
    if t.root == FLEX_NONE do return
    flex_measure(t, t.root, bounds.w)
    flex_arrange(t, t.root, bounds)
}

// ---------- verbatim regression tests from nanoui layout.zig ----------
//
// layout.zig:312 "row with a growing child" expects
//   a.x=10  b.x=70  b.w=180  d.x=260   (300x100, padding 10, gap 10)
// layout.zig:331 "centered column" expects
//   a.x=80 a.y=55  b.x=60 b.y=105     (200x200, center/center, gap 10)
// Port these into the target Odin project's test suite. They are the fastest
// way to prove the extraction kept the arithmetic intact.
