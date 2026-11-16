# Libadwaita Complex Calculator (Pure x86_64 Assembly)

A modern, standalone desktop calculator built **100% in pure x86_64 Linux assembly**, adhering to GNOME's **Libadwaita** design language.

> **Zero C, Zero External Libraries, Zero Toolkits**:
> This application does **not** link against libc, Xlib, XCB, Cairo, GTK, or any runtime helper. It interacts directly with the Linux kernel via syscalls and speaks the raw binary X11 wire protocol over a UNIX domain socket.

---

## Features

- **Libadwaita Dark Design System**:
  - Exact Adwaita color palette (window background `#242424`, display card `#1E1E1E`, buttons `#323232`, accent blue `#3584E4`, destructive red `#E01B24`).
  - Client-Side Decorations (CSD): Custom headerbar with title, hamburger menu, history clock button, and close button, with window decorations suppressed via `_MOTIF_WM_HINTS`.
  - Window Dragging: Native interactive window movement via EWMH `_NET_WM_MOVERESIZE`.
  - Physical Window Rounded Corners: Physical window clipped to $r=16\text{px}$ using the **X11 Shape Extension** (`ShapeRectangles`).
  - True Subpixel Supersampling (SSAA): $2\times 2$ pixel subsampling on curved squircle boundaries with fixed-point alpha blending (0%, 25%, 50%, 75%, 100%) for ultra-smooth rounded corners against any background.
  - Modern Antialiased Typography: Native $16\times 32$ antialiased typography synthesized from `AdwaitaSans-Regular.ttf` with 8-bit coverage; renders with direct alpha blending ($2\times$) and $2\times 2$ box subsampling ($1\times$) for crisp, vector-quality text.

- **Fully Functional Calculation History & Journal**:
  - **Live Expression Display**: Current ongoing calculation expression is rendered clearly in the display card (e.g. `12 + 4 =`, `sin(45) =`, `0xFF & 0x0F =`).
  - **Multi-Entry History Journal**: Automatically records up to 8 completed calculations across Basic, Scientific, and Programmer modes.
  - **Dedicated History Popover**: Accessible via the Clock icon (`⏱`) in the HeaderBar or by clicking the history expression directly in the Display Card.
  - **Interactive Result Recall**: Clicking any previous calculation in the history popover instantly loads its result back into the active display for subsequent operations.
  - **Clear All History**: Wipes the history journal and resets the display history. Pressing `C` (Clear) resets active input without destroying previous history entries.

- **Three Operational Modes**:
  - **Basic Mode**: Standard 4x5 keypad layout with operator chaining, display history, and sign inversion.
  - **Scientific Mode**: 5x6 keypad layout with degree/radian trigonometric functions ($\sin$, $\cos$, $\tan$), constants ($\pi$, $e$), powers ($x^2$, $\sqrt{x}$, $1/x$), and logarithms ($\ln$, $\log_{10}$), all with automated history recording.
  - **Programmer Mode**: 5x6 keypad layout with 64-bit integer signed arithmetic, bitwise logic (`&`, `|`, `^`, `~`, `<<`, `>>`), hexadecimal entry (`A`–`F`), and a live synchronized 4-base inspector displaying **HEX**, **DEC**, **OCT**, and **BIN** representations.

- **Headless CI & Testing**:
  - Command-line flag `--dump <output.ppm> [mode] [menu/history]` renders full frames to Netpbm PPM image files without needing a running X server or display connection.

---

## Architectural Breakdown

```
Assembly-Calculator/
├── calc_ui.s      # UI Subsystem, Direct X11 Socket Driver & Software Rasterizer
├── calc_core.s    # Arithmetic Engine, x87 FPU Math, Radix Formatters & Keypad Dispatch
├── font.bin       # Embedded 105-glyph 16x32 antialiased typography font (8-bit coverage, includes Clock icon)
├── Makefile       # Standalone build automation (as + ld + strip)
└── README.md      # Comprehensive architecture and technical documentation
```

### 1. `calc_ui.s` (UI & X11 Driver)
- **Kernel Interface**: Uses direct x86_64 Linux syscalls (`sys_mmap`, `sys_socket`, `sys_connect`, `sys_poll`, `sys_read`, `sys_write`, `sys_open`, `sys_close`, `sys_exit`).
- **Memory Allocation**: Allocates an anonymous $420 \times 680 \times 4$ byte 32-bit ARGB framebuffer using `sys_mmap`.
- **Authentication**: Directly parses `~/.Xauthority` searching for `MIT-MAGIC-COOKIE-1` binary keys without helper utilities.
- **X11 Protocol Client**:
  - Sends little-endian connection setup packet to `/tmp/.X11-unix/X0`.
  - Dynamically interns required X11 atoms (`WM_PROTOCOLS`, `WM_DELETE_WINDOW`, `_MOTIF_WM_HINTS`, `_NET_WM_MOVERESIZE`, etc.).
  - Creates the top-level window (`CreateWindow`), graphics context (`CreateGC`), and sets CSD hints.
  - Configures physical window rounded corners via `QueryExtension "SHAPE"` and `ShapeRectangles` (minor opcode 1) with 33 clipping rectangles.
  - Pushes rendered framebuffer frames to screen in 32-row slices via `PutImage` (ZPixmap format, 24/32-bit depth).
