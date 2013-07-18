/*
 * util.c - Utils for ruby-pg
 * $Id$
 *
 */

#include "pg.h"
#include "util.h"

/*
 * These functions assume little endian machine as they're only used on windows.
 *
 */
uint16_t pg_be16toh(uint16_t x)
{
	return ((x & 0x00ff) << 8) | ((x & 0xff00) >> 8);
}

uint32_t pg_be32toh(uint32_t x)
{
	return (x >> 24) |
		((x << 8) & 0x00ff0000L) |
		((x >> 8) & 0x0000ff00L) |
		(x << 24);
}

uint64_t pg_be64toh(uint64_t x)
{
	return (x >> 56) |
		((x << 40) & 0x00ff000000000000LL) |
		((x << 24) & 0x0000ff0000000000LL) |
		((x << 8) & 0x000000ff00000000LL) |
		((x >> 8) & 0x00000000ff000000LL) |
		((x >> 24) & 0x0000000000ff0000LL) |
		((x >> 40) & 0x000000000000ff00LL) |
		(x << 56);
}
