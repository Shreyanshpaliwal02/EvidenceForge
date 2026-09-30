.PHONY: doctor setup api web test build eval mcp agents-evals agents-smoke ship

# Windows users: ef.cmd <target> mirrors every target below (see ef.ps1 help).

doctor:
	python3 scripts/doctor.py

setup:
	cd backend && uv sync --locked
	cd frontend && npm ci

api:
	cd backend && uv run uvicorn evidenceforge.api:app --host 127.0.0.1 --port 8033

web:
	cd frontend && npm run dev -- --host 127.0.0.1 --port 5178 --strictPort

test:
	cd backend && uv run pytest
	cd frontend && npm test
	python3 -m unittest discover -s scripts -p 'test_*.py'

build:
	cd frontend && npm run build

eval:
	python3 scripts/evaluate.py

# Expose the evidence/learning/eval tools as an MCP server over stdio for external
# MCP clients (Claude Desktop, MCP Inspector, LangChain MCP adapters).
mcp:
	cd backend && uv run python -m evidenceforge.mcp_server

# Scripted trajectory evals (offline, no model). Add --live only with Ollama running.
agents-evals:
	cd backend && uv run python -m evidenceforge.agents.evals

# Live end-to-end multi-agent smoke against your local Ollama (qwen3.5:9b must be pulled).
agents-smoke:
	cd backend && EVIDENCEFORGE_LIVE_AGENT_TESTS=1 uv run pytest -m live -s

# Package this folder for another machine: manifest + zip next to the project directory.
ship:
	python3 scripts/ship.py
