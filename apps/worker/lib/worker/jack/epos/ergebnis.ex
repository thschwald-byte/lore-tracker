defmodule Worker.Jack.Epos.Ergebnis do
  @moduledoc """
  Was aus dem Schreiben des Epos-Jack herauskommt (E2, #1210), pur: das
  Kapitel als Markdown (`markdown/1`), die Quellen je Absatz (`quellen/1`) und
  die Zählwerte (`zaehlwerte/1`).

  **Markdown:** Absätze durch eine Leerzeile getrennt, ein Titel als fette
  Zeile davor — nur, wo Jack einen gesetzt hat; dieselbe Form und dieselben
  Schutzmaßnahmen wie beim Resümee
  (`Worker.Jack.Resuemee.Ergebnis.absatz_markdown/2`). **Den Kapitelkopf
  (Nummer, Datum) schreibt Jack nicht**; der bleibt deterministisch in der
  Pipeline (#752), `Worker.Jack.Epos.Pipeline.kopf/3` setzt ihn davor.

  **Quellen je Absatz statt je Satz:** der Epos-Jack schreibt frei, ohne
  Fakten je Satz (Maintainer, 13.09.2026). Ein Absatz, dem Jack eine Szene
  zugeordnet hat, bekommt deren Fakten aus den Notizen — kurze IDs und die
  echten Fakt-IDs der Pipeline, Fakten früherer Sitzungen eingeschlossen,
  wenn die Szene sie nennt. Belegblöcke (`source_refs` des Kapitels) liefern
  davon nur die Fakten dieser Sitzung (`Worker.Jack.Epos.Pipeline.quellen/2`).
  Ein Absatz ohne Szene hat keine Quellen.
  **Ehrliche Grenze:** die Zuordnung sagt, welche Szene ein Absatz erzählt,
  nicht, dass er ihre Fakten wiedergibt — geprüft wird das nicht.

  Alle drei arbeiten auf dem Entwurf des Stands, den sie bekommen: auf dem
  Stand der Durchsicht (E3) ist das das Kapitel nach der Durchsicht, und
  `zaehlwerte/1` trägt dann zusätzlich `durchsicht`
  (`Worker.Jack.Epos.Durchsicht.zaehlwerte/1`).
  """

  alias Worker.Jack.Epos.{Durchsicht, Entwurf}
  alias Worker.Jack.Resuemee.Ergebnis, as: Gemeinsam
  alias Worker.Jack.Resuemee.Stand

  @doc "Das Kapitel als Markdown, siehe Moduldoc."
  @spec markdown(Stand.t()) :: String.t()
  def markdown(%Stand{entwurf: e}),
    do: Enum.map_join(e, "\n\n", &Gemeinsam.absatz_markdown(&1.titel, &1.text))

  @doc """
  Je Absatz: `%{absatz:, titel:, szene:, fakten:, fakt_ids:}`. `absatz`
  zählt ab 1 wie in `entwurf()`, `szene` ist der Schlüssel der zugeordneten
  Szene oder `nil`, `fakten` die kurzen IDs der Szene aus den Notizen,
  `fakt_ids` die echten Fakt-IDs, auf die sie zeigen (eine ohne ID im Bestand
  fehlt dort).
  """
  @spec quellen(Stand.t()) :: [map()]
  def quellen(%Stand{} = s) do
    echt = Map.new(s.fakten ++ Enum.flat_map(s.fruehere, & &1.fakten), &{&1.id, &1.fakt_id})
    szenen = Map.new(Stand.abschnitt(s, "SZENEN"), &{&1.schluessel, &1.fakten})

    for {a, n} <- Enum.with_index(s.entwurf, 1) do
      fakten = if a.szene, do: Map.get(szenen, a.szene, []), else: []

      %{
        absatz: n,
        titel: a.titel,
        szene: a.szene,
        fakten: fakten,
        fakt_ids: fakten |> Enum.map(&Map.get(echt, &1)) |> Enum.reject(&is_nil/1)
      }
    end
  end

  @doc """
  Die Zählwerte, JSON-fähig: `absaetze`, `woerter` (Absatztexte und Titel,
  `Worker.Jack.Epos.Entwurf.woerter/1`), `absaetze_mit_szene`,
  `absaetze_ohne_szene`, `szenen` (Einträge unter SZENEN) und
  `szenen_ohne_absatz` (wie viele davon kein Absatz erzählt); auf dem Stand
  der Durchsicht dazu `durchsicht` (Durchgänge, bestätigt, ersetzt und
  gestrichen je mit Grund, Hinweise vorher und nachher).
  """
  @spec zaehlwerte(Stand.t()) :: map()
  def zaehlwerte(%Stand{durchsicht: %{}} = s),
    do: s |> schreibwerte() |> Map.put("durchsicht", Durchsicht.zaehlwerte(s))

  def zaehlwerte(%Stand{} = s), do: schreibwerte(s)

  defp schreibwerte(s) do
    mit = Enum.count(s.entwurf, &(&1.szene != nil))

    %{
      "absaetze" => length(s.entwurf),
      "woerter" => Entwurf.woerter(s),
      "absaetze_mit_szene" => mit,
      "absaetze_ohne_szene" => length(s.entwurf) - mit,
      "szenen" => length(Stand.abschnitt(s, "SZENEN")),
      "szenen_ohne_absatz" => length(Entwurf.ohne_absatz(s))
    }
  end
end