- **History Journal & Popover Subsystem**:
  - `commit_history`: Inserts completed calculation into a ring buffer of 8 entries (`expr` up to 32 bytes, `res` up to 32 bytes).
  - `clear_history`: Empties all history records.
  - `render_history_popover`: Renders modern Libadwaita popover card displaying past calculations with hover states and recall interactions.
- **Software Graphics Engine**:
  - `draw_rect`: Solid color fills using `rep stosl`.
  - `blend_pixel`: High-speed fixed-point ARGB alpha blender ($B + (((F - B) \cdot \alpha + 128) \gg 8)$).
  - `draw_squircle`: $2\times 2$ subpixel supersampled (SSAA) rounded corner rasterizer with smooth fractional alpha boundary blending and 1px borders.
  - `draw_glyph`: Anti-aliased typography renderer supporting $2\times 2$ box subsampling and fractional coverage alpha blending against any background.
  - `draw_string`: Null-terminated string rendering with horizontal cursor advancement.
- **Event Dispatcher**:
  - Polls socket with `sys_poll` (20ms timeout).
  - Handles `Expose`, `MotionNotify`, `ButtonPress`, `ButtonRelease`, `KeyPress`, and `ClientMessage` (`WM_DELETE_WINDOW`).

### 2. `calc_core.s` (Arithmetic Engine)
- **Display Buffer Operations**: `append_disp_char`, `clear_disp`, `bksp_disp`, `toggle_sign`.
- **Floating-Point Engine**:
  - Evaluates expressions on the 80-bit x87 FPU stack (`faddp`, `fsubrp`, `fmulp`, `fdivrp`, `fchs`, `fsin`, `fcos`, `fptan`, `fsqrt`, `fyl2x`).
  - Guards against division by zero via `fcomip` and reports "Cannot divide by 0".
  - Detects NaN and Infinity overflow using `fxam` + `fnstsw` and reports "Error".
- **ASCII Number Conversions**:
  - `parse_double`: Converts ASCII strings to 80-bit IEEE-754 floats on `ST(0)`.
  - `format_double`: Formats `ST(0)` float into human-readable string, truncating integer part with `fisttpq`, extracting up to 6 decimal digits, and stripping trailing zeros.
  - `int_to_str`: Converts unsigned 64-bit integer to decimal string.
  - `parse_int64`: Radix-aware parser supporting HEX (0-9, A-F), DEC, OCT (0-7), and BIN (0-1).
- **Scientific & Programmer History Formatters**:
  - `scifn_prep`: Formats function expression (`sin(45) =`, etc.) and commits to history on calculation.
  - Programmer operations (`&`, `|`, `^`, `<<`, `>>`, `~`) update history expressions and commit to journal.
- **Programmer Multi-Base Formatters**:
  - Synchronously updates four distinct readout buffers: `hex_buf` (`0xXXXXXXXX`), `dec_buf`, `oct_buf` (`0o...`), and `bin_buf` (`XXXXXXXX XXXXXXXX XXXXXXXX XXXXXXXX`).

---

## Building and Running

### Prerequisites
- Linux x86_64
- GNU Assembler (`as`) and GNU Linker (`ld`) (available via `binutils` on all Linux distributions)
- An active X11 or Xwayland display server (for GUI mode)

### Build
Compile, link, and strip the binary:
```bash
make clean && make
```
The resulting executable is a standalone, statically linked ELF binary (`calculator`) with zero runtime dependencies.

### Run
Launch the calculator GUI:
```bash
./calculator
```

### Headless Verification (Frame Dump)
To render and verify the UI headlessly without an X server:
```bash
# Dump all modes, menu, and history to PPM image files
make dump

# Or specify custom modes directly:
# ./calculator --dump <filename.ppm> [mode: 0=Basic, 1=Scientific, 2=Programmer] [popover: 'm'=menu, 'h'=history]
./calculator --dump preview_basic.ppm 0
./calculator --dump preview_adv.ppm 1
./calculator --dump preview_prog.ppm 2
./calculator --dump preview_menu.ppm 0 m
./calculator --dump preview_hist.ppm 0 h
```

---

## Keyboard Shortcuts

| Key | Action |
|:---|:---|
| `0` – `9` | Enter digit |
| `.` | Enter decimal point |
| `+`, `-`, `*`, `/` | Arithmetic operators |
| `Enter` / `Numpad Enter` | Evaluate expression (`=`) |
| `BackSpace` | Delete last entered character |
| `Escape` / `c` | Clear active display input (`C`) |

---

## License
MIT License. Free for educational, research, and production use.
