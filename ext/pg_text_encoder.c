/*
 * pg_text_encoder.c - PG::TextEncoder module
 * $Id$
 *
 */

/*
 *
 * Type casts for encoding Ruby objects to PostgreSQL string representation.
 *
 * Encoder classes are defined with pg_define_coder(). This assigns an encoder function to
 * the coder. The encoder function can decide between two different options to return the
 * encoded data. It can either return it as a Ruby String object or the expected length of
 * the encoded data. In the second option the encoder function is called a second time, when
 * the requested memory space was made available by the calling function, to do the actual
 * conversion.
 *
 * Signature of all type cast encoders is:
 *    int encoder_function(t_pg_coder *coder, VALUE value, char *out, VALUE *intermediate)
 *
 * Params:
 *   coder - The data part of the coder object that belongs to the encoder function.
 *   value - The Ruby object to cast.
 *   out   - NULL for the first call,
 *           pointer to a buffer with the requested size for the second call.
 *   intermediate - pointer to a VALUE that might be set by the encoding function to some
 *           value in the first call that can be retrieved later in the second call.
 *
 * Returns:
 *   >= 0  - If out==NULL the encoder function must return the expected output buffer size.
 *           This can be larger than the size of the second call.
 *           If out!=NULL the encoder function must return the actually used output buffer size
 *           without a termination character.
 *   -1    - The encoder function can alternatively return -1 to indicate that no second call
 *           is required, but the String value in *intermediate should be used instead.
 */


#include "pg.h"
#include "util.h"
#include <inttypes.h>

VALUE rb_mPG_TextEncoder;
static ID s_id_encode;
static ID s_id_to_i;


VALUE
pg_obj_to_i( VALUE value )
{
	switch (TYPE(value)) {
		case T_FIXNUM:
		case T_FLOAT:
		case T_BIGNUM:
			return value;
		default:
			return rb_funcall(value, s_id_to_i, 0);
	}
}

int
pg_coder_enc_to_str(t_pg_coder *this, VALUE value, char *out, VALUE *intermediate)
{
	*intermediate = rb_obj_as_string(value);
	return -1;
}

static int
pg_text_enc_integer(t_pg_coder *this, VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		if(TYPE(*intermediate) == T_STRING){
			return pg_coder_enc_to_str(this, value, out, intermediate);
		}else{
			char *start = out;
			int len;
			int neg = 0;
			long long ll = NUM2LL(*intermediate);

			if (ll < 0) {
				/* We don't expect problems with the most negative integer not being representable
				 * as a positive integer, because Fixnum is only up to 63 bits.
				 */
				ll = -ll;
				neg = 1;
			}

			/* Compute the result string backwards. */
			do {
				long long remainder;
				long long oldval = ll;

				ll /= 10;
				remainder = oldval - ll * 10;
				*out++ = '0' + remainder;
			} while (ll != 0);

			if (neg)
				*out++ = '-';

			len = out - start;

			/* Reverse string. */
			out--;
			while (start < out)
			{
				char swap = *start;

				*start++ = *out;
				*out-- = swap;
			}

			return len;
		}
	}else{
		*intermediate = pg_obj_to_i(value);
		if(TYPE(*intermediate) == T_FIXNUM){
			int len;
			long long sll = NUM2LL(*intermediate);
			long long ll = sll < 0 ? -sll : sll;
			if( ll < 100000000 ){
				if( ll < 10000 ){
					if( ll < 100 ){
						len = ll < 10 ? 1 : 2;
					}else{
						len = ll < 1000 ? 3 : 4;
					}
				}else{
					if( ll < 1000000 ){
						len = ll < 100000 ? 5 : 6;
					}else{
						len = ll < 10000000 ? 7 : 8;
					}
				}
			}else{
				if( ll < 1000000000000 ){
					if( ll < 10000000000 ){
						len = ll < 1000000000 ? 9 : 10;
					}else{
						len = ll < 100000000000 ? 11 : 12;
					}
				}else{
					if( ll < 100000000000000 ){
						len = ll < 10000000000000 ? 13 : 14;
					}else{
						return pg_coder_enc_to_str(this, *intermediate, NULL, intermediate);
					}
				}
			}
			return sll < 0 ? len+1 : len;
		}else{
			return pg_coder_enc_to_str(this, *intermediate, NULL, intermediate);
		}
	}
}

