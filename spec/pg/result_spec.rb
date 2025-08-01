# -*- rspec -*-
# encoding: utf-8

require_relative '../helpers'

require 'pg'


describe PG::Result do

	it "provides res_status" do
		str = PG::Result.res_status(PG::PGRES_EMPTY_QUERY)
		expect( str ).to eq("PGRES_EMPTY_QUERY")
		expect( str.encoding ).to eq(Encoding::UTF_8)

		res = @conn.exec("SELECT 1")
		expect( res.res_status ).to eq("PGRES_TUPLES_OK")
		expect( res.res_status(PG::PGRES_FATAL_ERROR) ).to eq("PGRES_FATAL_ERROR")

		expect{ res.res_status(1,2) }.to raise_error(ArgumentError)
	end

	it "should deny changes when frozen" do
		res = @conn.exec("SELECT 1").freeze
		expect{ res.type_map = PG::TypeMapAllStrings.new }.to raise_error(FrozenError)
		expect{ res.field_name_type = :symbol  }.to raise_error(FrozenError)
		expect{ res.clear }.to raise_error(FrozenError)
	end

	it "should be shareable for Ractor", :ractor do
		res = @conn.exec("SELECT 1")
		Ractor.make_shareable(res)
	end

	it "should be usable with Ractor", :ractor do
		res = Ractor.new(@conninfo) do |conninfo|
			conn = PG.connect(conninfo)
			conn.exec("SELECT 123 as col")
		ensure
			conn&.finish
		end.value

		expect( res ).to be_kind_of( PG::Result )
		expect( res.fields ).to eq( ["col"] )
		expect( res.values ).to eq( [["123"]] )
	end

	describe :field_name_type do
		let!(:res) { @conn.exec('SELECT 1 AS a, 2 AS "B"') }

		it "uses string field names per default" do
			expect(res.field_name_type).to eq(:string)
		end

		it "can set string field names" do
			res.field_name_type = :string
			expect(res.field_name_type).to eq(:string)
		end

		it "can set symbol field names" do
			res.field_name_type = :symbol
			expect(res.field_name_type).to eq(:symbol)
		end

		it "can set static_symbol field names" do
			res.field_name_type = :static_symbol
			expect(res.field_name_type).to eq(:static_symbol)
		end

		it "can't set symbol field names after #fields" do
			res.fields
			expect{ res.field_name_type = :symbol }.to raise_error(ArgumentError, /already materialized/)
			expect(res.field_name_type).to eq(:string)
		end

		it "can't set invalid values" do
			expect{ res.field_name_type = :sym }.to raise_error(ArgumentError, /invalid argument :sym/)
			expect{ res.field_name_type = "symbol" }.to raise_error(ArgumentError, /invalid argument "symbol"/)
		end
	end

	it "acts as an array of hashes" do
		res = @conn.exec("SELECT 1 AS a, 2 AS b")
		expect( res[0]['a'] ).to eq( '1' )
		expect( res[0]['b'] ).to eq( '2' )
	end

	it "acts as an array of hashes with symbols" do
		res = @conn.exec("SELECT 1 AS a, 2 AS b")
		res.field_name_type = :symbol
		expect( res[0][:a] ).to eq( '1' )
		expect( res[0][:b] ).to eq( '2' )
	end

	it "acts as an array of hashes with static_symbols" do
		res = @conn.exec("SELECT 1 AS a, 2 AS b")
		res.field_name_type = :static_symbol
		expect( res[0][:a] ).to eq( '1' )
		expect( res[0][:b] ).to eq( '2' )
	end

	it "yields a row as an array" do
		res = @conn.exec("SELECT 1 AS a, 2 AS b")
		list = []
		res.each_row { |r| list << r }
		expect( list ).to eq [['1', '2']]
	end

	it "yields a row as an Enumerator" do
		res = @conn.exec("SELECT 1 AS a, 2 AS b")
		e = res.each_row
		expect( e ).to be_a_kind_of(Enumerator)
		expect( e.size ).to eq( 1 )
		expect( e.to_a ).to eq [['1', '2']]
	end

	it "yields a row as an Enumerator of hashes" do
		res = @conn.exec("SELECT 1 AS a, 2 AS b")
		e = res.each
		expect( e ).to be_a_kind_of(Enumerator)
		expect( e.size ).to eq( 1 )
		expect( e.to_a ).to eq [{'a'=>'1', 'b'=>'2'}]
	end

	it "yields a row as an Enumerator of hashes with symbols" do
		res = @conn.exec("SELECT 1 AS a, 2 AS b")
		res.field_name_type = :symbol
		expect( res.each.to_a ).to eq [{:a=>'1', :b=>'2'}]
	end

	[
		[:single, nil, [:set_single_row_mode]],
		[:chunked, :postgresql_17, [:set_chunked_rows_mode, 3]],
	].each do |mode_name, guard, row_mode|
		context "result streaming in #{mode_name} row mode", guard do
			let!(:textdec_int){ PG::TextDecoder::Integer.new name: 'INT4', oid: 23 }

			it "can iterate over all rows as Hash" do
				@conn.send_query( "SELECT generate_series(2,4) AS a; SELECT 1 AS b, generate_series(5,6) AS c" )
				@conn.send(*row_mode)
				expect(
					@conn.get_result.stream_each.to_a
				).to eq(
					[{'a'=>"2"}, {'a'=>"3"}, {'a'=>"4"}]
				)
				expect(
					@conn.get_result.enum_for(:stream_each).to_a
				).to eq(
					[{'b'=>"1", 'c'=>"5"}, {'b'=>"1", 'c'=>"6"}]
				)
				expect( @conn.get_result ).to be_nil
			end

			it "can iterate over all rows as Hash with symbols and typemap" do
				@conn.send_query( "SELECT generate_series(2,4) AS a" )
				@conn.send(*row_mode)
				res = @conn.get_result.field_names_as(:symbol)
				res.type_map = PG::TypeMapByColumn.new [textdec_int]
				expect(
					res.stream_each.to_a
				).to eq(
					[{:a=>2}, {:a=>3}, {:a=>4}]
				)
				expect( @conn.get_result ).to be_nil
			end

			it "keeps last result on error while iterating stream_each" do
				@conn.send_query( "SELECT generate_series(2,6) AS a" )
				@conn.send(*row_mode)
				res = @conn.get_result
				expect do
					res.stream_each_row do
						raise ZeroDivisionError
					end
				end.to raise_error(ZeroDivisionError)
				expect( res.values ).to eq(mode_name==:single ? [["2"]] : [["2"], ["3"], ["4"]])
			end

			it "can iterate over all rows as Array" do
				@conn.send_query( "SELECT generate_series(2,4) AS a; SELECT 1 AS b, generate_series(5,6) AS c" )
				@conn.send(*row_mode)
				expect(
					@conn.get_result.enum_for(:stream_each_row).to_a
				).to eq(
					[["2"], ["3"], ["4"]]
				)
				expect(
					@conn.get_result.stream_each_row.to_a
				).to eq(
					[["1", "5"], ["1", "6"]]
				)
				expect( @conn.get_result ).to be_nil
			end

			it "keeps last result on error while iterating stream_each_row" do
				@conn.send_query( "SELECT generate_series(2,6) AS a" )
				@conn.send(*row_mode)
				res = @conn.get_result
				expect do
					res.stream_each_row do
						raise ZeroDivisionError
					end
				end.to raise_error(ZeroDivisionError)
				expect( res.values ).to eq(mode_name==:single ? [["2"]] : [["2"], ["3"], ["4"]])
			end

			it "can iterate over all rows as PG::Tuple" do
				@conn.send_query( "SELECT generate_series(2,4) AS a; SELECT 1 AS b, generate_series(5,6) AS c" )
				@conn.send(*row_mode)
				tuples = @conn.get_result.stream_each_tuple.to_a
				expect( tuples[0][0] ).to eq( "2" )
				expect( tuples[1]["a"] ).to eq( "3" )
				expect( tuples.size ).to eq( 3 )

				tuples = @conn.get_result.enum_for(:stream_each_tuple).to_a
				expect( tuples[-1][-1] ).to eq( "6" )
				expect( tuples[-2]["b"] ).to eq( "1" )
				expect( tuples.size ).to eq( 2 )

				expect( @conn.get_result ).to be_nil
			end

			it "clears result on error while iterating stream_each_tuple" do
				@conn.send_query( "SELECT generate_series(2,4) AS a" )
				@conn.send(*row_mode)
				res = @conn.get_result
				expect do
					res.stream_each_tuple do
						raise ZeroDivisionError
					end
				end.to raise_error(ZeroDivisionError)
				expect( res.cleared? ).to eq(true)
			end

			it "should reuse field names in stream_each_tuple" do
				@conn.send_query( "SELECT generate_series(2,3) AS a" )
				@conn.send(*row_mode)
				tuple1, tuple2 = *@conn.get_result.stream_each_tuple.to_a
				expect( tuple1.keys[0].object_id ).to eq(tuple2.keys[0].object_id)
			end

			it "can iterate over all rows as PG::Tuple with symbols and typemap" do
				@conn.send_query( "SELECT generate_series(2,4) AS a" )
				@conn.send(*row_mode)
				res = @conn.get_result.field_names_as(:symbol)
				res.type_map = PG::TypeMapByColumn.new [textdec_int]
				tuples = res.stream_each_tuple.to_a
				expect( tuples[0][0] ).to eq( 2 )
				expect( tuples[1][:a] ).to eq( 3 )
				expect( @conn.get_result ).to be_nil
			end

			it "can handle commands not returning tuples" do
				@conn.send_query( "CREATE TEMP TABLE test_single_row_mode (a int)" )
				@conn.send(*row_mode)
				res1 = @conn.get_result
				res2 = res1.stream_each_tuple { raise "this shouldn't be called" }
				expect( res2 ).to be_equal( res1 )
				expect( @conn.get_result ).to be_nil
				@conn.exec( "DROP TABLE test_single_row_mode" )
			end

			it "complains when not in single row mode" do
				@conn.send_query( "SELECT generate_series(2,4)" )
				expect{
					@conn.get_result.stream_each_row.to_a
				}.to raise_error(PG::InvalidResultStatus, /not in single row mode/)
			end

			it "complains when intersected with get_result" do
				@conn.send_query( "SELECT 1" )
				@conn.send(*row_mode)
				expect{
					@conn.get_result.stream_each_row.each{ @conn.get_result }
				}.to raise_error(PG::NoResultError, /no result received/)
			end

			it "raises server errors" do
				@conn.send_query( "SELECT 0/0" )
				expect{
					@conn.get_result.stream_each_row.to_a
				}.to raise_error(PG::DivisionByZero)
			end

			it "raises an error if result number of fields change" do
				@conn.send_query( "SELECT 1" )
				@conn.send(*row_mode)
				res = @conn.get_result
				expect{
					res.stream_each_row do
						@conn.discard_results
						@conn.send_query("SELECT 2,3");
						@conn.send(*row_mode)
					end
				}.to raise_error(PG::InvalidChangeOfResultFields, /from 1 to 2 /)
				expect( res.cleared? ).to be true
			end

			it "raises an error if there is a timeout during streaming" do
				@conn.exec( "SET local statement_timeout = 20" )

				@conn.send_query( "SELECT 1, true UNION ALL SELECT 2, (pg_sleep(0.3) IS NULL)" )
				@conn.send(*row_mode)
				expect{
					@conn.get_result.stream_each_row do |row|
						# No-op
					end
				}.to raise_error(PG::QueryCanceled, /statement timeout/)
			end

			it "should deny streaming when frozen" do
				@conn.send_query( "SELECT 1" )
				@conn.send(*row_mode)
				res = @conn.get_result.freeze
				expect{
					res.stream_each_row
				}.to raise_error(FrozenError)
			end
		end
	end

	it "inserts nil AS NULL and return NULL as nil" do
		res = @conn.exec_params("SELECT $1::int AS n", [nil])
		expect( res[0]['n'] ).to be_nil()
	end

	it "encapsulates errors in a PG::Error object" do
		exception = nil
		begin
			@conn.exec( "SELECT * FROM nonexistent_table" )
		rescue PG::Error => err
			exception = err
		end

		result = exception.result

		expect( result ).to be_a( described_class() )
		expect( result.error_field(PG::PG_DIAG_SEVERITY) ).to eq( 'ERROR' )
		expect( result.error_field(PG::PG_DIAG_SQLSTATE) ).to eq( '42P01' )
		expect(
			result.error_field(PG::PG_DIAG_MESSAGE_PRIMARY)
		).to eq( 'relation "nonexistent_table" does not exist' )
		expect( result.error_field(PG::PG_DIAG_MESSAGE_DETAIL) ).to be_nil()
		expect( result.error_field(PG::PG_DIAG_MESSAGE_HINT) ).to be_nil()
		expect( result.error_field(PG::PG_DIAG_STATEMENT_POSITION) ).to eq( '15' )
		expect( result.error_field(PG::PG_DIAG_INTERNAL_POSITION) ).to be_nil()
		expect( result.error_field(PG::PG_DIAG_INTERNAL_QUERY) ).to be_nil()
		expect( result.error_field(PG::PG_DIAG_CONTEXT) ).to be_nil()
		expect(
			result.error_field(PG::PG_DIAG_SOURCE_FILE)
		).to match( /parse_relation\.c$|namespace\.c$/ )
		expect( result.error_field(PG::PG_DIAG_SOURCE_LINE) ).to match( /^\d+$/ )
		expect(
			result.error_field(PG::PG_DIAG_SOURCE_FUNCTION)
		).to match( /^parserOpenTable$|^RangeVarGetRelid$/ )
	end

	it "encapsulates PG_DIAG_SEVERITY_NONLOCALIZED error in a PG::Error object" do
		result = nil
		begin
			@conn.exec( "SELECT * FROM nonexistent_table" )
		rescue PG::Error => err
			result = err.result
		end

		expect( result.error_field(PG::PG_DIAG_SEVERITY_NONLOCALIZED) ).to eq( 'ERROR' )
	end

	it "encapsulates database object names for integrity constraint violations" do
		@conn.exec( "CREATE TABLE integrity (id SERIAL PRIMARY KEY)" )
		exception = nil
		begin
			@conn.exec( "INSERT INTO integrity VALUES (NULL)" )
		rescue PG::Error => err
			exception = err
		end
		result = exception.result

		expect( result.error_field(PG::PG_DIAG_SCHEMA_NAME) ).to eq( 'public' )
		expect( result.error_field(PG::PG_DIAG_TABLE_NAME) ).to eq( 'integrity' )
		expect( result.error_field(PG::PG_DIAG_COLUMN_NAME) ).to eq( 'id' )
		expect( result.error_field(PG::PG_DIAG_DATATYPE_NAME) ).to be_nil
		expect( result.error_field(PG::PG_DIAG_CONSTRAINT_NAME) ).to be_nil
	end

	it "detects division by zero as SQLSTATE 22012" do
		sqlstate = nil
		begin
			@conn.exec("SELECT 1/0")
		rescue PG::Error => e
			sqlstate = e.result.result_error_field( PG::PG_DIAG_SQLSTATE ).to_i
		end
		expect( sqlstate ).to eq( 22012 )
	end

	it "provides the error message" do
		@conn.send_query("SELECT xyz")
		res = @conn.get_result; @conn.get_result
		expect( res.error_message ).to match(/"xyz"/)
		expect( res.result_error_message ).to match(/"xyz"/)
	end

	it "provides a verbose error message" do
		@conn.send_query("SELECT xyz")
		res = @conn.get_result; @conn.get_result
		# PQERRORS_TERSE should give a single line result
		expect( res.verbose_error_message(PG::PQERRORS_TERSE, PG::PQSHOW_CONTEXT_ALWAYS) ).to match(/\A.*\n\z/)
		# PQERRORS_VERBOSE should give a multi line result
		expect( res.result_verbose_error_message(PG::PQERRORS_VERBOSE, PG::PQSHOW_CONTEXT_NEVER) ).to match(/\n.*\n/)
	end

	it "provides a verbose error message with SQLSTATE", :postgresql_12 do
		@conn.send_query("SELECT xyz")
		res = @conn.get_result; @conn.get_result
		expect( res.verbose_error_message(PG::PQERRORS_SQLSTATE, PG::PQSHOW_CONTEXT_NEVER) ).to match(/42703/)
	end

	it "returns the same bytes in binary format that are sent in binary format" do
		binary_file = File.join(Dir.pwd, 'spec/data', 'random_binary_data')
		bytes = File.open(binary_file, 'rb').read
		res = @conn.exec_params('VALUES ($1::bytea)',
			[ { :value => bytes, :format => 1 } ], 1)
		expect( res[0]['column1'] ).to eq( bytes )
		expect( res.getvalue(0,0) ).to eq( bytes )
		expect( res.values[0][0] ).to eq( bytes )
		expect( res.column_values(0)[0] ).to eq( bytes )
	end

	it "returns the same bytes in binary format that are sent as inline text" do
		binary_file = File.join(Dir.pwd, 'spec/data', 'random_binary_data')
		bytes = File.open(binary_file, 'rb').read
		@conn.exec("SET standard_conforming_strings=on")
		res = @conn.exec_params("VALUES ('#{PG::Connection.escape_bytea(bytes)}'::bytea)", [], 1)
		expect( res[0]['column1'] ).to eq( bytes )
		expect( res.getvalue(0,0) ).to eq( bytes )
		expect( res.values[0][0] ).to eq( bytes )
		expect( res.column_values(0)[0] ).to eq( bytes )
	end

	it "returns the same bytes in text format that are sent in binary format" do
		binary_file = File.join(Dir.pwd, 'spec/data', 'random_binary_data')
		bytes = File.open(binary_file, 'rb').read
		res = @conn.exec_params('VALUES ($1::bytea)',
			[ { :value => bytes, :format => 1 } ])
		expect( PG::Connection.unescape_bytea(res[0]['column1']) ).to eq( bytes )
	end

	it "returns the same bytes in text format that are sent as inline text" do
		binary_file = File.join(Dir.pwd, 'spec/data', 'random_binary_data')
		in_bytes = File.open(binary_file, 'rb').read

		out_bytes = nil
		@conn.exec("SET standard_conforming_strings=on")
		res = @conn.exec_params("VALUES ('#{PG::Connection.escape_bytea(in_bytes)}'::bytea)", [], 0)
		out_bytes = PG::Connection.unescape_bytea(res[0]['column1'])
		expect( out_bytes ).to eq( in_bytes )
	end

	it "returns the parameter type of the specified prepared statement parameter" do
		query = 'SELECT * FROM pg_stat_activity WHERE user = $1::name AND query = $2::text'
		@conn.prepare( 'queryfinder', query )
		res = @conn.describe_prepared( 'queryfinder' )

		expect(
			@conn.exec_params( 'SELECT format_type($1, -1)', [res.paramtype(0)] ).getvalue( 0, 0 )
		).to eq( 'name' )
		expect(
			@conn.exec_params( 'SELECT format_type($1, -1)', [res.paramtype(1)] ).getvalue( 0, 0 )
		).to eq( 'text' )
	end

	it "raises an exception when a negative index is given to #fformat" do
		res = @conn.exec('SELECT * FROM pg_stat_activity')
		expect {
			res.fformat( -1 )
		}.to raise_error( ArgumentError, /column number/i )
	end

	it "raises an exception when a negative index is given to #fmod" do
		res = @conn.exec('SELECT * FROM pg_stat_activity')
		expect {
			res.fmod( -1 )
		}.to raise_error( ArgumentError, /column number/i )
	end

	it "raises an exception when a negative index is given to #[]" do
		res = @conn.exec('SELECT * FROM pg_stat_activity')
		expect {
			res[ -1 ]
		}.to raise_error( IndexError, /-1 is out of range/i )
	end

	it "raises allow for conversion to an array of arrays" do
		@conn.exec( 'CREATE TABLE valuestest ( foo varchar(33) )' )
		@conn.exec( 'INSERT INTO valuestest ("foo") values (\'bar\')' )
		@conn.exec( 'INSERT INTO valuestest ("foo") values (\'bar2\')' )

		res = @conn.exec( 'SELECT * FROM valuestest' )
		expect( res.values ).to eq( [ ["bar"], ["bar2"] ] )
	end

	it "provides the result status" do
		res = @conn.exec("SELECT 1")
		expect( res.result_status ).to eq(PG::PGRES_TUPLES_OK)

		res = @conn.exec("")
		expect( res.result_status ).to eq(PG::PGRES_EMPTY_QUERY)
	end

	it "can retrieve number of fields" do
		res = @conn.exec('SELECT 1 AS a, 2 AS "B"')
		expect(res.nfields).to eq(2)
		expect(res.num_fields).to eq(2)
	end

	it "can retrieve fields format (text/binary)" do
		res = @conn.exec_params('SELECT 1 AS a, 2 AS "B"', [], 0)
		expect(res.binary_tuples).to eq(0)
		res = @conn.exec_params('SELECT 1 AS a, 2 AS "B"', [], 1)
		expect(res.binary_tuples).to eq(1)
	end

	it "can retrieve field names" do
		res = @conn.exec('SELECT 1 AS a, 2 AS "B"')
		expect(res.fields).to eq(["a", "B"])
	end

	it "can retrieve field names as symbols" do
		res = @conn.exec('SELECT 1 AS a, 2 AS "B"')
		res.field_name_type = :symbol
		expect(res.fields).to eq([:a, :B])
	end

	it "can retrieve single field names" do
		res = @conn.exec('SELECT 1 AS a, 2 AS "B"')
		expect(res.fname(0)).to eq("a")
		expect(res.fname(1)).to eq("B")
		expect{res.fname(2)}.to raise_error(ArgumentError)
	end

	it "can retrieve single field names as symbol" do
		res = @conn.exec('SELECT 1 AS a, 2 AS "B"')
		res.field_name_type = :symbol
		expect(res.fname(0)).to eq(:a)
		expect(res.fname(1)).to eq(:B)
		expect{res.fname(2)}.to raise_error(ArgumentError)
	end

	# PQfmod
	it "can return the type modifier for a result column" do
		@conn.exec( 'CREATE TABLE fmodtest ( foo varchar(33) )' )
		res = @conn.exec( 'SELECT * FROM fmodtest' )
		expect( res.fmod(0) ).to eq( 33 + 4 ) # Column length + varlena size (4)
	end

	it "raises an exception when an invalid index is passed to PG::Result#fmod" do
		@conn.exec( 'CREATE TABLE fmodtest ( foo varchar(33) )' )
		res = @conn.exec( 'SELECT * FROM fmodtest' )
		expect { res.fmod(1) }.to raise_error( ArgumentError )
	end

	it "raises an exception when an invalid (negative) index is passed to PG::Result#fmod" do
		@conn.exec( 'CREATE TABLE fmodtest ( foo varchar(33) )' )
		res = @conn.exec( 'SELECT * FROM fmodtest' )
		expect { res.fmod(-11) }.to raise_error( ArgumentError )
	end

	it "doesn't raise an exception when a valid index is passed to PG::Result#fmod for a" +
	   " column with no typemod" do
		@conn.exec( 'CREATE TABLE fmodtest ( foo text )' )
		res = @conn.exec( 'SELECT * FROM fmodtest' )
		expect( res.fmod(0) ).to eq( -1 )
	end

	# PQftable
	it "can return the oid of the table from which a result column was fetched" do
		@conn.exec( 'CREATE TABLE ftabletest ( foo text )' )
		res = @conn.exec( 'SELECT * FROM ftabletest' )

		expect( res.ftable(0) ).to be_nonzero()
	end

	it "raises an exception when an invalid index is passed to PG::Result#ftable" do
		@conn.exec( 'CREATE TABLE ftabletest ( foo text )' )
		res = @conn.exec( 'SELECT * FROM ftabletest' )

		expect { res.ftable(18) }.to raise_error( ArgumentError )
	end

	it "raises an exception when an invalid (negative) index is passed to PG::Result#ftable" do
		@conn.exec( 'CREATE TABLE ftabletest ( foo text )' )
		res = @conn.exec( 'SELECT * FROM ftabletest' )

		expect { res.ftable(-2) }.to raise_error( ArgumentError )
	end

	it "doesn't raise an exception when a valid index is passed to PG::Result#ftable for a " +
	   "column with no corresponding table" do
		@conn.exec( 'CREATE TABLE ftabletest ( foo text )' )
		res = @conn.exec( 'SELECT foo, LENGTH(foo) as length FROM ftabletest' )
		expect( res.ftable(1) ).to eq( PG::INVALID_OID )
	end

	# PQftablecol
	it "can return the column number (within its table) of a column in a result" do
		@conn.exec( 'CREATE TABLE ftablecoltest ( foo text, bar numeric )' )
		res = @conn.exec( 'SELECT * FROM ftablecoltest' )

		expect( res.ftablecol(0) ).to eq( 1 )
		expect( res.ftablecol(1) ).to eq( 2 )
	end

	it "raises an exception when an invalid index is passed to PG::Result#ftablecol" do
		@conn.exec( 'CREATE TABLE ftablecoltest ( foo text, bar numeric )' )
		res = @conn.exec( 'SELECT * FROM ftablecoltest' )

		expect { res.ftablecol(32) }.to raise_error( ArgumentError )
	end

	it "raises an exception when an invalid (negative) index is passed to PG::Result#ftablecol" do
		@conn.exec( 'CREATE TABLE ftablecoltest ( foo text, bar numeric )' )
		res = @conn.exec( 'SELECT * FROM ftablecoltest' )

		expect { res.ftablecol(-1) }.to raise_error( ArgumentError )
	end

	it "doesnn't raise an exception when a valid index is passed to PG::Result#ftablecol for a " +
	   "column with no corresponding table" do
		@conn.exec( 'CREATE TABLE ftablecoltest ( foo text )' )
		res = @conn.exec( 'SELECT foo, LENGTH(foo) as length FROM ftablecoltest' )
		expect( res.ftablecol(1) ).to eq( 0 )
	end

	it "can be manually checked for failed result status (async API)" do
		@conn.send_query( "SELECT * FROM nonexistent_table" )
		res = @conn.get_result
		expect {
			res.check
		}.to raise_error( PG::Error, /relation "nonexistent_table" does not exist/ )
	end

	it "can return the values of a single field" do
		res = @conn.exec( "SELECT 1 AS x, 'a' AS y UNION ALL SELECT 2, 'b'" )
		expect( res.field_values('x') ).to eq( ['1', '2'] )
		expect( res.field_values('y') ).to eq( ['a', 'b'] )
		expect( res.field_values(:x) ).to eq( ['1', '2'] )
		expect{ res.field_values('') }.to raise_error(IndexError)
		expect{ res.field_values(0) }.to raise_error(TypeError)
	end

	it "can return the values of a single tuple" do
		res = @conn.exec( "SELECT 1 AS x, 'a' AS y UNION ALL SELECT 2, 'b'" )
		expect( res.tuple_values(0) ).to eq( ['1', 'a'] )
		expect( res.tuple_values(1) ).to eq( ['2', 'b'] )
		expect{ res.tuple_values(2) }.to raise_error(IndexError)
		expect{ res.tuple_values(-1) }.to raise_error(IndexError)
		expect{ res.tuple_values("x") }.to raise_error(TypeError)
	end

	it "can return the values of a single vary lazy tuple" do
		res = @conn.exec( "VALUES(1),(2)" )
		expect( res.tuple(0) ).to be_kind_of( PG::Tuple )
		expect( res.tuple(1) ).to be_kind_of( PG::Tuple )
		expect{ res.tuple(2) }.to raise_error(IndexError)
		expect{ res.tuple(-1) }.to raise_error(IndexError)
		expect{ res.tuple("x") }.to raise_error(TypeError)
	end

	it "raises a proper exception for a nonexistent table" do
		expect {
			@conn.exec( "SELECT * FROM nonexistent_table" )
		}.to raise_error( PG::UndefinedTable, /relation "nonexistent_table" does not exist/ )
	end

	it "raises a more generic exception for an unknown SQLSTATE" do
		old_error = PG::ERROR_CLASSES.delete('42P01')
		begin
			expect {
				@conn.exec( "SELECT * FROM nonexistent_table" )
			}.to raise_error{|error|
				expect( error ).to be_an_instance_of(PG::SyntaxErrorOrAccessRuleViolation)
				expect( error.to_s ).to match(/relation "nonexistent_table" does not exist/)
			}
		ensure
			PG::ERROR_CLASSES['42P01'] = old_error
		end
	end

	it "raises a ServerError for an unknown SQLSTATE class" do
		old_error1 = PG::ERROR_CLASSES.delete('42P01')
		old_error2 = PG::ERROR_CLASSES.delete('42')
		begin
			expect {
				@conn.exec( "SELECT * FROM nonexistent_table" )
			}.to raise_error{|error|
				expect( error ).to be_an_instance_of(PG::ServerError)
				expect( error.to_s ).to match(/relation "nonexistent_table" does not exist/)
			}
		ensure
			PG::ERROR_CLASSES['42P01'] = old_error1
			PG::ERROR_CLASSES['42'] = old_error2
		end
	end

	it "raises a proper exception for a nonexistent schema" do
		expect {
			@conn.exec( "DROP SCHEMA nonexistent_schema" )
		}.to raise_error( PG::InvalidSchemaName, /schema "nonexistent_schema" does not exist/ )
	end

	it "the raised result is nil in case of a connection error" do
		c = PG::Connection.connect_start( '127.0.0.1', 54320, "", "", "me", "xxxx", "somedb" )
		expect {
			c.exec "select 1"
		}.to raise_error {|error|
			expect( error ).to be_an_instance_of(PG::UnableToSend)
			expect( error.result ).to eq( nil )
		}
	end

	it "does not clear the result itself" do
		r = @conn.exec "select 1"
		expect( r.autoclear? ).to eq(false)
		expect( r.cleared? ).to eq(false)
		r.clear
		expect( r.cleared? ).to eq(true)
	end

	it "can be inspected before and after clear" do
		r = @conn.exec "select 1"
		expect( r.inspect ).to match(/status=PGRES_TUPLES_OK/)
		r.clear
		expect( r.inspect ).to match(/cleared/)
	end

	it "should give account about memory usage" do
		r = @conn.exec "select 1"
		expect( ObjectSpace.memsize_of(r) ).to be > 1000
		r.clear
		expect( ObjectSpace.memsize_of(r) ).to be < 100
	end

	it "doesn't define #allocate" do
		expect{ PG::Result.allocate }.to raise_error { |error|
			expect( error ).to satisfy { |v| [NoMethodError, TypeError].include?(v.class) }
		}
	end

	it "doesn't define #new" do
		expect{ PG::Result.new }.to raise_error { |error|
			expect( error ).to satisfy { |v| [NoMethodError, TypeError].include?(v.class) }
		}
	end

	context 'result value conversions with TypeMapByColumn' do
		let!(:textdec_int){ PG::TextDecoder::Integer.new name: 'INT4', oid: 23 }
		let!(:textdec_float){ PG::TextDecoder::Float.new name: 'FLOAT4', oid: 700 }

		it "should allow reading, assigning and disabling type conversions" do
			res = @conn.exec( "SELECT 123" )
			expect( res.type_map ).to be_kind_of(PG::TypeMapAllStrings)
			res.type_map = PG::TypeMapByColumn.new [textdec_int]
			expect( res.type_map ).to be_an_instance_of(PG::TypeMapByColumn)
			expect( res.type_map.coders ).to eq( [textdec_int] )
			res.type_map = PG::TypeMapByColumn.new [textdec_float]
			expect( res.type_map.coders ).to eq( [textdec_float] )
			res.type_map = PG::TypeMapAllStrings.new
			expect( res.type_map ).to be_kind_of(PG::TypeMapAllStrings)
		end

		it "should be applied to all value retrieving methods" do
			res = @conn.exec( "SELECT 123 as f" )
			res.type_map = PG::TypeMapByColumn.new [textdec_int]
			expect( res.values ).to eq( [[123]] )
			expect( res.getvalue(0,0) ).to eq( 123 )
			expect( res[0] ).to eq( {'f' => 123 } )
			expect( res.enum_for(:each_row).to_a ).to eq( [[123]] )
			expect( res.enum_for(:each).to_a ).to eq( [{'f' => 123}] )
			expect( res.column_values(0) ).to eq( [123] )
			expect( res.field_values('f') ).to eq( [123] )
			expect( res.field_values(:f) ).to eq( [123] )
			expect( res.tuple_values(0) ).to eq( [123] )
		end

		it "should be usable for several queries" do
			colmap = PG::TypeMapByColumn.new [textdec_int]
			res = @conn.exec( "SELECT 123" )
			res.type_map = colmap
			expect( res.values ).to eq( [[123]] )
			res = @conn.exec( "SELECT 456" )
			res.type_map = colmap
			expect( res.values ).to eq( [[456]] )
		end

		it "shouldn't allow invalid type maps" do
			res = @conn.exec( "SELECT 1" )
			expect{ res.type_map = 1 }.to raise_error(TypeError)
		end
	end
end
