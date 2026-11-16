# ==============================================================================
# Pure x86_64 Assembly Libadwaita Complex Calculator
# Core Arithmetic & Computation Engine (calc_core.s)
#
# Free of C runtime (libc), dynamic linkers, Python, or external dependencies.
# Direct hardware instructions: x87 FPU, 64-bit integer ALU, and string parsing.
# ==============================================================================
#
# Subsystem Architecture:
# ------------------------
# 1. Display Buffer Operations:
#    - append_disp_char: Appends typed character to active display buffer.
#    - clear_disp:       Resets display, expression history, and arithmetic state.
#    - bksp_disp:        Erases the last character (or resets to '0').
#    - toggle_sign:      Negates or restores the active display number (+/-).
#
# 2. Keypad Action Dispatchers:
#    - exec_basic_key:   Maps basic keypad button clicks (0..19) to operations.
#    - exec_adv_key:     Maps scientific button clicks (0..29) to trig/log/powers.
#    - exec_prog_key:    Maps programmer button clicks (0..29) to bitwise/radix ops.
#
# 3. Arithmetic & Evaluation State Machine:
#    - op_add, op_sub, op_mul, op_div: Prepares and chains pending operators.
#    - apply_op:         Handles intermediate chained expressions (e.g. 2 + 3 + ...).
#    - eval_expression:  Finalizes expression on '=' and renders output.
#    - eval_math_only:   Executes pending binary operations on IEEE-754 floats.
#    - eval_prog_op:     Executes pending binary bitwise/integer operations.
#
# 4. Conversion & Formatting Engine:
#    - parse_double:     Parses ASCII numeric string into 80-bit float on x87 stack.
#    - format_double:    Converts 80-bit float into human-readable formatted string.
#    - int_to_str:       Converts unsigned 64-bit integer to decimal ASCII string.
#    - parse_int64:      Parses numeric string according to active radix (HEX/DEC/OCT/BIN).
#    - update_prog_readouts: Synchronously updates 4 live multi-base inspector buffers.
# ==============================================================================

# ------------------------------------------------------------------------------
# Exported Global Symbols (Interface to calc_ui.s)
# ------------------------------------------------------------------------------
.global append_disp_char, clear_disp, bksp_disp, toggle_sign
.global exec_basic_key, exec_adv_key, exec_prog_key
.global eval_expression, update_prog_readouts
.global parse_double, format_double, parse_int64
.global op_add, op_sub, op_mul, op_div

# ------------------------------------------------------------------------------
# External State Variables (Defined in calc_ui.s .data / .bss sections)
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

# ==============================================================================
# Read-Only Data Section (Math Constants & Error Strings)
# ==============================================================================
.section .rodata
.align 8

# Floating-point constants for decimal conversion and scientific functions
fp_ten:     .double 10.0                    # Base-10 multiplier for digit extraction
fp_eps:     .double 0.00000001              # Epsilon threshold for zero rounding (1e-8)
fp_deg2rad: .double 0.017453292519943295    # Multiplier: Degrees to Radians (pi / 180)
fp_rad2deg: .double 57.29577951308232       # Multiplier: Radians to Degrees (180 / pi)
fp_e:       .double 2.71828182845904523536  # Euler's number (e)

# Informative UI error messages
str_err_div: .asciz "Cannot divide by 0"     # Displayed on division by zero
str_err_nan: .asciz "Error"                  # Displayed on NaN or Infinity overflow

# ==============================================================================
# Executable Code Section (.text)
# ==============================================================================
.section .text

# ------------------------------------------------------------------------------
# append_disp_char:
# Appends a single ASCII character (digit, decimal point, etc.) to disp_buf.
#
# Calling Convention:
#   Input:   %al = ASCII character to append
#   Output:  None (disp_buf updated in-place)
#   Scratch: %rdx, %rsi, %rcx
#   Safety:  Clamps buffer length to 28 characters to prevent buffer overrun.
# ------------------------------------------------------------------------------
append_disp_char:
    push %rax                   # Preserve input character across clr_next check

    # If clr_next is non-zero, the user previously pressed an operator or equals;
    # clear display buffer first so the new digit starts a fresh number.
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
    cmpb $0, (%rsi, %rcx)       # Look for null terminator '\0'
    jz .ap_insert
    inc %rcx
    cmp $28, %rcx               # Maximum allowed display length = 28 chars
    jge .ap_ret                 # If limit reached, ignore extra keystrokes
    jmp .ap_len

.ap_insert:
    # UX rule: If current buffer is exactly "0" and input is a digit (not '.'),
    # replace the leading '0' with the new digit instead of appending "07".
    cmp $1, %rcx
    jne .do_ap
    cmpb $'0', (%rsi)
    jne .do_ap
    cmpb $'.', %al              # If typing '.', keep "0."
    je .do_ap
    movb %al, (%rsi)            # Overwrite '0' with new digit
    ret

.do_ap:
    # Append character at current length offset and write terminating null byte
    movb %al, (%rsi, %rcx)
    movb $0, 1(%rsi, %rcx)
.ap_ret:
    ret

# ------------------------------------------------------------------------------
# clear_disp:
# Resets the calculator display and arithmetic state back to initial power-on state.
#
# Calling Convention:
#   Input:   None
#   Output:  None (state cleared, disp_buf reset to "0")
# ------------------------------------------------------------------------------
clear_disp:
    lea disp_buf(%rip), %rdi
    movb $'0', (%rdi)           # Display resets to default "0"
    movb $0, 1(%rdi)            # Null terminate
    movb $0, hist_buf(%rip)     # Clear expression history
    movl $0, pending_op(%rip)   # Clear pending operator
    movl $0, clr_next(%rip)     # Reset clear-on-next flag
    movq $0, acc_val(%rip)      # Reset floating-point accumulator to 0.0
    movq $0, acc_int(%rip)      # Reset integer accumulator to 0

    # If currently in Programmer Mode (mode == 2), refresh the 4-base readouts
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    jne .cd_done
    call update_prog_readouts
