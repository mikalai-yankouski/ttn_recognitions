# frozen_string_literal: true

require "mini_magick"
require "open3"
require "image_processing/mini_magick"

module Paper
  class Upright
    ANGLES = [ 0, 90, 270 ].freeze
    MIN_WINNING_SCORE = 30
    WIN_RATIO = 1.4
    SAMPLE_EDGE = 640
    # EXIF orientations that store a portrait photo in a landscape frame.
    SIDEWAYS_EXIF = [ 5, 6, 7, 8 ].freeze

    def initialize(scorer: nil, binary: nil)
      @scorer = scorer
      @binary = binary.presence || ENV.fetch("PAPER_OCR_BIN", "tesseract")
    end

    def degrees(path, force_landscape: false)
      scores = ANGLES.index_with { |angle| score(path, angle) }
      if force_landscape && landscape?(path)
        return preferred_sideways(scores)
      end
      if landscape?(path)
        sideways = preferred_sideways(scores)
        return sideways if scores.fetch(sideways) >= scores.fetch(0)
        return sideways if scores.fetch(0) < MIN_WINNING_SCORE
      end

      best_angle, best_score = scores.max_by { |_, value| value }
      return 0 if best_score < MIN_WINNING_SCORE
      return 0 if best_score < scores.fetch(0) * WIN_RATIO

      best_angle
    end

    private

    def landscape?(path)
      width, height = image_size(path)
      width.to_i > height.to_i
    end

    def preferred_sideways(scores)
      [ 90, 270 ].max_by { |angle| scores.fetch(angle) }
    end

    # Scores are measured on an auto-oriented sample, so the frame has to be
    # judged the same way: a phone portrait shot carries landscape pixel
    # dimensions plus an EXIF quarter turn.
    def image_size(path)
      image = open_image(path)
      return [ image.height, image.width ] if sideways_exif?(image)

      [ image.width, image.height ]
    rescue StandardError
      [ 0, 0 ]
    end

    def open_image(path)
      MiniMagick::Image.open(path)
    end

    def sideways_exif?(image)
      SIDEWAYS_EXIF.include?(image.exif["Orientation"].to_i)
    rescue StandardError
      false
    end

    def score(path, angle)
      return @scorer.call(path, angle) if @scorer

      tesseract_cyrillic_score(path, angle)
    rescue StandardError
      0
    end

    INVOICE_WORDS = /накладн|грузоотправ|грузополучател|наименов|товарн|итого|получател|отправител/i

    def self.text_score(text)
      letters = text.to_s.scan(/[А-Яа-яЁё]/).size
      keywords = text.to_s.scan(INVOICE_WORDS).size
      letters + (keywords * 80)
    end

    def tesseract_cyrillic_score(path, angle)
      sample = sampled_variant(path, angle)
      stdout, _stderr, status = Open3.capture3(@binary, sample.path, "stdout", "-l", "rus", "--psm", "6")
      return 0 unless status.success?

      self.class.text_score(stdout)
    ensure
      sample.close! if angle.positive? && sample.respond_to?(:close!)
    end

    def sampled_variant(path, angle)
      base = downscaled(path)
      return base if angle.zero?

      ImageProcessing::MiniMagick
        .source(base.path)
        .rotate(angle)
        .convert("jpg")
        .call
    end

    def downscaled(path)
      @downscaled ||= ImageProcessing::MiniMagick
        .source(path)
        .auto_orient
        .resize_to_limit(SAMPLE_EDGE, SAMPLE_EDGE)
        .convert("jpg")
        .call
    end
  end
end
