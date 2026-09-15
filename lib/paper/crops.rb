# frozen_string_literal: true

require "mini_magick"

module Paper
  class Crops
    MIN_EDGE = 400
    HEADER_RATIO = 0.38
    TABLE_TOP = 0.22
    TABLE_HEIGHT = 0.55

    Result = Struct.new(:header, :table, :composite, :temps, keyword_init: true) do
      def usable?
        table.present? && File.file?(table) && File.size(table).positive?
      end

      def cleanup
        Array(temps).each do |file|
          next unless file
          if file.respond_to?(:close!)
            file.close!
          elsif File.exist?(file.to_s)
            File.delete(file.to_s)
          end
        rescue StandardError
          nil
        end
      end
    end

    def initialize(composite: false)
      @composite = composite
    end

    def call(image_path)
      temps = []
      page = isolate_page(image_path)
      temps << page
      width, height = image_size(page)
      unless width >= MIN_EDGE && height >= MIN_EDGE
        return Result.new(header: nil, table: nil, composite: nil, temps: temps)
      end

      header = crop_band(page, 0, (height * HEADER_RATIO).to_i)
      table = crop_band(page, (height * TABLE_TOP).to_i, (height * TABLE_HEIGHT).to_i)
      composite = append_bands(header, table) if @composite
      temps.concat([ header, table, composite ])
      Result.new(
        header: path_for(header),
        table: path_for(table),
        composite: path_for(composite),
        temps: temps
      )
    rescue StandardError
      Result.new(header: nil, table: nil, composite: nil, temps: temps)
    end

    private

    def isolate_page(image_path)
      tmp = new_temp("paper_page")
      MiniMagick.convert do |convert|
        convert << image_path.to_s
        convert.auto_orient
        convert.gravity "Center"
        convert.crop "98x92%+0+0"
        convert << "+repage"
        convert << tmp.path
      end
      tmp
    end

    def crop_band(page, top, band_height)
      width, height = image_size(page)
      top = top.clamp(0, [ height - 1, 0 ].max)
      band_height = band_height.clamp(1, [ height - top, 1 ].max)
      tmp = new_temp("paper_band")
      MiniMagick.convert do |convert|
        convert << path_for(page)
        convert.crop "#{width}x#{band_height}+0+#{top}"
        convert << "+repage"
        convert << tmp.path
      end
      tmp
    end

    def append_bands(header, table)
      tmp = new_temp("paper_composite")
      MiniMagick.convert do |convert|
        convert << path_for(header)
        convert << path_for(table)
        convert << "-append"
        convert << tmp.path
      end
      tmp
    end

    def new_temp(prefix)
      tmp = Tempfile.new([ prefix, ".jpg" ])
      tmp.binmode
      tmp.close
      tmp
    end

    def path_for(file)
      file.respond_to?(:path) ? file.path : file.to_s
    end

    def image_size(page)
      img = MiniMagick::Image.open(path_for(page))
      [ img.width, img.height ]
    end
  end
end