.cd_done:
    ret

# ------------------------------------------------------------------------------
# bksp_disp:
# Backspaces (erases) the rightmost character in disp_buf.
# If only 1 character remains, resets display to "0" instead of empty string.
#
# Calling Convention:
#   Input:   None
#   Output:  None (disp_buf modified in-place)
# ------------------------------------------------------------------------------
bksp_disp:
    lea disp_buf(%rip), %rdi    # %rdi = pointer to display buffer
    xor %rcx, %rcx              # %rcx = length counter

.bkl:
    cmpb $0, (%rdi, %rcx)       # Find end of string
    jz .bk_found
    inc %rcx
    jmp .bkl

.bk_found:
    cmp $1, %rcx                # If length <= 1, erasing leaves "0"
    jle .bk_reset
    dec %rcx                    # Step back one character
    movb $0, (%rdi, %rcx)       # Truncate string with null terminator
    jmp .bk_check_prog

.bk_reset:
    movb $'0', (%rdi)           # Reset to single digit '0'
    movb $0, 1(%rdi)

.bk_check_prog:
    # Update programmer readouts if active
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    jne .bk_done
    call update_prog_readouts
.bk_done:
    ret

# ------------------------------------------------------------------------------
# toggle_sign:
# Inverts the numeric sign of disp_buf (+/-).
# - If negative: removes leading '-' by shifting characters left.
# - If positive: shifts characters right and inserts '-' at index 0.
# - If zero ("0"): no-op.
# ------------------------------------------------------------------------------
toggle_sign:
    lea disp_buf(%rip), %rdi    # %rdi = pointer to disp_buf
    cmpb $'0', (%rdi)           # If value is "0", do nothing
    jne .ts_check_neg
    cmpb $0, 1(%rdi)
    je .ts_ret                  # Ignore toggle on standalone 0

.ts_check_neg:
    cmpb $'-', (%rdi)
    jne .ts_add_neg

    # Remove leading '-' by shifting the string 1 byte to the left
    mov %rdi, %rsi
    inc %rsi                    # %rsi points to first character after '-'
.ts_copy:
    movb (%rsi), %al
    movb %al, (%rdi)            # Shift character left
    inc %rdi
    inc %rsi
    test %al, %al               # Stop when null terminator is copied
    jnz .ts_copy
    jmp .ts_check_prog

.ts_add_neg:
    # Prepend '-' by shifting the string 1 byte to the right
    mov $30, %rcx               # Start from end of maximum buffer length
.ts_shift:
    movb (%rdi, %rcx), %al
    movb %al, 1(%rdi, %rcx)     # Shift character right
    dec %rcx
    jns .ts_shift
    movb $'-', (%rdi)           # Place minus sign at index 0

.ts_check_prog:
    # Synchronize programmer readouts if in programmer mode
    mov curr_mode(%rip), %eax
    cmp $2, %eax
    jne .ts_ret
    call update_prog_readouts
.ts_ret:
    ret

# ------------------------------------------------------------------------------
# exec_basic_key:
# Dispatches keypad click events for Basic Calculator mode.
#
# Keypad Grid Layout: 4 columns x 5 rows = 20 buttons (indices 0..19)
#   Row 0:  0: C,    1: ⌫,    2: +/-,  3: ÷
#   Row 1:  4: 7,    5: 8,    6: 9,    7: ×
#   Row 2:  8: 4,    9: 5,   10: 6,   11: -
#   Row 3: 12: 1,   13: 2,   14: 3,   15: +
#   Row 4: 16: (,   17: 0,   18: .,   19: =
#
# Calling Convention:
#   Input:   %eax = Key index (0..19)
# ------------------------------------------------------------------------------
exec_basic_key:
    cmp $0, %eax; je clear_disp
    cmp $1, %eax; je bksp_disp
    cmp $2, %eax; je toggle_sign
    cmp $3, %eax; je op_div
    cmp $4, %eax; je .d7
    cmp $5, %eax; je .d8
    cmp $6, %eax; je .d9
    cmp $7, %eax; je op_mul
    cmp $8, %eax; je .d4
    cmp $9, %eax; je .d5
    cmp $10, %eax; je .d6
    cmp $11, %eax; je op_sub
    cmp $12, %eax; je .d1
    cmp $13, %eax; je .d2
    cmp $14, %eax; je .d3
    cmp $15, %eax; je op_add
    cmp $16, %eax; je .d_lparen
    cmp $17, %eax; je .d0
    cmp $18, %eax; je .d_dot
    cmp $19, %eax; je eval_expression
    ret

# Digit and punctuation entry trampolines
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
# Sets opcode in %edi and ASCII/custom glyph byte in %sil, then enters apply_op.
# ------------------------------------------------------------------------------
op_add:
    mov $1, %edi                # Opcode 1 = Addition
    movb $'+', %sil
    jmp apply_op

op_sub:
    mov $2, %edi                # Opcode 2 = Subtraction
    movb $'-', %sil
    jmp apply_op

op_mul:
    mov $3, %edi                # Opcode 3 = Multiplication
    movb $132, %sil             # Glyph 132 = '×'
    jmp apply_op

op_div:
    mov $4, %edi                # Opcode 4 = Division
    movb $131, %sil             # Glyph 131 = '÷'
    jmp apply_op

