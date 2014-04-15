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
		*intermediate = rb_to_int(value);
		if(TYPE(*intermediate) == T_FIXNUM){
			long long ll = NUM2LL(*intermediate);
			if( ll < 100000000 ){
				if( ll < 10000 ){
					if( ll < 100 ){
						return ll < 10 ? 1 : 2;
					}else{
						return ll < 1000 ? 3 : 4;
					}
				}else{
					if( ll < 1000000 ){
						return ll < 100000 ? 5 : 6;
					}else{
						return ll < 10000000 ? 7 : 8;
					}
				}
			}else{
				if( ll < 1000000000000 ){
					if( ll < 10000000000 ){
						return ll < 1000000000 ? 9 : 10;
					}else{
						return ll < 100000000000 ? 11 : 12;
					}
				}else{
					if( ll < 100000000000000 ){
						return ll < 10000000000000 ? 13 : 14;
					}else{
						return pg_type_enc_to_str(conv, *intermediate, NULL, intermediate);
					}
				}
			}
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
			char *buffer;
			int j;
			int strlen;
			int backslashs;
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
						/* Place the unescaped string at current output position. */
						strlen = enc_func(conv, entry, current_out, &subint);
						buffer = current_out;
						backslashs = 0;

						/* count required backlashs */
						for(j = 0; j < strlen; j++) {
							if(buffer[j] == '"' || buffer[j] == '\\'){
								backslashs++;
							}
						}

						/* 2 bytes quotation plus size of escaped string */
						current_out += 1 + strlen + backslashs + 1;
						*--current_out = '"';

						/* Then store the quoted string on the desired position, walking
						 * right to left, to avoid overwriting. */
						for(j = strlen-1; j >= 0; j--) {
							*--current_out = buffer[j];
							if(buffer[j] == '"' || buffer[j] == '\\'){
								*--current_out = '\\';
							}
						}
						*--current_out = '"';
						if( buffer != current_out ) rb_bug("something went wrong while escaping string for array encoding");

						current_out += 1 + strlen + backslashs + 1;
					}else{
						current_out += enc_func(conv, entry, current_out, &subint);
					}
			}
		}
		*current_out++ = '}';
		return current_out - out;

	} else {
		int sumlen = 0;
		Check_Type(value, T_ARRAY);

		if( *interm_pos < 0 ){
			*intermediate = rb_ary_new();
			*interm_pos = 0;
		}

		for( i=0; i<RARRAY_LEN(value); i++){
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
		return 1 + sumlen + RARRAY_LEN(value) - 1 + 1;
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

static int
pg_text_enc_array(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate)
{
	t_pg_composite_type *comp_conv = (t_pg_composite_type *)conv;
	int pos = -1;
	if( comp_conv->elem ){
		if( comp_conv->elem->enc_func ){
			return write_array(comp_conv->elem, value, out, intermediate, comp_conv->elem->enc_func, comp_conv->needs_quotation, &pos);
		}else{
			return write_array(comp_conv->elem, value, out, intermediate, pg_text_enc_in_ruby, comp_conv->needs_quotation, &pos);
		}
	}else{
		/* no element encoder defined -> use std to_str conversion */
		return write_array(comp_conv->elem, value, out, intermediate, pg_type_enc_to_str, comp_conv->needs_quotation, &pos);
	}
}


void
init_pg_text_encoder()
{
	s_id_call = rb_intern("call");

	rb_mPG_TextEncoder = rb_define_module_under( rb_mPG, "TextEncoder" );

	rb_cPG_TextEncoder_Simple = rb_define_class_under( rb_mPG_TextEncoder, "Simple", rb_cPG_Coder );
	pg_define_coder( "Boolean", pg_type_enc_to_str, rb_cPG_TextEncoder_Simple, rb_mPG_TextEncoder );
	pg_define_coder( "Integer", pg_text_enc_integer, rb_cPG_TextEncoder_Simple, rb_mPG_TextEncoder );
	pg_define_coder( "Float", pg_text_enc_float, rb_cPG_TextEncoder_Simple, rb_mPG_TextEncoder );
	pg_define_coder( "String", pg_type_enc_to_str, rb_cPG_TextEncoder_Simple, rb_mPG_TextEncoder );
	pg_define_coder( "Bytea", pg_type_enc_to_str, rb_cPG_TextEncoder_Simple, rb_mPG_TextEncoder );

	rb_cPG_TextEncoder_Composite = rb_define_class_under( rb_mPG_TextEncoder, "Composite", rb_cPG_Coder );
	pg_define_coder( "Array", pg_text_enc_array, rb_cPG_TextEncoder_Composite, rb_mPG_TextEncoder );
}
