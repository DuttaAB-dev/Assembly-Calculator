# ==============================================================================
# Machine-Synthesized Libadwaita Calculator - UI & Display Subsystem
# Pure x86_64 Assembly (No C, No Python, No external libraries)
# ==============================================================================

.global _start
.global WIN_W, WIN_H, fb_ptr, disp_buf, hist_buf, hex_buf, dec_buf, oct_buf, bin_buf
.global curr_mode, curr_base, menu_open, hover_btn, active_btn, hover_menu, dirty
.global pending_op, clr_next, acc_val, acc_int, exit_clean, exit_fail

.equ WIN_W, 420
.equ WIN_H, 680
.equ FB_SIZE, WIN_W * WIN_H * 4

# Linux Syscall Constants
.equ SYS_READ,    0
.equ SYS_WRITE,   1
.equ SYS_OPEN,    2
.equ SYS_CLOSE,   3
.equ SYS_POLL,    7
.equ SYS_MMAP,    9
.equ SYS_SOCKET,  41
.equ SYS_CONNECT, 42
.equ SYS_EXIT,    60

# Colors (GNOME Libadwaita Dark 32-bit ARGB/XRGB)
.equ COL_BG,          0x242424
.equ COL_HEADER,      0x242424
.equ COL_SEP,         0x303030
.equ COL_CARD_BG,     0x1E1E1E
.equ COL_CARD_BORDER, 0x333333
.equ COL_TEXT_PRI,    0xFFFFFF
.equ COL_TEXT_SEC,    0x8E8E93
.equ COL_BTN_IDLE,    0x323232
.equ COL_BTN_HOVER,   0x3D3D3D
.equ COL_BTN_ACTIVE,  0x282828
.equ COL_BTN_BORDER,  0x3E3E3E
.equ COL_ACCENT,      0x3584E4
.equ COL_ACC_HOV,     0x4790E8
.equ COL_ACC_ACT,     0x1C71D8
.equ COL_DEST,        0xE01B24
.equ COL_DEST_HOV,    0xE63840
.equ COL_DEST_ACT,    0xC01C28
.equ COL_POPOVER_BG,  0x2A2A2A
.equ COL_POPOVER_BRD, 0x444444
.equ COL_POPOVER_HOV, 0x383838

# ==============================================================================
.section .rodata
# ==============================================================================

.align 16
font_data:
    .incbin "font.bin"

str_x0_path:      .asciz "/tmp/.X11-unix/X0"
str_auth_name:    .asciz "MIT-MAGIC-COOKIE-1"
str_wm_proto:     .asciz "WM_PROTOCOLS"
str_wm_del:       .asciz "WM_DELETE_WINDOW"
str_mwm_hints:    .asciz "_MOTIF_WM_HINTS"
str_gtk_extents:  .asciz "_GTK_FRAME_EXTENTS"
str_net_type:     .asciz "_NET_WM_WINDOW_TYPE"
str_net_norm:     .asciz "_NET_WM_WINDOW_TYPE_NORMAL"
str_net_move:     .asciz "_NET_WM_MOVERESIZE"
str_app_title:    .asciz "Calculator"

str_basic_title:  .asciz "Basic Calculator"
str_adv_title:    .asciz "Scientific Calculator"
str_prog_title:   .asciz "Programming Calculator"

str_menu_basic:   .asciz "  Basic Mode"
str_menu_adv:     .asciz "  Scientific Mode"
str_menu_prog:    .asciz "  Programming Mode"
str_menu_clear:   .asciz "  Clear History"

str_hex_lbl:      .asciz "HEX:"
str_dec_lbl:      .asciz "DEC:"
str_oct_lbl:      .asciz "OCT:"
str_bin_lbl:      .asciz "BIN:"

str_default_disp: .asciz "0"

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

prog_key_types:
    .byte '&', '|', '^', '~', 'C'
    .byte '<', '>', 'A', 'B', 130
    .byte '7', '8', '9', 'C', 131
    .byte '4', '5', '6', 'D', 132
    .byte '1', '2', '3', 'E', '-'
    .byte '0', 133, '=', 'F', '+'
# ==============================================================================
.section .data
# ==============================================================================

.align 8
initial_rsp:    .quad 0
has_auth:       .long 0
str_xauth_prefix: .ascii "XAUTHORITY="

sock_fd:        .quad 0
win_id:         .quad 0
gc_id:          .quad 0
root_id:        .quad 0
fb_ptr:         .quad 0

atom_wm_proto:  .long 0
atom_wm_del:    .long 0
atom_mwm:       .long 0
atom_gfe:       .long 0
atom_net_type:  .long 0
atom_net_norm:  .long 0
atom_net_move:  .long 0

curr_mode:      .long 0
curr_base:      .long 0
menu_open:      .long 0
hover_btn:      .long -1
active_btn:     .long -1
hover_menu:     .long -1
dirty:          .long 1

pending_op:     .long 0
clr_next:       .long 0

acc_val:        .double 0.0
acc_int:        .quad 0

disp_buf:       .skip 64
hist_buf:       .skip 128
hex_buf:        .skip 32
dec_buf:        .skip 32
oct_buf:        .skip 32
bin_buf:        .skip 64

