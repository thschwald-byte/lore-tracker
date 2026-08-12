defmodule HubWeb.LocalTimeGuardTest do
  @moduledoc """
  Issue #1014: Quelltext-Wächter gegen den Rückfall (Muster: die Wächter aus
  #1005 Slice 1).

  Vor #1014 gab es **drei** unabhängige Zeitstempel-Formatierer
  (`CampaignLive.Components.format_ts/1`, ein privates `format_ts/1` in
  `AdminSpendLive`, ein `format_iso/1` in `AdminErrorsLive`) plus eine vierte
  Stelle, die rohes ISO ausgab. Zwei davon zeigten UTC **ohne** Kennzeichnung.
  Genau diese Drift ist der eigentliche Defekt gewesen — nicht die fehlende
  Zeitzone, sondern dass niemand mehr überblickte, wo Zeit wie gerendert wird.

  Der Wächter hält deshalb die Einzigkeit fest: `Calendar.strftime/2` darf im
  `hub_web`-Layer nur noch in `ui_components.ex` stehen, wo `<.local_time>`
  wohnt. Wer eine neue Zeitstempel-Anzeige baut, landet damit zwangsläufig bei
  der Komponente statt bei einer vierten Privatfunktion.

  **Ehrliche Grenze:** Der Wächter erkennt `Calendar.strftime`. Eine Anzeige,
  die rohes `DateTime.to_iso8601/1` ins Template schreibt (so war es in
  `admin_probelauf_live/render.ex`), fängt er NICHT — `to_iso8601` hat zu viele
  legitime Nicht-Anzeige-Verwendungen, ein Verbot wäre ein Fehlalarm-Generator.
  Die JS-Seite (`assets/js/local_time.js`) ist hier ohnehin nicht prüfbar.
  """
  use ExUnit.Case, async: true

  @allowed "lib/hub_web/components/ui_components.ex"

  test "Calendar.strftime lebt nur in der local_time-Komponente" do
    offenders =
      Path.wildcard("lib/hub_web/**/*.{ex,heex}")
      |> Enum.reject(&(&1 == @allowed))
      |> Enum.filter(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        # Kommentarzeilen ausnehmen: die Begründungen an den umgestellten
        # Stellen nennen den alten Aufruf beim Namen und wären sonst Fundstellen.
        |> Enum.reject(&(&1 |> String.trim() |> String.starts_with?("#")))
        |> Enum.any?(&String.contains?(&1, "Calendar.strftime"))
      end)

    assert offenders == [],
           """
           Zeitstempel-Formatierung außerhalb von <.local_time> gefunden:

           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

           Serverseitig formatierte Zeit ist immer UTC und wird vom Browser
           NICHT umgeschrieben — sie erscheint dem Nutzer als Ortszeit und ist
           damit eine stille Falschaussage (Issue #1014).

           Stattdessen: <.local_time iso={...} format={:time | :datetime | :datetime_sec} />
           """
  end
end
