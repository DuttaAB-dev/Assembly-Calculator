# ==============================================================================
# Pure x86_64 Assembly Libadwaita Complex Calculator
# User Interface, X11 Direct Protocol Driver & Compositor (calc_ui.s)
#
# Free of libc, Xlib, XCB, Cairo, GTK, Python, or any runtime dependencies.
# Direct Linux 64-bit syscalls + direct binary X11 socket protocol over UNIX domain.
# ==============================================================================
#
# Architectural Highlights:
# -------------------------
# 1. Direct Linux Syscall Kernel Interface:
#    - Memory allocation via sys_mmap (anonymous private 32-bit ARGB framebuffer).
#    - UNIX domain socket networking via sys_socket and sys_connect.
#    - High-efficiency multiplexed event waiting via sys_poll.
#    - Direct binary packet exchange via sys_read and sys_write.
#
# 2. Native X11 Wire Protocol Implementation:
#    - Reads MIT-MAGIC-COOKIE-1 authentication credentials from ~/.Xauthority.
#    - Negotiates connection setup handshake directly with X server (/tmp/.X11-unix/X0).
#    - Dynamic X11 Atom interning (WM_PROTOCOLS, WM_DELETE_WINDOW, _MOTIF_WM_HINTS, etc.).
#    - Client-Side Decorations (CSD): Suppresses window manager decorations using
#      _MOTIF_WM_HINTS to render modern Libadwaita-style custom headerbars.
#    - Window Movement: Triggers interactive window dragging via _NET_WM_MOVERESIZE.
#    - Physical Window Rounded Corners: Shapes physical window boundaries using the
#      X11 Shape Extension (ShapeRectangles, minor opcode 1) with 33 clipping rects.
#    - Screen Blitting: Fast chunked PutImage (opcode 72, ZPixmap 24/32-bit depth).
#
# 3. In-House Software 2D Graphics Rasterizer:
#    - draw_rect: Fast solid color fills via x86_64 'rep stosl'.
#    - draw_squircle: Exact circular corner rasterization (cx^2 + cy^2 <= r^2) with
#      1px antialiased borders, boundary clipping, and variable corner radii.
#    - draw_glyph: 8x16 bitmap glyph renderer with arbitrary integer scaling (NxN)
#      and strict screen-boundary clipping.
#    - draw_string: High-performance string typography renderer.
#
# 4. Libadwaita Component Compositor & Layout:
#    - HeaderBar: Mode title, hamburger menu button, close button, draggable titlebar.
#    - Inset Display Card: History expression, active input, or 4-base live inspector.
#    - Mode-adaptive keypads: Basic (4x5), Scientific (5x6), Programmer (5x6).
#    - Popover Dropdown Menu: Mode switcher with radio indicators and history clearing.
#
# 5. Headless CI & Dump Verification:
#    - Supports '--dump <file.ppm> [mode] [menu]' command-line flag for headless
#      rendering to Netpbm PPM images without an X server.
# ==============================================================================

# ------------------------------------------------------------------------------
# Exported Global Symbols
# ------------------------------------------------------------------------------
.global _start
.global WIN_W, WIN_H, fb_ptr, disp_buf, hist_buf, hex_buf, dec_buf, oct_buf, bin_buf
.global curr_mode, curr_base, menu_open, hover_btn, active_btn, hover_menu, dirty
.global pending_op, clr_next, acc_val, acc_int, exit_clean, exit_fail
.global history_count, history_open, history_hover, history_entries, commit_history, clear_history

# ==============================================================================
# Window & Framebuffer Geometry Constants
# ==============================================================================
.equ WIN_W,   420                        # Calculator window width in pixels
.equ WIN_H,   680                        # Calculator window height in pixels
.equ FB_SIZE, WIN_W * WIN_H * 4          # Total framebuffer size in bytes (32bpp ARGB)

# ==============================================================================
# Linux x86_64 Syscall Numbers (Direct Kernel ABI)
# ==============================================================================
.equ SYS_READ,    0                      # sys_read(fd, buf, count)
.equ SYS_WRITE,   1                      # sys_write(fd, buf, count)
.equ SYS_OPEN,    2                      # sys_open(filename, flags, mode)
.equ SYS_CLOSE,   3                      # sys_close(fd)
.equ SYS_POLL,    7                      # sys_poll(ufds, nfds, timeout)
.equ SYS_MMAP,    9                      # sys_mmap(addr, len, prot, flags, fd, off)
.equ SYS_SOCKET,  41                     # sys_socket(family, type, protocol)
.equ SYS_CONNECT, 42                     # sys_connect(fd, uservaddr, addrlen)
.equ SYS_EXIT,    60                     # sys_exit(error_code)

# ==============================================================================
# GNOME Libadwaita Dark Theme Color Palette (32-bit 0x00RRGGBB format)
# ==============================================================================
.equ COL_BG,          0x242424           # Base window background (#242424)
.equ COL_HEADER,      0x242424           # Headerbar background (#242424)
.equ COL_SEP,         0x303030           # Subtle separator lines (#303030)
.equ COL_CARD_BG,     0x1E1E1E           # Inset display card background (#1E1E1E)
.equ COL_CARD_BORDER, 0x333333           # Display card 1px border (#333333)
.equ COL_TEXT_PRI,    0xFFFFFF           # Primary high-contrast text (#FFFFFF)
.equ COL_TEXT_SEC,    0x8E8E93           # Secondary muted text (#8E8E93)
.equ COL_BTN_IDLE,    0x323232           # Keypad button idle surface (#323232)
.equ COL_BTN_HOVER,   0x3D3D3D           # Keypad button hover surface (#3D3D3D)
.equ COL_BTN_ACTIVE,  0x282828           # Keypad button pressed surface (#282828)
.equ COL_BTN_BORDER,  0x3E3E3E           # Keypad button border (#3E3E3E)
.equ COL_ACCENT,      0x3584E4           # Libadwaita accent blue (#3584E4)
.equ COL_ACC_HOV,     0x4790E8           # Accent button hover state (#4790E8)
.equ COL_ACC_ACT,     0x1C71D8           # Accent button active state (#1C71D8)
.equ COL_DEST,        0xE01B24           # Destructive action red (Clear) (#E01B24)
.equ COL_DEST_HOV,    0xE63840           # Destructive hover state (#E63840)
.equ COL_DEST_ACT,    0xC01C28           # Destructive active state (#C01C28)
.equ COL_POPOVER_BG,  0x2A2A2A           # Popover menu card background (#2A2A2A)
.equ COL_POPOVER_BRD, 0x444444           # Popover menu card border (#444444)
.equ COL_POPOVER_HOV, 0x383838           # Popover item hover background (#383838)

# ==============================================================================
# Read-Only Data Section (.rodata)
# ==============================================================================
.section .rodata

# 1. Embedded Bitmap Typography Font Data (104 glyphs, 8x16 pixels each)
.align 16
font_data:
    .incbin "font.bin"

# 2. X11 Wire Protocol String Literals
str_x0_path:      .asciz "/tmp/.X11-unix/X0"            # UNIX domain socket path
str_auth_name:    .asciz "MIT-MAGIC-COOKIE-1"           # X11 authorization protocol
str_wm_proto:     .asciz "WM_PROTOCOLS"                 # ICCCM window manager protocols
str_wm_del:       .asciz "WM_DELETE_WINDOW"             # Graceful window close request
str_mwm_hints:    .asciz "_MOTIF_WM_HINTS"              # Motif window decorations hints
str_gtk_extents:  .asciz "_GTK_FRAME_EXTENTS"           # Client-side decoration shadow extents
str_net_type:     .asciz "_NET_WM_WINDOW_TYPE"          # EWMH window type property
str_net_norm:     .asciz "_NET_WM_WINDOW_TYPE_NORMAL"   # EWMH normal top-level window
str_net_move:     .asciz "_NET_WM_MOVERESIZE"           # EWMH interactive window move action
str_app_title:    .asciz "Calculator"                   # Application name

# 3. UI HeaderBar Mode Titles
str_basic_title:  .asciz "Basic Calculator"
str_adv_title:    .asciz "Scientific Calculator"
str_prog_title:   .asciz "Programming Calculator"

# 4. Popover Menu Item Labels
str_menu_basic:   .asciz "  Basic Mode"
str_menu_adv:     .asciz "  Scientific Mode"
str_menu_prog:    .asciz "  Programming Mode"
str_menu_clear:   .asciz "  Clear History"

# 5. Programmer Mode Base Inspector Labels
str_hex_lbl:      .asciz "HEX:"
str_dec_lbl:      .asciz "DEC:"
str_oct_lbl:      .asciz "OCT:"
str_bin_lbl:      .asciz "BIN:"

str_default_disp: .asciz "0"
str_hist_title:  .asciz "Calculation History"
str_hist_empty:  .asciz "No History Yet"
str_hist_clear:  .asciz "Clear All History"

# 6. Keypad Grid Layout Tables (ASCII or custom glyph bytes)
# Glyph IDs: 127 = ≡, 128 = π, 129 = √, 130 = ⌫, 131 = ÷, 132 = ×, 133 = ±
basic_key_labels:
    .byte 'C', 130, 133, 131
    .byte '7', '8', '9', 132
    .byte '4', '5', '6', '-'
    .byte '1', '2', '3', '+'
    .byte '(', '0', '.', '='

adv_key_types:
    .byte 's', 'C', 130, 133, 131
    .byte 'c', '7', '8', '9', 132
    .byte 't', '4', '5', '6', '-'
    .byte 129, '1', '2', '3', '+'
    .byte 128, '(', '0', '.', '='
    .byte 'e', 'l', 'g', '^', 'r'

# 7. Physical Window Rounded Corners Clipping Rectangles Table (33 entries)
# Passed to X11 Shape Extension (ShapeRectangles) to clip window to 16px radius.
# Format per entry: x (short), y (short), width (short), height (short)
.align 8
shape_rects_table:
    .short 10, 0, 400, 1
    .short 8, 1, 404, 1
    .short 6, 2, 408, 1
    .short 5, 3, 410, 1
    .short 4, 4, 412, 1
    .short 3, 5, 414, 1
    .short 2, 6, 416, 1
    .short 2, 7, 416, 1
    .short 1, 8, 418, 1
    .short 1, 9, 418, 1
    .short 0, 10, 420, 1
    .short 0, 11, 420, 1
    .short 0, 12, 420, 1
    .short 0, 13, 420, 1
    .short 0, 14, 420, 1
    .short 0, 15, 420, 1
    .short 0, 16, 420, 648
    .short 0, 664, 420, 1
    .short 0, 665, 420, 1
    .short 0, 666, 420, 1
    .short 0, 667, 420, 1
    .short 0, 668, 420, 1
    .short 0, 669, 420, 1
    .short 1, 670, 418, 1
    .short 1, 671, 418, 1
    .short 2, 672, 416, 1
    .short 2, 673, 416, 1
    .short 3, 674, 414, 1
    .short 4, 675, 412, 1
    .short 5, 676, 410, 1
    .short 6, 677, 408, 1
    .short 8, 678, 404, 1
    .short 10, 679, 400, 1

prog_key_types:
    .byte '&', '|', '^', '~', 'C'
    .byte '<', '>', 'A', 'B', 130
    .byte '7', '8', '9', 'C', 131
    .byte '4', '5', '6', 'D', 132
    .byte '1', '2', '3', 'E', '-'
    .byte '0', 133, '=', 'F', '+'

# ==============================================================================
# Mutable Data Section (.data)
# ==============================================================================
.section .data
.align 8

# Process Startup & Authentication State
initial_rsp:    .quad 0                  # Saved initial %rsp (for argc, argv, envp)
has_auth:       .long 0                  # 1 if valid Xauthority cookie loaded, 0 otherwise
str_xauth_prefix: .ascii "XAUTHORITY="   # Environment variable search target

# X11 Socket & Resource Identifiers
sock_fd:        .quad 0                  # UNIX domain socket file descriptor
win_id:         .quad 0                  # Created X11 client Window ID
gc_id:          .quad 0                  # Created X11 Graphics Context (GC) ID
root_id:        .quad 0                  # Root Window ID of default screen
fb_ptr:         .quad 0                  # Pointer to mmap'd 32-bit ARGB framebuffer

# Interned X11 Atom IDs (retrieved dynamically from X server)
atom_wm_proto:  .long 0                  # WM_PROTOCOLS atom
atom_wm_del:    .long 0                  # WM_DELETE_WINDOW atom
atom_mwm:       .long 0                  # _MOTIF_WM_HINTS atom
atom_gfe:       .long 0                  # _GTK_FRAME_EXTENTS atom
atom_net_type:  .long 0                  # _NET_WM_WINDOW_TYPE atom
atom_net_norm:  .long 0                  # _NET_WM_WINDOW_TYPE_NORMAL atom
atom_net_move:  .long 0                  # _NET_WM_MOVERESIZE atom

# Interactive GUI State
curr_mode:      .long 0                  # Mode: 0 = Basic, 1 = Scientific, 2 = Programmer
curr_base:      .long 0                  # Programmer Radix: 0 = HEX, 1 = DEC, 2 = OCT, 3 = BIN
menu_open:      .long 0                  # Popover menu visibility flag (0 = closed, 1 = open)
hover_btn:      .long -1                 # Index of currently hovered button (-1 = none)
active_btn:     .long -1                 # Index of currently pressed button (-1 = none)
hover_menu:     .long -1                 # Index of hovered popover menu item (-1 = none)
history_count:   .long 0                  # Number of recorded calculations (0..8)
history_open:    .long 0                  # 1 if history popover is visible
history_hover:   .long -1                 # Index of hovered history item (-1 = none)
.align 8
history_entries: .skip 8 * 64             # 8 entries * 64 bytes each
dirty:          .long 1                  # Repaint request flag (1 = redraw needed)

