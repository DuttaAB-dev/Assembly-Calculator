AS ?= as
LD ?= ld

all: calculator

calc_ui.o: calc_ui.s font.bin
	$(AS) calc_ui.s -o calc_ui.o

calc_core.o: calc_core.s
	$(AS) calc_core.s -o calc_core.o

calculator: calc_ui.o calc_core.o
	$(LD) calc_ui.o calc_core.o -o calculator
	strip -s -R .comment -R .note calculator

clean:
	rm -f *.o calculator

.PHONY: all clean