# ------------------------------------------------------------------------------
# apply_op:
# Prepares or chains a binary operator (+, -, ×, ÷).
#
# Logic:
#   1. If an operator is already pending and user typed a number (clr_next == 0),
#      evaluates the pending calculation first (e.g., 5 + 3 + -> 8 +).
#   2. If user clicks another operator immediately (clr_next == 1), updates the
#      pending operator and history symbol without re-evaluating.
#   3. Stores current display value into accumulator (acc_val).
#   4. Updates hist_buf with "<number> <symbol> ".
#   5. Sets pending_op and flags clr_next = 1.
# ------------------------------------------------------------------------------
apply_op:
    push %rdi                   # Preserve operator code on stack
    push %rsi                   # Preserve operator symbol byte on stack

    # Check if an operator is already pending
    mov pending_op(%rip), %eax
    test %eax, %eax
    jz .ao_fresh

    # If user didn't enter a new number, just change the pending operator
    mov clr_next(%rip), %eax
    test %eax, %eax
    jnz .ao_update_sym

    # Evaluate previous pending operation before chaining the next
    call eval_math_only

.ao_fresh:
    # Parse display buffer into 80-bit float and save into acc_val
    lea disp_buf(%rip), %rsi
    call parse_double
    fstpl acc_val(%rip)

.ao_update_sym:
    # Build history string: copy disp_buf + " <operator_symbol> " into hist_buf
    lea hist_buf(%rip), %rdi
    lea disp_buf(%rip), %rsi
.ao_cpy:
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rdi
    inc %rsi
    test %al, %al
    jnz .ao_cpy
    dec %rdi                    # Rewind to overwrite null terminator

    # Append space, symbol, space, null
    movb $' ', (%rdi)
    pop %rsi                    # Restore operator symbol
    movb %sil, 1(%rdi)
    movb $' ', 2(%rdi)
    movb $0, 3(%rdi)

    pop %rdi                    # Restore operator code
    mov %edi, pending_op(%rip)  # Record pending operator
    movl $1, clr_next(%rip)     # Set clear-on-next flag for incoming digits
    ret

# ------------------------------------------------------------------------------
# eval_expression:
# Evaluates the full expression when '=' is clicked.
# - Programmer Mode: delegates to 64-bit integer evaluator (eval_prog_op).
# - Basic / Scientific Modes:
#     Appends current display string and " =" to hist_buf.
#     Calls eval_math_only to compute result.
#     Clears pending_op and sets clr_next = 1.
# ------------------------------------------------------------------------------
eval_expression:
    mov pending_op(%rip), %eax
    test %eax, %eax
    jz .ee_ret                  # No pending operation to evaluate

    # In Programming mode, handle 64-bit integer operations
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
    dec %rdi                    # Rewind over null terminator
    movb $' ', (%rdi)           # Append " ="
    movb $'=', 1(%rdi)
    movb $0, 2(%rdi)

    # Perform arithmetic evaluation on FPU
    call eval_math_only
    movl $0, pending_op(%rip)   # Clear pending operation
    movl $1, clr_next(%rip)     # Next keystroke starts fresh number
.ee_ret:
    ret

# ------------------------------------------------------------------------------
# eval_math_only:
# Executes the pending binary operation between acc_val and disp_buf.
#
# FPU Stack Layout:
#   ST(1) = acc_val (first operand)
#   ST(0) = parse_double(disp_buf) (second operand)
#
# Evaluates operation, guards against division by zero, and formats the result
# back into disp_buf as well as updating acc_val.
# ------------------------------------------------------------------------------
eval_math_only:
    sub $16, %rsp               # Allocate stack frame for FPU storage
    fldl acc_val(%rip)          # Load accumulator: ST(1) = acc_val
    lea disp_buf(%rip), %rsi
    call parse_double           # Parse disp_buf:   ST(0) = disp_val, ST(1) = acc_val

    mov pending_op(%rip), %eax
    cmp $1, %eax
    je .emo_add
    cmp $2, %eax
    je .emo_sub
    cmp $3, %eax
    je .emo_mul
    cmp $4, %eax
    je .emo_div

    # Unknown operation fallback: pop both floats and return
    fstp %st(0)
    fstp %st(0)
    add $16, %rsp
    ret

.emo_add:
    faddp                       # ST(1) = ST(1) + ST(0), pop -> ST(0)
    jmp .emo_save

.emo_sub:
    fsubrp                      # ST(1) = ST(1) - ST(0), pop -> ST(0)
    jmp .emo_save

.emo_mul:
    fmulp                       # ST(1) = ST(1) * ST(0), pop -> ST(0)
    jmp .emo_save

.emo_div:
    # Check division by zero: compare ST(0) (divisor) with 0.0
    fldz                        # Push 0.0: ST(0) = 0.0, ST(1) = divisor, ST(2) = dividend
    fcomip %st(1), %st(0)       # Compare 0.0 with divisor and pop 0.0
    jne .emo_do_div

    # Division by zero detected!
    fstp %st(0)                 # Pop divisor
    fstp %st(0)                 # Pop dividend
    lea disp_buf(%rip), %rdi
    lea str_err_div(%rip), %rsi # Copy "Cannot divide by 0" into display buffer
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
    fdivrp                      # ST(1) = ST(1) / ST(0), pop -> ST(0)
    jmp .emo_save

.emo_save:
    fld %st(0)                  # Duplicate result: ST(0) for saving, ST(1) for format
    fstpl acc_val(%rip)         # Save result into acc_val double
    lea disp_buf(%rip), %rdi
    call format_double          # Format ST(0) float into disp_buf ASCII string
    add $16, %rsp
    ret