# Arithmetic Engine State
pending_op:     .long 0                  # Pending binary operation opcode
clr_next:       .long 0                  # Next digit clears display buffer flag
acc_val:        .double 0.0              # IEEE-754 64-bit float accumulator
acc_int:        .quad 0                  # 64-bit integer accumulator for programmer mode

# Text Display Buffers (null-terminated strings)
disp_buf:       .skip 64                 # Active number display string
hist_buf:       .skip 128                # Expression history string (e.g. "12 + 4 =")
hex_buf:        .skip 32                 # Programmer Mode: Hex readout buffer
dec_buf:        .skip 32                 # Programmer Mode: Dec readout buffer
oct_buf:        .skip 32                 # Programmer Mode: Oct readout buffer
bin_buf:        .skip 64                 # Programmer Mode: Bin readout buffer

# Multiplexed Event Polling Structure (struct pollfd for sys_poll)
poll_pfd:
    .long 0                              # fd: filled with sock_fd
    .short 1                             # events: POLLIN (0x0001)
    .short 0                             # revents: filled by kernel

# Socket Communication Buffers
ev_packet:      .skip 64                 # Incoming 32-byte X11 event packet buffer
auth_cookie:    .skip 16                 # 16-byte MIT-MAGIC-COOKIE-1 binary cookie
sock_addr:      .skip 128                # struct sockaddr_un for /tmp/.X11-unix/X0

# ==============================================================================
# Executable Code Section (.text)
# ==============================================================================
.section .text

# ------------------------------------------------------------------------------
# _start:
# Application Entry Point (Linux Executable ABI).
#
# Execution Flow:
#   1. Saves initial stack pointer (%rsp) to access argc, argv, and envp.
#   2. Allocates 32-bit ARGB framebuffer (420x680x4 bytes) via sys_mmap.
#   3. Checks for headless '--dump' flag:
#      - If present, mocks state, renders UI, writes PPM image file, and exits 0.
#   4. If not dump:
#      - Scans environment variables for XAUTHORITY and extracts cookie.
#      - Opens UNIX domain socket to /tmp/.X11-unix/X0.
#      - Performs binary X11 connection setup handshake.
#      - Creates window, configures CSD (_MOTIF_WM_HINTS), sets rounded window
#        shape via X11 Shape extension, and maps window to display.
#   5. Enters main interactive event loop.
# ------------------------------------------------------------------------------
_start:
    mov %rsp, initial_rsp(%rip)          # Save initial stack pointer

    # 1. Allocate Framebuffer via sys_mmap (420x680x4 bytes = 1,142,400 bytes)
    # Arguments: addr=0, len=FB_SIZE, prot=PROT_READ|PROT_WRITE(3),
    #            flags=MAP_PRIVATE|MAP_ANONYMOUS(0x22), fd=-1, offset=0
    mov $SYS_MMAP, %rax
    xor %rdi, %rdi
    mov $FB_SIZE, %rsi
    mov $3, %rdx
    mov $0x22, %r10
    mov $-1, %r8
    xor %r9, %r9
    syscall
    mov %rax, fb_ptr(%rip)               # Store framebuffer pointer

    # 2. Check if headless '--dump' flag was passed in argv
    # argc is at (%rsp), argv[0] at 8(%rsp), argv[1] at 16(%rsp)
    mov initial_rsp(%rip), %rax
    mov (%rax), %rcx                     # %rcx = argc
    cmp $3, %rcx                         # Minimum 3 arguments: ./calc --dump <file.ppm>
    jl .not_dump

    mov 16(%rax), %rsi                   # %rsi = argv[1]
    cmpb $'-', (%rsi)
    jne .not_dump
    cmpb $'-', 1(%rsi)
    jne .not_dump
    cmpb $'d', 2(%rsi)
    jne .not_dump
    cmpb $'u', 3(%rsi)
    jne .not_dump
    cmpb $'m', 4(%rsi)
    jne .not_dump
    cmpb $'p', 5(%rsi)
    jne .not_dump

    # Optional mode specified in argv[3] (0=Basic, 1=Scientific, 2=Programmer)
    cmp $4, %rcx
    jl .no_custom_mode
    mov 32(%rax), %rsi                   # %rsi = argv[3]
    movzbq (%rsi), %rdx
    sub $'0', %rdx
    cmp $0, %edx
    jl .no_custom_mode
    cmp $2, %edx
    jg .no_custom_mode
    mov %edx, curr_mode(%rip)            # Set target mode

.no_custom_mode:
    # Optional menu / history flag in argv[4] ('m' = open menu, 'h' = open history)
    cmp $5, %rcx
    jl .do_render_dump
    mov 40(%rax), %rsi                   # %rsi = argv[4]
    cmpb $'m', (%rsi)
    je .set_m_open
    cmpb $'h', (%rsi)
    je .set_h_open
    jmp .do_render_dump
.set_m_open:
    movl $1, menu_open(%rip)
    jmp .do_render_dump
.set_h_open:
    movl $1, history_open(%rip)
    movl $3, history_count(%rip)
    # Mock entry 0: "12 + 4 =" -> "16"
    lea history_entries(%rip), %rdi
    movl $0x202B2032, (%rdi)            # "2 + "
    movb $'1', (%rdi)
    movb $'2', 1(%rdi)
    movb $' ', 2(%rdi)
    movb $'+', 3(%rdi)
    movb $' ', 4(%rdi)
    movb $'4', 5(%rdi)
    movb $' ', 6(%rdi)
    movb $'=', 7(%rdi)
    movb $0, 8(%rdi)
    lea history_entries+32(%rip), %rdi
    movb $'1', (%rdi)
    movb $'6', 1(%rdi)
    movb $0, 2(%rdi)
    # Mock entry 1: "sin(45) =" -> "0.707107"
    lea history_entries+64(%rip), %rdi
    movb $'s', (%rdi)
    movb $'i', 1(%rdi)
    movb $'n', 2(%rdi)
    movb $('('), 3(%rdi)
    movb $'4', 4(%rdi)
    movb $'5', 5(%rdi)
    movb $(')'), 6(%rdi)
    movb $' ', 7(%rdi)
    movb $'=', 8(%rdi)
    movb $0, 9(%rdi)
    lea history_entries+96(%rip), %rdi
    movb $'0', (%rdi)
    movb $'.', 1(%rdi)
    movb $'7', 2(%rdi)
    movb $'0', 3(%rdi)
    movb $'7', 4(%rdi)
    movb $'1', 5(%rdi)
    movb $0, 6(%rdi)
    # Mock entry 2: "710 + 710 =" -> "1420"
    lea history_entries+128(%rip), %rdi
    movb $'7', (%rdi)
    movb $'1', 1(%rdi)
    movb $'0', 2(%rdi)
    movb $' ', 3(%rdi)
    movb $'+', 4(%rdi)
    movb $' ', 5(%rdi)
    movb $'7', 6(%rdi)
    movb $'1', 7(%rdi)
    movb $'0', 8(%rdi)
    movb $' ', 9(%rdi)
    movb $'=', 10(%rdi)
    movb $0, 11(%rdi)
    lea history_entries+160(%rip), %rdi
    movb $'1', (%rdi)
    movb $'4', 1(%rdi)
    movb $'2', 2(%rdi)
    movb $'0', 3(%rdi)
    movb $0, 4(%rdi)

.do_render_dump:
    # Set up realistic mock display values based on selected mode
    lea disp_buf(%rip), %rdi
    mov curr_mode(%rip), %eax
    cmp $1, %eax
    je .mock_adv
    cmp $2, %eax
    je .mock_prog

    # Basic mode mock: "1420", history "710 + 710"
    movb $'1', (%rdi)
    movb $'4', 1(%rdi)
    movb $'2', 2(%rdi)
    movb $'0', 3(%rdi)
    movb $0, 4(%rdi)
    lea hist_buf(%rip), %rsi
    movb $'7', (%rsi)
    movb $'1', 1(%rsi)
    movb $'0', 2(%rsi)
    movb $' ', 3(%rsi)
    movb $'+', 4(%rsi)
    movb $' ', 5(%rsi)
    movb $'7', 6(%rsi)
    movb $'1', 7(%rsi)
    movb $'0', 8(%rsi)
    movb $0, 9(%rsi)
    jmp .start_dump_render

.mock_adv:
    # Scientific mode mock: "0.7071", history "sin(45)"
    movb $'0', (%rdi)
    movb $'.', 1(%rdi)
    movb $'7', 2(%rdi)
    movb $'0', 3(%rdi)
    movb $'7', 4(%rdi)
    movb $'1', 5(%rdi)
    movb $0, 6(%rdi)
    lea hist_buf(%rip), %rsi
    movb $'s', (%rsi)
    movb $'i', 1(%rsi)
    movb $'n', 2(%rsi)
    movb $('('), 3(%rsi)
    movb $'4', 4(%rsi)
    movb $'5', 5(%rsi)
    movb $(')'), 6(%rsi)
    movb $0, 7(%rsi)
    jmp .start_dump_render

.mock_prog:
    # Programmer mode mock: "255" with synchronous 4-base updates
    movb $'2', (%rdi)
    movb $'5', 1(%rdi)
    movb $'5', 2(%rdi)
    movb $0, 3(%rdi)
    call update_prog_readouts

.start_dump_render:
    # Render full UI into framebuffer
    call render_ui

    # Open destination file via sys_open(argv[2], O_WRONLY|O_CREAT|O_TRUNC(0x241), 0666)
    mov initial_rsp(%rip), %rax
    mov 24(%rax), %rdi                   # %rdi = argv[2] (output filename)
    mov $SYS_OPEN, %rax
    mov $0x241, %rsi
    mov $0666, %rdx
    syscall
    cmp $0, %rax
    jl exit_fail
    mov %rax, %r12                       # %r12 = destination file descriptor

    # Write PPM header: "P6\n420 680\n255\n" (15 bytes)
    sub $32, %rsp
    movb $'P', (%rsp)
    movb $'6', 1(%rsp)
    movb $'\n', 2(%rsp)
    movb $'4', 3(%rsp)
    movb $'2', 4(%rsp)
    movb $'0', 5(%rsp)
    movb $' ', 6(%rsp)
    movb $'6', 7(%rsp)
    movb $'8', 8(%rsp)
    movb $'0', 9(%rsp)
    movb $'\n', 10(%rsp)
    movb $'2', 11(%rsp)
    movb $'5', 12(%rsp)
    movb $'5', 13(%rsp)
    movb $'\n', 14(%rsp)

    mov $SYS_WRITE, %rax
    mov %r12, %rdi
    mov %rsp, %rsi
    mov $15, %rdx
    syscall
    add $32, %rsp

    # Convert 32-bit ARGB pixels to 24-bit RGB and write row-by-row (1260 bytes/row)
    sub $1280, %rsp
    xor %r13, %r13                       # %r13 = row index (0..WIN_H-1)
.dump_row_loop:
    cmp $WIN_H, %r13
    jge .dump_done

    mov %r13, %rax
    imul $WIN_W, %rax
    shl $2, %rax
    add fb_ptr(%rip), %rax
    mov %rax, %r14                       # %r14 = pointer to current row in framebuffer

    mov %rsp, %r15                       # %r15 = output row buffer pointer
    xor %rcx, %rcx                       # %rcx = column index (0..WIN_W-1)
.dump_col_loop:
    cmp $WIN_W, %rcx
    jge .dump_write_row
    mov (%r14, %rcx, 4), %eax            # Read 0x00RRGGBB
    mov %eax, %edx
    shr $16, %edx                        # Extract Red
    movb %dl, (%r15)
    mov %eax, %edx
    shr $8, %edx                         # Extract Green
    movb %dl, 1(%r15)
    movb %al, 2(%r15)                    # Extract Blue
    add $3, %r15
    inc %rcx
    jmp .dump_col_loop

.dump_write_row:
    mov $SYS_WRITE, %rax
    mov %r12, %rdi
    mov %rsp, %rsi
    mov $1260, %rdx                      # 420 pixels * 3 bytes = 1260 bytes
    syscall

    inc %r13
    jmp .dump_row_loop

.dump_done:
    add $1280, %rsp
    mov $SYS_CLOSE, %rax
    mov %r12, %rdi
    syscall

    mov $SYS_EXIT, %rax
    xor %rdi, %rdi                       # Headless dump successful (exit 0)
    syscall

