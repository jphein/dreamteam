# Backends

Outside services dreamteam talks to, by tier. Every row names what it needs and its status.

## Local model lane (`scripts/local-model.sh`, issue #16)

Optional and off by default (`.local.enabled`). Only for work that needs no frontier reasoning:
mechanical bulk, cron summaries, embeddings, pre-filter triage. Its output goes through the oracle
before any commit.

| Backend | API | Needs | Status |
|---|---|---|---|
| Ollama on a desktop GPU box (RTX 2080 Ti, 11 GiB, Turing sm_75) | Ollama `/api/generate`, `/api/tags` | Ollama >= 0.40 as a user unit; host and model in the private overlay `~/.config/dreamteam/local.json` on each consumer; the box's firewall allows only the consumer host | **live 2026-11-12**: `qwen3.5:9b-q4_K_M` (6.6 GB, all in VRAM, 16k context, unloads after 5 idle minutes) |
| Ollama embeddings | `/api/embeddings` | `nomic-embed-text:v1.5` pulled on the same box | not pulled yet: `--embed` exits 3 and the caller falls back |
| OpenAI-compatible llama-server (a server GPU, qwen3.6-35B-A3B) | `/v1/chat/completions` | an adapter in `local-model.sh` (it speaks Ollama only) and the server's API key | backlog: the server already serves the palace's dream job; no adapter yet |

### Model choice for an 11 GiB Turing card (2026-11-12)

Picked by fit first, then quality, then freshness, because the card is shared with a live desktop:

1. **Qwen3.5-9B (Mar 2026), Q4_K_M, 6.6 GB.** Fits entirely in VRAM. MMLU-Pro 82.5 and LiveCodeBench
   65.6 (thinking mode, model-card figures via aggregators). Chosen.
2. **Gemma 4 E4B (Apr 2026).** Smaller and faster, clearly weaker (MMLU-Pro 69.4). A fallback.
3. **Qwen3.6-35B-A3B (Apr 2026) with experts offloaded to the CPU.** The strongest that runs, but its
   experts would sit in 12-15 GB of the desktop's RAM and load its 8-core CPU while someone works.
   Rejected for a shared desktop; it stays on the server GPU.

Too big for this card: Qwen3.8-27B (dense, 18 GB at Q4), Qwen3.8-Flash-Next (125-180B MoE), Gemma 4
26B/31B.
