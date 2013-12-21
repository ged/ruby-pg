/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"

static VALUE rb_cColumnMap;
static ID s_id_encode;
static ID s_id_decode;


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
	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}

	if( p_colmap ){
		struct pg_type_converter *conv = &p_colmap->convs[field];
		VALUE val;

		if( !conv->cconv.dec_func ){
			rb_raise( rb_eArgError, "no decoder defined for field %d", field );
		}
		val = conv->cconv.dec_func(self, result, tuple, field);

		if( conv->type != Qnil ){
			return rb_funcall( conv->type, s_id_decode, 4, self, INT2NUM(tuple), INT2NUM(field), val );
		}
		return val;
	} else {
		return pg_type_dec_text_or_binary_string(self, result, tuple, field);
	}
}


static VALUE
colmap_init(VALUE self, VALUE conv_ary)
{
	int i;
	t_colmap *this;
	int conv_ary_len;

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

		if( obj == Qnil ){
			tc.cconv.dec_func = pg_type_dec_text_or_binary_string;
			tc.type = Qnil;
		} else if( TYPE(obj) == T_SYMBOL ){
			VALUE conv_obj = rb_const_get(rb_mPG_Type_Text, rb_to_id(obj));
			if( CLASS_OF(conv_obj) != rb_cPG_Type_CConverter ){
				rb_raise( rb_eTypeError, "wrong argument type %s (expected PG::Type::CConverter)",
						rb_obj_classname( conv_obj ) );
			}
			type_data = DATA_PTR(conv_obj);
			tc.cconv = *type_data;
			tc.type = Qnil;
		} else if( CLASS_OF(obj) == rb_cPG_Type_CConverter ){
			type_data = DATA_PTR(obj);
			tc.cconv = *type_data;
			tc.type = Qnil;
		} else if( rb_respond_to(obj, s_id_encode) || rb_respond_to(obj, s_id_decode)){
			tc.cconv.dec_func = pg_type_dec_text_or_binary_string;
			tc.type = obj;
		} else {
			rb_raise(rb_eArgError, "invalid argument %d", i+1);
		}

		this->convs[i] = tc;
	}

	this->nfields = conv_ary_len;

	rb_iv_set( self, "@conversions", rb_obj_freeze(conv_ary) );

	return self;
}


void
init_pg_column_mapping()
{
	s_id_encode = rb_intern("encode");
	s_id_decode = rb_intern("decode");

	rb_cColumnMap = rb_define_class_under( rb_mPG, "ColumnMapping", rb_cObject );
	rb_define_alloc_func( rb_cColumnMap, colmap_s_allocate );
	rb_define_method( rb_cColumnMap, "initialize", colmap_init, 1 );
	rb_define_attr( rb_cColumnMap, "conversions", 1, 0 );
}
