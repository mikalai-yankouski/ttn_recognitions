# frozen_string_literal: true

require "openssl"
require "active_support/core_ext/object/blank"

module Ttn
  class Auth
    WINDOW = 5 * 60
    TENANT_HEADER = "HTTP_X_TTN_TENANT"
    ISSUED_HEADER = "HTTP_X_TTN_ISSUED_AT"
    SIGNATURE_HEADER = "HTTP_X_TTN_SIGNATURE"

    Result = Struct.new(:ok, :status, :error, :slug, keyword_init: true)

    def initialize(secret: ENV["TTN_HMAC_SECRET"], allowlist: ENV["TTN_ALLOWED_SLUGS"])
      @secret = secret.to_s
      @allowlist = parse_allowlist(allowlist)
    end

    def call(env, body_digest:)
      return fail!(401, "Не задан TTN_HMAC_SECRET") if @secret.blank?

      slug = env[TENANT_HEADER].to_s.strip
      issued_at = env[ISSUED_HEADER].to_s.strip
      signature = env[SIGNATURE_HEADER].to_s.strip
      return fail!(401, "Нет подписи тенанта") if slug.blank? || issued_at.blank? || signature.blank?
      return fail!(403, "Тенант не имеет права импортировать накладные") unless allowed?(slug)
      return fail!(401, "Подпись просрочена") unless fresh?(issued_at)
      return fail!(401, "Неверная подпись") unless valid_signature?(slug, issued_at, body_digest, signature)

      Result.new(ok: true, status: 200, slug: slug)
    end

    def self.sign(secret:, slug:, issued_at:, body_digest:)
      OpenSSL::HMAC.hexdigest("SHA256", secret, canonical(slug, issued_at, body_digest))
    end

    def self.canonical(slug, issued_at, body_digest)
      "#{slug}\n#{issued_at}\n#{body_digest}"
    end

    def self.digest(bytes)
      OpenSSL::Digest::SHA256.hexdigest(bytes.to_s)
    end

    private

    def allowed?(slug)
      return false unless slug.match?(/\A[a-z0-9][a-z0-9_-]*\z/)
      return true if @allowlist == :all

      @allowlist.include?(slug)
    end

    def fresh?(issued_at)
      ts = Integer(issued_at, exception: false)
      return false if ts.nil?

      (Time.now.to_i - ts).abs <= WINDOW
    end

    def valid_signature?(slug, issued_at, body_digest, signature)
      expected = self.class.sign(secret: @secret, slug: slug, issued_at: issued_at, body_digest: body_digest)
      given = signature.to_s.downcase
      return false unless given.bytesize == expected.bytesize

      OpenSSL.fixed_length_secure_compare(expected, given)
    end

    def parse_allowlist(raw)
      list = raw.to_s.split(",").map(&:strip).reject(&:blank?)
      return :all if list == ["*"]
      return [] if list.empty?

      list
    end

    def fail!(status, error)
      Result.new(ok: false, status: status, error: error)
    end
  end
end
