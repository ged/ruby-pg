/*
 * pg_type_map_by_oid.c - PG::TypeMapByOid class extension
 * $Id$
 *
 */

#include "pg.h"

static VALUE rb_cTypeMapByOid;
static ID s_id_decode;

typedef struct {
	t_typemap typemap;
	int max_rows_for_online_lookup;

	struct pg_tmbo_converter {
		VALUE oid_to_coder;

		struct pg_tmbo_oid_cache_entry {
			Oid oid;
			t_pg_coder *p_coder;
		} cache_row[0x100];
	} format[2];
} t_tmbo;

/*
 * We use the OID's minor 8 Bits as index to a 256 entry cache. This avoids full ruby hash lookups
 * for each value in most cases.
 */
#define CACHE_LOOKUP(this, form, oid) ( &this->format[(form)].cache_row[(oid) & 0xff] )

static t_pg_coder *
pg_tmbo_lookup_oid(t_tmbo *this, int format, Oid oid)
{
	t_pg_coder *conv;
	struct pg_tmbo_oid_cache_entry *p_ce;

	p_ce = CACHE_LOOKUP(this, format, oid);

	/* Has the entry the expected OID and is it a non empty entry? */
	if( p_ce->oid == oid && (oid || p_ce->p_coder) ) {
		conv = p_ce->p_coder;
	} else {
		VALUE obj = rb_hash_lookup( this->format[format].oid_to_coder, UINT2NUM( oid ));
		/* obj must be nil or some kind of PG::Coder, this is checked at insertion */
		conv = NIL_P(obj) ? NULL : DATA_PTR(obj);
		/* Write the retrieved coder to the cache */
		p_ce->oid = oid;
		p_ce->p_coder = conv;
	}
	return conv;
}

/* Build a TypeMapByColumn that fits to the given result */
static VALUE
pg_tmbo_build_type_map_for_result2( t_tmbo *this, PGresult *pgresult )
{
	t_tmbc *p_colmap;
	int i;
	VALUE colmap;
	int nfields = PQnfields( pgresult );

	p_colmap = xmalloc(sizeof(t_tmbc) + sizeof(struct pg_tmbc_converter) * nfields);
	/* Set nfields to 0 at first, so that GC mark function doesn't access uninitialized memory. */
	p_colmap->nfields = 0;
	p_colmap->typemap = pg_tmbc_default_typemap;

	colmap = pg_tmbc_allocate();
	DATA_PTR(colmap) = p_colmap;

	for(i=0; i<nfields; i++)
	{
		int format = PQfformat(pgresult, i);

		if( format < 0 || format > 1 )
			rb_raise(rb_eArgError, "result field %d has unsupported format code %d", i+1, format);

		p_colmap->convs[i].cconv = pg_tmbo_lookup_oid( this, format, PQftype(pgresult, i) );
	}

	p_colmap->nfields = nfields;

	return colmap;
}

static VALUE
pg_tmbo_result_value(VALUE result, int tuple, int field)
{
	char * val;
	int len;
	int format;
	t_pg_coder *p_coder;
	t_pg_coder_dec_func dec_func;
	t_pg_result *p_result = pgresult_get_this(result);
	t_tmbo *this = (t_tmbo*) p_result->p_typemap;

	if (PQgetisnull(p_result->pgresult, tuple, field)) {
		return Qnil;
	}

	val = PQgetvalue( p_result->pgresult, tuple, field );
	len = PQgetlength( p_result->pgresult, tuple, field );
	format = PQfformat( p_result->pgresult, field );

	if( format < 0 || format > 1 )
		rb_raise(rb_eArgError, "result field %d has unsupported format code %d", field+1, format);

	p_coder = pg_tmbo_lookup_oid( this, format, PQftype(p_result->pgresult, field) );
	dec_func = pg_coder_dec_func( p_coder, format );
	return dec_func( p_coder, val, len, tuple, field, ENCODING_GET(result) );
}

