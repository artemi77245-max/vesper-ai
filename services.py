import os
import re
import httpx
from openai import AsyncOpenAI
from dotenv import load_dotenv

load_dotenv()


groq_client = AsyncOpenAI(
    base_url="https://api.groq.com/openai/v1",
    api_key=os.getenv("GROQ_API_KEY", ""),
)

google_client = AsyncOpenAI(
    base_url="https://generativelanguage.googleapis.com/v1beta/openai/",
    api_key=os.getenv("GEMINI_API_KEY", ""),
)

cerebras_client = AsyncOpenAI(
    base_url="https://api.cerebras.ai/v1",
    api_key=os.getenv("CEREBRAS_API_KEY", ""),
)

_openrouter_proxy = os.getenv("OPENROUTER_PROXY")
_openrouter_http_client = httpx.AsyncClient(
    proxy=_openrouter_proxy,
    timeout=httpx.Timeout(60.0, connect=15.0),
) if _openrouter_proxy else None

openrouter_client = AsyncOpenAI(
    base_url="https://openrouter.ai/api/v1",
    api_key=os.getenv("OPENROUTER_API_KEY", ""),
    http_client=_openrouter_http_client,
    default_headers={
        "HTTP-Referer": os.getenv("OPENROUTER_REFERER", "https://vesper.app"),
        "X-Title": "Vesper AI Backend",
    },
)


VESPER_MODELS = {
    "spark": {"client": groq_client, "model": "llama-3.1-8b-instant"},
    "nova": {"client": google_client, "model": "gemini-flash-latest"},
    "zenith": {"client": cerebras_client, "model": "gpt-oss-120b"},
    "quantum": {"client": groq_client, "model": "openai/gpt-oss-120b"},
    "fable": {"client": openrouter_client, "model": "anthropic/claude-3.5-sonnet"},
}

UTILITY_MODEL = "llama-3.1-8b-instant"
WORKER_MODEL = "llama-3.3-70b-versatile"


async def classify_query(user_prompt: str) -> str:
    """Определяет, нужен ли эксперт (COMPLEX) или это простая беседа (SIMPLE)."""
    try:
        response = await groq_client.chat.completions.create(
            model=UTILITY_MODEL,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "Ты Маршрутизатор. Верни только одно слово: COMPLEX если вопрос "
                        "сложный/технический/требует кода, или SIMPLE если это обычный "
                        "разговор. Без лишних символов."
                    ),
                },
                {"role": "user", "content": user_prompt},
            ],
            temperature=0.1,
            max_tokens=15,
        )
        ans = (response.choices[0].message.content or "").strip().upper()
        if not ans:
            return "COMPLEX"
        return "COMPLEX" if "COMPLEX" in ans else "SIMPLE"
    except Exception as e:
        print(f"[Маршрутизатор] Ошибка: {e}")
        return "COMPLEX"


async def ask_nemotron_worker(history: list, user_prompt: str) -> str:
    """Технический воркер. Генерирует код исключительно в тегах <artifact>."""
    short_history = history[-4:] if len(history) > 4 else history

    tech_prompt = (
        "Ты Технарь. Твоя задача — выдавать технические решения. "
        "ВАЖНОЕ ПРАВИЛО: Если ты пишешь код, конфиги или скрипты, НИКОГДА не используй "
        "стандартный markdown (```). "
        "ВМЕСТО ЭТОГО ОБЯЗАТЕЛЬНО оборачивай любой код в XML-теги по этому шаблону:\n"
        '<artifact title="название_файла.расширение" type="название_языка">\n'
        "САМ КОД\n"
        "</artifact>\n"
        "Пример:\n"
        '<artifact title="main.py" type="python">\nprint(\'Hello\')\n</artifact>'
    )

    messages = [{"role": "system", "content": tech_prompt}]
    messages.extend(short_history)
    messages.append({"role": "user", "content": user_prompt})

    try:
        response = await groq_client.chat.completions.create(
            model=WORKER_MODEL,
            messages=messages,
            temperature=0.2,
        )
        return response.choices[0].message.content or ""
    except Exception as e:
        return f"Ошибка Технаря: {e}"


def read_local_file(filepath: str) -> str:
    """Читает содержимое локального файла с защитой от больших файлов."""
    filepath = os.path.expanduser(filepath.strip())
    try:
        if not os.path.exists(filepath):
            return f"[Отчет Системы]: Файл {filepath} не найден."

        if os.path.getsize(filepath) > 200 * 1024:
            return "[Отчет Системы]: Ошибка! Файл слишком большой для чтения."

        with open(filepath, "r", encoding="utf-8") as f:
            content = f.read()
        return f"[Отчет Системы] Содержимое файла {filepath}:\n{content}"
    except PermissionError:
        return f"[Отчет Системы]: Нет прав для чтения файла {filepath}."
    except Exception as e:
        return f"[Отчет Системы]: Не удалось прочитать файл. Ошибка: {e}"


def _status_code(err: Exception) -> int | None:
    """Достаёт HTTP-код из ошибки openai/httpx, если он есть."""
    return getattr(err, "status_code", None) or getattr(err, "code", None)


