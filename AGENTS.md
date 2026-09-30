# AGENTS.md — orientation for the next AI agent (or human) working on EvidenceForge

Read this first. It is the shortest accurate description of what exists, what is
guaranteed by code, how to verify it, and what must not be done. `README.md` is
the user-facing narrative; `docs/HANDOFF.md` is the detailed state of play.

## What this is

EvidenceForge (tracker item **PROJ-03**) is a local-first, evidence-versioned RAG
system with a mutation-based evaluation harness and a mastery-learning layer, on
top of which sits a **genuine multi-agent system**: a LangGraph supervisor that
routes with `Command(goto=...)` between four LangChain `create_agent`
specialists (retriever, critic, coach, evaluator), tools shared with an **MCP**
server, **SQLite checkpoints** (`SqliteSaver`), a **human-in-the-loop
`interrupt()`** before the only write action, **SSE**-streamed trajectories and a
**trajectory-eval** suite. The model is a local Ollama `qwen3.5:9b`; nothing is
sent to any cloud service and nothing is downloaded by the app.

Default startup is fully offline (BM25 + extractive answers). The Agents tab is
the only feature that needs Ollama.

## Layout

```
ef.cmd / ef.ps1        Windows task runner (mirrors the Makefile). ef.cmd help
Makefile               macOS/Linux task runner
backend/               Python 3.12–3.14, FastAPI, uv-managed; package evidenceforge/
  evidenceforge/       store.py retrieval.py engine.py evaluation.py learning.py api.py
  evidenceforge/agents graph.py (supervisor) specialists.py tools.py llm.py models.py
                       mcp_server.py mcp_client.py scripted.py (fake model) evals.py api.py
  tests/               pytest; offline by default; -m live is opt-in
  .data/               runtime SQLite state (NOT shipped; recreated on first start)
frontend/              React 19 + TypeScript 7 + Vite 8; src/lib has typed API/SSE clients
scripts/               evaluate.py (mutation suite via API), doctor.py (preflight),
                       ship.py (packager), tests
docs/                  HANDOFF.md WINDOWS.md agents-contract.md v1-contract.md
                       INTERVIEW_PREP.md LINKEDIN_POST.md poster/ (social preview PNG + HTML source)
                       probes/ screenshots/ SHIP_MANIFEST.sha256
```

## Commands

| Task | macOS/Linux | Windows |
| --- | --- | --- |
| Preflight (tools, ports, Ollama) | `make doctor` | `ef.cmd doctor` |
| Install pinned deps | `make setup` | `ef.cmd setup` |
| API on 127.0.0.1:8033 | `make api` | `ef.cmd api` |
| Web on 127.0.0.1:5178 | `make web` | `ef.cmd web` (or `ef.cmd dev` for both) |
| Offline tests (backend+frontend+scripts) | `make test` | `ef.cmd test` |
| Production frontend build | `make build` | `ef.cmd build` |
| 24-case mutation suite (API must be up) | `make eval` | `ef.cmd eval` |
| Scripted trajectory evals (no model) | `make agents-evals` | `ef.cmd agents-evals` |
| Live 9B smoke (Ollama required) | `make agents-smoke` | `ef.cmd agents-smoke` |
| MCP stdio server | `make mcp` | `ef.cmd mcp` |
| Package for another machine | `make ship` | `ef.cmd ship` |

Expected green state (last verified on macOS arm64, see `docs/HANDOFF.md`):
backend **199 passed, 2 skipped**; frontend **40/40**; scripts **15 OK**;
`eval` **24/24**; `npm run build` clean.

## Invariants enforced by code (do not weaken them)

1. **Deterministic over LLM.** `verify_quote`, eligibility (as-of dates, source
   removal), `recommend_next_skill`, eval pass/fail counts and plan repair are
   computed by code. Model output never overrides them; disagreements become
   visible `warning` events and at most a `partial` status.
2. **Plan repair from goal text, not model labels.** `default_intent()` in
   `agents/graph.py` derives required specialists from keyword hints over the
   user's goal; any `retriever` step gets a `critic`; `evaluator`/`coach` are
   appended when the goal calls for them.
3. **The approved write runs exactly once, by code.** After an approved
   `interrupt()` resume, `_execute_approved_action` in `agents/specialists.py`
   executes `run_mutation_suite` through the audited tool path before the model
   loop; duplicates are refused with `approved_action_already_executed`; the
   ledger key is `run_id`.
4. **MCP never executes the write.** The standalone MCP server exposes the name
   and schema of `run_mutation_suite` but always denies it; the in-process,
   approval-gated implementation is the only executor.
5. **Fail closed.** Missing Ollama or model → HTTP 503 from `/api/agents/*`;
   never auto-start, never auto-pull, never fall back to a cloud model.
6. **Every specialist gets its own message list** (system + one brief). Two-phase
   calls (tool loop, then `with_structured_output(method="json_schema")`).
   Ollama grammar: strip only `maxLength > 1000`, validate Pydantic locally.
7. **Bounded everything.** Handoff cap, recursion limit, `EVIDENCEFORGE_AGENT_TIMEOUT_S`
   (240 s of active model time across resumes), payloads ≤ 2 KiB with
   `truncated: true`, one active run per SQLite reservation.

## Do-nots

- No cloud LLM calls, no telemetry, no LangSmith tracing, no model downloads,
  no `pip install` outside `uv` (`uv.lock` is the contract; use `uv sync --locked`).
- Do not ship `backend/.data`, `.env`, `.venv`, `node_modules`, `dist`.
- Do not claim Ragas/Langfuse/semantic faithfulness/calibrated confidence are
  active — they are `null` or documented as future work.
- Do not edit the wire shapes in `docs/agents-contract.md` without updating both
  `backend/evidenceforge/agents/models.py` and `frontend/src/lib/types.ts` and
  their tests together.
- Do not start persistent servers inside tests; do not depend on port 8033 being
  free in tests.

## Verification checklist before declaring anything done

```
ef.cmd doctor            (or make doctor)          -> no FAIL rows
ef.cmd test              (or make test)            -> 199 passed 2 skipped / 40 / 15 OK
ef.cmd build             (or make build)
ef.cmd api  + ef.cmd eval  in another window       -> 24/24 pass, exit 0
ef.cmd agents-evals                                -> 7 invariants, real counts
optional: ef.cmd agents-smoke  with Ollama running -> completed + partial(HITL) runs
```

Browser check: open 127.0.0.1:5178 → Agents tab → "Ask" a question (expect
retriever→critic, 30–60 s) → "Evaluate" goal naming the mutation suite (expect an
approval card, approve, expect exactly one new entry in the Evaluations tab).

## Known gaps / open items

See `docs/HANDOFF.md` §"Next steps". Headline items: no real 50k corpus or
200-case human golden set; `semantic_faithfulness`/`cost_usd` are `null`;
retrieval ablations not run; no deployment story; Windows-specific behaviours
listed in `docs/WINDOWS.md` were reasoned about and unit-tested but not executed
on a real Windows machine before shipping.

## Contracts and probes

- `docs/agents-contract.md` — settled multi-agent API/SSE wire shapes (authoritative).
- `docs/v1-contract.md` — original RAG/eval/learning API contract.
- `docs/probes/` — the two throwaway scripts that established the Ollama
  behaviours (single-brief messages, two-phase calls). Keep for provenance.
- `docs/screenshots/` — real-browser evidence of the working UI.
