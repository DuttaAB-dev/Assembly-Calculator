# ==============================================================================
# Pure x86_64 Assembly Libadwaita Complex Calculator
# Core Arithmetic & Computation Engine (calc_core.s)
#
# Free of C runtime (libc), dynamic linkers, Python, or external dependencies.
# Direct hardware instructions: x87 FPU, 64-bit integer ALU, and string parsing.
# ==============================================================================

# ------------------------------------------------------------------------------
# Exported Global Symbols (Interface to calc_ui.s)
# ------------------------------------------------------------------------------
.global append_disp_char, clear_disp, bksp_disp, toggle_sign
.global exec_basic_key, exec_adv_key, exec_prog_key
.global eval_expression, update_prog_readouts
.global parse_double, format_double, parse_int64, format_current_base
.global op_add, op_sub, op_mul, op_div, op_percent, op_pow, op_lparen, op_rparen
.global build_live_preview, paren_depth, preview_buf

# ------------------------------------------------------------------------------
# External State Variables & History Callbacks (Defined in calc_ui.s)
# ------------------------------------------------------------------------------
.extern disp_buf         # Main numeric entry string buffer (null-terminated)
.extern hist_buf         # Previous calculation expression history string
.extern hex_buf          # Programmer Mode: Hexadecimal readout buffer
.extern dec_buf          # Programmer Mode: Decimal readout buffer
.extern oct_buf          # Programmer Mode: Octal readout buffer
.extern bin_buf          # Programmer Mode: Binary readout buffer
.extern curr_mode        # 0 = Basic, 1 = Scientific, 2 = Programmer
.extern curr_base        # Programmer radix: 0 = HEX, 1 = DEC, 2 = OCT, 3 = BIN
.extern pending_op       # Operator ID: 1=+, 2=-, 3=*, 4=/, 7=&, 8=|, 9=^, 10=<<, 11=>>
.extern clr_next         # Flag: 1 if next entered digit should clear display buffer
.extern acc_val          # 64-bit IEEE-754 double precision accumulator
.extern acc_int          # 64-bit integer accumulator for programmer mode
.extern dirty            # Repaint flag for the UI rendering loop
.extern commit_history   # Records completed calculation into history journal
.extern clear_history    # Clears all recorded calculations
.extern preview_buf, paren_depth, paren_stack_acc, paren_stack_op

# ==============================================================================
# Read-Only Data Section (Math Constants & Error Strings)
# ==============================================================================
.section .rodata
.align 8

# Floating-point constants for decimal conversion and scientific functions
fp_hundred: .double 100.0                   # Multiplier/divisor for percentage
fp_ten:     .double 10.0                    # Base-10 multiplier for digit extraction
fp_eps:     .double 0.00000001              # Epsilon threshold for zero rounding (1e-8)
fp_deg2rad: .double 0.017453292519943295    # Multiplier: Degrees to Radians (pi / 180)
fp_rad2deg: .double 57.29577951308232       # Multiplier: Radians to Degrees (180 / pi)
fp_e:       .double 2.71828182845904523536  # Euler's number (e)

# Informative UI error messages
str_err_div: .asciz "Cannot divide by 0"     # Displayed on division by zero
str_err_nan: .asciz "Error"                  # Displayed on NaN or Infinity overflow

# Scientific Function History Formatting Prefixes
str_fn_sin:  .asciz "sin("
str_fn_cos:  .asciz "cos("
str_fn_tan:  .asciz "tan("
str_fn_sqrt: .asciz "√("
str_fn_inv:  .asciz "1/("
str_fn_ln:   .asciz "ln("
str_fn_log:  .asciz "log("
str_fn_pi:   .asciz "π ="
str_fn_e:    .asciz "e ="
str_fn_abs:  .asciz "abs("
str_fn_10x:  .asciz "10^("
str_fn_pow:  .asciz " ^ "

# Programmer Mode History Symbols
str_sym_and: .asciz " & "
str_sym_or:  .asciz " | "
str_sym_xor: .asciz " ^ "
str_sym_shl: .asciz " << "
str_sym_shr: .asciz " >> "

# ==============================================================================
# Executable Code Section (.text)
# ==============================================================================
.section .text

# ------------------------------------------------------------------------------
# append_disp_char:
# Appends a single ASCII character (digit, decimal point, etc.) to disp_buf.
# ------------------------------------------------------------------------------
append_disp_char:
    push %rax

    mov curr_mode(%rip), %edx
    cmp $2, %edx
    jne .ap_check_dot

    # Programmer Mode:
    # Reject decimal point completely
    cmpb $'.', %al
    je .ap_drop

    # Base-specific character validation
    mov curr_base(%rip), %edx
    cmp $0, %edx
    je .ap_val_hex
    cmp $1, %edx
    je .ap_val_dec
    cmp $2, %edx
    je .ap_val_oct
    cmp $3, %edx
    je .ap_val_bin
    jmp .ap_valid

.ap_val_hex:
    cmpb $'0', %al; jl .ap_drop
    cmpb $'9', %al; jle .ap_valid
    cmpb $'A', %al; jl .ap_drop
    cmpb $'F', %al; jle .ap_valid
    cmpb $'a', %al; jl .ap_drop
    cmpb $'f', %al; jg .ap_drop
    sub $'a' - 'A', %al         # Normalize to uppercase
    jmp .ap_valid

.ap_val_dec:
    cmpb $'0', %al; jl .ap_drop
    cmpb $'9', %al; jg .ap_drop
    jmp .ap_valid

.ap_val_oct:
    cmpb $'0', %al; jl .ap_drop
    cmpb $'7', %al; jg .ap_drop
    jmp .ap_valid

.ap_val_bin:
    cmpb $'0', %al; jl .ap_drop
    cmpb $'1', %al; jg .ap_drop
    jmp .ap_valid

.ap_check_dot:
    # Basic / Scientific Mode:
    # Prevent duplicate decimal points in active number
    cmpb $'.', %al
    jne .ap_valid

    lea disp_buf(%rip), %rsi
    xor %rcx, %rcx
.ap_dot_scan:
    movzbq (%rsi, %rcx), %rdx
    test %dl, %dl
    jz .ap_valid
    cmpb $'.', %dl
    je .ap_drop                 # Duplicate decimal point -> ignore
    inc %rcx
    jmp .ap_dot_scan

.ap_drop:
    pop %rax
    ret

.ap_valid:
    mov clr_next(%rip), %edx
    test %edx, %edx
    jz .ap_cont
    movb $0, disp_buf(%rip)     # Clear buffer to empty string
    movl $0, clr_next(%rip)     # Reset clear-on-next flag

