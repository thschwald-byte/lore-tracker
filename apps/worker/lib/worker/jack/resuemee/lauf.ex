defmodule Worker.Jack.Resuemee.Lauf do
  @moduledoc """
  Die Laufmechanik, die Resümee-Jack (`Worker.Jack.Resuemee`) und Epos-Jack
  (`Worker.Jack.Epos`, #1210) teilen: ein Lauf auf einer Eingabe — Fakten,
  Modell und Kontextfenster prüfen, einen Halter mit dem Stand starten,
  `Worker.Agent.laufen/1` mit dem Systemprompt, dem Auftrag, den Werkzeugen
  und der Kompaktierung fahren, danach den Stand abholen — und das Füllen der
  Auftragsvorlagen.

  Was je Jack verschieden ist, kommt als Map herein (`starten/6`, `jack`):
  `:werkzeuge` (`fn halter -> [Worker.Agent.Werkzeug] end`),
  `:zusammenfassung` (`fn halter -> Rückruf für die Kompaktierung end`) und
  optional `:abbild` (`fn stand -> map end`, was ein Beobachter bekommt —
  ohne es `Worker.Jack.Resuemee.Stand.abbild/1`, siehe
  `Worker.Jack.Resuemee.Halter`).

  Aus `Worker.Jack.Resuemee` herausgezogen (E1, #1210), ohne am Verhalten des
  Resümee-Jack etwas zu ändern. Es liegt vorerst im Namensraum des
  Resümee-Jack, wie die übrigen gemeinsam genutzten Teile (Lesebasis, Suche,
  Halter, Abschluss-Mechanik); sie in einen neutralen Namensraum zu
  verschieben ist ein eigener Schritt, damit dieser hier keine Umbenennung
  quer durch die Tests braucht.
  """

  alias Worker.Jack.{Phase, Pipeline, Systemprompt}
  alias Worker.Jack.Resuemee.{Halter, Stand}

  @doc """
  Fährt einen Lauf: `stand` und `auftrag` sind Funktionen ohne Argument (der
  Auftrag darf `{:ok, text}` oder `{:error, grund}` liefern und entfällt,
  wenn `opts[:auftrag]` gesetzt ist), `fehler` die Marke für einen Lauf ohne
  Abschluss, `jack` die Teile des Jack (Moduledoc).

  Optionen: `:modell` (ohne es `Worker.Jack.Pipeline.modell/0`),
  `:kontext_fenster` (ohne es `Worker.Jack.Pipeline.kontext_fenster/0`;
  mindestens `Worker.Jack.Phase.mindestfenster/0`), `:auftrag`,
  `:denken_zurueck` (Default `false`), `:max_runden` (5000), `:max_ms`
  (6 Stunden), `:beobachter`, `:stand_beobachter`, `:protokoll`, `:bei_stopp`
  (Default `Worker.Jack.Phase.nachhaken/1`).

  Liefert `{:ok, %{stand:, runden:, ms:}}`, wenn der Jack mit `fertig`
  abschloss, sonst `{:error, {fehler, ende}}`; ohne Fakten
  `{:error, :keine_fakten}`.
  """
  @spec starten(map(), keyword(), (-> Stand.t()), (-> term()), atom(), map()) ::
          {:ok, map()} | {:error, term()}
  def starten(eingabe, opts, stand, auftrag, fehler, jack) do
    with :ok <- Keyword.get(opts, :vorbedingung, &fakten_da/1).(eingabe),
         {:ok, modell} <- aus_opts(opts, :modell, &Pipeline.modell/0),
         {:ok, fenster} <- fenster(opts),
         {:ok, auftrag} <- aus_opts(opts, :auftrag, auftrag) do
      case fahren(stand.(), auftrag, modell, fenster, opts, jack) do
        {:ok, r} -> {:ok, r}
        {:error, ende} -> {:error, {fehler, ende}}
      end
    end
  end

  @doc """
  `:ok`, wenn die Eingabe Fakten hat, sonst `{:error, :keine_fakten}`.

  **Die Vorbedingung ist seit #1247 wählbar** (Option `:vorbedingung`): Der
  Zeit-Jack arbeitet auf den Äußerungen, nicht auf den Fakten — für ihn ist
  ein leerer Mitschnitt der Abbruchgrund, und eine Sitzung ohne Fakten kein
  Hindernis.
  """
  @spec fakten_da(map()) :: :ok | {:error, :keine_fakten}
  def fakten_da(%{fakten: [_ | _]}), do: :ok
  def fakten_da(_eingabe), do: {:error, :keine_fakten}

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

  defp fahren(s, auftrag, modell, fenster, opts, jack) do
    {:ok, halter} =
      Halter.start_link(s, beobachter: opts[:stand_beobachter], abbild: jack[:abbild])

    ergebnis =
      Worker.Agent.laufen(
        modell: modell,
        system: Systemprompt.pi(),
        nachrichten: [%{role: :user, content: auftrag}],
        denken_zurueck: Keyword.get(opts, :denken_zurueck, false),
        werkzeuge: jack.werkzeuge.(halter),
        kontext: Phase.kontext(fenster, jack.zusammenfassung.(halter)),
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
      _ -> {:error, Phase.ende(ergebnis)}
    end
  end

  # ─── Vorlagen ─────────────────────────────────────────────────────────

  @doc """
  Eine Auftragsvorlage aus `dir` (Default `priv/jack/auftraege/`). Fehlt sie,
  ist das `{:error, {:auftrag_fehlt, pfad}}`.
  """
  @spec vorlage(String.t(), Path.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def vorlage(name, dir) do
    pfad = Path.join(dir || Application.app_dir(:worker, "priv/jack/auftraege"), name)

    case File.read(pfad) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> {:error, {:auftrag_fehlt, pfad}}
    end
  end

  @doc """
  Setzt `werte` (Name → Text) für die Platzhalter `{{name}}` ein, in einem
  Durchgang: was eingesetzt wird (Ton und Notizen sind Text von Menschen bzw.
  vom Modell), wird nicht noch einmal nach Platzhaltern durchsucht.
  Unbekannte Platzhalter bleiben stehen.
  """
  @spec einsetzen(String.t(), %{String.t() => String.t()}) :: String.t()
  def einsetzen(text, werte),
    do: Regex.replace(~r/\{\{(\w+)\}\}/, text, fn ganz, name -> Map.get(werte, name, ganz) end)

  @doc """
  Ein Satz über die früheren Sitzungen (ihre Nummern); ohne sie der neutrale
  Hinweis `Worker.Jack.Resuemee.Stand.keine_frueheren/0`.
  """
  @spec fruehere_text([pos_integer()]) :: String.t()
  def fruehere_text([]), do: Stand.keine_frueheren()
  def fruehere_text([n]), do: "Vor dieser Sitzung liegt Sitzung #{n}."

  def fruehere_text(nrs),
    do: "Vor dieser Sitzung liegen die Sitzungen #{Enum.join(nrs, ", ")}."
end