static int
pg_text_enc_float(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		return sprintf( out, "%.16E", NUM2DBL(value));
	}else{
		*intermediate = value;
		return 23;
	}
}

static char *
quote_string(t_pg_coder *this, VALUE value, VALUE string, char *current_out, char quote_char, char escape_char)
{
	int strlen;
	VALUE subint;
	t_pg_coder_enc_func enc_func = pg_coder_enc_func(this);

	strlen = enc_func(this, value, NULL, &subint);

	if( strlen == -1 ){
		/* we can directly use String value in subint */
		strlen = RSTRING_LEN(subint);

		if(quote_char){
			char *ptr1;
			/* size of string assuming the worst case, that every character must be escaped. */
			current_out = pg_ensure_str_capa( string, strlen * 2 + 2, current_out );

			*current_out++ = quote_char;

			/* Copy string from subint with backslash escaping */
			for(ptr1 = RSTRING_PTR(subint); ptr1 < RSTRING_PTR(subint) + strlen; ptr1++) {
				if(*ptr1 == quote_char || *ptr1 == escape_char){
					*current_out++ = escape_char;
				}
				*current_out++ = *ptr1;
			}
			*current_out++ = quote_char;
		} else {
			current_out = pg_ensure_str_capa( string, strlen, current_out );
			memcpy( current_out, RSTRING_PTR(subint), strlen );
			current_out += strlen;
		}

	} else {

		if(quote_char){
			char *ptr1;
			char *ptr2;
			int backslashs;

			/* size of string assuming the worst case, that every character must be escaped
				* plus two bytes for quotation.
				*/
			current_out = pg_ensure_str_capa( string, 2 * strlen + 2, current_out );

			*current_out++ = quote_char;

			/* Place the unescaped string at current output position. */
			strlen = enc_func(this, value, current_out, &subint);
			ptr1 = current_out;
			ptr2 = current_out + strlen;

			/* count required backlashs */
			for(backslashs = 0; ptr1 != ptr2; ptr1++) {
				if(*ptr1 == quote_char || *ptr1 == escape_char){
					backslashs++;
				}
			}

			ptr1 = current_out + strlen;
			ptr2 = current_out + strlen + backslashs;
			current_out = ptr2;
			*current_out++ = quote_char;

			/* Then store the escaped string on the final position, walking
				* right to left, until all backslashs are placed. */
			while( ptr1 != ptr2 ) {
				*--ptr2 = *--ptr1;
				if(*ptr2 == quote_char || *ptr2 == escape_char){
					*--ptr2 = escape_char;
				}
			}
		}else{
			/* size of the unquoted string */
			current_out = pg_ensure_str_capa( string, strlen, current_out );
			current_out += enc_func(this, value, current_out, &subint);
		}
	}
	return current_out;
}

static char *
write_array(t_pg_composite_coder *this, VALUE value, char *current_out, VALUE string, int quote)
{
	int i;

	/* size of "{}" */
	current_out = pg_ensure_str_capa( string, 2, current_out );
	*current_out++ = '{';

	for( i=0; i<RARRAY_LEN(value); i++){
		VALUE entry = rb_ary_entry(value, i);

		if( i > 0 ){
			current_out = pg_ensure_str_capa( string, 1, current_out );
			*current_out++ = this->delimiter;
		}

		switch(TYPE(entry)){
			case T_ARRAY:
				current_out = write_array(this, entry, current_out, string, quote);
			break;
			case T_NIL:
				current_out = pg_ensure_str_capa( string, 4, current_out );
				*current_out++ = 'N';
				*current_out++ = 'U';
				*current_out++ = 'L';
				*current_out++ = 'L';
				break;
			default:
				current_out = quote_string( this->elem, entry, string, current_out, quote ? '"' : 0, '\\' );
		}
	}
	current_out = pg_ensure_str_capa( string, 1, current_out );
	*current_out++ = '}';
	return current_out;
}