.ap_cont:
    pop %rax                    # Restore character to append in %al
    lea disp_buf(%rip), %rsi    # %rsi = pointer to start of disp_buf
    xor %rcx, %rcx              # %rcx = character length counter

.ap_len:
    cmpb $0, (%rsi, %rcx)       # Look for null terminator
    jz .ap_insert
    inc %rcx
    cmp $28, %rcx               # Maximum allowed display length = 28 chars
    jge .ap_ret                 # If limit reached, ignore extra keystrokes
    jmp .ap_len

.ap_insert:
    cmp $1, %rcx
    jne .do_ap
    cmpb $'0', (%rsi)
    jne .do_ap
    cmpb $'.', %al              # If typing '.', keep "0."
    je .do_ap
    movb %al, (%rsi)            # Overwrite '0' with new digit
    jmp .ap_sync_prog

.do_ap:
    movb %al, (%rsi, %rcx)
    movb $0, 1(%rsi, %rcx)

.ap_sync_prog:
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    jne .ap_ret
    call update_prog_readouts

.ap_ret:
    ret

# ------------------------------------------------------------------------------
clear_disp:
    lea disp_buf(%rip), %rdi
    movb $'0', (%rdi)           # Display resets to default "0"
    movb $0, 1(%rdi)            # Null terminate
    movb $0, hist_buf(%rip)     # Reset expression history string
    movl $0, pending_op(%rip)   # Clear pending operator
    movl $0, clr_next(%rip)     # Reset clear-on-next flag
    movl $0, paren_depth(%rip)  # Reset parentheses stack
    movq $0, acc_val(%rip)      # Reset floating-point accumulator to 0.0
    movq $0, acc_int(%rip)      # Reset integer accumulator to 0

    mov curr_mode(%rip), %eax
    cmp $2, %eax
    jne .cd_done
    call update_prog_readouts
.cd_done:
    ret

# ------------------------------------------------------------------------------
# bksp_disp:
# Erases rightmost character in disp_buf.
# ------------------------------------------------------------------------------
bksp_disp:
    lea disp_buf(%rip), %rdi
    xor %rcx, %rcx

.bkl:
    cmpb $0, (%rdi, %rcx)
    jz .bk_found
    inc %rcx
    jmp .bkl

.bk_found:
    cmp $1, %rcx
    jle .bk_reset
    dec %rcx
    movb $0, (%rdi, %rcx)
    jmp .bk_check_prog

.bk_reset:
    movb $'0', (%rdi)
    movb $0, 1(%rdi)

.bk_check_prog:
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    jne .bk_done
    call update_prog_readouts
.bk_done:
    ret

# ------------------------------------------------------------------------------
# toggle_sign:
# Inverts numeric sign (+/-).
# ------------------------------------------------------------------------------
toggle_sign:
    lea disp_buf(%rip), %rdi
    cmpb $'0', (%rdi)
    jne .ts_check_neg
    cmpb $0, 1(%rdi)
    je .ts_ret

.ts_check_neg:
    cmpb $'-', (%rdi)
    jne .ts_add_neg

    mov %rdi, %rsi
    inc %rsi
.ts_copy:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rdi
    inc %rsi
    test %al, %al
    jnz .ts_copy
    jmp .ts_check_prog

.ts_add_neg:
    mov $30, %rcx
.ts_shift:
    movb (%rdi, %rcx), %al
    movb %al, 1(%rdi, %rcx)
    dec %rcx
    jns .ts_shift
    movb $'-', (%rdi)

.ts_check_prog:
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    jne .ts_ret
    call update_prog_readouts
.ts_ret:
    ret

# ------------------------------------------------------------------------------
# op_percent:
# Percentage calculation: divides active display value by 100.
# ------------------------------------------------------------------------------
op_percent:
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    je .pct_ret

    lea disp_buf(%rip), %rsi
    cmpb $0, (%rsi)
    je .pct_ret

    call parse_double                    # ST(0) = parsed display value
    fldl fp_hundred(%rip)                # ST(0) = 100.0, ST(1) = val
    fdivrp %st, %st(1)                   # ST(0) = val / 100.0

    lea disp_buf(%rip), %rdi
    call format_double
    movl $1, clr_next(%rip)
.pct_ret:
    ret

# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# op_lparen:
# Pushes current accumulator and pending operator onto paren stack.
# ------------------------------------------------------------------------------
op_lparen:
    mov paren_depth(%rip), %eax
    cmp $15, %eax
    jge .lp_ret

    shl $3, %rax                         # depth * 8
    lea paren_stack_acc(%rip), %rdx
    movsd acc_val(%rip), %xmm0
    movsd %xmm0, (%rdx, %rax)
    shr $1, %rax                         # depth * 4
    lea paren_stack_op(%rip), %rdx
    mov pending_op(%rip), %ecx
    mov %ecx, (%rdx, %rax)
    incl paren_depth(%rip)

    movq $0, acc_val(%rip)
    movl $0, pending_op(%rip)
    movl $1, clr_next(%rip)

    lea hist_buf(%rip), %rdi
.lp_find:
    cmpb $0, (%rdi)
    jz .lp_app
    inc %rdi
    jmp .lp_find
.lp_app:
    movb $'(', (%rdi)
    movb $0, 1(%rdi)
.lp_ret:
    ret

# ------------------------------------------------------------------------------
# op_rparen:
# Evaluates pending inner expression, restores parent accumulator and op.
# ------------------------------------------------------------------------------
op_rparen:
    mov paren_depth(%rip), %eax
    test %eax, %eax
    jz .rp_ret

    mov pending_op(%rip), %edx
    test %edx, %edx
    jz .rp_no_eval
    call eval_math_only
.rp_no_eval:
    lea hist_buf(%rip), %rdi
.rp_find:
    cmpb $0, (%rdi)
    jz .rp_app_disp
    inc %rdi
    jmp .rp_find
.rp_app_disp:
    movb $')', (%rdi)
    movb $0, 1(%rdi)

    decl paren_depth(%rip)
    mov paren_depth(%rip), %eax
    shl $3, %rax
    lea paren_stack_acc(%rip), %rdx
    movsd (%rdx, %rax), %xmm0
    movsd %xmm0, acc_val(%rip)
    shr $1, %rax
    lea paren_stack_op(%rip), %rdx
    mov (%rdx, %rax), %ecx
    mov %ecx, pending_op(%rip)
    movl $1, clr_next(%rip)
.rp_ret:
    ret

# ------------------------------------------------------------------------------
# op_pow:
# Power operator (^).
# ------------------------------------------------------------------------------
op_pow:
    mov $5, %edi
    movb $'^', %sil
    jmp apply_op

