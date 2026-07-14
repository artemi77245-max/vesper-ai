# Vesper — мультимодельный AI-ассистент

Пет-проект: десктопный AI-ассистент с интерфейсом на Flutter и бэкендом на Python (FastAPI).
Общение с несколькими LLM через один интерфейс, стриминг ответов в реальном времени.

> Статус: в активной разработке. Личный учебный проект, не production-решение.

## Что работает

- Интерфейс на Flutter с кастомным анимированным орбом (GLSL-шейдер)
- Стриминг ответов от модели через WebSocket
- Бэкенд на FastAPI с маршрутизацией запросов между моделями
- Переключение моделей из интерфейса
- Память диалога между сессиями

## В разработке / планах

- Удалённое выполнение Python-кода в песочнице (пока не активировано)
- (допиши честно, что ещё в процессе)

## Стек

**Frontend:** Flutter, Riverpod, GLSL-шейдер
**Backend:** Python, FastAPI, uvicorn, WebSocket, API нейросетей (Groq и др.)

## Структура

vesper/
├── backend/     # FastAPI: маршрутизатор моделей, API
└── frontend/    # Flutter-приложение


## Запуск

### Backend
cd backend
pip install -r requirements.txt
cp .env.example .env      # впиши свои ключи
uvicorn main:app --reload

### Frontend
cd frontend
flutter pub get
flutter run

## Автор

Артём — разработчик. Учусь и делаю проекты на Python и Flutter.
Telegram: @raydennwq0
