defmodule Worker.Jack.Sicht.Lage do
  @moduledoc """
  Was die Laufsicht über einen Lauf weiß, abgeleitet aus den Ereignissen der
  Laufzeit (`{:agent, daten}`, siehe `Worker.Agent.Protokoll`) und dem Stand
  des Halters (`{:jack_stand, abbild}`, siehe `Worker.Jack.Halter`). Rein:
  jedes Ereignis liefert die neue Lage und die Nachrichten an die Seite.

  Nachrichten an die Seite, je eine JSON-Map mit `art`:

    * `delta` — ein Stück Denken (`was: "denken"`) oder Text (`"text"`), so
      wie es vom Modell kommt;
    * `lauf` — die abgeleitete Lage (`lauf`) und die Spur, nach jedem anderen
      Ereignis; `neue_runde: true`, wenn eine Modellanfrage beginnt (die Seite
      leert dann den Denkraum);
    * `stand` — der Stand nach einem Werkzeugaufruf.

  Die Lage liest die Daten sowohl vor der JSON-Kodierung (live, Atom-Schlüssel
  in `nutzung`) als auch aus der Protokolldatei (Text-Schlüssel), damit ein
  beendeter Lauf dieselbe Seite ergibt.
  """

  @spur_max 40
  @letzte_max 12
  @text_max 320
  # Der Denkraum hält höchstens so viele Bytes; darüber wird vorn gekürzt.
  @denk_max 60_000

  defstruct lauf: %{}, spur: [], denkt: "", schreibt: "", stand: nil

  @type t :: %__MODULE__{}

  @doc "Eine leere Lage."
  @spec neu() :: t()
  def neu, do: %__MODULE__{lauf: lauf_leer()}

  defp lauf_leer do
    %{
      "start" => nil,
      "modell" => nil,
      "werkzeug_liste" => [],
      "kontext_fenster" => nil,
      "runden" => 0,
      "letztes" => nil,
      "wartet_seit" => nil,
      "kontext_jetzt" => nil,
      "kontext_prozent" => nil,
      "am_deckel" => 0,
      "werkzeuge" => %{},
      "fehler" => 0,
      "wiederholungen" => 0,
      "kompaktierungen" => 0,
      "ende" => nil,
      "letzte" => [],
      "bestand_start" => nil
    }
  end

  @doc "Alles, was die Seite beim (Wieder-)Verbinden braucht."
  @spec zustand(t()) :: map()
  def zustand(%__MODULE__{} = l) do
    %{
      "stand" => l.stand,
      "lauf" => l.lauf,
      "spur" => l.spur,
      "denkt" => l.denkt,
      "schreibt" => l.schreibt
    }
  end

  @doc "Ein neuer Stand vom Halter."
  @spec stand(t(), map()) :: {t(), [map()]}
  def stand(%__MODULE__{} = l, abbild) do
    l = %{l | stand: abbild}

    if l.lauf["start"] && is_nil(l.lauf["bestand_start"]) do
      l = put_in(l.lauf["bestand_start"], abbild["bestand"])
      {l, [%{"art" => "stand", "stand" => abbild}, lauf_nachricht(l, false)]}
    else
      {l, [%{"art" => "stand", "stand" => abbild}]}
    end
  end

  @doc "Ein Ereignis der Laufzeit."
  @spec ereignis(t(), map()) :: {t(), [map()]}
  def ereignis(%__MODULE__{} = l, %{"ereignis" => "delta"} = d) do
    text = to_string(d["text"] || "")

    l =
      case d["art"] do
        "denken" -> %{l | denkt: kappen(l.denkt <> text)}
        _ -> %{l | schreibt: kappen(l.schreibt <> text)}
      end

    {put_in(l.lauf["letztes"], d["t"]), [%{"art" => "delta", "was" => d["art"], "text" => text}]}
  end

  def ereignis(%__MODULE__{} = l, %{"ereignis" => art} = d) do
    l = put_in(l.lauf["letztes"], d["t"]) |> anwenden(art, d)
    {l, [lauf_nachricht(l, art == "anfrage")]}
  end

  def ereignis(%__MODULE__{} = l, _anderes), do: {l, []}

  defp lauf_nachricht(l, neue_runde),
    do: %{"art" => "lauf", "lauf" => l.lauf, "spur" => l.spur, "neue_runde" => neue_runde}

  # ─── Die Ereignisse ───────────────────────────────────────────────────

  defp anwenden(l, "start", d) do
    werkzeuge = d["werkzeuge"] || []
    modell = d["modell_name"] || d["modell"]

    lauf =
      Map.merge(lauf_leer(), %{
        "start" => d["t"],
        "letztes" => d["t"],
        "modell" => modell,
        "werkzeug_liste" => werkzeuge,
        "kontext_fenster" => d["kontext_fenster"],
        "bestand_start" => l.stand && l.stand["bestand"]
      })

    %{l | lauf: lauf, denkt: "", schreibt: ""}
    |> spur("start", "Lauf beginnt — #{length(werkzeuge)} Werkzeuge, Modell #{modell}", d)
  end

  defp anwenden(l, "anfrage", d) do
    %{l | lauf: Map.put(l.lauf, "wartet_seit", d["t"]), denkt: "", schreibt: ""}
  end

  defp anwenden(l, "antwort", d) do
    nutzung = d["nutzung"] || %{}
    eingabe = wert(nutzung, :eingabe)
    aufrufe = d["aufrufe"] || []

    zeile = %{
      "t" => d["t"],
      "runde" => d["runde"],
      "ms" => d["ms"],
      "eingabe" => eingabe,
      "ausgabe" => wert(nutzung, :ausgabe),
      "stopp" => d["stopp"],
      "aufrufe" => Enum.map(aufrufe, & &1["name"])
    }

    lauf =
      l.lauf
      |> Map.merge(%{"runden" => d["runde"] || l.lauf["runden"], "wartet_seit" => nil})
      |> kontext(eingabe)
      |> Map.update!("am_deckel", &if(d["stopp"] == "laenge", do: &1 + 1, else: &1))
      |> Map.update!("letzte", &Enum.take(&1 ++ [zeile], -@letzte_max))

    # Ohne Deltas (ein Lauf aus der Datei) steht der Gedanke erst hier.
    l = %{
      l
      | lauf: lauf,
        denkt: if(l.denkt == "", do: kappen(d["denken"] || ""), else: l.denkt),
        schreibt: if(l.schreibt == "", do: kappen(d["text"] || ""), else: l.schreibt)
    }

    l = l |> spur_wenn("denkt", d["denken"], d) |> spur_wenn("sagt", d["text"], d)
    Enum.reduce(aufrufe, l, &spur(&2, "ruft", ruft(&1), d))
  end

  defp anwenden(l, "ergebnis", d) do
    fehler? = d["art"] in ["error", "abbruch"]

    lauf =
      l.lauf
      |> Map.update!("werkzeuge", &Map.update(&1, d["name"], 1, fn n -> n + 1 end))
      |> Map.update!("fehler", &if(fehler?, do: &1 + 1, else: &1))

    spur(
      %{l | lauf: lauf},
      if(fehler?, do: "fehler", else: "ergebnis"),
      "#{d["name"]}: #{d["text"]}",
      d
    )
  end

  defp anwenden(l, "wiederholung", d) do
    l
    |> Map.update!(:lauf, &Map.update!(&1, "wiederholungen", fn n -> n + 1 end))
    |> spur("sperre", "#{d["name"]}: #{d["folge"]} beim #{d["anzahl"]}. gleichen Aufruf", d)
  end

  defp anwenden(l, "kompaktierung", %{"weggefallen" => weg} = d)
       when is_integer(weg) and weg > 0 do
    l
    |> Map.update!(:lauf, &Map.update!(&1, "kompaktierungen", fn n -> n + 1 end))
    |> spur("kompaktiert", "#{weg} Nachrichten zusammengefasst (bei #{d["tokens"]} Token)", d)
  end

  defp anwenden(l, "kompaktierung", _d), do: l

  defp anwenden(l, "folge", d), do: spur(l, "folge", to_string(d["text"]), d)

  defp anwenden(l, "modell_fehler", d) do
    %{l | lauf: Map.put(l.lauf, "wartet_seit", nil)}
    |> spur("fehler", "Modell: #{d["grund"]}", d)
  end

  defp anwenden(l, "ende", d) do
    ende = d["ende"] |> to_string() |> String.replace(":", "")

    %{l | lauf: Map.merge(l.lauf, %{"ende" => ende, "wartet_seit" => nil})}
    |> spur("ende", "Lauf beendet: #{ende} nach #{d["runden"]} Runden", d)
  end

  defp anwenden(l, art, d), do: spur(l, "fehler", "#{art}: #{inspect(d, limit: 10)}", d)

  # ─── Hilfen ───────────────────────────────────────────────────────────

  defp kontext(lauf, nil), do: lauf

  defp kontext(lauf, eingabe) do
    prozent =
      case lauf["kontext_fenster"] do
        f when is_integer(f) and f > 0 -> round(eingabe * 100 / f)
        _ -> nil
      end

    Map.merge(lauf, %{"kontext_jetzt" => eingabe, "kontext_prozent" => prozent})
  end

  defp wert(%{} = n, schluessel),
    do: Map.get(n, schluessel) || Map.get(n, Atom.to_string(schluessel))

  defp wert(_, _), do: nil

  defp ruft(%{} = a) do
    # Kein JSON-Objekt geschickt: dann steht der Rohtext unter `roh`.
    args =
      case a["argumente"] || a["roh"] do
        %{} = m -> m |> Enum.take(3) |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{json(v)}" end)
        roh -> to_string(roh)
      end

    "#{a["name"]}(#{args})"
  end

  defp json(v) do
    Jason.encode!(v)
  rescue
    _ -> inspect(v)
  end

  defp spur_wenn(l, _was, text, _d) when text in [nil, ""], do: l
  defp spur_wenn(l, was, text, d), do: spur(l, was, text, d)

  defp spur(l, was, text, d) do
    eintrag = %{
      "was" => was,
      "text" => String.slice(to_string(text), 0, @text_max),
      "t" => d["t"]
    }

    %{l | spur: Enum.take(l.spur ++ [eintrag], -@spur_max)}
  end

  # Vorn kürzen, ohne ein UTF-8-Zeichen zu zerschneiden — ein halbes Zeichen
  # ließe sich nicht mehr als JSON senden.
  defp kappen(text) when byte_size(text) <= @denk_max, do: text

  defp kappen(text) do
    ab = byte_size(text) - div(@denk_max * 3, 4)
    text |> binary_part(ab, byte_size(text) - ab) |> ohne_fortsetzung()
  end

  defp ohne_fortsetzung(<<0b10::2, _::6, rest::binary>>), do: ohne_fortsetzung(rest)
  defp ohne_fortsetzung(rest), do: rest
end