poll_pfd:
    .long 0
    .short 1
    .short 0

ev_packet:      .skip 64
auth_cookie:    .skip 16
sock_addr:      .skip 128

# ==============================================================================
.section .text
# ==============================================================================

_start:
    mov %rsp, initial_rsp(%rip)

    # 1. Allocate Framebuffer via sys_mmap (420x680x4 bytes)
    mov $SYS_MMAP, %rax
    xor %rdi, %rdi
    mov $FB_SIZE, %rsi
    mov $3, %rdx
    mov $0x22, %r10
    mov $-1, %r8
    xor %r9, %r9
    syscall
    mov %rax, fb_ptr(%rip)

    # 2. Check if headless --dump flag passed
    mov initial_rsp(%rip), %rax
    mov (%rax), %rcx
    cmp $3, %rcx
    jl .not_dump

    mov 16(%rax), %rsi
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

    # Optional mode in argv[3]
    cmp $4, %rcx
    jl .no_custom_mode
    mov 32(%rax), %rsi
    movzbq (%rsi), %rdx
    sub $'0', %rdx
    cmp $0, %edx
    jl .no_custom_mode
    cmp $2, %edx
    jg .no_custom_mode
    mov %edx, curr_mode(%rip)

.no_custom_mode:
    # Optional menu flag in argv[4]
    cmp $5, %rcx
    jl .do_render_dump
    mov 40(%rax), %rsi
    cmpb $'m', (%rsi)
    jne .do_render_dump
    movl $1, menu_open(%rip)

.do_render_dump:
    lea disp_buf(%rip), %rdi
    mov curr_mode(%rip), %eax
    cmp $1, %eax
    je .mock_adv
    cmp $2, %eax
    je .mock_prog

    # Basic mock
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
    movb $'2', (%rdi)
    movb $'5', 1(%rdi)
    movb $'5', 2(%rdi)
    movb $0, 3(%rdi)
    call update_prog_readouts

.start_dump_render:
    call render_ui

    # sys_open(argv[2], O_WRONLY | O_CREAT | O_TRUNC = 0x241, 0666)
    mov initial_rsp(%rip), %rax
    mov 24(%rax), %rdi
    mov $SYS_OPEN, %rax
    mov $0x241, %rsi
    mov $0666, %rdx
    syscall
    cmp $0, %rax
    jl exit_fail
    mov %rax, %r12

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

    # Convert fb_ptr pixels to RGB and write in rows
    sub $1280, %rsp
    xor %r13, %r13
.dump_row_loop:
    cmp $WIN_H, %r13
    jge .dump_done

    mov %r13, %rax
    imul $WIN_W, %rax
    shl $2, %rax
    add fb_ptr(%rip), %rax
    mov %rax, %r14

    mov %rsp, %r15
    xor %rcx, %rcx
.dump_col_loop:
    cmp $WIN_W, %rcx
    jge .dump_write_row
    mov (%r14, %rcx, 4), %eax
    mov %eax, %edx
    shr $16, %edx
    movb %dl, (%r15)
    mov %eax, %edx
    shr $8, %edx
    movb %dl, 1(%r15)
    movb %al, 2(%r15)
    add $3, %r15
    inc %rcx
    jmp .dump_col_loop

.dump_write_row:
    mov $SYS_WRITE, %rax
    mov %r12, %rdi
    mov %rsp, %rsi
    mov $1260, %rdx
    syscall

    inc %r13
    jmp .dump_row_loop

.dump_done:
    add $1280, %rsp
    mov $SYS_CLOSE, %rax
    mov %r12, %rdi
    syscall

    mov $SYS_EXIT, %rax
    xor %rdi, %rdi
    syscall

.not_dump:
    # 3. Extract XAuthority Cookie
    call x11_load_cookie

    # 4. Connect to X11 socket (/tmp/.X11-unix/X0)
    mov $SYS_SOCKET, %rax
    mov $1, %rdi
    mov $1, %rsi
    xor %rdx, %rdx
    syscall
    cmp $0, %rax
    jl exit_fail
    mov %rax, sock_fd(%rip)

    lea sock_addr(%rip), %rdi
    movw $1, (%rdi)
    lea 2(%rdi), %rdi
    lea str_x0_path(%rip), %rsi
    mov $18, %rcx
    rep movsb

    mov $SYS_CONNECT, %rax
    mov sock_fd(%rip), %rdi
    lea sock_addr(%rip), %rsi
    mov $110, %rdx
    syscall
    cmp $0, %rax
    jl exit_fail

    # 5. Perform X11 Handshake
    call x11_handshake
    test %rax, %rax
    jz exit_fail

    # 6. Initialize Window with CSD & Libadwaita properties
    call x11_init_window

    lea disp_buf(%rip), %rdi
    lea str_default_disp(%rip), %rsi
    movb $'0', (%rdi)
    movb $0, 1(%rdi)

    # 7. Main Interactive Event Loop
main_loop:
    mov dirty(%rip), %eax
    test %eax, %eax
    jz wait_event

    call render_ui
    call x11_blit_fb
    movl $0, dirty(%rip)

