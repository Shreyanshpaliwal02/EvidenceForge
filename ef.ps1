# EvidenceForge task runner for Windows (also runs under pwsh on macOS/Linux).
# Equivalent of the Makefile.  Usage:  .\ef.ps1 <command>   or   ef.cmd <command>
#
#   doctor        preflight: tools, versions, ports, Ollama, foreign venvs (add -VerifyManifest)
#   setup         uv sync --locked (backend) + npm ci (frontend)
#   api           run the FastAPI server on http://127.0.0.1:8033 (foreground)
#   web           run the Vite dev server on http://127.0.0.1:5178 (foreground)
#   dev           open api and web in two new PowerShell windows
#   test          backend pytest + frontend node tests + scripts unittest (offline)
#   build         production frontend build (frontend/dist)
#   eval          run the 24-case mutation suite through the running API
#   agents-evals  scripted trajectory evals (offline, no model needed)
#   agents-smoke  LIVE multi-agent smoke test against local Ollama (slow, opt-in)
#   mcp           run the MCP stdio server (for MCP Inspector / Claude Desktop)
#   ship          write docs/SHIP_MANIFEST.sha256 and a zip next to the project folder
#   clean         delete backend/.venv, frontend/node_modules, dist and caches (keeps .data)
#   reset-data    delete backend/.data (SQLite state, agent runs, checkpoints)
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7. ASCII only on purpose.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",
    [switch]$VerifyManifest,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSCommandPath
$Backend = Join-Path $Root "backend"
$Frontend = Join-Path $Root "frontend"
$EnvFile = Join-Path $Root ".env"

# Python 3.14 still defaults to the ANSI code page for redirected streams on Windows.
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
# Decode child-process output as UTF-8 (python/node emit UTF-8 with the settings above).
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
# The local model layer never traces to LangSmith or any cloud service.
$env:LANGSMITH_TRACING = "false"
$env:LANGCHAIN_TRACING_V2 = "false"

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host ("==> " + $Text) -ForegroundColor Cyan
}

function Require-Tool([string]$Name, [string]$Hint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw ("'" + $Name + "' is not on PATH. " + $Hint)
    }
}

function Invoke-In([string]$Directory, [string]$Executable, [string[]]$Arguments) {
    Push-Location $Directory
    # Windows PowerShell 5.1 turns native stderr into terminating errors when the host's
    # output is captured (CI, an AI agent's tool, "> log 2>&1") and the preference is Stop.
    # uv reports all progress on stderr, so marshal both streams by hand and trust exit codes.
    $ErrorActionPreference = "Continue"
    try {
        # stderr, so piped stdout (for example doctor --json) stays machine-readable
        [Console]::Error.WriteLine("    " + $Executable + " " + ($Arguments -join " "))
        & $Executable @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                [Console]::Error.WriteLine($_.ToString())
            }
            else {
                [Console]::Out.WriteLine([string]$_)
            }
        }
        if ($LASTEXITCODE -ne 0) {
            throw ($Executable + " exited with code " + $LASTEXITCODE)
        }
    }
    finally {
        Pop-Location
    }
}

