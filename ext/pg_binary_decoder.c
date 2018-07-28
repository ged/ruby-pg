/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"
#include "util.h"
#ifdef HAVE_INTTYPES_H
#include <inttypes.h>
#endif

VALUE rb_mPG_BinaryDecoder;


/*
 * Document-class: PG::BinaryDecoder::Boolean < PG::SimpleDecoder
 *
 * This is a decoder class for conversion of PostgreSQL binary bool type
 * to Ruby true or false objects.
 *
 */
static VALUE
pg_bin_dec_boolean(t_pg_coder *conv, const char *val, int len, int tuple, int field, int enc_idx)
{
	if (len < 1) {
		rb_raise( rb_eTypeError, "wrong data for binary boolean converter in tuple %d field %d", tuple, field);
	}
	return *val == 0 ? Qfalse : Qtrue;
}

/*
 * Document-class: PG::BinaryDecoder::Integer < PG::SimpleDecoder
 *
 * This is a decoder class for conversion of PostgreSQL binary int2, int4 and int8 types
 * to Ruby Integer objects.
 *
 */
static VALUE
pg_bin_dec_integer(t_pg_coder *conv, const char *val, int len, int tuple, int field, int enc_idx)
{
	switch( len ){
		case 2:
			return INT2NUM(read_nbo16(val));
		case 4:
			return LONG2NUM(read_nbo32(val));
		case 8:
			return LL2NUM(read_nbo64(val));
		default:
			rb_raise( rb_eTypeError, "wrong data for binary integer converter in tuple %d field %d length %d", tuple, field, len);
	}
}

/*
 * Document-class: PG::BinaryDecoder::Float < PG::SimpleDecoder
 *
 * This is a decoder class for conversion of PostgreSQL binary float4 and float8 types
 * to Ruby Float objects.
 *
 */
static VALUE
pg_bin_dec_float(t_pg_coder *conv, const char *val, int len, int tuple, int field, int enc_idx)
{
	union {
		float f;
		int32_t i;
	} swap4;
	union {
		double f;
		int64_t i;
	} swap8;

	switch( len ){
		case 4:
			swap4.i = read_nbo32(val);
			return rb_float_new(swap4.f);
		case 8:
			swap8.i = read_nbo64(val);
			return rb_float_new(swap8.f);
		default:
			rb_raise( rb_eTypeError, "wrong data for BinaryFloat converter in tuple %d field %d length %d", tuple, field, len);
	}
}

/*
 * Document-class: PG::BinaryDecoder::Bytea < PG::SimpleDecoder
 *
 * This decoder class delivers the data received from the server as binary String object.
 * It is therefore suitable for conversion of PostgreSQL bytea data as well as any other
 * data in binary format.
 *
 */
VALUE
pg_bin_dec_bytea(t_pg_coder *conv, const char *val, int len, int tuple, int field, int enc_idx)
{
	VALUE ret;
	ret = rb_tainted_str_new( val, len );
	PG_ENCODING_SET_NOCHECK( ret, rb_ascii8bit_encindex() );
	return ret;
}

/*
 * Document-class: PG::BinaryDecoder::ToBase64 < PG::CompositeDecoder
 *
 * This is a decoder class for conversion of binary (bytea) to base64 data.
 *
 */
static VALUE
pg_bin_dec_to_base64(t_pg_coder *conv, const char *val, int len, int tuple, int field, int enc_idx)
{
	t_pg_composite_coder *this = (t_pg_composite_coder *)conv;
	t_pg_coder_dec_func dec_func = pg_coder_dec_func(this->elem, this->comp.format);
	int encoded_len = BASE64_ENCODED_SIZE(len);
	/* create a buffer of the encoded length */
	VALUE out_value = rb_tainted_str_new(NULL, encoded_len);

	base64_encode( RSTRING_PTR(out_value), val, len );

	/* Is it a pure String conversion? Then we can directly send out_value to the user. */
	if( this->comp.format == 0 && dec_func == pg_text_dec_string ){
		PG_ENCODING_SET_NOCHECK( out_value, enc_idx );
		return out_value;
	}
	if( this->comp.format == 1 && dec_func == pg_bin_dec_bytea ){
		PG_ENCODING_SET_NOCHECK( out_value, rb_ascii8bit_encindex() );
		return out_value;
	}
	out_value = dec_func(this->elem, RSTRING_PTR(out_value), encoded_len, tuple, field, enc_idx);

	return out_value;
}

#define PG_INT64_MIN	(-0x7FFFFFFFFFFFFFFFL - 1)
#define PG_INT64_MAX	0x7FFFFFFFFFFFFFFFL

