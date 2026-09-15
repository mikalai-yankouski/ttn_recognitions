# ttn

Микросервис распознавания товарных накладных (ТН/ТТН) для [Varka](https://github.com/mikalai-yankouski/varka). Держит Ollama vision; Varka шлёт фото и подпись тенанта, получает JSON и дальше сама матчит товары в QuickResto.

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
ollama pull qwen2.5vl:7b
bin/dev
```

`bin/dev` поднимает Ollama (если ещё не запущена) и ttn на `localhost:3000` — в этот порт смотрит cloudpub. Туннель отдельно: `clo run`. Ctrl-C гасит ttn и ту Ollama, которую скрипт сам запустил.

Или `docker compose up --build`. После первого старта: `docker compose exec ollama ollama pull qwen2.5vl:7b`.

Тесты: `bin/test`
