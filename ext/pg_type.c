/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"
#include "util.h"
#include <inttypes.h>

extern VALUE rb_cPG_Type_TextEncoder_Simple;
extern VALUE rb_cPG_Type_TextEncoder_Composite;
extern VALUE rb_cPG_Type_BinaryEncoder_Simple;
extern VALUE rb_cPG_Type_BinaryEncoder_Composite;
extern VALUE rb_cPG_Type_TextDecoder_Simple;
extern VALUE rb_cPG_Type_TextDecoder_Composite;
extern VALUE rb_cPG_Type_BinaryDecoder_Simple;
extern VALUE rb_cPG_Type_BinaryDecoder_Composite;

VALUE rb_mPG_Type;
VALUE rb_cPG_Type_SimpleType;
VALUE rb_cPG_Type_CompositeType;
static ID s_id_call;


static VALUE
pg_simple_type_allocate( VALUE klass )
{
	t_pg_type *sval;
	VALUE self = Data_Make_Struct( klass, t_pg_type, NULL, -1, sval );
	sval->enc_func = NULL;
	sval->dec_func = NULL;
	sval->enc_obj = Qnil;
	sval->dec_obj = Qnil;
	sval->oid = 0;
	sval->format = 0;
	rb_iv_set( self, "@encoder", Qnil );
	rb_iv_set( self, "@decoder", Qnil );
	rb_iv_set( self, "@name", Qnil );
	return self;
}

static VALUE
pg_comp_type_allocate( VALUE klass )
{
	t_pg_composite_type *sval;
	VALUE self = Data_Make_Struct( klass, t_pg_composite_type, NULL, -1, sval );
	sval->comp.enc_func = NULL;
	sval->comp.dec_func = NULL;
	sval->comp.enc_obj = Qnil;
	sval->comp.dec_obj = Qnil;
	sval->comp.oid = 0;
	sval->comp.format = 0;
	sval->elem = NULL;
	sval->needs_quotation = 1;
	rb_iv_set( self, "@encoder", Qnil );
	rb_iv_set( self, "@decoder", Qnil );
	rb_iv_set( self, "@name", Qnil );
	rb_iv_set( self, "@elements_type", Qnil );
	return self;
}


t_pg_type *
pg_type_get_and_check( VALUE self )
{
	Check_Type(self, T_DATA);

	if ( !rb_obj_is_kind_of(self, rb_cPG_Type_SimpleType) ) {
		rb_raise( rb_eTypeError, "wrong argument type %s (expected PG::Type)",
				rb_obj_classname( self ) );
	}

	return DATA_PTR( self );
}

static VALUE
pg_type_encode(VALUE self, VALUE value)
{
	VALUE res = rb_str_new_cstr("");
	VALUE intermediate;
	int len;
	t_pg_type *type_data = DATA_PTR(self);

	if( type_data->enc_func ){
		len = type_data->enc_func( type_data, value, NULL, &intermediate );
		res = rb_str_resize( res, len );
		len = type_data->enc_func( type_data, value, RSTRING_PTR(res), &intermediate);
		rb_str_set_len( res, len );
	} else if( !NIL_P(type_data->enc_obj) ){
		res = rb_funcall( type_data->enc_obj, s_id_call, 1, value );
	} else {
		rb_raise( rb_eArgError, "no encoder defined for type %s",
				rb_obj_classname( self ) );
	}

	return res;
}

