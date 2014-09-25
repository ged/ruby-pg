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


static int
pg_text_enc_copy_row(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	t_pg_copycoder *this = (t_pg_copycoder *)conv;
	t_pg_coder_enc_func enc_func;
	VALUE typemap;
	static t_pg_coder *p_elem_coder;
	int i;
	t_typemap *p_typemap;
	char *current_out;

	if( NIL_P(this->typemap) ){
		rb_raise( rb_eTypeError, "no type_map defined" );
	} else {
		p_typemap = DATA_PTR( this->typemap );
		typemap = p_typemap->fit_to_query( this->typemap, value );
		p_typemap = DATA_PTR( typemap );
	}

	*intermediate = rb_str_new(NULL, 0);
	current_out = RSTRING_PTR(*intermediate);

	for( i=0; i<RARRAY_LEN(value); i++){
		char *ptr1;
		char *ptr2;
		int strlen;
		int backslashs;
		VALUE subint;
		VALUE entry;

		entry = rb_ary_entry(value, i);

		if( i > 0 ){
			current_out = pg_ensure_str_capa( *intermediate, 1, current_out );
			*current_out++ = this->delimiter;
		}

		switch(TYPE(entry)){
			case T_NIL:
				current_out = pg_ensure_str_capa( *intermediate, 2, current_out );
				*current_out++ = '\\';
				*current_out++ = 'N';
				break;
			default:
				p_elem_coder = p_typemap->typecast_query_param(typemap, entry, i);
				enc_func = pg_coder_enc_func(p_elem_coder);

				/* 1st pass for retiving the required memory space */
				strlen = enc_func(p_elem_coder, entry, NULL, &subint);

				if( strlen == -1 ){
					/* we can directly use String value in subint */
					strlen = RSTRING_LEN(subint);

					/* size of string assuming the worst case, that every character must be escaped. */
					current_out = pg_ensure_str_capa( *intermediate, strlen * 2, current_out );

					/* Copy string from subint with backslash escaping */
					for(ptr1 = RSTRING_PTR(subint); ptr1 < RSTRING_PTR(subint) + strlen; ptr1++) {
						/* Escape backslash itself, newline, carriage return, and the current delimiter character. */
						if(*ptr1 == '\\' || *ptr1 == '\n' || *ptr1 == '\r' || *ptr1 == this->delimiter){
							*current_out++ = '\\';
						}
						*current_out++ = *ptr1;
					}
				} else {
					/* 2nd pass for writing the data to prepared buffer */
					/* size of string assuming the worst case, that every character must be escaped. */
					current_out = pg_ensure_str_capa( *intermediate, strlen * 2, current_out );

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
	}
	current_out = pg_ensure_str_capa( *intermediate, 1, current_out );
	*current_out++ = '\n';

	rb_str_set_len( *intermediate, current_out - RSTRING_PTR(*intermediate) );

	return -1;
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
