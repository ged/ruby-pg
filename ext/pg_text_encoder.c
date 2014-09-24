/*
 * pg_text_encoder.c - PG::TextEncoder module
 * $Id$
 *
 */

/*
 *
 * Type casts for encoding Ruby objects to PostgreSQL string representation.
 *
 * Encoder classes are defined with pg_define_coder(). This assigns the encoder function to
 * the coder. The encoder function is called twice - the first call to determine the
 * required output size and the second call to do the actual conversion.
 *
 * Signature of all type cast encoders is:
 *    int encoder_function(t_pg_coder *coder, VALUE value, char *out, VALUE *intermediate)
 *
 * Params:
 *   coder - The coder object that belongs to the encoder function.
 *   value - The Ruby object to cast.
 *   out   - NULL for the first call,
 *           pointer to a buffer with the requested size for the second call.
 *   intermediate - pointer to a VALUE that might be set by the encoding function to some
 *           value in the first call that can be retrieved in the second call.
 *
 * Returns:
 *   >= 0  - If out==NULL the encoder function must return the expected output buffer size.
 *           This can be larger than the size of the second call.
 *           If out!=NULL the encoder function must return the actually used output buffer size.
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
pg_coder_enc_to_str(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	*intermediate = rb_obj_as_string(value);
	return -1;
}

static int
pg_text_enc_integer(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		if(TYPE(*intermediate) == T_STRING){
			return pg_coder_enc_to_str(conv, value, out, intermediate);
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
						return pg_coder_enc_to_str(conv, *intermediate, NULL, intermediate);
					}
				}
			}
			return sll < 0 ? len+1 : len;
		}else{
			return pg_coder_enc_to_str(conv, *intermediate, NULL, intermediate);
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
ensure_str_capa( VALUE str, long expand_len, char *end_ptr )
{
	long curr_len = end_ptr - RSTRING_PTR(str);
	long curr_capa = rb_str_capacity( str );
	if( curr_capa < curr_len + expand_len ){
		rb_str_modify_expand( str, (curr_len + expand_len) * 2 - curr_capa );
		return RSTRING_PTR(str) + curr_len;
	}
	return end_ptr;
}

static char *
write_array(t_pg_composite_coder *comp_conv, VALUE value, char *current_out, VALUE *intermediate, t_pg_coder_enc_func enc_func, int quote)
{
	int i;

	/* size of "{}" */
	current_out = ensure_str_capa( *intermediate, 2, current_out );
	*current_out++ = '{';

	for( i=0; i<RARRAY_LEN(value); i++){
		int strlen;
		VALUE subint;
		VALUE entry = rb_ary_entry(value, i);


		if( i > 0 ){
			current_out = ensure_str_capa( *intermediate, 1, current_out );
			*current_out++ = comp_conv->delimiter;
		}

		switch(TYPE(entry)){
			case T_ARRAY:
				current_out = write_array(comp_conv, entry, current_out, intermediate, enc_func, quote);
			break;
			case T_NIL:
				current_out = ensure_str_capa( *intermediate, 4, current_out );
				*current_out++ = 'N';
				*current_out++ = 'U';
				*current_out++ = 'L';
				*current_out++ = 'L';
				break;
			default:

				strlen = enc_func(comp_conv->elem, entry, NULL, &subint);

				if( strlen == -1 ){
					/* we can directly use String value in subint */
					strlen = RSTRING_LEN(subint);

					if(quote){
						char *ptr1;
						/* size of string assuming the worst case, that every character must be escaped. */
						current_out = ensure_str_capa( *intermediate, strlen * 2, current_out );

						/* Copy string from subint with backslash escaping */
						for(ptr1 = RSTRING_PTR(subint); ptr1 < RSTRING_PTR(subint) + strlen; ptr1++) {
							if(*ptr1 == '"' || *ptr1 == '\\'){
								*current_out++ = '\\';
							}
							*current_out++ = *ptr1;
						}
					} else {
						current_out = ensure_str_capa( *intermediate, strlen, current_out );
						memcpy( current_out, RSTRING_PTR(subint), strlen );
						current_out += strlen;
					}

				} else {

					if(quote){
						char *ptr1;
						char *ptr2;
						int backslashs;

						/* size of string assuming the worst case, that every character must be escaped
						 * plus two bytes for quotation.
						 */
						current_out = ensure_str_capa( *intermediate, 2 * strlen + 2, current_out );

						*current_out++ = '"';

						/* Place the unescaped string at current output position. */
						strlen = enc_func(comp_conv->elem, entry, current_out, &subint);
						ptr1 = current_out;
						ptr2 = current_out + strlen;

						/* count required backlashs */
						for(backslashs = 0; ptr1 != ptr2; ptr1++) {
							if(*ptr1 == '"' || *ptr1 == '\\'){
								backslashs++;
							}
						}

						ptr1 = current_out + strlen;
						ptr2 = current_out + strlen + backslashs;
						current_out = ptr2;
						*current_out++ = '"';

						/* Then store the escaped string on the final position, walking
						 * right to left, until all backslashs are placed. */
						while( ptr1 != ptr2 ) {
							*--ptr2 = *--ptr1;
							if(*ptr2 == '"' || *ptr2 == '\\'){
								*--ptr2 = '\\';
							}
						}
					}else{
						/* size of the unquoted string */
						current_out = ensure_str_capa( *intermediate, strlen, current_out );
						current_out += enc_func(comp_conv->elem, entry, current_out, &subint);
					}
				}
		}
	}
	current_out = ensure_str_capa( *intermediate, 1, current_out );
	*current_out++ = '}';
	return current_out;
}

