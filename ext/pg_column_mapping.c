/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"

VALUE rb_cColumnMap;
static ID s_id_encode;
static ID s_id_decode;
static ID s_id_oid;
static ID s_id_format;


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
	int enc_idx = 0;
	VALUE ret;
	char * val;
	int len;
	struct pg_type_converter *conv = NULL;

	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}

#ifdef M17N_SUPPORTED
	enc_idx = ENCODING_GET(self);
#endif

	val = PQgetvalue( result, tuple, field );
	len = PQgetlength( result, tuple, field );

	if( p_colmap ){
		conv = &p_colmap->convs[field];

		if( conv->cconv.dec_func ){
			return conv->cconv.dec_func(val, len, tuple, field, enc_idx);
		}
	}

	if ( 0 == PQfformat(result, field) ) {
		ret = pg_type_dec_text_string(val, len, tuple, field, enc_idx);
	} else {
		ret = pg_type_dec_binary_bytea(val, len, tuple, field, enc_idx);
	}

	if( conv && !NIL_P(conv->type) ){
		ret = rb_funcall( conv->type, s_id_decode, 3, ret, INT2NUM(tuple), INT2NUM(field) );
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
	this = xmalloc(sizeof(t_colmap) + sizeof(struct pg_type_converter) * conv_ary_len);
	DATA_PTR(self) = this;

	for(i=0; i<conv_ary_len; i++)
	{
		VALUE obj = rb_ary_entry(conv_ary, i);
		struct pg_type_converter tc;
		struct pg_type_cconverter *type_data;

		if( TYPE(obj) == T_SYMBOL ){
			obj = rb_const_get(rb_mPG_Type_Text, rb_to_id(obj));
		}

		if( obj == Qnil ){
			tc.cconv.dec_func = NULL;
			tc.cconv.enc_func = NULL;
			tc.cconv.oid = 0;
			tc.cconv.format = 0;
			tc.type = Qnil;
		} else if( rb_obj_is_kind_of(obj, rb_cPG_Type_CConverter) ){
			type_data = DATA_PTR(obj);
			tc.cconv = *type_data;
			tc.type = obj;
		} else if( rb_respond_to(obj, s_id_oid) && rb_respond_to(obj, s_id_format)){
			VALUE oid = rb_funcall(obj, s_id_oid, 0);
			VALUE format = rb_funcall(obj, s_id_format, 0);
			tc.cconv.dec_func = NULL;
			tc.cconv.enc_func = NULL;
			tc.cconv.oid = NUM2INT(oid);
			tc.cconv.format = NUM2INT(format);
			tc.type = obj;
		} else {
			rb_raise(rb_eArgError, "invalid type argument %d", i+1);
		}

		this->convs[i] = tc;
		rb_ary_push( ary_types, obj );
	}

	this->nfields = conv_ary_len;
	rb_iv_set( self, "@types", rb_obj_freeze(ary_types) );

	return self;
}


void
init_pg_column_mapping()
{
	s_id_encode = rb_intern("encode");
	s_id_decode = rb_intern("decode");
	s_id_oid = rb_intern("oid");
	s_id_format = rb_intern("format");

	rb_cColumnMap = rb_define_class_under( rb_mPG, "ColumnMapping", rb_cObject );
	rb_define_alloc_func( rb_cColumnMap, colmap_s_allocate );
	rb_define_method( rb_cColumnMap, "initialize", colmap_init, 1 );
	rb_define_attr( rb_cColumnMap, "types", 1, 0 );
}
