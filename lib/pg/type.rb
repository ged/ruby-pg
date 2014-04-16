#!/usr/bin/env ruby

module PG

	class Type

		def initialize(params={})
			params.each do |key, val|
				send("#{key}=", val)
			end
		end

		def dup
			self.class.new(to_h)
		end

		def to_h
			{
				encoder: encoder,
				decoder: decoder,
				oid: oid,
				format: format,
				name: name,
			}
		end

		def ==(v)
			self.class == v.class && to_h == v.to_h
		end

		def marshal_dump
			Marshal.dump(to_h)
		end

		def marshal_load(str)
			initialize Marshal.load(str)
		end
	end

	class CompositeType < Type
		def to_h
			super.merge!({
				elements_type: elements_type,
				needs_quotation: needs_quotation?,
			})
		end
	end

end # module PG

