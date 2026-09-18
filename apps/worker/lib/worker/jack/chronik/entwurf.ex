defmodule Worker.Jack.Chronik.Entwurf do
  @moduledoc """
  Die Chronik-Einträge eines Laufs und die Regeln, die beim Schreiben gelten
  (J7, #1211). Pur: Einträge hinein, Einträge und eine Meldung heraus.

  **Die Regeln stehen hier, nicht im Auftrag.** Das ist die Linie aller
  Jack-Läufe seit J5: Was das Werkzeug nicht zulässt, muss der Auftrag nicht
  erklären, und was der Auftrag erklärt, hält sich das Modell nicht
  zwangsläufig. Abgelehnt wird mit einer Meldung, die sagt, was zu tun ist —
  nicht mit einem Fehlercode.

  ## Was ein Eintrag ist

  Ein Abschnitt der Handlung, keine Einzelszene: ein ganzer Auftrag von der
  Annahme über die Anfahrt bis zur Abrechnung ist **eine** Phase. Einen
  eigenen Eintrag bekommt daneben nur, was die Kampagne oder die Welt
  verändert — der Tod einer Spielerfigur, ein Krieg, eine Seuche. Das
  unterscheidet `wichtigkeit`: `"phase"` gegen `"schluesselszene"`.

  Welche Fälle einschneidend genug für eine eigene Szene sind, entscheidet
  **Jack**, geführt von Beispielen im Auftrag — nicht dieses Modul. Der
  Fakt-Typ `zustandsänderung` wäre dafür zu fein (jede Verletzung, jede
  geöffnete Tür trägt ihn), und ein Wortabgleich auf Todesfälle wäre genau
  das Verfahren, das in #1109 abgeschaltet wurde, weil ein einzelner
  Falschtreffer zur bindenden Aussage wird.

  ## Die vier Regeln, die hier durchgesetzt werden

    1. **Jeder Fakt existiert.** Eine erfundene Fakt-ID wäre ein Eintrag ohne
       Beleg — die Chronik soll nichts enthalten, was nicht als Fakt dasteht.
    2. **Ein Fakt liegt in höchstens einer Phase.** Sonst erschiene dasselbe
       Geschehen zweimal im Zeitstrahl, und die Trichter-Messung (#1111)
       zählte mehr Fakten verarbeitet, als es gibt.
    3. **Das Ziel eines Bezugs existiert.** Ein Bezug auf einen Eintrag, den
       es nicht gibt, ist keine Ordnung, sondern eine Lücke.
    4. **Kuratiertes wird nicht gestrichen.** Ergänzen und Einordnen sind
       erlaubt, Streichen nicht — und was der Spielleiter geschrieben hat,
       bleibt erhalten, auch wenn Jack fortschreibt.

  ## Was hier NICHT geprüft wird

  Die **Reihenfolge** — ob die Bezüge einen Kreis bilden, rechnet
  `Worker.Jack.Chronik.Ordnung` nach dem Schreiben; ein Zyklus ist ein
  Befund für die Durchsicht, kein Grund, den einzelnen Aufruf abzulehnen.
  Und die **Spanne** eines Eintrags (von wann bis wann) rechnet Elixir aus
  den Fakten, statt sie Jack anzugeben: ein Feld, das das Modell füllt, wäre
  wieder eine Stelle, an der es Tage rät.
  """

  alias Worker.Jack.Chronik.Ordnung
  alias Worker.Jack.Resuemee.Stand

  @arten ~w(phase schluesselszene)

  @typedoc """
  Ein Eintrag im Lauf. `kuratiert?` kommt aus dem Bestand und schützt vor dem
  Streichen; `kuratierter_text` hält fest, was der Spielleiter geschrieben
  hat — Jacks Fortschreibung steht getrennt daneben, damit in der Oberfläche
  erkennbar bleibt, welcher Teil von wem stammt.
  """
  @type eintrag :: %{
          required(:id) => String.t(),
          required(:titel) => String.t(),
          required(:text) => String.t(),
          required(:fakt_ids) => [String.t()],
          required(:wichtigkeit) => String.t(),
          required(:zeit_bezug) => [map()],
          required(:kuratiert?) => boolean(),
          required(:kuratierter_text) => String.t() | nil,
          required(:neu?) => boolean()
        }

  @doc """
  Legt einen Eintrag an. `bekannte_fakten` ist die Karte kurze ID -> echte ID der Fakten, die es
  gibt; `eintraege` der bisherige Stand des Laufs.
  """
  @spec anlegen([eintrag()], map(), %{String.t() => String.t()}) ::
          {:ok, [eintrag()], String.t()} | {:error, String.t()}
  def anlegen(eintraege, p, bekannte_fakten) do
    with {:ok, titel} <- text_feld(p, "titel"),
         {:ok, text} <- text_feld(p, "text"),
         {:ok, wichtigkeit} <- wichtigkeit(p),
         {:ok, fakt_ids} <- fakt_ids(p, bekannte_fakten),
         :ok <- fakten_frei(fakt_ids, eintraege, nil, umgekehrt(bekannte_fakten)),
         {:ok, bezug} <- bezug(p, eintraege, nil) do
      neu = %{
        id: neue_id(titel, fakt_ids),
        titel: titel,
        text: text,
        fakt_ids: fakt_ids,
        wichtigkeit: wichtigkeit,
        zeit_bezug: bezug,
        kuratiert?: false,
        kuratierter_text: nil,
        neu?: true
      }

      {:ok, eintraege ++ [neu],
       "Eintrag #{neu.id} angelegt (#{wichtigkeit}, #{length(fakt_ids)} Fakten). " <>
         "Die Chronik hat jetzt #{length(eintraege) + 1} Einträge."}
    end
  end

  @doc """
  Schreibt einen Eintrag fort: Text wird **angehängt**, Fakten kommen dazu.
  Ersetzt wird nichts — bei einem kuratierten Eintrag bliebe sonst der Text
  des Spielleiters auf der Strecke, und bei einem eigenen verlöre Jack, was
  er im selben Lauf schon geschrieben hat.
  """
  @spec ergaenzen([eintrag()], map(), %{String.t() => String.t()}) ::
          {:ok, [eintrag()], String.t()} | {:error, String.t()}
  def ergaenzen(eintraege, p, bekannte_fakten) do
    with {:ok, e, rest} <- finden(eintraege, p),
         {:ok, text} <- text_feld(p, "text"),
         {:ok, neue_fakten} <- fakt_ids(p, bekannte_fakten),
         :ok <- fakten_frei(neue_fakten, rest, e.id, umgekehrt(bekannte_fakten)) do
      dazu = Enum.reject(neue_fakten, &(&1 in e.fakt_ids))

      erweitert = %{
        e
        | text: String.trim(e.text <> "\n\n" <> text),
          fakt_ids: e.fakt_ids ++ dazu
      }

      {:ok, ersetzen(eintraege, erweitert),
       "Eintrag #{e.id} fortgeschrieben" <>
         zusatz(dazu) <>
         if(e.kuratiert?,
           do: ". Der Text des Spielleiters bleibt unangetastet, deiner steht darunter.",
           else: "."
         )}
    end
  end

  @doc """
  Ändert nur die Stellung in der Reihenfolge, nie den Text. Auch bei einem
  kuratierten Eintrag erlaubt: Der Text gehört dem Spielleiter, die Ordnung
  dem Zeitstrahl.
  """
  @spec einordnen([eintrag()], map()) :: {:ok, [eintrag()], String.t()} | {:error, String.t()}
  def einordnen(eintraege, p) do
    with {:ok, e, rest} <- finden(eintraege, p),
         {:ok, b} <- bezug(p, rest, e.id) do
      {:ok, ersetzen(eintraege, %{e | zeit_bezug: b}),
       "Eintrag #{e.id} eingeordnet: #{beschreibe(b)}."}
    end
  end

  @doc """
  Streicht einen Eintrag — außer er ist kuratiert. Der Grund steht im
  Journal; ohne ihn lässt sich später nicht nachvollziehen, warum ein
  Abschnitt der Handlung fehlt.
  """
  @spec streichen([eintrag()], map()) :: {:ok, [eintrag()], String.t()} | {:error, String.t()}
  def streichen(eintraege, p) do
    with {:ok, e, rest} <- finden(eintraege, p),
         {:ok, _grund} <- text_feld(p, "grund") do
      cond do
        e.kuratiert? ->
          {:error,
           "Eintrag #{e.id} ist vom Spielleiter kuratiert und wird nicht gestrichen. " <>
             "Du darfst ihn mit eintrag_ergaenzen() fortschreiben und mit " <>
             "eintrag_einordnen() an eine andere Stelle setzen."}

        zeigt_jemand_darauf?(rest, e.id) ->
          {:error,
           "Auf Eintrag #{e.id} beziehen sich andere Einträge (#{verweise(rest, e.id)}). " <>
             "Ordne die erst um (eintrag_einordnen), dann kannst du ihn streichen — " <>
             "sonst zeigt ihre Reihenfolge ins Leere."}

        true ->
          {:ok, rest,
           "Eintrag #{e.id} gestrichen. Die Chronik hat jetzt #{length(rest)} Einträge."}
      end
    end
  end

  @doc """
  Die Fakten, die noch in keinem Eintrag liegen — die Zahl, an der sich
  „gebündelt" von „verschluckt" unterscheidet (#1111).
  """
  @spec offene_fakten([eintrag()], [String.t()]) :: [String.t()]
  def offene_fakten(eintraege, alle) do
    belegt = MapSet.new(Enum.flat_map(eintraege, & &1.fakt_ids))
    Enum.reject(alle, &MapSet.member?(belegt, &1))
  end

  # ─── Regeln ─────────────────────────────────────────────────────────

  # `bekannte` ist die Karte kurze ID -> echte ID (`bekannte/1`). Das Modell
  # nennt die kurzen (`S1-F12`, eine Position im Bestand); gespeichert wird die
  # echte, inhaltsadressierte — sonst zeigte jeder Eintrag nach dem nächsten
  # Regenerate stumm auf andere Fakten (die K6-Klasse; genau so war es bis
  # zum ersten Review am 18.09.2026, entgegen dem Moduledoc der Eingabe).
  @doc "Die `fakt_ids` eines Aufrufs geprüft und in echte IDs übersetzt."
  @spec fakt_ids(map(), %{String.t() => String.t()}) :: {:ok, [String.t()]} | {:error, String.t()}
  def fakt_ids(p, bekannte) do
    case Map.get(p, "fakt_ids") do
      ids when is_list(ids) ->
        case Enum.reject(ids, &Map.has_key?(bekannte, &1)) do
          [] ->
            {:ok, ids |> Enum.map(&Map.fetch!(bekannte, &1)) |> Enum.uniq()}

          fehlend ->
            {:error,
             "Diese Fakten gibt es nicht: #{Enum.join(fehlend, ", ")}. " <>
               "Nimm die IDs so, wie fakten() sie nennt — die Chronik soll nichts " <>
               "enthalten, was nicht als Fakt dasteht."}
        end

      _ ->
        {:error,
         "fakt_ids fehlt oder ist keine Liste. Nenne die Fakten, die in diesem " <>
           "Eintrag aufgehen — auch bei einer Phase, die viele bündelt."}
    end
  end

  defp fakten_frei(ids, eintraege, eigene_id, kurz) do
    doppelt =
      for e <- eintraege,
          e.id != eigene_id,
          f <- e.fakt_ids,
          f in ids,
          do: {f, e.id}

    case doppelt do
      [] ->
        :ok

      _ ->
        # Dem Modell die kurze ID nennen, die es kennt — die echte sagt ihm nichts.
        liste =
          doppelt
          |> Enum.map(fn {f, id} -> "#{Map.get(kurz, f, f)} (liegt in #{id})" end)
          |> Enum.join(", ")

        {:error,
         "Diese Fakten liegen schon in einem anderen Eintrag: #{liste}. " <>
           "Ein Geschehen gehört in genau eine Phase — sonst steht es zweimal im " <>
           "Zeitstrahl. Nimm sie hier heraus, oder schreibe den anderen Eintrag fort."}
    end
  end

  defp umgekehrt(karte), do: Map.new(karte, fn {kurz, echt} -> {echt, kurz} end)

  @doc """
  Der Reststand als Satz, den jedes schreibende Werkzeug anhängt: wie viele
  Geschehen noch in keinem Eintrag liegen, und welche.

  **Warum an jeder Antwort:** Im Überblick nennt `notiz` den Stand laufend;
  im Schreiben erfuhr Jack ihn bis zum 18.09.2026 nur aus der Ablehnung von
  `fertig()` — er legte Einträge an, rief `fertig`, wurde abgewiesen und
  musste nachlegen. Eine Runde, die nichts baut, und der Weg, auf dem
  Wiederholungen entstehen (die Sperre aus #1174 beendet den Lauf beim
  sechsten gleichen Aufruf).
  """
  @spec reststand(Stand.t()) :: String.t()
  def reststand(%Stand{} = s) do
    case Worker.Jack.Chronik.Abschluss.offene(s) do
      [] ->
        " Jedes Geschehen liegt in einem Eintrag oder steht begründet unter " <>
          "NICHT_ZEITLEISTE — du kannst fertig() rufen."

      ids ->
        kurz = Map.new(s.fakten, &{&1.fakt_id, &1.id})
        namen = Enum.map(ids, &Map.get(kurz, &1, &1))

        " Noch #{length(namen)} Geschehen in keinem Eintrag: " <>
          (namen |> Enum.take(12) |> Enum.join(", ")) <>
          if(length(namen) > 12, do: " und weitere", else: "") <>
          " — offen() zeigt sie mit ihrer Aussage."
    end
  end

  defp wichtigkeit(p) do
    case Map.get(p, "wichtigkeit") do
      w when w in @arten ->
        {:ok, w}

      _ ->
        {:error,
         "wichtigkeit muss \"phase\" oder \"schluesselszene\" sein. " <>
           "Eine Phase ist ein Abschnitt der Handlung — ein ganzer Auftrag von der " <>
           "Annahme bis zur Abrechnung. Eine Schlüsselszene bekommt nur, was die " <>
           "Kampagne oder die Welt verändert."}
    end
  end

  # Seit dem Review vom 18.09.2026 eine LISTE: „gleichzeitig mit A und nach B“
  # war mit einem Bezug nicht sagbar. Eine einzelne Map nimmt das Werkzeug
  # weiter an (ein Modell, das die alte Form gelernt hat, scheitert nicht
  # daran), `isoliert` wird zur leeren Liste. Jedes Element wird einzeln
  # geprüft; die erste Ablehnung gewinnt.
  defp bezug(p, eintraege, eigene_id) do
    case Map.get(p, "zeit_bezug") do
      liste when is_list(liste) ->
        liste
        |> Enum.reduce_while({:ok, []}, fn b, {:ok, acc} ->
          case einer(b, eintraege, eigene_id) do
            {:ok, %{"art" => "isoliert"}} -> {:cont, {:ok, acc}}
            {:ok, bezug} -> {:cont, {:ok, [bezug | acc]}}
            {:error, _} = fehler -> {:halt, fehler}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq()}
          fehler -> fehler
        end

      %{} = einer ->
        bezug(Map.put(p, "zeit_bezug", [einer]), eintraege, eigene_id)

      _ ->
        {:error,
         "zeit_bezug fehlt oder ist keine Liste. Gib die Bezüge als Liste an — jeder mit " <>
           "art \"nach\", \"vor\" oder \"gleichzeitig_mit\" (je mit ziel) oder " <>
           "\"absolut\" (mit zeit); die leere Liste heisst ohne Bezug. Sag, was wovor " <>
           "geschah — den Tag rechnen wir."}
    end
  end

  defp einer(b, eintraege, eigene_id) do
    case b do
      %{"art" => art} = b when art in ["nach", "vor", "gleichzeitig_mit"] ->
        ziel = Map.get(b, "ziel")

        cond do
          not is_binary(ziel) or ziel == "" ->
            {:error,
             "Der Bezug \"#{art}\" braucht ein ziel — die ID des Eintrags, auf den " <>
               "er sich bezieht."}

          ziel == eigene_id ->
            {:error, "Ein Eintrag kann sich nicht auf sich selbst beziehen."}

          not Enum.any?(eintraege, &(&1.id == ziel)) ->
            {:error,
             "Den Eintrag #{ziel} gibt es nicht. chronik() nennt die vorhandenen; " <>
               "ohne Bezug gib die leere Liste."}

          true ->
            {:ok, %{"art" => art, "ziel" => ziel}}
        end

      %{"art" => "absolut"} = b ->
        case Map.get(b, "zeit") do
          z when is_binary(z) and z != "" ->
            {:ok, %{"art" => "absolut", "zeit" => String.trim(z)}}

          _ ->
            {:error,
             "Der Bezug \"absolut\" braucht eine zeit — die Angabe, wie sie im " <>
               "Mitschnitt steht. Rechne nichts um."}
        end

      %{"art" => "isoliert"} ->
        {:ok, %{"art" => "isoliert"}}

      _ ->
        {:error,
         "Ein Bezug hat eine unbekannte art. Erlaubt sind: \"nach\", \"vor\", " <>
           "\"gleichzeitig_mit\" (je mit ziel) und \"absolut\" (mit zeit); ohne Bezug " <>
           "gib die leere Liste. Sag, was wovor geschah — den Tag rechnen wir."}
    end
  end

  # ─── Zugriff ────────────────────────────────────────────────────────

  defp finden(eintraege, p) do
    id = Map.get(p, "id")

    case Enum.split_with(eintraege, &(&1.id == id)) do
      {[e], rest} ->
        {:ok, e, rest}

      {[], _} ->
        {:error, "Den Eintrag #{inspect(id)} gibt es nicht. chronik() nennt die vorhandenen."}
    end
  end

  defp ersetzen(eintraege, neu),
    do: Enum.map(eintraege, fn e -> if e.id == neu.id, do: neu, else: e end)

  defp text_feld(p, name) do
    case Map.get(p, name) do
      t when is_binary(t) ->
        case String.trim(t) do
          "" -> {:error, "#{name} ist leer."}
          s -> {:ok, s}
        end

      _ ->
        {:error, "#{name} fehlt."}
    end
  end

  defp zeigt_jemand_darauf?(eintraege, id), do: verweisende(eintraege, id) != []

  defp verweise(eintraege, id), do: eintraege |> verweisende(id) |> Enum.join(", ")

  defp verweisende(eintraege, id),
    do:
      for(e <- eintraege, Enum.any?(Ordnung.bezuege(e.zeit_bezug), &(&1["ziel"] == id)), do: e.id)

  defp zusatz([]), do: ""
  defp zusatz(dazu), do: ", #{length(dazu)} Fakten dazu"

  defp beschreibe([]), do: "ohne Bezug"
  defp beschreibe(liste) when is_list(liste), do: Enum.map_join(liste, "; ", &beschreibe/1)
  defp beschreibe(%{"art" => "isoliert"}), do: "ohne Bezug"
  defp beschreibe(%{"art" => "absolut", "zeit" => z}), do: "auf #{z}"
  defp beschreibe(%{"art" => a, "ziel" => z}), do: "#{a} #{z}"

  # Die ID hängt an den Fakten, nicht am Text: Formuliert ein späterer Lauf
  # denselben Abschnitt um, bleibt es derselbe Eintrag — Kuration und Bezüge
  # überleben. Das ist das Muster der Fakt-Kuration (#916); die alte
  # Chronik-ID hing am Text und verwaiste bei jeder Umformulierung.
  defp neue_id(titel, []), do: "chr-" <> kurz(titel)
  defp neue_id(_titel, fakt_ids), do: "chr-" <> kurz(Enum.sort(fakt_ids) |> Enum.join("|"))

  defp kurz(seed),
    do: :crypto.hash(:sha, seed) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  @doc """
  Die Reihenfolge der Einträge — Durchreichung an `Ordnung.ordne/1` mit der
  Gestalt, die dort erwartet wird (String-Schlüssel).
  """
  @spec ordnen([eintrag()]) :: {:ok, map()} | {:zyklus, [String.t()]}
  def ordnen(eintraege),
    do: Ordnung.ordne(Enum.map(eintraege, &%{"id" => &1.id, "zeit_bezug" => &1.zeit_bezug}))

  # ─── Werkzeuge ──────────────────────────────────────────────────────

  @doc """
  Die Werkzeug-Definitionen des Schreibens. Die Beschreibungen tragen die
  **Flughöhe** — sie ist die Entscheidung, die dieser Lauf umsetzt, und sie
  steht bewusst hier und nicht nur im Auftrag: Was das Werkzeug sagt, liest
  Jack bei jedem Aufruf, was der Auftrag sagt, einmal am Anfang.
  """
  @spec werkzeuge(Worker.Jack.Resuemee.Stand.t()) :: [map()]
  def werkzeuge(%Worker.Jack.Resuemee.Stand{}) do
    [
      %{
        name: "chronik_eintrag",
        beschreibung:
          "Legt einen Eintrag der Chronik an. Die Chronik ist die ZEITLEISTE DER " <>
            "KAMPAGNE, kein Sitzungsprotokoll: Ein ganzer Auftrag — von der Annahme " <>
            "über die Anfahrt und die Durchführung bis zur Abrechnung — ist EIN " <>
            "Eintrag (wichtigkeit \"phase\"), nicht zwölf. Das geht regelmäßig über " <>
            "Sitzungsgrenzen. Einen eigenen Eintrag (wichtigkeit " <>
            "\"schluesselszene\") bekommt nur, was die Kampagne oder die Welt " <>
            "verändert: der Tod einer Spielerfigur, ein Krieg, eine Seuche, ein " <>
            "Epochenereignis. Ein erschossener Wachmann ist Teil der Phase. " <>
            "fakt_ids: alle Fakten, die in diesem Eintrag aufgehen — auch viele. " <>
            "zeit_bezug: sag, was WOVOR geschah, nicht wann; den Tag rechnen wir.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "titel" => %{"type" => "string"},
            "text" => %{"type" => "string"},
            "fakt_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
            "wichtigkeit" => %{"type" => "string", "enum" => @arten},
            "zeit_bezug" => bezug_schema()
          },
          "required" => ~w(titel text fakt_ids wichtigkeit zeit_bezug)
        },
        optional: ["zeit_bezug.ziel", "zeit_bezug.zeit"],
        wiederholung: :zaehlt,
        ausfuehren: &w_anlegen/2
      },
      %{
        name: "eintrag_ergaenzen",
        beschreibung:
          "Schreibt einen bestehenden Eintrag fort: Der Text wird ANGEHÄNGT, die " <>
            "Fakten kommen dazu. Nichts wird ersetzt — bei einem kuratierten Eintrag " <>
            "bleibt der Text des Spielleiters vollständig stehen, deiner kommt " <>
            "darunter. Das ist der Weg, eine Phase fortzuschreiben, die in einer " <>
            "früheren Sitzung begann.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string"},
            "text" => %{"type" => "string"},
            "fakt_ids" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ~w(id text fakt_ids)
        },
        wiederholung: :zaehlt,
        ausfuehren: &w_ergaenzen/2
      },
      %{
        name: "eintrag_einordnen",
        beschreibung:
          "Ändert die Stellung eines Eintrags in der Reihenfolge — und NUR die. Der " <>
            "Text bleibt unangetastet, auch bei einem kuratierten Eintrag: Der Text " <>
            "gehört dem Spielleiter, die Ordnung dem Zeitstrahl.",
        parameter: %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string"}, "zeit_bezug" => bezug_schema()},
          "required" => ~w(id zeit_bezug)
        },
        optional: ["zeit_bezug.ziel", "zeit_bezug.zeit"],
        wiederholung: :zaehlt,
        ausfuehren: &w_einordnen/2
      },
      %{
        name: "eintrag_streichen",
        beschreibung:
          "Streicht einen Eintrag, den du selbst angelegt hast — für den Fall, dass " <>
            "du dich vergriffen hast. Einen Eintrag, den der Spielleiter kuratiert " <>
            "hat, streicht das Werkzeug NICHT; dort sind Ergänzen und Einordnen die " <>
            "Wege. grund: warum dieser Abschnitt der Handlung keiner ist.",
        parameter: %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string"}, "grund" => %{"type" => "string"}},
          "required" => ~w(id grund)
        },
        wiederholung: :zaehlt,
        ausfuehren: &w_streichen/2
      }
    ]
  end

  # Das Schema des Bezugs — an drei Stellen gebraucht, deshalb einmal
  # geschrieben. `ziel` und `zeit` hängen von der `art` ab; welche Kombination
  # gilt, prüft `bezug/3` mit einer Meldung, die den Weg nach vorn nennt. Ein
  # Schema kann diese Abhängigkeit nicht ausdrücken, ohne dass die Ablehnung
  # zu „ungültig" verkümmert.
  #
  # **Beide MÜSSEN darum in `optional:` jedes Werkzeugs stehen**, das einen
  # Bezug nimmt (`Worker.Agent.Schema.streng/2` macht sonst jedes Feld zur
  # Pflicht). Der Schema-Pfad kennt keinen Index — `zeit_bezug.ziel`, nicht
  # `zeit_bezug.0.ziel`, weil `innen/1` in `items` einsteigt, ohne den Pfad zu
  # verlängern. Am ersten echten Lauf gesehen (18.09.2026): Nach der
  # Umstellung auf die Liste fehlte das `optional`, und `eintrag_einordnen`
  # wurde VIERMAL abgelehnt („zeit_bezug.0.zeit: mindestens 1 Zeichen,
  # erhalten 0") — das Werkzeug war unbenutzbar, und Jack konnte seine
  # Einträge nicht in eine Reihenfolge bringen.
  defp bezug_schema do
    %{
      "type" => "array",
      "description" =>
        "die Bezüge dieses Eintrags, so viele wie nötig — etwa gleichzeitig_mit A UND " <>
          "nach B; die leere Liste heisst ohne Bezug",
      "items" => bezug_element_schema()
    }
  end

  defp bezug_element_schema do
    %{
      "type" => "object",
      "properties" => %{
        "art" => %{
          "type" => "string",
          "enum" => ~w(nach vor gleichzeitig_mit absolut)
        },
        "ziel" => %{"type" => "string"},
        "zeit" => %{"type" => "string"}
      },
      "required" => ["art"]
    }
  end

  defp w_anlegen(s, p), do: anwenden(s, &anlegen(&1, p, bekannte(s)))
  defp w_ergaenzen(s, p), do: anwenden(s, &ergaenzen(&1, p, bekannte(s)))
  defp w_einordnen(s, p), do: anwenden(s, &einordnen(&1, p))
  defp w_streichen(s, p), do: anwenden(s, &streichen(&1, p))

  # Jede gelungene Änderung nennt den Reststand — an EINER Stelle, durch die
  # alle vier schreibenden Werkzeuge laufen. Gerechnet auf dem NEUEN Stand,
  # sonst nennte die Antwort den Stand von vor dem eigenen Eintrag.
  defp anwenden(s, fun) do
    case fun.(s.eintraege) do
      {:ok, eintraege, meldung} ->
        neu = %{s | eintraege: eintraege}
        {neu, {:ok, meldung <> reststand(neu)}}

      {:error, meldung} ->
        {s, {:error, meldung}}
    end
  end

  # Kurze ID (wie fakten() sie nennt) -> echte, inhaltsadressierte Fakt-ID.
  # Das ist die EINE Stelle, an der übersetzt wird; alles hinter dem Werkzeug
  # rechnet mit echten IDs, s. `fakten/2`.
  @doc "Die Karte kurze ID -> echte ID für einen Stand."
  @spec karte(Stand.t()) :: %{String.t() => String.t()}
  def karte(s), do: Map.new(s.fakten, &{&1.id, &1.fakt_id})

  defp bekannte(s), do: karte(s)
end