wait_event:
    mov sock_fd(%rip), %rax
    mov %eax, poll_pfd(%rip)
    mov $SYS_POLL, %rax
    lea poll_pfd(%rip), %rdi
    mov $1, %rsi
    mov $20, %rdx
    syscall
    cmp $0, %rax
    jl exit_clean
    jz main_loop

    mov $SYS_READ, %rax
    mov sock_fd(%rip), %rdi
    lea ev_packet(%rip), %rsi
    mov $32, %rdx
    syscall
    cmp $32, %rax
    jne exit_clean

    call handle_x11_event
    jmp main_loop

exit_clean:
    mov $SYS_CLOSE, %rax
    mov sock_fd(%rip), %rdi
    syscall
    mov $SYS_EXIT, %rax
    xor %rdi, %rdi
    syscall

exit_fail:
    mov $SYS_EXIT, %rax
    mov $1, %rdi
    syscall

# ==============================================================================
# X11 Socket Protocol Helpers
# ==============================================================================

x11_load_cookie:
    push %rbp
    mov %rsp, %rbp
    sub $512, %rsp

    mov initial_rsp(%rip), %rax
    test %rax, %rax
    jz .lc_done
    mov (%rax), %rcx
    lea 16(%rax, %rcx, 8), %rsi

.lc_env:
    mov (%rsi), %rdi
    test %rdi, %rdi
    jz .lc_done
    push %rsi
    push %rdi
    lea str_xauth_prefix(%rip), %rsi
    mov $11, %rcx
    repe cmpsb
    pop %rdi
    pop %rsi
    je .lc_found_env
    add $8, %rsi
    jmp .lc_env

.lc_found_env:
    lea 11(%rdi), %rdi
    mov $SYS_OPEN, %rax
    xor %rsi, %rsi
    xor %rdx, %rdx
    syscall
    cmp $0, %rax
    jl .lc_done
    mov %rax, %r12

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
    lea 20(%rdi, %rcx), %rsi
    lea auth_cookie(%rip), %rdi
    mov $16, %rcx
    rep movsb
    movl $1, has_auth(%rip)
    jmp .lc_done
.lc_next:
    inc %rcx
    jmp .lc_scan

.lc_done:
    leave
    ret

x11_handshake:
    sub $128, %rsp
    mov %rsp, %rdi
    movb $'l', (%rdi)
    movb $0, 1(%rdi)
    movw $11, 2(%rdi)
    movw $0, 4(%rdi)

    mov has_auth(%rip), %eax
    test %eax, %eax
    jz .hs_no_auth

    movw $18, 6(%rdi)
    movw $16, 8(%rdi)
    movw $0, 10(%rdi)

    lea 12(%rsp), %rdi
    lea str_auth_name(%rip), %rsi
    mov $18, %rcx
    rep movsb
    movw $0, (%rdi)

    lea 32(%rsp), %rdi
    lea auth_cookie(%rip), %rsi
    mov $16, %rcx
    rep movsb

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $48, %rdx
    syscall
    jmp .hs_read_rep

.hs_no_auth:
    movw $0, 6(%rdi)
    movw $0, 8(%rdi)
    movw $0, 10(%rdi)

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $12, %rdx
    syscall

.hs_read_rep:
    mov $SYS_READ, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $8, %rdx
    syscall
    cmpb $1, (%rsp)
    jne .hs_err

    movzwq 6(%rsp), %r12
    shl $2, %r12

    sub %r12, %rsp
    mov $SYS_READ, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov %r12, %rdx
    syscall

    mov 4(%rsp), %eax
    or $1, %eax
    mov %rax, win_id(%rip)
    add $1, %eax
    mov %rax, gc_id(%rip)

    movzwq 16(%rsp), %rcx
    mov %rcx, %rdx
    and $3, %rdx
    jz .v_pad_done
    mov $4, %rax
    sub %rdx, %rax
    add %rax, %rcx
.v_pad_done:
    movzbq 21(%rsp), %rax
    shl $3, %rax
    add %rax, %rcx
    add $32, %rcx
    mov (%rsp, %rcx), %eax
    mov %rax, root_id(%rip)

    add %r12, %rsp
    add $128, %rsp
    mov $1, %rax
    ret

.hs_err:
    add $128, %rsp
    xor %rax, %rax
    ret

x11_atom:
    push %rbp
    mov %rsp, %rbp
    sub $64, %rsp

    xor %rcx, %rcx
.al_loop:
    cmpb $0, (%rdi, %rcx)
    jz .al_done
    inc %rcx
    jmp .al_loop
.al_done:
    mov %rcx, %rdx
    add $3, %rdx
    and $~3, %rdx
    mov %rdx, %rax
    shr $2, %rax
    add $2, %rax
    shl $16, %rax
    or $16, %rax

    mov %rax, (%rsp)
    mov %cx, 4(%rsp)
    movw $0, 6(%rsp)

    lea 8(%rsp), %rsi
    push %rcx
    push %rdi
    mov %rdi, %rax
    mov %rsi, %rdi
    mov %rax, %rsi
    rep movsb
    pop %rdi
    pop %rcx

    mov %rdx, %r8
    shr $2, %r8
    add $2, %r8
    shl $2, %r8

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov %r8, %rdx
    syscall

    mov $SYS_READ, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $32, %rdx
    syscall

    mov 8(%rsp), %eax
    leave
    ret