static VALUE
dec_timestamp(const char *val, int len, int tuple, int field, int timezone)
{
	int64_t timestamp;
	struct timespec ts;

	if( len != sizeof(timestamp) ){
		rb_raise( rb_eTypeError, "wrong data for timestamp converter in tuple %d field %d length %d", tuple, field, len);
	}

	timestamp = read_nbo64(val);

	switch(timestamp){
		case PG_INT64_MAX:
			return rb_str_new2("infinity");
		case PG_INT64_MIN:
			return rb_str_new2("-infinity");
		default:
			/* PostgreSQL's timestamp is based on year 2000 and Ruby's time is based on 1970.
			 * Adjust the 30 years difference. */
			ts.tv_sec = (timestamp / 1000000) + 10957L * 24L * 3600L;
			ts.tv_nsec = (timestamp % 1000000) * 1000;

			switch(timezone){
				case 0:
					return rb_time_timespec_new(&ts, INT_MAX); /* create local time */
				case 1:
					return rb_time_timespec_new(&ts, INT_MAX-1); /* create UTC time */
			}
			return Qnil; /* not reached */
	}
}

/*
 * Document-class: PG::BinaryDecoder::TimestampUtcToLocal < PG::SimpleDecoder
 *
 * This is a decoder class for conversion of PostgreSQL binary timestamps
 * to Ruby Time objects.
 *
 */
static VALUE
pg_bin_dec_timestamp_utc_to_local(t_pg_coder *conv, const char *val, int len, int tuple, int field, int enc_idx)
{
	return dec_timestamp(val, len, tuple, field, 0);
}

/*
 * Document-class: PG::BinaryDecoder::TimestampUtc < PG::SimpleDecoder
 *
 * This is a decoder class for conversion of PostgreSQL binary timestamps
 * to Ruby Time objects.
 *
 */
static VALUE
pg_bin_dec_timestamp_utc(t_pg_coder *conv, const char *val, int len, int tuple, int field, int enc_idx)
{
	return dec_timestamp(val, len, tuple, field, 1);
}

/*
 * Document-class: PG::BinaryDecoder::TimestampLocal < PG::SimpleDecoder
 *
 * This is a decoder class for conversion of PostgreSQL binary timestamps
 * to Ruby Time objects.
 *
 */
static VALUE
pg_bin_dec_timestamp_local(t_pg_coder *conv, const char *val, int len, int tuple, int field, int enc_idx)
{
	VALUE t = dec_timestamp(val, len, tuple, field, 0);
	if( TYPE(t) == T_STRING ) return t;
	return rb_funcall(t, rb_intern("-"), 1, rb_funcall(t, rb_intern("utc_offset"), 0));
}

/*
 * Document-class: PG::BinaryDecoder::String < PG::SimpleDecoder
 *
 * This is a decoder class for conversion of PostgreSQL text output to
 * to Ruby String object. The output value will have the character encoding
 * set with PG::Connection#internal_encoding= .
 *
 */

void
init_pg_binary_decoder()
{
	/* This module encapsulates all decoder classes with binary input format */
	rb_mPG_BinaryDecoder = rb_define_module_under( rb_mPG, "BinaryDecoder" );

	/* Make RDoc aware of the decoder classes... */
	/* dummy = rb_define_class_under( rb_mPG_BinaryDecoder, "Boolean", rb_cPG_SimpleDecoder ); */
	pg_define_coder( "Boolean", pg_bin_dec_boolean, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );
	/* dummy = rb_define_class_under( rb_mPG_BinaryDecoder, "Integer", rb_cPG_SimpleDecoder ); */
	pg_define_coder( "Integer", pg_bin_dec_integer, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );
	/* dummy = rb_define_class_under( rb_mPG_BinaryDecoder, "Float", rb_cPG_SimpleDecoder ); */
	pg_define_coder( "Float", pg_bin_dec_float, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );
	/* dummy = rb_define_class_under( rb_mPG_BinaryDecoder, "String", rb_cPG_SimpleDecoder ); */
	pg_define_coder( "String", pg_text_dec_string, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );
	/* dummy = rb_define_class_under( rb_mPG_BinaryDecoder, "Bytea", rb_cPG_SimpleDecoder ); */
	pg_define_coder( "Bytea", pg_bin_dec_bytea, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );
	/* dummy = rb_define_class_under( rb_mPG_BinaryDecoder, "TimestampUtc", rb_cPG_SimpleDecoder ); */
	pg_define_coder( "TimestampUtc", pg_bin_dec_timestamp_utc, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );
	/* dummy = rb_define_class_under( rb_mPG_BinaryDecoder, "TimestampUtcToLocal", rb_cPG_SimpleDecoder ); */
	pg_define_coder( "TimestampUtcToLocal", pg_bin_dec_timestamp_utc_to_local, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );
	/* dummy = rb_define_class_under( rb_mPG_BinaryDecoder, "TimestampLocal", rb_cPG_SimpleDecoder ); */
	pg_define_coder( "TimestampLocal", pg_bin_dec_timestamp_local, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );

	/* dummy = rb_define_class_under( rb_mPG_BinaryDecoder, "ToBase64", rb_cPG_CompositeDecoder ); */
	pg_define_coder( "ToBase64", pg_bin_dec_to_base64, rb_cPG_CompositeDecoder, rb_mPG_BinaryDecoder );
}