.not_dump:
    # 3. Extract XAuthority Cookie from ~/.Xauthority
    call x11_load_cookie

    # 4. Connect to UNIX domain socket at /tmp/.X11-unix/X0
    mov $SYS_SOCKET, %rax
    mov $1, %rdi                         # AF_UNIX (1)
    mov $1, %rsi                         # SOCK_STREAM (1)
    xor %rdx, %rdx
    syscall
    cmp $0, %rax
    jl exit_fail
    mov %rax, sock_fd(%rip)

    # Initialize sockaddr_un structure (sun_family = AF_UNIX, sun_path = "/tmp/.X11-unix/X0")
    lea sock_addr(%rip), %rdi
    movw $1, (%rdi)
    lea 2(%rdi), %rdi
    lea str_x0_path(%rip), %rsi
    mov $18, %rcx
    rep movsb

    mov $SYS_CONNECT, %rax
    mov sock_fd(%rip), %rdi
    lea sock_addr(%rip), %rsi
    mov $110, %rdx                       # sizeof(struct sockaddr_un)
    syscall
    cmp $0, %rax
    jl exit_fail

    # 5. Perform X11 Handshake (Negotiate byte-order, auth, and display info)
    call x11_handshake
    test %rax, %rax
    jz exit_fail

    # 6. Initialize Window with CSD, rounded shapes, and Libadwaita properties
    call x11_init_window

    # Initialize default display buffer
    lea disp_buf(%rip), %rdi
    lea str_default_disp(%rip), %rsi
    movb $'0', (%rdi)
    movb $0, 1(%rdi)

    # 7. Main Interactive Event Loop
main_loop:
    mov dirty(%rip), %eax                # Check if UI repaint is requested
    test %eax, %eax
    jz wait_event

    call render_ui                       # Render dirty components to framebuffer
    call x11_blit_fb                     # Push framebuffer pixels to X11 window
    movl $0, dirty(%rip)                 # Reset dirty flag

wait_event:
    # Multiplexed socket wait using sys_poll with a 20ms timeout
    mov sock_fd(%rip), %rax
    mov %eax, poll_pfd(%rip)             # Set socket fd in pollfd
    mov $SYS_POLL, %rax
    lea poll_pfd(%rip), %rdi
    mov $1, %rsi                         # nfds = 1
    mov $20, %rdx                        # timeout = 20ms
    syscall
    cmp $0, %rax
    jl exit_clean                        # Error / signal -> clean exit
    jz main_loop                         # Timeout -> check dirty and continue

    # Read incoming 32-byte X11 event packet
    mov $SYS_READ, %rax
    mov sock_fd(%rip), %rdi
    lea ev_packet(%rip), %rsi
    mov $32, %rdx
    syscall
    cmp $32, %rax
    jne exit_clean                       # Connection closed by X server

    # Dispatch event
    call handle_x11_event
    jmp main_loop

exit_clean:
    mov $SYS_CLOSE, %rax
    mov sock_fd(%rip), %rdi
    syscall
    mov $SYS_EXIT, %rax
    xor %rdi, %rdi                       # Clean exit code 0
    syscall

exit_fail:
    mov $SYS_EXIT, %rax
    mov $1, %rdi                         # Failure exit code 1
    syscall

# ==============================================================================
# X11 Socket Protocol Helpers
# ==============================================================================

# ------------------------------------------------------------------------------
# x11_load_cookie:
# Locates and parses ~/.Xauthority to extract the 16-byte MIT-MAGIC-COOKIE-1.
#
# Logic:
#   1. Walks environment variables on stack past argc and argv looking for "XAUTHORITY=".
#   2. Opens the specified authority file via sys_open.
#   3. Scans binary records for protocol name "MIT-MAGIC-COOKIE-1".
#   4. Copies the 16-byte secret authentication cookie into auth_cookie buffer.
# ------------------------------------------------------------------------------
x11_load_cookie:
    push %rbp
    mov %rsp, %rbp
    sub $512, %rsp

    # Access environment pointer from initial stack: envp = initial_rsp + 16 + 8 * argc
    mov initial_rsp(%rip), %rax
    test %rax, %rax
    jz .lc_done
    mov (%rax), %rcx                     # %rcx = argc
    lea 16(%rax, %rcx, 8), %rsi          # %rsi = envp array

.lc_env:
    mov (%rsi), %rdi                     # Read environment variable pointer
    test %rdi, %rdi
    jz .lc_done                          # End of environment list
    push %rsi
    push %rdi
    lea str_xauth_prefix(%rip), %rsi
    mov $11, %rcx                        # Length of "XAUTHORITY="
    repe cmpsb                           # Compare string prefix
    pop %rdi
    pop %rsi
    je .lc_found_env
    add $8, %rsi
    jmp .lc_env

.lc_found_env:
    lea 11(%rdi), %rdi                   # Skip "XAUTHORITY=" to point to file path
    mov $SYS_OPEN, %rax
    xor %rsi, %rsi                       # O_RDONLY (0)
    xor %rdx, %rdx
    syscall
    cmp $0, %rax
    jl .lc_done
    mov %rax, %r12                       # %r12 = .Xauthority file descriptor

    # Read binary authority entries into stack buffer
    mov $SYS_READ, %rax
    mov %r12, %rdi
    mov %rsp, %rsi
    mov $512, %rdx
    syscall
    push %rax

    mov $SYS_CLOSE, %rax
    mov %r12, %rdi
    syscall
    pop %rax
    cmp $32, %rax
    jl .lc_done

    # Scan buffer for "MIT-MAGIC-COOKIE-1" record name
    mov %rsp, %rdi
    xor %rcx, %rcx
.lc_scan:
    cmp $400, %rcx
    jge .lc_done
    cmpb $'M', (%rdi, %rcx)
    jne .lc_next
    cmpb $'I', 1(%rdi, %rcx)
    jne .lc_next
    cmpb $'T', 2(%rdi, %rcx)
    jne .lc_next
    cmpb $'-', 3(%rdi, %rcx)
    jne .lc_next

    # Cookie payload is located 20 bytes past "MIT-" header in standard xauth record
    lea 20(%rdi, %rcx), %rsi
    lea auth_cookie(%rip), %rdi
    mov $16, %rcx
    rep movsb                            # Copy 16-byte authentication cookie
    movl $1, has_auth(%rip)              # Flag authentication as active
    jmp .lc_done

.lc_next:
    inc %rcx
    jmp .lc_scan

.lc_done:
    leave
    ret

# ------------------------------------------------------------------------------
# x11_handshake:
# Negotiates the initial X11 connection setup with the X server.
#
# Protocol Format:
#   Client Connection Setup Packet:
#     byte 0:      'l' (0x6C, little-endian byte order)
#     byte 1:      0x00 (unused)
#     bytes 2..3:  Major version = 11 (0x000B)
#     bytes 4..5:  Minor version = 0  (0x0000)
#     bytes 6..7:  Auth proto name length = 18 ("MIT-MAGIC-COOKIE-1")
#     bytes 8..9:  Auth data length = 16 (16-byte cookie)
#     bytes 10..11: Unused (pad)
#     followed by auth name and padded cookie data.
#
# Reads 8-byte setup reply:
#     byte 0:      Status: 1 = Success, 0 = Failed, 2 = Authenticate
#     bytes 6..7:  Additional data length in 4-byte multiples
#
# Reads additional setup data, extracts Client Resource ID Base, Resource ID
# Mask, and root window ID of default screen.
# ------------------------------------------------------------------------------
x11_handshake:
    sub $128, %rsp
    mov %rsp, %rdi

    # Byte order 'l' = little-endian, X11 version 11.0
    movb $'l', (%rdi)
    movb $0, 1(%rdi)
    movw $11, 2(%rdi)
    movw $0, 4(%rdi)

    mov has_auth(%rip), %eax
    test %eax, %eax
    jz .hs_no_auth

    # Authenticated setup packet (48 bytes total)
    movw $18, 6(%rdi)                    # Auth proto name length (18)
    movw $16, 8(%rdi)                    # Auth data length (16)
    movw $0, 10(%rdi)

    # Copy "MIT-MAGIC-COOKIE-1" + 2 padding bytes (aligned to 4 bytes = 20)
    lea 12(%rsp), %rdi
    lea str_auth_name(%rip), %rsi
    mov $18, %rcx
    rep movsb
    movw $0, (%rdi)                      # 2-byte alignment padding

    # Copy 16-byte authorization cookie
    lea 32(%rsp), %rdi
    lea auth_cookie(%rip), %rsi
    mov $16, %rcx
    rep movsb

    # Send 48-byte connection setup packet
    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $48, %rdx
    syscall
    jmp .hs_read_rep

.hs_no_auth:
    # Unauthenticated setup packet (12 bytes)
    movw $0, 6(%rdi)
    movw $0, 8(%rdi)
    movw $0, 10(%rdi)

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $12, %rdx
    syscall

.hs_read_rep:
    # Read 8-byte setup reply header
    mov $SYS_READ, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $8, %rdx
    syscall
    cmpb $1, (%rsp)                      # Check Status byte (1 = Success)
    jne .hs_err

    # Compute length of remaining setup data: 4 * length_words
    movzwq 6(%rsp), %r12
    shl $2, %r12

    # Read remaining setup data block
    sub %r12, %rsp
    mov $SYS_READ, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov %r12, %rdx
    syscall

    # Extract client Resource ID Base from offset 4
    mov 4(%rsp), %eax
    or $1, %eax
    mov %rax, win_id(%rip)               # Assign window ID = base | 1
    add $1, %eax
    mov %rax, gc_id(%rip)                # Assign Graphics Context ID = base | 2

    # Parse setup data to locate root window ID:
    # vendor_length is at offset 16; padded to 4-byte boundary
    movzwq 16(%rsp), %rcx
    mov %rcx, %rdx
    and $3, %rdx
    jz .v_pad_done
    mov $4, %rax
    sub %rdx, %rax
    add %rax, %rcx                       # %rcx = padded vendor length
.v_pad_done:
    # number of formats is at offset 21 (each format takes 8 bytes)
    movzbq 21(%rsp), %rax
    shl $3, %rax                         # %rax = format_count * 8
    add %rax, %rcx
    add $32, %rcx                        # Skip to first SCREEN structure
    mov (%rsp, %rcx), %eax               # First dword of SCREEN = Root Window ID
    mov %rax, root_id(%rip)

    add %r12, %rsp
    add $128, %rsp
    mov $1, %rax                         # Handshake success
    ret

.hs_err:
    add $128, %rsp
    xor %rax, %rax                       # Handshake failure
    ret

# ------------------------------------------------------------------------------
# x11_atom:
# Interns an X11 atom string by sending an InternAtom request (Opcode 16).
#
# Calling Convention:
#   Input:   %rdi = Pointer to null-terminated atom string
#   Output:  %eax = 32-bit Atom ID
# ------------------------------------------------------------------------------
x11_atom:
    push %rbp
    mov %rsp, %rbp
    sub $64, %rsp

    # Measure string length
    xor %rcx, %rcx
.al_loop:
    cmpb $0, (%rdi, %rcx)
    jz .al_done
    inc %rcx
    jmp .al_loop
.al_done:
    # Align length to 4 bytes: %rdx = (len + 3) & ~3
    mov %rcx, %rdx
    add $3, %rdx
    and $~3, %rdx
    # Request length in 4-byte words: 2 + (%rdx / 4)
    mov %rdx, %rax
    shr $2, %rax
    add $2, %rax
    shl $16, %rax
    or $16, %rax                         # Opcode 16 = InternAtom

    mov %rax, (%rsp)
    mov %cx, 4(%rsp)                     # Name length
    movw $0, 6(%rsp)                     # only_if_exists = False (0)

    # Copy atom string name into request body
    lea 8(%rsp), %rsi
    push %rcx
    push %rdi
    mov %rdi, %rax
    mov %rsi, %rdi
    mov %rax, %rsi
    rep movsb
    pop %rdi
    pop %rcx

    # Calculate total request length in bytes
    mov %rdx, %r8
    shr $2, %r8
    add $2, %r8
    shl $2, %r8

    # Send InternAtom request
    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov %r8, %rdx
    syscall

    # Read 32-byte reply
    mov $SYS_READ, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $32, %rdx
    syscall

    mov 8(%rsp), %eax                    # 32-bit Atom ID is at offset 8
    leave
    ret

