# Аудит инфраструктурных затрат и план миграции на Self-Hosted решений (Palmier Pro)

**Дата**: 29 июля 2026 г.  
**Роль**: Staff Software Engineer / Solution Architect  
**Цель**: Полный анализ использования сторонних платных сервисов, SaaS и API в Palmier Pro; разработка плана перевода на self-hosted / open-source альтернативы для максимального снижения ежемесячных затрат при сохранении производительности и надежности.

---

# Executive Summary

Проект **Palmier Pro** представляет собой гибридное решение: клиентское macOS-приложение полностью локально и опенсорсно ([GPLv3](../LICENSE)), однако функции генеративного ИИ, облачной транскрипции, аутентификации, биллинга и телеметрии завязаны на сторонние платные SaaS и облачные провайдеры.

При текущем масштабе потенциальные расходы на облачную инфраструктуру и API при 10 000 MAU / 1 000 активных пользователей генерации составляют **~$2 700 – $13 000 в месяц**. 

Благодаря архитектуре Apple Silicon (M1–M4) и наличию уже включенных в проект нативных библиотек (`mlx-swift`, `speech-swift`, `swift-transformers`), **до 75–85% потенциальных расходов можно сократить**, переведя транскрипцию на 100% on-device, а бэкенд, телеметрию и LLM-агентов — на self-hosted решения (PocketBase/Supabase, GlitchTip, PostHog Self-Hosted, DeepSeek / Qwen 2.5 Coder).

---

## Используемые платные сервисы

| Сервис | Назначение | Можно заменить | Приоритет |
| :--- | :--- | :--- | :--- |
| **Clerk** | Аутентификация, SSO (Google), JWT сессии | Да (PocketBase Auth / Supabase Auth / Custom Go Auth) | P1 |
| **Convex** | Реактивная БД, RPC, подписки, очереди задач | Да (PocketBase / Supabase Self-Hosted + WebSockets) | P1 |
| **Anthropic API** (Claude 3.5/3.7 Sonnet) | LLM-агент для автоматизации редактора | Частично (DeepSeek R1/V3, Qwen 2.5 Coder + Local MLX) | P1 |
| **Cloud Speech API** | Транскрипция аудио в текст/субтитры | **Да (100% local `speech-swift` / `mlx-swift`)** | **P0** |
| **Sentry** | Отслеживание крашей и ошибок | Да (Self-hosted GlitchTip или `os_log`) | P1 |
| **PostHog Cloud** | Продуктовая аналитика и события | Да (Self-hosted PostHog Docker / Umami) | P2 |
| **Generative AI APIs** (Seedance, Kling, Nano Banana) | Генерация видео и изображений | Частично (Self-hosted ComfyUI / RunPod Serverless GPU) | P2 |
| **Stripe** | Эквайринг подписок и покупка кредитов | Оставить (или продублировать через Apple IAP) | P2 |

---

## Возможная экономия

| Сервис | Текущие расходы (эстимейт/мес) | Расходы после миграции (мес) | Ожидаемая экономия | Сложность миграции |
| :--- | :--- | :--- | :--- | :--- |
| **Cloud Transcription API** | $100 – $300 | $0 (On-device Whisper MLX) | **$100 – $300 (100%)** | **Низкая (1-2 дня)** |
| **Sentry Cloud** | $26 – $80 | $0 – $10 (GlitchTip VPS) | **$26 – $70 (85%)** | **Низкая (1 день)** |
| **PostHog Cloud** | $50 – $250 | $15 (Self-hosted Docker) | **$35 – $235 (80%)** | **Низкая (1 день)** |
| **Clerk Auth** | $25 – $100 | $0 (Self-hosted Auth) | **$25 – $100 (100%)** | Средняя (1-2 недели) |
| **Convex Cloud** | $25 – $250 | $15 – $30 (Hetzner VPS) | **$10– $220 (85%)** | Средняя (2 недели) |
| **Anthropic Claude API** | $500 – $2 000 | $50 – $300 (DeepSeek / Local) | **$450 – $1 700 (80%)** | Средняя (3-5 дней) |
| **GenAI Cloud APIs** | $2 000 – $10 000 | $600 – $2 500 (RunPod / Wan2.1) | **$1 400 – $7 500 (70%)** | Высокая (3-4 недели) |
| **ИТОГО** | **$2 726 – $13 080** | **$690 – $2 855** | **$2 036 – $10 225 / мес** | — |

---

## Подробный анализ зависимостей и сервисов

### 1. Аутентификация: Clerk (`clerk-ios`, `clerk-convex-swift`)
* **Где используется**: `AccountService.swift`, `BackendConfig.swift`.
* **Зачем**: Логин пользователей через Google OAuth, управление токенами сессий (JWT) для Convex.
* **Альтернатива**: 
  - **PocketBase Auth** или **Supabase Auth (Self-Hosted)**.
  - Нативный клиент на Swift для OAuth (Google / Apple Sign-In), работающий напрямую с собственным бэкендом.
