# frozen_string_literal: true

require "logger"
require "json"
require "openssl"
require "time"
require "rack"
require "faraday"
require "active_support/all"

module Rails
  class << self
    def logger
      @logger ||= Logger.new($stdout)
    end
  end
end

module Product
  def self.normalize_search_key(value)
    value.to_s
         .downcase
         .tr("ё", "е")
         .gsub(/[«»""„"]/, " ")
         .gsub(/\(([^)]*)\)/) { " #{::Regexp.last_match(1)} " }
         .gsub(/\b\d+(?:[,.]\d+)?\s*(?:шт|гр?|г\.|мл)\b/i, " ")
         .gsub(/[^[:alnum:]\s]/, " ")
         .squish
  end
end

paper_dir = File.expand_path("../paper", __dir__)
%w[
  vat_rate
  invoice_totals
  invoice_schema
  upright
  enhance
  crops
  vision
  recognize
].each { |name| require File.join(paper_dir, name) }

require_relative "auth"
require_relative "app"
