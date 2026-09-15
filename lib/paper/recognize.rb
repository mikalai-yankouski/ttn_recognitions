# frozen_string_literal: true

module Paper
  class Recognize
    class Error < StandardError; end
    class Unavailable < Error; end

    ALLOWED_TYPES = %w[
      image/jpeg
      image/jpg
      image/pjpeg
      image/png
      image/webp
      image/heic
      image/heif
    ].freeze
    MAX_BYTES = 12.megabytes

    def initialize(enhancer: nil, vision: :default, profile: nil)
      @enhancer = enhancer || Enhance.new
      @vision = resolve_vision(vision, profile)
    end

    def call(upload)
      enhanced = nil
      @upload = upload
      validate!(upload)
      enhanced = @enhancer.call(source_path(upload))
      path = ocr_path(enhanced)
      json = @vision.call(path, filename: source_filename)
      raise Error, "Модель не вернула данные накладной." if json.blank?

      Rails.logger.info("[paper] recognized json chars=#{json.length}")
      json
    rescue Enhance::Error => error
      raise Error, error.message
    rescue Recognize::Unavailable => error
      Rails.logger.warn("[paper] vision failed: #{error.message}")
      raise Error, error.message
    ensure
      enhanced.close! if enhanced.respond_to?(:close!)
    end

    private

    def resolve_vision(vision, profile)
      return vision unless vision == :default

      Vision.new(profile: profile)
    end

    def source_filename
      if @upload.respond_to?(:original_filename) && @upload.original_filename.present?
        return @upload.original_filename.to_s
      end

      File.basename(source_path(@upload).to_s)
    end

    def validate!(upload)
      raise Error, "Загрузите фото накладной" if upload.blank?
      raise Error, "Файл больше #{MAX_BYTES / 1.megabyte} МБ — сожмите снимок или пришлите JPEG" if file_size(upload) > MAX_BYTES

      type = content_type(upload)
      return if ALLOWED_TYPES.include?(type)

      raise Error, "Нужен снимок JPEG, PNG или HEIC, не PDF и не документ Word"
    end

    def ocr_path(enhanced)
      enhanced.respond_to?(:path) ? enhanced.path : enhanced.to_s
    end

    def source_path(upload)
      if upload.respond_to?(:path) && upload.path.present?
        upload.path
      elsif upload.respond_to?(:tempfile)
        upload.tempfile.path
      else
        raise Error, "Загрузите фото накладной"
      end
    end

    def file_size(upload)
      return upload.size if upload.respond_to?(:size) && upload.size.to_i.positive?

      File.size(source_path(upload))
    end

    def content_type(upload)
      type = upload.content_type.to_s.downcase if upload.respond_to?(:content_type)
      return type if type.present?

      name = upload.original_filename.to_s if upload.respond_to?(:original_filename)
      name ||= File.basename(source_path(upload))
      Rack::Mime.mime_type(File.extname(name).downcase, "application/octet-stream")
    end
  end
end