x11_init_window:
    push %rbp
    mov %rsp, %rbp
    sub $128, %rsp

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

    # 1. CreateWindow
    movl $0x000A0001, (%rsp)
    mov win_id(%rip), %eax
    mov %eax, 4(%rsp)
    mov root_id(%rip), %eax
    mov %eax, 8(%rsp)
    movl $0x00640064, 12(%rsp)
    movl $((WIN_H << 16) | WIN_W), 16(%rsp)
    movl $0x00010000, 20(%rsp)
    movl $0, 24(%rsp)
    movl $0x00000802, 28(%rsp)
    movl $COL_BG, 32(%rsp)
    movl $0x0000804D, 36(%rsp)

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $40, %rdx
    syscall

    # 2. CreateGC
    movl $0x00040037, (%rsp)
    mov gc_id(%rip), %eax
    mov %eax, 4(%rsp)
    mov win_id(%rip), %eax
    mov %eax, 8(%rsp)
    movl $0, 12(%rsp)

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $16, %rdx
    syscall

    # 3. Set WM_NAME
    movl $0x00080012, (%rsp)
    mov win_id(%rip), %eax
    mov %eax, 4(%rsp)
    movl $39, 8(%rsp)
    movl $31, 12(%rsp)
    movl $0x000008, 16(%rsp)
    movl $10, 20(%rsp)
    movl $0x636C6143, 24(%rsp)
    movl $0x74616C75, 28(%rsp)
    movl $0x0000726F, 32(%rsp)

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $36, %rdx
    syscall

    # 4. Set WM_PROTOCOLS (WM_DELETE_WINDOW)
    movl $0x00070012, (%rsp)
    mov win_id(%rip), %eax
    mov %eax, 4(%rsp)
    mov atom_wm_proto(%rip), %eax
    mov %eax, 8(%rsp)
    movl $4, 12(%rsp)
    movl $32, 16(%rsp)
    movl $1, 20(%rsp)
    mov atom_wm_del(%rip), %eax
    mov %eax, 24(%rsp)

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $28, %rdx
    syscall

    # 5. Suppress System Titlebar & Frame (_MOTIF_WM_HINTS)
    mov atom_mwm(%rip), %eax
    test %eax, %eax
    jz .skip_mwm
    movl $0x000B0012, (%rsp)
    mov win_id(%rip), %edx
    mov %edx, 4(%rsp)
    mov %eax, 8(%rsp)
    mov %eax, 12(%rsp)
    movl $32, 16(%rsp)
    movl $5, 20(%rsp)
    movl $2, 24(%rsp)
    movl $0, 28(%rsp)
    movl $0, 32(%rsp)
    movl $0, 36(%rsp)
    movl $0, 40(%rsp)

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $44, %rdx
    syscall
.skip_mwm:

    # 6. MapWindow
    movl $0x00020008, (%rsp)
    mov win_id(%rip), %eax
    mov %eax, 4(%rsp)

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $8, %rdx
    syscall

    leave
    ret

x11_blit_fb:
    push %rbp
    mov %rsp, %rbp
    sub $64, %rsp

    xor %r12, %r12
.blit_loop:
    cmp $WIN_H, %r12
    jge .blit_done
    mov $32, %r13
    mov $WIN_H, %rax
    sub %r12, %rax
    cmp %r13, %rax
    cmovl %rax, %r13

    mov $WIN_W, %rax
    imul %r13, %rax
    add $6, %rax

    mov %rax, %rdx
    shl $16, %rdx
    or $0x0248, %rdx
    mov %edx, (%rsp)
    mov win_id(%rip), %eax
    mov %eax, 4(%rsp)
    mov gc_id(%rip), %eax
    mov %eax, 8(%rsp)
    movw $WIN_W, 12(%rsp)
    movw %r13w, 14(%rsp)
    movw $0, 16(%rsp)
    movw %r12w, 18(%rsp)
    movb $0, 20(%rsp)
    movb $24, 21(%rsp)
    movw $0, 22(%rsp)

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    mov %rsp, %rsi
    mov $24, %rdx
    syscall

    mov %r12, %rax
    imul $WIN_W * 4, %rax
    add fb_ptr(%rip), %rax
    mov %rax, %rsi

    mov $WIN_W * 4, %rax
    imul %r13, %rax
    mov %rax, %rdx

    mov $SYS_WRITE, %rax
    mov sock_fd(%rip), %rdi
    syscall

    add %r13, %r12
    jmp .blit_loop

.blit_done:
    leave
    ret

