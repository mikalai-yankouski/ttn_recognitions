# frozen_string_literal: true

require_relative "utf8"

module Paper
  module InvoiceSchema
    module_function

    def json_schema
      {
        type: "object",
        properties: {
          document_number: nullable_string,
          series: nullable_string,
          date: nullable_string,
          supplier_name: nullable_string,
          declared_line_count: nullable_integer,
          document_total: nullable_number,
          total_vat_text: nullable_string,
          recognition_warnings: { type: "array", items: { type: "string" } },
          items: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string" },
                unit: nullable_string,
                quantity: nullable_number,
                price: nullable_number,
                vat_rate: { type: [ "string", "number", "null" ] },
                vat_amount: nullable_number,
                amount_with_vat: nullable_number
              },
              required: %w[name quantity price]
            }
          }
        },
        required: %w[
          document_number series date supplier_name declared_line_count
          document_total total_vat_text items
        ]
      }
    end

    def items_json_schema
      {
        type: "object",
        properties: {
          items: json_schema.dig(:properties, :items),
          declared_line_count: nullable_integer,
          document_total: nullable_number,
          total_vat_text: nullable_string,
          recognition_warnings: { type: "array", items: { type: "string" } }
        },
        required: %w[items declared_line_count document_total total_vat_text]
      }
    end

    def header_json_schema
      properties = json_schema.fetch(:properties).slice(
        :document_number, :series, :date, :supplier_name
      )
      {
        type: "object",
        properties:,
        required: properties.keys.map(&:to_s)
      }
    end

    def gemini_json_schema
      to_gemini_schema(json_schema)
    end

    def gemini_items_json_schema
      to_gemini_schema(items_json_schema)
    end

    def gemini_header_json_schema
      to_gemini_schema(header_json_schema)
    end

    def normalize_json(content)
      parsed = parse(content)
      return unless parsed.is_a?(Hash)

      parsed = parsed.stringify_keys
      warnings = []
      items = coerce_items(parsed["items"]).filter_map.with_index do |row, index|
        normalize_item(row, index:, warnings:)
      end
      if items.blank?
        return quality_certificate_json(parsed, warnings) if quality_certificate?(parsed, warnings)

        return
      end

      apply_document_zero_vat!(parsed, items)
      reconciled = InvoiceTotals.reconcile(
        items: items,
        document_total: parsed["document_total"],
        declared_line_count: parsed["declared_line_count"],
        zero_vat_document: VatRate.zero_document?(parsed["total_vat_text"])
      )
      items = reconciled[:items]
      items.each do |item|
        item.delete("vat_amount")
        item.delete("amount_with_vat")
      end
      parsed["items"] = items
      parsed["supplier_name"] = normalize_supplier_name(parsed["supplier_name"])
      parsed["document_number"] = normalize_document_number(parsed["document_number"])
      parsed["declared_line_count"] = reconciled[:declared_line_count]
      parsed["document_total"] = reconciled[:document_total]&.to_f
      parsed.delete("total_vat_text")
      warnings.concat(reconciled[:warnings])
      parsed["recognition_warnings"] = warnings.uniq if warnings.any?
      parsed.to_json
    end

    def parse(content)
      stripped = Utf8.string(content).strip
      stripped = stripped.sub(/\A```(?:json)?/i, "").sub(/```\z/, "").strip
      JSON.parse(stripped)
    rescue JSON::ParserError
      nil
    end

    def normalize_item(row, index:, warnings:)
      return unless row.is_a?(Hash)

      item = row.stringify_keys
      name = Utf8.string(item["name"]).strip
      return if name.blank? || price_only_name?(name) || garbage_item_name?(name)

      item["name"] = normalize_item_name(name)
      item["unit"] = item["unit"].presence || "шт"
      quantity = decimal(item["quantity"])
      price = decimal(item["price"])
      warnings << "Строка #{index + 1} «#{name}»: количество не распознано." unless quantity&.positive?
      warnings << "Строка #{index + 1} «#{name}»: цена не распознана." unless price&.positive?

      net = quantity.to_d * price.to_d
      item["vat_rate"] = VatRate.normalize(
        item["vat_rate"],
        vat_amount: item["vat_amount"],
        net:,
        amount_with_vat: item["amount_with_vat"]
      )
      if arithmetic_mismatch?(item, net)
        warnings << "Строка #{index + 1} «#{name}»: арифметика количества, цены и суммы не сходится."
      end
      item
    end
    private_class_method :normalize_item

    def apply_document_zero_vat!(parsed, items)
      return unless VatRate.zero_document?(parsed["total_vat_text"])

      items.each { |item| item["vat_rate"] = 0 }
    end
    private_class_method :apply_document_zero_vat!

    def arithmetic_mismatch?(item, net)
      gross = decimal(item["amount_with_vat"])
      rate = decimal(item["vat_rate"])
      return false unless gross&.positive? && net.positive? && rate

      expected = net * (1 + rate / 100)
      (gross - expected).abs > [ 0.05.to_d, expected * 0.01 ].max
    end
    private_class_method :arithmetic_mismatch?

    def normalize_document_number(value)
      raw = value.to_s.strip
      return if raw.blank?

      stripped = raw.sub(/\A№\s*/i, "").gsub(/(?:унп|упн)/i, " ").squish
      stripped = stripped.sub(/\A(?:KH|KN)(?=\s*\d)/i, "КН")
      if (token = stripped[/\bb2b[-_]?\d+\b/i])
        return token
      end
      if (combo = stripped.match(/\A([А-ЯЁа-яё]{2})\s*0*(\d{5,8})\z/))
        return "#{combo[1].upcase}#{combo[2]}"
      end

      compact = stripped.gsub(/\s+/, "")
      digits = compact.gsub(/\D/, "")
      if compact.match?(/\A(?=.*[A-Za-zА-Яа-яЁё])[A-Za-zА-Яа-яЁё0-9][-A-Za-zА-Яа-яЁё0-9_\/.]{2,24}\z/) &&
          digits.length.between?(3, 8)
        return compact
      end

      return if digits.blank?
      return if digits.length < 5 || digits.length == 9

      digits
    end

    def coerce_items(value)
      case value
      when Array then value
      when Hash then [ value ]
      when String
        coerce_items(parse(value))
      else
        []
      end
    end
    private_class_method :coerce_items

    def quality_certificate?(parsed, warnings = [])
      blob = [
        parsed["supplier_name"],
        parsed["document_kind"],
        Array(parsed["recognition_warnings"]).join(" "),
        Array(warnings).join(" "),
        coerce_items(parsed["items"]).map { |row|
          row.is_a?(Hash) ? row.stringify_keys["name"] : row
        }.join(" ")
      ].join(" ")
      blob.match?(/удостоверен|не товарн\p{L}* накладн|отсутствуют товарный раздел|это не накладн/i)
    end

    def quality_certificate_json(parsed, warnings)
      notice = (
        Array(parsed["recognition_warnings"]) + Array(warnings)
      ).find { |warning| warning.to_s.match?(/удостоверен|не товарн|отсутствуют товарный раздел|это не накладн/i) }
      if notice.blank?
        notice = if coerce_items(parsed["items"]).any? { |row|
          (row.is_a?(Hash) ? row.stringify_keys["name"] : row).to_s.match?(/удостоверен/i)
        } || parsed["supplier_name"].to_s.match?(/удостоверен/i)
          "Это удостоверение качества, а не товарная накладная."
        else
          "Это не товарная накладная."
        end
      end
      parsed["items"] = []
      parsed["document_number"] = nil
      parsed["supplier_name"] = normalize_supplier_name(parsed["supplier_name"])
      parsed["recognition_warnings"] = (
        warnings + Array(parsed["recognition_warnings"]) + [ notice ]
      ).flatten.compact.uniq
      parsed.to_json
    end
    private_class_method :quality_certificate?, :quality_certificate_json

    def price_only_name?(value)
      value.to_s.strip.match?(/\A\d+(?:[.,]\d+)?\z/)
    end

    GARBAGE_ITEM_NAME = /
      \A(?:покупка|итого)\z|
      \A\d+(?:[.,]\d+)?\s*(?:т|кг|гр?|мл|л)\z|
      рубл|копе(?:ек|йки)|
      товарн\p{L}*\s+(?:раздел|работ|розбер)|
      санитарно|сертификат|удостоверен|
      согласно\s+приложен
    /ix

    def garbage_item_name?(value)
      name = value.to_s.squish
      return true if name.blank?
      return true if name.match?(GARBAGE_ITEM_NAME)

      false
    end

    def normalize_item_name(value)
      name = value.to_s.strip
      return name if name.blank?

      name = name.dup
      name.sub!(/\Aпищев(?:ое|ые)\s+пекарн\p{L}*\s+/i, "")
      [
        [ /нирокн\p{L}*/i, "Пирожное" ],
        [ /\bколбко\b/i, "Кольцо" ],
        [ /мустацков/i, "фисташков" ],
        [ /\bнесочн/i, "песочн" ],
        [ /\bлесочн/i, "песочн" ],
        [ /трюфик\p{L}*/i, "трубочк" ],
        [ /\bонадвич\b/i, "Сэндвич" ],
        [ /\bзаварной с маком/i, "Завиванец с маком" ],
        [ /\bтранол/i, "Гранол" ],
        [ /\bтренол/i, "Гранол" ],
        [ /кольцо с фисташковым кремом/i, "Кольцо фисташковое" ],
        [ /цезарь бойл/i, "Цезарь боул" ],
        [ /цезарь булл/i, "Цезарь боул" ],
        [ /цезарь бул/i, "Цезарь боул" ],
        [ /салат цезарь боул/i, "Цезарь боул" ],
        [ /арахисовый крех/i, "Арахисовый кранч" ],
        [ /\boreo\b/i, "орео" ]
      ].each { |pattern, replacement| name.gsub!(pattern, replacement) }
      name.squish
    end

    def normalize_supplier_name(value)
      name = value.to_s.dup
      name.sub!(/\A\s*(?:грузоотправитель|отправитель)\s*[:.\-–]?\s*/i, "")
      name.gsub!(/\s*унп\s*\d+/i, "")
      [
        [ /общество с ограниченной ответственностью/i, "ООО" ],
        [ /открытое акционерное общество/i, "ОАО" ],
        [ /закрытое акционерное общество/i, "ЗАО" ],
        [ /частное унитарное предприятие/i, "ЧУП" ],
        [ /индивидуальный предприниматель/i, "ИП" ]
      ].each { |pattern, abbr| name.gsub!(pattern, abbr) }
      name.gsub!(/частн(?:ый|ого|ому|ая)?\s+хлеб/i, "Честный хлеб")
      name.gsub!(/спортюнион/i, "Спортпион")
      name.gsub!(/бейковит|бейксант/i, "Бейксвит")
      name.gsub!(/кернада|кернда/i, "Керида")
      name.gsub!(/импер[ие]я\s*кофе/i, "Империя Кофе")
      name.squish.presence
    end

    def decimal(value)
      return if value.nil?

      BigDecimal(value.to_s.tr(",", "."))
    rescue ArgumentError
      nil
    end
    private_class_method :decimal

    def nullable_string
      { type: [ "string", "null" ] }
    end
    private_class_method :nullable_string

    def nullable_number
      { type: [ "number", "null" ] }
    end
    private_class_method :nullable_number

    def nullable_integer
      { type: [ "integer", "null" ] }
    end
    private_class_method :nullable_integer

    def to_gemini_schema(node)
      return node unless node.is_a?(Hash)

      raw_type = node[:type] || node["type"]
      types = raw_type.is_a?(Array) ? raw_type : [ raw_type ]
      nullable = types.intersect?([ "null", :null ])
      concrete = (types - [ "null", :null ]).first
      result = {}
      result[:type] = gemini_type(concrete) if concrete
      result[:nullable] = true if nullable
      properties = node[:properties] || node["properties"]
      if properties
        result[:properties] = properties.to_h { |key, value| [ key.to_s, to_gemini_schema(value) ] }
      end
      items = node[:items] || node["items"]
      result[:items] = to_gemini_schema(items) if items
      required = node[:required] || node["required"]
      result[:required] = required if required
      result
    end
    private_class_method :to_gemini_schema

    def gemini_type(type)
      {
        "object" => "OBJECT",
        "array" => "ARRAY",
        "string" => "STRING",
        "number" => "NUMBER",
        "integer" => "INTEGER",
        "boolean" => "BOOLEAN"
      }.fetch(type.to_s, "STRING")
    end
    private_class_method :gemini_type
  end
end
