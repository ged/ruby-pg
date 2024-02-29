# -*- rspec -*-
# encoding: utf-8

require_relative '../helpers'

require 'pg'
require 'time'

describe 'Basic type mapping' do

	describe PG::BasicTypeMapForQueries do
		let!(:basic_type_mapping) do
			PG::BasicTypeMapForQueries.new(@conn).freeze
		end

		let!(:basic_type_mapping_writable) do
			PG::BasicTypeMapForQueries.new(@conn)
		end

		it "should be shareable for Ractor", :ractor do
			Ractor.make_shareable(basic_type_mapping)
		end

		it "should be usable with Ractor", :ractor do
			vals = Ractor.new(@conninfo) do |conninfo|
				conn = PG.connect(conninfo)
				conn.type_map_for_queries = PG::BasicTypeMapForQueries.new(conn)
				res = conn.exec_params( "SELECT $1 AT TIME ZONE '-02', $2",
					[Time.new(2019, 12, 8, 20, 38, 12.123, "-01:00"), true])
				res.values
			ensure
				conn&.finish
			end.take

			expect( vals ).to eq( [[ "2019-12-08 23:38:12.123", "t" ]] )
		end

		it "can be initialized with a CoderMapsBundle instead of a connection" do
			maps = PG::BasicTypeRegistry::CoderMapsBundle.new(@conn).freeze
			tm = PG::BasicTypeMapForQueries.new(maps)
			expect( tm[Integer] ).to be_kind_of(PG::TextEncoder::Integer)
		end

		it "can be initialized with a custom type registry" do
			regi = PG::BasicTypeRegistry.new
			regi.register_type 0, 'int8', PG::BinaryEncoder::Int8, nil
			tm = PG::BasicTypeMapForQueries.new(@conn, registry: regi, if_undefined: proc{}).freeze
			res = @conn.exec_params( "SELECT $1::text", [0x3031323334353637], 0, tm )
			expect( res.values ).to eq( [["01234567"]] )
		end

		it "can take a Proc and nitify about undefined types" do
			regi = PG::BasicTypeRegistry.new.freeze
			args = []
			pr = proc { |*a| args << a }
			PG::BasicTypeMapForQueries.new(@conn, registry: regi, if_undefined: pr)
			expect( args.first ).to eq( ["bool", 1] )
		end

		it "raises UndefinedEncoder for undefined types" do
			regi = PG::BasicTypeRegistry.new.freeze
			expect do
				PG::BasicTypeMapForQueries.new(@conn, registry: regi, if_undefined: nil)
			end.to raise_error(PG::BasicTypeMapForQueries::UndefinedEncoder)
		end

		it "should be shareable for Ractor", :ractor do
			Ractor.make_shareable(basic_type_mapping)
		end

		#
		# Encoding Examples
		#

		it "should do basic param encoding" do
			res = @conn.exec_params( "SELECT $1::int8, $2::float, $3, $4::TEXT",
				[1, 2.1, true, "b"], nil, basic_type_mapping )

			expect( res.values ).to eq( [
					[ "1", "2.1", "t", "b" ],
			] )

			expect( result_typenames(res) ).to eq( ['bigint', 'double precision', 'boolean', 'text'] )
		end

		it "should do basic Time encoding" do
			res = @conn.exec_params( "SELECT $1 AT TIME ZONE '-02'",
				[Time.new(2019, 12, 8, 20, 38, 12.123, "-01:00")], nil, basic_type_mapping )

			expect( res.values ).to eq( [[ "2019-12-08 23:38:12.123" ]] )
		end

		it "should do basic param encoding of various float values" do
			res = @conn.exec_params( "SELECT $1::float, $2::float, $3::float, $4::float, $5::float, $6::float, $7::float, $8::float, $9::float, $10::float, $11::float, $12::float",
				[0, 7, 9, 0.1, 0.9, -0.11, 10.11,
			   9876543210987654321e-400,
			   9876543210987654321e400,
			   -1.234567890123456789e-280,
			   -1.234567890123456789e280,
			   9876543210987654321e280
			  ], nil, basic_type_mapping )

			expect( res.values[0][0, 9] ).to eq(
					[ "0", "7", "9", "0.1", "0.9", "-0.11", "10.11", "0", "Infinity" ]
			)

			expect( res.values[0][9]  ).to match( /^-1\.2345678901234\d*e\-280$/ )
			expect( res.values[0][10] ).to match( /^-1\.2345678901234\d*e\+280$/ )
			expect( res.values[0][11] ).to match(  /^9\.8765432109876\d*e\+298$/ )

			expect( result_typenames(res) ).to eq( ['double precision'] * 12 )
		end

		it "should do default array-as-array param encoding" do
			expect( basic_type_mapping.encode_array_as).to eq(:array)
			res = @conn.exec_params( "SELECT $1,$2,$3,$4,$5", [
					[1, 2, 3], # Integer -> bigint[]
					[[1, 2], [3, nil]], # Integer two dimensions -> bigint[]
					[1.11, 2.21], # Float -> double precision[]
					['/,"'.gsub("/", "\\"), nil, 'abcäöü'], # String -> text[]
					[IPAddr.new('1234::5678')], # IPAddr -> inet[]
				], nil, basic_type_mapping )

			expect( res.values ).to eq( [[
					'{1,2,3}',
					'{{1,2},{3,NULL}}',
					'{1.11,2.21}',
					'{"//,/"",NULL,abcäöü}'.gsub("/", "\\"),
					'{1234::5678}',
			]] )

			expect( result_typenames(res) ).to eq( ['bigint[]', 'bigint[]', 'double precision[]', 'text[]', 'inet[]'] )
		end

		it "should do bigdecimal array-as-array param encoding", :bigdecimal do
			expect( basic_type_mapping.encode_array_as).to eq(:array)
			res = @conn.exec_params( "SELECT $1", [
					[BigDecimal("123.45")], # BigDecimal -> numeric[]
				], nil, basic_type_mapping )

			expect( res.values ).to eq( [[
					'{123.45}',
			]] )

			expect( result_typenames(res) ).to eq( ['numeric[]'] )
		end

		it "should do default array-as-array param encoding with Time objects" do
			res = @conn.exec_params( "SELECT $1", [
					[Time.new(2019, 12, 8, 20, 38, 12.123, "-01:00")], # Time -> timestamptz[]
				], nil, basic_type_mapping )

			expect( res.values[0][0] ).to match( /\{\"2019-12-0\d \d\d:38:12.123[+-]\d\d\"\}/ )
			expect( result_typenames(res) ).to eq( ['timestamp with time zone[]'] )
		end

		it "should do array-as-json encoding" do
			basic_type_mapping_writable.encode_array_as = :json
			expect( basic_type_mapping_writable.encode_array_as).to eq(:json)

			res = @conn.exec_params( "SELECT $1::JSON, $2::JSON", [
					[1, {a: 5}, true, ["a", 2], [3.4, nil]],
					['/,"'.gsub("/", "\\"), nil, 'abcäöü'],
				], nil, basic_type_mapping_writable )

			expect( res.values ).to eq( [[
					'[1,{"a":5},true,["a",2],[3.4,null]]',
					'["//,/"",null,"abcäöü"]'.gsub("/", "\\"),
			]] )

			expect( result_typenames(res) ).to eq( ['json', 'json'] )
		end

		it "should do hash-as-json encoding" do
			res = @conn.exec_params( "SELECT $1::JSON, $2::JSON", [
					{a: 5, b: ["a", 2], c: nil},
					{qu: '/,"'.gsub("/", "\\"), ni: nil, uml: 'abcäöü'},
				], nil, basic_type_mapping )

			expect( res.values ).to eq( [[
					'{"a":5,"b":["a",2],"c":null}',
					'{"qu":"//,/"","ni":null,"uml":"abcäöü"}'.gsub("/", "\\"),
			]] )

			expect( result_typenames(res) ).to eq( ['json', 'json'] )
		end

		describe "Record encoding" do
			before :all do
				@conn.exec("CREATE TYPE test_record1 AS (i int, d float, t text)")
				@conn.exec("CREATE TYPE test_record2 AS (i int, r test_record1)")
			end

			after :all do
				@conn.exec("DROP TYPE IF EXISTS test_record2 CASCADE")
				@conn.exec("DROP TYPE IF EXISTS test_record1 CASCADE")
			end

			it "should do array-as-record encoding" do
				basic_type_mapping_writable.encode_array_as = :record
				expect( basic_type_mapping_writable.encode_array_as).to eq(:record)

				res = @conn.exec_params( "SELECT $1::test_record1, $2::test_record2, $3::text", [
						[5, 3.4, "txt"],
				    [1, [2, 4.5, "bcd"]],
				    [4, 5, 6],
					], nil, basic_type_mapping_writable )

				expect( res.values ).to eq( [[
						'(5,3.4,txt)',
				    '(1,"(2,4.5,bcd)")',
						'("4","5","6")',
				]] )

				expect( result_typenames(res) ).to eq( ['test_record1', 'test_record2', 'text'] )
			end
		end

		it "should do bigdecimal param encoding", :bigdecimal do
			large = ('123456790'*10) << '.' << ('012345679')
			res = @conn.exec_params( "SELECT $1::numeric,$2::numeric",
				[BigDecimal('1'), BigDecimal(large)], nil, basic_type_mapping )

			expect( res.values ).to eq( [
					[ "1.0", large ],
			] )

			expect( result_typenames(res) ).to eq( ['numeric', 'numeric'] )
		end

		it "should do IPAddr param encoding" do
			res = @conn.exec_params( "SELECT $1::inet,$2::inet,$3::cidr,$4::cidr",
				['1.2.3.4', IPAddr.new('1234::5678'), '1.2.3.4', IPAddr.new('1234:5678::/32')], nil, basic_type_mapping )

			expect( res.values ).to eq( [
					[ '1.2.3.4', '1234::5678', '1.2.3.4/32', '1234:5678::/32'],
			] )

			expect( result_typenames(res) ).to eq( ['inet', 'inet', 'cidr', 'cidr'] )
		end

		it "should do array of string encoding on unknown classes" do
			iv = Class.new do
				def to_s
					"abc"
				end
			end.new
			res = @conn.exec_params( "SELECT $1", [
					[iv, iv], # Unknown -> text[]
				], nil, basic_type_mapping )

			expect( res.values ).to eq( [[
					'{abc,abc}',
			]] )

			expect( result_typenames(res) ).to eq( ['text[]'] )
		end

		it "should take BinaryData for bytea columns" do
			@conn.exec("CREATE TEMP TABLE IF NOT EXISTS bytea_test (data bytea)")
			bd = PG::BasicTypeMapForQueries::BinaryData.new("ab\xff\0cd").freeze
			res = @conn.exec_params("INSERT INTO bytea_test (data) VALUES ($1) RETURNING data", [bd], nil, basic_type_mapping)

			expect( res.to_a ).to eq([{"data" => "\\x6162ff006364"}])
		end
	end
end
