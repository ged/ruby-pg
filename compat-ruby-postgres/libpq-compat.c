#include <stdlib.h>

#ifndef HAVE_PQESCAPESTRING
/*
 * Escaping arbitrary strings to get valid SQL literal strings.
 *
 * Replaces "\\" with "\\\\" and "'" with "''".
 *
 * length is the length of the source string.  (Note: if a terminating NUL
 * is encountered sooner, PQescapeString stops short of "length"; the behavior
 * is thus rather like strncpy.)
 *
 * For safety the buffer at "to" must be at least 2*length + 1 bytes long.
 * A terminating NUL character is added to the output string, whether the
 * input is NUL-terminated or not.
 *
 * Returns the actual length of the output (not counting the terminating NUL).
 */
size_t
PQescapeString(char *to, const char *from, size_t length)
{
	const char *source = from;
	char	   *target = to;
	size_t		remaining = length;

	while (remaining > 0 && *source != '\0')
	{
		switch (*source)
		{
			case '\\':
				*target++ = '\\';
				*target++ = '\\';
				break;

			case '\'':
				*target++ = '\'';
				*target++ = '\'';
				break;

			default:
				*target++ = *source;
				break;
		}
		source++;
		remaining--;
	}

	/* Write the terminating NUL character. */
	*target = '\0';

	return target - to;
}

/*
 *		PQescapeBytea	- converts from binary string to the
 *		minimal encoding necessary to include the string in an SQL
 *		INSERT statement with a bytea type column as the target.
 *
 *		The following transformations are applied
 *		'\0' == ASCII  0 == \\000
 *		'\'' == ASCII 39 == \'
 *		'\\' == ASCII 92 == \\\\
 *		anything < 0x20, or > 0x7e ---> \\ooo
 *										(where ooo is an octal expression)
 */
unsigned char *
PQescapeBytea(const unsigned char *bintext, size_t binlen, size_t *bytealen)
{
	const unsigned char *vp;
	unsigned char *rp;
	unsigned char *result;
	size_t		i;
	size_t		len;

	/*
	 * empty string has 1 char ('\0')
	 */
	len = 1;

	vp = bintext;
	for (i = binlen; i > 0; i--, vp++)
	{
		if (*vp < 0x20 || *vp > 0x7e)
			len += 5;			/* '5' is for '\\ooo' */
		else if (*vp == '\'')
			len += 2;
		else if (*vp == '\\')
			len += 4;
		else
			len++;
	}

	rp = result = (unsigned char *) malloc(len);
	if (rp == NULL)
		return NULL;

	vp = bintext;
	*bytealen = len;

	for (i = binlen; i > 0; i--, vp++)
	{
		if (*vp < 0x20 || *vp > 0x7e)
		{
			(void) sprintf(rp, "\\\\%03o", *vp);
			rp += 5;
		}
		else if (*vp == '\'')
		{
			rp[0] = '\\';
			rp[1] = '\'';
			rp += 2;
		}
		else if (*vp == '\\')
		{
			rp[0] = '\\';
			rp[1] = '\\';
			rp[2] = '\\';
			rp[3] = '\\';
			rp += 4;
		}
		else
			*rp++ = *vp;
	}
	*rp = '\0';

	return result;
}

#define ISFIRSTOCTDIGIT(CH) ((CH) >= '0' && (CH) <= '3')
#define ISOCTDIGIT(CH) ((CH) >= '0' && (CH) <= '7')
#define OCTVAL(CH) ((CH) - '0')

/*
 *		PQunescapeBytea - converts the null terminated string representation
 *		of a bytea, strtext, into binary, filling a buffer. It returns a
 *		pointer to the buffer (or NULL on error), and the size of the
 *		buffer in retbuflen. The pointer may subsequently be used as an
 *		argument to the function free(3). It is the reverse of PQescapeBytea.
 *
 *		The following transformations are made:
 *		\\	 == ASCII 92 == \
 *		\ooo == a byte whose value = ooo (ooo is an octal number)
 *		\x	 == x (x is any character not matched by the above transformations)
 */
unsigned char *
PQunescapeBytea(const unsigned char *strtext, size_t *retbuflen)
{
	size_t		strtextlen,
				buflen;
	unsigned char *buffer,
			   *tmpbuf;
	size_t		i,
				j;

	if (strtext == NULL)
		return NULL;

	strtextlen = strlen(strtext);

	/*
	 * Length of input is max length of output, but add one to avoid
	 * unportable malloc(0) if input is zero-length.
	 */
	buffer = (unsigned char *) malloc(strtextlen + 1);
	if (buffer == NULL)
		return NULL;

	for (i = j = 0; i < strtextlen;)
	{
		switch (strtext[i])
		{
			case '\\':
				i++;
				if (strtext[i] == '\\')
					buffer[j++] = strtext[i++];
				else
				{
					if ((ISFIRSTOCTDIGIT(strtext[i])) &&
						(ISOCTDIGIT(strtext[i + 1])) &&
						(ISOCTDIGIT(strtext[i + 2])))
					{
						int			byte;

						byte = OCTVAL(strtext[i++]);
						byte = (byte << 3) + OCTVAL(strtext[i++]);
						byte = (byte << 3) + OCTVAL(strtext[i++]);
						buffer[j++] = byte;
					}
				}

				/*
				 * Note: if we see '\' followed by something that isn't a
				 * recognized escape sequence, we loop around having done
				 * nothing except advance i.  Therefore the something will
				 * be emitted as ordinary data on the next cycle. Corner
				 * case: '\' at end of string will just be discarded.
				 */
				break;

			default:
				buffer[j++] = strtext[i++];
				break;
		}
	}
	buflen = j;					/* buflen is the length of the dequoted
								 * data */

	/* Shrink the buffer to be no larger than necessary */
	/* +1 avoids unportable behavior when buflen==0 */
	tmpbuf = realloc(buffer, buflen + 1);

	/* It would only be a very brain-dead realloc that could fail, but... */
	if (!tmpbuf)
	{
		free(buffer);
		return NULL;
	}

	*retbuflen = buflen;
	return tmpbuf;
}
#endif

#ifndef HAVE_PQEXECPARAMS
#include <ruby.h>
#include <re.h>
#include <libpq-fe.h>

#define BIND_PARAM_PATTERN "\\$(\\d+)"
#define BindParamNumber(match) (FIX2INT(rb_str_to_inum(rb_reg_nth_match(1, match), 10, 0))-1)

PGresult *PQexecParams_compat(PGconn *conn, VALUE command, VALUE values)
{
    VALUE bind_param_re = rb_reg_new(BIND_PARAM_PATTERN, 7, 0);
    VALUE result = rb_str_buf_new(RSTRING(command)->len);
    char* ptr = RSTRING(command)->ptr;
    int scan = 0;
    while ((scan = rb_reg_search(bind_param_re, command, scan, 0)) > 0) {
        VALUE match = rb_backref_get();
        int pos = BindParamNumber(match);
        if (pos < RARRAY(values)->len) {
            rb_str_buf_cat(result, ptr, scan - (ptr - RSTRING(command)->ptr));
            ptr = RSTRING(command)->ptr + scan;
            rb_str_buf_append(result, RARRAY(values)->ptr[pos]);
        }
        scan += RSTRING(rb_reg_nth_match(0, match))->len;
        ptr += RSTRING(rb_reg_nth_match(0, match))->len;
    }
    rb_str_buf_cat(result, ptr, RSTRING(command)->len - (ptr - RSTRING(command)->ptr));

    return PQexec(conn, StringValuePtr(result));
}
#endif