exec_basic_key:
    cmp $0, %eax; je clear_disp
    cmp $1, %eax; je op_lparen
    cmp $2, %eax; je op_rparen
    cmp $3, %eax; je bksp_disp
    cmp $4, %eax; je op_percent
    cmp $5, %eax; je .f_sqrt
    cmp $6, %eax; je .f_sq
    cmp $7, %eax; je op_div
    cmp $8, %eax; je .d7
    cmp $9, %eax; je .d8
    cmp $10, %eax; je .d9
    cmp $11, %eax; je op_mul
    cmp $12, %eax; je .d4
    cmp $13, %eax; je .d5
    cmp $14, %eax; je .d6
    cmp $15, %eax; je op_sub
    cmp $16, %eax; je .d1
    cmp $17, %eax; je .d2
    cmp $18, %eax; je .d3
    cmp $19, %eax; je op_add
    cmp $20, %eax; je toggle_sign
    cmp $21, %eax; je .d0
    cmp $22, %eax; je .d_dot
    cmp $23, %eax; je eval_expression
    ret

.d7: movb $'7', %al; jmp append_disp_char
.d8: movb $'8', %al; jmp append_disp_char
.d9: movb $'9', %al; jmp append_disp_char
.d4: movb $'4', %al; jmp append_disp_char
.d5: movb $'5', %al; jmp append_disp_char
.d6: movb $'6', %al; jmp append_disp_char
.d1: movb $'1', %al; jmp append_disp_char
.d2: movb $'2', %al; jmp append_disp_char
.d3: movb $'3', %al; jmp append_disp_char
.d0: movb $'0', %al; jmp append_disp_char
.d_dot: movb $'.', %al; jmp append_disp_char
.d_lparen: movb $'(', %al; jmp append_disp_char

# ------------------------------------------------------------------------------
# Operator Handlers (+, -, *, /)
# ------------------------------------------------------------------------------
op_add:
    mov $1, %edi
    movb $'+', %sil
    jmp apply_op

op_sub:
    mov $2, %edi
    movb $'-', %sil
    jmp apply_op

op_mul:
    mov $3, %edi
    movb $132, %sil             # '×'
    jmp apply_op

op_div:
    mov $4, %edi
    movb $131, %sil             # '÷'
    jmp apply_op

# ------------------------------------------------------------------------------
# apply_op:
# Prepares or chains a binary operator (+, -, ×, ÷).
# ------------------------------------------------------------------------------
apply_op:
    push %rdi
    push %rsi

    mov curr_mode(%rip), %eax
    cmp $2, %eax
    je .ao_prog

    mov pending_op(%rip), %eax
    test %eax, %eax
    jz .ao_fresh

    mov clr_next(%rip), %eax
    test %eax, %eax
    jnz .ao_update_sym

    call eval_math_only

.ao_fresh:
    lea disp_buf(%rip), %rsi
    call parse_double
    fstpl acc_val(%rip)

.ao_update_sym:
    lea hist_buf(%rip), %rdi
    lea disp_buf(%rip), %rsi
.ao_cpy:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rdi
    inc %rsi
    test %al, %al
    jnz .ao_cpy
    dec %rdi

    movb $' ', (%rdi)
    pop %rsi
    movb %sil, 1(%rdi)
    movb $' ', 2(%rdi)
    movb $0, 3(%rdi)

    pop %rdi
    mov %edi, pending_op(%rip)
    movl $1, clr_next(%rip)
    ret

.ao_prog:
    mov pending_op(%rip), %eax
    test %eax, %eax
    jz .ao_prog_fresh

    mov clr_next(%rip), %eax
    test %eax, %eax
    jnz .ao_prog_sym

    call eval_prog_math_only
    mov %rax, acc_int(%rip)
    mov %rax, %rdi
    lea disp_buf(%rip), %rsi
    call format_current_base
    call update_prog_readouts
    jmp .ao_prog_sym

.ao_prog_fresh:
    call parse_int64
    mov %rax, acc_int(%rip)

.ao_prog_sym:
    lea hist_buf(%rip), %rdi
    lea disp_buf(%rip), %rsi
.ao_prog_cpy:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rdi
    inc %rsi
    test %al, %al
    jnz .ao_prog_cpy
    dec %rdi

    movb $' ', (%rdi)
    pop %rsi
    movb %sil, 1(%rdi)
    movb $' ', 2(%rdi)
    movb $0, 3(%rdi)

    pop %rdi
    mov %edi, pending_op(%rip)
    movl $1, clr_next(%rip)
    ret

# ------------------------------------------------------------------------------
eval_expression:
    mov pending_op(%rip), %eax
    test %eax, %eax
    jz .ee_ret

    mov curr_mode(%rip), %edx
    cmp $2, %edx
    je eval_prog_op

    # Build hist_buf: hist_buf + disp_buf + " ="
    lea hist_buf(%rip), %rdi
.ee_find_end:
    cmpb $0, (%rdi)
    jz .ee_cat_disp
    inc %rdi
    jmp .ee_find_end

.ee_cat_disp:
    lea disp_buf(%rip), %rsi
.ee_cpy2:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rdi
    inc %rsi
    test %al, %al
    jnz .ee_cpy2
    dec %rdi
    movb $' ', (%rdi)
    movb $'=', 1(%rdi)
    movb $0, 2(%rdi)

    call eval_math_only
.ee_paren_loop:
    mov paren_depth(%rip), %eax
    test %eax, %eax
    jz .ee_paren_done
    decl paren_depth(%rip)
    mov paren_depth(%rip), %eax
    shl $3, %rax
    lea paren_stack_acc(%rip), %rdx
    movsd (%rdx, %rax), %xmm0
    movsd %xmm0, acc_val(%rip)
    shr $1, %rax
    lea paren_stack_op(%rip), %rdx
    mov (%rdx, %rax), %ecx
    mov %ecx, pending_op(%rip)
    test %ecx, %ecx
    jz .ee_paren_loop
    call eval_math_only
    jmp .ee_paren_loop
.ee_paren_done:
    call scifn_append_res       # Append result to hist_buf so both show final result
    call commit_history         # Record into history journal!
    movl $0, pending_op(%rip)
    movl $1, clr_next(%rip)
.ee_ret:
    ret

# ------------------------------------------------------------------------------
# eval_math_only:
# Executes pending binary operation on FPU stack.
# ------------------------------------------------------------------------------
eval_math_only:
    sub $16, %rsp
    fldl acc_val(%rip)
    lea disp_buf(%rip), %rsi
    call parse_double

    mov pending_op(%rip), %eax
    cmp $1, %eax
    je .emo_add
    cmp $2, %eax
    je .emo_sub
    cmp $3, %eax
    je .emo_mul
    cmp $4, %eax
    je .emo_div
    cmp $5, %eax
    je .emo_pow

    fstp %st(0)
    fstp %st(0)
    add $16, %rsp
    ret