x11_start_drag:
    mov atom_net_move(%rip), %eax
    test %eax, %eax
    jz .drag_ret

    sub $64, %rsp
    movl $0x000B0019, (%rsp)
    mov root_id(%rip), %eax
    mov %eax, 4(%rsp)
    movl $0x00180000, 8(%rsp)

    lea 12(%rsp), %rdi
    movb $33, (%rdi)
    movb $32, 1(%rdi)
    movw $0, 2(%rdi)
    mov win_id(%rip), %eax
    mov %eax, 4(%rdi)
    mov atom_net_move(%rip), %eax
    mov %eax, 8(%rdi)
    movzwl ev_packet+20(%rip), %eax
    mov %eax, 12(%rdi)
    movzwl ev_packet+22(%rip), %eax
    mov %eax, 16(%rdi)
    movl $8, 20(%rdi)
    movl $1, 24(%rdi)
    movl $1, 28(%rdi)

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

draw_rect:
    push %r12
    push %r13
    push %r14
    mov %edi, %r12d
    mov %esi, %r13d
    mov %edx, %r14d
.dr_loop:
    test %ecx, %ecx
    jle .dr_done
    push %rcx
    mov %r13d, %eax
    imul $WIN_W, %eax
    add %r12d, %eax
    shl $2, %rax
    add fb_ptr(%rip), %rax
    mov %rax, %rdi
    mov %r8d, %eax
    mov %r14d, %ecx
    rep stosl
    pop %rcx
    inc %r13d
    dec %ecx
    jmp .dr_loop
.dr_done:
    pop %r14
    pop %r13
    pop %r12
    ret

draw_squircle:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13
    push %r14
    push %r15
    push %rbx

    mov %edi, %r12d
    mov %esi, %r13d
    mov %edx, %r14d
    mov %ecx, %r15d
    mov 16(%rbp), %ebx

    test %ebx, %ebx
    jle .sq_rect

    mov %r12d, %edi
    mov %r13d, %esi
    mov %r14d, %edx
    mov %r15d, %ecx
    push %r8
    mov %r9d, %r8d
    call draw_rect
    pop %r8

    lea 1(%r12d), %edi
    lea 1(%r13d), %esi
    lea -2(%r14d), %edx
    lea -2(%r15d), %ecx
    call draw_rect
    jmp .sq_done

.sq_rect:
    call draw_rect
.sq_done:
    pop %rbx
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    leave
    ret

# Draw 8x16 Glyph: edi=x, esi=y, edx=ascii, r8d=color, r9d=scale
draw_glyph:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13
    push %r14
    push %r15
    push %rbx

    mov %edi, %r12d
    mov %esi, %r13d
    sub $32, %edx
    cmp $105, %edx
    jge .dg_done
    test %edx, %edx
    jl .dg_done

    shl $4, %rdx
    lea font_data(%rip), %rax
    add %rdx, %rax
    mov %rax, %r14

    xor %r15d, %r15d
.row_loop:
    cmp $16, %r15d
    jge .dg_done
    movzbq (%r14, %r15), %rbx

    xor %ecx, %ecx
.col_loop:
    cmp $8, %ecx
    jge .row_next
    mov $7, %rdx
    sub %rcx, %rdx
    bt %rdx, %rbx
    jnc .col_next

    cmp $1, %r9d
    jg .scale2

    # Scale 1x
    mov %r13d, %eax
    add %r15d, %eax
    cmp $WIN_H, %eax
    jge .col_next
    imul $WIN_W, %eax
    add %r12d, %eax
    add %ecx, %eax
    cmp $WIN_W * WIN_H, %eax
    jge .col_next
    shl $2, %rax
    add fb_ptr(%rip), %rax
    mov %r8d, (%rax)
    jmp .col_next

.scale2:
    # Scale 2x
    mov %r13d, %eax
    lea (%rax, %r15, 2), %eax
    mov %r12d, %edx
    lea (%rdx, %rcx, 2), %edx

    imul $WIN_W, %eax
    add %edx, %eax
    shl $2, %rax
    add fb_ptr(%rip), %rax
    mov %r8d, (%rax)
    mov %r8d, 4(%rax)
    mov %r8d, WIN_W * 4(%rax)
    mov %r8d, (WIN_W * 4 + 4)(%rax)

.col_next:
    inc %ecx
    jmp .col_loop

.row_next:
    inc %r15d
    jmp .row_loop

.dg_done:
    pop %rbx
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    leave
    ret

draw_string:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13
    push %r14
    push %r15
    push %rbx

    mov %edi, %r12d
    mov %esi, %r13d
    mov %rdx, %r14
    mov %r8d, %ebx  # save color
    mov %r9d, %r15d # scale

.ds_loop:
    movzbq (%r14), %rdx
    test %dl, %dl
    jz .ds_done

    mov %r12d, %edi
    mov %r13d, %esi
    mov %ebx, %r8d
    mov %r15d, %r9d
    call draw_glyph

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

