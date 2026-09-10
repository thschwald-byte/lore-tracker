defmodule Worker.Jack.Abschluss do
  @moduledoc """
  `fertig` ist der einzige gültige Abschluss eines Durchgangs. Das Werkzeug
  rechnet nach und lehnt ab, solange Arbeit offen ist. Danach vergleicht es
  die Zahlen, die Jack meldet, mit der eigenen Buchhaltung.

  Portiert aus dem Spike (`abschlussHindernisse`, `istZahlen`, `fertig`,
  Stand Lauf 6). Die Texte sind wörtlich übernommen, bis auf die Antwort auf
  falsche Zahlen.

  **Abweichungen vom Spike:**

    * **Ein Schema je Phase** (#1196, Punkt 4). Pflicht sind genau die Zahlen
      dieser Phase und `offen_geblieben`, das leer sein darf. Im Spike waren
      alle zehn Felder optional, in jeder Phase dieselben.
    * **Die Ablehnung verrät die richtigen Zahlen nicht** (#1196, Punkt 5). Der
      Spike antwortete auf eine falsche Zahl mit `richtige_zahlen` und „du
      sagst 12, gezaehlt sind 14“. Aus der Pflicht wurde so ein Abschreibeweg.
      Jetzt steht nur da, welche Zahl nicht stimmt, und der Hinweis sagt
      „Zaehl nach“ statt „mit diesen Werten“. Wie im Spike geht der dritte
      Versuch trotzdem durch. Die Abweichung steht dann mit beiden Werten im
      Journal (`abschluss.jsonl`), das Jack nicht sieht.
    * Keine Phase 3 (Toms Entscheidung, 10.09.); der Spike behält ihren Zweig,
      ruft ihn aber nicht mehr auf.

  Ergebnis: `{:halt, …}` bei Erfolg, sonst `{:error, …}`. Nach `:halt` endet
  der Lauf, wenn in derselben Antwort nichts anderes mehr läuft.
  """

  alias Worker.Jack.{Antwort, Gedaechtnis, Stand}

  @zahlversuche 3
  @zahlen %{1 => ~w(bereiche eintraege), 2 => ~w(aussagen)}
  @felder %{
    1 => "bereiche (Zahl der ABLAUF-Zeilen) und eintraege (Eintraege insgesamt)",
    2 => "aussagen (Zahl der eingetragenen Aussagen)"
  }
  @noch_ein_abschnitt "Es liegt noch ein Abschnitt vor dir. Ruf weiter() — und dann " <>
                        "wieder, bis das Werkzeug sagt, dass nichts mehr kommt."

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Das Werkzeug `fertig` für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{} = s) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Meldet diesen Durchgang als abgeschlossen — der EINZIGE gueltige " <>
            "Abschluss. Ein Satz in der letzten Nachricht zaehlt nicht. " <>
            "Das Werkzeug rechnet nach und LEHNT AB, solange Arbeit offen ist; " <>
            "in der Ablehnung steht, was genau fehlt. Erwartete Zahlen hier: " <>
            @felder[s.phase] <>
            ". Zahl deiner Selbstauskunft und Buchhaltung werden verglichen.",
        parameter: schema(s),
        wiederholung: :frei,
        ausfuehren: &fertig/2
      }
    ]
  end

  @doc "Die Parameter von `fertig` in der Phase des Stands."
  @spec schema(Stand.t()) :: map()
  def schema(%Stand{} = s) do
    zahlen = Map.new(@zahlen[s.phase], &{&1, %{"type" => "integer", "minimum" => 0}})

    %{
      "type" => "object",
      "properties" =>
        Map.put(zahlen, "offen_geblieben", %{
          "type" => "string",
          "minLength" => 0,
          "description" => "was der Mitschnitt nicht klaert — in Worten, nicht als Zahl"
        })
    }
  end

  @doc "Den Durchgang abschließen (Werkzeug `fertig`)."
  @spec fertig(Stand.t(), map()) :: ergebnis()
  def fertig(%Stand{} = s, p) do
    case hindernisse(s) do
      [] ->
        nachrechnen(s, p)

      h ->
        s =
          Stand.journal(s, "abschluss.jsonl", %{
            "versuch" => "abgelehnt",
            "phase" => s.phase,
            "hindernisse" => h
          })

        {s,
         {:error,
          Antwort.geordnet([
            {"ok", false},
            {"fertig", false},
            {"hinweis", "Noch nicht fertig. Arbeite die Punkte ab und ruf fertig() erneut."},
            {"offen", h}
          ])}}
    end
  end

  defp nachrechnen(s, p) do
    ist = ist_zahlen(s)
    schluessel = @zahlen[s.phase]
    gemeldet = Map.new(schluessel, &{&1, p[&1]})
    falsch = Enum.filter(schluessel, &(gemeldet[&1] != ist[&1]))
    versuch = s.abschluss_zahlversuche + if(falsch == [], do: 0, else: 1)
    s = %{s | abschluss_zahlversuche: versuch}

    if falsch != [] and versuch < @zahlversuche do
      s =
        Stand.journal(s, "abschluss.jsonl", %{
          "versuch" => "zahlen",
          "nr" => versuch,
          "phase" => s.phase,
          "abweichung" => abweichung(falsch, gemeldet, ist)
        })

      {s,
       {:error,
        Antwort.geordnet([
          {"ok", false},
          {"fertig", false},
          {"hinweis",
           "Die Arbeit ist durch, aber deine Zahlen stimmen nicht mit der Buchhaltung " <>
             "ueberein. Zaehl nach und ruf fertig() noch einmal."},
          {"abweichung", Enum.map(falsch, &"#{&1}: du sagst #{gemeldet[&1]} — das stimmt nicht.")}
        ])}}
    else
      abschliessen(s, p, ist, gemeldet, falsch)
    end
  end

  defp abschliessen(s, p, ist, gemeldet, falsch) do
    # Wie viele Aussagen haben mehrere Durchgänge unabhängig gefunden? Das ist
    # das Robustheitsmaß des Bestands; die Zahl steht sonst nirgends.
    mehrfach =
      Enum.count(s.eingetragen, fn e ->
        e.voll["_verworfen"] != true and (e.voll["_bestaetigt"] || 0) > 1
      end)

    s =
      Stand.journal(s, "abschluss.jsonl", %{
        "abschluss" => true,
        "phase" => s.phase,
        "mehrfach_gefunden" => mehrfach,
        "zahlen" => ist,
        "gemeldet" => gemeldet,
        "zahlen_stimmten" => if(falsch == [], do: "ja", else: "nein"),
        "abweichung" => if(falsch != [], do: abweichung(falsch, gemeldet, ist)),
        "offen_geblieben" => p["offen_geblieben"]
      })

    hinweis =
      if mehrfach > 0,
        do:
          "Abgeschlossen. Du kannst aufhoeren. #{mehrfach} Aussage(n) wurden " <>
            "von mehreren Durchgaengen unabhaengig gefunden — das ist der " <>
            "belastbarste Teil des Bestands.",
        else: "Abgeschlossen. Du kannst aufhoeren."

    {s,
     {:halt,
      Antwort.geordnet([
        {"ok", true},
        {"fertig", true},
        {"zahlen", Antwort.geordnet(Enum.map(@zahlen[s.phase], &{&1, ist[&1]}))},
        {"mehrfach_gefunden", mehrfach},
        {"hinweis", hinweis}
      ])}}
  end

  # Nur fürs Journal: hier stehen beide Werte.
  defp abweichung(falsch, gemeldet, ist),
    do: Enum.map(falsch, &"#{&1}: du sagst #{gemeldet[&1]}, gezaehlt sind #{ist[&1]}")

  @doc "Die Zahlen, wie die Buchhaltung sie kennt — je Phase andere."
  @spec ist_zahlen(Stand.t()) :: %{String.t() => non_neg_integer()}
  def ist_zahlen(%Stand{phase: 1} = s) do
    %{
      "bereiche" => Enum.count(s.register, &(&1.abschnitt == "ABLAUF")),
      "eintraege" => length(s.register)
    }
  end

  def ist_zahlen(%Stand{phase: 2} = s), do: %{"aussagen" => s.lfd}

  @doc "Was den Abschluss verhindert. Leer heißt: fertig."
  @spec hindernisse(Stand.t()) :: [String.t()]
  def hindernisse(%Stand{phase: 1} = s) do
    cond do
      s.gelesen == [] and s.beppo ->
        [
          "Du hast keinen einzigen Abschnitt geholt. weiter() ist der Anfang " <>
            "der Arbeit, nicht eine Formalie."
        ]

      s.gelesen == [] ->
        [
          "Du hast keinen einzigen Block geholt. bloecke(von, bis) ist der " <>
            "Anfang der Arbeit, nicht eine Formalie."
        ]

      s.beppo and s.beppo_pos <= s.max_block ->
        [@noch_ein_abschnitt]

      true ->
        nie = nie_gelesen(s)
        fehlend = Stand.geruest_fehlt(s)
        luecken = Gedaechtnis.ablauf_luecken(s)

        wenn(
          nie != [],
          "Nie gelesen: #{Enum.join(nie, ", ")}. Das Gedaechtnis darf nur ueber " <>
            "Bloecke reden, die du vor dir hattest — hol diese Bereiche nach."
        ) ++
          wenn(fehlend != [], "Im Gedaechtnis fehlt: " <> Enum.join(fehlend, ", ")) ++
          wenn(
            luecken != [],
            "ABLAUF hat Luecken: #{Enum.join(luecken, ", ")}. Jeder Bereich eine Zeile."
          )
    end
  end

  def hindernisse(%Stand{phase: 2} = s) do
    leer =
      wenn(
        s.lfd == 0,
        "Es steht keine einzige Aussage im Bestand. aussage() ist der " <>
          "Zweck dieses Durchgangs."
      )

    leer ++
      if(s.beppo, do: wenn(s.beppo_pos <= s.max_block, @noch_ein_abschnitt), else: ungelesen(s))
  end

  # Nicht die höchste angefasste Blocknummer, sondern Lückenlosigkeit: wer
  # 0-60 und dann 1750-1801 holt, hat 94 % nie gesehen.
  defp ungelesen(s) do
    nie = nie_gelesen(s)
    mehr = if length(nie) > 12, do: " …", else: ""

    wenn(
      nie != [],
      "Diese Bloecke hast du in diesem Durchgang nicht angesehen: " <>
        "#{nie |> Enum.take(12) |> Enum.join(", ")}#{mehr}. " <>
        "Hol sie mit bloecke(von, bis) und trag ein, was dort steht — " <>
        "ein Bereich, der wenig hergibt, ist normal, ein Bereich, den " <>
        "niemand gelesen hat, nicht."
    )
  end

  @doc "Die Bereiche des Mitschnitts, die in diesem Durchgang nie gelesen wurden."
  @spec nie_gelesen(Stand.t()) :: [String.t()]
  def nie_gelesen(%Stand{} = s), do: Stand.luecken(s.gelesen, s.max_block)

  defp wenn(true, text), do: [text]
  defp wenn(false, _text), do: []
end