.emo_pow:
    fyl2x
    fld %st(0)
    frndint
    fsubr %st(0), %st(1)
    fxch %st(1)
    f2xm1
    fld1
    faddp
    fscale
    fstp %st(1)
    jmp .emo_save

.emo_add:
    faddp
    jmp .emo_save

.emo_sub:
    fsubrp
    jmp .emo_save

.emo_mul:
    fmulp
    jmp .emo_save

.emo_div:
    fldz
    fcomip %st(1), %st(0)
    jne .emo_do_div

    fstp %st(0)
    fstp %st(0)
    lea disp_buf(%rip), %rdi
    lea str_err_div(%rip), %rsi
.emo_err_cpy:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rdi
    inc %rsi
    test %al, %al
    jnz .emo_err_cpy
    add $16, %rsp
    ret

.emo_do_div:
    fdivrp
    jmp .emo_save

.emo_save:
    fld %st(0)
    fstpl acc_val(%rip)
    lea disp_buf(%rip), %rdi
    call format_double
    add $16, %rsp
    ret

# ------------------------------------------------------------------------------
# parse_double:
# Converts ASCII string at %rsi into 80-bit float in ST(0).
# ------------------------------------------------------------------------------
parse_double:
    sub $32, %rsp
    movq $0, (%rsp)
    movq $0, 8(%rsp)

    xor %rax, %rax
    xor %r8d, %r8d

.pd_skip_ws:
    cmpb $' ', (%rsi)
    jne .pd_chk_sign
    inc %rsi
    jmp .pd_skip_ws

.pd_chk_sign:
    cmpb $'-', (%rsi)
    jne .pd_start
    inc %rsi
    mov $1, %r8d

.pd_start:
.pd_int:
    movzbq (%rsi), %rdx
    test %dl, %dl
    jz .pd_finish
    cmpb $'.', %dl
    je .pd_frac_start
    cmpb $'0', %dl
    jl .pd_finish
    cmpb $'9', %dl
    jg .pd_finish

    sub $'0', %rdx
    imul $10, %rax
    add %rdx, %rax
    inc %rsi
    jmp .pd_int

.pd_frac_start:
    inc %rsi
    mov %rax, (%rsp)
    fildq (%rsp)

    fldz
    fld1
.pd_frac:
    movzbq (%rsi), %rdx
    test %dl, %dl
    jz .pd_frac_end
    cmpb $'0', %dl
    jl .pd_frac_end
    cmpb $'9', %dl
    jg .pd_frac_end

    sub $'0', %rdx
    fmull fp_ten(%rip)
    mov %rdx, 8(%rsp)
    fildq 8(%rsp)
    fdiv %st(1), %st(0)
    faddp %st(0), %st(2)

    inc %rsi
    jmp .pd_frac

.pd_frac_end:
    fstp %st(0)
    faddp
    test %r8d, %r8d
    jz .pd_done
    fchs
.pd_done:
    add $32, %rsp
    ret

.pd_finish:
    mov %rax, (%rsp)
    fildq (%rsp)
    test %r8d, %r8d
    jz .pd_done
    fchs
    jmp .pd_done

# ------------------------------------------------------------------------------
# format_double:
# Formats ST(0) float into ASCII string at %rdi.
# ------------------------------------------------------------------------------
format_double:
    sub $64, %rsp
    mov %rdi, 32(%rsp)

    fxam
    fnstsw %ax
    and $0x4500, %ax
    cmp $0x0100, %ax
    je .fd_nan
    cmp $0x0500, %ax
    je .fd_nan

    ftst
    fnstsw %ax
    sahf
    jnc .fd_pos
    movb $'-', (%rdi)
    inc %rdi
    fchs

.fd_pos:
    fld %st(0)
    fisttpq 8(%rsp)
    mov 8(%rsp), %rax
    call int_to_str

    fildq 8(%rsp)
    fsubrp

    fldl fp_eps(%rip)
    fcomip %st(1), %st(0)
    jb .fd_has_frac

    fstp %st(0)
    movb $0, (%rdi)
    add $64, %rsp
    ret

.fd_has_frac:
    movb $'.', (%rdi)
    inc %rdi

    mov $6, %ecx
.fd_frac_loop:
    fmull fp_ten(%rip)
    fld %st(0)
    fisttpq 16(%rsp)
    mov 16(%rsp), %rax
    add $'0', %al
    movb %al, (%rdi)
    inc %rdi

    fildq 16(%rsp)
    fsubrp

    fldl fp_eps(%rip)
    fcomip %st(1), %st(0)
    jbe .fd_frac_cont
    jmp .fd_pop_frac

.fd_frac_cont:
    dec %ecx
    jnz .fd_frac_loop

.fd_pop_frac:
    fstp %st(0)
    movb $0, (%rdi)

    dec %rdi
.strip_loop:
    mov 32(%rsp), %rax
    cmp %rax, %rdi
    jle .fd_done
    cmpb $'0', (%rdi)
    jne .strip_check_dot
    movb $0, (%rdi)
    dec %rdi
    jmp .strip_loop

.strip_check_dot:
    cmpb $'.', (%rdi)
    jne .fd_done
    movb $0, (%rdi)

.fd_done:
    add $64, %rsp
    ret

.fd_nan:
    fstp %st(0)
    lea str_err_nan(%rip), %rsi
.fd_nan_cpy:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rdi
    inc %rsi
    test %al, %al
    jnz .fd_nan_cpy
    add $64, %rsp
    ret

# ------------------------------------------------------------------------------
# int_to_str:
# Converts unsigned 64-bit integer %rax to decimal string at %rdi.
# ------------------------------------------------------------------------------
int_to_str:
    sub $32, %rsp
    mov %rsp, %rsi
    add $30, %rsi
    movb $0, 1(%rsi)

    test %rax, %rax
    jnz .its_loop
    movb $'0', (%rdi)
    movb $0, 1(%rdi)
    inc %rdi
    add $32, %rsp
    ret

.its_loop:
    xor %rdx, %rdx
    mov $10, %rcx
    div %rcx
    add $'0', %dl
    movb %dl, (%rsi)
    dec %rsi
    test %rax, %rax
    jnz .its_loop

    inc %rsi
.its_copy:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rdi
    inc %rsi
    test %al, %al
    jnz .its_copy
    dec %rdi
    add $32, %rsp
    ret

