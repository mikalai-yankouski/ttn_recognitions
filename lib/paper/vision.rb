# frozen_string_literal: true

require "base64"
require "json"
require "thread"
require "uri"
require_relative "utf8"

module Paper
  class Vision
    DEFAULT_OLLAMA_MODEL = "qwen2.5vl:7b"
    DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434"
    DEFAULT_OPENAI_URL = "https://api.openai.com/v1"
    DEFAULT_OPENAI_MODEL = "gpt-4o"
    DEFAULT_XAI_URL = "https://api.x.ai/v1"
    DEFAULT_XAI_MODEL = "grok-2-vision-1212"
    DEFAULT_GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/"
    # Lite models only: free Flash non-lite is ~20 RPD and dies under real TTN volume.
    # Chain separate quota buckets so daily load can spill across models.
    DEFAULT_GEMINI_MODEL = "gemini-3.1-flash-lite"
    DEFAULT_GEMINI_FALLBACKS = "gemini-3.5-flash-lite,gemini-2.5-flash-lite"
    DEFAULT_GEMINI_BUDGET = "180"
    OLLAMA_MUTEX = Mutex.new
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
      - Если это «Удостоверение качества», письмо, печать МЧС или любой кадр без товарной таблицы — сразу верни items: [] и recognition_warnings: ["Это не товарная накладная."]. Не выдумывай строки.
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
      Контекст бланка ТН РБ:
      - Серия (ЯЛ/ЯР/ЯМ/ЯН) и номер 6–8 цифр у штрихкода «ТОВАРНАЯ НАКЛАДНАЯ». Не УНП/УПН (9 цифр сверху) и не год формы 2016 («постановление 30.06.2016»).
      - Дата — «16 сентября 2026 г.» рядом с номером, не 2016.
      - Грузоотправитель — ЛЕВАЯ колонка шапки, полное ООО «Название». Справа грузополучатель — не supplier_name. Не оставляй supplier_name как голое «ООО».
      - Колонки: 3 количество, 4 цена без НДС, 5 стоимость, 6 ставка НДС, 7 сумма НДС, 8 стоимость с НДС.
      - amount_with_vat бери только из колонки 8. Если колонка 8 равна колонке 5 — vat_rate для импорта 0, даже если в колонке 6 10/13/20. vat_amount всё равно из колонки 7.
      - document_total — цифры «Всего стоимость с НДС» в подвале, не сумма НДС.
      - Единица может быть «Пор.», «шт», «кг». Прочитай ВСЕ строки до ИТОГО.
      Пример: Круассан Классический, Пор., 2 × 3.70, стоимость 7.40, ставка 13.0951, НДС 0.97, стоимость с НДС 7.40 → vat_rate 0, amount_with_vat 7.40.
      Если поля нет — null. Если строк нет — пустой массив items.
    TEXT
    TABLE_PROMPT = <<~TEXT.freeze
      Это кроп товарного раздела белорусской ТН. Верни только JSON:
      {"declared_line_count":1,"document_total":0,"total_vat_text":"Ноль руб. 00 коп.","items":[{"name":"...","unit":"шт","quantity":0,"price":0,"vat_rate":"Без НДС","vat_amount":null,"amount_with_vat":null}]}
      Каждая строка таблицы до ИТОГО — отдельный item.
      declared_line_count — число товарных строк до ИТОГО. document_total — итог стоимости с НДС цифрами.
      name — полное наименование с кавычками и граммами как в бланке, не число из колонки «Цена».
      Не включай ИТОГО, сумму прописью, «Товарный раздел» и сертификаты.
      Если это удостоверение качества без цен — верни {"items":[],"total_vat_text":null,"recognition_warnings":["Это удостоверение качества, а не товарная накладная."]}.
      price — колонка Цена за единицу БЕЗ НДС, не стоимость строки и не сумма с НДС.
      vat_rate — текст ячейки «Ставка НДС %»: «Без НДС», «0», «10», «13», «20» или «25». Не подставляй 20 вместо «Без НДС».
      0 если в ячейке «Без НДС» / 0% или в ИТОГО написано «без НДС» / «Ноль руб.» — тогда 0 у всех строк, не 20.
      Если колонка «Стоимость с НДС» равна «Стоимость» без НДС — vat_rate 0, даже при 10/13/20 в ставке. Всё равно заполни amount_with_vat из колонки 8.
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
      Дата накладной — строка вида «16 сентября 2026 г.» у номера ТН, не постановление 2016 года и не УНП.
      supplier_name — полное имя в кавычках, не голое «ООО».
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
      return :gemini if gemini_key.present?
      return :openai if openai_key.present?

      :ollama
    end

    def self.openai_key
      ENV["PAPER_VISION_API_KEY"].presence || ENV["OPENAI_API_KEY"].presence || ENV["XAI_API_KEY"].presence
    end

    def self.gemini_key
      ENV["GEMINI_API_KEY"].presence || ENV["GOOGLE_API_KEY"].presence
    end

    def self.payment_scan?(filename)
      File.basename(Utf8.string(filename)).match?(PAYMENT_FILENAME)
    end

    def self.request_timeout(provider = default_provider)
      explicit = ENV["PAPER_VISION_TIMEOUT"].to_i
      return explicit if explicit.positive?

      case provider.to_sym
      when :ollama then 2100
      when :gemini then ENV.fetch("PAPER_VISION_GEMINI_TIMEOUT", "45").to_i
      else 400
      end
    end

    def initialize(url: nil, model: nil, connection: nil, api_key: nil, provider: nil, profile: nil, ollama_connection: nil)
      @provider = (provider || self.class.default_provider).to_sym
      @profile = Integer(profile, exception: false)
      @api_key = api_key.presence || key_for_provider
      @url = url.presence || url_for_provider
      @explicit_model = model.present?
      @model = model.presence || model_for_provider
      @ollama_connection = ollama_connection
      @connection = connection || default_connection
    end

    def call(image_path, filename: nil)
      @source_name = filename.presence || File.basename(image_path.to_s)
      return call_openai(image_path) if @provider == :openai

      if gemini_first?
        json = try_gemini(image_path)
        return json if json.present?

        # Ollama almost never returns a usable invoice JSON for us — keep it off
        # unless explicitly re-enabled for offline/dev.
        unless ollama_fallback_enabled?
          raise Recognize::Unavailable,
                "Очередь распознавания сейчас перегружена. Попробуйте ещё раз через минуту."
        end
      end

      ensure_ollama_client!
      with_ollama_slot { call_ollama(image_path) }
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

    def with_ollama_slot
      locked = false
      unless (locked = OLLAMA_MUTEX.try_lock)
        raise Recognize::Unavailable, "Ollama занята другим запросом. Повторю через Gemini."
      end

      yield
    ensure
      OLLAMA_MUTEX.unlock if locked
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

    def gemini_first?
      @provider != :ollama && self.class.gemini_key.present?
    end

    # Default off: local VL model burns the slot and rarely yields a reviewable draft.
    def ollama_fallback_enabled?
      ENV.fetch("PAPER_VISION_OLLAMA_FALLBACK", "0") != "0"
    end

    def try_gemini(image_path)
      skip = {}
      started = monotonic_now
      deadline = started + gemini_budget
      round = 0

      loop do
        round += 1
        remaining = deadline - monotonic_now
        break if remaining <= 0 && round > 1

        gemini_models.each do |model|
          next if skip[model]

          remaining = deadline - monotonic_now
          break if remaining <= 0 && round > 1

          @model = model
          mode = round > 1 ? :crops : :full
          json = call_gemini(image_path, timeout: gemini_call_timeout(remaining), mode: mode)
          elapsed = (monotonic_now - started).round(1)
          Rails.logger.info("[paper] gemini recognized via #{@model} mode=#{mode} round=#{round} after=#{elapsed}s")
          return json
        rescue Recognize::Unavailable => error
          remaining = [ deadline - monotonic_now, 0 ].max.round(1)
          Rails.logger.warn("[paper] gemini #{@model} mode=#{mode} round=#{round} left=#{remaining}s failed: #{error.message}")
          skip[model] = true unless retryable_gemini?(error)
        end

        break if gemini_models.all? { |model| skip[model] }

        remaining = deadline - monotonic_now
        break if remaining <= 0

        delay = [ gemini_retry_sleep, remaining ].min
        sleep(delay) if delay.positive?
      end

      elapsed = (monotonic_now - started).round(1)
      if ollama_fallback_enabled?
        Rails.logger.warn("[paper] gemini unavailable after #{elapsed}s, falling back to ollama")
      else
        Rails.logger.warn("[paper] gemini unavailable after #{elapsed}s (ollama fallback disabled)")
      end
      nil
    end

    def gemini_models
      return [ @model ] if @explicit_model

      primary = ENV["PAPER_VISION_CLOUD_MODEL"].presence || DEFAULT_GEMINI_MODEL
      extras = ENV.fetch("PAPER_VISION_GEMINI_FALLBACKS", DEFAULT_GEMINI_FALLBACKS)
                  .split(",")
                  .map(&:strip)
                  .reject(&:blank?)
      [ primary, *extras ].uniq
    end

    def gemini_budget
      ENV.fetch("PAPER_VISION_GEMINI_BUDGET", DEFAULT_GEMINI_BUDGET).to_f
    end

    def gemini_call_timeout(remaining)
      cap = self.class.request_timeout(:gemini).to_f
      cap = 45 if cap <= 0
      timeout = remaining.positive? ? [ cap, remaining ].min : cap
      timeout.clamp(1, cap)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def gemini_retry_sleep
      ENV.fetch("PAPER_VISION_GEMINI_RETRY_SLEEP", "1.5").to_f
    end

    def gemini_generate_path
      "models/#{@model}:generateContent"
    end

    def gemini_thinking_config
      if @model.to_s.match?(/gemini-3/i)
        { thinkingLevel: "minimal" }
      else
        { thinkingBudget: 0 }
      end
    end

    def retryable_gemini?(error)
      return false if error.message.match?(/ключ vision API отклонён|USER_LOCATION|location is not supported/i)
      return false if error.message.match?(/\b404\b|NOT_FOUND/i)

      true
    end

    def ensure_ollama_client!
      @provider = :ollama
      @model = ENV["PAPER_VISION_OLLAMA_MODEL"].presence || ENV.fetch("PAPER_VISION_MODEL", DEFAULT_OLLAMA_MODEL)
      @url = ENV.fetch("OLLAMA_URL", DEFAULT_OLLAMA_URL)
      @connection = @ollama_connection || default_connection
    end

    def call_gemini(image_path, timeout: nil, mode: :full)
      if mode == :crops
        json = recognize_gemini_crops(image_path, timeout:)
        return json if json.present?
      end

      parse_success!(
        post_gemini(document_prompt, image_path, timeout:, schema: InvoiceSchema.gemini_json_schema),
        quality: true
      )
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => error
      raise Recognize::Unavailable, "Gemini недоступен (#{error.class.name.demodulize}). Проверьте GEMINI_API_KEY."
    rescue Faraday::Error => error
      raise Recognize::Unavailable, "Не удалось обратиться к Gemini: #{error.message}"
    end

    def recognize_gemini_crops(image_path, timeout: nil)
      crops = Crops.new(composite: false).call(image_path)
      return unless crops.usable?

      items_json = parse_success!(
        post_gemini(TABLE_PROMPT, crops.table, timeout:, schema: InvoiceSchema.gemini_items_json_schema)
      )
      header = {}
      if crops.header.present?
        begin
          header = parse_object(
            post_gemini(HEADER_PROMPT, crops.header, timeout:, schema: InvoiceSchema.gemini_header_json_schema)
          )
        rescue Recognize::Unavailable
          header = {}
        end
      end
      json = merge_vision(header, items_json)
      unless gemini_acceptable?(json)
        raise Recognize::Unavailable, "Gemini вернул несогласованную накладную, повторяю"
      end

      json
    ensure
      crops&.cleanup
    end

    def post_gemini(prompt, image_path, timeout: nil, schema: InvoiceSchema.gemini_json_schema)
      @connection.post(gemini_generate_path) do |request|
        request.headers["X-goog-api-key"] = @api_key if @api_key.present?
        request.options.timeout = timeout if timeout
        request.body = {
          contents: [
            {
              role: "user",
              parts: [
                { text: prompt },
                { inline_data: { mime_type: "image/jpeg", data: encoded_image(image_path) } }
              ]
            }
          ],
          generationConfig: {
            temperature: 0,
            maxOutputTokens: 8192,
            responseMimeType: "application/json",
            responseSchema: schema,
            thinkingConfig: gemini_thinking_config
          }
        }
      end
    end

    def parse_success!(response, ollama: false, quality: false)
      unless response.success?
        raise Recognize::Unavailable, ollama ? model_missing_message(response) : cloud_error_message(response)
      end

      raw = extract_content(response.body)
      json = extract_json(raw)
      if json.blank?
        parsed = InvoiceSchema.parse(raw)
        names = Array(parsed.is_a?(Hash) ? parsed["items"] || parsed[:items] : []).first(8)
        names = names.map { |row| row.is_a?(Hash) ? row.stringify_keys["name"] : row.to_s.truncate(40) }
        snippet = Utf8.string(raw).gsub(/\s+/, " ").truncate(180)
        Rails.logger.warn("[paper] empty invoice json finish=#{gemini_finish_reason(response.body)} names=#{names.inspect} snippet=#{snippet.inspect}")
        raise Recognize::Unavailable, parsed.is_a?(Hash) ? "Gemini вернул несогласованную накладную, повторяю" : "Модель не вернула JSON накладной"
      end
      if quality && !gemini_acceptable?(json)
        raise Recognize::Unavailable, "Gemini вернул несогласованную накладную, повторяю"
      end

      json
    end

    def gemini_acceptable?(json)
      parsed = InvoiceSchema.parse(json)
      return false unless parsed.is_a?(Hash)

      parsed = parsed.stringify_keys
      warnings = Array(parsed["recognition_warnings"])
      return true if warnings.any? { |warning|
        warning.to_s.match?(/удостоверен|не товарн|отсутствуют товарный раздел|это не накладн/i)
      }

      items = Array(parsed["items"])
      return false if items.empty?
      return false if parsed["date"].to_s.match?(/\A2016/)
      return false if parsed["supplier_name"].to_s.squish.match?(/\A(?:ооо|оао|зао|чуп|ип)\.?\z/i)
      return false if warnings.any? { |warning|
        warning.to_s.match?(/итог по строкам|количество не распознано|цена не распознана/i)
      }

      true
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
      data = gemini_payload(body)
      content = data.dig(:choices, 0, :message, :content) ||
                data.dig(:message, :content) ||
                gemini_parts_text(data)
      content.is_a?(Hash) ? content.to_json : content.to_s
    end

    def gemini_payload(body)
      body = JSON.parse(body) if body.is_a?(String)
      body.respond_to?(:deep_symbolize_keys) ? body.deep_symbolize_keys : body
    end

    def gemini_parts_text(data)
      parts = Array(data.dig(:candidates, 0, :content, :parts))
      return if parts.blank?

      visible = parts.filter_map { |part| gemini_part_text(part) unless thought_part?(part) }
      return visible.join if visible.any?

      parts.filter_map { |part| gemini_part_text(part) }.join.presence
    end

    def gemini_part_text(part)
      return unless part.is_a?(Hash)

      text = part[:text]
      return text if text.present?
      return part.except(:thought, :thought_signature).to_json if part[:items] || part[:document_number]

      nil
    end

    def thought_part?(part)
      part.is_a?(Hash) && part[:thought] == true
    end

    def gemini_finish_reason(body)
      gemini_payload(body).dig(:candidates, 0, :finishReason).presence ||
        gemini_payload(body).dig(:promptFeedback, :blockReason)
    rescue StandardError
      nil
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
        url = configured || DEFAULT_GEMINI_URL
        url.end_with?("/") ? url : "#{url}/"
      else
        configured || ENV.fetch("OLLAMA_URL", DEFAULT_OLLAMA_URL)
      end
    end

    def model_for_provider
      cloud = ENV["PAPER_VISION_CLOUD_MODEL"].presence
      case @provider
      when :openai
        cloud || (xai_only? ? DEFAULT_XAI_MODEL : DEFAULT_OPENAI_MODEL)
      when :gemini
        cloud || DEFAULT_GEMINI_MODEL
      else
        ENV["PAPER_VISION_OLLAMA_MODEL"].presence || ENV.fetch("PAPER_VISION_MODEL", DEFAULT_OLLAMA_MODEL)
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
      detail = google_error_detail(response)
      if response.status == 401 || response.status == 403
        return "Ключ vision API отклонён. Проверьте PAPER_VISION_API_KEY или GEMINI_API_KEY."
      end
      if response.status == 503
        return "Gemini 503 очередь #{@model}. #{detail}".squish.truncate(200)
      end

      suffix = detail.present? ? ": #{detail}" : "."
      "Vision API ответил #{response.status}#{suffix}".truncate(200)
    end

    def google_error_detail(response)
      body = response.body
      body = JSON.parse(body) if body.is_a?(String)
      return "" unless body.is_a?(Hash)

      err = body["error"] || body[:error]
      return err.to_s if err.is_a?(String)
      return err["message"].to_s if err.is_a?(Hash) && err["message"]
      return err[:message].to_s if err.is_a?(Hash) && err[:message]

      ""
    rescue JSON::ParserError
      ""
    end

    def default_connection
      options = { url: @url }
      if local_url?(@url)
        options[:proxy] = nil
      elsif (proxy = proxy_url).present?
        options[:proxy] = proxy
      end

      Faraday.new(**options) do |faraday|
        faraday.request :json
        faraday.response :json, content_type: /\bjson/, parser_options: { decoder: [ JsonBody, :parse ] }
        faraday.adapter Faraday.default_adapter
        faraday.options.timeout = self.class.request_timeout(@provider)
        faraday.options.open_timeout = 8
      end
    end

    # json 3 only takes keyword options; Faraday still calls JSON.parse(body, {}).
    module JsonBody
      def self.parse(body, _options = nil)
        JSON.parse(body)
      end
    end
    private_constant :JsonBody

    def proxy_url
      ENV["HTTPS_PROXY"].presence || ENV["https_proxy"].presence || ENV["HTTP_PROXY"].presence || ENV["http_proxy"].presence
    end

    def local_url?(url)
      host = URI.parse(url.to_s).host.to_s
      host.empty? || host == "localhost" || host == "127.0.0.1" || host == "::1"
    rescue URI::InvalidURIError
      false
    end
  end
end