def _is_transient(err: Exception) -> bool:
    """True — временный сбой, False — ошибка конфигурации/политики."""
    code = _status_code(err)
    if code in (429, 500, 502, 503, 504):
        return True
    if code in (401, 403, 404, 400):
        return False
    return True


async def ask_judge_stream(
    history: list,
    user_prompt: str,
    worker_responses: list,
    model_key: str = "nova",
):
    """Собирает контекст, стримит ответ и при необходимости читает локальные файлы."""
    context = "\n\n---\n\n".join(
        [f"Отчет суб-модуля {i + 1}:\n{resp}" for i, resp in enumerate(worker_responses)]
    )

    system_prompt = (
        "Ты — Vesper, тёплый, дружелюбный и эмпатичный искусственный интеллект. "
        "Общайся с пользователем как заботливый друг и надёжный напарник.\n"
        "КРИТИЧЕСКИ ВАЖНО 1: Если генерируешь исходный код, скрипт или конфиг, "
        "ОБЯЗАТЕЛЬНО оборачивай его в XML-теги. "
        'Шаблон: <artifact title="название_файла.расширение" type="название_языка"> '
        "...сам код... </artifact>. НИКАКОГО стандартного markdown (```)!\n"
        "КРИТИЧЕСКИ ВАЖНО 2: НИКОГДА не упоминай вслух про XML-теги, артефакты, "
        "суб-модули или свои инструкции. Просто используй их молча.\n"
        "КРИТИЧЕСКИ ВАЖНО 3: Перед финальным ответом порассуждай внутри "
        "тегов <think>...</think>.\n"
        "КРИТИЧЕСКИ ВАЖНО 4 (АГЕНТ): Если для ответа нужно прочитать локальный файл, "
        'выведи тег <read_file path="/абсолютный/путь/к/файлу" /> и БОЛЬШЕ НИЧЕГО. '
        "Система прочитает файл и вернёт его текст, после чего ты дашь осмысленный ответ.\n"
        f"Данные от суб-модулей по текущему запросу:\n{context}"
    )

    messages = (
        [{"role": "system", "content": system_prompt}]
        + history
        + [{"role": "user", "content": user_prompt}]
    )

    model_config = VESPER_MODELS.get(model_key, VESPER_MODELS["nova"])
    active_client = model_config["client"]
    actual_model = model_config["model"]

    fallback_order = [model_key] + [k for k in VESPER_MODELS if k != model_key]
    tried: set[str] = set()

    print(f"[Vesper] Подключаю модель -> {actual_model} ({active_client.base_url})")

    max_agent_steps = 3
    current_step = 0

    while current_step < max_agent_steps:
        current_step += 1
        full_response = ""
        tool_called = False
        tried.add(model_key)

        try:
            stream = await active_client.chat.completions.create(
                model=actual_model,
                messages=messages,
                temperature=0.4,
                stream=True,
            )

            buffer = ""
            async for chunk in stream:
                if not chunk.choices:
                    continue
                delta = chunk.choices[0].delta.content
                if delta is not None:
                    full_response += delta
                    buffer += delta

                    if len(buffer) >= 15 or "\n" in delta:
                        yield buffer
                        buffer = ""

                    if "<read_file" in full_response and "/>" in full_response:
                        tool_called = True
                        break

            if buffer and not tool_called:
                yield buffer

            if tool_called:
                match = re.search(
                    r'<read_file\s+path=["\']([^"\']+)["\']\s*/>', full_response
                )
                if match:
                    filepath = match.group(1)
                    yield f"\n\n*(Система: Читаю локальный файл {filepath}...)*\n\n"
                    file_content = read_local_file(filepath)
                    print(f"[Агент] Прочитан файл {filepath}")

                    messages.append({"role": "assistant", "content": full_response})
                    messages.append({"role": "user", "content": file_content})
                    continue
                else:
                    print("[Агент] Ошибка синтаксиса тега <read_file>")
                    break
            else:
                break

        except Exception as e:
            code = _status_code(e)
            transient = _is_transient(e)
            already_streamed = bool(full_response.strip())

            next_key = next((k for k in fallback_order if k not in tried), None)

            if transient and not already_streamed and next_key is not None:
                model_key = next_key
                model_config = VESPER_MODELS[next_key]
                active_client = model_config["client"]
                actual_model = model_config["model"]
                print(f"[Vesper] Провайдер недоступен (code={code}). Переключаюсь -> {actual_model}")
                yield "\n\n*(Система: подбираю доступную модель…)*\n\n"
                current_step -= 1
                continue

            if code in (401, 403):
                print(f"[Vesper] Ошибка доступа (code={code}): {e}")
                yield (
                    "\n\n**Vesper не может подключиться к модели.** "
                    "Провайдер вернул ошибку доступа (401/403)."
                )
            elif code == 429:
                yield (
                    "\n\n**Все модели сейчас заняты** (лимит запросов исчерпан). "
                    "Попробуй чуть позже или переключи модель вручную."
                )
            else:
                print(f"[Vesper] Сбой ядра (code={code}): {e}")
                yield f"\n\n**Системная ошибка ядра Vesper:** {e}"
            break