render_ui:
    push %rbp
    mov %rsp, %rbp

    # 1. Clear background to #242424
    mov fb_ptr(%rip), %rdi
    mov $COL_BG, %eax
    mov $WIN_W * WIN_H, %ecx
    rep stosl

    # 2. HeaderBar Separator Line at y=50
    mov $0, %edi
    mov $50, %esi
    mov $WIN_W, %edx
    mov $1, %ecx
    mov $COL_SEP, %r8d
    call draw_rect

    # 3. Hamburger Menu Button (x=12, y=8, w=36, h=34)
    mov $12, %edi
    mov $8, %esi
    mov $36, %edx
    mov $34, %ecx
    mov $COL_BTN_IDLE, %r8d
    mov $COL_BTN_BORDER, %r9d
    sub $8, %rsp
    movq $8, (%rsp)
    call draw_squircle
    add $8, %rsp

    mov $22, %edi
    mov $17, %esi
    mov $127, %edx
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_glyph

    # 4. Mode Title in HeaderBar
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

    # 5. Window Close Button (x=372, y=8, w=36, h=34)
    mov $372, %edi
    mov $8, %esi
    mov $36, %edx
    mov $34, %ecx
    mov $COL_BTN_IDLE, %r8d
    mov $COL_BTN_BORDER, %r9d
    sub $8, %rsp
    movq $17, (%rsp)
    call draw_squircle
    add $8, %rsp

    mov $386, %edi
    mov $17, %esi
    mov $'x', %edx
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_glyph

    # 6. Inset Display Card (x=16, y=62, w=388, h=140)
    mov $16, %edi
    mov $62, %esi
    mov $388, %edx
    mov $140, %ecx
    mov $COL_CARD_BG, %r8d
    mov $COL_CARD_BORDER, %r9d
    sub $8, %rsp
    movq $12, (%rsp)
    call draw_squircle
    add $8, %rsp

    # Render inside Display Card based on Mode
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    je .render_disp_prog

    # Basic / Advanced Display
    mov $32, %edi
    mov $78, %esi
    lea hist_buf(%rip), %rdx
    mov $COL_TEXT_SEC, %r8d
    mov $1, %r9d
    call draw_string

    # Main input string at y=136 (2x scale)
    lea disp_buf(%rip), %rdx
    xor %rcx, %rcx
.len_loop:
    cmpb $0, (%rdx, %rcx)
    jz .len_done
    inc %rcx
    jmp .len_loop
.len_done:
    shl $4, %rcx
    mov $384, %edi
    sub %ecx, %edi
    cmp $32, %edi
    jge .x_ok
    mov $32, %edi
.x_ok:
    mov $136, %esi
    lea disp_buf(%rip), %rdx
    mov $COL_TEXT_PRI, %r8d
    mov $2, %r9d
    call draw_string
    jmp .render_keypad

.render_disp_prog:
    # Programming Mode 4-Base Live Inspector
    mov $32, %edi
    mov $72, %esi
    lea disp_buf(%rip), %rdx
    mov $COL_TEXT_PRI, %r8d
    mov $2, %r9d
    call draw_string

    # HEX row
    mov $32, %edi
    mov $114, %esi
    lea str_hex_lbl(%rip), %rdx
    mov $COL_TEXT_SEC, %r8d
    mov curr_base(%rip), %eax
    cmp $0, %eax
    jne .h1
    mov $COL_ACCENT, %r8d
.h1:
    mov $1, %r9d
    call draw_string

    mov $74, %edi
    mov $114, %esi
    lea hex_buf(%rip), %rdx
    call draw_string

    # DEC row
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

    # OCT row
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

    # BIN row
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
    # 7. Render Keypads based on Mode
    mov curr_mode(%rip), %eax
    cmp $1, %eax
    je .draw_adv_keys
    cmp $2, %eax
    je .draw_prog_keys

    # Basic keypad
    call render_basic_keys
    jmp .check_popover

.draw_adv_keys:
    call render_adv_keys
    jmp .check_popover

.draw_prog_keys:
    call render_prog_keys

.check_popover:
    # 8. Render Popover Submenu if open
    mov menu_open(%rip), %eax
    test %eax, %eax
    jz .ui_done

    call render_popover

.ui_done:
    leave
    ret

render_basic_keys:
    push %rbp
    mov %rsp, %rbp
    sub $32, %rsp

    xor %r12d, %r12d
.bk_loop:
    cmp $20, %r12d
    jge .bk_done

    mov %r12d, %eax
    xor %edx, %edx
    mov $4, %ecx
    div %ecx
    mov %eax, %r13d
    mov %edx, %r14d

    imul $99, %r14d, %edi
    add $16, %edi
    imul $90, %r13d, %esi
    add $216, %esi
    mov $89, %edx
    mov $80, %ecx

    mov $COL_BTN_IDLE, %r8d
    mov $COL_BTN_BORDER, %r9d
    cmp $0, %r12d
    jne .b_not_c
    mov $COL_DEST, %r8d
    jmp .b_color_ok
.b_not_c:
    cmp $19, %r12d
    je .b_is_acc
    cmp $3, %r12d
    je .b_is_acc
    cmp $7, %r12d
    je .b_is_acc
    cmp $11, %r12d
    je .b_is_acc
    cmp $15, %r12d
    je .b_is_acc
    jmp .b_color_ok
.b_is_acc:
    mov $COL_ACCENT, %r8d