int
pg_text_enc_in_ruby(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	if( out ){
		memcpy(out, RSTRING_PTR(*intermediate), RSTRING_LEN(*intermediate));
		return RSTRING_LEN(*intermediate);
	}else{
		*intermediate = rb_funcall( conv->coder_obj, s_id_encode, 1, value );
		StringValue( *intermediate );
		return RSTRING_LEN(*intermediate);
	}
}

static t_pg_coder_enc_func
composite_elem_func(t_pg_composite_coder *comp_conv)
{
	if( comp_conv->elem ){
		if( comp_conv->elem->enc_func ){
			return comp_conv->elem->enc_func;
		}else{
			return pg_text_enc_in_ruby;
		}
	}else{
		/* no element encoder defined -> use std to_str conversion */
		return pg_coder_enc_to_str;
	}
}

static int
pg_text_enc_array(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	char *end_ptr;
	t_pg_composite_coder *comp_conv = (t_pg_composite_coder *)conv;
	t_pg_coder_enc_func enc_func = composite_elem_func(comp_conv);
	*intermediate = rb_str_new(NULL, 0);

	end_ptr = write_array(comp_conv, value, RSTRING_PTR(*intermediate), intermediate, enc_func, comp_conv->needs_quotation);

	rb_str_set_len( *intermediate, end_ptr - RSTRING_PTR(*intermediate) );

	return -1;
}

static int
quote_string(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate, char quote_char)
{
	t_pg_composite_coder *comp_conv = (t_pg_composite_coder *)conv;
	t_pg_coder_enc_func enc_func = composite_elem_func(comp_conv);

	if( comp_conv->needs_quotation ){
		if( out ){
			char *ptr1;
			char *ptr2;
			int strlen;
			int escapes;
			*out++ = quote_char;

			/* Place the unescaped string at current output position. */
			strlen = enc_func(comp_conv->elem, value, out, intermediate);
			ptr1 = out;
			ptr2 = out + strlen;

			/* count required escapes */
			for(escapes = 0; ptr1 != ptr2; ptr1++) {
				if(*ptr1 == quote_char){
					escapes++;
				}
			}

			ptr2 += escapes;
			*ptr2 = quote_char;

			/* Then store the escaped string on the final position, walking
			 * right to left, until all escapes are placed. */
			while( ptr1 != ptr2 ) {
				*--ptr2 = *--ptr1;
				if(*ptr2 == quote_char){
					*--ptr2 = quote_char;
				}
			}

			return 1 + strlen + escapes + 1;
		} else {
			/* size of string assuming the worst case, that every character must be escaped
			 * plus two bytes for quotation.
			 */
			return enc_func(comp_conv->elem, value, NULL, intermediate) * 2 + 2;
		}
	} else {
		/* no quotation required -> pass through to elem type */
		return enc_func(comp_conv->elem, value, out, intermediate);
	}
}

static int
pg_text_enc_array_identifier(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	int i;
	if( out ){
		char *out_start = out;
		int nr_elems = RARRAY_LEN(value);
		for( i=0; i<nr_elems; i++){
			VALUE subint = rb_ary_entry(*intermediate, i);
			VALUE entry = rb_ary_entry(value, i);

			out += quote_string(conv, entry, out, &subint, '"');
			if( i < nr_elems-1 ){
				*out++ = '.';
			}
		}
		return out - out_start;
	} else {
		int sumlen = 0;
		Check_Type(value, T_ARRAY);
		*intermediate = rb_ary_new();

		for( i=0; i<RARRAY_LEN(value); i++){
			VALUE subint;
			VALUE entry = rb_ary_entry(value, i);

			sumlen += quote_string(conv, entry, out, &subint, '"');
			rb_ary_push(*intermediate, subint);
		}
		/* add one byte per "." seperator */
		sumlen += RARRAY_LEN(value) - 1;
		return sumlen;
	}
}

static int
pg_text_enc_identifier(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	if( TYPE(value) == T_ARRAY){
		return pg_text_enc_array_identifier(conv, value, out, intermediate);
	} else {
		return quote_string(conv, value, out, intermediate, '"');
	}
}

static int
pg_text_enc_quoted_literal(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	return quote_string(conv, value, out, intermediate, '\'');
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