* **Сроки миграции**: ~1–2 недели.

### 2. Бэкенд и БД: Convex (`convex-swift`)
* **Где используется**: `GenerationBackend.swift`, `TranscriptionBackend.swift`, `BackendStorage.swift`.
* **Зачем**: Реактивная синхронизация статусов генераций, биллинг-планов, загрузка референсных файлов.
* **Альтернатива**:
  - **PocketBase** (Go + SQLite, поддерживающий realtime subscriptions через WebSockets из коробки).
  - **Supabase Self-Hosted** (Postgres + Realtime + Storage).
  - Собственный лёгкий сервис на **Go / FastStream / Node.js** + **MinIO** (для Storage) + **NATS/Redis** (для очередей задач генерации).
* **Сроки миграции**: 2 недели.

### 3. Транскрипция аудио: Cloud Speech vs. Local `BundledSpeech`
* **Где используется**: `TranscriptionBackend.swift`.
* **Зачем**: Автоматическое создание субтитров и поиск пауз/спикеров.
* **Критическое наблюдение**: В `Package.swift` УЖЕ подключен `BundledSpeech` с библиотеками `mlx-swift` и `speech-swift` (Whisper / Voice Activity Detection)!
* **Решение**: Перевести локальную транскрипцию по умолчанию на `BundledSpeech` для всех пользователей Mac. Это даст **100% экономию** на облачных вызовах Whisper и позволит транскрибировать видео офлайн.
* **Сроки замены**: **1–2 дня (Quick Win!)**.

### 4. LLM-Агент: Anthropic API (`AnthropicClient.swift` / `PalmierClient.swift`)
* **Где используется**: `AnthropicClient.swift`, `PalmierClient.swift`.
* **Зачем**: Чат-агент для автоматизации работы с таймлайном (tool calling).
* **Альтернатива**:
  - Добавить поддержку **OpenAI-compatible API** (DeepSeek R1/V3, Qwen 2.5 Coder 32B через DeepInfra / Together AI или self-hosted vLLM). Стоимость вызовов DeepSeek в 10–15 раз ниже, чем Claude 3.5 Sonnet.
  - Локальный провайдер для Mac на `mlx-swift` / `Ollama` (Qwen 2.5 Coder 14B Q4_K_M) для 100% бесплатной офлайн-работы агента.
* **Сроки замены**: **3–4 дня**.

### 5. Телеметрия и аналитика: Sentry & PostHog
* **Где используется**: `Telemetry.swift`, `Analytics.swift`.
* **Зачем**: Логирование крашей и отслеживание действий пользователей.
* **Альтернатива**:
  - **Sentry**: Изменить DSN на self-hosted **GlitchTip** (100% совместим с `sentry-cocoa`).
  - **PostHog**: Поменять `host` в `Analytics.swift` с `app.posthog.com` на собственный инстанс `analytics.palmier.io` (развернутый в Docker).
* **Сроки замены**: **1 день (Quick Win!)**.

---

## Quick Wins (1–2 дня)

### 1. Перевод транскрипции на 100% On-Device (Whisper MLX)
* **Действие**: Изменить логику в `TranscriptionService`, установив приоритет выполнения на локальный `BundledSpeech` (`mlx-swift` / `speech-swift`) вместо обращения к `TranscriptionBackend.submit`.
* **Экономия**: ~$100 – $300 / мес.
* **Срок**: 1 день.

### 2. Переключение Sentry на Self-Hosted GlitchTip
* **Действие**: Поднять контейнер GlitchTip ($5/мес VPS) и указать его DSN в `Info.plist` -> `SentryDSN`.
* **Экономия**: ~$26 – $80 / мес.
* **Срок**: 0.5 дня.

### 3. Переключение PostHog на Self-Hosted Docker
* **Действие**: Развернуть PostHog Open Source или Umami в Docker и прописать URL в `PostHogHost`.
* **Экономия**: ~$50 – $250 / мес.
* **Срок**: 0.5 дня.

---

## Среднесрочные улучшения (1–3 недели)

### 1. Интеграция DeepSeek / Qwen 2.5 Coder для AI-агента
* Реализовать `OpenAICompatibleClient`, позволяющий подключать бэкенды DeepSeek, Groq, DeepInfra или локальный Ollama / MLX.
* Снизит стоимость токенов для работы агента на 80–90%.

### 2. Замена Clerk на Self-Hosted Auth (PocketBase / Supabase)
* Создание собственного единого API аутентификации.
* Устранение ежемесячной платы за Clerk MAU.