# ------------------------------------------------------------------------------
# x11_init_window:
# Creates and configures the top-level application window.
#
# Protocol Steps Executed:
#   1. Interns required atoms: WM_PROTOCOLS, WM_DELETE_WINDOW, _MOTIF_WM_HINTS, etc.
#   2. CreateWindow (Opcode 1): 420x680, parent=root, event mask=Exposure|Motion|Button|Key.
#   3. CreateGC (Opcode 55): Graphics context for framebuffer blitting.
#   4. ChangeProperty (Opcode 18): Sets WM_NAME = "Calculator".
#   5. ChangeProperty (Opcode 18): Sets WM_PROTOCOLS = [WM_DELETE_WINDOW].
#   6. Suppresses window manager titlebar & border via _MOTIF_WM_HINTS (Client-Side Decorations).
#   7. Configures physical window rounded corners via x11_set_window_shape.
#   8. MapWindow (Opcode 8): Maps window to make it visible on display.
# ------------------------------------------------------------------------------
x11_init_window:
    push %rbp
    mov %rsp, %rbp
    sub $128, %rsp

    # Intern required window manager atoms
    lea str_wm_proto(%rip), %rdi
    call x11_atom
    mov %eax, atom_wm_proto(%rip)

    lea str_wm_del(%rip), %rdi
    call x11_atom
    mov %eax, atom_wm_del(%rip)

    lea str_mwm_hints(%rip), %rdi
    call x11_atom
    mov %eax, atom_mwm(%rip)

    lea str_gtk_extents(%rip), %rdi
    call x11_atom
    mov %eax, atom_gfe(%rip)

    lea str_net_type(%rip), %rdi
    call x11_atom
    mov %eax, atom_net_type(%rip)

    lea str_net_norm(%rip), %rdi
    call x11_atom
    mov %eax, atom_net_norm(%rip)

    lea str_net_move(%rip), %rdi
    call x11_atom
    mov %eax, atom_net_move(%rip)

    # 1. CreateWindow (Opcode 1, length 10 words = 40 bytes)
    movl $0x000A0001, (%rsp)             # Opcode 1, Length 10
    mov win_id(%rip), %eax
    mov %eax, 4(%rsp)                    # Client Window ID
    mov root_id(%rip), %eax
    mov %eax, 8(%rsp)                    # Parent (Root Window) ID
    movl $0x00640064, 12(%rsp)           # x = 100, y = 100
    movl $((WIN_H << 16) | WIN_W), 16(%rsp) # w = 420, h = 680
    movl $0x00010000, 20(%rsp)           # border_width = 0, class = InputOutput (1)
    movl $0, 24(%rsp)                    # visual = CopyFromParent (0)
    movl $0x00000802, 28(%rsp)           # value_mask = CWBackPixel (2) | CWEventMask (0x800)
    movl $COL_BG, 32(%rsp)               # Background pixel color
    # Event Mask: Exposure(0x8000) | PointerMotion(0x40) | ButtonPress(4) | ButtonRelease(8) | KeyPress(1)
    movl $0x0000804D, 36(%rsp)

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $40, %rdx
    syscall

    # 2. CreateGC (Opcode 55, length 4 words = 16 bytes)
    movl $0x00040037, (%rsp)             # Opcode 55 (0x37), Length 4
    mov gc_id(%rip), %eax
    mov %eax, 4(%rsp)                    # GC ID
    mov win_id(%rip), %eax
    mov %eax, 8(%rsp)                    # Drawable (Window) ID
    movl $0, 12(%rsp)                    # Value mask = 0

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $16, %rdx
    syscall

    # 3. Set WM_NAME = "Calculator" (ChangeProperty, Opcode 18)
    movl $0x00080012, (%rsp)             # Opcode 18, Length 8
    mov win_id(%rip), %eax
    mov %eax, 4(%rsp)                    # Window ID
    movl $39, 8(%rsp)                    # Property: XA_WM_NAME (39)
    movl $31, 12(%rsp)                   # Type: XA_STRING (31)
    movl $0x000008, 16(%rsp)             # Format = 8-bit
    movl $10, 20(%rsp)                   # Length = 10 chars
    movl $0x636C6143, 24(%rsp)           # "Calc"
    movl $0x74616C75, 28(%rsp)           # "ulat"
    movl $0x0000726F, 32(%rsp)           # "or\0\0"

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $36, %rdx
    syscall

    # 4. Set WM_PROTOCOLS = [WM_DELETE_WINDOW] (ChangeProperty, Opcode 18)
    movl $0x00070012, (%rsp)             # Opcode 18, Length 7
    mov win_id(%rip), %eax
    mov %eax, 4(%rsp)
    mov atom_wm_proto(%rip), %eax
    mov %eax, 8(%rsp)                    # Property: WM_PROTOCOLS
    movl $4, 12(%rsp)                    # Type: XA_ATOM (4)
    movl $32, 16(%rsp)                   # Format = 32-bit
    movl $1, 20(%rsp)                    # Num items = 1
    mov atom_wm_del(%rip), %eax
    mov %eax, 24(%rsp)                   # Value: WM_DELETE_WINDOW

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $28, %rdx
    syscall

    # 5. Suppress System Titlebar & Frame (_MOTIF_WM_HINTS)
    # Tells window manager to disable server-side titlebars (enabling Libadwaita CSD)
    mov atom_mwm(%rip), %eax
    test %eax, %eax
    jz .skip_mwm
    movl $0x000B0012, (%rsp)             # Opcode 18, Length 11
    mov win_id(%rip), %edx
    mov %edx, 4(%rsp)
    mov %eax, 8(%rsp)                    # Property: _MOTIF_WM_HINTS
    mov %eax, 12(%rsp)                   # Type: _MOTIF_WM_HINTS
    movl $32, 16(%rsp)                   # Format = 32-bit
    movl $5, 20(%rsp)                    # Num items = 5 (flags, functions, decorations, input_mode, status)
    movl $2, 24(%rsp)                    # flags = MWM_HINTS_DECORATIONS (2)
    movl $0, 28(%rsp)                    # functions = 0
    movl $0, 32(%rsp)                    # decorations = 0 (No decorations!)
    movl $0, 36(%rsp)
    movl $0, 40(%rsp)

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $44, %rdx
    syscall
.skip_mwm:

    # 6. Apply Physical Window Rounded Corners via X11 Shape Extension
    call x11_set_window_shape

    # 7. MapWindow (Opcode 8, length 2 words = 8 bytes)
    movl $0x00020008, (%rsp)             # Opcode 8, Length 2
    mov win_id(%rip), %eax
    mov %eax, 4(%rsp)                    # Window ID

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $8, %rdx
    syscall

    leave
    ret

# ------------------------------------------------------------------------------
# x11_set_window_shape:
# Clips the physical X11 window into rounded corners using the X11 Shape Extension.
#
# Protocol Steps:
#   1. Sends QueryExtension (Opcode 98) for "SHAPE" (5 bytes).
#   2. Parses reply to read extension presence and dynamic major_opcode.
#   3. If supported, constructs ShapeRectangles request:
#      - major_opcode = from query reply (typically 129)
#      - minor_opcode = 1 (ShapeRectangles)
#      - dest_kind    = 0 (ShapeBounding)
#      - op           = 0 (ShapeSet)
#      - copies 33 clipping rectangles from shape_rects_table.
#   4. Sends request to X server, clipping the outer window mask.
# ------------------------------------------------------------------------------
x11_set_window_shape:
    push %rbp
    mov %rsp, %rbp
    sub $320, %rsp

    # QueryExtension (Opcode 98, length 4 words) for "SHAPE"
    movl $0x00040062, (%rsp)             # Opcode 98 (0x62), Length 4
    movw $5, 4(%rsp)                     # Name length = 5
    movw $0, 6(%rsp)                     # Pad
    movl $0x50414853, 8(%rsp)            # "SHAP"
    movl $0x00000045, 12(%rsp)           # "E\0\0\0"

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $16, %rdx
    syscall

    # Read 32-byte QueryExtension reply
    mov $SYS_READ, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $32, %rdx
    syscall

    cmpb $1, 8(%rsp)                     # Check 'present' field at offset 8
    jne .shape_done
    movzbq 9(%rsp), %r10                 # Read major_opcode at offset 9

    # ShapeRectangles Header (Minor Opcode 1, Length 70 words = 280 bytes)
    movb %r10b, (%rsp)                   # Major opcode
    movb $1, 1(%rsp)                     # Minor opcode 1 (ShapeRectangles)
    movw $70, 2(%rsp)                    # Length in 4-byte words
    mov win_id(%rip), %eax
    mov %eax, 4(%rsp)                    # Destination window ID
    movb $0, 8(%rsp)                     # dest_kind = ShapeBounding (0)
    movb $0, 9(%rsp)                     # op = ShapeSet (0)
    movb $0, 10(%rsp)                    # ordering = Unsorted (0)
    movb $0, 11(%rsp)                    # Pad
    movw $0, 12(%rsp)                    # x_offset = 0
    movw $0, 14(%rsp)                    # y_offset = 0

    # Copy 33 rectangles (66 dwords) from shape_rects_table into request body
    lea 16(%rsp), %rdi
    lea shape_rects_table(%rip), %rsi
    mov $66, %ecx
    rep movsl

    # Send ShapeRectangles request
    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $280, %rdx
    syscall

.shape_done:
    leave
    ret

# ------------------------------------------------------------------------------
# x11_blit_fb:
# Transfers the software framebuffer pixels to the X11 window.
#
# Chunking Strategy:
#   To prevent exceeding the X11 server socket buffer limit, the 680-row
#   framebuffer is transferred in vertical slices of 32 rows each using PutImage
#   (Opcode 72, ZPixmap format, 24/32-bit depth).
# ------------------------------------------------------------------------------
x11_blit_fb:
    push %rbp
    mov %rsp, %rbp
    sub $64, %rsp

    xor %r12, %r12                       # %r12 = current starting row (y)
.blit_loop:
    cmp $WIN_H, %r12
    jge .blit_done
    mov $32, %r13                        # %r13 = rows in this slice (default 32)
    mov $WIN_H, %rax
    sub %r12, %rax
    cmp %r13, %rax
    cmovl %rax, %r13                     # Clamp to remaining window height

    # Calculate request word length: 6 header words + (WIN_W * chunk_rows)
    mov $WIN_W, %rax
    imul %r13, %rax
    add $6, %rax

    # PutImage Request Header (Opcode 72 = 0x48, format 2 = ZPixmap)
    mov %rax, %rdx
    shl $16, %rdx
    or $0x0248, %rdx
    mov %edx, (%rsp)                     # Opcode 72, Format 2, Length
    mov win_id(%rip), %eax
    mov %eax, 4(%rsp)                    # Destination Drawable ID
    mov gc_id(%rip), %eax
    mov %eax, 8(%rsp)                    # GC ID
    movw $WIN_W, 12(%rsp)                # Width = 420
    movw %r13w, 14(%rsp)                 # Height = chunk_rows
    movw $0, 16(%rsp)                    # dst_x = 0
    movw %r12w, 18(%rsp)                 # dst_y = current row
    movb $0, 20(%rsp)                    # left_pad = 0
    movb $24, 21(%rsp)                   # depth = 24
    movw $0, 22(%rsp)                    # pad

    # Send PutImage 24-byte request header
    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $24, %rdx
    syscall

    # Stream pixel payload for this vertical chunk directly from framebuffer
    mov %r12, %rax
    imul $WIN_W * 4, %rax
    add fb_ptr(%rip), %rax
    mov %rax, %rsi                       # %rsi = chunk source memory address

    mov $WIN_W * 4, %rax
    imul %r13, %rax
    mov %rax, %rdx                       # %rdx = chunk byte length

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    syscall

    add %r13, %r12                       # Advance to next slice
    jmp .blit_loop

.blit_done:
    leave
    ret

# ------------------------------------------------------------------------------
# x11_start_drag:
# Triggers native window movement via EWMH _NET_WM_MOVERESIZE ClientMessage.
# Sent when the user clicks and drags the custom Libadwaita HeaderBar.
# ------------------------------------------------------------------------------
x11_start_drag:
    mov atom_net_move(%rip), %eax
    test %eax, %eax
    jz .drag_ret

    sub $64, %rsp
    # SendEvent Request (Opcode 25 = 0x19, length 11 words = 44 bytes)
    movl $0x000B0019, (%rsp)
    mov root_id(%rip), %eax
    mov %eax, 4(%rsp)                    # Destination: Root Window
    movl $0x00180000, 8(%rsp)            # Event mask = SubstructureRedirect | SubstructureNotify

    # ClientMessage Event Body (32 bytes)
    lea 12(%rsp), %rdi
    movb $33, (%rdi)                     # Event code 33 = ClientMessage
    movb $32, 1(%rdi)                    # Format = 32-bit
    movw $0, 2(%rdi)
    mov win_id(%rip), %eax
    mov %eax, 4(%rdi)                    # Subject window
    mov atom_net_move(%rip), %eax
    mov %eax, 8(%rdi)                    # Message type: _NET_WM_MOVERESIZE
    # Mouse root coordinates from trigger event
    movzwl ev_packet+20(%rip), %eax
    mov %eax, 12(%rdi)                   # root_x
    movzwl ev_packet+22(%rip), %eax
    mov %eax, 16(%rdi)                   # root_y
    movl $8, 20(%rdi)                    # Action: _NET_WM_MOVERESIZE_MOVE (8)
    movl $1, 24(%rdi)                    # Button 1
    movl $1, 28(%rdi)                    # Source indication = Normal application

    # Send SendEvent request
    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $44, %rdx
    syscall
    add $64, %rsp
.drag_ret:
    ret

# ==============================================================================
# Graphics Rendering Engine
# ==============================================================================

# ------------------------------------------------------------------------------
# draw_rect:
# Draws a solid filled rectangle into the 32-bit ARGB framebuffer.
#
# Calling Convention:
#   Inputs: %edi = x, %esi = y, %edx = width, %ecx = height, %r8d = color
#   Scratch: %rax, %rcx, %rdi
# ------------------------------------------------------------------------------
draw_rect:
    push %r12
    push %r13
    push %r14
    mov %edi, %r12d                      # %r12d = x
    mov %esi, %r13d                      # %r13d = current y
    mov %edx, %r14d                      # %r14d = width
.dr_loop:
    test %ecx, %ecx
    jle .dr_done
    push %rcx
    # Calculate row start: fb_ptr + 4 * (y * WIN_W + x)
    mov %r13d, %eax
    imul $WIN_W, %eax
    add %r12d, %eax
    shl $2, %rax
    add fb_ptr(%rip), %rax
    mov %rax, %rdi
    mov %r8d, %eax                       # %eax = 32-bit fill color
    mov %r14d, %ecx                      # %ecx = number of pixels
    rep stosl                            # Fast fill dwords
    pop %rcx
    inc %r13d
    dec %ecx
    jmp .dr_loop
.dr_done:
    pop %r14
    pop %r13
    pop %r12
    ret

