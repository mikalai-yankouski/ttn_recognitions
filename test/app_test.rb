# frozen_string_literal: true

require "minitest/autorun"
require "rack/test"
require "json"
require "tempfile"
require "active_support/all"
require_relative "../lib/ttn/auth"
require_relative "../lib/ttn/app"

class FakeRecognizer
  def call(_upload)
    { "document_number" => "0939716", "items" => [{ "name" => "Сэндвич", "quantity" => 1, "price" => 8 }] }.to_json
  end
end

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    @app ||= Ttn::App.new(
      recognizer: FakeRecognizer.new,
      auth: Ttn::Auth.new(secret: "test-secret", allowlist: "varka")
    )
  end

  def test_health
    get "/up"
    assert_equal 200, last_response.status
    assert_equal true, JSON.parse(last_response.body)["ok"]
  end

  def test_recognize_returns_json_for_signed_tenant
    with_jpeg("\xFF\xD8fakejpeg".b) do |path, jpeg|
      issued = Time.now.to_i.to_s
      digest = Ttn::Auth.digest(jpeg)
      signature = Ttn::Auth.sign(secret: "test-secret", slug: "varka", issued_at: issued, body_digest: digest)

      header "X-Ttn-Tenant", "varka"
      header "X-Ttn-Issued-At", issued
      header "X-Ttn-Signature", signature
      post "/v1/recognize", { "image" => Rack::Test::UploadedFile.new(path, "image/jpeg") }

      assert_equal 200, last_response.status, last_response.body
      body = JSON.parse(last_response.body)
      assert_equal "varka", body["tenant_slug"]
      assert_equal "0939716", body["document_number"]
      assert_equal "Сэндвич", body.dig("items", 0, "name")
    end
  end

  def test_forbidden_without_allowlist
    with_jpeg("x".b) do |path, jpeg|
      issued = Time.now.to_i.to_s
      digest = Ttn::Auth.digest(jpeg)
      signature = Ttn::Auth.sign(secret: "test-secret", slug: "other", issued_at: issued, body_digest: digest)

      header "X-Ttn-Tenant", "other"
      header "X-Ttn-Issued-At", issued
      header "X-Ttn-Signature", signature
      post "/v1/recognize", { "image" => Rack::Test::UploadedFile.new(path, "image/jpeg") }

      assert_equal 403, last_response.status
    end
  end

  private

  def with_jpeg(bytes)
    file = Tempfile.new(["tn", ".jpg"], binmode: true)
    file.write(bytes)
    file.flush
    yield file.path, bytes
  ensure
    file.close!
  end
end