static VALUE
pg_tmbo_fit_to_result( VALUE self, VALUE result )
{
	t_tmbo *this = DATA_PTR( self );
	PGresult *pgresult = pgresult_get( result );

	if( PQntuples( pgresult ) <= this->max_rows_for_online_lookup ){
		/* Do a hash lookup for each result value in pg_tmbc_result_value() */
		return self;
	}else{
		/* Build a new TypeMapByColumn that fits to the given result and
		 * uses a fast array lookup.
		 */
		return pg_tmbo_build_type_map_for_result2( this, pgresult );
	}
}

static void
pg_tmbo_mark( t_tmbo *this )
{
	int i;

	for( i=0; i<2; i++){
		rb_gc_mark(this->format[i].oid_to_coder);
	}
}

static VALUE
pg_tmbo_s_allocate( VALUE klass )
{
	t_tmbo *this;
	VALUE self;
	int i;

	self = Data_Make_Struct( klass, t_tmbo, pg_tmbo_mark, -1, this );

	this->typemap.fit_to_result = pg_tmbo_fit_to_result;
	this->typemap.fit_to_query = pg_typemap_fit_to_query;
	this->typemap.fit_to_copy_get = pg_typemap_fit_to_copy_get;
	this->typemap.typecast_result_value = pg_tmbo_result_value;
	this->typemap.typecast_query_param = pg_typemap_typecast_query_param;
	this->typemap.typecast_copy_get = pg_typemap_typecast_copy_get;
	this->max_rows_for_online_lookup = 10;

	for( i=0; i<2; i++){
		this->format[i].oid_to_coder = rb_hash_new();
	}

	return self;
}

/*
 * call-seq:
 *    typemap.add_coder( coder )
 *
 * Assigns a new PG::Coder object to the type map. The decoder
 * is registered for type casts based on it's PG::Coder#oid and
 * PG::Coder#format attributes.
 *
 * Later changes of the oid or format code within the coder object
 * will have no effect to the type map.
 *
 */
static VALUE
pg_tmbo_add_coder( VALUE self, VALUE coder )
{
	VALUE hash;
	t_tmbo *this = DATA_PTR( self );
	t_pg_coder *p_coder;
	struct pg_tmbo_oid_cache_entry *p_ce;

	if( !rb_obj_is_kind_of(coder, rb_cPG_Coder) )
		rb_raise(rb_eArgError, "invalid type %s (should be some kind of PG::Coder)",
							rb_obj_classname( coder ));

	Data_Get_Struct(coder, t_pg_coder, p_coder);

	if( p_coder->format < 0 || p_coder->format > 1 )
		rb_raise(rb_eArgError, "invalid format code %d", p_coder->format);

	/* Update cache entry */
	p_ce = CACHE_LOOKUP(this, p_coder->format, p_coder->oid);
	p_ce->oid = p_coder->oid;
	p_ce->p_coder = p_coder;
	/* Write coder into the hash of the given format */
	hash = this->format[p_coder->format].oid_to_coder;
	rb_hash_aset( hash, UINT2NUM(p_coder->oid), coder);

	return self;
}

/*
 * call-seq:
 *    typemap.rm_coder( format, oid )
 *
 * Removes a PG::Coder object from the type map based on the given
 * oid and format codes.
 *
 * Returns the removed coder object.
 */
static VALUE
pg_tmbo_rm_coder( VALUE self, VALUE format, VALUE oid )
{
	VALUE hash;
	VALUE coder;
	t_tmbo *this = DATA_PTR( self );
	int i_format = NUM2INT(format);
	struct pg_tmbo_oid_cache_entry *p_ce;

	if( i_format < 0 || i_format > 1 )
		rb_raise(rb_eArgError, "invalid format code %d", i_format);

	/* Mark the cache entry as empty */
	p_ce = CACHE_LOOKUP(this, i_format, NUM2UINT(oid));
	p_ce->oid = 0;
	p_ce->p_coder = NULL;
	hash = this->format[i_format].oid_to_coder;
	coder = rb_hash_delete( hash, oid );

	return coder;
}

/*
 * call-seq:
 *    typemap.coders -> Array
 *
 * Array of all assigned PG::Coder objects.
 */