# ------------------------------------------------------------------------------
# draw_squircle:
# Rasterizes a rounded rectangle with circular corners of radius 'r' and a 1px border.
#
# Calling Convention:
#   Inputs: %edi = x, %esi = y, %edx = width, %ecx = height
#           %r8d = fill_color, %r9d = border_color
#           16(%rbp) = corner radius (passed on stack)
#
# Algorithm:
#   1. Clamps radius r to min(w/2, h/2).
#   2. Calculates squared thresholds: r_sq = r * r, r_in_sq = (r - 1)^2.
#   3. For each pixel (px, py):
#      - Computes distance cx to horizontal corner curve, cy to vertical curve.
#      - If inside corner bounding square:
#          d2 = cx^2 + cy^2
#          If d2 > r_sq: pixel is outside squircle (transparent/skipped).
#          Else if d2 >= r_in_sq: pixel is on corner border -> writes border_color.
#          Else: pixel is inside -> writes fill_color.
#      - If in straight region:
#          If on outer perimeter (px=0, py=0, px=w-1, py=h-1): writes border_color.
#          Else: writes fill_color.
#   4. Fully clipped against window dimensions (WIN_W, WIN_H).
# ------------------------------------------------------------------------------
draw_squircle:
    push %rbp
    mov %rsp, %rbp
    sub $96, %rsp
    mov %r12, -8(%rbp)                   # Callee-saved register storage
    mov %r13, -16(%rbp)
    mov %r14, -24(%rbp)
    mov %r15, -32(%rbp)
    mov %rbx, -40(%rbp)

    mov %edi, %r12d                      # %r12d = x
    mov %esi, %r13d                      # %r13d = y
    mov %edx, %r14d                      # %r14d = w
    mov %ecx, %r15d                      # %r15d = h
    mov 16(%rbp), %ebx                   # %ebx  = radius r

    mov %r8d, -48(%rbp)                  # Local: fill color
    mov %r9d, -56(%rbp)                  # Local: border color

    test %r14d, %r14d
    jle .sq_done
    test %r15d, %r15d
    jle .sq_done

    test %ebx, %ebx
    jle .sq_fallback                     # If r <= 0, fallback to draw_rect

    # Clamp radius to min(w / 2, h / 2)
    mov %r14d, %eax
    shr $1, %eax
    cmp %eax, %ebx
    cmovg %eax, %ebx
    mov %r15d, %eax
    shr $1, %eax
    cmp %eax, %ebx
    cmovg %eax, %ebx

    # Compute squared outer radius: r_sq = r * r
    mov %ebx, %eax
    imul %ebx, %eax
    mov %eax, -64(%rbp)

    # Compute squared inner radius: r_in_sq = (r - 1) * (r - 1)
    lea -1(%ebx), %eax
    imul %eax, %eax
    mov %eax, -72(%rbp)

    xor %r11d, %r11d                     # %r11d = py (0..h-1)
.sq_row_loop:
    cmp %r15d, %r11d
    jge .sq_done

    mov %r13d, %eax
    add %r11d, %eax                      # screen_y = y + py
    cmp $WIN_H, %eax
    jge .sq_row_next                     # Clip against window height
    test %eax, %eax
    jl .sq_row_next

    # Calculate corner distance cy:
    # If py < r: cy = r - 1 - py
    # Else if py >= h - r: cy = py - (h - r)
    # Else: cy = 0 (straight edge)
    xor %esi, %esi
    cmp %ebx, %r11d
    jge .sq_chk_by
    mov %ebx, %esi
    sub $1, %esi
    sub %r11d, %esi
    jmp .sq_got_cy
.sq_chk_by:
    mov %r15d, %edx
    sub %ebx, %edx                       # h - r
    cmp %edx, %r11d
    jl .sq_got_cy
    mov %r11d, %esi
    sub %edx, %esi                       # py - (h - r)
.sq_got_cy:
    mov %esi, -80(%rbp)                  # Store cy

    # Base framebuffer pointer for this row: fb_ptr + 4 * (screen_y * WIN_W + x)
    imul $WIN_W, %eax
    add %r12d, %eax
    shl $2, %rax
    add fb_ptr(%rip), %rax
    mov %rax, %rcx                       # %rcx = pixel write pointer

    xor %r10d, %r10d                     # %r10d = px (0..w-1)
.sq_col_loop:
    cmp %r14d, %r10d
    jge .sq_row_next

    mov %r12d, %eax
    add %r10d, %eax                      # screen_x = x + px
    cmp $WIN_W, %eax
    jge .sq_col_skip                     # Clip against window width
    test %eax, %eax
    jl .sq_col_skip

    # Calculate corner distance cx:
    # If px < r: cx = r - 1 - px
    # Else if px >= w - r: cx = px - (w - r)
    # Else: cx = 0
    xor %edi, %edi
    cmp %ebx, %r10d
    jge .sq_chk_rx
    mov %ebx, %edi
    sub $1, %edi
    sub %r10d, %edi
    jmp .sq_eval_pixel
.sq_chk_rx:
    mov %r14d, %edx
    sub %ebx, %edx                       # w - r
    cmp %edx, %r10d
    jl .sq_eval_pixel
    mov %r10d, %edi
    sub %edx, %edi                       # px - (w - r)

.sq_eval_pixel:
    mov -80(%rbp), %esi                  # Restore cy
    test %edi, %edi
    jz .sq_straight                      # cx == 0 -> straight segment
    test %esi, %esi
    jz .sq_straight                      # cy == 0 -> straight segment

    # Corner pixel: evaluate squared Euclidean distance d2 = cx^2 + cy^2
    mov %edi, %eax
    imul %edi, %eax                      # cx^2
    mov %esi, %edx
    imul %esi, %edx                      # cy^2
    add %edx, %eax                       # d2 = cx^2 + cy^2

    cmp -64(%rbp), %eax                  # d2 > r_sq ?
    jg .sq_col_skip                      # Outside corner circle: transparent/skip

    cmp -72(%rbp), %eax                  # d2 >= r_in_sq ?
    jge .sq_write_border                 # In 1px border zone
    jmp .sq_write_fill                   # Inside corner

.sq_straight:
    # Straight segment border check (outer 1px perimeter)
    test %r10d, %r10d                    # px == 0
    jz .sq_write_border
    mov %r14d, %eax
    dec %eax
    cmp %eax, %r10d                      # px == w - 1
    je .sq_write_border

    test %r11d, %r11d                    # py == 0
    jz .sq_write_border
    mov %r15d, %eax
    dec %eax
    cmp %eax, %r11d                      # py == h - 1
    je .sq_write_border

.sq_write_fill:
    mov -48(%rbp), %eax
    mov %eax, (%rcx)                     # Write fill color
    jmp .sq_col_skip

.sq_write_border:
    mov -56(%rbp), %eax
    mov %eax, (%rcx)                     # Write border color

.sq_col_skip:
    add $4, %rcx                         # Advance pixel pointer
    inc %r10d
    jmp .sq_col_loop

.sq_row_next:
    inc %r11d
    jmp .sq_row_loop

.sq_fallback:
    # Fallback to rectangular fill if r <= 0
    mov %r12d, %edi
    mov %r13d, %esi
    mov %r14d, %edx
    mov %r15d, %ecx
    mov -48(%rbp), %r8d
    call draw_rect

.sq_done:
    mov -8(%rbp), %r12
    mov -16(%rbp), %r13
    mov -24(%rbp), %r14
    mov -32(%rbp), %r15
    mov -40(%rbp), %rbx
    leave
    ret

# ------------------------------------------------------------------------------
# draw_glyph:
# Renders an 8x16 1-bit bitmap font glyph into the framebuffer.
#
# Calling Convention:
#   Inputs: %edi = x, %esi = y, %edx = glyph_id/ascii, %r8d = color, %r9d = scale
#
# Features:
#   - Supports arbitrary integer scaling (e.g. 1x, 2x) by stretching each font
#     bit into a (scale x scale) block of pixels.
#   - Boundary clipping: guarantees no pixel writes outside [0..WIN_W-1, 0..WIN_H-1].
# ------------------------------------------------------------------------------
draw_glyph:
    push %rbp
    mov %rsp, %rbp
    sub $80, %rsp
    mov %r12, -8(%rbp)                   # Save callee-saved registers
    mov %r13, -16(%rbp)
    mov %r14, -24(%rbp)
    mov %r15, -32(%rbp)
    mov %rbx, -40(%rbp)

    mov %edi, %r12d                      # %r12d = x
    mov %esi, %r13d                      # %r13d = y
    mov %r8d, -48(%rbp)                  # Local: color
    mov %r9d, -56(%rbp)                  # Local: integer scale

    # Validate glyph ID: font covers glyphs 32 to 136 (105 glyphs total)
    sub $32, %edx
    cmp $106, %edx
    jge .dg_ret
    test %edx, %edx
    jl .dg_ret

    # Glyph data offset = glyph_index * 16 bytes
    shl $4, %rdx
    lea font_data(%rip), %rax
    add %rdx, %rax
    mov %rax, %r14                       # %r14 = pointer to 16-byte glyph bitmap

    xor %r15d, %r15d                     # %r15d = font row index (0..15)
.dg_row_loop:
    cmp $16, %r15d
    jge .dg_ret
    movzbq (%r14, %r15), %rbx            # Read 8-bit row byte (MSB = leftmost pixel)

    xor %ecx, %ecx                       # %ecx = font column index (0..7)
.dg_col_loop:
    cmp $8, %ecx
    jge .dg_row_next
    mov $7, %edx
    sub %ecx, %edx                       # Bit index: 7 - col
    bt %rdx, %rbx                        # Test if pixel bit is set
    jnc .dg_col_next

    # Active pixel bit! Compute top-left corner of the scaled pixel block
    mov -56(%rbp), %eax
    imul %ecx, %eax
    add %r12d, %eax
    mov %eax, -64(%rbp)                  # base_x = x + col * scale

    mov -56(%rbp), %eax
    imul %r15d, %eax
    add %r13d, %eax
    mov %eax, -72(%rbp)                  # base_y = y + row * scale

    # Render (scale x scale) block of pixels
    xor %edx, %edx                       # sy = 0..scale-1
.dg_sy_loop:
    cmp -56(%rbp), %edx
    jge .dg_col_next

    mov -72(%rbp), %eax
    add %edx, %eax                       # py = base_y + sy
    cmp $WIN_H, %eax                     # Clip against window height
    jge .dg_sy_next
    test %eax, %eax
    jl .dg_sy_next

    imul $WIN_W, %eax
    mov %eax, %esi

    xor %edi, %edi                       # sx = 0..scale-1
.dg_sx_loop:
    cmp -56(%rbp), %edi
    jge .dg_sy_next

    mov -64(%rbp), %eax
    add %edi, %eax                       # px = base_x + sx
    cmp $WIN_W, %eax                     # Clip against window width
    jge .dg_sx_next
    test %eax, %eax
    jl .dg_sx_next

    add %esi, %eax
    shl $2, %rax
    add fb_ptr(%rip), %rax               # Framebuffer target address
    mov -48(%rbp), %r8d
    mov %r8d, (%rax)                     # Write 32-bit pixel color

.dg_sx_next:
    inc %edi
    jmp .dg_sx_loop

.dg_sy_next:
    inc %edx
    jmp .dg_sy_loop

.dg_col_next:
    inc %ecx
    jmp .dg_col_loop

.dg_row_next:
    inc %r15d
    jmp .dg_row_loop

.dg_ret:
    mov -8(%rbp), %r12
    mov -16(%rbp), %r13
    mov -24(%rbp), %r14
    mov -32(%rbp), %r15
    mov -40(%rbp), %rbx
    leave
    ret

# ------------------------------------------------------------------------------
# draw_string:
# Renders a null-terminated ASCII string into the framebuffer.
#
# Calling Convention:
#   Inputs: %edi = x, %esi = y, %rdx = string_ptr, %r8d = color, %r9d = scale
# ------------------------------------------------------------------------------
draw_string:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13
    push %r14
    push %r15
    push %rbx

    mov %edi, %r12d                      # %r12d = current x
    mov %esi, %r13d                      # %r13d = current y
    mov %rdx, %r14                       # %r14  = string pointer
    mov %r8d, %ebx                       # %ebx  = color
    mov %r9d, %r15d                      # %r15d = scale

.ds_loop:
    movzbq (%r14), %rdx                  # Read next character
    test %dl, %dl
    jz .ds_done

    mov %r12d, %edi
    mov %r13d, %esi
    mov %ebx, %r8d
    mov %r15d, %r9d
    call draw_glyph                      # Render single glyph

    # Advance horizontal cursor by (8 * scale) pixels
    mov $8, %eax
    imul %r15d, %eax
    add %eax, %r12d
    inc %r14
    jmp .ds_loop

.ds_done:
    pop %rbx
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    leave
    ret

# ==============================================================================
# UI Component Renderers
# ==============================================================================