# ------------------------------------------------------------------------------
# scifn_prep:
# Prepares history string for scientific functions:
# Builds: hist_buf = prefix + disp_buf + ") ="
# Input: %rsi -> null-terminated prefix string (e.g. "sin(")
# ------------------------------------------------------------------------------
scifn_prep:
    push %rbx
    lea hist_buf(%rip), %rdi
.sp_p_cpy:
    movb (%rsi), %al
    movb %al, (%rdi)
    test %al, %al
    jz .sp_d_start
    inc %rsi
    inc %rdi
    jmp .sp_p_cpy

.sp_d_start:
    lea disp_buf(%rip), %rsi
.sp_d_cpy:
    movb (%rsi), %al
    movb %al, (%rdi)
    test %al, %al
    jz .sp_end
    inc %rsi
    inc %rdi
    jmp .sp_d_cpy

.sp_end:
    movb $')', (%rdi)
    movb $' ', 1(%rdi)
    movb $'=', 2(%rdi)
    movb $0, 3(%rdi)
    pop %rbx
    ret

# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# scifn_append_res:
# Appends " " + disp_buf to hist_buf so the completed equation and answer are both visible.
# ------------------------------------------------------------------------------
scifn_append_res:
    lea hist_buf(%rip), %rdi
.sar_find:
    cmpb $0, (%rdi)
    jz .sar_app
    inc %rdi
    jmp .sar_find
.sar_app:
    cmp %rdi, hist_buf(%rip)
    je .sar_cpy_start
    cmpb $' ', -1(%rdi)
    je .sar_cpy_start
    movb $' ', (%rdi)
    inc %rdi
.sar_cpy_start:
    lea disp_buf(%rip), %rsi
.sar_cpy:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .sar_cpy
    ret

.f_abs:
    lea str_fn_abs(%rip), %rsi
    call scifn_prep
    lea disp_buf(%rip), %rsi
    call parse_double
    fabs
    lea disp_buf(%rip), %rdi
    call format_double
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

.f_10x:
    lea str_fn_10x(%rip), %rsi
    call scifn_prep
    fldl2t
    lea disp_buf(%rip), %rsi
    call parse_double
    fmulp
    fld %st(0)
    frndint
    fsubr %st(0), %st(1)
    fxch %st(1)
    f2xm1
    fld1
    faddp
    fscale
    fstp %st(1)
    lea disp_buf(%rip), %rdi
    call format_double
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

.f_fact:
    lea hist_buf(%rip), %rdi
    lea disp_buf(%rip), %rsi
.ff_cp:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .ff_cp
    dec %rdi
    movb $'!', (%rdi)
    movb $' ', 1(%rdi)
    movb $'=', 2(%rdi)
    movb $0, 3(%rdi)

    call parse_int64
    cmp $0, %rax
    jl .ff_err
    cmp $20, %rax
    jg .ff_err
    mov %rax, %rcx
    mov $1, %rax
    mov $1, %rsi
.ff_loop:
    cmp %rcx, %rsi
    jg .ff_calc_done
    imul %rsi, %rax
    inc %rsi
    jmp .ff_loop
.ff_calc_done:
    lea disp_buf(%rip), %rdi
    call int_to_str
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret
.ff_err:
    lea disp_buf(%rip), %rdi
    lea str_err_nan(%rip), %rsi
.ff_ecp:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .ff_ecp
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

exec_adv_key:
    cmp $0, %eax; je .f_sin
    cmp $1, %eax; je .f_ln
    cmp $2, %eax; je clear_disp
    cmp $3, %eax; je op_lparen
    cmp $4, %eax; je op_rparen
    cmp $5, %eax; je bksp_disp

    cmp $6, %eax; je .f_cos
    cmp $7, %eax; je .f_log
    cmp $8, %eax; je op_percent
    cmp $9, %eax; je .f_sqrt
    cmp $10, %eax; je .f_sq
    cmp $11, %eax; je op_div

    cmp $12, %eax; je .f_tan
    cmp $13, %eax; je op_pow
    cmp $14, %eax; je .d7
    cmp $15, %eax; je .d8
    cmp $16, %eax; je .d9
    cmp $17, %eax; je op_mul

    cmp $18, %eax; je .f_pi
    cmp $19, %eax; je .f_e
    cmp $20, %eax; je .d4
    cmp $21, %eax; je .d5
    cmp $22, %eax; je .d6
    cmp $23, %eax; je op_sub

    cmp $24, %eax; je .f_inv
    cmp $25, %eax; je .f_abs
    cmp $26, %eax; je .d1
    cmp $27, %eax; je .d2
    cmp $28, %eax; je .d3
    cmp $29, %eax; je op_add

    cmp $30, %eax; je .f_fact
    cmp $31, %eax; je .f_10x
    cmp $32, %eax; je toggle_sign
    cmp $33, %eax; je .d0
    cmp $34, %eax; je .d_dot
    cmp $35, %eax; je eval_expression
    ret

# --- Scientific Functions with Functional History & Auto-Commit ---
.f_sin:
    lea str_fn_sin(%rip), %rsi
    call scifn_prep
    lea disp_buf(%rip), %rsi
    call parse_double
    fmull fp_deg2rad(%rip)
    fsin
    lea disp_buf(%rip), %rdi
    call format_double
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

.f_cos:
    lea str_fn_cos(%rip), %rsi
    call scifn_prep
    lea disp_buf(%rip), %rsi
    call parse_double
    fmull fp_deg2rad(%rip)
    fcos
    lea disp_buf(%rip), %rdi
    call format_double
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

.f_tan:
    lea str_fn_tan(%rip), %rsi
    call scifn_prep
    lea disp_buf(%rip), %rsi
    call parse_double
    fmull fp_deg2rad(%rip)
    fptan
    fstp %st(0)
    lea disp_buf(%rip), %rdi
    call format_double
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

.f_pi:
    lea hist_buf(%rip), %rdi
    lea str_fn_pi(%rip), %rsi
.pi_cp:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .pi_cp

    fldpi
    lea disp_buf(%rip), %rdi
    call format_double
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

.f_e:
    lea hist_buf(%rip), %rdi
    lea str_fn_e(%rip), %rsi
.e_cp:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .e_cp

    fldl fp_e(%rip)
    lea disp_buf(%rip), %rdi
    call format_double
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

.f_sqrt:
    lea str_fn_sqrt(%rip), %rsi
    call scifn_prep
    lea disp_buf(%rip), %rsi
    call parse_double
    fsqrt
    lea disp_buf(%rip), %rdi
    call format_double
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

.f_sq:
    # Build hist_buf: disp_buf + "^2 ="
    lea hist_buf(%rip), %rdi
    lea disp_buf(%rip), %rsi
