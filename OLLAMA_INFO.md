## What TinyLlama is

TinyLlama is a compact open-source LLM with only 1.1B parameters, making it suitable for applications that need a small computation and memory footprint. Through Ollama's library, it ships as a 638MB quantized model with a 2K token context window, text-only. It's not great for complex reasoning, but it's fast, cheap to run on CPU, and good for prototyping, edge devices, or chatbots where you don't need GPT-4-level quality. 
Ollama
Ollama

## What Ollama is

Ollama is a runtime that wraps llama.cpp-style inference engines behind a simple CLI and a local REST API (default port 11434). It handles downloading, quantizing/formatting (GGUF), and serving models, so you don't manage model weights or inference code yourself.

The Docker image

Two main options:

1. Official ollama/ollama image (recommended) — the base Ollama server, model pulled separately at runtime:

```
bash
docker pull ollama/ollama
docker run -d -v ollama:/root/.ollama -p 11434:11434 --name ollama ollama/ollama
docker exec -it ollama ollama pull tinyllama
docker exec -it ollama ollama run tinyllama
```

The -v flag creates a named volume mounted to /root/.ollama, so models persist even if the container is removed; -p maps port 11434 on the host to the container. 
OneUptime

2. Pre-baked images with TinyLlama already inside — e.g. langchain4j/ollama-tinyllama, which is the standard ollama/ollama image with the tinyllama model pre-downloaded. Useful for CI/testing (e.g. Testcontainers) where you don't want a pull step at container start. 
Docker Hub

GPU note: on Mac, Ollama should be run as a standalone app outside Docker since Docker Desktop doesn't support GPU passthrough there; Ollama can use GPU acceleration inside Docker on Linux with Nvidia GPUs. TinyLlama is small enough that CPU-only is usually fine anyway. 
Ollama

How it works (request flow)
Ollama server loads the model file (GGUF format) into memory on first request (or on ollama run).
Your app sends a JSON request to /api/generate (single prompt) or /api/chat (multi-turn, message history) over HTTP.
Ollama tokenizes input, runs it through the model, and streams back tokens as JSON lines (or one final JSON if "stream": false).
Model stays loaded in memory for a few minutes (configurable) so subsequent calls are fast; it unloads after idle timeout to free RAM.

Example call:
```
bash
curl http://localhost:11434/api/chat -d '{
  "model": "tinyllama",
  "messages": [{"role": "user", "content": "Hello!"}],
  "stream": false
}'
```
Python and Node clients work the same way via the ollama package. 
Ollama

Environment variables you'll actually use

Set these on the container (-e VAR=value or in docker-compose.yml):

Variable	Purpose
OLLAMA_HOST	Bind address/port, e.g. 0.0.0.0:11434
OLLAMA_MODELS	Custom path to store model files
OLLAMA_NUM_PARALLEL	Number of concurrent requests handled per model
OLLAMA_MAX_LOADED_MODELS	How many models can be resident in memory at once
OLLAMA_KEEP_ALIVE	How long a model stays loaded after last use (e.g. 5m)
OLLAMA_ORIGINS	Allowed CORS origins if calling from browser JS

A production docker-compose setup binds the port to localhost only, sets OLLAMA_HOST, OLLAMA_NUM_PARALLEL, and OLLAMA_MAX_LOADED_MODELS, and reserves GPU resources under deploy.resources. 
OneUptime

Using it in a project

Docker Compose skeleton:
```
yaml
services:
  ollama:
    image: ollama/ollama
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    environment:
      - OLLAMA_KEEP_ALIVE=10m
volumes:
  ollama_data:
```
Then in your app container/service, just point your HTTP client at http://ollama:11434 (Docker network DNS) and call /api/chat.

Python:
```
python
from ollama import chat
response = chat(model='tinyllama', messages=[{'role': 'user', 'content': 'Hello!'}])
print(response.message.content)
```
This is the standard pattern for the ollama Python package. 
Ollama

Node.js: same idea with the ollama npm package's chat() function.

Other useful endpoints: GET /api/tags lists available models; POST /api/embed generates embeddings; POST /api/pull downloads a model; DELETE /api/delete removes one. 
Usebruno
OneUptime

Ins and outs — practical tradeoffs
In: zero API cost, fully local/private, fast startup, tiny memory footprint (~1–2GB RAM), good for demos/CI/offline apps.
Out: 2K context window is small (long documents won't fit), 1.1B parameters means weak reasoning/instruction-following compared to models like Llama 3.2 or Mistral — treat it as a "toy" or a placeholder while building your pipeline, not a production-quality assistant.
Scaling: for real traffic, OLLAMA_NUM_PARALLEL and OLLAMA_MAX_LOADED_MODELS matter, and you can deploy multiple Ollama instances behind a load balancer for horizontal scaling. 
OneUptime

If you tell me what your project's stack is (Python backend, Node app, etc.) I can give you a ready-to-drop-in integration snippet.


---

**Because they're doing two different jobs, not duplicating one:**

1. ollama — the long-running server
This is the actual Ollama daemon that stays up and serves the API on port 11434. Its healthcheck (ollama list) just confirms the server process is alive and responding — it says nothing about which models are downloaded.

2. ollama-pull-model — a one-shot setup job
This container uses the same image but runs a single command (ollama pull tinyllama) and then exits. Its only purpose is to download the TinyLlama weights into the shared ollama-data volume the first time the stack comes up, so tinyllama actually exists before your app tries to call it.

Why split it out instead of just pulling the model inside the main ollama service:

The main ollama container's entrypoint runs ollama serve, which blocks forever — there's no clean point to also run ollama pull inside that same container without hacking the entrypoint script.
Docker Compose's depends_on: condition: service_completed_successfully only works for containers that exit after finishing (exit code 0) — a long-running server never "completes," so it can't be used as a dependency gate for "has the model finished downloading."
Splitting it lets bankapp depend on ollama-pull-model reaching service_completed_successfully — meaning: don't start the Spring/Java app until the model pull has actually finished, not just until the Ollama server has booted.

So the flow is:

mysql (healthy) ─┐
                  ├─→ bankapp starts
ollama (healthy) → ollama-pull-model (pulls tinyllama, exits 0) ─┘

Both containers share the same ollama-data volume, so the model pulled by ollama-pull-model is immediately visible to the ollama server container — ollama-pull-model doesn't need to stay running, it just needed write access to that volume once.

One subtlety worth knowing: OLLAMA_HOST=ollama in the pull container is a bit unusual — normally OLLAMA_HOST sets what address a server binds to, not what a client connects to (that's usually done via OLLAMA_HOST as well actually, since the CLI also reads it to know where to send requests). Here it's being used client-side, telling the ollama CLI inside ollama-pull-model to send its pull request to the ollama service by its Docker network name rather than localhost. That works because Docker Compose's internal DNS resolves ollama to the other container's IP on bankapp-net.


---

## how to Run it in a server

```
docker run -d -e OLLAMA_CPU_AVX2=false  -p 11434:11434 -v /home/ubuntu/ollama:/root/.ollama ollama/ollama

docker exec -it 4bd bash

ollama pull tinyllama

mv /usr/lib/ollama/libggml-cpu-sapphirerapids.so /usr/lib/ollama/libggml-cpu-sapphirerapids.so.bak

ollama run tinyllama

```
