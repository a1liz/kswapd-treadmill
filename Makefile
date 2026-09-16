CC      ?= gcc
CFLAGS  ?= -O2 -Wall -pthread
BINS     = frag_pin fileprober

all: $(BINS)

frag_pin: src/frag_pin.c src/common.h
	$(CC) $(CFLAGS) -o $@ $<

fileprober: src/fileprober.c src/common.h
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(BINS)

.PHONY: all clean
