#!/usr/bin/env ruby

module PG

	module Type
		class SimpleType
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
		end

		class CompositeType < SimpleType
			def to_h
				super.merge!({
					element_type: element_type,
					needs_quotation: needs_quotation?,
				})
			end
		end
	end

end # module PG

