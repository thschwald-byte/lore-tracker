defmodule Worker.Agent.Lauf do
  @moduledoc """
  Die Schleife eines Agenten: Modellantwort holen, Werkzeugaufrufe ausführen,
  Ergebnisse anhängen, weiter — bis das Modell ohne Werkzeugaufruf endet, die
  Werkzeuge den Lauf beenden oder ein Deckel greift.

  Aufbau nach pi (`agent-loop.js`: `runLoop`, `executeToolCalls`,
  `prepareToolCall`, `failToolCallsFromTruncatedMessage`,
  `shouldTerminateToolBatch`, `getFollowUpMessages`), siehe `Worker.Agent`.
  Was schiefgehen kann, wird zu einem **Fehlerergebnis mit Text**, auf den
  das Modell reagieren kann, nie zu einem Absturz: unbekanntes Werkzeug,
  Argumente, die kein JSON-Objekt sind, Verstoß gegen das Schema, Ausnahme im
  Werkzeug, und eine Antwort, die an der Ausgabegrenze abgeschnitten wurde —
  dann werden **alle** ihre Aufrufe abgelehnt, weil jedes Argument
  abgeschnitten sein kann.

  Bewusst anders als pi:

    * **Werkzeuge laufen nacheinander im Prozess des Aufrufers**, in der
      Reihenfolge der Antwort. pi führt sie parallel aus; unsere Werkzeuge
      werden in Mnesia schreiben, und eine feste Reihenfolge macht einen Lauf
      nachvollziehbar. Ein langsames Werkzeug hält damit die Runde auf.
    * **Kein Abbruchsignal.** Die Wanduhr wird vor jedem Modellaufruf
      geprüft; einen laufenden Aufruf beendet nur dessen eigene HTTP-Frist.
      Ein Lauf kann `max_ms` also um bis zu eine Frist überziehen. Gestreamt
      wird nur für einen Beobachter (`:beobachter`); die Schleife selbst
      wartet immer auf die ganze Antwort.
    * **Der Auftrag ist angeheftet** und fällt keiner Kompaktierung zum Opfer.
      pi fasst ihn mit zusammen; bei einem Hintergrundjob ist er aber das,
      woran der ganze Lauf hängt.

  ## Optionen

    * `:modell` (Pflicht) — `{modul, opts}`; `modul` implementiert `Worker.Agent.Modell`.
    * `:system` (Pflicht) — der Systemprompt.
    * `:nachrichten` (Pflicht) — der Auftrag, eine nicht leere Liste von
      `%{role: :user, content: text}`.
    * `:werkzeuge` — Liste von `Worker.Agent.Werkzeug`, Namen eindeutig.
    * `:max_runden` — höchstens so viele Modellaufrufe (Default 100).
    * `:max_ms` — Wanduhr in Millisekunden (Default eine Stunde).
    * `:kontext` — `[fenster:, reserve:, behalten:, zusammenfassen:]`, siehe
      `Worker.Agent.Kontext`. Ohne diese Option wird nie kompaktiert.
    * `:bei_stopp` — `fn %{runde:, text:, stopp:} -> :fertig | {:weiter, text} end`,
      aufgerufen, wenn das Modell ohne Werkzeugaufruf endet. `{:weiter, text}`
      hängt `text` als Nachricht an und macht weiter. Default: `:fertig`.
    * `:protokoll` — Pfad einer JSONL-Datei, siehe `Worker.Agent.Protokoll`.
    * `:beobachter` — ein Prozess, der jede Protokollzeile als Nachricht
      `{:agent, daten}` bekommt, dazu die Deltas des Modells (`"delta"`, nur
      für ihn). Mit Beobachter bekommt das Modell `bei_delta` und streamt
      (siehe `Worker.Agent.Modell.Ollama`). Für die lokale Laufsicht (#1202).
    * `:wiederholungen` — `[warnung: n, abbruch: m]`: ab dem n-ten gleichen
      Aufruf im Lauf wird er nicht mehr ausgeführt und die Antwort ist eine
      Warnung, beim m-ten wird der Lauf abgebrochen (Default
      `[warnung: 4, abbruch: 6]`, `false` schaltet ab), siehe
      `Worker.Agent.Wiederholung`.

  Falsche Optionen und ein falscher Rückgabewert von `bei_stopp` oder
  `zusammenfassen` sind Programmierfehler und werfen `ArgumentError`.

  ## Ergebnis

  `{:ok, bericht}` bei `ende: :fertig` oder `:halt`; `{:error, bericht}` bei
  `{:deckel, :runden}`, `{:deckel, :zeit}`, `{:modell_fehler, grund}` oder
  `{:abbruch, {:wiederholung | :werkzeug, name}}` — die Wiederholungssperre
  oder ein Werkzeug hat den Lauf abgebrochen. Der
  Bericht trägt den Verlauf, wie ihn das Modell zuletzt gesehen hat — auch ein
  abgebrochener Lauf bleibt damit auswertbar.
  """

  alias Worker.Agent.{Kontext, Modell, Protokoll, Schema, Werkzeug, Wiederholung}

  @default_runden 100
  @default_ms 3_600_000

  @type ende ::
          :fertig
          | :halt
          | {:deckel, :runden | :zeit}
          | {:modell_fehler, term()}
          | {:abbruch, {:wiederholung | :werkzeug, String.t()}}
  @type bericht :: %{
          ende: ende(),
          runden: non_neg_integer(),
          nachrichten: [map()],
          kompaktierungen: non_neg_integer(),
          nutzung: Modell.nutzung(),
          ms: non_neg_integer()
        }
  @type ergebnis :: {:ok, bericht()} | {:error, bericht()}

  @enforce_keys [
    :modell,
    :system,
    :angeheftet,
    :werkzeuge,
    :werkzeug_liste,
    :max_runden,
    :max_ms,
    :kontext,
    :bei_stopp,
    :wiederholung,
    :start_ms
  ]
  defstruct @enforce_keys ++
              [
                protokoll: %Protokoll{},
                verlauf: [],
                zusammenfassung: nil,
                basis: nil,
                runde: 0,
                kompaktierungen: 0,
                abbruch: nil,
                nutzung: %{eingabe: 0, ausgabe: 0}
              ]

  @doc "Führt einen Lauf aus; Optionen und Ergebnis siehe Moduldoku."
  @spec laufen(keyword()) :: ergebnis()
  def laufen(opts) do
    s = neu(opts)
    protokoll = Protokoll.oeffnen(Keyword.get(opts, :protokoll), Keyword.get(opts, :beobachter))
    s = %{s | protokoll: protokoll}

    try do
      {modul, modell_opts} = s.modell

      Protokoll.schreiben(protokoll, "start", %{
        "modell" => inspect(modul),
        "modell_name" => modell_opts[:modell],
        "werkzeuge" => Enum.map(s.werkzeug_liste, & &1.name),
        "max_runden" => s.max_runden,
        "max_ms" => s.max_ms,
        "kontext_fenster" => s.kontext && s.kontext.fenster
      })

      s |> schleife() |> abschluss()
    after
      Protokoll.schliessen(protokoll)
    end
  end

  # ─── Die Schleife ─────────────────────────────────────────────────────

  defp schleife(s) do
    cond do
      s.runde >= s.max_runden -> {s, {:deckel, :runden}}
      verstrichen(s) > s.max_ms -> {s, {:deckel, :zeit}}
      true -> s |> vielleicht_kompaktieren() |> runde()
    end
  end

  defp runde(s) do
    s = %{s | runde: s.runde + 1}
    nachrichten = nachrichten(s)

    Protokoll.schreiben(s.protokoll, "anfrage", %{
      "runde" => s.runde,
      "nachrichten" => length(nachrichten)
    })

    t0 = System.monotonic_time(:millisecond)
    antwort = Modell.aufrufen(modell_mit_deltas(s), nachrichten, s.werkzeug_liste)
    ms = System.monotonic_time(:millisecond) - t0

    case antwort do
      {:ok, a} ->
        s |> antwort_anhaengen(a, ms) |> nach_antwort(a)

      {:error, grund} ->
        Protokoll.schreiben(s.protokoll, "modell_fehler", %{
          "runde" => s.runde,
          "ms" => ms,
          "grund" => inspect(grund)
        })

        {s, {:modell_fehler, grund}}
    end
  end

  # Mit Beobachter streamt das Modell: Denken und Text gehen Stück für Stück
  # an ihn, statt erst mit der fertigen Antwort (#1202, Tom: „Echtzeit“).
  defp modell_mit_deltas(%{protokoll: %Protokoll{beobachter: nil}, modell: modell}), do: modell

  defp modell_mit_deltas(%{modell: {modul, opts}, protokoll: p, runde: runde}) do
    melden = fn art, text ->
      Protokoll.melden(p, "delta", %{
        "runde" => runde,
        "art" => Atom.to_string(art),
        "text" => text
      })
    end

    {modul, Keyword.put(opts, :bei_delta, melden)}
  end

  defp nach_antwort(s, %{aufrufe: []} = a), do: gestoppt(s, a)

  defp nach_antwort(s, %{stopp: :laenge, aufrufe: aufrufe}) do
    s
    |> ergebnisse_anhaengen(Enum.map(aufrufe, &{&1, {:error, abgeschnitten(&1)}}))
    |> schleife()
  end

  defp nach_antwort(s, %{aufrufe: aufrufe}) do
    {ergebnisse, s} = Enum.map_reduce(aufrufe, s, &ausfuehren_beobachtet/2)
    s = ergebnisse_anhaengen(s, ergebnisse)

    cond do
      s.abbruch -> {s, {:abbruch, s.abbruch}}
      Enum.all?(ergebnisse, &match?({_, {:halt, _}}, &1)) -> {s, :halt}
      true -> schleife(s)
    end
  end

  defp gestoppt(s, a) do
    case s.bei_stopp.(%{runde: s.runde, text: a.text, stopp: a.stopp}) do
      :fertig ->
        {s, :fertig}

      {:weiter, text} when is_binary(text) ->
        Protokoll.schreiben(s.protokoll, "folge", %{"runde" => s.runde, "text" => text})
        s |> anhaengen(%{role: :user, content: text}) |> schleife()

      anderes ->
        raise ArgumentError,
              "bei_stopp lieferte #{inspect(anderes)}, erwartet :fertig oder {:weiter, text}"
    end
  end

  defp abschluss({s, ende}) do
    bericht = %{
      ende: ende,
      runden: s.runde,
      nachrichten: nachrichten(s),
      kompaktierungen: s.kompaktierungen,
      nutzung: s.nutzung,
      ms: verstrichen(s)
    }

    Protokoll.schreiben(s.protokoll, "ende", %{
      "ende" => inspect(ende),
      "runden" => s.runde,
      "kompaktierungen" => s.kompaktierungen,
      "nutzung" => s.nutzung,
      "ms" => bericht.ms
    })

    if ende in [:fertig, :halt], do: {:ok, bericht}, else: {:error, bericht}
  end

  # ─── Werkzeuge ────────────────────────────────────────────────────────

  # Erst der Wiederholungssperre zeigen, dann ausführen. Ab der Warnschwelle
  # läuft der Aufruf nicht mehr, seine Antwort ist die Warnung (Tom: „der
  # gewarnte wird nicht ausgeführt, und das steht auch in der Antwort“); an
  # der Abbruchschwelle endet der Lauf. Ist er abgebrochen, laufen auch die
  # übrigen Aufrufe derselben Antwort nicht, bekommen aber eine Antwort —
  # jeder Aufruf braucht ein Ergebnis.
  defp ausfuehren_beobachtet(aufruf, %{abbruch: grund} = s) when grund != nil,
    do: {{aufruf, {:error, "Nicht ausgeführt: der Lauf ist abgebrochen."}}, s}

  defp ausfuehren_beobachtet(aufruf, s) do
    werkzeug = Map.get(s.werkzeuge, aufruf.name)
    art_zaehlung = if werkzeug, do: werkzeug.wiederholung, else: :zaehlt

    {w, status} =
      if art_zaehlung == :frei,
        do: {s.wiederholung, nil},
        else:
          Wiederholung.beobachten(
            s.wiederholung,
            {aufruf.name, aufruf.argumente},
            art_zaehlung
          )

    s = %{s | wiederholung: w}
    if status, do: wiederholung_protokollieren(s, aufruf, status)

    case status do
      {:abbruch, n} ->
        {{aufruf, {:abbruch, Wiederholung.abbruch(aufruf.name, n)}},
         %{s | abbruch: {:wiederholung, aufruf.name}}}

      {:warnung, n} ->
        {{aufruf, {:error, Wiederholung.warnung(aufruf.name, n, w.abbruch)}}, s}

      nil ->
        {art, text} = ausfuehren(aufruf, s.werkzeuge)

        s =
          cond do
            art == :abbruch ->
              %{s | abbruch: {:werkzeug, aufruf.name}}

            art == :ok and werkzeug != nil and werkzeug.aendert_bestand ->
              %{s | wiederholung: Wiederholung.bestand_geaendert(s.wiederholung)}

            true ->
              s
          end

        {{aufruf, {art, text}}, s}
    end
  end

  defp wiederholung_protokollieren(s, aufruf, {folge, anzahl}) do
    Protokoll.schreiben(s.protokoll, "wiederholung", %{
      "runde" => s.runde,
      "id" => aufruf.id,
      "name" => aufruf.name,
      "anzahl" => anzahl,
      "folge" => Atom.to_string(folge)
    })
  end

  defp ausfuehren(%{name: name} = aufruf, werkzeuge) do
    with {:ok, w} <- finden(werkzeuge, name),
         {:ok, argumente} <- argumente(aufruf),
         {:ok, argumente} <- pruefen(w, argumente) do
      sicher_ausfuehren(w, argumente)
    end
  end

  defp finden(werkzeuge, name) do
    case Map.fetch(werkzeuge, name) do
      {:ok, w} ->
        {:ok, w}

      :error ->
        verfuegbar = werkzeuge |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        {:error, "Werkzeug #{inspect(name)} gibt es nicht. Verfügbar: #{verfuegbar}."}
    end
  end

  defp argumente(%{argumente: {:ok, argumente}}), do: {:ok, argumente}

  defp argumente(%{name: name, argumente: {:error, roh}}),
    do: {:error, "Die Argumente für #{name} sind kein JSON-Objekt:\n#{roh}"}

  defp pruefen(w, argumente) do
    case Schema.pruefen(w.parameter, argumente) do
      {:ok, angeglichen} ->
        {:ok, angeglichen}

      {:error, verstoesse} ->
        {:error,
         "Argumente für #{w.name} ungültig:\n" <>
           Enum.map_join(verstoesse, "\n", &"  - #{&1}") <>
           "\n\nErhalten:\n" <> Jason.encode!(argumente, pretty: true)}
    end
  end

  defp sicher_ausfuehren(w, argumente) do
    case w.ausfuehren.(argumente) do
      {art, inhalt} when art in [:ok, :error, :halt, :abbruch] ->
        {art, als_text(inhalt)}

      anderes ->
        {:error, "Werkzeug #{w.name} lieferte ein ungültiges Ergebnis: #{inspect(anderes)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    art, grund -> {:error, "#{art}: #{inspect(grund)}"}
  end

  defp als_text(text) when is_binary(text), do: text
  defp als_text(inhalt), do: Jason.encode!(inhalt)

  defp abgeschnitten(%{name: name}) do
    "Werkzeugaufruf #{name} wurde nicht ausgeführt: die Antwort ist an die Ausgabegrenze " <>
      "gestoßen, die Argumente können abgeschnitten sein. Wiederhole den Aufruf mit " <>
      "vollständigen Argumenten."
  end

  # ─── Verlauf ──────────────────────────────────────────────────────────

  defp nachrichten(s), do: fest(s) ++ s.verlauf

  defp fest(s) do
    zusammenfassung =
      if s.zusammenfassung, do: [%{role: :user, content: s.zusammenfassung}], else: []

    [%{role: :system, content: s.system} | s.angeheftet] ++ zusammenfassung
  end

  defp anhaengen(s, nachricht), do: %{s | verlauf: s.verlauf ++ [nachricht]}

  defp antwort_anhaengen(s, a, ms) do
    Protokoll.schreiben(s.protokoll, "antwort", %{
      "runde" => s.runde,
      "ms" => ms,
      "stopp" => Atom.to_string(a.stopp),
      "text" => a.text,
      "denken" => a.denken,
      "aufrufe" => Enum.map(a.aufrufe, &aufruf_json/1),
      "nutzung" => a.nutzung
    })

    s = anhaengen(s, %{role: :assistant, content: a.text, tool_calls: a.aufrufe})
    %{s | basis: basis(a.nutzung, s.verlauf), nutzung: summieren(s.nutzung, a.nutzung)}
  end

  defp ergebnisse_anhaengen(s, ergebnisse) do
    Enum.reduce(ergebnisse, s, fn {aufruf, {art, text}}, acc ->
      Protokoll.schreiben(acc.protokoll, "ergebnis", %{
        "runde" => acc.runde,
        "id" => aufruf.id,
        "name" => aufruf.name,
        "art" => Atom.to_string(art),
        "text" => text
      })

      anhaengen(acc, %{
        role: :tool,
        tool_call_id: aufruf.id,
        name: aufruf.name,
        content: text,
        fehler: art in [:error, :abbruch]
      })
    end)
  end

  defp aufruf_json(%{id: id, name: name, argumente: {:ok, argumente}}),
    do: %{"id" => id, "name" => name, "argumente" => argumente}

  defp aufruf_json(%{id: id, name: name, argumente: {:error, roh}}),
    do: %{"id" => id, "name" => name, "roh" => roh}

  defp basis(nil, _verlauf), do: nil
  defp basis(%{eingabe: e, ausgabe: a}, verlauf), do: {e + a, length(verlauf)}

  defp summieren(summe, nil), do: summe

  defp summieren(summe, %{eingabe: e, ausgabe: a}),
    do: %{eingabe: summe.eingabe + e, ausgabe: summe.ausgabe + a}

  # ─── Kompaktierung ────────────────────────────────────────────────────

  defp vielleicht_kompaktieren(%{kontext: nil} = s), do: s

  defp vielleicht_kompaktieren(%{kontext: k} = s) do
    tokens = Kontext.tokens(fest(s), s.verlauf, s.basis)
    if Kontext.voll?(tokens, k.fenster, k.reserve), do: kompaktieren(s, tokens), else: s
  end

  defp kompaktieren(s, tokens) do
    case Kontext.schnitt(s.verlauf, s.kontext.behalten) do
      0 ->
        Protokoll.schreiben(s.protokoll, "kompaktierung", %{
          "runde" => s.runde,
          "tokens" => tokens,
          "weggefallen" => 0
        })

        s

      i ->
        {weg, bleibt} = Enum.split(s.verlauf, i)
        text = zusammenfassen(s, weg)

        Protokoll.schreiben(s.protokoll, "kompaktierung", %{
          "runde" => s.runde,
          "tokens" => tokens,
          "weggefallen" => i,
          "behalten" => length(bleibt),
          "zusammenfassung" => text
        })

        %{
          s
          | verlauf: bleibt,
            zusammenfassung: text,
            basis: nil,
            kompaktierungen: s.kompaktierungen + 1
        }
    end
  end

  defp zusammenfassen(s, weg) do
    case s.kontext.zusammenfassen.(%{weggefallen: weg, vorherige: s.zusammenfassung}) do
      text when is_binary(text) ->
        text

      anderes ->
        raise ArgumentError, "zusammenfassen lieferte #{inspect(anderes)}, erwartet einen Text"
    end
  end

  # ─── Optionen ─────────────────────────────────────────────────────────

  defp neu(opts) do
    werkzeuge = Keyword.get(opts, :werkzeuge, [])

    %__MODULE__{
      modell: modell!(Keyword.fetch!(opts, :modell)),
      system: text!(Keyword.fetch!(opts, :system), :system),
      angeheftet: auftrag!(Keyword.fetch!(opts, :nachrichten)),
      werkzeuge: werkzeuge!(werkzeuge),
      werkzeug_liste: werkzeuge,
      max_runden: positiv!(Keyword.get(opts, :max_runden, @default_runden), :max_runden),
      max_ms: positiv!(Keyword.get(opts, :max_ms, @default_ms), :max_ms),
      kontext: kontext!(Keyword.get(opts, :kontext)),
      bei_stopp: funktion!(Keyword.get(opts, :bei_stopp, fn _info -> :fertig end), :bei_stopp),
      wiederholung: wiederholung!(Keyword.get(opts, :wiederholungen, [])),
      start_ms: System.monotonic_time(:millisecond)
    }
  end

  defp wiederholung!(false), do: nil

  defp wiederholung!(opts) when is_list(opts) do
    case Wiederholung.neu(opts) do
      {:ok, w} -> w
      {:error, grund} -> raise ArgumentError, "wiederholungen: #{grund}"
    end
  end

  defp wiederholung!(anderes),
    do:
      raise(
        ArgumentError,
        "wiederholungen: [warnung: n, abbruch: m] oder false erwartet, erhalten #{inspect(anderes)}"
      )

  defp modell!({modul, opts} = modell) when is_atom(modul) and is_list(opts) do
    if Code.ensure_loaded?(modul) and function_exported?(modul, :antworten, 3),
      do: modell,
      else:
        raise(ArgumentError, "modell: #{inspect(modul)} implementiert Worker.Agent.Modell nicht")
  end

  defp modell!(anderes),
    do: raise(ArgumentError, "modell: erwartet {modul, opts}, erhalten #{inspect(anderes)}")

  defp auftrag!([_ | _] = nachrichten) do
    if Enum.all?(nachrichten, &match?(%{role: :user, content: text} when is_binary(text), &1)),
      do: nachrichten,
      else: raise(ArgumentError, "nachrichten: nur %{role: :user, content: text} erlaubt")
  end

  defp auftrag!(anderes),
    do:
      raise(
        ArgumentError,
        "nachrichten: nicht leere Liste erwartet, erhalten #{inspect(anderes)}"
      )

  defp werkzeuge!(liste) when is_list(liste) do
    Enum.each(liste, fn
      %Werkzeug{} = w -> Werkzeug.pruefen!(w)
      anderes -> raise ArgumentError, "werkzeuge: kein Worker.Agent.Werkzeug: #{inspect(anderes)}"
    end)

    namen = Enum.map(liste, & &1.name)

    case namen -- Enum.uniq(namen) do
      [] ->
        Map.new(liste, &{&1.name, &1})

      doppelt ->
        raise ArgumentError, "werkzeuge: Namen doppelt: #{Enum.join(Enum.uniq(doppelt), ", ")}"
    end
  end

  defp kontext!(nil), do: nil

  defp kontext!(kw) when is_list(kw) do
    k = %{
      fenster: Keyword.fetch!(kw, :fenster),
      reserve: Keyword.fetch!(kw, :reserve),
      behalten: Keyword.fetch!(kw, :behalten),
      zusammenfassen: Keyword.get(kw, :zusammenfassen, &Kontext.standard_zusammenfassung/1)
    }

    zahlen? = Enum.all?([k.fenster, k.reserve, k.behalten], &(is_integer(&1) and &1 > 0))

    if zahlen? and k.reserve + k.behalten < k.fenster and is_function(k.zusammenfassen, 1) do
      k
    else
      raise ArgumentError,
            "kontext: fenster, reserve, behalten positive ganze Zahlen mit reserve + behalten < fenster, " <>
              "zusammenfassen eine Funktion mit einem Argument — erhalten #{inspect(kw)}"
    end
  end

  defp text!(text, _name) when is_binary(text), do: text

  defp text!(anderes, name),
    do: raise(ArgumentError, "#{name}: Text erwartet, erhalten #{inspect(anderes)}")

  defp positiv!(n, _name) when is_integer(n) and n > 0, do: n

  defp positiv!(anderes, name),
    do:
      raise(ArgumentError, "#{name}: positive ganze Zahl erwartet, erhalten #{inspect(anderes)}")

  defp funktion!(f, _name) when is_function(f, 1), do: f

  defp funktion!(anderes, name),
    do:
      raise(
        ArgumentError,
        "#{name}: Funktion mit einem Argument erwartet, erhalten #{inspect(anderes)}"
      )

  defp verstrichen(s), do: System.monotonic_time(:millisecond) - s.start_ms
end
