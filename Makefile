# ==============================================================================
# Pure x86_64 Assembly Libadwaita Complex Calculator - Makefile
#
# Builds a standalone, statically linked executable with zero external libraries.
# Toolchain: GNU Assembler (as) and GNU Linker (ld).
# ==============================================================================

AS ?= as
LD ?= ld

# Default build target: compiles assembly files, links, and strips ELF binary
all: calculator

# UI Subsystem, X11 Protocol Driver, and Embedded Font
calc_ui.o: calc_ui.s font.bin
	$(AS) calc_ui.s -o calc_ui.o

# Core Arithmetic, Floating-Point FPU, and Base Conversion Engine
calc_core.o: calc_core.s
	$(AS) calc_core.s -o calc_core.o

# Statically link object files and strip metadata/comments for minimal footprint
calculator: calc_ui.o calc_core.o
	$(LD) calc_ui.o calc_core.o -o calculator
	strip -s -R .comment -R .note calculator

# Test headless rendering (generates sample frame dumps in Netpbm PPM format)
dump: calculator
	./calculator --dump preview_basic.ppm 0
	./calculator --dump preview_adv.ppm 1
	./calculator --dump preview_prog.ppm 2
	./calculator --dump preview_menu.ppm 0 m
	./calculator --dump preview_hist.ppm 0 h

# Remove build artifacts and temporary previews
clean:
	rm -f *.o calculator preview_*.ppm preview_*.png

.PHONY: all dump clean