static int
pg_text_enc_array(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	char *end_ptr;
	t_pg_composite_coder *this = (t_pg_composite_coder *)conv;
	*intermediate = rb_str_new(NULL, 0);

	end_ptr = write_array(this, value, RSTRING_PTR(*intermediate), *intermediate, this->needs_quotation);

	rb_str_set_len( *intermediate, end_ptr - RSTRING_PTR(*intermediate) );

	return -1;
}

static char *
pg_text_enc_array_identifier(t_pg_composite_coder *this, VALUE value, VALUE string, char *out)
{
	int i;
	int nr_elems;
	Check_Type(value, T_ARRAY);
	nr_elems = RARRAY_LEN(value);

	for( i=0; i<nr_elems; i++){
		VALUE entry = rb_ary_entry(value, i);

		out = quote_string(this->elem, entry, string, out, this->needs_quotation ? '"' : 0, '"');
		if( i < nr_elems-1 ){
			out = pg_ensure_str_capa( string, 1, out );
			*out++ = '.';
		}
	}
	return out;
}

static int
pg_text_enc_identifier(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	t_pg_composite_coder *this = (t_pg_composite_coder *)conv;

	*intermediate = rb_str_new(NULL, 0);
	out = RSTRING_PTR(*intermediate);

	if( TYPE(value) == T_ARRAY){
		out = pg_text_enc_array_identifier(this, value, *intermediate, out);
	} else {
		out = quote_string(this->elem, value, *intermediate, out, this->needs_quotation ? '"' : 0, '"');
	}
	rb_str_set_len( *intermediate, out - RSTRING_PTR(*intermediate) );
	return -1;
}

static int
pg_text_enc_quoted_literal(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	t_pg_composite_coder *this = (t_pg_composite_coder *)conv;

	*intermediate = rb_str_new(NULL, 0);
	out = RSTRING_PTR(*intermediate);
	out = quote_string(this->elem, value, *intermediate, out, this->needs_quotation ? '\'' : 0, '\'');
	rb_str_set_len( *intermediate, out - RSTRING_PTR(*intermediate) );
	return -1;
}


void
init_pg_text_encoder()
{
	s_id_encode = rb_intern("encode");
	s_id_to_i = rb_intern("to_i");

	/* This module encapsulates all encoder classes for text format */
	rb_mPG_TextEncoder = rb_define_module_under( rb_mPG, "TextEncoder" );

	pg_define_coder( "Boolean", pg_coder_enc_to_str, rb_cPG_SimpleEncoder, rb_mPG_TextEncoder );
	pg_define_coder( "Integer", pg_text_enc_integer, rb_cPG_SimpleEncoder, rb_mPG_TextEncoder );
	pg_define_coder( "Float", pg_text_enc_float, rb_cPG_SimpleEncoder, rb_mPG_TextEncoder );
	pg_define_coder( "String", pg_coder_enc_to_str, rb_cPG_SimpleEncoder, rb_mPG_TextEncoder );

	pg_define_coder( "Array", pg_text_enc_array, rb_cPG_CompositeEncoder, rb_mPG_TextEncoder );
	pg_define_coder( "Identifier", pg_text_enc_identifier, rb_cPG_CompositeEncoder, rb_mPG_TextEncoder );
	pg_define_coder( "QuotedLiteral", pg_text_enc_quoted_literal, rb_cPG_CompositeEncoder, rb_mPG_TextEncoder );
}
