# -*- rspec -*-
# encoding: utf-8

require_relative '../helpers'

describe 'Basic type mapping' do
	describe PG::BasicTypeMapBasedOnResult do
		let!(:basic_type_mapping) do
			PG::BasicTypeMapBasedOnResult.new(@conn).freeze
		end

		it "can be initialized with a CoderMapsBundle instead of a connection" do
			maps = PG::BasicTypeRegistry::CoderMapsBundle.new(@conn).freeze
			tm = PG::BasicTypeMapBasedOnResult.new(maps)
			expect( tm.rm_coder(0, 16) ).to be_kind_of(PG::TextEncoder::Boolean)
		end

		it "can be initialized with a custom type registry" do
			regi = PG::BasicTypeRegistry.new
			regi.register_type 1, 'int4', PG::BinaryEncoder::Int8, nil
			tm = PG::BasicTypeMapBasedOnResult.new(@conn, registry: regi).freeze

			res = @conn.exec_params( "SELECT 123::INT4", [], 1 )
			tm2 = tm.build_column_map( res )
			expect( tm2.coders.map(&:class) ).to eq( [PG::BinaryEncoder::Int8] )
		end

		it "should be shareable for Ractor", :ractor do
			Ractor.make_shareable(basic_type_mapping)
		end

		[1, 0].each do |format|
			it "should be usable with Ractor in format #{format}", :ractor do
				vals = Ractor.new(@conninfo, format) do |conninfo, format|
					conn = PG.connect(conninfo)
					basic_type_mapping = PG::BasicTypeMapBasedOnResult.new(conn)
					conn.exec( "CREATE TEMP TABLE copytable (t TEXT, i INT, ai INT[])" )

					# Retrieve table OIDs per empty result set.
					res = conn.exec( "SELECT * FROM copytable LIMIT 0", [], format )
					tm = basic_type_mapping.build_column_map( res )
					nsp = format==1 ? PG::BinaryEncoder : PG::TextEncoder
					row_encoder = nsp::CopyRow.new type_map: tm

					conn.copy_data( "COPY copytable FROM STDIN WITH (FORMAT #{ format==1 ? "binary" : "text" })", row_encoder ) do |res|
						conn.put_copy_data ['b', 234, [2,3]]
					end
					res = conn.exec( "SELECT * FROM copytable" )
					res.values
				ensure
					conn&.finish
				end.take

				expect( vals ).to eq( [['b', '234', '{2,3}']] )
			end
		end

		context "with usage of result oids for bind params encoder selection" do
			[1, 0].each do |format|
				it "can type cast query params to format #{format}" do
					@conn.exec( "CREATE TEMP TABLE copytable (t TEXT, i INT, ai INT[], by BYTEA)" )

					# Retrieve table OIDs per empty result.
					res = @conn.exec( "SELECT * FROM copytable LIMIT 0", [], format )
					tm = basic_type_mapping.build_column_map( res )

					@conn.exec_params( "INSERT INTO copytable VALUES ($1, $2, $3, $4)", ['a', 123, [5,4,3], "\0\xFF'"], 0, tm )
					@conn.exec_params( "INSERT INTO copytable VALUES ($1, $2, $3, $4)", ['b', 234, [2,3], "\"\n\r"], 0, tm )
					res = @conn.exec( "SELECT * FROM copytable" )
					expect( res.values ).to eq( [['a', '123', '{5,4,3}', '\x00ff27'], ['b', '234', '{2,3}', '\x220a0d']] )
				end
			end

			it "can do JSON conversions" do
				['JSON', 'JSONB'].each do |type|
					sql = "SELECT CAST('123' AS #{type}),
						CAST('12.3' AS #{type}),
						CAST('true' AS #{type}),
						CAST('false' AS #{type}),
						CAST('null' AS #{type}),
						CAST('[1, \"a\", null]' AS #{type}),
						CAST('{\"b\" : [2,3]}' AS #{type})"

					tm = basic_type_mapping.build_column_map( @conn.exec( sql ) )
					expect( tm.coders.map(&:name) ).to eq( [type.downcase] * 7 )

					res = @conn.exec_params( "SELECT $1, $2, $3, $4, $5, $6, $7",
						[ 123,
							12.3,
							true,
							false,
							nil,
							[1, "a", nil],
							{"b" => [2, 3]},
						], 0, tm )

					expect( res.getvalue(0,0) ).to eq( "123" )
					expect( res.getvalue(0,1) ).to eq( "12.3" )
					expect( res.getvalue(0,2) ).to eq( "true" )
					expect( res.getvalue(0,3) ).to eq( "false" )
					expect( res.getvalue(0,4) ).to eq( nil )
					expect( res.getvalue(0,5).gsub(" ","") ).to eq( "[1,\"a\",null]" )
					expect( res.getvalue(0,6).gsub(" ","") ).to eq( "{\"b\":[2,3]}" )
				end
			end
		end

		context "with usage of result oids for copy encoder selection" do
			[1, 0].each do |format|
				it "can type cast #copy_data text input with encoder to format #{format}" do
					@conn.exec( "CREATE TEMP TABLE copytable (t TEXT, i INT, ai INT[])" )

					# Retrieve table OIDs per empty result set.
					res = @conn.exec( "SELECT * FROM copytable LIMIT 0", [], format )
					tm = basic_type_mapping.build_column_map( res )
					nsp = format==1 ? PG::BinaryEncoder : PG::TextEncoder
					row_encoder = nsp::CopyRow.new type_map: tm

					@conn.copy_data( "COPY copytable FROM STDIN WITH (FORMAT #{ format==1 ? "binary" : "text" })", row_encoder ) do |res|
						@conn.put_copy_data ['a', 123, [[5,4],[3,2]]]
						@conn.put_copy_data ['b', 234, [2,3]]
					end
					res = @conn.exec( "SELECT * FROM copytable" )
					expect( res.values ).to eq( [['a', '123', '{{5,4},{3,2}}'], ['b', '234', '{2,3}']] )
				end
			end

			[1, 0].each do |format|
				it "can type cast #copy_data input with encoder to format #{format}" do
					@conn.exec( "CREATE TEMP TABLE copytable (b bytea, i INT, ts1 timestamp, ts2 timestamp, f4 float4, f8 float8, d1 date, d2 date)" )

					# Retrieve table OIDs per empty result set.
					res = @conn.exec_params( "SELECT * FROM copytable LIMIT 0", [], format )
					tm = basic_type_mapping.build_column_map( res )
					nsp = format==1 ? PG::BinaryEncoder : PG::TextEncoder
					row_encoder = nsp::CopyRow.new type_map: tm

					@conn.copy_data( "COPY copytable FROM STDIN WITH (FORMAT #{ format==1 ? "binary" : "text" })", row_encoder ) do |res|
						@conn.put_copy_data ["\xff\x00\n\r'", 123, Time.utc(2023, 3, 17, 3, 4, 5.6789123), Time.new(1990, 12, 17, 18, 44, 45, "+03:30").utc, 12.345, -12.345e167, Date.new(2055, 12, 31), Date.new(1234, 8, 31)]
						@conn.put_copy_data ["  xyz  ", -444, "Infinity", "-infinity", -Float::INFINITY, Float::NAN, "infinity", "-infinity"]
					end
					res = @conn.exec( "SELECT * FROM copytable" )
					expect( res.values ).to eq( [
						["\\xff000a0d27", "123", "2023-03-17 03:04:05.678912", "1990-12-17 15:14:45", "12.345", "-1.2345e+168", "2055-12-31", "1234-08-31"],
						["\\x202078797a2020", "-444", "infinity", "-infinity", "-Infinity", "NaN", "infinity", "-infinity"]
					] )
				end
			end
		end
	end
end