# ------------------------------------------------------------------------------
# parse_double:
# Parses an ASCII string into an 80-bit IEEE-754 floating point number on the
# x87 FPU stack (ST(0)).
#
# Calling Convention:
#   Input:   %rsi = Pointer to null-terminated string
#   Output:  Parsed number loaded into ST(0)
#   Scratch: %rax, %rdx, %r8d
#
# Parsing Algorithm:
#   1. Skips leading whitespace.
#   2. Checks for optional '-' sign; sets %r8d = 1 if negative.
#   3. Accumulates integer digits: val = val * 10 + digit.
#   4. If '.' encountered, loads integer part into FPU, then for each fractional
#      digit divides by 10^k and accumulates into sum.
#   5. Applies negative sign via fchs if %r8d was set.
# ------------------------------------------------------------------------------
parse_double:
    sub $32, %rsp
    movq $0, (%rsp)             # Scratch slot for integer part
    movq $0, 8(%rsp)            # Scratch slot for fractional digits

    xor %rax, %rax              # %rax = accumulated integer part
    xor %r8d, %r8d              # %r8d = sign flag (0 = positive, 1 = negative)

.pd_skip_ws:
    cmpb $' ', (%rsi)           # Skip spaces
    jne .pd_chk_sign
    inc %rsi
    jmp .pd_skip_ws

.pd_chk_sign:
    cmpb $'-', (%rsi)           # Check for minus sign
    jne .pd_start
    inc %rsi
    mov $1, %r8d                # Set sign flag to negative

.pd_start:
.pd_int:
    movzbq (%rsi), %rdx         # Read next ASCII character
    test %dl, %dl
    jz .pd_finish               # Null terminator: end of integer part
    cmpb $'.', %dl
    je .pd_frac_start           # Decimal point: start fractional part
    cmpb $'0', %dl
    jl .pd_finish
    cmpb $'9', %dl
    jg .pd_finish

    # Accumulate digit: %rax = %rax * 10 + (%rdx - '0')
    sub $'0', %rdx
    imul $10, %rax
    add %rdx, %rax
    inc %rsi
    jmp .pd_int

.pd_frac_start:
    inc %rsi                    # Skip '.' character
    mov %rax, (%rsp)
    fildq (%rsp)                # Load integer part onto FPU stack: ST(2) = int

    fldz                        # ST(1) = sum (0.0)
    fld1                        # ST(0) = divisor (1.0)
.pd_frac:
    movzbq (%rsi), %rdx
    test %dl, %dl
    jz .pd_frac_end
    cmpb $'0', %dl
    jl .pd_frac_end
    cmpb $'9', %dl
    jg .pd_frac_end

    # Divisor = Divisor * 10.0
    sub $'0', %rdx
    fmull fp_ten(%rip)
    mov %rdx, 8(%rsp)
    fildq 8(%rsp)               # Load current digit: ST(0) = digit
    fdiv %st(1), %st(0)         # digit / divisor
    faddp %st(0), %st(2)        # sum = sum + (digit / divisor)

    inc %rsi
    jmp .pd_frac

.pd_frac_end:
    fstp %st(0)                 # Pop divisor
    faddp                       # ST(0) = sum + int
    test %r8d, %r8d             # Check sign flag
    jz .pd_done
    fchs                        # Invert sign to negative
.pd_done:
    add $32, %rsp
    ret

.pd_finish:
    # No fractional part: load integer directly to FPU
    mov %rax, (%rsp)
    fildq (%rsp)
    test %r8d, %r8d
    jz .pd_done
    fchs                        # Invert sign to negative
    jmp .pd_done

# ------------------------------------------------------------------------------
# format_double:
# Converts an 80-bit float in ST(0) into a clean, human-readable ASCII string.
#
# Calling Convention:
#   Input:   Float in ST(0), %rdi = destination buffer pointer
#   Output:  Pops ST(0), writes null-terminated string at %rdi
#
# Formatting Algorithm:
#   1. Tests float status using fxam / fnstsw for NaN or Infinity -> "Error".
#   2. Tests sign via ftst; outputs '-' and negates float if negative.
#   3. Truncates integer part with fisttpq; converts to string via int_to_str.
#   4. Subtracts integer part to get fractional remainder: frac = float - int.
#   5. If frac < epsilon (1e-8), omits decimal point.
#   6. Otherwise, outputs '.' and iterates up to 6 decimal digits (frac *= 10).
#   7. Strips unnecessary trailing zeroes (e.g. "3.500000" -> "3.5").
# ------------------------------------------------------------------------------
format_double:
    sub $64, %rsp
    mov %rdi, 32(%rsp)          # Save start pointer for trailing-zero stripping

    # Check for NaN / Infinity using x87 fxam instruction
    fxam
    fnstsw %ax
    and $0x4500, %ax
    cmp $0x0100, %ax            # Condition code: NaN
    je .fd_nan
    cmp $0x0500, %ax            # Condition code: Infinity
    je .fd_nan

    # Test float sign
    ftst
    fnstsw %ax
    sahf
    jnc .fd_pos                 # If not carry, value is >= 0.0
    movb $'-', (%rdi)           # Append minus sign
    inc %rdi
    fchs                        # Make positive for digit extraction

.fd_pos:
    # Extract integer part using fisttpq (SSE3/x87 truncate to 64-bit int)
    fld %st(0)
    fisttpq 8(%rsp)             # 8(%rsp) = integer part, ST(0) = full float
    mov 8(%rsp), %rax
    call int_to_str             # Format integer part; advances %rdi

    # Compute fractional remainder: ST(0) - integer_part
    fildq 8(%rsp)               # ST(0) = integer part, ST(1) = full float
    fsubrp                      # ST(0) = full float - integer part = fraction

    # Check if fractional remainder is virtually zero (< 1e-8)
    fldl fp_eps(%rip)
    fcomip %st(1), %st(0)       # Compare eps with fraction and pop eps
    jb .fd_has_frac

    # Fractional part is negligible: pop remainder and finish string
    fstp %st(0)
    movb $0, (%rdi)
    add $64, %rsp
    ret