# ------------------------------------------------------------------------------
# render_ui:
# Master compositor for all UI elements:
#   1. Clears outer canvas to 0 (corners transparent).
#   2. Renders window background card with 18px squircle corners.
#   3. Renders HeaderBar: separator line, hamburger menu button, mode title, close button.
#   4. Renders Inset Display Card: 14px squircle card with history, input or programmer bases.
#   5. Renders active keypad grid (Basic, Scientific, or Programmer).
#   6. Renders popover dropdown menu (if menu_open == 1).
# ------------------------------------------------------------------------------
render_ui:
    push %rbp
    mov %rsp, %rbp

    # 1. Clear outer canvas to 0 (transparent outside rounded window boundary)
    mov fb_ptr(%rip), %rdi
    xor %eax, %eax
    mov $WIN_W * WIN_H, %ecx
    rep stosl

    # 2. Window background card with 18px rounded corners
    mov $0, %edi
    mov $0, %esi
    mov $WIN_W, %edx
    mov $WIN_H, %ecx
    mov $COL_BG, %r8d
    mov $0x383838, %r9d                  # Subtle outer border
    sub $8, %rsp
    movq $18, (%rsp)                     # Radius 18px
    call draw_squircle
    add $8, %rsp

    # 3. HeaderBar Separator Line at y=50
    mov $0, %edi
    mov $50, %esi
    mov $WIN_W, %edx
    mov $1, %ecx
    mov $COL_SEP, %r8d
    call draw_rect

    # 4. Hamburger Menu Button (x=12, y=8, w=36, h=34, r=10)
    mov $12, %edi
    mov $8, %esi
    mov $36, %edx
    mov $34, %ecx
    mov $COL_BTN_IDLE, %r8d
    mov $COL_BTN_BORDER, %r9d
    sub $8, %rsp
    movq $10, (%rsp)
    call draw_squircle
    add $8, %rsp

    # Draw '≡' icon (Glyph 127) inside hamburger button
    mov $22, %edi
    mov $17, %esi
    mov $127, %edx
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_glyph

    # 5. HeaderBar Mode Title
    lea str_basic_title(%rip), %rdx
    mov curr_mode(%rip), %eax
    cmp $1, %eax
    je .t_adv
    cmp $2, %eax
    je .t_prog
    jmp .t_draw
.t_adv:
    lea str_adv_title(%rip), %rdx
    jmp .t_draw
.t_prog:
    lea str_prog_title(%rip), %rdx
.t_draw:
    mov $130, %edi
    mov $17, %esi
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_string

    # 5. History Button (x=328, y=8, w=36, h=34, r=10)
    mov $328, %edi
    mov $8, %esi
    mov $36, %edx
    mov $34, %ecx
    mov $COL_BTN_IDLE, %r8d
    cmpl $1, history_open(%rip)
    jne .hb_idle
    mov $COL_ACCENT, %r8d
.hb_idle:
    mov $COL_BTN_BORDER, %r9d
    sub $8, %rsp
    movq $10, (%rsp)
    call draw_squircle
    add $8, %rsp

    # Clock icon (Glyph 136) at x=342, y=17
    mov $342, %edi
    mov $17, %esi
    mov $136, %edx
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_glyph

    # 6. Window Close Button (x=372, y=8, w=36, h=34, r=17 circle)
    mov $372, %edi
    mov $8, %esi
    mov $36, %edx
    mov $34, %ecx
    mov $COL_BTN_IDLE, %r8d
    mov $COL_BTN_BORDER, %r9d
    sub $8, %rsp
    movq $17, (%rsp)                     # Circular button: r = 17
    call draw_squircle
    add $8, %rsp

    # Draw 'x' icon inside close button
    mov $386, %edi
    mov $17, %esi
    mov $'x', %edx
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_glyph

    # 7. Inset Display Card (x=16, y=62, w=388, h=140, r=14)
    mov $16, %edi
    mov $62, %esi
    mov $388, %edx
    mov $140, %ecx
    mov $COL_CARD_BG, %r8d
    mov $COL_CARD_BORDER, %r9d
    sub $8, %rsp
    movq $14, (%rsp)                     # Radius 14px
    call draw_squircle
    add $8, %rsp

    # Render inside Display Card based on Mode
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    je .render_disp_prog

    # --- Basic / Scientific Mode Display ---
    # History expression at y=78 (1x scale, secondary color)
    mov $32, %edi
    mov $78, %esi
    lea hist_buf(%rip), %rdx
    mov $COL_TEXT_SEC, %r8d
    mov $1, %r9d
    call draw_string

    # Main active input string at y=136 (2x scale, right-aligned)
    lea disp_buf(%rip), %rdx
    xor %rcx, %rcx
.len_loop:
    cmpb $0, (%rdx, %rcx)
    jz .len_done
    inc %rcx
    jmp .len_loop
.len_done:
    shl $4, %rcx                         # Width = len * (8 * scale 2) = len * 16
    mov $384, %edi                       # Right boundary anchor
    sub %ecx, %edi
    cmp $32, %edi
    jge .x_ok
    mov $32, %edi                        # Left clamp
.x_ok:
    mov $136, %esi
    lea disp_buf(%rip), %rdx
    mov $COL_TEXT_PRI, %r8d
    mov $2, %r9d                         # 2x enlarged scale
    call draw_string
    jmp .render_keypad

.render_disp_prog:
    # --- Programming Mode Live 4-Base Inspector ---
    # Active input at y=72 (2x scale)
    mov $32, %edi
    mov $72, %esi
    lea disp_buf(%rip), %rdx
    mov $COL_TEXT_PRI, %r8d
    mov $2, %r9d
    call draw_string

    # HEX readout row at y=114
    mov $32, %edi
    mov $114, %esi
    lea str_hex_lbl(%rip), %rdx
    mov $COL_TEXT_SEC, %r8d
    mov curr_base(%rip), %eax
    cmp $0, %eax
    jne .h1
    mov $COL_ACCENT, %r8d                # Highlight active base in accent blue
.h1:
    mov $1, %r9d
    call draw_string

    mov $74, %edi
    mov $114, %esi
    lea hex_buf(%rip), %rdx
    call draw_string

    # DEC readout row at y=134
    mov $32, %edi
    mov $134, %esi
    lea str_dec_lbl(%rip), %rdx
    mov $COL_TEXT_SEC, %r8d
    mov curr_base(%rip), %eax
    cmp $1, %eax
    jne .h2
    mov $COL_ACCENT, %r8d
.h2:
    mov $1, %r9d
    call draw_string

    mov $74, %edi
    mov $134, %esi
    lea dec_buf(%rip), %rdx
    call draw_string

    # OCT readout row at y=154
    mov $32, %edi
    mov $154, %esi
    lea str_oct_lbl(%rip), %rdx
    mov $COL_TEXT_SEC, %r8d
    mov curr_base(%rip), %eax
    cmp $2, %eax
    jne .h3
    mov $COL_ACCENT, %r8d
.h3:
    mov $1, %r9d
    call draw_string

    mov $74, %edi
    mov $154, %esi
    lea oct_buf(%rip), %rdx
    call draw_string

    # BIN readout row at y=174
    mov $32, %edi
    mov $174, %esi
    lea str_bin_lbl(%rip), %rdx
    mov $COL_TEXT_SEC, %r8d
    mov curr_base(%rip), %eax
    cmp $3, %eax
    jne .h4
    mov $COL_ACCENT, %r8d
.h4:
    mov $1, %r9d
    call draw_string

    mov $74, %edi
    mov $174, %esi
    lea bin_buf(%rip), %rdx
    call draw_string

.render_keypad:
    # 8. Render Keypad Grid based on Mode
    mov curr_mode(%rip), %eax
    cmp $1, %eax
    je .draw_adv_keys
    cmp $2, %eax
    je .draw_prog_keys

    call render_basic_keys
    jmp .check_popover

.draw_adv_keys:
    call render_adv_keys
    jmp .check_popover

.draw_prog_keys:
    call render_prog_keys

.check_popover:
    # 9. Render Popovers if open
    mov history_open(%rip), %eax
    test %eax, %eax
    jz .chk_m_pop
    call render_history_popover

.chk_m_pop:
    mov menu_open(%rip), %eax
    test %eax, %eax
    jz .ui_done
    call render_popover

.ui_done:
    leave
    ret

# ------------------------------------------------------------------------------
# render_basic_keys:
# Renders 4 columns x 5 rows keypad buttons for Basic Mode.
# Button geometry: width = 89px, height = 80px, radius = 14px.
# Centers 2x enlarged bold glyphs inside each button.
# ------------------------------------------------------------------------------
render_basic_keys:
    push %rbp
    mov %rsp, %rbp
    sub $32, %rsp

    xor %r12d, %r12d                     # %r12d = key index (0..19)
.bk_loop:
    cmp $20, %r12d
    jge .bk_done

    # Calculate row and column: row = index / 4, col = index % 4
    mov %r12d, %eax
    xor %edx, %edx
    mov $4, %ecx
    div %ecx
    mov %eax, %r13d                      # %r13d = row
    mov %edx, %r14d                      # %r14d = col

    # Button coordinates: x = 16 + col * 99, y = 216 + row * 90
    imul $99, %r14d, %edi
    add $16, %edi
    imul $90, %r13d, %esi
    add $216, %esi
    mov $89, %edx                        # Button width = 89
    mov $80, %ecx                        # Button height = 80

    # Color selection: Clear is Red (COL_DEST), Operators are Accent Blue, rest Idle
    mov $COL_BTN_IDLE, %r8d
    mov $COL_BTN_BORDER, %r9d
    cmp $0, %r12d
    jne .b_not_c
    mov $COL_DEST, %r8d                  # 'C' button is destructive red
    jmp .b_color_ok
.b_not_c:
    cmp $19, %r12d                       # '=' button
    je .b_is_acc
    cmp $3, %r12d                        # '÷' button
    je .b_is_acc
    cmp $7, %r12d                        # '×' button
    je .b_is_acc
    cmp $11, %r12d                       # '-' button
    je .b_is_acc
    cmp $15, %r12d                       # '+' button
    je .b_is_acc
    jmp .b_color_ok
.b_is_acc:
    mov $COL_ACCENT, %r8d                # Operators are accent blue
.b_color_ok:
    push %rdi
    push %rsi
    sub $8, %rsp
    movq $14, (%rsp)                     # Button corner radius = 14px
    call draw_squircle
    add $8, %rsp
    pop %rsi
    pop %rdi

    # Render centered glyph at 2x scale (+36, +24)
    lea basic_key_labels(%rip), %rax
    movzbq (%rax, %r12), %rdx
    lea 36(%rdi), %edi
    lea 28(%rsi), %esi
    mov $COL_TEXT_PRI, %r8d
    mov $2, %r9d                         # 2x enlarged scale
    call draw_glyph

    inc %r12d
    jmp .bk_loop

.bk_done:
    leave
    ret

# ------------------------------------------------------------------------------
# render_adv_keys:
# Renders 5 columns x 6 rows keypad buttons for Scientific Mode.
# Button geometry: width = 71px, height = 66px, radius = 12px.
# ------------------------------------------------------------------------------
render_adv_keys:
    push %rbp
    mov %rsp, %rbp

    xor %r12d, %r12d                     # %r12d = key index (0..29)
.ak_loop:
    cmp $30, %r12d
    jge .ak_done

    # row = index / 5, col = index % 5
    mov %r12d, %eax
    xor %edx, %edx
    mov $5, %ecx
    div %ecx
    mov %eax, %r13d                      # %r13d = row
    mov %edx, %r14d                      # %r14d = col

    # Coordinates: x = 16 + col * 79, y = 216 + row * 74
    imul $79, %r14d, %edi
    add $16, %edi
    imul $74, %r13d, %esi
    add $216, %esi
    mov $71, %edx                        # Button width = 71
    mov $66, %ecx                        # Button height = 66

    mov $COL_BTN_IDLE, %r8d
    mov $COL_BTN_BORDER, %r9d

    cmp $1, %r12d                        # 'C' button
    jne .ak_not_c
    mov $COL_DEST, %r8d
    jmp .ak_col_ok
.ak_not_c:
    cmp $4, %r12d                        # '÷'
    je .ak_is_acc
    cmp $9, %r12d                        # '×'
    je .ak_is_acc
    cmp $14, %r12d                       # '-'
    je .ak_is_acc
    cmp $19, %r12d                       # '+'
    je .ak_is_acc
    cmp $24, %r12d                       # '='
    je .ak_is_acc
    jmp .ak_col_ok
.ak_is_acc:
    mov $COL_ACCENT, %r8d
.ak_col_ok:
    push %rdi
    push %rsi
    sub $8, %rsp
    movq $12, (%rsp)                     # Button corner radius = 12px
    call draw_squircle
    add $8, %rsp
    pop %rsi
    pop %rdi

    # Render centered glyph at 2x scale (+27, +17)
    lea adv_key_types(%rip), %rax
    movzbq (%rax, %r12), %rbx

    lea 27(%rdi), %edi
    lea 21(%rsi), %esi
    mov %ebx, %edx
    mov $COL_TEXT_PRI, %r8d
    mov $2, %r9d
    call draw_glyph

    inc %r12d
    jmp .ak_loop

.ak_done:
    leave
    ret

# ------------------------------------------------------------------------------
# render_prog_keys:
# Renders 5 columns x 6 rows keypad buttons for Programmer Mode.
# Button geometry: width = 71px, height = 66px, radius = 12px.
# ------------------------------------------------------------------------------
render_prog_keys:
    push %rbp
    mov %rsp, %rbp

    xor %r12d, %r12d                     # %r12d = key index (0..29)
.pk_loop:
    cmp $30, %r12d
    jge .pk_done

    mov %r12d, %eax
    xor %edx, %edx
    mov $5, %ecx
    div %ecx
    mov %eax, %r13d
    mov %edx, %r14d

    imul $79, %r14d, %edi
    add $16, %edi
    imul $74, %r13d, %esi
    add $216, %esi
    mov $71, %edx
    mov $66, %ecx

    mov $COL_BTN_IDLE, %r8d
    mov $COL_BTN_BORDER, %r9d

    cmp $4, %r12d                        # 'C' button
    jne .pk_not_c
    mov $COL_DEST, %r8d
    jmp .pk_col_ok
