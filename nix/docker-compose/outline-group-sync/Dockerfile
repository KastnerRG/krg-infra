FROM python:3.15.2-slim-bookworm@sha256:498829c717b1e59fc42f0e7865eafe4e04ca0f70a3769d4ae70ba218df54507c
COPY --from=ghcr.io/astral-sh/uv:0.13.10@sha256:a3ea1357342c1a4bf9a0c53a3deb1b55379aefa037338d8113d5771efa01774f /uv /usr/local/bin/uv
WORKDIR /app
ENV UV_PYTHON_DOWNLOADS=never
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-install-project --no-cache
COPY sync.py workflow.py worker.py ./
ENV PATH="/app/.venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 1000:1000
CMD ["python", "worker.py", "worker"]
