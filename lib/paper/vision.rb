# frozen_string_literal: true

require "base64"

module Paper
  class Vision
    DEFAULT_OLLAMA_MODEL = "qwen2.5vl:7b"
    DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434"
    DEFAULT_OPENAI_URL = "https://api.openai.com/v1"
    DEFAULT_OPENAI_MODEL = "gpt-4o"
    DEFAULT_XAI_URL = "https://api.x.ai/v1"
    DEFAULT_XAI_MODEL = "grok-2-vision-1212"
    DEFAULT_GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta"
    DEFAULT_GEMINI_MODEL = "gemini-2.0-flash"
    MAX_EDGE = 3072
    PROMPT = <<~TEXT.freeze
      Извлеки данные с фото белорусской товарной накладной (ТН/ТТН) или счёта на оплату.
      Верни только JSON без markdown.
      Схема:
      {
        "document_number": "номер ТН рядом с серией или штрихкодом, не УНП",
        "series": "две кириллические буквы серии или null",
        "date": "YYYY-MM-DD",
        "supplier_name": "название организации грузоотправителя",
        "declared_line_count": 0,
        "document_total": 0,
        "total_vat_text": "текст «Всего сумма НДС» как на бланке",
        "items": [
          {"name": "текст из колонки наименование", "unit": "шт", "quantity": 0, "price": 0, "vat_rate": "Без НДС", "vat_amount": null, "amount_with_vat": null}
        ]
      }
      Правила:
      - Бери значения только с фото, не копируй примеры схемы.
      - Если это «Удостоверение качества», а не товарная накладная — сразу верни items: [] и recognition_warnings: ["Это удостоверение качества, а не товарная накладная."]. Не перечисляй изделия.
      - Если это «Счёт на оплату» / «Счет на оплату» — всё равно заполни items из таблицы. document_number — номер счёта. price — колонка «Цена» без НДС. Не оставляй items пустым.
      - name — текст из колонки «Наименование», никогда не голая цена вроде 4.63.
      - Не ставь в name сумму прописью («Сорок четыре рубля»), «Итого», «покупка», «Товарный раздел» или сертификат.
      - Каждая строка товарного раздела — отдельный item, имя с кавычками и граммовкой как в бланке.
      - declared_line_count — фактическое число пронумерованных товарных строк до «Итого».
      - document_total — итог «Всего стоимость с НДС» цифрами. Не сумма НДС и не сумма прописью.
      - price — колонка «Цена» за единицу БЕЗ НДС, не «Стоимость» и не «Стоимость с НДС».
      - vat_rate — колонка «Ставка НДС %» как в ячейке: «Без НДС», «0», «10», «13», «20» или «25». Не заменяй «Без НДС» на 20.
      - 0 / «Без НДС» если в ячейке «Без НДС» / 0%, или в ИТОГО / подвале написано «без НДС» / «НДС не исчисляется» / «Ноль руб.» — тогда 0 у всех строк.
      - Не ставь 20 по умолчанию. Если сумма НДС 0 и «Стоимость с НДС» равна стоимости без НДС — vat_rate 0.
      - vat_amount — колонка «Сумма НДС» (руб. коп.), не ставка. При «без НДС» это 0.
      - amount_with_vat — колонка «Стоимость с НДС». При «без НДС» совпадает с количеством × ценой.
      - total_vat_text — строка «Всего сумма НДС» целиком, как на бланке (например «Ноль руб. 00 коп.»).
      - document_number — номер товарной накладной у серии (ЯЛ/ЯР/ЯМ) или штрихкода, 6–8 цифр. Не УНП и не УПН (9 цифр у грузоотправителя/получателя).
      - supplier_name — поле «Грузоотправитель» (левая колонка), не грузополучатель, не страна, не типография.
      - Пекарня «Честный хлеб», не «Частный хлеб».
      Если поля нет — null. Если строк нет — пустой массив items.
    TEXT
    TABLE_PROMPT = <<~TEXT.freeze
      Это кроп товарного раздела белорусской ТН. Верни только JSON:
      {"declared_line_count":1,"document_total":0,"total_vat_text":"Ноль руб. 00 коп.","items":[{"name":"...","unit":"шт","quantity":0,"price":0,"vat_rate":"Без НДС","vat_amount":null,"amount_with_vat":null}]}
      Каждая строка таблицы до ИТОГО — отдельный item.
      declared_line_count — число товарных строк до ИТОГО. document_total — итог стоимости с НДС цифрами.
      name — полное наименование с кавычками и граммами как в бланке, не число из колонки «Цена».
      Не включай ИТОГО, сумму прописью, «Товарный раздел» и сертификаты.
      Если это удостоверение качества без цен — верни {"items":[],"total_vat_text":null}.
      price — колонка Цена за единицу БЕЗ НДС, не стоимость строки и не сумма с НДС.
      vat_rate — текст ячейки «Ставка НДС %»: «Без НДС», «0», «10», «13», «20» или «25». Не подставляй 20 вместо «Без НДС».
      0 если в ячейке «Без НДС» / 0% или в ИТОГО написано «без НДС» / «Ноль руб.» — тогда 0 у всех строк, не 20.
      Если «Стоимость с НДС» равна стоимости без НДС, vat_rate 0 и vat_amount 0.
      vat_amount — колонка «Сумма НДС». amount_with_vat — «Стоимость с НДС».
      total_vat_text — «Всего сумма НДС» или ИТОГО сумма НДС как на бланке, дословно.
      Не извлекайте грузоотправителя из товарного раздела.
      Не пропускай строки. Не копируй примеры.
    TEXT
    HEADER_PROMPT = <<~TEXT.freeze
      Это шапка белорусской товарной накладной. Верни только JSON:
      {"document_number":"номер ТН у серии или штрихкода","series":"две буквы серии или null","date":"YYYY-MM-DD","supplier_name":"грузоотправитель"}
      document_number — поле «Товарная накладная» / серия+номер / штрихкод, обычно 6–8 цифр. Не УНП и не УПН (9 цифр рядом с грузоотправителем или грузополучателем).
      supplier_name — поле «Грузоотправитель» в левой колонке шапки: ООО/ЧУП/ИП и название в кавычках.
      Не бери «Грузополучателя» (правая колонка), не страну, не УНП, не адрес, не типографию, не «экз. грузоотправителю».
      Если написано «Общество с ограниченной ответственностью», сократи до ООО.
      Пекарня называется «Честный хлеб», не «Частный хлеб».
      Дата накладной — строка вида «20 августа 2026 г.», не постановление 2016 года.
      Бери значения только с фото.
    TEXT
    COMPOSITE_PROMPT = <<~TEXT.freeze
      #{PROMPT}
      Изображение составное: сверху шапка накладной, снизу товарный раздел.
      Области могут частично повторяться — не дублируй товарные строки.
      Прочитай оба блока за один проход.
    TEXT
    PAYMENT_PROMPT = <<~TEXT.freeze
      Это счёт на оплату или таблица цен поставщика, не товарная накладная.
      Верни только JSON без markdown.
      Схема:
      {
        "document_number": "номер счёта как на бланке, например b2b_6652",
        "series": null,
        "date": "YYYY-MM-DD",
        "supplier_name": "продавец / поставщик",
        "declared_line_count": 0,
        "document_total": 0,
        "total_vat_text": "текст итога НДС или null",
        "items": [
          {"name": "наименование", "unit": "шт", "quantity": 0, "price": 0, "vat_rate": "20", "vat_amount": null, "amount_with_vat": null}
        ]
      }
      Правила:
      - Прочитай ВСЕ строки таблицы до «Итого» / «Всего к оплате».
      - name — колонка «Наименование» целиком, с кавычками и фасовкой.
      - unit — единица (шт, кг, уп).
      - quantity — количество.
      - price — цена за единицу БЕЗ НДС.
      - vat_rate — ставка НДС строки: 20, 10, 0 или «Без НДС». На счетах Империи Кофе обычно 20.
      - vat_amount — сумма НДС строки.
      - amount_with_vat — стоимость с НДС.
      - document_number — номер счёта как напечатан (b2b_6652), не УНП.
      - date — дата счёта.
      - supplier_name — продавец (ООО «Империя Кофе»), не покупатель.
      - document_total — итого к оплате с НДС.
      - Не ищи серию ТН и штрихкод накладной.
      - Это не удостоверение качества: не оставляй items пустым.
      - Не пропускай строки. Не копируй примеры.
    TEXT
    PAYMENT_FILENAME = /
      сч[её]т |
      schet |
      b2b[_-] |
      импери[яи].*кофе |
      \AIMAGE[-_\s]+\d{4}
    /ix

    def self.default_provider
      return :openai if openai_key.present?
      return :gemini if gemini_key.present?

      :ollama
    end

    def self.openai_key
      ENV["PAPER_VISION_API_KEY"].presence || ENV["OPENAI_API_KEY"].presence || ENV["XAI_API_KEY"].presence
    end

    def self.gemini_key
      ENV["GEMINI_API_KEY"].presence || ENV["GOOGLE_API_KEY"].presence
    end

    def self.payment_scan?(filename)
      File.basename(filename.to_s).match?(PAYMENT_FILENAME)
    end

    def self.request_timeout(provider = default_provider)
      explicit = ENV["PAPER_VISION_TIMEOUT"].to_i
      return explicit if explicit.positive?

      provider.to_sym == :ollama ? 2100 : 400
    end

    def initialize(url: nil, model: nil, connection: nil, api_key: nil, provider: nil, profile: nil)
      @provider = (provider || self.class.default_provider).to_sym
      @profile = Integer(profile, exception: false)
      @api_key = api_key.presence || key_for_provider
      @url = url.presence || url_for_provider
      @model = model.presence || model_for_provider
      @connection = connection || default_connection
    end

    def call(image_path, filename: nil)
      @source_name = filename.presence || File.basename(image_path.to_s)
      case @provider
      when :openai then call_openai(image_path)
      when :gemini then call_gemini(image_path)
      else call_ollama(image_path)
      end
    ensure
      @source_name = nil
    end

    private

    def call_ollama(image_path)
      return recognize_profile(image_path) if @profile
      return parse_success!(post_ollama(document_prompt, image_path), ollama: true) if payment_scan?

      crops = nil
      crops = Crops.new(composite: ollama_composite?).call(image_path) if ollama_crops?
      if crops&.usable?
        if ollama_composite? && crops.composite.present?
          parse_success!(post_ollama(COMPOSITE_PROMPT, crops.composite), ollama: true)
        else
          recognize_from_crops(crops)
        end
      else
        parse_success!(post_ollama(document_prompt, image_path), ollama: true)
      end
    rescue Faraday::TimeoutError
      raise Recognize::Unavailable, "Распознавание не успело за отведённое время. Черновик останется на проверку, если строки уже есть."
    rescue Faraday::ConnectionFailed, Faraday::SSLError => error
      raise Recognize::Unavailable, "Ollama недоступна (#{error.class.name.demodulize}). Запустите ollama serve и ollama pull #{@model}."
    rescue Faraday::Error => error
      raise Recognize::Unavailable, "Не удалось обратиться к Ollama: #{error.message}"
    ensure
      crops&.cleanup
    end

    # Attempt 1 reads the header and table crops separately — each crop keeps
    # its own resolution, which is what makes Cyrillic item names legible.
    # Later attempts fall back to the whole page for photos where the crop
    # bands miss the table.
    def recognize_profile(image_path)
      if payment_scan? || @profile.to_i >= 2
        return parse_success!(post_ollama(document_prompt, image_path), ollama: true)
      end

      crops = Crops.new(composite: ollama_composite?).call(image_path)
      return parse_success!(post_ollama(document_prompt, image_path), ollama: true) unless crops.usable?

      if ollama_composite? && crops.composite.present?
        parse_success!(post_ollama(COMPOSITE_PROMPT, crops.composite), ollama: true)
      else
        recognize_from_crops(crops)
      end
    ensure
      crops&.cleanup
    end

    def recognize_from_crops(crops)
      items_json = parse_success!(
        post_ollama(
          TABLE_PROMPT,
          crops.table,
          format: InvoiceSchema.items_json_schema,
          keep_alive: ollama_crop_keep_alive
        ),
        ollama: true
      )
      header = {}
      if crops.header.present?
        begin
          header = parse_object(
            post_ollama(HEADER_PROMPT, crops.header, format: InvoiceSchema.header_json_schema)
          )
        rescue Recognize::Unavailable
          header = {}
        end
      end
      merge_vision(header, items_json)
    end

    def post_ollama(
      prompt,
      image_path,
      prepare: true,
      format: InvoiceSchema.json_schema,
      keep_alive: ollama_keep_alive
    )
      payload = {
        model: @model,
        stream: false,
        format:,
        keep_alive:,
        options: { temperature: 0, num_ctx: ollama_num_ctx },
        messages: [
          {
            role: "user",
            content: prompt,
            images: [ encoded_image(image_path, prepare: prepare) ]
          }
        ]
      }

      @connection.post("/api/chat") { |request| request.body = payload }
    end

    def parse_object(response)
      unless response.success?
        raise Recognize::Unavailable, model_missing_message(response)
      end

      content = extract_content(response.body)
      stripped = content.to_s.strip.sub(/\A```(?:json)?/i, "").sub(/```\z/, "").strip
      parsed = JSON.parse(stripped)
      parsed.is_a?(Hash) ? parsed.stringify_keys : {}
    rescue JSON::ParserError
      {}
    end

    def merge_vision(header, items_json)
      items = JSON.parse(items_json)
      header = header.stringify_keys
      merged = {
        "document_number" => header["document_number"].presence || items["document_number"],
        "series" => header["series"].presence || items["series"],
        "date" => header["date"].presence || items["date"],
        "supplier_name" => header["supplier_name"].presence || items["supplier_name"],
        "declared_line_count" => items["declared_line_count"],
        "document_total" => items["document_total"],
        "total_vat_text" => items["total_vat_text"],
        "items" => items["items"]
      }
      extract_json(merged.to_json)
    end

    def call_openai(image_path)
      payload = {
        model: @model,
        temperature: 0,
        response_format: { type: "json_object" },
        messages: [
          {
            role: "user",
            content: [
              { type: "text", text: document_prompt },
              { type: "image_url", image_url: { url: "data:image/jpeg;base64,#{encoded_image(image_path)}" } }
            ]
          }
        ]
      }

      response = @connection.post("/chat/completions") do |request|
        request.headers["Authorization"] = "Bearer #{@api_key}" if @api_key.present?
        request.body = payload
      end
      parse_success!(response)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => error
      raise Recognize::Unavailable, "Облачный vision недоступен (#{error.class.name.demodulize}). Проверьте PAPER_VISION_API_KEY и сеть."
    rescue Faraday::Error => error
      raise Recognize::Unavailable, "Не удалось обратиться к vision API: #{error.message}"
    end

    def call_gemini(image_path)
      response = @connection.post("/models/#{@model}:generateContent") do |request|
        request.params["key"] = @api_key if @api_key.present?
        request.body = {
          contents: [
            {
              role: "user",
              parts: [
                { text: document_prompt },
                { inline_data: { mime_type: "image/jpeg", data: encoded_image(image_path) } }
              ]
            }
          ],
          generationConfig: { temperature: 0, responseMimeType: "application/json" }
        }
      end
      parse_success!(response)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => error
      raise Recognize::Unavailable, "Gemini недоступен (#{error.class.name.demodulize}). Проверьте GEMINI_API_KEY."
    rescue Faraday::Error => error
      raise Recognize::Unavailable, "Не удалось обратиться к Gemini: #{error.message}"
    end

    def parse_success!(response, ollama: false)
      unless response.success?
        raise Recognize::Unavailable, ollama ? model_missing_message(response) : cloud_error_message(response)
      end

      json = extract_json(extract_content(response.body))
      raise Recognize::Unavailable, "Модель не вернула JSON накладной" if json.blank?

      json
    end

    def encoded_image(image_path, prepare: true)
      prepared = nil
      path = image_path.to_s
      if prepare
        prepared = prepare_image(image_path)
        path = prepared.respond_to?(:path) ? prepared.path : prepared.to_s
      end
      Base64.strict_encode64(File.binread(path))
    ensure
      prepared.close! if prepared.respond_to?(:close!) && path != image_path.to_s
    end

    def prepare_image(image_path)
      edge = @provider == :ollama ? ollama_max_edge : MAX_EDGE
      ImageProcessing::MiniMagick
        .source(image_path)
        .auto_orient
        .resize_to_limit(edge, edge)
        .convert("jpg")
        .saver(quality: 85)
        .call
    rescue StandardError
      image_path
    end

    def extract_content(body)
      body = JSON.parse(body) if body.is_a?(String)
      data = body.respond_to?(:deep_symbolize_keys) ? body.deep_symbolize_keys : body
      content = data.dig(:choices, 0, :message, :content) ||
                data.dig(:message, :content) ||
                data.dig(:candidates, 0, :content, :parts, 0, :text)
      content.is_a?(Hash) ? content.to_json : content.to_s
    end

    def extract_json(content)
      InvoiceSchema.normalize_json(content)
    end

    def key_for_provider
      case @provider
      when :openai then self.class.openai_key
      when :gemini then self.class.gemini_key
      end
    end

    def url_for_provider
      configured = ENV["PAPER_VISION_URL"].presence
      case @provider
      when :openai
        configured || (xai_only? ? DEFAULT_XAI_URL : DEFAULT_OPENAI_URL)
      when :gemini
        configured || DEFAULT_GEMINI_URL
      else
        configured || ENV.fetch("OLLAMA_URL", DEFAULT_OLLAMA_URL)
      end
    end

    def model_for_provider
      cloud = ENV["PAPER_VISION_CLOUD_MODEL"].presence
      case @provider
      when :openai
        cloud || ENV["PAPER_VISION_MODEL"].presence || (xai_only? ? DEFAULT_XAI_MODEL : DEFAULT_OPENAI_MODEL)
      when :gemini
        cloud || ENV["PAPER_VISION_MODEL"].presence || DEFAULT_GEMINI_MODEL
      else
        ENV.fetch("PAPER_VISION_MODEL", DEFAULT_OLLAMA_MODEL)
      end
    end

    def xai_only?
      ENV["XAI_API_KEY"].present? && ENV["PAPER_VISION_API_KEY"].blank? && ENV["OPENAI_API_KEY"].blank?
    end

    def ollama_num_ctx
      ENV.fetch("PAPER_VISION_NUM_CTX", "4096").to_i
    end

    def ollama_max_edge
      ENV.fetch("PAPER_VISION_MAX_EDGE", "1280").to_i
    end

    # 7b weights ~6 GiB; CLIP + activations need another ~2 GiB. Pinning the
    # model with keep_alive leaves ~0.5 GiB and the next photo dies.
    def ollama_keep_alive
      ENV.fetch("PAPER_VISION_KEEP_ALIVE", "0")
    end

    def ollama_crop_keep_alive
      ENV.fetch("PAPER_VISION_CROP_KEEP_ALIVE", "2m")
    end

    def payment_scan?
      self.class.payment_scan?(@source_name)
    end

    def document_prompt
      payment_scan? ? PAYMENT_PROMPT : PROMPT
    end

    def ollama_crops?
      ENV.fetch("PAPER_VISION_CROPS", "1") != "0"
    end

    def ollama_composite?
      ENV.fetch("PAPER_VISION_COMPOSITE", "0") != "0"
    end

    def ollama_low_ram_message
      "Ollama не смогла загрузить #{@model}: не хватает RAM под веса и картинку. " \
        "Подключите файл подкачки: sudo swapon ~/.cache/varka-ollama.swap"
    end

    def model_missing_message(response)
      detail = ollama_error_detail(response)
      if response.status == 404
        return "Vision-модель #{@model} не установлена. В терминале: ollama pull #{@model}."
      end
      if detail.match?(/DeviceLost|Not enough memory for command submission/i)
        return "Vega iGPU не тянет #{@model} (Vulkan DeviceLost). Нужен CPU: OLLAMA_IGPU_ENABLE=0 и OLLAMA_VULKAN=0."
      end
      if detail.match?(/exceed_context_size|exceeds the available context size/i)
        return "Снимок не влез в контекст модели (#{ollama_num_ctx} токенов). Увеличьте PAPER_VISION_NUM_CTX."
      end
      if response.status == 500 || detail.match?(/signal: killed|out of memory|unexpected EOF/i)
        return ollama_low_ram_message
      end

      return "Ollama ответила #{response.status}." if detail.blank?

      "Ollama ответила #{response.status}: #{detail.to_s.truncate(180)}"
    end

    def ollama_error_detail(response)
      body = response.body
      body = JSON.parse(body) if body.is_a?(String)
      return body["error"].to_s if body.is_a?(Hash) && body["error"]
      return body[:error].to_s if body.is_a?(Hash) && body[:error]

      body.to_s
    rescue JSON::ParserError
      response.body.to_s
    end

    def cloud_error_message(response)
      if response.status == 401 || response.status == 403
        return "Ключ vision API отклонён. Проверьте PAPER_VISION_API_KEY или GEMINI_API_KEY."
      end

      "Vision API ответил #{response.status}."
    end

    def default_connection
      Faraday.new(url: @url) do |faraday|
        faraday.request :json
        faraday.response :json, content_type: /\bjson/
        faraday.adapter Faraday.default_adapter
        faraday.options.timeout = self.class.request_timeout(@provider)
        faraday.options.open_timeout = 8
      end
    end
  end
end
