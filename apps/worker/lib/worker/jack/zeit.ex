defmodule Worker.Jack.Zeit do
  @moduledoc """
  #1247: der Zeit-Jack — er bringt die **Äußerungen** einer Kampagne in eine
  zeitliche Reihe.

  ## Warum die Zeit an den Äußerungen hängt und nicht an den Fakten

  Bis hierher trug der **Fakt** die Zeit, in Feldern, die die Extraktion
  nebenbei ausfüllte. Das hat nicht getragen, und zwar belegt: 543 von 544
  Chronik-Einträgen einer echten Kampagne lagen auf demselben Tag (#1092),
  der deterministische Zeit-Vorlauf war gemessen wirkungslos (#1213), und
  zwei der drei Ankerformen kamen in echten Daten **null Mal** vor (#1109).

  Ein Fakt ist auch der falsche Träger: Er entsteht bei jeder Extraktion neu,
  seine ID hängt am Wortlaut, und eine Zeitangabe an ihm ist nach dem
  nächsten Regenerate weg. **Utterances werden nie neu erstellt** — sie sind
  die stabilste Schicht des Systems.

  ## Die drei Läufe

      :gedaechtnis   Die Fakten lesen, den Ablauf verstehen. Setzt nichts.
      :einsortieren  Durch den Mitschnitt gehen und einordnen.
      :pruefen       Die entstandene Linie lesen und geraderücken.

  **Zwei Läufe mit verschiedenen Aufträgen, keine Iteration bis zur
  Sättigung** (Maintainer, 19.09.2026: „ein neue einsortieren lauf und ein
  alles prüfen lauf"). Ein wiederholter Durchgang sähe zweimal dasselbe; der
  Prüf-Lauf hat einen anderen **Gegenstand** — die entstandene Linie statt
  des Mitschnitts.

  ## Anders als die Extraktion sieht dieser Jack sein Ergebnis

  Die Extraktion hält den Bestand bewusst verborgen (`Worker.Jack.Tor`).
  Hier ist es umgekehrt, und es muss so sein: Ein einzelner Anker kann für
  sich richtig sein und die Reihe trotzdem falsch. Das ist nur am
  **gerechneten** Ergebnis zu sehen, und genau das zeigt `linie()`
  (Maintainer, 19.09.2026: „im unterschied zur extraction das timejack die
  ergebnisse anschauen").

  ## Best effort in beide Richtungen

  Scheitert ein Lauf, behält er, was er gesetzt hat — jeder Anker ist
  einzeln geprüft, und ein abgebrochener Durchgang ist keine Rücknahme. Die
  folgenden Stufen (Resümee, Chronik, Epos) laufen weiter; eine Linie ist
  eine Verbesserung, keine Vorbedingung.
  """

  require Logger

  alias Worker.Jack.Resuemee.{Lauf, Melder}
  alias Worker.Jack.Zeit.{Auftrag, Speicher, Stand, Werkzeuge, Zusammenfassung}

  @stufe_gedaechtnis "zeit_gedaechtnis"
  @stufe_zeit "zeit"

  @doc """
  Fährt die Läufe und liefert den Stand des letzten, der durchkam.

  `eingabe` ist eine Map mit `:kampagne`, `:mitschnitt`, `:fakten`, `:anker`,
  `:kalender`, `:session_id`, `:campaign_id` (s. `Worker.Jack.Zeit.Eingabe`).
  Optionen wie bei den anderen Jacks: `:melde_stufe`, `:modell`,
  `:kontext_fenster`, `:max_runden`, `:max_ms`, `:beobachter`,
  `:stand_beobachter`.
  """
  @spec laufen(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def laufen(eingabe, opts \\ []) do
    melde = Keyword.get(opts, :melde_stufe) || fn _stufe, _ereignis -> :ok end
    opts = Keyword.delete(opts, :melde_stufe)

    with {:ok, g} <-
           Melder.gemeldet(@stufe_gedaechtnis, melde, opts, &lauf(eingabe, :gedaechtnis, &1)),
         eingabe = Map.put(eingabe, :notizen, notizen(g)),
         {:ok, e} <- Melder.gemeldet(@stufe_zeit, melde, opts, &lauf(eingabe, :einsortieren, &1)) do
      {:ok, ergebnis(e, pruefen(eingabe, e, opts))}
    end
  end

  # **Der Prüf-Lauf ist best-effort, auch gegen einen RAISE** — dieselbe
  # Lehre wie bei der Chronik-Durchsicht (#1211): Dort starb am 18.09.2026
  # die letzte, verzichtbare Stufe an `{:badmap, nil}`, riss den Prozess mit,
  # und die Arbeit von 31 Minuten wurde nie veröffentlicht. Was der
  # Einsortier-Lauf gesetzt hat, gilt auch dann, wenn die Prüfung stirbt.
  defp pruefen(eingabe, e, opts) do
    if Keyword.get(opts, :pruefen, true) do
      # **Der Prüf-Lauf erbt, was der Einsortier-Lauf getan hat** (#1247):
      # die Anker, die Notizen — und die Leseabdeckung samt Einordnung.
      # Ohne das Letzte musste er 2168 Zeilen ein zweites Mal lesen und ein
      # zweites Mal einordnen, nur um abschliessen zu dürfen. Sein Auftrag
      # sagt das Gegenteil („geh von den Befunden aus, nicht von Zeile 1"),
      # und die Schranke gewann: Im Lauf vom 19.09.2026 verbrachte er über
      # neunzig Runden damit, die Linie abzusuchen, statt sie zu prüfen.
      eingabe = Map.merge(eingabe, erbe(e.stand))

      case lauf(eingabe, :pruefen, opts) do
        {:ok, p} ->
          p

        {:error, grund} ->
          Logger.warning(
            "Zeit-Jack: Prüf-Lauf gescheitert, es gilt die Linie aus dem " <>
              "Einsortieren: #{inspect(grund, limit: 20)}"
          )

          nil
      end
    end
  rescue
    e ->
      Logger.warning("Zeit-Jack: Prüf-Lauf mit Ausnahme beendet: #{Exception.message(e)}")
      nil
  end

  # Der Prüf-Lauf gewinnt, wenn er durchkam — er hat denselben Bestand
  # gesehen und ihn geradegerückt.
  defp ergebnis(e, nil), do: %{stand: e.stand, runden: e.runden, ms: e.ms, geprueft?: false}
  defp ergebnis(_e, p), do: %{stand: p.stand, runden: p.runden, ms: p.ms, geprueft?: true}

  defp notizen(%{stand: %Stand{notizen: n}}), do: n
  defp notizen(_), do: %{}

  @doc "Ein einzelner Lauf. Öffentlich, damit man ihn einzeln fahren kann."
  @spec lauf(map(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def lauf(eingabe, art, opts \\ []) do
    Lauf.starten(
      eingabe,
      Keyword.put(opts, :vorbedingung, &mitschnitt_da/1),
      fn -> stand(eingabe, art) end,
      fn -> Auftrag.fuer(stand(eingabe, art), Map.get(eingabe, :kampagne, "")) end,
      fehlerklasse(art),
      jack()
    )
  end

  # **Die Vorbedingung ist der Mitschnitt, nicht die Fakten** (Maintainer,
  # 19.09.2026: „wir stellen den jacklauf ganz auf die utts um"). Alle drei
  # Läufe lesen die Äußerungen; eine Sitzung ohne Fakten ist für den
  # Zeit-Jack kein Hindernis, eine ohne Mitschnitt schon.
  defp mitschnitt_da(%{mitschnitt: [_ | _]}), do: :ok
  defp mitschnitt_da(_), do: {:error, :kein_mitschnitt}

  defp fehlerklasse(:gedaechtnis), do: :zeit_gedaechtnis_ohne_abschluss
  defp fehlerklasse(:pruefen), do: :zeit_pruefen_ohne_abschluss
  defp fehlerklasse(_), do: :zeit_einsortieren_ohne_abschluss

  @doc """
  Was der Prüf-Lauf vom Einsortier-Lauf erbt — **die eine Liste**, aus der
  beide Seiten lesen.

  Sie stand vorher an zwei Stellen: `pruefen/3` legte die Felder in die
  Eingabe, `stand/2` holte sie heraus. Genau das ging schief (20.09.2026):
  `kette` wurde übergeben und **nie ausgepackt**, obwohl `Stand.neu/3` sie
  kennt und ihr Kommentar dort die Vererbung ausdrücklich zusagt. Der
  Prüf-Lauf startete also vor einer leeren Kette, baute keine — sein Auftrag
  sagt ihm, er solle von den Befunden ausgehen — und sein Stand gewinnt am
  Ende. **Die ganze Einsortier-Arbeit eines Laufs war damit weg**, sichtbar
  nur an einem Widerspruch in den Zahlen: 2168 Zeilen eingeordnet, null in
  der Kette. Ein fehlender Schlüssel erzeugt keinen Fehler, nur ein leeres
  Ergebnis — dieselbe Klasse wie die vergessenen Permission-Assigns (#1090).
  """
  @spec erbe(Stand.t()) :: map()
  def erbe(%Stand{} = stand) do
    %{
      anker: Map.values(stand.anker),
      notizen: stand.notizen,
      gelesen: stand.gelesen,
      einordnung: stand.einordnung,
      kette: stand.kette,
      # #1247: der Blick über die Sitzungsgrenze reist mit. Ohne das hätte der
      # Prüf-Lauf keine Sitzungsübersicht, keinen Lader und keine schon
      # geladenen Mitschnitte — er lüde jeden fremden Mitschnitt ein zweites
      # Mal, und `sitzungen()` wüsste nichts.
      sitzung_nr: stand.sitzung_nr,
      sitzungen: stand.sitzungen,
      lader: stand.lader,
      mitschnitte: stand.mitschnitte,
      vorige_notizen: stand.vorige_notizen,
      konflikte: stand.konflikte
    }
  end

  defp stand(eingabe, art) do
    geerbt = for {k, _} <- erbe(%Stand{}), do: {k, Map.get(eingabe, k)}

    Stand.neu(
      art,
      Map.get(eingabe, :mitschnitt, []),
      [
        session_id: Map.get(eingabe, :session_id),
        campaign_id: Map.get(eingabe, :campaign_id),
        kalender: Map.get(eingabe, :kalender)
      ] ++ geerbt
    )
  end

  # **`nach_aufruf` sichert nach JEDEM Werkzeugaufruf** (Maintainer,
  # 24.09.2026). Vorher wurde erst nach `laufen/2` veröffentlicht — und an
  # einem Tag sind zwei Läufe von je rund einer Stunde verloren gegangen, weil
  # sie das Ende nie erreichten (Wiederholungsschleife, Wiederholungssperre).
  # Was eingetragen ist, steht damit in der Datenbank, auch wenn der Lauf
  # danach scheitert.
  defp jack,
    do: %{
      werkzeuge: &Werkzeuge.fuer/1,
      zusammenfassung: &Zusammenfassung.fuer/1,
      abbild: &Stand.abbild/1,
      nach_aufruf: &Speicher.sichern/1
    }
end
