# frozen_string_literal: true

module Paper
  class InvoiceTotals
    SCALES = [ 100, 10 ].freeze
    VAT_RATES = [ 20, 10, 13, 25 ].freeze

    def self.reconcile(items:, document_total:, declared_line_count: nil, zero_vat_document: false)
      new(items:, document_total:, declared_line_count:, zero_vat_document:).call
    end

    def initialize(items:, document_total:, declared_line_count:, zero_vat_document: false)
      @items = Array(items).map { |item| item.to_h.deep_stringify_keys }
      @document_total = decimal(document_total)
      @declared_line_count = Integer(declared_line_count, exception: false)
      @zero_vat_document = zero_vat_document
    end

    def call
      repair_line_amounts!
      repair_amount_used_as_price!
      drop_exact_duplicates!
      align_vat_rate!
      align_document_total!
      align_declared_count!
      {
        items: @items,
        document_total: @document_total,
        declared_line_count: @declared_line_count,
        warnings: warnings
      }
    end

    private

    def repair_line_amounts!
      @items.each do |item|
        quantity = decimal(item["quantity"])
        price = decimal(item["price"])
        next unless quantity&.positive? && price&.positive?

        amount = decimal(item["amount_with_vat"])
        next unless amount&.positive?

        net = (quantity * price).round(2)
        next if close?(amount, line_gross(item, net))

        SCALES.each do |factor|
          if close?(amount / factor, net) || close?(amount / factor, line_gross(item, net))
            item["amount_with_vat"] = (amount / factor).round(2)
            break
          elsif close?(price / factor, amount / quantity)
            item["price"] = (price / factor).round(2)
            break
          end
        end
      end
    end

    def repair_amount_used_as_price!
      original_gross = lines_gross
      repaired = @items.map { |item| amount_as_unit_price(item) || item }
      return if repaired.none? { |item| item["__repaired_price"] }

      repaired_gross = gross_of(repaired)
      return unless take_repaired_prices?(original_gross, repaired_gross)

      @repaired_prices = true
      @items = repaired.map { |item| item.except("__repaired_price") }
    end

    def amount_as_unit_price(item)
      quantity = decimal(item["quantity"])
      price = decimal(item["price"])
      return unless quantity && quantity > 1 && price&.positive?

      line_net = (quantity * price).round(2)
      if @document_total&.positive?
        return unless line_net > @document_total
      else
        return unless line_net > 200 && quantity >= 10
      end

      unit = (price / quantity).round(2)
      return unless plausible_unit_price?(unit)

      item.merge("price" => unit, "__repaired_price" => true)
    end

    def plausible_unit_price?(value)
      value >= 0.05.to_d && value <= 80.to_d
    end

    def take_repaired_prices?(original_gross, repaired_gross)
      return false if repaired_gross <= 0

      if @document_total&.positive?
        return true if closer?(repaired_gross, @document_total, original_gross)
        return true if original_gross > @document_total * 2 && repaired_gross <= @document_total * 1.5
      end

      original_gross > 1_000 && repaired_gross < (original_gross / 5)
    end

    def closer?(candidate, target, current)
      (candidate - target).abs + 0.01.to_d < (current - target).abs
    end

    def drop_exact_duplicates!
      seen = {}
      @items.select! do |item|
        key = [
          Product.normalize_search_key(item["name"] || item["raw_name"]),
          decimal(item["quantity"])&.round(3),
          decimal(item["price"])&.round(2)
        ]
        next false if key.first.blank? || seen[key]

        seen[key] = true
      end
    end

    # Vision misreads the «Ставка НДС» column — it zeroes the whole column, or
    # drops the odd cell to 10. When a single standard rate makes the line sums
    # meet the declared «Всего стоимость с НДС», that rate is the one on the
    # form. Zero is never a candidate, so a real VAT charge cannot be erased by
    # a document_total that turned out to be the net subtotal.
    def align_vat_rate!
      return if @zero_vat_document || @items.empty?
      return if @document_total.nil? || @document_total <= 0 || totals_agree?

      net = lines_net
      return unless net.positive?

      rate = VAT_RATES.find { |candidate| close?(net * (100 + candidate) / 100, @document_total) }
      return if rate.nil?

      @items.each { |item| item["vat_rate"] = rate }
    end

    def align_document_total!
      calculated = lines_gross
      return @document_total = calculated if @document_total.nil? || @document_total <= 0
      return if calculated <= 0 || close?(@document_total, calculated)

      SCALES.each do |factor|
        if close?(@document_total / factor, calculated)
          @document_total = calculated
          return
        end
      end

      SCALES.each do |factor|
        next unless close?(calculated / factor, @document_total)

        @items.each do |item|
          price = decimal(item["price"])
          item["price"] = (price / factor).round(2) if price&.positive?
        end
        return
      end

      return unless @repaired_prices

      @document_total = calculated
    end

    def align_declared_count!
      return if @items.empty?

      if @declared_line_count.nil? || @declared_line_count <= 0
        @declared_line_count = @items.size
        return
      end
      return if @declared_line_count == @items.size
      return unless totals_agree?

      @declared_line_count = @items.size
    end

    def warnings
      return [] if @items.empty? || totals_agree?

      calculated = lines_gross
      stated = @document_total
      return [] if calculated <= 0 || stated.nil?

      [ "Итог по строкам #{calculated.to_f} не совпадает с итогом накладной #{stated.to_f}." ]
    end

    def totals_agree?
      calculated = lines_gross
      return false if calculated <= 0 || @document_total.nil? || @document_total <= 0

      close?(@document_total, calculated)
    end

    def lines_gross
      gross_of(@items)
    end

    def lines_net
      @items.sum { |item|
        quantity = decimal(item["quantity"]).to_d
        price = decimal(item["price"]).to_d
        next 0.to_d unless quantity.positive? && price.positive?

        quantity * price
      }.round(2)
    end

    def gross_of(items)
      Array(items).sum { |item|
        quantity = decimal(item["quantity"]).to_d
        price = decimal(item["price"]).to_d
        next 0.to_d unless quantity.positive? && price.positive?

        line_gross(item, quantity * price)
      }.round(2)
    end

    def line_gross(item, net)
      vat = decimal(item["vat_rate"]).to_d
      (net + (net * vat / 100)).round(2)
    end

    def close?(left, right)
      return false if left.nil? || right.nil?
      return false unless left.positive? && right.positive?

      (left - right).abs <= [ 0.05.to_d, [ left, right ].max * 0.01 ].max
    end

    def decimal(value)
      return if value.nil? || value.to_s.strip.empty?

      BigDecimal(value.to_s.tr(",", "."))
    rescue ArgumentError
      nil
    end
  end
end