.fd_has_frac:
    movb $'.', (%rdi)           # Write decimal point
    inc %rdi

    mov $6, %ecx                # Maximum 6 decimal places
.fd_frac_loop:
    fmull fp_ten(%rip)          # frac = frac * 10.0
    fld %st(0)
    fisttpq 16(%rsp)            # Extract digit via truncation
    mov 16(%rsp), %rax
    add $'0', %al
    movb %al, (%rdi)            # Write decimal digit
    inc %rdi

    fildq 16(%rsp)
    fsubrp                      # frac = frac - digit

    # Check if remaining fraction has dropped below epsilon
    fldl fp_eps(%rip)
    fcomip %st(1), %st(0)
    jbe .fd_frac_cont
    jmp .fd_pop_frac            # Remainder is zero, stop loop early

.fd_frac_cont:
    dec %ecx
    jnz .fd_frac_loop

.fd_pop_frac:
    fstp %st(0)                 # Pop remaining fraction
    movb $0, (%rdi)             # Null terminate

    # Clean up trailing zeros after decimal point
    dec %rdi
.strip_loop:
    mov 32(%rsp), %rax
    cmp %rax, %rdi
    jle .fd_done
    cmpb $'0', (%rdi)
    jne .strip_check_dot
    movb $0, (%rdi)             # Erase trailing '0'
    dec %rdi
    jmp .strip_loop

.strip_check_dot:
    cmpb $'.', (%rdi)           # If entire fraction was stripped, erase '.'
    jne .fd_done
    movb $0, (%rdi)

.fd_done:
    add $64, %rsp
    ret

.fd_nan:
    # Overflow or Invalid Math: Output "Error"
    fstp %st(0)                 # Pop invalid float
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
# Converts an unsigned 64-bit integer into a decimal ASCII string.
#
# Calling Convention:
#   Input:   %rax = 64-bit unsigned integer
#            %rdi = destination buffer pointer
#   Output:  %rdi advanced to point to the terminating null byte
#   Scratch: %rbx, %rdx, %rsi
# ------------------------------------------------------------------------------
int_to_str:
    sub $32, %rsp
    mov %rsp, %rsi
    add $30, %rsi               # Work backwards from end of local stack buffer
    movb $0, 1(%rsi)            # Set terminating null byte

    # Handle special case where input integer is 0
    test %rax, %rax
    jnz .its_loop
    movb $'0', (%rdi)
    movb $0, 1(%rdi)
    inc %rdi
    add $32, %rsp
    ret

.its_loop:
    xor %rdx, %rdx              # Clear high dividend for 64-bit div
    mov $10, %rbx
    div %rbx                    # %rax = quotient, %rdx = remainder (digit)
    add $'0', %dl
    movb %dl, (%rsi)            # Store ASCII digit
    dec %rsi
    test %rax, %rax
    jnz .its_loop

    inc %rsi                    # %rsi now points to the first character
.its_copy:
    movb (%rsi), %al
    movb %al, (%rdi)            # Copy reversed digits into destination buffer
    inc %rdi
    inc %rsi
    test %al, %al
    jnz .its_copy
    dec %rdi                    # %rdi points to '\0'
    add $32, %rsp
    ret

# ------------------------------------------------------------------------------
# exec_adv_key:
# Dispatches keypad click events for Scientific Calculator mode.
#
# Keypad Grid Layout: 5 columns x 6 rows = 30 buttons (indices 0..29)
#   Row 0:  0: sin,  1: C,    2: ⌫,   3: +/-,  4: ÷
#   Row 1:  5: cos,  6: 7,    7: 8,   8: 9,    9: ×
#   Row 2: 10: tan, 11: 4,   12: 5,  13: 6,   14: -
#   Row 3: 15: √,   16: 1,   17: 2,  18: 3,   19: +
#   Row 4: 20: π,   21: (,   22: 0,  23: .,   24: =
#   Row 5: 25: e,   26: ln,  27: log,28: x²,  29: 1/x
#
# Calling Convention:
#   Input:   %eax = Key index (0..29)
# ------------------------------------------------------------------------------
exec_adv_key:
    cmp $0, %eax; je .f_sin
    cmp $1, %eax; je clear_disp
    cmp $2, %eax; je bksp_disp
    cmp $3, %eax; je toggle_sign
    cmp $4, %eax; je op_div

    cmp $5, %eax; je .f_cos
    cmp $6, %eax; je .d7
    cmp $7, %eax; je .d8
    cmp $8, %eax; je .d9
    cmp $9, %eax; je op_mul

    cmp $10, %eax; je .f_tan
    cmp $11, %eax; je .d4
    cmp $12, %eax; je .d5
    cmp $13, %eax; je .d6
    cmp $14, %eax; je op_sub

    cmp $15, %eax; je .f_sqrt
    cmp $16, %eax; je .d1
    cmp $17, %eax; je .d2
    cmp $18, %eax; je .d3
    cmp $19, %eax; je op_add

    cmp $20, %eax; je .f_pi
    cmp $21, %eax; je .d_lparen
    cmp $22, %eax; je .d0
    cmp $23, %eax; je .d_dot
    cmp $24, %eax; je eval_expression

    cmp $25, %eax; je .f_e
    cmp $26, %eax; je .f_ln
    cmp $27, %eax; je .f_log
    cmp $28, %eax; je .f_sq
    cmp $29, %eax; je .f_inv
    ret

