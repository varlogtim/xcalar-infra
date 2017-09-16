CFLAGS=-std=gnu99 -O2 -fno-omit-frame-pointer -fno-builtin-malloc -ggdb -Wall -fPIC -D_GNU_SOURCE

CC=gcc
AR=ar

all: libguardrails.a libguardrails.so.0.0 test

libguardrails.a: GuardRails.o
	rm -f libguardrails.a
	$(AR) crv libguardrails.a GuardRails.o

libguardrails.so.0.0: GuardRails.o
	$(CC) -shared -Wl,-soname,libguardrails.so.0 -o libguardrails.so.0.0 \
		$(CFLAGS) GuardRails.o -lpthread -lc

GuardRails.o: GuardRails.c
	$(CC) $(CFLAGS) -c $< -o $@

test: test.o
	$(CC) -o test test.o

test.o: test.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f test test.o GuardRails.o libguardrails.a libguardrails.so.0.0
