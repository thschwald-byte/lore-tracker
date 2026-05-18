defmodule Worker.LLM.Backend do
  @moduledoc """
  Pluggable LLM backend for the Worker.Recording pipeline.

  Each stage of the pipeline picks a backend via `Worker.Settings`:

  - `:bundled` — built-in small model via Bumblebee+Nx (default in prod, M9b)
  - `:local`   — configurable local HTTP endpoint (Ollama-compatible, M9c)
  - `:mock`    — deterministic stub for dev/CI (M9a)

  Implementations register under `Worker.LLM.<Name>` and implement this
  behaviour. The pipeline calls them via `Worker.LLM.complete/3` /
  `Worker.LLM.transcribe/3` so the dispatch lives in one place.
  """

  @type opts :: keyword()

  @callback complete(prompt :: String.t(), opts) ::
              {:ok, String.t()} | {:error, term()}

  @callback transcribe(audio :: binary() | Path.t(), opts) ::
              {:ok, [%{discord_id: String.t(), text: String.t(), timestamp: DateTime.t()}]}
              | {:error, term()}

  @optional_callbacks [transcribe: 2]
end