static VALUE
pg_type_decode(int argc, VALUE *argv, VALUE self)
{
	char *val;
	VALUE tuple = -1;
	VALUE field = -1;
	VALUE ret;
	t_pg_type *type_data = DATA_PTR(self);

	if(argc < 1 || argc > 3){
		rb_raise(rb_eArgError, "wrong number of arguments (%i for 1..3)", argc);
	}else if(argc >= 3){
		tuple = NUM2INT(argv[1]);
		field = NUM2INT(argv[2]);
	}

	if( type_data->dec_func ){
		val = StringValuePtr(argv[0]);
		ret = type_data->dec_func(type_data, val, RSTRING_LEN(argv[0]), tuple, field, ENCODING_GET(argv[0]));
	} else if( !NIL_P(type_data->dec_obj) ){
		ret = rb_funcall( type_data->dec_obj, s_id_call, 3, argv[0], INT2NUM(tuple), INT2NUM(field) );
	} else {
		rb_raise( rb_eArgError, "no decoder defined for type %s",
				rb_obj_classname( self ) );
	}
	return ret;
}

static VALUE
pg_type_oid_set(VALUE self, VALUE oid)
{
	t_pg_type *type_data = DATA_PTR(self);
	type_data->oid = NUM2INT(oid);
	return oid;
}

static VALUE
pg_type_oid_get(VALUE self)
{
	t_pg_type *type_data = DATA_PTR(self);
	return INT2NUM(type_data->oid);
}

static VALUE
pg_type_format_set(VALUE self, VALUE format)
{
	t_pg_type *type_data = DATA_PTR(self);
	type_data->format = NUM2INT(format);
	return format;
}

static VALUE
pg_type_format_get(VALUE self)
{
	t_pg_type *type_data = DATA_PTR(self);
	return INT2NUM(type_data->format);
}

static VALUE
pg_type_needs_quotation_set(VALUE self, VALUE needs_quotation)
{
	t_pg_composite_type *type_data = DATA_PTR(self);
	type_data->needs_quotation = RTEST(needs_quotation);
	return needs_quotation;
}

static VALUE
pg_type_needs_quotation_get(VALUE self)
{
	t_pg_composite_type *type_data = DATA_PTR(self);
	return type_data->needs_quotation ? Qtrue : Qnil;
}

typedef enum {
	CODERTYPE_ENCODER = 0,
	CODERTYPE_DECODER = 1,
	CODERTYPE_SIMPLE = 0,
	CODERTYPE_COMPOSITE = 2
} e_coder_type;

static const struct { VALUE *klass0; VALUE *klass1; } coderclasses[4] = {
	{ &rb_cPG_Type_TextEncoder_Simple, &rb_cPG_Type_BinaryEncoder_Simple },
	{ &rb_cPG_Type_TextDecoder_Simple, &rb_cPG_Type_BinaryDecoder_Simple },
	{ &rb_cPG_Type_TextEncoder_Composite, &rb_cPG_Type_BinaryEncoder_Composite },
	{ &rb_cPG_Type_TextDecoder_Composite, &rb_cPG_Type_BinaryDecoder_Composite }
};

static VALUE check_and_set_coder(VALUE self, e_coder_type codertype, VALUE coder){
	t_pg_type *p_type = DATA_PTR( self );
	VALUE klass = rb_obj_class(coder);
	VALUE klass0 = *coderclasses[codertype].klass0;
	VALUE klass1 = *coderclasses[codertype].klass1;

	if( klass == klass0 || klass == klass1 ){
		if(codertype & CODERTYPE_DECODER){
			p_type->dec_func = DATA_PTR( coder );
		} else {
			p_type->enc_func = DATA_PTR( coder );
		}
	} else if( NIL_P(coder) || rb_respond_to(coder, s_id_call) ){
		if(codertype & CODERTYPE_DECODER){
			p_type->dec_func = NULL;
		} else {
			p_type->enc_func = NULL;
		}
	} else {
		rb_raise( rb_eTypeError, "wrong encoder type %s (expected to respond to :call or type %s or %s)",
				rb_obj_classname( self ), rb_class2name( klass0 ), rb_class2name( klass1 ) );
	}

	if(codertype & CODERTYPE_DECODER){
		p_type->dec_obj = coder;
		rb_iv_set( self, "@decoder", coder );
	}else{
		p_type->enc_obj = coder;
		rb_iv_set( self, "@encoder", coder );
	}
	return coder;
}

