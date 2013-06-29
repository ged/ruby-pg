/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"


VALUE rb_cColumnMap;
static ID s_id_text_boolean;
static ID s_id_text_string;
static ID s_id_text_integer;
static ID s_id_text_float;
static ID s_id_text_bytea;
static ID s_id_binary_bytea;
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
colmap_conv_text_float(VALUE self, PGresult *result, int tuple, int field)
{
	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}
	return rb_float_new(strtod(PQgetvalue(result, tuple, field), NULL));
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
colmap_init(int argc, VALUE *argv, VALUE self)
{
	int i;
	t_colmap *this;

	Check_Type(self, T_DATA);
	this = xmalloc(sizeof(t_colmap) + sizeof(struct column_converter) * argc);
	DATA_PTR(self) = this;

	for(i=0; i<argc; i++)
	{
		VALUE obj = argv[i];
		ID id;
		t_column_converter_func func;
		VALUE proc;

		switch( TYPE(obj) ){
		case T_NIL:
			func = colmap_conv_text_or_binary_string;
			proc = Qnil;
			break;
		case T_SYMBOL:
		case T_STRING:
			id = rb_to_id(obj);

			/* TODO: Use a static hash table based on st_table if the
			 * number of conversion functions grow. */
			if( id == s_id_text_boolean ){
				func = colmap_conv_text_boolean;
			} else if( id == s_id_text_string ){
				func = colmap_conv_text_string;
			} else if( id == s_id_text_integer ){
				func = colmap_conv_text_integer;
			} else if( id == s_id_text_float ){
				func = colmap_conv_text_float;
			} else if( id == s_id_text_bytea ){
				func = colmap_conv_text_bytea;
			} else if( id == s_id_binary_bytea ){
				func = colmap_conv_binary_bytea;
			} else {
				rb_raise(rb_eArgError, "invalid argument %d", i+1);
			}
			proc = Qnil;
			break;
		case T_DATA:
			if( rb_respond_to(obj, s_id_call) ){
				func = colmap_conv_text_or_binary_string;
				proc = obj;
			} else {
				rb_raise(rb_eArgError, "invalid argument %d", i+1);
			}
			break;
		default:
			rb_raise(rb_eArgError, "invalid argument %d", i+1);
		}
		this->convs[i].func = func;
		this->convs[i].proc = proc;
	}

	this->nfields = argc;

	rb_iv_set( self, "@conversions", rb_obj_freeze(rb_ary_new4(argc, argv)) );

	return self;
}


void
init_pg_column_mapping()
{
	s_id_text_boolean = rb_intern("text_boolean");
	s_id_text_string = rb_intern("text_string");
	s_id_text_integer = rb_intern("text_integer");
	s_id_text_float = rb_intern("text_float");
	s_id_text_bytea = rb_intern("text_bytea");
	s_id_binary_bytea = rb_intern("binary_bytea");
	s_id_call = rb_intern("call");

	rb_cColumnMap = rb_define_class_under( rb_mPG, "ColumnMapping", rb_cObject );

	rb_define_alloc_func( rb_cColumnMap, colmap_s_allocate );
	rb_define_method(rb_cColumnMap, "initialize", colmap_init, -1);
	rb_define_attr(rb_cColumnMap, "conversions", 1, 0);
}