.b_color_ok:
    push %rdi
    push %rsi
    sub $8, %rsp
    movq $10, (%rsp)
    call draw_squircle
    add $8, %rsp
    pop %rsi
    pop %rdi

    lea basic_key_labels(%rip), %rax
    movzbq (%rax, %r12), %rdx
    lea 38(%rdi), %edi
    lea 32(%rsi), %esi
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_glyph

    inc %r12d
    jmp .bk_loop

.bk_done:
    leave
    ret

render_adv_keys:
    push %rbp
    mov %rsp, %rbp

    xor %r12d, %r12d
.ak_loop:
    cmp $30, %r12d
    jge .ak_done

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

    cmp $1, %r12d
    jne .ak_not_c
    mov $COL_DEST, %r8d
    jmp .ak_col_ok
.ak_not_c:
    cmp $4, %r12d
    je .ak_is_acc
    cmp $9, %r12d
    je .ak_is_acc
    cmp $14, %r12d
    je .ak_is_acc
    cmp $19, %r12d
    je .ak_is_acc
    cmp $24, %r12d
    je .ak_is_acc
    jmp .ak_col_ok
.ak_is_acc:
    mov $COL_ACCENT, %r8d
.ak_col_ok:
    push %rdi
    push %rsi
    sub $8, %rsp
    movq $8, (%rsp)
    call draw_squircle
    add $8, %rsp
    pop %rsi
    pop %rdi

    lea adv_key_types(%rip), %rax
    movzbq (%rax, %r12), %rbx

    lea 26(%rdi), %edi
    lea 26(%rsi), %esi
    mov %ebx, %edx
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_glyph

    inc %r12d
    jmp .ak_loop

.ak_done:
    leave
    ret

render_prog_keys:
    push %rbp
    mov %rsp, %rbp

    xor %r12d, %r12d
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

    cmp $4, %r12d
    jne .pk_not_c
    mov $COL_DEST, %r8d
    jmp .pk_col_ok
.pk_not_c:
    cmp $14, %r12d
    je .pk_is_acc
    cmp $19, %r12d
    je .pk_is_acc
    cmp $24, %r12d
    je .pk_is_acc
    cmp $27, %r12d
    je .pk_is_acc
    cmp $29, %r12d
    je .pk_is_acc
    jmp .pk_col_ok
.pk_is_acc:
    mov $COL_ACCENT, %r8d
.pk_col_ok:
    push %rdi
    push %rsi
    sub $8, %rsp
    movq $8, (%rsp)
    call draw_squircle
    add $8, %rsp
    pop %rsi
    pop %rdi

    lea prog_key_types(%rip), %rax
    movzbq (%rax, %r12), %rbx

    lea 26(%rdi), %edi
    lea 26(%rsi), %esi
    mov %ebx, %edx
    mov $COL_TEXT_PRI, %r8d
    mov $1, %r9d
    call draw_glyph

    inc %r12d
    jmp .pk_loop

.pk_done:
    leave
    ret

render_popover:
    push %rbp
    mov %rsp, %rbp

    # Card background (x=12, y=52, w=230, h=176)
    mov $12, %edi
    mov $52, %esi
    mov $230, %edx
    mov $176, %ecx
    mov $COL_POPOVER_BG, %r8d
    mov $COL_POPOVER_BRD, %r9d
    sub $8, %rsp
    movq $12, (%rsp)
    call draw_squircle
    add $8, %rsp

    # Item 0: Basic Mode
    mov $COL_POPOVER_BG, %r8d
    cmpl $0, hover_menu(%rip)
    jne .m0_nh
    mov $COL_POPOVER_HOV, %r8d
.m0_nh:
    mov $16, %edi
    mov $56, %esi
    mov $222, %edx
    mov $36, %ecx
    call draw_rect

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
    mov $COL_POPOVER_BG, %r8d
    cmpl $1, hover_menu(%rip)
    jne .m1_nh
    mov $COL_POPOVER_HOV, %r8d
.m1_nh:
    mov $16, %edi
    mov $94, %esi
    mov $222, %edx
    mov $36, %ecx
    call draw_rect

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
    mov $COL_POPOVER_BG, %r8d
    cmpl $2, hover_menu(%rip)
    jne .m2_nh
    mov $COL_POPOVER_HOV, %r8d
.m2_nh:
    mov $16, %edi
    mov $132, %esi
    mov $222, %edx
    mov $36, %ecx
    call draw_rect

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

    # Separator at y=172
    mov $20, %edi
    mov $172, %esi
    mov $214, %edx
    mov $1, %ecx
    mov $COL_POPOVER_BRD, %r8d
    call draw_rect

    # Item 3: Clear History
    mov $COL_POPOVER_BG, %r8d
    cmpl $3, hover_menu(%rip)
    jne .m3_nh
    mov $COL_POPOVER_HOV, %r8d
.m3_nh:
    mov $16, %edi
    mov $178, %esi
    mov $222, %edx
    mov $36, %ecx
    call draw_rect

    mov $40, %edi
    mov $188, %esi
    lea str_menu_clear(%rip), %rdx
    mov $COL_DEST, %r8d
    mov $1, %r9d
    call draw_string

    leave
    ret

# ==============================================================================
# X11 Event Dispatcher
# ==============================================================================