.sq_cp:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .sq_cp
    dec %rdi
    movb $'^', (%rdi)
    movb $'2', 1(%rdi)
    movb $' ', 2(%rdi)
    movb $'=', 3(%rdi)
    movb $0, 4(%rdi)

    lea disp_buf(%rip), %rsi
    call parse_double
    fld %st(0)
    fmulp
    lea disp_buf(%rip), %rdi
    call format_double
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

.f_inv:
    lea str_fn_inv(%rip), %rsi
    call scifn_prep
    lea disp_buf(%rip), %rsi
    call parse_double
    fld1
    fdivp
    lea disp_buf(%rip), %rdi
    call format_double
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

.f_ln:
    lea str_fn_ln(%rip), %rsi
    call scifn_prep
    fldln2
    lea disp_buf(%rip), %rsi
    call parse_double
    fyl2x
    lea disp_buf(%rip), %rdi
    call format_double
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

.f_log:
    lea str_fn_log(%rip), %rsi
    call scifn_prep
    fldlg2
    lea disp_buf(%rip), %rsi
    call parse_double
    fyl2x
    lea disp_buf(%rip), %rdi
    call format_double
    call scifn_append_res
    call commit_history
    movl $1, clr_next(%rip)
    ret

# ------------------------------------------------------------------------------
# prog_op_prep:
# Prepares history for programmer bitwise operations.
# Input: %rsi -> operator string (e.g. " & ")
# ------------------------------------------------------------------------------
prog_op_prep:
    push %rsi
    lea hist_buf(%rip), %rdi
    lea disp_buf(%rip), %rsi
.pop_cp:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .pop_cp
    dec %rdi
    pop %rsi
.pop_s_cp:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .pop_s_cp
    ret

# ------------------------------------------------------------------------------
# exec_prog_key:
# Dispatches keypad click events for Programmer Calculator mode.
# ------------------------------------------------------------------------------
exec_prog_key:
    cmp $0, %eax; je .p_and
    cmp $1, %eax; je .p_or
    cmp $2, %eax; je .p_xor
    cmp $3, %eax; je .p_not
    cmp $4, %eax; je clear_disp

    cmp $5, %eax; je .p_shl
    cmp $6, %eax; je .p_shr
    cmp $7, %eax; je .hex_A
    cmp $8, %eax; je .hex_B
    cmp $9, %eax; je bksp_disp

    cmp $10, %eax; je .d7
    cmp $11, %eax; je .d8
    cmp $12, %eax; je .d9
    cmp $13, %eax; je .hex_C
    cmp $14, %eax; je op_div

    cmp $15, %eax; je .d4
    cmp $16, %eax; je .d5
    cmp $17, %eax; je .d6
    cmp $18, %eax; je .hex_D
    cmp $19, %eax; je op_mul

    cmp $20, %eax; je .d1
    cmp $21, %eax; je .d2
    cmp $22, %eax; je .d3
    cmp $23, %eax; je .hex_E
    cmp $24, %eax; je op_sub

    cmp $25, %eax; je .d0
    cmp $26, %eax; je toggle_sign
    cmp $27, %eax; je eval_expression
    cmp $28, %eax; je .hex_F
    cmp $29, %eax; je op_add
    ret

.hex_A: movb $'A', %al; call append_disp_char; call update_prog_readouts; ret
.hex_B: movb $'B', %al; call append_disp_char; call update_prog_readouts; ret
.hex_C: movb $'C', %al; call append_disp_char; call update_prog_readouts; ret
.hex_D: movb $'D', %al; call append_disp_char; call update_prog_readouts; ret
.hex_E: movb $'E', %al; call append_disp_char; call update_prog_readouts; ret
.hex_F: movb $'F', %al; call append_disp_char; call update_prog_readouts; ret

apply_prog_bitwise:
    push %rdi
    push %rsi

    mov pending_op(%rip), %eax
    test %eax, %eax
    jz .apb_fresh

    mov clr_next(%rip), %eax
    test %eax, %eax
    jnz .apb_sym

    call eval_prog_math_only
    mov %rax, acc_int(%rip)
    mov %rax, %rdi
    lea disp_buf(%rip), %rsi
    call format_current_base
    call update_prog_readouts

.apb_sym:
    pop %rsi
    call prog_op_prep
    pop %rdi
    mov %edi, pending_op(%rip)
    movl $1, clr_next(%rip)
    ret

.apb_fresh:
    call parse_int64
    mov %rax, acc_int(%rip)
    jmp .apb_sym

.p_and:
    mov $7, %edi
    lea str_sym_and(%rip), %rsi
    jmp apply_prog_bitwise

.p_or:
    mov $8, %edi
    lea str_sym_or(%rip), %rsi
    jmp apply_prog_bitwise

.p_xor:
    mov $9, %edi
    lea str_sym_xor(%rip), %rsi
    jmp apply_prog_bitwise

.p_not:
    # Build hist_buf: "~" + disp_buf + " ="
    lea hist_buf(%rip), %rdi
    movb $'~', (%rdi)
    inc %rdi
    lea disp_buf(%rip), %rsi
.pnot_cp:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .pnot_cp
    dec %rdi
    movb $' ', (%rdi)
    movb $'=', 1(%rdi)
    movb $0, 2(%rdi)

    call parse_int64
    not %rax
    mov %rax, %rdi
    lea disp_buf(%rip), %rsi
    call format_current_base
    call update_prog_readouts
    call commit_history
    movl $1, clr_next(%rip)
    ret

.p_shl:
    mov $10, %edi
    lea str_sym_shl(%rip), %rsi
    jmp apply_prog_bitwise

.p_shr:
    mov $11, %edi
    lea str_sym_shr(%rip), %rsi
    jmp apply_prog_bitwise

# ------------------------------------------------------------------------------
# eval_prog_math_only:
# Executes pending 64-bit integer arithmetic/bitwise operation on acc_int and disp_buf.
# Returns computed 64-bit integer in %rax.
# ------------------------------------------------------------------------------
eval_prog_math_only:
    call parse_int64
    mov %rax, %r8               # Second operand in %r8
    mov acc_int(%rip), %rax     # First operand

    mov pending_op(%rip), %ecx
    cmp $1, %ecx; je .po_add
    cmp $2, %ecx; je .po_sub
    cmp $3, %ecx; je .po_mul
    cmp $4, %ecx; je .po_div
    cmp $7, %ecx; je .po_and
    cmp $8, %ecx; je .po_or
    cmp $9, %ecx; je .po_xor
    cmp $10, %ecx; je .po_shl
    cmp $11, %ecx; je .po_shr
    ret