# --- Scientific Trigonometric Functions (with Degree-to-Radian conversion) ---
.f_sin:
    lea disp_buf(%rip), %rsi
    call parse_double           # Load display value in degrees
    fmull fp_deg2rad(%rip)      # Convert to radians: rad = deg * (pi / 180)
    fsin                        # Compute sine
    lea disp_buf(%rip), %rdi
    call format_double          # Format result into disp_buf
    movl $1, clr_next(%rip)
    ret

.f_cos:
    lea disp_buf(%rip), %rsi
    call parse_double
    fmull fp_deg2rad(%rip)      # Convert to radians
    fcos                        # Compute cosine
    lea disp_buf(%rip), %rdi
    call format_double
    movl $1, clr_next(%rip)
    ret

.f_tan:
    lea disp_buf(%rip), %rsi
    call parse_double
    fmull fp_deg2rad(%rip)      # Convert to radians
    fptan                       # fptan computes tan and pushes 1.0, then tan
    fstp %st(0)                 # Pop constant 1.0, leaving tan result on ST(0)
    lea disp_buf(%rip), %rdi
    call format_double
    movl $1, clr_next(%rip)
    ret

# --- Mathematical Constants ---
.f_pi:
    fldpi                       # Push Archimedes' constant pi onto FPU stack
    lea disp_buf(%rip), %rdi
    call format_double
    movl $1, clr_next(%rip)
    ret

.f_e:
    fldl fp_e(%rip)             # Push Euler's constant e onto FPU stack
    lea disp_buf(%rip), %rdi
    call format_double
    movl $1, clr_next(%rip)
    ret

# --- Algebraic Operations ---
.f_sqrt:
    lea disp_buf(%rip), %rsi
    call parse_double
    fsqrt                       # Compute square root
    lea disp_buf(%rip), %rdi
    call format_double
    movl $1, clr_next(%rip)
    ret

.f_sq:
    lea disp_buf(%rip), %rsi
    call parse_double
    fld %st(0)
    fmulp                       # Compute square: x * x
    lea disp_buf(%rip), %rdi
    call format_double
    movl $1, clr_next(%rip)
    ret

.f_inv:
    lea disp_buf(%rip), %rsi
    call parse_double
    fld1                        # Push 1.0: ST(0) = 1.0, ST(1) = x
    fdivp                       # Compute reciprocal: 1.0 / x
    lea disp_buf(%rip), %rdi
    call format_double
    movl $1, clr_next(%rip)
    ret

# --- Logarithms (via x87 fyl2x instruction: ST(1) * log2(ST(0))) ---
.f_ln:
    fldln2                      # Push ln(2): ST(0) = ln(2)
    lea disp_buf(%rip), %rsi
    call parse_double           # ST(0) = x, ST(1) = ln(2)
    fyl2x                       # ln(x) = ln(2) * log2(x)
    lea disp_buf(%rip), %rdi
    call format_double
    movl $1, clr_next(%rip)
    ret

.f_log:
    fldlg2                      # Push log10(2): ST(0) = log10(2)
    lea disp_buf(%rip), %rsi
    call parse_double           # ST(0) = x, ST(1) = log10(2)
    fyl2x                       # log10(x) = log10(2) * log2(x)
    lea disp_buf(%rip), %rdi
    call format_double
    movl $1, clr_next(%rip)
    ret

# ------------------------------------------------------------------------------
# exec_prog_key:
# Dispatches keypad click events for Programmer Calculator mode.
#
# Keypad Grid Layout: 5 columns x 6 rows = 30 buttons (indices 0..29)
#   Row 0:  0: &,   1: |,    2: ^,   3: ~,   4: C
#   Row 1:  5: <<,  6: >>,   7: A,   8: B,   9: ⌫
#   Row 2: 10: 7,  11: 8,   12: 9,  13: C,  14: ÷
#   Row 3: 15: 4,  16: 5,   17: 6,  18: D,  19: ×
#   Row 4: 20: 1,  21: 2,   22: 3,  23: E,  24: -
#   Row 5: 25: 0,  26: +/-, 27: =,  28: F,  29: +
#
# Calling Convention:
#   Input:   %eax = Key index (0..29)
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

# --- Hexadecimal Digit Appenders (A through F) ---
.hex_A: movb $'A', %al; call append_disp_char; call update_prog_readouts; ret
.hex_B: movb $'B', %al; call append_disp_char; call update_prog_readouts; ret
.hex_C: movb $'C', %al; call append_disp_char; call update_prog_readouts; ret
.hex_D: movb $'D', %al; call append_disp_char; call update_prog_readouts; ret
.hex_E: movb $'E', %al; call append_disp_char; call update_prog_readouts; ret
.hex_F: movb $'F', %al; call append_disp_char; call update_prog_readouts; ret

# --- Programmer Bitwise Operator Setters ---
.p_and:
    call parse_int64
    mov %rax, acc_int(%rip)      # Save first operand in integer accumulator
    movl $7, pending_op(%rip)    # Opcode 7 = Bitwise AND (&)
    movl $1, clr_next(%rip)
    ret

.p_or:
    call parse_int64
    mov %rax, acc_int(%rip)
    movl $8, pending_op(%rip)    # Opcode 8 = Bitwise OR (|)
    movl $1, clr_next(%rip)
    ret

.p_xor:
    call parse_int64
    mov %rax, acc_int(%rip)
    movl $9, pending_op(%rip)    # Opcode 9 = Bitwise XOR (^)
    movl $1, clr_next(%rip)
    ret

