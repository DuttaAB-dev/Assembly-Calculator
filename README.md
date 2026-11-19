# Assembly-Calculator (v1.2.0)

[![Release](https://img.shields.io/github/v/release/DuttaAB-dev/Assembly-Calculator?color=3584E4&label=version)](https://github.com/DuttaAB-dev/Assembly-Calculator/releases/latest)
[![Binary Size](https://img.shields.io/badge/binary%20size-74%20KB-success)](https://github.com/DuttaAB-dev/Assembly-Calculator/releases/latest)
[![Pure Assembly](https://img.shields.io/badge/language-x86__64%20assembly-orange)](#)
[![Zero Dependencies](https://img.shields.io/badge/dependencies-none%20(libc--free)-blue)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A modern, standalone desktop calculator built **100% in pure x86_64 Linux assembly** from scratch.

It features **zero external dependencies** — no C runtime (`libc`), no GTK, no Qt, and no Xlib. It speaks raw X11 binary wire protocol over a UNIX domain socket directly to the X server, and implements an in-house software 2D graphics engine with **$2\times 2$ subpixel supersampling (SSAA)**, fixed-point alpha blending, and fractional anti-aliased typography.

---

## Releases & Pre-Built Binaries

Pre-compiled, statically linked standalone binaries (74 KB ELF) with zero dependencies are available on the [**Releases Page**](https://github.com/DuttaAB-dev/Assembly-Calculator/releases):

### Download & Run v1.2.0
```bash
# Download the compressed release archive
wget https://github.com/DuttaAB-dev/Assembly-Calculator/releases/download/v1.2.0/assembly-calculator-v1.2.0-linux-x86_64.tar.gz

# Extract the archive
tar -xzf assembly-calculator-v1.2.0-linux-x86_64.tar.gz

# Run directly on any x86_64 Linux system
./assembly-calculator
```

Or download the standalone executable directly:
```bash
wget https://github.com/DuttaAB-dev/Assembly-Calculator/releases/download/v1.2.0/assembly-calculator
chmod +x assembly-calculator
./assembly-calculator
```

---

## Key Features

- **Pure x86_64 Linux Assembly**:
  - Zero external libraries: zero C runtime (`libc`), no Xlib/XCB, no OpenGL, no Cairo.
  - Direct Linux kernel system calls (`sys_mmap`, `sys_socket`, `sys_connect`, `sys_poll`, `sys_read`, `sys_write`, `sys_exit`).
  - Hand-crafted binary X11 protocol engine: connection setup, atom interning, CSD configuration, shaped windows, and pixmap blitting.

- **Modern Libadwaita Dark Theme & Visual Design**:
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

- **Command-Line Interface**:
  - `-v`, `--version`: Prints version metadata (`Assembly-Calculator v1.2.0`).
  - `-h`, `--help`: Prints comprehensive command-line options and usage syntax.
  - `--dump <file.ppm> [mode] [m|h]`: Headless CI rendering engine that renders pixel-accurate Netpbm PPM frames without requiring an X server or display connection.

---

## Architectural Breakdown

```
Assembly-Calculator/
├── calc_ui.s              # UI Subsystem, Direct X11 Socket Driver & Software Rasterizer
├── calc_core.s            # Arithmetic Engine, x87 FPU Math, Radix Formatters & Keypad Dispatch
├── font.bin               # Embedded 105-glyph 16x32 antialiased typography font (8-bit coverage)
├── Makefile               # Standalone build automation (as + ld + strip + release packaging)
├── .github/
│   └── workflows/
│       └── release.yml    # Automated CI/CD release builder and asset publisher
└── README.md              # Comprehensive architecture and technical documentation
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

## Building from Source

### Prerequisites
- Linux x86_64
- GNU Assembler (`as`) and GNU Linker (`ld`) (available via `binutils` on all Linux distributions)
- An active X11 or Xwayland display server (for GUI mode)

### Build Executable
```bash
make clean && make
```
The resulting executable is a standalone, statically linked ELF binary (`calculator`) with zero runtime dependencies.

### Package Release Archive
```bash
make release
```
Creates `dist/assembly-calculator`, `dist/assembly-calculator-v1.2.0-linux-x86_64.tar.gz`, and `dist/SHA256SUMS.txt`.

### Headless Verification (Frame Dump)
To render and verify the UI headlessly without an X server:
```bash
# Dump all modes, menu, and history to PPM image files
make dump

# Custom dumps:
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

## Release History

### v1.2.0 (Keypad Expansion, Live Preview & Typography Polish)
- **Live Expression Preview & Dual Result Display**: Real-time evaluation of ongoing binary operations in the upper history row while typing second operand, with persistence across keystrokes and dual display upon evaluation.
- **Keypad Expansion & Nested Brackets**: Added 16-level parenthesis evaluation stack (`(`, `)`) in both Basic and Scientific modes; expanded Basic mode to 4x6 grid (24 keys) and Scientific mode to 6x6 grid (36 keys) with power ($x^y$), absolute value (`abs`), factorial (`x!`), $10^x$, $\pi$, $e$, and reciprocal ($1/x$).
- **Header Bar Redesign**: Enlarged 3-bar hamburger icon, 16x16 circular clock face with hands for history, and crisp bold cross for window close.
- **Scale 3 Anti-Aliased Typography**: Dynamically rendered large, crisp input numbers up to 14 characters with automatic downscaling for longer inputs.
- **Subtle Amber Equals Button**: Styled equals button with warm amber (`#ED9A1E`) and crisp white glyph.

### v1.1.0 (UX & Physical Rounded Corners Release)
- **Physical Window Rounded Corners**: Corrected X11 wire protocol packet header alignment and `WM_NAME` socket length to properly enable direct X11 Shape Extension clipping (`ShapeBounding` and `ShapeClip`), eliminating sharp 90-degree outer corner triangles.
- **Keypad UX Redesign**: Replaced the isolated open-bracket key `'('` in Basic mode with `±` (toggle sign / negation) and added `%` (percentage division via x87 FPU) across all modes.
- **Streamlined Stability**: Zero libc, zero external dependencies, robust socket protocol synchronization.

### v1.0.0 (Initial Release)
- **Zero-Dependency x86_64 Assembly Engine**: Full standalone calculator implemented in pure Linux assembly.
- **Tri-Mode Support**: Basic, Scientific, and Programmer modes with interactive base conversions.
- **Libadwaita Dark Theme CSD**: Custom HeaderBar, hamburger menu popover, and interactive window dragging.
- **X11 Shaped Window**: Physical rounded corners via X11 Shape extension.
- **2x2 Subpixel Supersampling (SSAA)**: Smooth antialiased squircles and buttons with fixed-point alpha blending.
- **Anti-Aliased Typography**: Native $16\times 32$ 8-bit coverage font with $2\times 2$ box subsampling.
- **Calculation History Journal**: Multi-entry calculation memory and dedicated History Popover with click recall.
- **Headless CI Testing**: Netpbm PPM frame dump engine (`--dump`).
- **CLI Options**: `-v`/`--version` and `-h`/`--help`.

---

## License
MIT License. Free for educational, research, and production use.
