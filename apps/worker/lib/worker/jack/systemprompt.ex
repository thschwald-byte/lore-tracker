defmodule Worker.Jack.Systemprompt do
  @moduledoc """
  Der Systemprompt, mit dem der Spike (#1174) lief: pis eingebauter
  Standardprompt (`system-prompt.js`, `buildSystemPrompt`). `pi-konfig`
  setzt keinen eigenen — kein `SYSTEM.md`, kein `APPEND_SYSTEM.md`, keine
  Kontextdatei —, also sah das Modell in Reihe C diesen Text. Für J3 wird er
  wörtlich nachgebaut, damit Port und Spike mit demselben Rahmen messen.

  Wie er zustande kommt, am pi-Code nachvollzogen:

    * **„Available tools: (none)“** — pi nimmt Werkzeugzeilen nur aus
      `promptSnippet` einer Werkzeugdefinition (`agent-session.js`); die
      Werkzeuge des Spikes tragen keins.
    * **Zwei Leitlinien** — ohne `bash`, `grep`, `find`, `ls` und ohne
      `promptGuidelines` bleiben nur die beiden festen.
    * **Doku-Pfade** unter dem Paketverzeichnis in der VM
      (`/mnt/software/opt/pi/node_modules/@earendil-works/pi-coding-agent`).
    * **„Current working directory: /“** — der Treiber ruft pi ohne `cd`
      auf; der Kopf des Ereignisstroms nennt `"cwd":"/"` (eve, 10.09.).

  **Ehrliche Grenze:** Der Ereignisstrom schreibt den Systemprompt nicht mit.
  Der Text ist aus dem Code rekonstruiert, nicht mitgeschnitten. Unbelegt
  sind der genaue Paketpfad (pi löst ihn über `import.meta.url` auf; ein
  anderer Pfad änderte drei Zeilen) und dass im Wurzelverzeichnis der VM
  keine `AGENTS.md` lag, die pi angehängt hätte.

  Für J4 ist dieser Prompt nicht gedacht: er nennt einen Coding-Agenten und
  pis Doku. Er steht hier nur, damit die Messung dasselbe misst.
  """

  @paket "/mnt/software/opt/pi/node_modules/@earendil-works/pi-coding-agent"

  @doc "pis Standard-Systemprompt, wie ihn der Spike in Reihe C schickte."
  @spec pi() :: String.t()
  def pi do
    """
    You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.

    Available tools:
    (none)

    In addition to the tools above, you may have access to other custom tools depending on the project.

    Guidelines:
    - Be concise in your responses
    - Show file paths clearly when working with files

    Pi documentation (read only when the user asks about pi itself, its SDK, extensions, themes, skills, or TUI):
    - Main documentation: #{@paket}/README.md
    - Additional docs: #{@paket}/docs
    - Examples: #{@paket}/examples (extensions, custom tools, SDK)
    - When reading pi docs or examples, resolve docs/... under Additional docs and examples/... under Examples, not the current working directory
    - When asked about: extensions (docs/extensions.md, examples/extensions/), themes (docs/themes.md), skills (docs/skills.md), prompt templates (docs/prompt-templates.md), TUI components (docs/tui.md), keybindings (docs/keybindings.md), SDK integrations (docs/sdk.md), custom providers (docs/custom-provider.md), adding models (docs/models.md), pi packages (docs/packages.md), environment variables (docs/environment-variables.md)
    - When working on pi topics, read the docs and examples, and follow .md cross-references before implementing
    - Always read pi .md files completely and follow links to related docs (e.g., tui.md for TUI API details)
    Current working directory: /\
    """
  end
end