.p_not:
    call parse_int64
    not %rax                     # Invert all 64 bits (~x)
    mov %rax, %rdi
    lea disp_buf(%rip), %rsi
    call format_current_base     # Format according to active base
    call update_prog_readouts    # Update live multi-base inspector
    movl $1, clr_next(%rip)
    ret

.p_shl:
    call parse_int64
    mov %rax, acc_int(%rip)
    movl $10, pending_op(%rip)   # Opcode 10 = Shift Left (<<)
    movl $1, clr_next(%rip)
    ret

.p_shr:
    call parse_int64
    mov %rax, acc_int(%rip)
    movl $11, pending_op(%rip)   # Opcode 11 = Shift Right (>>)
    movl $1, clr_next(%rip)
    ret

# ------------------------------------------------------------------------------
# eval_prog_op:
# Evaluates 64-bit integer arithmetic and bitwise operations in Programmer Mode.
# Operands:
#   First operand:  acc_int
#   Second operand: parse_int64(disp_buf)
# ------------------------------------------------------------------------------
eval_prog_op:
    call parse_int64
    mov %rax, %rbx              # %rbx = second operand
    mov acc_int(%rip), %rax     # %rax = first operand

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
    jmp .po_done

.po_add: add %rbx, %rax; jmp .po_done
.po_sub: sub %rbx, %rax; jmp .po_done
.po_mul: imul %rbx, %rax; jmp .po_done
.po_div:
    test %rbx, %rbx             # Guard against integer division by zero
    jz .po_div_zero
    xor %rdx, %rdx              # Clear high bits for signed division
    idiv %rbx
    jmp .po_done
.po_div_zero:
    xor %rax, %rax              # Set result to 0 on division by zero
    jmp .po_done

.po_and: and %rbx, %rax; jmp .po_done
.po_or:  or %rbx, %rax;  jmp .po_done
.po_xor: xor %rbx, %rax; jmp .po_done
.po_shl:
    mov %bl, %cl                # Shift count must be in %cl register
    shl %cl, %rax
    jmp .po_done
.po_shr:
    mov %bl, %cl
    shr %cl, %rax
    jmp .po_done

.po_done:
    mov %rax, acc_int(%rip)      # Store result in accumulator
    mov %rax, %rdi
    lea disp_buf(%rip), %rsi
    call format_current_base     # Format result in active radix
    call update_prog_readouts    # Refresh all 4 multi-base displays
    movl $0, pending_op(%rip)    # Reset operator
    movl $1, clr_next(%rip)      # Flag clear-on-next
    ret

# ------------------------------------------------------------------------------
# format_current_base:
# Formats integer %rdi into buffer %rsi according to curr_base setting:
#   curr_base = 0: Hexadecimal (format_hex_raw)
#   curr_base = 1: Decimal     (format_dec)
#   curr_base = 2: Octal       (format_oct_raw)
#   curr_base = 3: Binary      (format_bin_raw)
# ------------------------------------------------------------------------------
format_current_base:
    mov curr_base(%rip), %eax
    cmp $0, %eax; je format_hex_raw
    cmp $1, %eax; je format_dec
    cmp $2, %eax; je format_oct_raw
    cmp $3, %eax; je format_bin_raw
    jmp format_dec

# ------------------------------------------------------------------------------
# format_hex_raw:
# Formats 64-bit integer %rdi as clean hexadecimal string without '0x' prefix
# into buffer %rsi, skipping leading zeroes.
# ------------------------------------------------------------------------------
format_hex_raw:
    mov %rdi, %rax
    mov %rsi, %rdi
    mov $16, %ecx               # Up to 16 hex nibbles in 64 bits
.fhr_l:
    dec %ecx
    js .fhr_zero
    mov %rax, %rdx
    shr $60, %rdx               # Extract topmost nibble
    shl $4, %rax                # Shift next nibble to top
    test %rdx, %rdx
    jz .fhr_l                   # Skip leading zeroes
    jmp .fhr_emit

.fhr_zero:
    # All bits were zero: emit single '0'
    movb $'0', (%rdi)
    movb $0, 1(%rdi)
    ret

.fhr_emit:
    cmp $10, %dl                # Convert nibble to ASCII character ('0'-'9', 'A'-'F')
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

# ------------------------------------------------------------------------------
# format_oct_raw:
# Formats 64-bit integer %rdi as clean octal string without '0o' prefix
# into buffer %rsi, skipping leading zeroes.
# ------------------------------------------------------------------------------
format_oct_raw:
    mov %rdi, %rax
    mov %rsi, %rdi
    sub $32, %rsp
    mov %rsp, %rsi
    add $30, %rsi
    movb $0, 1(%rsi)

    test %rax, %rax
    jnz .for_loop
    movb $'0', (%rdi)           # Handle zero case
    movb $0, 1(%rdi)
    add $32, %rsp
    ret

.for_loop:
    mov %rax, %rdx
    and $7, %rdx                # Extract lowest 3 bits
    shr $3, %rax                # Shift out octal digit
    add $'0', %dl
    movb %dl, (%rsi)            # Store ASCII digit in reverse
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

# ------------------------------------------------------------------------------
# format_bin_raw:
# Formats 64-bit integer %rdi as clean binary string without prefix
# into buffer %rsi, skipping leading zeroes.
# ------------------------------------------------------------------------------
format_bin_raw:
    mov %rdi, %rax
    mov %rsi, %rdi

    # Find Most Significant Bit (MSB) that is set
    mov $63, %ecx
.fbr_find:
    bt %rcx, %rax               # Bit Test
    jc .fbr_found
    dec %ecx
    jns .fbr_find

    # All bits are zero: emit single '0'
    movb $'0', (%rdi)
    movb $0, 1(%rdi)
    ret