.pk_not_c:
    cmp $14, %r12d                       # '÷'
    je .pk_is_acc
    cmp $19, %r12d                       # '×'
    je .pk_is_acc
    cmp $24, %r12d                       # '-'
    je .pk_is_acc
    cmp $27, %r12d                       # '='
    je .pk_is_acc
    cmp $29, %r12d                       # '+'
    je .pk_is_acc
    jmp .pk_col_ok
.pk_is_acc:
    mov $COL_ACCENT, %r8d
.pk_col_ok:
    push %rdi
    push %rsi
    sub $8, %rsp
    movq $12, (%rsp)                     # Button corner radius = 12px
    call draw_squircle
    add $8, %rsp
    pop %rsi
    pop %rdi

    # Render centered glyph at 2x scale (+27, +17)
    lea prog_key_types(%rip), %rax
    movzbq (%rax, %r12), %rbx

    lea 27(%rdi), %edi
    lea 21(%rsi), %esi
    mov %ebx, %edx
    mov $COL_TEXT_PRI, %r8d
    mov $2, %r9d
    call draw_glyph

    inc %r12d
    jmp .pk_loop

.pk_done:
    leave
    ret

# ------------------------------------------------------------------------------
# render_popover:
# Renders the dropdown popover menu card for mode switching and history clearing.
# Card geometry: x=12, y=52, w=230, h=176, radius=14px.
# Items:
#   Item 0: Basic Mode       (radio dot + label)
#   Item 1: Scientific Mode  (radio dot + label)
#   Item 2: Programming Mode (radio dot + label)
#   Separator line at y=172
#   Item 3: Clear History    (destructive red text)
# ------------------------------------------------------------------------------
render_popover:
    push %rbp
    mov %rsp, %rbp

    # Card background (x=12, y=52, w=230, h=176, r=14)
    mov $12, %edi
    mov $52, %esi
    mov $230, %edx
    mov $176, %ecx
    mov $COL_POPOVER_BG, %r8d
    mov $COL_POPOVER_BRD, %r9d
    sub $8, %rsp
    movq $14, (%rsp)                     # Popover card radius = 14px
    call draw_squircle
    add $8, %rsp

    # Item 0: Basic Mode (hover highlight with r=8)
    cmpl $0, hover_menu(%rip)
    jne .m0_nh
    mov $16, %edi
    mov $56, %esi
    mov $222, %edx
    mov $36, %ecx
    mov $COL_POPOVER_HOV, %r8d
    mov $COL_POPOVER_HOV, %r9d
    sub $8, %rsp
    movq $8, (%rsp)
    call draw_squircle
    add $8, %rsp
.m0_nh:

    # Radio bullet: Glyph 134 (filled bullet ●) if active, 135 (open circle ○) otherwise
    mov $135, %edx
    mov curr_mode(%rip), %eax
    cmp $0, %eax
    jne .m0_r
    mov $134, %edx
.m0_r:
    mov $24, %edi
    mov $66, %esi
    mov $COL_ACCENT, %r8d
    mov $1, %r9d
    call draw_glyph

    mov $40, %edi
    mov $66, %esi
    lea str_menu_basic(%rip), %rdx
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_string

    # Item 1: Advanced Mode
    cmpl $1, hover_menu(%rip)
    jne .m1_nh
    mov $16, %edi
    mov $94, %esi
    mov $222, %edx
    mov $36, %ecx
    mov $COL_POPOVER_HOV, %r8d
    mov $COL_POPOVER_HOV, %r9d
    sub $8, %rsp
    movq $8, (%rsp)
    call draw_squircle
    add $8, %rsp
.m1_nh:

    mov $135, %edx
    mov curr_mode(%rip), %eax
    cmp $1, %eax
    jne .m1_r
    mov $134, %edx
.m1_r:
    mov $24, %edi
    mov $104, %esi
    mov $COL_ACCENT, %r8d
    mov $1, %r9d
    call draw_glyph

    mov $40, %edi
    mov $104, %esi
    lea str_menu_adv(%rip), %rdx
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_string

    # Item 2: Programming Mode
    cmpl $2, hover_menu(%rip)
    jne .m2_nh
    mov $16, %edi
    mov $132, %esi
    mov $222, %edx
    mov $36, %ecx
    mov $COL_POPOVER_HOV, %r8d
    mov $COL_POPOVER_HOV, %r9d
    sub $8, %rsp
    movq $8, (%rsp)
    call draw_squircle
    add $8, %rsp
.m2_nh:

    mov $135, %edx
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    jne .m2_r
    mov $134, %edx
.m2_r:
    mov $24, %edi
    mov $142, %esi
    mov $COL_ACCENT, %r8d
    mov $1, %r9d
    call draw_glyph

    mov $40, %edi
    mov $142, %esi
    lea str_menu_prog(%rip), %rdx
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_string

    # Popover Separator Line at y=172
    mov $20, %edi
    mov $172, %esi
    mov $214, %edx
    mov $1, %ecx
    mov $COL_POPOVER_BRD, %r8d
    call draw_rect

    # Item 3: Clear History
    cmpl $3, hover_menu(%rip)
    jne .m3_nh
    mov $16, %edi
    mov $178, %esi
    mov $222, %edx
    mov $36, %ecx
    mov $COL_POPOVER_HOV, %r8d
    mov $COL_POPOVER_HOV, %r9d
    sub $8, %rsp
    movq $8, (%rsp)
    call draw_squircle
    add $8, %rsp
.m3_nh:

    mov $40, %edi
    mov $188, %esi
    lea str_menu_clear(%rip), %rdx
    mov $COL_DEST, %r8d                 # Red text for destructive action
    mov $1, %r9d
    call draw_string

    leave
    ret

# ==============================================================================
# Calculation History Management & Rendering
# ==============================================================================

# ------------------------------------------------------------------------------
# commit_history:
# Records a completed calculation into the history journal.
# Reads current hist_buf (expression) and disp_buf (result).
# Shifts existing entries down by 1, inserts new entry at index 0.
# ------------------------------------------------------------------------------
commit_history:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13

    # If hist_buf is empty, do not record
    cmpb $0, hist_buf(%rip)
    jz .ch_done

    # Increment count if less than 8
    mov history_count(%rip), %eax
    cmp $8, %eax
    jge .ch_shift
    inc %eax
    mov %eax, history_count(%rip)

.ch_shift:
    # Shift existing entries down from 7 to 1
    mov $7, %ecx
.ch_s_loop:
    cmp $0, %ecx
    jle .ch_insert
    mov %ecx, %eax
    shl $6, %rax                         # i * 64
    lea history_entries(%rip), %rdi
    add %rax, %rdi                       # &history_entries[i]

    mov %ecx, %edx
    dec %edx
    shl $6, %rdx
    lea history_entries(%rip), %rsi
    add %rdx, %rsi                       # &history_entries[i-1]

    push %rcx
    mov $16, %ecx                        # 64 bytes = 16 dwords
    rep movsl
    pop %rcx

    dec %ecx
    jmp .ch_s_loop

.ch_insert:
    # Copy hist_buf into history_entries[0].expr (offset 0..31)
    lea history_entries(%rip), %rdi
    lea hist_buf(%rip), %rsi
    mov $31, %ecx
.ch_cp_expr:
    movb (%rsi), %al
    movb %al, (%rdi)
    test %al, %al
    jz .ch_expr_done
    inc %rsi
    inc %rdi
    dec %ecx
    jnz .ch_cp_expr
    movb $0, (%rdi)
.ch_expr_done:

    # Copy disp_buf into history_entries[0].res (offset 32..63)
    lea history_entries+32(%rip), %rdi
    lea disp_buf(%rip), %rsi
    mov $31, %ecx
.ch_cp_res:
    movb (%rsi), %al
    movb %al, (%rdi)
    test %al, %al
    jz .ch_res_done
    inc %rsi
    inc %rdi
    dec %ecx
    jnz .ch_cp_res
    movb $0, (%rdi)
.ch_res_done:
    movl $1, dirty(%rip)

.ch_done:
    pop %r13
    pop %r12
    leave
    ret

# ------------------------------------------------------------------------------
# clear_history:
# Empties all history journal entries and clears display history line.
# ------------------------------------------------------------------------------
clear_history:
    movl $0, history_count(%rip)
    movl $-1, history_hover(%rip)
    movb $0, hist_buf(%rip)
    movl $1, dirty(%rip)
    ret

# ------------------------------------------------------------------------------
# render_history_popover:
# Renders the modern Libadwaita History Popover card.
# Card: x=44, y=52, w=364, h=310, radius=14px.
# ------------------------------------------------------------------------------
render_history_popover:
    push %rbp
    mov %rsp, %rbp
    sub $32, %rsp

    # Card background (x=44, y=52, w=364, h=310, r=14)
    mov $44, %edi
    mov $52, %esi
    mov $364, %edx
    mov $310, %ecx
    mov $COL_POPOVER_BG, %r8d
    mov $COL_POPOVER_BRD, %r9d
    sub $8, %rsp
    movq $14, (%rsp)
    call draw_squircle
    add $8, %rsp

    # Header Title at x=64, y=66
    mov $64, %edi
    mov $66, %esi
    lea str_hist_title(%rip), %rdx
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_string

    # Header Separator at y=88
    mov $56, %edi
    mov $88, %esi
    mov $340, %edx
    mov $1, %ecx
    mov $COL_SEP, %r8d
    call draw_rect

    # Empty check
    mov history_count(%rip), %eax
    test %eax, %eax
    jnz .rhp_has_items

    mov $164, %edi
    mov $160, %esi
    lea str_hist_empty(%rip), %rdx
    mov $COL_TEXT_SEC, %r8d
    mov $1, %r9d
    call draw_string
    jmp .rhp_bottom

.rhp_has_items:
    xor %r12d, %r12d                     # %r12d = item index
.rhp_loop:
    cmp history_count(%rip), %r12d
    jge .rhp_bottom
    cmp $4, %r12d                        # Max 4 items shown on page
    jge .rhp_bottom

    # item_y = 94 + r12d * 42
    mov %r12d, %eax
    imul $42, %eax
    add $94, %eax
    mov %eax, %r13d

    # Hover check
    cmp history_hover(%rip), %r12d
    jne .rhp_no_hov
    mov $52, %edi
    mov %r13d, %esi
    mov $348, %edx
    mov $38, %ecx
    mov $COL_POPOVER_HOV, %r8d
    mov $COL_POPOVER_HOV, %r9d
    sub $8, %rsp
    movq $8, (%rsp)
    call draw_squircle
    add $8, %rsp
.rhp_no_hov:

    # Expression at item_y + 4 (scale 1, secondary color)
    mov $64, %edi
    lea 4(%r13), %esi
    mov %r12d, %eax
    shl $6, %rax
    lea history_entries(%rip), %rdx
    add %rax, %rdx
    mov $COL_TEXT_SEC, %r8d
    mov $1, %r9d
    call draw_string

    # Result at item_y + 20 (scale 1, primary text)
    mov $64, %edi
    lea 20(%r13), %esi
    mov %r12d, %eax
    shl $6, %rax
    lea history_entries+32(%rip), %rdx
    add %rax, %rdx
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_string

    inc %r12d
    jmp .rhp_loop

.rhp_bottom:
    # Separator line at y=268
    mov $56, %edi
    mov $268, %esi
    mov $340, %edx
    mov $1, %ecx
    mov $COL_SEP, %r8d
    call draw_rect

    # Clear All History button at y=274
    cmpl $10, history_hover(%rip)
    jne .rhp_no_clrhov
    mov $52, %edi
    mov $274, %esi
    mov $348, %edx
    mov $32, %ecx
    mov $COL_POPOVER_HOV, %r8d
    mov $COL_POPOVER_HOV, %r9d
    sub $8, %rsp
    movq $8, (%rsp)
    call draw_squircle
    add $8, %rsp
.rhp_no_clrhov:

    mov $150, %edi
    mov $282, %esi
    lea str_hist_clear(%rip), %rdx
    mov $COL_DEST, %r8d
    mov $1, %r9d
    call draw_string

    leave
    ret

# ==============================================================================
# X11 Event Dispatcher
# ==============================================================================

# ------------------------------------------------------------------------------
# handle_x11_event:
# Decodes 32-byte X11 event packets from ev_packet:
#   Opcode 12 = Expose: Marks display dirty for repaint.
#   Opcode 6  = MotionNotify: Tracks hover states for popover items.
#   Opcode 4  = ButtonPress: Handles mouse clicks on buttons, headerbar, popovers.
#   Opcode 5  = ButtonRelease: Resets active button pressed state.
#   Opcode 2  = KeyPress: Translates hardware keycodes into calculator actions.
#   Opcode 33 = ClientMessage: Detects WM_DELETE_WINDOW and triggers clean exit.
# ------------------------------------------------------------------------------
handle_x11_event:
    push %rbp
    mov %rsp, %rbp

    movzbq ev_packet(%rip), %rax
    and $0x7F, %rax                      # Mask out synthetic send_event bit (0x80)

    cmp $12, %rax
    je .ev_expose
    cmp $6, %rax
    je .ev_motion
    cmp $4, %rax
    je .ev_bpress
    cmp $5, %rax
    je .ev_brelease
    cmp $2, %rax
    je .ev_key
    cmp $33, %rax
    je .ev_cmsg
    jmp .h_done

