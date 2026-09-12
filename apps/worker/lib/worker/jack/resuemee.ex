defmodule Worker.Jack.Resuemee do
  @moduledoc """
  Jack schreibt das Resümee (J5, #1209, Epic #1195) — die Ablaufsteuerung.

  Geplant sind drei Läufe, gebaut ist der erste:

    1. **Überblick** (B1, `laufen_ueberblick/2`) — das Gegenstück zu Jacks
       Gedächtnis: Jack liest alle Fakten der Sitzung, notiert zuerst die
       FORM, die er aus der Überschrift der Resümee-Spalte ableitet, und legt
       danach die GLIEDERUNG an, gestützt auf die Fakten und die
       kampagnenweiten Bögen. Stellen, an denen die Fakten zum Verstehen nicht
       reichen, notiert er unter OFFEN.
    2. Schreiben (B2) — Satz für Satz, jeder mit seinen Fakten.
    3. Durchsicht (B3) — gnädig, nur grobe Schnitzer.

  Der Einbau in die Pipeline, die eigene Modell-Einstellung und das Ablegen
  des Stands als Ereignis folgen mit B4.

  **Wie beim Fakten-Jack:** dasselbe Modell (`Worker.Jack.Pipeline.modell/0`),
  dasselbe Kontextfenster (`Worker.Jack.Pipeline.kontext_fenster/0`) und
  dieselbe Kompaktierung (`Worker.Jack.Phase.kontext/2`) mit einer
  Zusammenfassung aus Notizen und Lesestand
  (`Worker.Jack.Resuemee.Zusammenfassung`), derselbe Systemprompt
  (`Worker.Jack.Systemprompt.pi/0`) und dasselbe Nachhaken, wenn eine
  Antwort ohne Werkzeugaufruf endet (`Worker.Jack.Phase.nachhaken/1`).

  **Anders als beim Fakten-Jack ist der Auftrag angeheftet** (Default der
  Laufzeit): der Fakten-Jack fährt `anheften: false`, weil seine Aufträge
  so gemessen sind; für das Resümee gibt es keine Messung, gegen die es
  vergleichbar bleiben müsste, und der Auftrag trägt die Überschrift, aus der
  die FORM folgt.

  Der Auftrag kommt aus `priv/jack/auftraege/resuemee_ueberblick.md`
  (`auftrag/2`).
  """

  alias Worker.Jack.{Phase, Pipeline, Systemprompt}
  alias Worker.Jack.Resuemee.{Eingabe, Halter, Stand, Werkzeuge, Zusammenfassung}

  @vorlage "resuemee_ueberblick.md"

  @doc """
  Der Überblick für eine Sitzung aus dem Repo: `Eingabe.aus_repo/1`, dann
  `laufen_ueberblick/2` mit denselben Optionen.
  """
  @spec ueberblick(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ueberblick(session_id, opts \\ []) do
    with {:ok, e} <- Eingabe.aus_repo(session_id), do: laufen_ueberblick(e, opts)
  end

  @doc """
  Fährt den Überblick auf einer Eingabe (`Worker.Jack.Resuemee.Eingabe`).

  Optionen: `:modell` (`{modul, opts}`; ohne es `Worker.Jack.Pipeline.modell/0`),
  `:kontext_fenster` (ohne es `Worker.Jack.Pipeline.kontext_fenster/0`;
  mindestens `Worker.Jack.Phase.mindestfenster/0`), `:auftrag` (Text; ohne
  ihn `auftrag/2`), `:denken_zurueck` (Default `false`), `:max_runden`
  (5000), `:max_ms` (6 Stunden), `:beobachter` (bekommt das Protokoll der
  Laufzeit), `:stand_beobachter` (bekommt den Stand, siehe
  `Worker.Jack.Resuemee.Halter`), `:protokoll` (Pfad), `:bei_stopp`
  (Default `Worker.Jack.Phase.nachhaken/1`).

  Liefert `{:ok, %{stand:, runden:, ms:}}`, wenn Jack mit `fertig`
  abschloss; sonst `{:error, {:ueberblick_ohne_abschluss, ende}}`. Eine
  Sitzung ohne Fakten ist `{:error, :keine_fakten}` — ohne Fakten gibt es
  nichts zu gliedern, und `fertig` könnte nie gelingen.
  """
  @spec laufen_ueberblick(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def laufen_ueberblick(eingabe, opts \\ []) do
    with :ok <- fakten_da(eingabe),
         {:ok, modell} <- aus_opts(opts, :modell, &Pipeline.modell/0),
         {:ok, fenster} <- fenster(opts),
         {:ok, auftrag} <- aus_opts(opts, :auftrag, fn -> auftrag(eingabe) end) do
      fahren(Stand.neu(eingabe), auftrag, modell, fenster, opts)
    end
  end

  defp fakten_da(%{fakten: [_ | _]}), do: :ok
  defp fakten_da(_eingabe), do: {:error, :keine_fakten}

  defp aus_opts(opts, schluessel, sonst) do
    case Keyword.fetch(opts, schluessel) do
      {:ok, wert} -> {:ok, wert}
      :error -> sonst.()
    end
  end

  # Ein zu kleines Fenster ist vor dem Lauf ein Fehler, statt dass die
  # Laufzeit mitten im Start mit `ArgumentError` abbricht (wie
  # `Pipeline.kontext_fenster/0`).
  defp fenster(opts) do
    mindestens = Phase.mindestfenster()

    case Keyword.fetch(opts, :kontext_fenster) do
      {:ok, n} when is_integer(n) and n >= mindestens -> {:ok, n}
      {:ok, anderes} -> {:error, {:kontext_fenster_ungueltig, anderes, mindestens}}
      :error -> Pipeline.kontext_fenster()
    end
  end

  defp fahren(s, auftrag, modell, fenster, opts) do
    {:ok, halter} = Halter.start_link(s, beobachter: opts[:stand_beobachter])

    ergebnis =
      Worker.Agent.laufen(
        modell: modell,
        system: Systemprompt.pi(),
        nachrichten: [%{role: :user, content: auftrag}],
        denken_zurueck: Keyword.get(opts, :denken_zurueck, false),
        werkzeuge: Werkzeuge.fuer(halter),
        kontext: Phase.kontext(fenster, Zusammenfassung.fuer(halter)),
        max_runden: Keyword.get(opts, :max_runden, 5000),
        max_ms: Keyword.get(opts, :max_ms, 6 * 3_600_000),
        beobachter: opts[:beobachter],
        protokoll: opts[:protokoll],
        bei_stopp: Keyword.get(opts, :bei_stopp, &Phase.nachhaken/1)
      )

    stand = Halter.stand(halter)
    Agent.stop(halter)

    case ergebnis do
      {:ok, %{ende: :halt} = b} -> {:ok, %{stand: stand, runden: b.runden, ms: b.ms}}
      _ -> {:error, {:ueberblick_ohne_abschluss, Phase.ende(ergebnis)}}
    end
  end

  @doc """
  Der Auftrag des Überblicks: die Vorlage `resuemee_ueberblick.md` aus `dir`
  (Default `priv/jack/auftraege/`), gefüllt mit `fuellen/2`. Fehlt sie, ist
  das `{:error, {:auftrag_fehlt, pfad}}`.
  """
  @spec auftrag(map(), Path.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def auftrag(eingabe, dir \\ nil) do
    pfad = Path.join(dir || Application.app_dir(:worker, "priv/jack/auftraege"), @vorlage)

    case File.read(pfad) do
      {:ok, text} -> {:ok, fuellen(text, eingabe)}
      {:error, _} -> {:error, {:auftrag_fehlt, pfad}}
    end
  end

  @doc """
  Setzt die Angaben einer Sitzung in die Vorlage ein: `{{ueberschrift}}`,
  `{{sitzung}}` (Sessionnummer), `{{anzahl_fakten}}`, `{{letzter_block}}`
  und `{{fruehere}}` (ein Satz über die früheren Sitzungen; ohne sie der
  neutrale Hinweis `Worker.Jack.Resuemee.Stand.keine_frueheren/0`).
  """
  @spec fuellen(String.t(), map()) :: String.t()
  def fuellen(text, eingabe) do
    fruehere = eingabe |> Map.get(:fruehere, []) |> Enum.map(& &1.nummer)

    text
    |> String.replace("{{ueberschrift}}", Map.get(eingabe, :ueberschrift) || "Resümee")
    |> String.replace("{{sitzung}}", to_string(eingabe.sitzung.nummer))
    |> String.replace("{{anzahl_fakten}}", Integer.to_string(length(eingabe.fakten)))
    |> String.replace(
      "{{letzter_block}}",
      Integer.to_string(max(length(Map.get(eingabe, :bloecke, [])) - 1, 0))
    )
    |> String.replace("{{fruehere}}", fruehere_text(fruehere))
  end

  defp fruehere_text([]), do: Stand.keine_frueheren()
  defp fruehere_text([n]), do: "Vor dieser Sitzung liegt Sitzung #{n}."

  defp fruehere_text(nrs),
    do: "Vor dieser Sitzung liegen die Sitzungen #{Enum.join(nrs, ", ")}."
end
