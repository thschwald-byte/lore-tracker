defmodule Shared.TeststageAbzug do
  @moduledoc """
  Wo der Teststage-Default liegt (#1260).

  **In `shared`, weil Hub und Worker es beide brauchen** — derselbe Grund wie
  bei `Shared.PipelineStufen` und `Shared.ResuemeeLaenge`: Der Worker liest den
  Abzug (`Worker.Teststage`), und der Hub-Task `mix lore.pr_test` muss vor dem
  Einspielen wissen, ob es einen gibt, um sonst laut auf die Romeo-Demo
  zurückzufallen. Zwei Konstanten an zwei Orten laufen auseinander, ohne dass
  etwas rot wird (#1090).

  Der Abzug selbst liegt **außerhalb des Repos** und ist nicht eingecheckt: Er
  trägt die echten Namen, Discord-IDs und Gespräche der Runde, und das Repo ist
  öffentlich. Hier steht nur, wo er zu finden ist.
  """

  @standard "~/.local/share/lore-jack/teststage"

  @doc """
  Das Verzeichnis des Default-Abzugs. **Ohne Datum im Namen**: Ein datierter
  Pfad ist kein kanonischer Ort — man müsste wissen, welcher der richtige ist,
  und genau das hat am 26.09.2026 eine Stunde gekostet.
  """
  @spec standard_verzeichnis() :: Path.t()
  def standard_verzeichnis, do: Path.expand(@standard)

  @doc """
  `true`, wenn in `verzeichnis` mindestens eine `.jsonl` liegt.

  Bewusst nur die Anwesenheit, nicht der Inhalt: Ob die Ereignisse taugen,
  entscheidet der Worker beim Lesen (`Worker.Teststage.ereignisse/1`) — der Hub
  hat dafür keinen Leser und soll keinen bekommen.
  """
  @spec vorhanden?(Path.t()) :: boolean()
  def vorhanden?(verzeichnis \\ standard_verzeichnis()) do
    case File.ls(verzeichnis) do
      {:ok, namen} -> Enum.any?(namen, &String.ends_with?(&1, ".jsonl"))
      {:error, _} -> false
    end
  end
end
