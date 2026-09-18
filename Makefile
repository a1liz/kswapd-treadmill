CC      ?= gcc
CFLAGS  ?= -O2 -Wall -pthread
BINS     = frag_pin fileprober bindread

all: $(BINS)

frag_pin: src/frag_pin.c src/common.h
	$(CC) $(CFLAGS) -o $@ $<

fileprober: src/fileprober.c src/common.h
	$(CC) $(CFLAGS) -o $@ $<

bindread: src/bindread.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(BINS)

.PHONY: all clean
