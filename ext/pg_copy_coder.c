/*
 * pg_copycoder.c - PG::Coder class extension
 *
 */

#include "pg.h"

VALUE rb_cPG_CopyCoder;
VALUE rb_cPG_CopyEncoder;
VALUE rb_cPG_CopyDecoder;

typedef struct {
	t_pg_coder comp;
	VALUE typemap;
	char delimiter;
} t_pg_copycoder;


/*
 * Document-class: PG::CopyCoder
 *
 * This is the base class for all type cast classes for COPY data,
 *
 */

static VALUE
pg_copycoder_encoder_allocate( VALUE klass )
{
	t_pg_copycoder *this;
	VALUE self = Data_Make_Struct( klass, t_pg_copycoder, NULL, -1, this );
	pg_coder_init_encoder( self );
	this->typemap = Qnil;
	this->delimiter = '\t';
	return self;
}

static VALUE
pg_copycoder_decoder_allocate( VALUE klass )
{
	t_pg_copycoder *this;
	VALUE self = Data_Make_Struct( klass, t_pg_copycoder, NULL, -1, this );
	pg_coder_init_decoder( self );
	this->typemap = Qnil;
	this->delimiter = '\t';
	return self;
}

static VALUE
pg_copycoder_delimiter_set(VALUE self, VALUE delimiter)
{
	t_pg_copycoder *this = DATA_PTR(self);
	StringValue(delimiter);
	if(RSTRING_LEN(delimiter) != 1)
		rb_raise( rb_eArgError, "delimiter size must be one byte");
	this->delimiter = *RSTRING_PTR(delimiter);
	return delimiter;
}

static VALUE
pg_copycoder_delimiter_get(VALUE self)
{
	t_pg_copycoder *this = DATA_PTR(self);
	return rb_str_new(&this->delimiter, 1);
}

/*
 *
 */
static VALUE
pg_copycoder_type_map_set(VALUE self, VALUE type_map)
{
	t_pg_copycoder *this = DATA_PTR( self );

	if ( !NIL_P(type_map) && !rb_obj_is_kind_of(type_map, rb_cTypeMap) ){
		rb_raise( rb_eTypeError, "wrong elements type %s (expected some kind of PG::TypeMap)",
				rb_obj_classname( type_map ) );
	}
	this->typemap = type_map;

	return type_map;
}

/*
 *
 */
static VALUE
pg_copycoder_type_map_get(VALUE self)
{
	t_pg_copycoder *this = DATA_PTR( self );

	return this->typemap;
}


static t_pg_coder_enc_func
copy_elem_func(t_pg_coder *elem_coder)
{
	if( elem_coder ){
		if( elem_coder->enc_func ){
			return elem_coder->enc_func;
		}else{
			return pg_text_enc_in_ruby;
		}
	}else{
		/* no element encoder defined -> use std to_str conversion */
		return pg_coder_enc_to_str;
	}
}