.fbr_found:
.fbr_emit:
    bt %rcx, %rax               # Test bit at index %rcx
    jc .fbr_one
    movb $'0', (%rdi)
    jmp .fbr_nxt
.fbr_one:
    movb $'1', (%rdi)
.fbr_nxt:
    inc %rdi
    dec %ecx
    jns .fbr_emit
    movb $0, (%rdi)             # Null terminate
    ret

# ------------------------------------------------------------------------------
# parse_int64:
# Parses numeric string in disp_buf into a 64-bit integer in %rax according
# to active radix (curr_base: 0=HEX, 1=DEC, 2=OCT, 3=BIN).
# ------------------------------------------------------------------------------
parse_int64:
    lea disp_buf(%rip), %rsi
    xor %rax, %rax              # %rax = accumulated integer
    mov curr_base(%rip), %r8d

.pi_loop:
    movzbq (%rsi), %rdx
    test %dl, %dl
    jz .pi_done                 # Stop at null terminator

    cmp $0, %r8d
    je .pi_hex
    cmp $2, %r8d
    je .pi_oct
    cmp $3, %r8d
    je .pi_bin

    # --- Base 10 (Decimal) ---
    cmpb $'0', %dl; jl .pi_done
    cmpb $'9', %dl; jg .pi_done
    sub $'0', %rdx
    imul $10, %rax
    add %rdx, %rax
    inc %rsi
    jmp .pi_loop

.pi_hex:
    # --- Base 16 (Hexadecimal: 0-9, A-F, a-f) ---
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
    shl $4, %rax                # Shift left 4 bits (multiply by 16)
    add %rdx, %rax
    inc %rsi
    jmp .pi_loop

.pi_oct:
    # --- Base 8 (Octal: 0-7) ---
    cmpb $'0', %dl; jl .pi_done
    cmpb $'7', %dl; jg .pi_done
    sub $'0', %rdx
    shl $3, %rax                # Shift left 3 bits (multiply by 8)
    add %rdx, %rax
    inc %rsi
    jmp .pi_loop

.pi_bin:
    # --- Base 2 (Binary: 0-1) ---
    cmpb $'0', %dl; jl .pi_done
    cmpb $'1', %dl; jg .pi_done
    sub $'0', %rdx
    shl $1, %rax                # Shift left 1 bit (multiply by 2)
    add %rdx, %rax
    inc %rsi
    jmp .pi_loop

.pi_done:
    ret

# ------------------------------------------------------------------------------
# update_prog_readouts:
# Updates all four live multi-base inspector buffers (hex_buf, dec_buf,
# oct_buf, bin_buf) based on the current number entered in disp_buf.
# ------------------------------------------------------------------------------
update_prog_readouts:
    push %rbx
    call parse_int64
    mov %rax, %rbx              # Preserve parsed 64-bit integer across calls

    # Update HEX readout buffer
    mov %rbx, %rdi
    lea hex_buf(%rip), %rsi
    call format_hex

    # Update DEC readout buffer
    mov %rbx, %rdi
    lea dec_buf(%rip), %rsi
    call format_dec

    # Update OCT readout buffer
    mov %rbx, %rdi
    lea oct_buf(%rip), %rsi
    call format_oct

    # Update BIN readout buffer
    mov %rbx, %rdi
    lea bin_buf(%rip), %rsi
    call format_bin

    pop %rbx
    ret

# ------------------------------------------------------------------------------
# format_hex:
# Formats integer %rdi as "0x" followed by 8 uppercase hexadecimal digits
# (32-bit DWORD view) into buffer %rsi.
# ------------------------------------------------------------------------------
format_hex:
    movb $'0', (%rsi)
    movb $'x', 1(%rsi)
    add $2, %rsi
    mov $8, %ecx                # Exactly 8 hex digits
.fh_l:
    dec %ecx
    js .fh_d
    mov %rdi, %rax
    mov %ecx, %edx
    shl $2, %edx                # Shift count = digit_index * 4
    mov %edx, %ecx
    shr %cl, %rax
    mov %edx, %ecx
    shr $2, %ecx
    and $0xF, %al               # Isolate 4-bit nibble
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
    movb $0, (%rsi)             # Null terminate
    ret

# ------------------------------------------------------------------------------
# format_dec:
# Formats integer %rdi as standard decimal into buffer %rsi.
# ------------------------------------------------------------------------------
format_dec:
    mov %rdi, %rax
    mov %rsi, %rdi
    jmp int_to_str

# ------------------------------------------------------------------------------
# format_oct:
# Formats integer %rdi as "0o" followed by octal digits into buffer %rsi.
# ------------------------------------------------------------------------------
format_oct:
    movb $'0', (%rsi)
    movb $'o', 1(%rsi)
    add $2, %rsi
    mov %rdi, %rax
    test %rax, %rax
    jnz .fo_nz
    movb $'0', (%rsi)           # If value is 0, emit "0"
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

# ------------------------------------------------------------------------------
# format_bin:
# Formats integer %rdi as 32-bit binary with a space separating each 8-bit byte:
# "00000000 00000000 00000000 00000000" into buffer %rsi.
# ------------------------------------------------------------------------------
format_bin:
    mov $32, %ecx               # 32 bits total
.fb_l:
    dec %ecx
    js .fb_d
    mov %rdi, %rax
    shr %cl, %rax
    and $1, %al
    add $'0', %al
    movb %al, (%rsi)
    inc %rsi

    # Insert byte separator space after every 8 bits (except at end)
    mov %ecx, %eax
    and $7, %eax
    jnz .fb_l
    test %ecx, %ecx
    jz .fb_l
    movb $' ', (%rsi)
    inc %rsi
    jmp .fb_l

.fb_d:
    movb $0, (%rsi)             # Null terminate
    ret
