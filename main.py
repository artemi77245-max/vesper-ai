import json
import os
import subprocess
import tempfile
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from services import classify_query, ask_nemotron_worker, ask_judge_stream

app = FastAPI()
MEMORY_FILE = "vesper_memory.json"


def load_memory():
    """Загружает историю чатов из файла."""
    if os.path.exists(MEMORY_FILE) and os.path.getsize(MEMORY_FILE) > 0:
        try:
            with open(MEMORY_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except json.JSONDecodeError:
            return {}
    return {}


def save_memory(db):
    """Сохраняет историю чатов в файл."""
    with open(MEMORY_FILE, "w", encoding="utf-8") as f:
        json.dump(db, f, ensure_ascii=False, indent=2)


def run_python_code(code_to_run: str) -> dict:
    """Запускает Python-код во временном файле с таймаутом 10 секунд."""
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".py", delete=False, encoding="utf-8"
        ) as f:
            f.write(code_to_run)
            temp_path = f.name

        result = subprocess.run(
            ["python", temp_path], capture_output=True, text=True, timeout=10
        )
        return {
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exit_code": result.returncode,
        }
    except subprocess.TimeoutExpired:
        return {
            "stdout": "",
            "stderr": "Ошибка: скрипт выполнялся слишком долго (таймаут 10 секунд).",
            "exit_code": -1,
        }
    except Exception as e:
        return {
            "stdout": "",
            "stderr": f"Системная ошибка запуска: {e}",
            "exit_code": -1,
        }
    finally:
        if temp_path and os.path.exists(temp_path):
            os.remove(temp_path)


@app.websocket("/ws/chat/{chat_id}")
async def chat_endpoint(websocket: WebSocket, chat_id: str):
    await websocket.accept()

    memory_db = load_memory()
    if chat_id not in memory_db:
        memory_db[chat_id] = []

    chat_history = memory_db[chat_id]

    if chat_history:
        await websocket.send_json({"type": "history", "messages": chat_history})

    try:
        while True:
            text_data = await websocket.receive_text()
            data = json.loads(text_data)

            if data.get("type") == "run_code":
                artifact_id = data.get("artifact_id", "")
                print(f"[Сервер] Запуск кода для артефакта {artifact_id}")

                result = run_python_code(data.get("code", ""))
                await websocket.send_json({
                    "type": "run_result",
                    "artifact_id": artifact_id,
                    **result,
                })
                continue

            user_text = data.get("text", "")
            selected_model = data.get("model", "nova")

            if not user_text.strip():
                continue

            print(f"[Запрос] {user_text} | Модель: {selected_model}")

            complexity = await classify_query(user_text)
            worker_responses = []

            if complexity == "COMPLEX":
                worker_resp = await ask_nemotron_worker(chat_history, user_text)
                worker_responses.append(worker_resp)

            full_response = ""
            async for chunk in ask_judge_stream(
                chat_history, user_text, worker_responses, model_key=selected_model
            ):
                full_response += chunk
                await websocket.send_json({"type": "token", "value": chunk})

            chat_history.append({"role": "user", "content": user_text})
            chat_history.append({"role": "assistant", "content": full_response})
            save_memory(memory_db)

            await websocket.send_json({"type": "done"})

    except WebSocketDisconnect:
        print("[Сервер] Клиент отключился.")
    except Exception as e:
        print(f"[Сервер] Ошибка WebSocket: {e}")
        try:
            await websocket.send_json({"type": "token", "value": f"\n\n**Сбой соединения:** {e}"})
            await websocket.send_json({"type": "done"})
        except Exception:
            pass
