# frozen_string_literal: true

require_relative "test_helper"
require "faraday"
require "tempfile"
require_relative "../lib/ttn/boot"

class VisionFallbackTest < Minitest::Test
  INVOICE_JSON = {
    "document_number" => "0939716",
    "series" => "ЯЛ",
    "date" => "2026-08-21",
    "supplier_name" => "ООО Тест",
    "declared_line_count" => 1,
    "document_total" => 8,
    "total_vat_text" => "Ноль руб. 00 коп.",
    "items" => [ { "name" => "Сэндвич", "unit" => "шт", "quantity" => 1, "price" => 8, "vat_rate" => "Без НДС" } ]
  }.freeze

  def setup
    @gemini_key = ENV["GEMINI_API_KEY"]
    @google_key = ENV["GOOGLE_API_KEY"]
    @crops = ENV["PAPER_VISION_CROPS"]
    @cloud_model = ENV["PAPER_VISION_CLOUD_MODEL"]
    @fallbacks = ENV["PAPER_VISION_GEMINI_FALLBACKS"]
    @retry_sleep = ENV["PAPER_VISION_GEMINI_RETRY_SLEEP"]
    @budget = ENV["PAPER_VISION_GEMINI_BUDGET"]
    ENV["GEMINI_API_KEY"] = "test-gemini-key"
    ENV.delete("GOOGLE_API_KEY")
    ENV["PAPER_VISION_CROPS"] = "0"
    ENV["PAPER_VISION_GEMINI_RETRY_SLEEP"] = "0"
    ENV["PAPER_VISION_GEMINI_BUDGET"] = "60"
  end

  def teardown
    restore_env("GEMINI_API_KEY", @gemini_key)
    restore_env("GOOGLE_API_KEY", @google_key)
    restore_env("PAPER_VISION_CROPS", @crops)
    restore_env("PAPER_VISION_CLOUD_MODEL", @cloud_model)
    restore_env("PAPER_VISION_GEMINI_FALLBACKS", @fallbacks)
    restore_env("PAPER_VISION_GEMINI_RETRY_SLEEP", @retry_sleep)
    restore_env("PAPER_VISION_GEMINI_BUDGET", @budget)
  end

  def test_gemini_success_does_not_call_ollama
    gemini = stub_connection do |stubs|
      stubs.post("models/gemini-flash-latest:generateContent") do
        [ 200, { "Content-Type" => "application/json" }, gemini_body(INVOICE_JSON) ]
      end
    end
    ollama = stub_connection do |stubs|
      stubs.post("/api/chat") { flunk "ollama should not run when gemini succeeds" }
    end

    json = vision(gemini:, ollama:).call(jpeg_path)
    payload = JSON.parse(json)
    assert_equal "0939716", payload["document_number"]
    assert_equal "Сэндвич", payload.dig("items", 0, "name")
  end

  def test_gemini_unavailable_falls_back_to_ollama
    gemini = stub_connection do |stubs|
      stubs.post("models/gemini-flash-latest:generateContent") do
        [ 403, { "Content-Type" => "application/json" }, { "error" => { "message" => "USER_LOCATION_INVALID" } } ]
      end
    end
    ollama = stub_connection do |stubs|
      stubs.post("/api/chat") do
        [ 200, { "Content-Type" => "application/json" }, ollama_body(INVOICE_JSON.merge("document_number" => "0939717")) ]
      end
    end

    json = vision(gemini:, ollama:).call(jpeg_path)
    payload = JSON.parse(json)
    assert_equal "0939717", payload["document_number"]
  end

  def test_gemini_503_tries_next_cloud_model
    ENV["PAPER_VISION_CLOUD_MODEL"] = "gemini-3-flash-preview"
    ENV["PAPER_VISION_GEMINI_FALLBACKS"] = "gemini-flash-lite-latest"
    gemini = stub_connection do |stubs|
      stubs.post("models/gemini-3-flash-preview:generateContent") do
        [ 503, { "Content-Type" => "application/json" }, { "error" => { "status" => "UNAVAILABLE", "message" => "high demand" } } ]
      end
      stubs.post("models/gemini-flash-lite-latest:generateContent") do
        [ 200, { "Content-Type" => "application/json" }, gemini_body(INVOICE_JSON.merge("document_number" => "0939718")) ]
      end
    end
    ollama = stub_connection do |stubs|
      stubs.post("/api/chat") { flunk "ollama should not run when a gemini fallback succeeds" }
    end

    json = Paper::Vision.new(
      provider: :gemini,
      api_key: "test-gemini-key",
      connection: gemini,
      ollama_connection: ollama
    ).call(jpeg_path)
    payload = JSON.parse(json)
    assert_equal "0939718", payload["document_number"]
  end

  def test_gemini_retries_until_success_within_budget
    fail_503 = [ 503, { "Content-Type" => "application/json" }, { "error" => { "status" => "UNAVAILABLE", "message" => "high demand" } } ]
    gemini = stub_connection do |stubs|
      stubs.post("models/gemini-flash-latest:generateContent") { fail_503 }
      stubs.post("models/gemini-flash-latest:generateContent") { fail_503 }
      stubs.post("models/gemini-flash-latest:generateContent") do
        [ 200, { "Content-Type" => "application/json" }, gemini_body(INVOICE_JSON.merge("document_number" => "0939719")) ]
      end
    end
    ollama = stub_connection do |stubs|
      stubs.post("/api/chat") { flunk "ollama should not run when gemini succeeds within the budget" }
    end

    json = vision(gemini:, ollama:).call(jpeg_path)
    payload = JSON.parse(json)
    assert_equal "0939719", payload["document_number"]
  end

  def test_gemini_empty_json_keeps_retrying_until_success
    gemini = stub_connection do |stubs|
      stubs.post("models/gemini-flash-latest:generateContent") do
        [ 200, { "Content-Type" => "application/json" }, { "candidates" => [ { "content" => { "parts" => [ { "text" => "{}" } ] } } ] } ]
      end
      stubs.post("models/gemini-flash-latest:generateContent") do
        [ 200, { "Content-Type" => "application/json" }, gemini_body(INVOICE_JSON.merge("document_number" => "0939720")) ]
      end
    end
    ollama = stub_connection do |stubs|
      stubs.post("/api/chat") { flunk "empty gemini JSON should retry, not jump to ollama" }
    end

    json = vision(gemini:, ollama:).call(jpeg_path)
    payload = JSON.parse(json)
    assert_equal "0939720", payload["document_number"]
  end

  def test_payment_scan_accepts_binary_cyrillic_filename
    refute Paper::Vision.payment_scan?("тест.jpg".b)
    assert Paper::Vision.payment_scan?("счёт-на-оплату.jpg".b)
  end

  private

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end

  def vision(gemini:, ollama:)
    Paper::Vision.new(
      provider: :gemini,
      api_key: "test-gemini-key",
      model: "gemini-flash-latest",
      connection: gemini,
      ollama_connection: ollama
    )
  end

  def stub_connection
    stubs = Faraday::Adapter::Test::Stubs.new
    yield stubs
    Faraday.new(url: "http://vision.test") do |faraday|
      faraday.request :json
      faraday.response :json, content_type: /\bjson/
      faraday.adapter :test, stubs
    end
  end

  def gemini_body(payload)
    { "candidates" => [ { "content" => { "parts" => [ { "text" => payload.to_json } ] } } ] }
  end

  def ollama_body(payload)
    { "message" => { "content" => payload.to_json } }
  end

  def jpeg_path
    @jpeg_file ||= begin
      file = Tempfile.new([ "tn", ".jpg" ], binmode: true)
      file.write("\xFF\xD8fakejpeg".b)
      file.flush
      file
    end
    @jpeg_file.path
  end
end
