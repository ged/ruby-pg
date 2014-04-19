/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"

VALUE rb_cColumnMap;
static ID s_id_call;


static VALUE
colmap_s_allocate( VALUE klass )
{
	VALUE self = Data_Wrap_Struct( klass, NULL, -1, NULL );
	return self;
}


t_colmap *
colmap_get_and_check( VALUE self, int nfields )
{
	t_colmap *p_colmap;
	Check_Type( self, T_DATA );

	if ( !rb_obj_is_kind_of(self, rb_cColumnMap) ) {
		rb_raise( rb_eTypeError, "wrong argument type %s (expected PG::ColumnMapping)",
				rb_obj_classname( self ) );
	}

	p_colmap = DATA_PTR( self );

	if ( p_colmap->nfields != nfields ) {
		rb_raise( rb_eArgError, "number of result fields (%d) does not match number of mapped columns (%d)",
				nfields, p_colmap->nfields );
	}

	return p_colmap;
}


VALUE
colmap_result_value(VALUE self, PGresult *result, int tuple, int field, t_colmap *p_colmap)
{
	VALUE ret;
	char * val;
	int len;
	t_pg_type *conv = NULL;

	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}

	val = PQgetvalue( result, tuple, field );
	len = PQgetlength( result, tuple, field );

	if( p_colmap ){
		conv = p_colmap->convs[field].cconv;

		if( conv && conv->dec_func ){
			return conv->dec_func(conv, val, len, tuple, field, p_colmap->encoding_index);
		}
	}

	if ( 0 == PQfformat(result, field) ) {
		ret = pg_text_dec_string(NULL, val, len, tuple, field, ENCODING_GET(self));
	} else {
		ret = pg_bin_dec_bytea(NULL, val, len, tuple, field, ENCODING_GET(self));
	}

	if( conv ){
		ret = rb_funcall( conv->dec_obj, s_id_call, 3, ret, INT2NUM(tuple), INT2NUM(field) );
	}

	return ret;
}


static VALUE
colmap_init(VALUE self, VALUE conv_ary)
{
	int i;
	t_colmap *this;
	int conv_ary_len;
	VALUE ary_types = rb_ary_new();

	Check_Type(self, T_DATA);
	Check_Type(conv_ary, T_ARRAY);
	conv_ary_len = RARRAY_LEN(conv_ary);
	this = xmalloc(sizeof(t_colmap) + sizeof(struct pg_colmap_converter) * conv_ary_len);
	DATA_PTR(self) = this;

	for(i=0; i<conv_ary_len; i++)
	{
		VALUE obj = rb_ary_entry(conv_ary, i);

		if( obj == Qnil ){
			/* no type cast */
			this->convs[i].cconv = NULL;
		} else if( rb_obj_is_kind_of(obj, rb_cPG_Type) ){
			Check_Type(obj, T_DATA);
			this->convs[i].cconv = DATA_PTR(obj);
		} else {
			rb_raise(rb_eArgError, "argument %d has invalid type %s (should be nil or some kind of PG::Type)",
							 i+1, rb_obj_classname( obj ));
		}

		rb_ary_push( ary_types, obj );
	}

	/* encoding_index is set, when the ColumnMapping is assigned to a PG::Result. */
	this->encoding_index = 0;
	this->nfields = conv_ary_len;
	rb_iv_set( self, "@types", rb_obj_freeze(ary_types) );

	return self;
}


void
init_pg_column_mapping()
{
	s_id_call = rb_intern("call");

	rb_cColumnMap = rb_define_class_under( rb_mPG, "ColumnMapping", rb_cObject );
	rb_define_alloc_func( rb_cColumnMap, colmap_s_allocate );
	rb_define_method( rb_cColumnMap, "initialize", colmap_init, 1 );
	rb_define_attr( rb_cColumnMap, "types", 1, 0 );
}