static VALUE
pg_tmbo_coders( VALUE self )
{
	t_tmbo *this = DATA_PTR( self );

	return rb_ary_concat(
			rb_funcall(this->format[0].oid_to_coder, rb_intern("values"), 0),
			rb_funcall(this->format[1].oid_to_coder, rb_intern("values"), 0));
}

/*
 * call-seq:
 *    typemap.max_rows_for_online_lookup = number
 *
 * Threshold for doing Hash lookups versus creation of a dedicated PG::TypeMapByColumn.
 * The type map will do Hash lookups for each result value, if the number of rows
 * is below or equal +number+.
 *
 */
static VALUE
pg_tmbo_max_rows_for_online_lookup_set( VALUE self, VALUE value )
{
	t_tmbo *this = DATA_PTR( self );
	this->max_rows_for_online_lookup = NUM2INT(value);
	return value;
}

/*
 * call-seq:
 *    typemap.max_rows_for_online_lookup -> Integer
 */
static VALUE
pg_tmbo_max_rows_for_online_lookup_get( VALUE self )
{
	t_tmbo *this = DATA_PTR( self );
	return INT2NUM(this->max_rows_for_online_lookup);
}

/*
 * call-seq:
 *    typemap.fit_to_result( result, online_lookup = nil )
 *
 * This is an extended version of PG::TypeMap#fit_to_result that
 * allows explicit selection of online lookup ( online_lookup=true )
 * or building of a new PG::TypeMapByColumn ( online_lookup=false ).
 *
 *
 */
static VALUE
pg_tmbo_fit_to_result_ext( int argc, VALUE *argv, VALUE self )
{
	t_tmbo *this = DATA_PTR( self );
	VALUE result;
	VALUE online_lookup;

	rb_scan_args(argc, argv, "11", &result, &online_lookup);

	if ( !rb_obj_is_kind_of(result, rb_cPGresult) ) {
		rb_raise( rb_eTypeError, "wrong argument type %s (expected kind of PG::Result)",
				rb_obj_classname( result ) );
	}

	if( NIL_P( online_lookup ) ){
		/* call super */
		return this->typemap.fit_to_result(self, result);
	} else if( RB_TYPE_P( online_lookup, T_TRUE ) ){
		return self;
	} else if( RB_TYPE_P( online_lookup, T_FALSE ) ){
		PGresult *pgresult = pgresult_get( result );

		return pg_tmbo_build_type_map_for_result2( this, pgresult );
	} else {
		rb_raise( rb_eArgError, "argument online_lookup %s should be true, false or nil instead",
				rb_obj_classname( result ) );
	}
}


void
init_pg_type_map_by_oid()
{
	s_id_decode = rb_intern("decode");

	/*
	 * Document-class: PG::TypeMapByOid < PG::TypeMap
	 *
	 * This type map casts values based on the type OID of the given column
	 * in the result set.
	 *
	 * This type map is only suitable to cast values from PG::Result objects.
	 * Therefore only decoders might be assigned by the #add_coder method.
	 */
	rb_cTypeMapByOid = rb_define_class_under( rb_mPG, "TypeMapByOid", rb_cTypeMap );
	rb_define_alloc_func( rb_cTypeMapByOid, pg_tmbo_s_allocate );
	rb_define_method( rb_cTypeMapByOid, "add_coder", pg_tmbo_add_coder, 1 );
	rb_define_method( rb_cTypeMapByOid, "rm_coder", pg_tmbo_rm_coder, 2 );
	rb_define_method( rb_cTypeMapByOid, "coders", pg_tmbo_coders, 0 );
	rb_define_method( rb_cTypeMapByOid, "max_rows_for_online_lookup=", pg_tmbo_max_rows_for_online_lookup_set, 1 );
	rb_define_method( rb_cTypeMapByOid, "max_rows_for_online_lookup", pg_tmbo_max_rows_for_online_lookup_get, 0 );
	rb_define_method( rb_cTypeMapByOid, "fit_to_result", pg_tmbo_fit_to_result_ext, -1 );
}