static int
pg_text_enc_copy_row(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	t_pg_copycoder *this = (t_pg_copycoder *)conv;
	t_pg_coder_enc_func enc_func;
	VALUE typemap;
	VALUE elem_coder;
	static t_pg_coder *p_elem_coder;
	int i;
	t_typemap *p_typemap;

	if( NIL_P(this->typemap) ){
		rb_raise( rb_eTypeError, "no type_map defined" );
	} else {
		p_typemap = DATA_PTR( this->typemap );
		typemap = p_typemap->fit_to_query( this->typemap, value );
		p_typemap = DATA_PTR( typemap );
	}

	if(out){
		char *current_out = out;
		int interm_pos = 0;

		for( i=0; i<RARRAY_LEN(value); i++){
			char *ptr1;
			char *ptr2;
			int strlen;
			int backslashs;
			VALUE subint;
			VALUE entry;

			entry = rb_ary_entry(value, i);

			if( i > 0 ) *current_out++ = this->delimiter;
			switch(TYPE(entry)){
				case T_NIL:
					*current_out++ = '\\';
					*current_out++ = 'N';
					break;
				default:
					elem_coder = rb_ary_entry(*intermediate, interm_pos++);
					p_elem_coder = NIL_P(elem_coder) ? NULL : DATA_PTR(elem_coder);
					subint = rb_ary_entry(*intermediate, interm_pos++);

					enc_func = copy_elem_func(p_elem_coder);

					/* Place the unescaped string at current output position. */
					strlen = enc_func(p_elem_coder, entry, current_out, &subint);

					ptr1 = current_out;
					ptr2 = current_out + strlen;

					/* count required backlashs */
					for(backslashs = 0; ptr1 != ptr2; ptr1++) {
						/* Escape backslash itself, newline, carriage return, and the current delimiter character. */
						if(*ptr1 == '\\' || *ptr1 == '\n' || *ptr1 == '\r' || *ptr1 == this->delimiter){
							backslashs++;
						}
					}

					ptr1 = current_out + strlen;
					ptr2 = current_out + strlen + backslashs;
					current_out = ptr2;

					/* Then store the escaped string on the final position, walking
					 * right to left, until all backslashs are placed. */
					while( ptr1 != ptr2 ) {
						*--ptr2 = *--ptr1;
						if(*ptr1 == '\\' || *ptr1 == '\n' || *ptr1 == '\r' || *ptr1 == this->delimiter){
							*--ptr2 = '\\';
						}
					}
			}
		}
		*current_out++ = '\n';
		return current_out - out;

	} else {
		int sumlen = 0;
		int nr_elems;
		Check_Type(value, T_ARRAY);
		nr_elems = RARRAY_LEN(value);

		*intermediate = rb_ary_new2(nr_elems * 2);

		for( i=0; i<nr_elems; i++){
			VALUE subint;
			VALUE entry = rb_ary_entry(value, i);
			switch(TYPE(entry)){
				case T_NIL:
					/* size of "\N" */
					sumlen += 2;
					subint = Qnil;
					break;
				default:

					p_elem_coder = p_typemap->typecast_query_param(typemap, entry, i);
					enc_func = copy_elem_func(p_elem_coder);

					/* size of string assuming the worst case, that every character must be escaped. */
					sumlen += 2 * enc_func(p_elem_coder, entry, NULL, &subint);

					rb_ary_push(*intermediate, p_elem_coder ? p_elem_coder->coder_obj : Qnil);
					rb_ary_push(*intermediate, subint);
			}
		}

		/* size of content plus n-1 times "\t" plus "\n" */
		return sumlen + (nr_elems>0 ? nr_elems-1 : 0) + 1;
	}
}


void
init_pg_copycoder()
{
	rb_cPG_CopyCoder = rb_define_class_under( rb_mPG, "CopyCoder", rb_cPG_Coder );
	rb_define_method( rb_cPG_CopyCoder, "type_map=", pg_copycoder_type_map_set, 1 );
	rb_define_method( rb_cPG_CopyCoder, "type_map", pg_copycoder_type_map_get, 0 );
	rb_define_method( rb_cPG_CopyCoder, "delimiter=", pg_copycoder_delimiter_set, 1 );
	rb_define_method( rb_cPG_CopyCoder, "delimiter", pg_copycoder_delimiter_get, 0 );

	rb_cPG_CopyEncoder = rb_define_class_under( rb_mPG, "CopyEncoder", rb_cPG_CopyCoder );
	rb_define_alloc_func( rb_cPG_CopyEncoder, pg_copycoder_encoder_allocate );
	rb_cPG_CopyDecoder = rb_define_class_under( rb_mPG, "CopyDecoder", rb_cPG_CopyCoder );
	rb_define_alloc_func( rb_cPG_CopyDecoder, pg_copycoder_decoder_allocate );

	pg_define_coder( "CopyRow", pg_text_enc_copy_row, rb_cPG_CopyEncoder, rb_mPG_TextEncoder );
}