.ev_expose:
    movl $1, dirty(%rip)                 # Flag window for repaint
    jmp .h_done

.ev_motion:
    # Mouse pointer motion: coordinates at offsets 24 (x) and 26 (y)
    movswl ev_packet+24(%rip), %ecx
    movswl ev_packet+26(%rip), %edx

    # 1. History popover motion tracking
    mov history_open(%rip), %eax
    test %eax, %eax
    jz .chk_menu_motion

    cmp $44, %ecx
    jl .no_h_hov
    cmp $408, %ecx
    jg .no_h_hov
    cmp $94, %edx
    jl .chk_h_clr_hov
    cmp $262, %edx
    jge .chk_h_clr_hov

    mov %edx, %eax
    sub $94, %eax
    xor %edx, %edx
    mov $42, %esi
    div %esi
    mov %eax, history_hover(%rip)
    movl $1, dirty(%rip)
    jmp .h_done

.chk_h_clr_hov:
    cmp $268, %edx
    jl .no_h_hov
    cmp $310, %edx
    jg .no_h_hov
    movl $10, history_hover(%rip)
    movl $1, dirty(%rip)
    jmp .h_done

.no_h_hov:
    movl $-1, history_hover(%rip)
    movl $1, dirty(%rip)
    jmp .h_done

.chk_menu_motion:
    mov menu_open(%rip), %eax
    test %eax, %eax
    jz .chk_btn_hov

    # Check hover inside open popover menu (x: 12..242, y: 56..214)
    cmp $12, %ecx
    jl .no_m_hov
    cmp $242, %ecx
    jg .no_m_hov
    cmp $56, %edx
    jl .no_m_hov
    cmp $214, %edx
    jg .no_m_hov

    # Item index = (y - 56) / 38
    mov %edx, %eax
    sub $56, %eax
    xor %edx, %edx
    mov $38, %esi
    div %esi
    mov %eax, hover_menu(%rip)
    movl $1, dirty(%rip)
    jmp .h_done
.no_m_hov:
    movl $-1, hover_menu(%rip)

.chk_btn_hov:
    movl $1, dirty(%rip)
    jmp .h_done

.ev_bpress:
    # ButtonPress: only process primary mouse button (Button 1)
    movzbq ev_packet+1(%rip), %rax
    cmp $1, %rax
    jne .h_done

    movswl ev_packet+24(%rip), %ecx      # %ecx = click x
    movswl ev_packet+26(%rip), %edx      # %edx = click y

    # 1. History Popover open check
    mov history_open(%rip), %eax
    test %eax, %eax
    jz .check_menu_open

    # Check click inside history popover card (x: 44..408, y: 52..362)
    cmp $44, %ecx
    jl .close_hist_pop
    cmp $408, %ecx
    jg .close_hist_pop
    cmp $52, %edx
    jl .close_hist_pop
    cmp $362, %edx
    jg .close_hist_pop

    # Check if click is on an item (y: 94..262)
    cmp $94, %edx
    jl .chk_hist_clr_click
    cmp $262, %edx
    jge .chk_hist_clr_click

    mov %edx, %eax
    sub $94, %eax
    xor %edx, %edx
    mov $42, %esi
    div %esi
    cmp history_count(%rip), %eax
    jge .close_hist_pop

    # Copy history_entries[eax].res into disp_buf!
    shl $6, %rax
    lea history_entries+32(%rip), %rsi
    add %rax, %rsi
    lea disp_buf(%rip), %rdi
.h_copy_res:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .h_copy_res

    # Synchronize programmer readouts if in programmer mode
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    jne .h_load_done
    call update_prog_readouts
.h_load_done:
    movl $1, clr_next(%rip)              # Next typed digit replaces restored result
    jmp .close_hist_pop

.chk_hist_clr_click:
    # Check if click is on "Clear All History" (y: 268..310)
    cmp $268, %edx
    jl .close_hist_pop
    cmp $310, %edx
    jg .close_hist_pop
    call clear_history
    jmp .close_hist_pop

.close_hist_pop:
    movl $0, history_open(%rip)
    movl $1, dirty(%rip)
    jmp .h_done

.check_menu_open:
    # 2. Hamburger Popover open check: if menu is open, clicks either select an item or dismiss
    mov menu_open(%rip), %eax
    test %eax, %eax
    jz .check_header_click

    cmp $12, %ecx
    jl .close_pop
    cmp $242, %ecx
    jg .close_pop
    cmp $56, %edx
    jl .close_pop
    cmp $214, %edx
    jg .close_pop

    # Compute selected menu item index
    mov %edx, %eax
    sub $56, %eax
    xor %edx, %edx
    mov $38, %esi
    div %esi
    cmp $0, %eax
    je .set_basic
    cmp $1, %eax
    je .set_adv
    cmp $2, %eax
    je .set_prog
    cmp $3, %eax
    je .do_clear_hist
    jmp .close_pop

.set_basic:
    movl $0, curr_mode(%rip)
    jmp .close_pop
.set_adv:
    movl $1, curr_mode(%rip)
    jmp .close_pop
.set_prog:
    movl $2, curr_mode(%rip)
    jmp .close_pop
.do_clear_hist:
    movb $0, hist_buf(%rip)
    jmp .close_pop

.close_pop:
    movl $0, menu_open(%rip)             # Dismiss popover
    movl $1, dirty(%rip)
    jmp .h_done

.check_header_click:
    # HeaderBar region: y < 50
    cmp $50, %edx
    jge .check_keypad_click

    # Hamburger button check: x: 12..48, y: 8..42
    cmp $12, %ecx
    jl .chk_hist_btn
    cmp $48, %ecx
    jg .chk_hist_btn
    cmp $8, %edx
    jl .chk_hist_btn
    cmp $42, %edx
    jg .chk_hist_btn
    movl $0, history_open(%rip)
    xorl $1, menu_open(%rip)             # Toggle popover menu
    movl $1, dirty(%rip)
    jmp .h_done

.chk_hist_btn:
    # History button check: x: 328..364, y: 8..42
    cmp $328, %ecx
    jl .chk_close
    cmp $364, %ecx
    jg .chk_close
    cmp $8, %edx
    jl .chk_close
    cmp $42, %edx
    jg .chk_close
    movl $0, menu_open(%rip)
    xorl $1, history_open(%rip)          # Toggle history popover
    movl $1, dirty(%rip)
    jmp .h_done

.chk_close:
    # Close button check: x: 372..408, y: 8..42
    cmp $372, %ecx
    jl .header_drag
    cmp $408, %ecx
    jg .header_drag
    cmp $8, %edx
    jl .header_drag
    cmp $42, %edx
    jg .header_drag
    jmp exit_clean                       # Exit application

.header_drag:
    # Titlebar drag region: start interactive window move
    call x11_start_drag
    jmp .h_done

.check_keypad_click:
    # Check click on History Expression row in Display Card (y: 62..96)
    cmp $62, %edx
    jl .chk_prog_bases
    cmp $96, %edx
    jge .chk_prog_bases
    movl $0, menu_open(%rip)
    movl $1, history_open(%rip)          # Open history popover on history row click!
    movl $1, dirty(%rip)
    jmp .h_done

.chk_prog_bases:
    # In Programmer Mode, check clicks on the 4 base rows inside the display card
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    jne .chk_kp_y
    cmp $108, %edx
    jl .chk_kp_y
    cmp $192, %edx
    jge .chk_kp_y
    # Base index = (y - 108) / 20
    mov %edx, %eax
    sub $108, %eax
    xor %edx, %edx
    mov $20, %esi
    div %esi
    cmp $3, %eax
    jle .sb_ok
    mov $3, %eax
.sb_ok:
    mov %eax, curr_base(%rip)            # Switch active programmer radix
    call update_prog_readouts
    movl $1, dirty(%rip)
    jmp .h_done

.chk_kp_y:
    # Keypad grid begins at y >= 216
    cmp $216, %edx
    jl .h_done
    mov curr_mode(%rip), %eax
    cmp $1, %eax
    je .click_adv
    cmp $2, %eax
    je .click_prog

    # --- Basic Keypad Click Hit-Testing ---
    # col = (x - 16) / 99 (valid cols: 0..3)
    mov %ecx, %eax
    sub $16, %eax
    js .h_done
    xor %edx, %edx
    mov $99, %esi
    div %esi
    cmp $4, %eax
    jge .h_done
    mov %eax, %r14d

    # row = (y - 216) / 90 (valid rows: 0..4)
    movswl ev_packet+26(%rip), %eax
    sub $216, %eax
    js .h_done
    xor %edx, %edx
    mov $90, %esi
    div %esi
    cmp $5, %eax
    jge .h_done
    mov %eax, %r13d

    # key_index = row * 4 + col
    imul $4, %r13d, %eax
    add %r14d, %eax
    call exec_basic_key
    movl $1, dirty(%rip)
    jmp .h_done

.click_adv:
    # --- Scientific Keypad Click Hit-Testing ---
    # col = (x - 16) / 79 (valid cols: 0..4)
    mov %ecx, %eax
    sub $16, %eax
    js .h_done
    xor %edx, %edx
    mov $79, %esi
    div %esi
    cmp $5, %eax
    jge .h_done
    mov %eax, %r14d

    # row = (y - 216) / 74 (valid rows: 0..5)
    movswl ev_packet+26(%rip), %eax
    sub $216, %eax
    js .h_done
    xor %edx, %edx
    mov $74, %esi
    div %esi
    cmp $6, %eax
    jge .h_done
    mov %eax, %r13d

    # key_index = row * 5 + col
    imul $5, %r13d, %eax
    add %r14d, %eax
    call exec_adv_key
    movl $1, dirty(%rip)
    jmp .h_done

.click_prog:
    # --- Programmer Keypad Click Hit-Testing ---
    # col = (x - 16) / 79 (valid cols: 0..4)
    mov %ecx, %eax
    sub $16, %eax
    js .h_done
    xor %edx, %edx
    mov $79, %esi
    div %esi
    cmp $5, %eax
    jge .h_done
    mov %eax, %r14d

    # row = (y - 216) / 74 (valid rows: 0..5)
    movswl ev_packet+26(%rip), %eax
    sub $216, %eax
    js .h_done
    xor %edx, %edx
    mov $74, %esi
    div %esi
    cmp $6, %eax
    jge .h_done
    mov %eax, %r13d

    # key_index = row * 5 + col
    imul $5, %r13d, %eax
    add %r14d, %eax
    call exec_prog_key
    movl $1, dirty(%rip)
    jmp .h_done

.ev_brelease:
    movl $-1, active_btn(%rip)
    movl $1, dirty(%rip)
    jmp .h_done

.ev_key:
    # KeyPress: Hardware keycode is at byte offset 1 in ev_packet
    movzbq ev_packet+1(%rip), %rax
    cmp $9, %rax                         # Escape (key 9) -> Clear
    je .k_clear
    cmp $54, %rax                        # 'c' key -> Clear
    je .k_clear
    cmp $36, %rax                        # Return / Enter -> Evaluate
    je .k_eval
    cmp $104, %rax                       # Numpad Enter -> Evaluate
    je .k_eval
    cmp $22, %rax                        # BackSpace -> Bksp
    je .k_bksp

    # Number keys 1-9 (keycodes 10..18 -> digits '1'..'9')
    cmp $10, %rax
    jl .k_chk_sym
    cmp $18, %rax
    jg .k_chk_zero
    sub $9, %rax
    add $'0', %al
    call append_disp_char
    movl $1, dirty(%rip)
    jmp .h_done

.k_chk_zero:
    cmp $19, %rax                        # Keycode 19 = '0'
    jne .k_chk_sym
    movb $'0', %al
    call append_disp_char
    movl $1, dirty(%rip)
    jmp .h_done

.k_chk_sym:
    cmp $60, %rax                        # Keycode 60 = '.'
    je .k_dot
    cmp $61, %rax                        # Keycode 61 = '/'
    je .k_div
    cmp $106, %rax                       # Numpad '/'
    je .k_div
    cmp $20, %rax                        # Keycode 20 = '-'
    je .k_sub
    cmp $82, %rax                        # Numpad '-'
    je .k_sub
    cmp $86, %rax                        # Numpad '+'
    je .k_add
    cmp $63, %rax                        # Numpad '*'
    je .k_mul
    cmp $21, %rax                        # Keycode 21 = '='
    je .k_eval
    jmp .h_done

.k_dot:
    movb $'.', %al
    call append_disp_char
    movl $1, dirty(%rip)
    jmp .h_done
.k_add:
    call op_add
    movl $1, dirty(%rip)
    jmp .h_done
.k_sub:
    call op_sub
    movl $1, dirty(%rip)
    jmp .h_done
.k_mul:
    call op_mul
    movl $1, dirty(%rip)
    jmp .h_done
.k_div:
    call op_div
    movl $1, dirty(%rip)
    jmp .h_done
.k_clear:
    call clear_disp
    movl $1, dirty(%rip)
    jmp .h_done
.k_eval:
    call eval_expression
    movl $1, dirty(%rip)
    jmp .h_done
.k_bksp:
    call bksp_disp
    movl $1, dirty(%rip)
    jmp .h_done

.ev_cmsg:
    # ClientMessage: check if data.l[0] (offset 12) matches atom_wm_del
    mov ev_packet+12(%rip), %eax
    cmp atom_wm_del(%rip), %eax
    je exit_clean                        # User closed window via window manager
    jmp .h_done

.h_done:
    leave
    ret
