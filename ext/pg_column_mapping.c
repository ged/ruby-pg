/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"

VALUE rb_cColumnMap;
static VALUE rb_cColumnMapCConverter;
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


static VALUE
colmap_conv_text_boolean(VALUE self, PGresult *result, int tuple, int field)
{
	if (PQgetisnull(result, tuple, field) || PQgetlength(result, tuple, field) < 1) {
		return Qnil;
	}
	return *PQgetvalue(result, tuple, field) == 't' ? Qtrue : Qfalse;
}

static VALUE
colmap_conv_text_string(VALUE self, PGresult *result, int tuple, int field)
{
	VALUE val;
	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}
	val = rb_tainted_str_new( PQgetvalue(result, tuple, field ),
	                          PQgetlength(result, tuple, field) );
#ifdef M17N_SUPPORTED
	ASSOCIATE_INDEX( val, self );
#endif
	return val;
}

static VALUE
colmap_conv_text_integer(VALUE self, PGresult *result, int tuple, int field)
{
	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}
	return rb_cstr2inum(PQgetvalue(result, tuple, field), 10);
}

static VALUE
colmap_conv_binary_integer(VALUE self, PGresult *result, int tuple, int field)
{
	int len;
	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}
	len = PQgetlength(result, tuple, field);
	switch( len ){
		case 2:
			return INT2NUM((int16_t)be16toh(*(int16_t*)PQgetvalue(result, tuple, field)));
		case 4:
			return LONG2NUM((int32_t)be32toh(*(int32_t*)PQgetvalue(result, tuple, field)));
		case 8:
			return LL2NUM((int64_t)be64toh(*(int64_t*)PQgetvalue(result, tuple, field)));
		default:
			rb_raise( rb_eTypeError, "wrong data for BinaryInteger converter in tuple %d field %d length %d", tuple, field, len);
	}
}

static VALUE
colmap_conv_text_float(VALUE self, PGresult *result, int tuple, int field)
{
	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}
	return rb_float_new(strtod(PQgetvalue(result, tuple, field), NULL));
}

static VALUE
colmap_conv_binary_float(VALUE self, PGresult *result, int tuple, int field)
{
	int len;
	union {
		float f;
		int32_t i;
	} swap4;
	union {
		double f;
		int64_t i;
	} swap8;

	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}

	len = PQgetlength(result, tuple, field);
	switch( len ){
		case 4:
			swap4.f = *(float *)PQgetvalue(result, tuple, field);
			swap4.i = be32toh(swap4.i);
			return DBL2NUM(swap4.f);
		case 8:
			swap8.f = *(double *)PQgetvalue(result, tuple, field);
			swap8.i = be64toh(swap8.i);
			return DBL2NUM(swap8.f);
		default:
			rb_raise( rb_eTypeError, "wrong data for BinaryFloat converter in tuple %d field %d length %d", tuple, field, len);
	}
}

static VALUE
colmap_conv_text_bytea(VALUE self, PGresult *result, int tuple, int field)
{
	unsigned char *to;
	size_t to_len;
	VALUE ret;

	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}

	to = PQunescapeBytea( (unsigned char *)PQgetvalue(result, tuple, field ), &to_len);

	ret = rb_str_new((char*)to, to_len);
	PQfreemem(to);

	return ret;
}

static VALUE
colmap_conv_binary_bytea(VALUE self, PGresult *result, int tuple, int field)
{
	VALUE val;
	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}
	val = rb_tainted_str_new( PQgetvalue(result, tuple, field ),
	                          PQgetlength(result, tuple, field) );
#ifdef M17N_SUPPORTED
	rb_enc_associate( val, rb_ascii8bit_encoding() );
#endif
	return val;
}

static VALUE
colmap_conv_text_or_binary_string(VALUE self, PGresult *result, int tuple, int field)
{
	if ( 0 == PQfformat(result, field) ) {
		return colmap_conv_text_string(self, result, tuple, field);
	} else {
		return colmap_conv_binary_bytea(self, result, tuple, field);
	}
}


VALUE
colmap_result_value(VALUE self, PGresult *result, int tuple, int field, t_colmap *p_colmap)
{
	if( p_colmap ){
		struct column_converter *conv = &p_colmap->convs[field];
		VALUE val = conv->func(self, result, tuple, field);

		if( conv->proc != Qnil ){
			return rb_funcall( conv->proc, s_id_call, 4, self, INT2NUM(tuple), INT2NUM(field), val );
		}
		return val;
	} else {
		return colmap_conv_text_or_binary_string(self, result, tuple, field);
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
	this = xmalloc(sizeof(t_colmap) + sizeof(struct column_converter) * conv_ary_len);
	DATA_PTR(self) = this;

	for(i=0; i<conv_ary_len; i++)
	{
		VALUE obj = rb_ary_entry(conv_ary, i);
		t_column_converter_func func;
		VALUE proc;

		if( obj == Qnil ){
			func = colmap_conv_text_or_binary_string;
			proc = Qnil;
		} else if( TYPE(obj) == T_SYMBOL ){
			VALUE conv_obj = rb_const_get(rb_cColumnMap, rb_to_id(obj));
			if( CLASS_OF(conv_obj) != rb_cColumnMapCConverter ){
				rb_raise( rb_eTypeError, "wrong argument type %s (expected PG::ColumnMapping::CConverter)",
						rb_obj_classname( conv_obj ) );
			}
			func = DATA_PTR(conv_obj);
			proc = Qnil;
		} else if( CLASS_OF(obj) == rb_cColumnMapCConverter ){
			func = DATA_PTR(obj);
			proc = Qnil;
		} else if( rb_respond_to(obj, s_id_call) ){
			func = colmap_conv_text_or_binary_string;
			proc = obj;
		} else {
			rb_raise(rb_eArgError, "invalid argument %d", i+1);
		}

		this->convs[i].func = func;
		this->convs[i].proc = proc;
	}

	this->nfields = conv_ary_len;

	rb_iv_set( self, "@conversions", rb_obj_freeze(conv_ary) );

	return self;
}


static void
colmap_define_converter(const char *name, t_column_converter_func func)
{
	rb_define_const( rb_cColumnMap, name, Data_Wrap_Struct(rb_cColumnMapCConverter, NULL, NULL, func) );
}


void
init_pg_column_mapping()
{
	s_id_call = rb_intern("call");

	rb_cColumnMap = rb_define_class_under( rb_mPG, "ColumnMapping", rb_cObject );
	rb_cColumnMapCConverter = rb_define_class_under( rb_cColumnMap, "CConverter", rb_cObject );
	colmap_define_converter( "TextBoolean", colmap_conv_text_boolean );
	colmap_define_converter( "TextString", colmap_conv_text_string );
	colmap_define_converter( "TextInteger", colmap_conv_text_integer );
	colmap_define_converter( "TextFloat", colmap_conv_text_float );
	colmap_define_converter( "TextBytea", colmap_conv_text_bytea );
	colmap_define_converter( "BinaryBytea", colmap_conv_binary_bytea );
	colmap_define_converter( "BinaryInteger", colmap_conv_binary_integer );
	colmap_define_converter( "BinaryFloat", colmap_conv_binary_float );

	rb_define_alloc_func( rb_cColumnMap, colmap_s_allocate );
	rb_define_method( rb_cColumnMap, "initialize", colmap_init, 1 );
	rb_define_attr( rb_cColumnMap, "conversions", 1, 0 );
}
