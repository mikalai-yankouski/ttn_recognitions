# frozen_string_literal: true

module Paper
  module Utf8
    module_function

    def string(value)
      s = value.to_s.dup
      s.force_encoding(Encoding::UTF_8)
      return s if s.valid_encoding?

      s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    def deep(value)
      case value
      when Hash
        value.to_h.each_with_object({}) do |(key, item), memo|
          memo[string(key)] = deep(item)
        end
      when Array
        value.map { |item| deep(item) }
      when String
        string(value)
      else
        value
      end
    end
  end
end
