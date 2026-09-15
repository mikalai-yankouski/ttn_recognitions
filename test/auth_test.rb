# frozen_string_literal: true

require "minitest/autorun"
require "active_support/all"
require_relative "../lib/ttn/auth"

class AuthTest < Minitest::Test
  def setup
    @secret = "test-secret"
    @auth = Ttn::Auth.new(secret: @secret, allowlist: "varka,kopishche")
    @issued = Time.now.to_i.to_s
    @digest = Ttn::Auth.digest("jpeg-bytes")
  end

  def test_accepts_signed_allowed_tenant
    signature = Ttn::Auth.sign(secret: @secret, slug: "varka", issued_at: @issued, body_digest: @digest)
    result = @auth.call(headers("varka", @issued, signature), body_digest: @digest)

    assert result.ok
    assert_equal "varka", result.slug
  end

  def test_rejects_tenant_not_on_allowlist
    signature = Ttn::Auth.sign(secret: @secret, slug: "stranger", issued_at: @issued, body_digest: @digest)
    result = @auth.call(headers("stranger", @issued, signature), body_digest: @digest)

    refute result.ok
    assert_equal 403, result.status
  end

  def test_rejects_bad_signature
    result = @auth.call(headers("varka", @issued, "ab" * 32), body_digest: @digest)

    refute result.ok
    assert_equal 401, result.status
  end

  def test_rejects_stale_timestamp
    old = (Time.now.to_i - 600).to_s
    signature = Ttn::Auth.sign(secret: @secret, slug: "varka", issued_at: old, body_digest: @digest)
    result = @auth.call(headers("varka", old, signature), body_digest: @digest)

    refute result.ok
    assert_equal 401, result.status
  end

  def test_star_allowlist_accepts_any_valid_slug
    auth = Ttn::Auth.new(secret: @secret, allowlist: "*")
    signature = Ttn::Auth.sign(secret: @secret, slug: "arina", issued_at: @issued, body_digest: @digest)
    result = auth.call(headers("arina", @issued, signature), body_digest: @digest)

    assert result.ok
  end

  private

  def headers(slug, issued, signature)
    {
      "HTTP_X_TTN_TENANT" => slug,
      "HTTP_X_TTN_ISSUED_AT" => issued,
      "HTTP_X_TTN_SIGNATURE" => signature
    }
  end
end