.po_add: add %r8, %rax; ret
.po_sub: sub %r8, %rax; ret
.po_mul: imul %r8, %rax; ret
.po_div:
    test %r8, %r8
    jz .po_div_zero
    cqo
    idiv %r8
    ret
.po_div_zero:
    xor %rax, %rax
    ret

.po_and: and %r8, %rax; ret
.po_or:  or %r8, %rax;  ret
.po_xor: xor %r8, %rax; ret
.po_shl:
    mov %r8b, %cl
    shl %cl, %rax
    ret
.po_shr:
    mov %r8b, %cl
    shr %cl, %rax
    ret

# ------------------------------------------------------------------------------
# eval_prog_op:
# Evaluates 64-bit integer arithmetic and bitwise operations in Programmer Mode.
# ------------------------------------------------------------------------------
eval_prog_op:
    # Append disp_buf + " =" to hist_buf
    lea hist_buf(%rip), %rdi
.epo_end:
    cmpb $0, (%rdi)
    jz .epo_cp
    inc %rdi
    jmp .epo_end
.epo_cp:
    lea disp_buf(%rip), %rsi
.epo_cp2:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .epo_cp2
    dec %rdi
    movb $' ', (%rdi)
    movb $'=', 1(%rdi)
    movb $0, 2(%rdi)

    call eval_prog_math_only

    mov %rax, acc_int(%rip)
    mov %rax, %rdi
    lea disp_buf(%rip), %rsi
    call format_current_base
    call update_prog_readouts
    call scifn_append_res
    call commit_history         # Record into history journal!
    movl $0, pending_op(%rip)
    movl $1, clr_next(%rip)
    ret

# ------------------------------------------------------------------------------
format_current_base:
    mov curr_base(%rip), %eax
    cmp $0, %eax; je format_hex_raw
    cmp $1, %eax; je format_dec
    cmp $2, %eax; je format_oct_raw
    cmp $3, %eax; je format_bin_raw
    jmp format_dec

format_hex_raw:
    mov %rdi, %rax
    mov %rsi, %rdi
    mov $16, %ecx
.fhr_l:
    dec %ecx
    js .fhr_zero
    mov %rax, %rdx
    shr $60, %rdx
    shl $4, %rax
    test %rdx, %rdx
    jz .fhr_l
    jmp .fhr_emit

.fhr_zero:
    movb $'0', (%rdi)
    movb $0, 1(%rdi)
    ret

.fhr_emit:
    cmp $10, %dl
    jl .fhr_d
    add $'A' - 10, %dl
    jmp .fhr_w
.fhr_d:
    add $'0', %dl
.fhr_w:
    movb %dl, (%rdi)
    inc %rdi
    dec %ecx
    js .fhr_end
    mov %rax, %rdx
    shr $60, %rdx
    shl $4, %rax
    jmp .fhr_emit
.fhr_end:
    movb $0, (%rdi)
    ret

format_oct_raw:
    mov %rdi, %rax
    mov %rsi, %rdi
    sub $32, %rsp
    mov %rsp, %rsi
    add $30, %rsi
    movb $0, 1(%rsi)

    test %rax, %rax
    jnz .for_loop
    movb $'0', (%rdi)
    movb $0, 1(%rdi)
    add $32, %rsp
    ret

.for_loop:
    mov %rax, %rdx
    and $7, %rdx
    shr $3, %rax
    add $'0', %dl
    movb %dl, (%rsi)
    dec %rsi
    test %rax, %rax
    jnz .for_loop

    inc %rsi
.for_copy:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rdi
    inc %rsi
    test %al, %al
    jnz .for_copy
    add $32, %rsp
    ret

format_bin_raw:
    mov %rdi, %rax
    mov %rsi, %rdi
    mov $63, %ecx
.fbr_find:
    bt %rcx, %rax
    jc .fbr_found
    dec %ecx
    jns .fbr_find

    movb $'0', (%rdi)
    movb $0, 1(%rdi)
    ret

.fbr_found:
.fbr_emit:
    bt %rcx, %rax
    jc .fbr_one
    movb $'0', (%rdi)
    jmp .fbr_nxt
.fbr_one:
    movb $'1', (%rdi)
.fbr_nxt:
    inc %rdi
    dec %ecx
    jns .fbr_emit
    movb $0, (%rdi)
    ret

parse_int64:
    lea disp_buf(%rip), %rsi
    xor %rax, %rax
    mov curr_base(%rip), %r8d
    xor %r9d, %r9d                      # is_negative = 0

    cmpb $'-', (%rsi)
    jne .pi_loop
    inc %rsi
    mov $1, %r9d                        # is_negative = 1

.pi_loop:
    movzbq (%rsi), %rdx
    test %dl, %dl
    jz .pi_done

    cmp $0, %r8d
    je .pi_hex
    cmp $2, %r8d
    je .pi_oct
    cmp $3, %r8d
    je .pi_bin

    cmpb $'0', %dl; jl .pi_done
    cmpb $'9', %dl; jg .pi_done
    sub $'0', %rdx
    imul $10, %rax
    add %rdx, %rax
    inc %rsi
    jmp .pi_loop

.pi_hex:
    cmpb $'0', %dl; jl .pi_done
    cmpb $'9', %dl; jle .pih_dig
    cmpb $'A', %dl; jl .pi_done
    cmpb $'F', %dl; jle .pih_upper
    cmpb $'a', %dl; jl .pi_done
    cmpb $'f', %dl; jle .pih_lower
    jmp .pi_done
.pih_dig:
    sub $'0', %rdx
    jmp .pih_accum
.pih_upper:
    sub $'A' - 10, %rdx
    jmp .pih_accum
.pih_lower:
    sub $'a' - 10, %rdx
.pih_accum:
    shl $4, %rax
    add %rdx, %rax
    inc %rsi
    jmp .pi_loop

.pi_oct:
    cmpb $'0', %dl; jl .pi_done
    cmpb $'7', %dl; jg .pi_done
    sub $'0', %rdx
    shl $3, %rax
    add %rdx, %rax
    inc %rsi
    jmp .pi_loop

.pi_bin:
    cmpb $'0', %dl; jl .pi_done
    cmpb $'1', %dl; jg .pi_done
    sub $'0', %rdx
    shl $1, %rax
    add %rdx, %rax
    inc %rsi
    jmp .pi_loop

.pi_done:
    test %r9d, %r9d
    jz .pi_ret
    neg %rax
.pi_ret:
    ret

