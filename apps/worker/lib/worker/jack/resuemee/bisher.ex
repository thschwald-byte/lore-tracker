defmodule Worker.Jack.Resuemee.Bisher do
  @moduledoc """
  Die Kampagne bis einschließlich der laufenden Sitzung (E0, #1210):
  `boegen_kampagne()` — jeder Bogen mit seinen Fakten aus allen diesen
  Sitzungen — und `vorige_kapitel(von?, bis?)` — die Epos-Kapitel früherer
  Sitzungen, analog `vorige_resuemees`.

  **Bis einschließlich, nicht darüber hinaus.** Bögen, die erst in einer
  späteren Sitzung einen Fakt bekommen, fehlen: beim Neu-Generieren einer
  frühen Sitzung läse Jack sonst die Zukunft. `boegen()` bleibt die Sicht
  dieser Sitzung.

  Pur wie `Worker.Jack.Resuemee.Lesen`. Die Funktionen lesen nur die Felder
  `sitzung`, `fakten`, `fruehere`, `boegen_kampagne` und `kapitel`.
  """

  alias Worker.Jack.Resuemee.{Eingabe, Stand}

  @type ergebnis :: {map(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Die Werkzeuge dieses Moduls, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(map()) :: [map()]
  def werkzeuge(s) do
    [
      %{
        name: "boegen_kampagne",
        beschreibung:
          "Alle Bögen der Kampagne bis einschließlich dieser Sitzung (#{s.sitzung.nummer}): " <>
            "Titel, Art, Status, Leitfrage und die IDs ihrer Fakten aus allen diesen " <>
            "Sitzungen. Damit siehst du, woher ein Bogen kommt. Die Bögen dieser Sitzung " <>
            "allein liefert boegen().",
        parameter: objekt(%{}),
        wiederholung: :frei,
        ausfuehren: &boegen_kampagne/2
      },
      %{
        name: "vorige_kapitel",
        beschreibung:
          "Die Epos-Kapitel früherer Sitzungen, jedes mit seinem Kapitelkopf — Hintergrund " <>
            "für Anschluss, Namen und Ton. von und bis sind Sitzungsnummern; ohne Angabe " <>
            "alle früheren.",
        parameter:
          objekt(%{
            "von" => zahl("erste Sitzungsnummer"),
            "bis" => zahl("letzte Sitzungsnummer")
          }),
        optional: ["von", "bis"],
        ausfuehren: &vorige_kapitel/2
      }
    ]
  end

  defp objekt(props), do: %{"type" => "object", "properties" => props}

  defp zahl(beschreibung),
    do: %{"type" => "integer", "minimum" => 1, "description" => beschreibung}

  @doc "Die Fakten aller Sitzungen bis einschließlich dieser, aufsteigend nach Sitzung."
  @spec alle_fakten(map()) :: [map()]
  def alle_fakten(s), do: Enum.flat_map(s.fruehere, & &1.fakten) ++ s.fakten

  @doc """
  Die Bögen der Kampagne bis einschließlich dieser Sitzung: aus der Eingabe
  (`boegen_kampagne`, mit Leitfrage und Status), sonst aus den Fakten
  abgeleitet (`Worker.Jack.Resuemee.Eingabe.boegen/2` ohne Stränge — dann
  ohne Leitfrage und Status).
  """
  @spec alle_boegen(map()) :: [map()]
  def alle_boegen(%{boegen_kampagne: b}) when is_list(b), do: b
  def alle_boegen(s), do: Eingabe.boegen(alle_fakten(s), [])

  @doc "Die Bögen der Kampagne (Werkzeug `boegen_kampagne`)."
  @spec boegen_kampagne(map(), map()) :: ergebnis()
  def boegen_kampagne(s, _args) do
    n = s.sitzung.nummer

    case alle_boegen(s) do
      [] ->
        {s, {:ok, "Bis einschließlich Sitzung #{n} gehört kein Fakt zu einem Bogen."}}

      boegen ->
        kopf =
          "Die Bögen der Kampagne bis einschließlich Sitzung #{n}, in der Reihenfolge ihres " <>
            "ersten Fakts. Art: arc = Handlungsbogen, context = Hintergrund und Weltwissen, " <>
            "rauschen = Gespräch am Tisch. Die Bögen dieser Sitzung allein liefert boegen()."

        zeilen =
          Enum.map(boegen, fn b ->
            Enum.join(
              [
                b.titel,
                "Art: #{b.art}",
                "Status: #{b.status || "—"}",
                "Leitfrage: #{b.leitfrage || "—"}",
                "Fakten: #{Enum.join(b.fakten, ", ")}"
              ],
              "\t"
            )
          end)

        {s, {:ok, Enum.join([kopf, "" | zeilen], "\n")}}
    end
  end

  @doc "Die Epos-Kapitel früherer Sitzungen (Werkzeug `vorige_kapitel`)."
  @spec vorige_kapitel(map(), map()) :: ergebnis()
  def vorige_kapitel(%{fruehere: []} = s, _args), do: {s, {:ok, Stand.keine_frueheren()}}

  def vorige_kapitel(s, p) do
    von = p["von"] || 1
    bis = p["bis"] || s.sitzung.nummer - 1

    if von > bis do
      {s, {:error, "von (#{von}) ist größer als bis (#{bis})."}}
    else
      treffer =
        Enum.filter(
          s.kapitel,
          &(&1.nummer >= von and &1.nummer <= bis and &1.nummer < s.sitzung.nummer)
        )

      case treffer do
        [] ->
          {s, {:ok, "Zu den früheren Sitzungen #{von} bis #{bis} liegt kein Epos-Kapitel vor."}}

        k ->
          {s, {:ok, Enum.map_join(k, "\n\n", &kapitel_text/1)}}
      end
    end
  end

  defp kapitel_text(k), do: "## Sitzung #{k.nummer}#{name(k)}\n\n" <> String.trim(k.text)

  defp name(%{name: n}) when is_binary(n) and n != "", do: " — " <> n
  defp name(_), do: ""
end
