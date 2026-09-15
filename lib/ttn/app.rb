# frozen_string_literal: true

require "tempfile"
require "tmpdir"

module Ttn
  class App
    Upload = Struct.new(:path, :original_filename, :content_type, :size, keyword_init: true)

    def initialize(recognizer: nil, auth: nil)
      @recognizer = recognizer
      @auth = auth || Auth.new
    end

    def call(env)
      req = Rack::Request.new(env)
      case [req.request_method, req.path_info]
      when ["GET", "/up"]
        json(200, { ok: true })
      when ["POST", "/v1/recognize"]
        recognize(req, env)
      else
        json(404, { error: "not found" })
      end
    end

    private

    def recognize(req, env)
      image = req.params["image"] || req.params["file"]
      return json(422, { error: "Загрузите фото накладной" }) if image.blank?

      bytes, filename, content_type = extract_upload(image)
      digest = Auth.digest(bytes)
      auth = @auth.call(env, body_digest: digest)
      return json(auth.status, { error: auth.error }) unless auth.ok

      json_text = with_tempfile(bytes, filename) do |path|
        upload = Upload.new(
          path: path,
          original_filename: filename,
          content_type: content_type,
          size: bytes.bytesize
        )
        recognizer.call(upload)
      end

      payload = JSON.parse(json_text)
      json(200, payload.merge("tenant_slug" => auth.slug))
    rescue JSON::ParserError
      json(502, { error: "Модель вернула не JSON" })
    rescue Paper::Recognize::Error => error
      status = error.is_a?(Paper::Recognize::Unavailable) ? 503 : 422
      json(status, { error: error.message })
    end

    def extract_upload(image)
      if image.is_a?(Hash)
        file = image[:tempfile] || image["tempfile"]
        bytes = File.binread(file.path)
        name = (image[:filename] || image["filename"]).to_s
        type = (image[:type] || image["type"]).to_s
        return [bytes, name.presence || "scan.jpg", type.presence || "image/jpeg"]
      end

      if image.respond_to?(:tempfile)
        bytes = File.binread(image.tempfile.path)
        name = image.original_filename.to_s if image.respond_to?(:original_filename)
        type = image.content_type.to_s if image.respond_to?(:content_type)
        return [bytes, name.presence || "scan.jpg", type.presence || "image/jpeg"]
      end

      if image.respond_to?(:path)
        bytes = File.binread(image.path)
        name = image.original_filename.to_s if image.respond_to?(:original_filename)
        type = image.content_type.to_s if image.respond_to?(:content_type)
        return [bytes, name.presence || File.basename(image.path), type.presence || "image/jpeg"]
      end

      ["", "scan.jpg", "application/octet-stream"]
    end

    def with_tempfile(bytes, filename)
      ext = File.extname(filename.to_s)
      ext = ".jpg" if ext.blank?
      file = Tempfile.new(["ttn", ext], binmode: true)
      file.write(bytes)
      file.flush
      yield file.path
    ensure
      file&.close!
    end

    def recognizer
      @recognizer ||= Paper::Recognize.new
    end

    def json(status, body)
      payload = JSON.generate(body)
      [status, { "content-type" => "application/json; charset=utf-8" }, [payload]]
    end
  end
end
