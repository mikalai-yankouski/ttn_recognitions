# frozen_string_literal: true

module Paper
  class Enhance
    class Error < StandardError; end

    MAX_EDGE = 2200

    def initialize(upright: nil, force_landscape: false)
      @upright = upright
      @force_landscape = force_landscape
    end

    def call(path)
      if vips?
        enhance_with_vips(path)
      else
        enhance_with_mini_magick(path)
      end
    rescue Error
      raise
    rescue StandardError => error
      raise Error, "Не удалось прочитать снимок (#{error.class.name.demodulize}). Сохраните фото как JPEG и попробуйте снова."
    end

    private

    def vips?
      return @vips if defined?(@vips)

      require "image_processing/vips"
      @vips = true
    rescue LoadError
      @vips = false
    end

    def enhance_with_vips(path)
      pipeline = ImageProcessing::Vips
        .source(path)
        .loader(autorot: true)
      pipeline = rotate_if_sideways(pipeline, path)
      pipeline
        .resize_to_limit(MAX_EDGE, MAX_EDGE)
        .convert("jpg")
        .saver(quality: 92)
        .call
    end

    def enhance_with_mini_magick(path)
      require "image_processing/mini_magick"

      pipeline = ImageProcessing::MiniMagick
        .source(path)
        .auto_orient
      pipeline = rotate_if_sideways(pipeline, path)
      pipeline
        .resize_to_limit(MAX_EDGE, MAX_EDGE)
        .convert("jpg")
        .call
    end

    def rotate_if_sideways(pipeline, path)
      degrees = (@upright || Upright.new).degrees(path, force_landscape: @force_landscape)
      return pipeline unless degrees.positive?

      pipeline.rotate(degrees)
    end
  end
end
