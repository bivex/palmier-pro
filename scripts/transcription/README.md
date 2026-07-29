# Whisper Large V3 Turbo (MLX Format) Integration

Локальный скрипт и конфигурация для быстрой транскрипции аудиофайлов с использованием модели **Whisper Large V3 Turbo** с аппаратным ускорением Apple Silicon (MLX).

## Установка зависимостей

```bash
# Создание виртуального окружения Python
python3 -m venv venv
source venv/bin/activate

# Установка MLX Whisper
pip install mlx-whisper
```

## Использование

### Базовый запуск:

```bash
python scripts/transcription/transcribe.py /path/to/audio.mp3
```

### Параметры:

```bash
# Указать язык (например, uk, ru, en, es)
python scripts/transcription/transcribe.py audio.mp3 -l uk

# Перевод на английский язык
python scripts/transcription/transcribe.py audio.mp3 -t translate

# Сохранить полный JSON-результат со словарем таймкодов слов
python scripts/transcription/transcribe.py audio.mp3 -o result.json
```

## Конфигурация модели
Модель по умолчанию: `mlx-community/whisper-large-v3-turbo` (1.6 ГБ, ускорение через Metal / Neural Engine).