handle_x11_event:
    push %rbp
    mov %rsp, %rbp

    movzbq ev_packet(%rip), %rax
    and $0x7F, %rax

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
    movl $1, dirty(%rip)
    jmp .h_done

.ev_motion:
    movswl ev_packet+24(%rip), %ecx
    movswl ev_packet+26(%rip), %edx

    mov menu_open(%rip), %eax
    test %eax, %eax
    jz .chk_btn_hov

    cmp $12, %ecx
    jl .no_m_hov
    cmp $242, %ecx
    jg .no_m_hov
    cmp $56, %edx
    jl .no_m_hov
    cmp $214, %edx
    jg .no_m_hov

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
    movzbq ev_packet+1(%rip), %rax
    cmp $1, %rax
    jne .h_done

    movswl ev_packet+24(%rip), %ecx
    movswl ev_packet+26(%rip), %edx

    # 1. Popover open check
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
    movl $0, menu_open(%rip)
    movl $1, dirty(%rip)
    jmp .h_done

.check_header_click:
    cmp $50, %edx
    jge .check_keypad_click

    cmp $12, %ecx
    jl .chk_close
    cmp $48, %ecx
    jg .chk_close
    cmp $8, %edx
    jl .chk_close
    cmp $42, %edx
    jg .chk_close
    xorl $1, menu_open(%rip)
    movl $1, dirty(%rip)
    jmp .h_done

.chk_close:
    cmp $372, %ecx
    jl .header_drag
    cmp $408, %ecx
    jg .header_drag
    cmp $8, %edx
    jl .header_drag
    cmp $42, %edx
    jg .header_drag
    jmp exit_clean

.header_drag:
    call x11_start_drag
    jmp .h_done

.check_keypad_click:
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    jne .chk_kp_y
    cmp $108, %edx
    jl .chk_kp_y
    cmp $192, %edx
    jge .chk_kp_y
    mov %edx, %eax
    sub $108, %eax
    xor %edx, %edx
    mov $20, %esi
    div %esi
    cmp $3, %eax
    jle .sb_ok
    mov $3, %eax
.sb_ok:
    mov %eax, curr_base(%rip)
    call update_prog_readouts
    movl $1, dirty(%rip)
    jmp .h_done

.chk_kp_y:
    cmp $216, %edx
    jl .h_done
    mov curr_mode(%rip), %eax
    cmp $1, %eax
    je .click_adv
    cmp $2, %eax
    je .click_prog

    # Basic keypad click
    mov %ecx, %eax
    sub $16, %eax
    js .h_done
    xor %edx, %edx
    mov $99, %esi
    div %esi
    cmp $4, %eax
    jge .h_done
    mov %eax, %r14d

    movswl ev_packet+26(%rip), %eax
    sub $216, %eax
    js .h_done
    xor %edx, %edx
    mov $90, %esi
    div %esi
    cmp $5, %eax
    jge .h_done
    mov %eax, %r13d

    imul $4, %r13d, %eax
    add %r14d, %eax
    call exec_basic_key
    movl $1, dirty(%rip)
    jmp .h_done

.click_adv:
    mov %ecx, %eax
    sub $16, %eax
    js .h_done
    xor %edx, %edx
    mov $79, %esi
    div %esi
    cmp $5, %eax
    jge .h_done
    mov %eax, %r14d

    movswl ev_packet+26(%rip), %eax
    sub $216, %eax
    js .h_done
    xor %edx, %edx
    mov $74, %esi
    div %esi
    cmp $6, %eax
    jge .h_done
    mov %eax, %r13d

    imul $5, %r13d, %eax
    add %r14d, %eax
    call exec_adv_key
    movl $1, dirty(%rip)
    jmp .h_done

.click_prog:
    mov %ecx, %eax
    sub $16, %eax
    js .h_done
    xor %edx, %edx
    mov $79, %esi
    div %esi
    cmp $5, %eax
    jge .h_done
    mov %eax, %r14d

    movswl ev_packet+26(%rip), %eax
    sub $216, %eax
    js .h_done
    xor %edx, %edx
    mov $74, %esi
    div %esi
    cmp $6, %eax
    jge .h_done
    mov %eax, %r13d

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
    movzbq ev_packet+1(%rip), %rax
    cmp $9, %rax
    je .k_clear
    cmp $54, %rax
    je .k_clear
    cmp $36, %rax
    je .k_eval
    cmp $104, %rax
    je .k_eval
    cmp $22, %rax
    je .k_bksp
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
    cmp $19, %rax
    jne .k_chk_sym
    movb $'0', %al
    call append_disp_char
    movl $1, dirty(%rip)
    jmp .h_done
.k_chk_sym:
    cmp $60, %rax
    je .k_dot
    cmp $61, %rax
    je .k_div
    cmp $106, %rax
    je .k_div
    cmp $20, %rax
    je .k_sub
    cmp $82, %rax
    je .k_sub
    cmp $86, %rax
    je .k_add
    cmp $63, %rax
    je .k_mul
    cmp $21, %rax
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
    mov ev_packet+12(%rip), %eax
    cmp atom_wm_del(%rip), %eax
    je exit_clean
    jmp .h_done

.h_done:
    leave
    ret