update_prog_readouts:
    push %rbx
    call parse_int64
    mov %rax, %rbx

    mov %rbx, %rdi
    lea hex_buf(%rip), %rsi
    call format_hex

    mov %rbx, %rdi
    lea dec_buf(%rip), %rsi
    call format_dec

    mov %rbx, %rdi
    lea oct_buf(%rip), %rsi
    call format_oct

    mov %rbx, %rdi
    lea bin_buf(%rip), %rsi
    call format_bin

    pop %rbx
    ret

format_hex:
    movb $'0', (%rsi)
    movb $'x', 1(%rsi)
    add $2, %rsi
    mov $8, %ecx
.fh_l:
    dec %ecx
    js .fh_d
    mov %rdi, %rax
    mov %ecx, %edx
    shl $2, %edx
    mov %edx, %ecx
    shr %cl, %rax
    mov %edx, %ecx
    shr $2, %ecx
    and $0xF, %al
    cmp $10, %al
    jl .fh_num
    add $'A' - 10, %al
    jmp .fh_st
.fh_num:
    add $'0', %al
.fh_st:
    movb %al, (%rsi)
    inc %rsi
    jmp .fh_l
.fh_d:
    movb $0, (%rsi)
    ret

format_dec:
    mov %rdi, %rax
    mov %rsi, %rdi
    test %rax, %rax
    jns int_to_str
    movb $'-', (%rdi)
    inc %rdi
    neg %rax
    jmp int_to_str

format_oct:
    movb $'0', (%rsi)
    movb $'o', 1(%rsi)
    add $2, %rsi
    mov %rdi, %rax
    test %rax, %rax
    jnz .fo_nz
    movb $'0', (%rsi)
    movb $0, 1(%rsi)
    ret

.fo_nz:
    mov %rsi, %rdi
    sub $32, %rsp
    mov %rsp, %rsi
    add $30, %rsi
    movb $0, 1(%rsi)
.fo_l:
    test %rax, %rax
    jz .fo_c
    mov %rax, %rdx
    and $7, %rdx
    shr $3, %rax
    add $'0', %dl
    movb %dl, (%rsi)
    dec %rsi
    jmp .fo_l
.fo_c:
    inc %rsi
.fo_c2:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rdi
    inc %rsi
    test %al, %al
    jnz .fo_c2
    add $32, %rsp
    ret

format_bin:
    mov $32, %ecx
.fb_l:
    dec %ecx
    js .fb_d
    mov %rdi, %rax
    shr %cl, %rax
    and $1, %al
    add $'0', %al
    movb %al, (%rsi)
    inc %rsi

    mov %ecx, %eax
    and $7, %eax
    jnz .fb_l
    test %ecx, %ecx
    jz .fb_l
    movb $' ', (%rsi)
    inc %rsi
    jmp .fb_l

.fb_d:
    movb $0, (%rsi)
    ret

# ------------------------------------------------------------------------------
# build_live_preview:
# Generates non-destructive preview of pending calculation into preview_buf.
# preview_buf = hist_buf + disp_buf + " = " + preview_answer
# ------------------------------------------------------------------------------
.global build_live_preview
build_live_preview:
    push %rbp
    mov %rsp, %rbp
    sub $128, %rsp

    # 1. Copy hist_buf into preview_buf
    lea preview_buf(%rip), %rdi
    lea hist_buf(%rip), %rsi
.blp_cp1:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .blp_cp1
    dec %rdi

    # 2. Append disp_buf
    lea disp_buf(%rip), %rsi
.blp_cp2:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    test %al, %al
    jnz .blp_cp2
    dec %rdi

    # 3. Append " = "
    movb $' ', (%rdi)
    movb $'=', 1(%rdi)
    movb $' ', 2(%rdi)
    add $3, %rdi
    mov %rdi, -8(%rbp)                   # save pointer for result string

    # 4. Compute preview value
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    je .blp_prog

    # Basic / Scientific floating point preview
    fldl acc_val(%rip)
    lea disp_buf(%rip), %rsi
    call parse_double

    mov pending_op(%rip), %eax
    cmp $1, %eax; je .blp_add
    cmp $2, %eax; je .blp_sub
    cmp $3, %eax; je .blp_mul
    cmp $4, %eax; je .blp_div
    cmp $5, %eax; je .blp_pow
    fstp %st(0)
    fstp %st(0)
    jmp .blp_done

.blp_add: faddp; jmp .blp_fmt
.blp_sub: fsubrp; jmp .blp_fmt
.blp_mul: fmulp; jmp .blp_fmt
.blp_div:
    fldz
    fcomip %st(1), %st(0)
    jne .blp_do_div
    fstp %st(0)
    fstp %st(0)
    jmp .blp_done
.blp_do_div:
    fdivrp
    jmp .blp_fmt
.blp_pow:
    fyl2x
    fld %st(0)
    frndint
    fsubr %st(0), %st(1)
    fxch %st(1)
    f2xm1
    fld1
    faddp
    fscale
    fstp %st(1)
.blp_fmt:
    mov -8(%rbp), %rdi
    call format_double
    jmp .blp_done

.blp_prog:
    # Programmer Mode 64-bit integer preview
    call parse_int64
    mov %rax, %rsi                       # %rsi = current operand
    mov acc_int(%rip), %rax              # %rax = acc_int
    mov pending_op(%rip), %ecx
    cmp $1, %ecx; je .blp_p_add
    cmp $2, %ecx; je .blp_p_sub
    cmp $3, %ecx; je .blp_p_mul
    cmp $4, %ecx; je .blp_p_div
    cmp $7, %ecx; je .blp_p_and
    cmp $8, %ecx; je .blp_p_or
    cmp $9, %ecx; je .blp_p_xor
    cmp $10, %ecx; je .blp_p_shl
    cmp $11, %ecx; je .blp_p_shr
    jmp .blp_p_fmt
.blp_p_add: add %rsi, %rax; jmp .blp_p_fmt
.blp_p_sub: sub %rsi, %rax; jmp .blp_p_fmt
.blp_p_mul: imul %rsi, %rax; jmp .blp_p_fmt
.blp_p_div:
    test %rsi, %rsi; jz .blp_done
    cqo
    idiv %rsi
    jmp .blp_p_fmt
.blp_p_and: and %rsi, %rax; jmp .blp_p_fmt
.blp_p_or:  or %rsi, %rax;  jmp .blp_p_fmt
.blp_p_xor: xor %rsi, %rax; jmp .blp_p_fmt
.blp_p_shl: mov %sil, %cl; shl %cl, %rax; jmp .blp_p_fmt
.blp_p_shr: mov %sil, %cl; shr %cl, %rax; jmp .blp_p_fmt
.blp_p_fmt:
    mov %rax, %rdi
    mov -8(%rbp), %rsi
    call format_current_base
.blp_done:
    leave
    ret