### 3. Замена Convex на PocketBase / Supabase Self-Hosted
* Миграция схемы данных (users, generations, billing) на SQLite / PostgreSQL с поддержкой WebSockets.
* Размещение на VPS (Hetzner) стоимостью $15–$30/мес.

---

## Долгосрочные улучшения (1–2 месяца)

### 1. Self-Hosted GPU Cluster для генеративного ИИ (Wan2.1 / LTX-Video / FLUX)
* Переход от сторонних дорогостоящих SaaS API (Kling, Seedance) на собственные графические узлы (RunPod Serverless / Lambda Labs) с запущенными ComfyUI / Diffusers pipelines.
* Снижение себестоимости генерации 5-секундного видео с $0.15–$0.30 до $0.03–$0.05.

### 2. Локальная генерация медиа на Apple Silicon
* Задействование чипов Apple Silicon (M-series) с помощью CoreML / MLX для локальной генерации изображений (SDXL Turbo / FLUX Schnell) и коротких гифок прямо на устройстве пользователя.

---

## План миграции

```
[Фаза 1: Quick Wins] (Дни 1–2)
  ├── 1.1 Отключение платной облачной транскрипции ──► Перевод на BundledSpeech (MLX)
  ├── 1.2 Миграция Sentry DSN ──────────────────────► Self-Hosted GlitchTip
  └── 1.3 Миграция PostHog Host ────────────────────► Self-Hosted PostHog / Umami

[Фаза 2: LLM & Auth] (Недели 1–2)
  ├── 2.1 Внедрение OpenAI-compatible клиента ─────► DeepSeek / Qwen 2.5 Coder
  └── 2.2 Миграция аутентификации Clerk ────────────► Self-Hosted Auth (PocketBase)

[Фаза 3: Backend & Storage] (Недели 2–3)
  ├── 3.1 Замена Convex Realtime ────────────────────► PocketBase / Supabase WebSockets
  └── 3.2 Перевод загрузки файлов ─────────────────► MinIO / Cloudflare R2

[Фаза 4: GenAI Infrastructure] (Месяц 2)
  └── 4.1 Создание RunPod Serverless GPU ──────────► ComfyUI (Wan2.1 / FLUX)
```

---

## Архитектурные рекомендации

```
                               ┌──────────────────────────────────────────────┐
                               │             macOS Client (GPLv3)             │
                               │                                              │
                               │  [On-Device AI Engine]                       │
                               │   • MLX / SpeechVAD (Транскрипция $0)        │
                               │   • SigLIP 2 CoreML (Поиск $0)              │
                               │   • Local LLM / Ollama (Агент $0)            │
                               └──────────────────────┬───────────────────────┘
                                                      │
                                    Self-Hosted REST / WebSocket / Auth API
                                                      │
                                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                   SELF-HOSTED INFRASTRUCTURE                                    │
│                                    (Hetzner / Docker / $35/mo)                                   │
│                                                                                                 │
│   ┌──────────────────────────┐    ┌──────────────────────────┐    ┌──────────────────────────┐  │
│   │ PocketBase / Supabase    │    │ GlitchTip / Sentry       │    │ PostHog Self-Hosted      │  │
│   │  • Auth & User DB        │    │  • Error Tracking        │    │  • Product Analytics     │  │
│   │  • Realtime Job Statuses │    │  • Crash Logs            │    │  • Telemetry Events      │  │
│   └────────────┬─────────────┘    └──────────────────────────┘    └──────────────────────────┘  │
│                │                                                                                │
│                ▼                                                                                │
│   ┌──────────────────────────┐                                                                  │
│   │ RunPod GPU Cluster       │                                                                  │
│   │  • ComfyUI / Wan2.1      │                                                                  │
│   │  • FLUX / LTX-Video      │                                                                  │
│   └──────────────────────────┘                                                                  │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Приоритеты

* **P0 — Заменить немедленно**:
  - Облачная транскрипция `TranscriptionBackend.swift` $\rightarrow$ Переключить на нативный `BundledSpeech`.
* **P1 — Заменить в ближайшее время**:
  - Telemetry & Analytics DSN/Host $\rightarrow$ Self-hosted GlitchTip & PostHog.
  - LLM-провайдер `PalmierClient.swift` $\rightarrow$ Добавить поддержку DeepSeek R1 / V3 / Qwen.
  - Auth (Clerk) и Backend (Convex) $\rightarrow$ Self-hosted PocketBase/Supabase.
* **P2 — Можно оставить / Мигрировать позже**:
  - Эквайринг Stripe (оставить или продублировать Apple IAP).
  - Сторонние GenAI API (Seedance, Kling) — переводить на собственные GPU по мере роста числа сгенерированных видео.
