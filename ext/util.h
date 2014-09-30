/*
 * utils.h
 *
 */

#ifndef __utils_h
#define __utils_h


/*
 * This bit hides differences between systems on big-endian conversions.
 *
 */
#if defined(__linux__)
#  include <endian.h>
#elif defined(__FreeBSD__) || defined(__NetBSD__)
#  include <sys/endian.h>
#elif defined(__OpenBSD__)
#  include <sys/types.h>
#  define be16toh(x) betoh16(x)
#  define be32toh(x) betoh32(x)
#  define be64toh(x) betoh64(x)
#elif defined(_WIN32)
#  define be16toh(x) pg_be16toh(x)
#  define be32toh(x) pg_be32toh(x)
#  define be64toh(x) pg_be64toh(x)
#  define htobe16(x) pg_be16toh(x)
#  define htobe32(x) pg_be32toh(x)
#  define htobe64(x) pg_be64toh(x)
#endif

uint16_t pg_be16toh(uint16_t x);
uint32_t pg_be32toh(uint32_t x);
uint64_t pg_be64toh(uint64_t x);

#define BASE64_ENCODED_SIZE(strlen) (((strlen) + 2) / 3 * 4)
#define BASE64_DECODED_SIZE(base64len) (((base64len) + 3) / 4 * 3)

void base64_encode( char *out, char *in, int len);
int base64_decode( char *out, char *in, unsigned int len);

#endif /* end __utils_h */
