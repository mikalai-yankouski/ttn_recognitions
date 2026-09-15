# frozen_string_literal: true

module Paper
  module VatRate
    RATES = [ 0, 10, 13, 20, 25 ].freeze
    EXEMPT = "bez_nds"
    SELECT_OPTIONS = [
      [ "Без НДС", EXEMPT ],
      [ "0%", 0 ],
      [ "10%", 10 ],
      [ "13%", 13 ],
      [ "20%", 20 ],
      [ "25%", 25 ]
    ].freeze

    module_function

    def select_value(value)
      text = value.to_s.strip
      return EXEMPT if text == EXEMPT || bez_nds?(text)

      rate = text.gsub(/[^\d]/, "").to_i
      return rate if RATES.include?(rate)

      0
    end

    def percent(value)
      selected = select_value(value)
      return 0 if selected == EXEMPT

      selected.to_i
    end

    def normalize(value, vat_amount: nil, net: nil, amount_with_vat: nil)
      vat_amount = decimal(vat_amount)
      net = decimal(net)
      gross = decimal(amount_with_vat)

      if vat_amount <= 0 && gross.positive? && net.positive? && (gross - net) > 0.05
        vat_amount = (gross - net).round(2)
      end

      if bez_nds?(value)
        return amounts_include_vat?(net, vat_amount, gross) ? infer_from_amount(net, vat_amount) : EXEMPT
      end

      inferred = infer_from_amount(net, vat_amount)
      return inferred if inferred.positive?
      return 0 if amounts_exclude_vat?(net, vat_amount, gross)

      declared(value)
    end

    def infer_from_amount(net, vat_amount)
      return 0 if net <= 0 || vat_amount <= 0

      ratio = vat_amount / net
      return 25 if ratio >= 0.225
      return 20 if ratio >= 0.15
      return 13 if ratio >= 0.115
      return 10 if ratio >= 0.05

      0
    end

    def amounts_exclude_vat?(net, vat_amount, gross)
      return false unless net.positive? && gross.positive?
      return false if vat_amount > 0.05

      (gross - net).abs <= [ 0.05.to_d, net * 0.005 ].max
    end

    def amounts_include_vat?(net, vat_amount, gross)
      inferred = infer_from_amount(net, vat_amount)
      return false unless inferred.positive? && gross.positive? && net.positive?

      expected = net + vat_amount
      (gross - expected).abs <= [ 0.05.to_d, expected * 0.01 ].max
    end

    def declared(value)
      text = value.to_s.strip
      return 0 if text == EXEMPT || bez_nds?(text)
      return 20 if text.blank?

      rate = text.gsub(/[^\d]/, "").to_i
      return rate if RATES.include?(rate)
      return 25 if rate >= 23
      return 20 if rate >= 16
      return 13 if rate >= 12
      return 10 if rate >= 5

      20
    end

    def bez_nds?(value)
      text = value.to_s
      text == EXEMPT || text.match?(/без/i)
    end

    def zero_document?(value)
      text = value.to_s.downcase
      return false if text.blank?
      return true if text.match?(/без\s*ндс|ноль|нуль/)
      return true if text.match?(/\A\s*0+(?:[.,]0+)?\s*(?:руб)?/)

      false
    end

    def decimal(value)
      return 0.to_d if value.nil? || value.to_s.strip.empty?

      BigDecimal(value.to_s.tr(":,", "."))
    rescue ArgumentError
      0.to_d
    end
  end
end