static VALUE
pg_type_encoder_set(VALUE self, VALUE encoder)
{
	return check_and_set_coder(self, CODERTYPE_ENCODER | CODERTYPE_SIMPLE, encoder);
}

static VALUE
pg_type_decoder_set(VALUE self, VALUE decoder)
{
	return check_and_set_coder(self, CODERTYPE_DECODER | CODERTYPE_SIMPLE, decoder);
}

static VALUE
pg_type_composite_encoder_set(VALUE self, VALUE encoder)
{
	return check_and_set_coder(self, CODERTYPE_ENCODER | CODERTYPE_COMPOSITE, encoder);
}

static VALUE
pg_type_composite_decoder_set(VALUE self, VALUE decoder)
{
	return check_and_set_coder(self, CODERTYPE_DECODER | CODERTYPE_COMPOSITE, decoder);
}

static VALUE
pg_type_elements_type_set(VALUE self, VALUE elem_type)
{
	t_pg_composite_type *p_type = DATA_PTR( self );

	if ( !rb_obj_is_kind_of(elem_type, rb_cPG_Type_SimpleType) ){
		rb_raise( rb_eTypeError, "wrong elements type %s (expected some kind of PG::Type::SimpleType)",
				rb_obj_classname( self ) );
	}

	p_type->elem = DATA_PTR( elem_type );
	rb_iv_set( self, "@elements_type", elem_type );
	return elem_type;
}

void
init_pg_type()
{
	s_id_call = rb_intern("call");

	rb_mPG_Type = rb_define_module_under( rb_mPG, "Type" );

	rb_cPG_Type_SimpleType = rb_define_class_under( rb_mPG_Type, "SimpleType", rb_cObject );
	rb_define_alloc_func( rb_cPG_Type_SimpleType, pg_simple_type_allocate );
	rb_define_method( rb_cPG_Type_SimpleType, "encoder=", pg_type_encoder_set, 1 );
	rb_define_attr(   rb_cPG_Type_SimpleType, "encoder", 1, 0 );
	rb_define_method( rb_cPG_Type_SimpleType, "decoder=", pg_type_decoder_set, 1 );
	rb_define_attr(   rb_cPG_Type_SimpleType, "decoder", 1, 0 );
	rb_define_method( rb_cPG_Type_SimpleType, "oid=", pg_type_oid_set, 1 );
	rb_define_method( rb_cPG_Type_SimpleType, "oid", pg_type_oid_get, 0 );
	rb_define_method( rb_cPG_Type_SimpleType, "format=", pg_type_format_set, 1 );
	rb_define_method( rb_cPG_Type_SimpleType, "format", pg_type_format_get, 0 );
	rb_define_attr(   rb_cPG_Type_SimpleType, "name", 1, 1 );
	rb_define_method( rb_cPG_Type_SimpleType, "encode", pg_type_encode, 1 );
	rb_define_method( rb_cPG_Type_SimpleType, "decode", pg_type_decode, -1 );

	rb_cPG_Type_CompositeType = rb_define_class_under( rb_mPG_Type, "CompositeType", rb_cPG_Type_SimpleType );
	rb_define_alloc_func( rb_cPG_Type_CompositeType, pg_comp_type_allocate );
	rb_define_method( rb_cPG_Type_CompositeType, "encoder=", pg_type_composite_encoder_set, 1 );
	rb_define_method( rb_cPG_Type_CompositeType, "decoder=", pg_type_composite_decoder_set, 1 );
	rb_define_method( rb_cPG_Type_CompositeType, "elements_type=", pg_type_elements_type_set, 1 );
	rb_define_attr( rb_cPG_Type_CompositeType, "elements_type", 1, 0 );
	rb_define_method( rb_cPG_Type_CompositeType, "needs_quotation=", pg_type_needs_quotation_set, 1 );
	rb_define_method( rb_cPG_Type_CompositeType, "needs_quotation?", pg_type_needs_quotation_get, 0 );
}