function Test-Api {
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:8033/api/health" -UseBasicParsing -TimeoutSec 3
        return $response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

function Remove-IfExists([string]$Path) {
    if (Test-Path $Path) {
        Write-Host ("    removing " + $Path) -ForegroundColor DarkGray
        Remove-Item -Recurse -Force $Path
    }
}

function Api-Arguments {
    $arguments = @("run")
    if (Test-Path $EnvFile) {
        $arguments += @("--env-file", $EnvFile)
    }
    $arguments += @("uvicorn", "evidenceforge.api:app", "--host", "127.0.0.1", "--port", "8033")
    return $arguments
}

switch ($Command.ToLower()) {
    "help" {
        Get-Content $PSCommandPath | Select-Object -First 19 | ForEach-Object { $_ -replace "^# ?", "" }
        exit 0
    }

    "doctor" {
        Require-Tool "uv" "Install with:  winget install astral-sh.uv   then reopen the terminal."
        $arguments = @("run", "--no-project", "--python", "3.14", "python", (Join-Path $Root "scripts\doctor.py"))
        if ($VerifyManifest) { $arguments += "--verify-manifest" }
        if ($Rest) { $arguments += $Rest }
        Invoke-In $Root "uv" $arguments
        exit 0
    }

    "setup" {
        Require-Tool "uv" "Install with:  winget install astral-sh.uv"
        Require-Tool "npm" "Install Node.js LTS (>= 22.12):  winget install OpenJS.NodeJS.LTS"
        Write-Step "backend: uv sync --locked (downloads a managed Python 3.14 if needed)"
        Invoke-In $Backend "uv" @("sync", "--locked")
        Write-Step "frontend: npm ci"
        Invoke-In $Frontend "npm" @("ci")
        if (-not (Test-Path $EnvFile)) {
            Copy-Item (Join-Path $Root ".env.example") $EnvFile
            Write-Host "    created .env from .env.example (all settings optional; edit to change the agent model)"
        }
        Write-Step "setup complete. Next:  ef.cmd doctor   then   ef.cmd dev"
        exit 0
    }

    "api" {
        Require-Tool "uv" "Run ef.cmd setup first."
        Write-Step "API on http://127.0.0.1:8033  (docs at /docs). Ctrl+C stops it."
        Invoke-In $Backend "uv" (Api-Arguments)
        exit 0
    }

    "web" {
        Require-Tool "npm" "Run ef.cmd setup first."
        Write-Step "Web on http://127.0.0.1:5178  (proxies /api to 8033). Ctrl+C stops it."
        Invoke-In $Frontend "npm" @("run", "dev")
        exit 0
    }

    "dev" {
        Require-Tool "uv" "Run ef.cmd setup first."
        Require-Tool "npm" "Run ef.cmd setup first."
        $self = $PSCommandPath
        Write-Step "starting API and web in two new windows"
        Start-Process powershell -ArgumentList @("-NoExit", "-ExecutionPolicy", "Bypass", "-File", $self, "api")
        Start-Sleep -Seconds 2
        Start-Process powershell -ArgumentList @("-NoExit", "-ExecutionPolicy", "Bypass", "-File", $self, "web")
        Write-Host ""
        Write-Host "    app:  http://127.0.0.1:5178"
        Write-Host "    api:  http://127.0.0.1:8033/docs"
        Write-Host "    Agents tab needs the Ollama app running with  ollama pull qwen3.5:9b  done once."
        exit 0
    }

    "test" {
        Require-Tool "uv" "Run ef.cmd setup first."
        Require-Tool "npm" "Run ef.cmd setup first."
        Write-Step "backend: pytest (offline, scripted model; live tests are deselected)"
        Invoke-In $Backend "uv" @("run", "pytest")
        Write-Step "frontend: node --test"
        Invoke-In $Frontend "npm" @("test")
        Write-Step "scripts: unittest"
        Invoke-In $Root "uv" @("run", "--project", $Backend, "python", "-m", "unittest", "discover", "-s", "scripts", "-p", "test_*.py")
        Write-Step "all test groups passed"
        exit 0
    }

    "build" {
        Require-Tool "npm" "Run ef.cmd setup first."
        Write-Step "frontend: tsc -b && vite build"
        Invoke-In $Frontend "npm" @("run", "build")
        exit 0
    }

    "eval" {
        Require-Tool "uv" "Run ef.cmd setup first."
        if (-not (Test-Api)) {
            throw "The API is not running on 127.0.0.1:8033. Start it with  ef.cmd api  (or ef.cmd dev) in another window, then rerun."
        }
        Write-Step "mutation suite through POST /api/evals/run"
        $arguments = @("run", "--project", $Backend, "python", (Join-Path $Root "scripts\evaluate.py"))
        if ($Rest) { $arguments += $Rest }
        Invoke-In $Root "uv" $arguments
        exit 0
    }

    "agents-evals" {
        Require-Tool "uv" "Run ef.cmd setup first."
        Write-Step "scripted trajectory evals (offline; add --live only with Ollama and EVIDENCEFORGE_LIVE_AGENT_TESTS=1)"
        $arguments = @("run", "python", "-m", "evidenceforge.agents.evals")
        if ($Rest) { $arguments += $Rest }
        Invoke-In $Backend "uv" $arguments
        exit 0
    }

    "agents-smoke" {
        Require-Tool "uv" "Run ef.cmd setup first."
        Write-Step "LIVE smoke: real qwen3.5:9b runs (about 70 s on an M1 Pro; longer on CPU-only Windows)"
        $env:EVIDENCEFORGE_LIVE_AGENT_TESTS = "1"
        Invoke-In $Backend "uv" @("run", "pytest", "-m", "live", "-s")
        exit 0
    }

    "mcp" {
        Require-Tool "uv" "Run ef.cmd setup first."
        Write-Step "MCP stdio server (reads only; run_mutation_suite is always denied here). Ctrl+C stops it."
        Invoke-In $Backend "uv" @("run", "python", "-m", "evidenceforge.mcp_server")
        exit 0
    }

    "ship" {
        Require-Tool "uv" "Install with:  winget install astral-sh.uv"
        Write-Step "packaging (excludes .venv, node_modules, .data, dist, caches, real .env)"
        $arguments = @("run", "--no-project", "--python", "3.14", "python", (Join-Path $Root "scripts\ship.py"))
        if ($Rest) { $arguments += $Rest }
        Invoke-In $Root "uv" $arguments
        exit 0
    }

    "clean" {
        Write-Step "removing installed dependencies and caches (backend/.data is kept)"
        Remove-IfExists (Join-Path $Backend ".venv")
        Remove-IfExists (Join-Path $Backend ".pytest_cache")
        Remove-IfExists (Join-Path $Frontend "node_modules")
        Remove-IfExists (Join-Path $Frontend "dist")
        Get-ChildItem -Path $Root -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch "node_modules|\.venv" } |
            ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
        Write-Host "    done. Run  ef.cmd setup  to reinstall."
        exit 0
    }

    "reset-data" {
        Write-Step "deleting backend/.data (evidence store, learner state, agent runs, checkpoints)"
        Remove-IfExists (Join-Path $Backend ".data")
        Write-Host "    done. The next API start reseeds the fixture corpus."
        exit 0
    }

    default {
        Write-Host ("unknown command: " + $Command) -ForegroundColor Red
        Write-Host "run  .\ef.ps1 help"
        exit 2
    }
}
