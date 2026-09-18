# ttn

Микросервис распознавания товарных накладных (ТН/ТТН) для [Varka](https://github.com/mikalai-yankouski/varka). По умолчанию читает фото через **Gemini Lite** (`gemini-3.1-flash-lite` → `gemini-3.5-flash-lite` → `gemini-2.5-flash-lite`). Обычный Flash (~20 RPD на free tier) в цепочку не ставим. Локальный Ollama — опциональный fallback (`PAPER_VISION_OLLAMA_FALLBACK=1`), для продакшена обычно выключен. Varka шлёт фото и подпись тенанта, получает JSON и дальше сама матчит товары в QuickResto.

Для стабильных **~600–1000 ТН/день** на free tier мало (Lite ≈ 500 RPD на модель): включите billing в AI Studio (Tier 1+). Без биллинга объём держится только за счёт spillover между Lite-моделями и легко ломается на ретраях.

Публичный туннель (dev): `https://maladroitly-social-worm.cloudpub.ru/`

## Запрос

`POST /v1/recognize` (multipart)

| Поле / заголовок | Значение |
|---|---|
| `image` | файл JPEG/PNG/WEBP/HEIC |
| `X-Ttn-Tenant` | slug тенанта |
| `X-Ttn-Issued-At` | unix time |
| `X-Ttn-Signature` | HMAC-SHA256(`secret`, `slug\\nissued_at\\nsha256(bytes)`) hex |

Ответ — JSON схемы Paper vision (`document_number`, `date`, `supplier_name`, `items[]` …) плюс `tenant_slug`.

`GET /up` — здоровье.

## Право тенанта

Два слоя:

1. Varka не подписывает запрос, если у `Tenant` выключено `invoice_import_enabled` или статус не `active`.
2. ttn сверяет HMAC общим секретом `TTN_HMAC_SECRET` и slug со списком `TTN_ALLOWED_SLUGS`. Пустой список никого не пускает. `*` пускает любой валидный slug.

## Локально

```bash
bundle install
cp .env.example .env
# В .env: GEMINI_API_KEY=... (и HTTPS_PROXY, если нужен из BY)
bin/dev
```

`bin/dev` поднимает ttn (порт из `PORT`). Туннель отдельно: `clo run`. Ollama не нужна, пока не включён `PAPER_VISION_OLLAMA_FALLBACK=1`.

Тесты: `bin/test`
