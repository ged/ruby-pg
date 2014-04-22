/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"
#include "util.h"
#include <inttypes.h>

VALUE rb_mPG_TextEncoder;
VALUE rb_cPG_TextEncoder_Simple;
VALUE rb_cPG_TextEncoder_Composite;
static ID s_id_call;


int
pg_type_enc_to_str(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		memcpy( out, RSTRING_PTR(*intermediate), RSTRING_LEN(*intermediate));
	} else {
		*intermediate = rb_obj_as_string(value);
	}

	return RSTRING_LEN(*intermediate);
}

static int
pg_text_enc_integer(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		if(TYPE(*intermediate) == T_STRING){
			return pg_type_enc_to_str(conv, value, out, intermediate);
		}else{
			return sprintf(out, "%lld", NUM2LL(*intermediate));
		}
	}else{
		*intermediate = rb_Integer(value);
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
						return pg_type_enc_to_str(conv, *intermediate, NULL, intermediate);
					}
				}
			}
			return sll < 0 ? len+1 : len;
		}else{
			return pg_type_enc_to_str(conv, *intermediate, NULL, intermediate);
		}
	}
}

static int
pg_text_enc_float(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		return sprintf( out, "%.16E", NUM2DBL(value));
	}else{
		*intermediate = value;
		return 23;
	}
}

static int
write_array(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate, t_pg_type_enc_func enc_func, int quote, int *interm_pos)
{
	int i;
	if(out){
		char *current_out = out;

		if( *interm_pos < 0 ) *interm_pos = 0;

		*current_out++ = '{';
		for( i=0; i<RARRAY_LEN(value); i++){
			VALUE subint;
			VALUE entry = rb_ary_entry(value, i);
			if( i > 0 ) *current_out++ = ',';
			switch(TYPE(entry)){
				case T_ARRAY:
					current_out += write_array(conv, entry, current_out, intermediate, enc_func, quote, interm_pos);
				break;
				case T_NIL:
					*current_out++ = 'N';
					*current_out++ = 'U';
					*current_out++ = 'L';
					*current_out++ = 'L';
					break;
				default:
					subint = rb_ary_entry(*intermediate, *interm_pos);
					*interm_pos = *interm_pos + 1;
					if(quote){
						char *ptr1;
						char *ptr2;
						int strlen;
						int backslashs;
						*current_out++ = '"';

						/* Place the unescaped string at current output position. */
						strlen = enc_func(conv, entry, current_out, &subint);
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
						current_out += enc_func(conv, entry, current_out, &subint);
					}
			}
		}
		*current_out++ = '}';
		return current_out - out;

	} else {
		int sumlen = 0;
		int nr_elems;
		Check_Type(value, T_ARRAY);
		nr_elems = RARRAY_LEN(value);

		if( *interm_pos < 0 ){
			*intermediate = rb_ary_new();
			*interm_pos = 0;
		}

		for( i=0; i<nr_elems; i++){
			VALUE subint;
			VALUE entry = rb_ary_entry(value, i);
			switch(TYPE(entry)){
				case T_ARRAY:
					/* size of array content */
					sumlen += write_array(conv, entry, NULL, intermediate, enc_func, quote, interm_pos);
				break;
				case T_NIL:
					/* size of "NULL" */
					sumlen += 4;
					break;
				default:
					if(quote){
						/* size of string assuming the worst case, that every character must be escaped
						 * plus two bytes for quotation.
						 */
						sumlen += 2 * enc_func(conv, entry, NULL, &subint) + 2;
					}else{
						/* size of the unquoted string */
						sumlen += enc_func(conv, entry, NULL, &subint);
					}
					rb_ary_push(*intermediate, subint);
			}
		}

		/* size of "{" plus content plus n-1 times "," plus "}" */
		return 1 + sumlen + (nr_elems>0 ? nr_elems-1 : 0) + 1;
	}
}

static int
pg_text_enc_in_ruby(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate)
{
	if( out ){
		memcpy(out, RSTRING_PTR(*intermediate), RSTRING_LEN(*intermediate));
		return RSTRING_LEN(*intermediate);
	}else{
		*intermediate = rb_funcall( conv->enc_obj, s_id_call, 1, value );
		StringValue( *intermediate );
		return RSTRING_LEN(*intermediate);
	}
}

static t_pg_type_enc_func
composite_elem_func(t_pg_composite_type *comp_conv)
{
	if( comp_conv->elem ){
		if( comp_conv->elem->enc_func ){
			return comp_conv->elem->enc_func;
		}else{
			return pg_text_enc_in_ruby;
		}
	}else{
		/* no element encoder defined -> use std to_str conversion */
		return pg_type_enc_to_str;
	}
}

static int
pg_text_enc_array(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate)
{
	t_pg_composite_type *comp_conv = (t_pg_composite_type *)conv;
	t_pg_type_enc_func enc_func = composite_elem_func(comp_conv);
	int pos = -1;

	return write_array(comp_conv->elem, value, out, intermediate, enc_func, comp_conv->needs_quotation, &pos);
}

static int
quote_string(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate, char quote_char)
{
	t_pg_composite_type *comp_conv = (t_pg_composite_type *)conv;
	t_pg_type_enc_func enc_func = composite_elem_func(comp_conv);

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
pg_text_enc_array_identifier(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate)
{
	int sumlen = 0;
	int i;
	if( out ){
		int nr_elems = RARRAY_LEN(value);
		for( i=0; i<nr_elems; i++){
			VALUE subint = rb_ary_entry(*intermediate, i);
			VALUE entry = rb_ary_entry(value, i);

			sumlen += quote_string(conv, entry, out, &subint, '"');
			out += sumlen;
			if( i < nr_elems-1 ){
				*out++ = '.';
			}
		}
		/* add one byte per "." seperator */
		sumlen += RARRAY_LEN(value) - 1;
		return sumlen;
	} else {
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
pg_text_enc_identifier(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate)
{
	if( TYPE(value) == T_ARRAY){
		return pg_text_enc_array_identifier(conv, value, out, intermediate);
	} else {
		return quote_string(conv, value, out, intermediate, '"');
	}
}

void
init_pg_text_encoder()
{
	s_id_call = rb_intern("call");

	rb_mPG_TextEncoder = rb_define_module_under( rb_mPG, "TextEncoder" );

	rb_cPG_TextEncoder_Simple = rb_define_class_under( rb_mPG_TextEncoder, "Simple", rb_cPG_Coder );
	pg_define_coder( "BOOLEAN", pg_type_enc_to_str, rb_cPG_TextEncoder_Simple, rb_mPG_TextEncoder );
	pg_define_coder( "INTEGER", pg_text_enc_integer, rb_cPG_TextEncoder_Simple, rb_mPG_TextEncoder );
	pg_define_coder( "FLOAT", pg_text_enc_float, rb_cPG_TextEncoder_Simple, rb_mPG_TextEncoder );
	pg_define_coder( "STRING", pg_type_enc_to_str, rb_cPG_TextEncoder_Simple, rb_mPG_TextEncoder );
	pg_define_coder( "BYTEA", pg_type_enc_to_str, rb_cPG_TextEncoder_Simple, rb_mPG_TextEncoder );

	rb_cPG_TextEncoder_Composite = rb_define_class_under( rb_mPG_TextEncoder, "Composite", rb_cPG_Coder );
	pg_define_coder( "ARRAY", pg_text_enc_array, rb_cPG_TextEncoder_Composite, rb_mPG_TextEncoder );
	pg_define_coder( "IDENTIFIER", pg_text_enc_identifier, rb_cPG_TextEncoder_Composite, rb_mPG_TextEncoder );
}
