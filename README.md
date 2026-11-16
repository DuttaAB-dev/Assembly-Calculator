# Autonomous Pure-Assembly Libadwaita Complex Calculator

A multi-mode complex scientific & programming calculator created **exclusively in pure x86_64 Machine Assembly (`.s`) and raw binary (`.bin`)**.

Built from fundamental principles with **zero C, zero Python, zero external GUI toolkits, and zero human runtime libraries**.

---

## Visual Architecture & Previews

The application strictly implements the **GNOME 45+ Libadwaita Human Interface Guidelines (HIG)**:

1. **CSD HeaderBar**: Custom client-side decoration headerbar with a hamburger menu button `≡`, centered title, and circular close button `x` (`#3A3A3A`, hover `#E01B24`). Suppresses window manager titlebars via `_MOTIF_WM_HINTS = {2, 0, 0, 0, 0}` and supports native window dragging via `_NET_WM_MOVERESIZE`.
2. **Popover Submenu**: Floating Libadwaita popover menu card with 12px corner radius, drop shadow, active radio indicators (`●` / `○`), and destructive actions (`Clear History`).
3. **Inset OLED Display Card**: Deep black card (`#1E1E1E`) with subtle 1px border (`#333333`) and 12px corner radii.
4. **Tactile Squircle Keypads**: Rounded buttons (radius 10px) with 1px highlight outlines, drop shadows, and responsive states (idle, hover, active).

### Supported Calculator Modes

- **Basic Calculator**: Full arithmetic evaluation (`+`, `-`, `×`, `÷`, `+/-`, `(`, `0`–`9`, `.`, `=`), double-precision floating point with decimal fraction support, chained operations (`12 + 34 + 5`), and expression history.
- **Scientific Calculator**: Hardware x87 FPU trigonometric routines (`sin`, `cos`, `tan`), natural and common logarithms (`ln`, `log`), powers & roots (`x²`, `1/x`, `√`), and constants ($\pi$, $e$).
- **Programming Calculator**: 64-bit integer bitwise operations (`AND`, `OR`, `XOR`, `NOT`, `<<`, `>>`), hexadecimal input (`A`–`F`), integer arithmetic (`+`, `-`, `×`, `÷`), and a **live 4-base inspector** with clickable active base switching (`HEX`, `DEC`, `OCT`, `BIN`).

---

## File Structure

| File | Type | Description | Size |
| :--- | :--- | :--- | :--- |
| [`font.bin`](font.bin) | Binary | Synthesized 8x16 bitmap font covering ASCII 32–136 | 1.6 KB |
| [`calc_ui.s`](calc_ui.s) | x86_64 Assembly | Raw X11 wire socket, CSD hints, framebuffer blitter, squircle rasterizer, Popover menu, event dispatcher | 39 KB |
| [`calc_core.s`](calc_core.s) | x86_64 Assembly | x87 FPU math engine, 64-bit bitwise logic, string parsing, multi-base formatting | 26 KB |
| [`Makefile`](Makefile) | Build | Direct invocation of `as` and `ld` (no compiler needed) | 325 B |
| [`calculator`](calculator) | ELF Executable | **Statically linked, stripped standalone binary** | **19.6 KB** |

---

## Build and Execution

### Assemble & Link (Pure `as` + `ld`)
```bash
make clean && make
```

### Run
```bash
./calculator
```

### Headless Verification Frame Dump
```bash
# Dump Basic Mode
./calculator --dump preview_basic.ppm 0

# Dump Scientific Mode
./calculator --dump preview_adv.ppm 1

# Dump Programming Mode with 4-Base Readouts
./calculator --dump preview_prog.ppm 2

# Dump Popover Submenu
./calculator --dump preview_menu.ppm 0 m
```

### Verify Zero Dependencies
```bash
$ file ./calculator
calculator: ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, stripped

$ ldd ./calculator
not a dynamic executable
```
