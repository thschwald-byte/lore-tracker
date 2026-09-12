defmodule Worker.Jack.Resuemee.Abschluss do
  @moduledoc """
  `fertig` des Resümee-Jack (J5, #1209), je Lauf — nach dem Muster von
  `Worker.Jack.Abschluss`: das Werkzeug rechnet nach und lehnt ab, solange
  Arbeit offen ist, und vergleicht danach die gemeldeten Zahlen mit der
  eigenen Buchhaltung.

  **Offen ist der Überblick** (B1), solange

    * ein Fakt dieser Sitzung ungelesen ist (die Gliederung darf nur über
      Fakten reden, die Jack vor sich hatte),
    * die FORM fehlt,
    * die GLIEDERUNG leer ist, oder
    * ein berührter Bogen der Art `arc` in keinem Gliederungspunkt vorkommt.
      Bögen der Art `context` und `rauschen` sind frei.

  Zahlen: `fakten` (gelesene Fakten dieser Sitzung) und `gliederung`
  (Punkte unter GLIEDERUNG).

  **Offen ist das Schreiben** (B2), solange

    * der Entwurf leer ist, oder
    * ein berührter Bogen der Art `arc` weder im Text vorkommt — kein Satz
      nennt einen seiner Fakten dieser Sitzung
      (`Worker.Jack.Resuemee.Stand.arc_ohne_satz/1`) — noch in `ausgelassen`
      mit einem Grund steht. In `ausgelassen` stehen nur Handlungsbögen
      (`arc`) dieser Sitzung, jeder mit einem Grund in Worten; eine andere
      Angabe ist selbst ein Hindernis.

  Zahlen: `absaetze` und `saetze` (im ganzen Entwurf).

  **Offen ist die Durchsicht** (B3), solange im laufenden Durchgang ein
  Absatz weder bestätigt noch ersetzt noch gestrichen ist
  (`Worker.Jack.Resuemee.Durchsicht.offen/1`). Den nächsten Durchgang
  beginnt nicht `fertig`, sondern die Entscheidung über den letzten offenen
  Absatz (`Worker.Jack.Resuemee.Durchsicht.weiter/1`); nach dem dritten
  beginnt keiner mehr. Zahlen: `bestaetigt` und `ersetzt` — wie oft in der
  ganzen Durchsicht, über alle Durchgänge.

  **In allen Läufen:** dazu `offen_geblieben` in Worten. Die Ablehnung
  sagt, welche Zahl nicht stimmt, nicht, was richtig wäre; der dritte
  Versuch geht trotzdem durch, die Abweichung steht dann mit beiden Werten im
  Journal (`abschluss.jsonl`) — wie beim Fakten-Jack (#1196, Punkt 5).

  Ergebnis: `{:halt, …}` bei Erfolg, sonst `{:error, …}`.
  """

  alias Worker.Jack.Antwort
  alias Worker.Jack.Resuemee.{Durchsicht, Stand}

  @zahlversuche 3

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Das Werkzeug `fertig` für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{lauf: :durchsicht}) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Meldet die Durchsicht als abgeschlossen — der EINZIGE gültige Abschluss. Ein Satz " <>
            "in der letzten Nachricht zählt nicht. Das Werkzeug rechnet nach und LEHNT AB, " <>
            "solange im laufenden Durchgang ein Absatz offen ist; in der Ablehnung steht, " <>
            "welcher. Erwartete Zahlen: bestaetigt (wie oft du in der ganzen Durchsicht einen " <>
            "Absatz bestätigt hast, über alle Durchgänge) und ersetzt (wie oft du einen Absatz " <>
            "ersetzt hast). Deine Zahlen und die Buchhaltung werden verglichen.",
        parameter: schema_durchsicht(),
        wiederholung: :frei,
        ausfuehren: &fertig/2
      }
    ]
  end

  def werkzeuge(%Stand{lauf: :schreiben}) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Meldet das Resümee als geschrieben — der EINZIGE gültige Abschluss. Ein Satz in " <>
            "der letzten Nachricht zählt nicht. Das Werkzeug rechnet nach und LEHNT AB, " <>
            "solange Arbeit offen ist; in der Ablehnung steht, was genau fehlt. Erwartete " <>
            "Zahlen: absaetze (Absätze im Entwurf) und saetze (Sätze im ganzen Entwurf). " <>
            "ausgelassen: die Handlungsbögen, die du bewusst nicht erzählst, je mit dem Grund; " <>
            "erzählst du alle, ist es []. Deine Zahlen und die Buchhaltung werden verglichen.",
        parameter: schema_schreiben(),
        wiederholung: :frei,
        ausfuehren: &fertig/2
      }
    ]
  end

  def werkzeuge(%Stand{}) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Meldet den Überblick als abgeschlossen — der EINZIGE gültige Abschluss. Ein Satz " <>
            "in der letzten Nachricht zählt nicht. Das Werkzeug rechnet nach und LEHNT AB, " <>
            "solange Arbeit offen ist; in der Ablehnung steht, was genau fehlt. Erwartete " <>
            "Zahlen: fakten (wie viele Fakten dieser Sitzung du gelesen hast) und gliederung " <>
            "(Zahl der Punkte unter GLIEDERUNG). Deine Zahlen und die Buchhaltung werden " <>
            "verglichen.",
        parameter: schema(),
        wiederholung: :frei,
        ausfuehren: &fertig/2
      }
    ]
  end

  @doc "Die Parameter von `fertig` im Überblick."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "fakten" => %{"type" => "integer", "minimum" => 0},
        "gliederung" => %{"type" => "integer", "minimum" => 0},
        "offen_geblieben" => offen_geblieben()
      }
    }
  end

  @doc "Die Parameter von `fertig` im Schreiben."
  @spec schema_schreiben() :: map()
  def schema_schreiben do
    %{
      "type" => "object",
      "properties" => %{
        "absaetze" => %{"type" => "integer", "minimum" => 0},
        "saetze" => %{"type" => "integer", "minimum" => 0},
        "ausgelassen" => %{
          "type" => "array",
          "description" =>
            "Handlungsbögen (Art arc), die das Resümee bewusst nicht erzählt; [] wenn keiner",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "bogen" => %{"type" => "string", "description" => "Titel wie in boegen()"},
              "grund" => %{"type" => "string", "description" => "warum er fehlt, in Worten"}
            }
          }
        },
        "offen_geblieben" => offen_geblieben()
      }
    }
  end

  @doc "Die Parameter von `fertig` in der Durchsicht."
  @spec schema_durchsicht() :: map()
  def schema_durchsicht do
    %{
      "type" => "object",
      "properties" => %{
        "bestaetigt" => %{"type" => "integer", "minimum" => 0},
        "ersetzt" => %{"type" => "integer", "minimum" => 0},
        "offen_geblieben" => %{
          "type" => "string",
          "minLength" => 0,
          "description" =>
            "was dir aufgefallen ist, ohne ein grober Schnitzer zu sein, oder was die Fakten " <>
              "nicht hergeben — in Worten, nicht als Zahl"
        }
      }
    }
  end

  defp offen_geblieben,
    do: %{
      "type" => "string",
      "minLength" => 0,
      "description" => "was die Fakten zum Verstehen nicht hergeben — in Worten, nicht als Zahl"
    }

  defp zahlen(%Stand{lauf: :durchsicht}), do: ~w(bestaetigt ersetzt)
  defp zahlen(%Stand{lauf: :schreiben}), do: ~w(absaetze saetze)
  defp zahlen(%Stand{}), do: ~w(fakten gliederung)

  @doc "Den Lauf abschließen (Werkzeug `fertig`)."
  @spec fertig(Stand.t(), map()) :: ergebnis()
  def fertig(%Stand{} = s, p) do
    case hindernisse(s, p) do
      [] ->
        nachrechnen(s, p)

      h ->
        s =
          Stand.journal(s, "abschluss.jsonl", %{
            "versuch" => "abgelehnt",
            "lauf" => to_string(s.lauf),
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
    namen = zahlen(s)
    ist = ist_zahlen(s)
    gemeldet = Map.new(namen, &{&1, p[&1]})
    falsch = Enum.filter(namen, &(gemeldet[&1] != ist[&1]))
    versuch = s.abschluss_zahlversuche + if(falsch == [], do: 0, else: 1)
    s = %{s | abschluss_zahlversuche: versuch}

    if falsch != [] and versuch < @zahlversuche do
      s =
        Stand.journal(s, "abschluss.jsonl", %{
          "versuch" => "zahlen",
          "lauf" => to_string(s.lauf),
          "nr" => versuch,
          "abweichung" => abweichung(falsch, gemeldet, ist)
        })

      {s,
       {:error,
        Antwort.geordnet([
          {"ok", false},
          {"fertig", false},
          {"hinweis",
           "Die Arbeit ist durch, aber deine Zahlen stimmen nicht mit der Buchhaltung " <>
             "überein. Zähl nach und ruf fertig() noch einmal auf."},
          {"abweichung", Enum.map(falsch, &gemeldet_falsch(&1, gemeldet[&1]))}
        ])}}
    else
      abschliessen(s, p, ist, gemeldet, falsch)
    end
  end

  defp abschliessen(s, p, ist, gemeldet, falsch) do
    eintrag = %{
      "abschluss" => true,
      "lauf" => to_string(s.lauf),
      "zahlen" => ist,
      "gemeldet" => gemeldet,
      "zahlen_stimmten" => if(falsch == [], do: "ja", else: "nein"),
      "abweichung" => if(falsch != [], do: abweichung(falsch, gemeldet, ist)),
      "offen_geblieben" => p["offen_geblieben"]
    }

    eintrag =
      case s.lauf do
        :schreiben -> Map.put(eintrag, "ausgelassen", p["ausgelassen"] || [])
        :durchsicht -> Map.put(eintrag, "durchgaenge", s.durchsicht.durchgang)
        _ -> eintrag
      end

    s = Stand.journal(s, "abschluss.jsonl", eintrag)

    {s,
     {:halt,
      Antwort.geordnet([
        {"ok", true},
        {"fertig", true},
        {"zahlen", Antwort.geordnet(Enum.map(zahlen(s), &{&1, ist[&1]}))},
        {"hinweis", "Abgeschlossen. Du kannst aufhören."}
      ])}}
  end

  # Die Antwort an Jack: welche Zahl nicht stimmt, nicht, was richtig wäre.
  defp gemeldet_falsch(k, nil), do: "#{k}: fehlt"

  defp gemeldet_falsch(k, v),
    do: "#{k}: du sagst #{v} — das stimmt nicht mit der Buchhaltung überein"

  # Nur fürs Journal: hier stehen beide Werte.
  defp abweichung(falsch, gemeldet, ist) do
    Enum.map(falsch, fn k ->
      case gemeldet[k] do
        nil -> "#{k}: fehlt (ist #{ist[k]})"
        v -> "#{k}: du sagst #{v}, gezaehlt sind #{ist[k]}"
      end
    end)
  end

  @doc "Die Zahlen, wie die Buchhaltung sie kennt."
  @spec ist_zahlen(Stand.t()) :: %{String.t() => non_neg_integer()}
  def ist_zahlen(%Stand{lauf: :durchsicht} = s) do
    z = Durchsicht.zaehler(s)
    %{"bestaetigt" => z.bestaetigt, "ersetzt" => z.ersetzt}
  end

  def ist_zahlen(%Stand{lauf: :schreiben} = s) do
    z = Stand.entwurf_zahlen(s)
    %{"absaetze" => z.absaetze, "saetze" => z.saetze}
  end

  def ist_zahlen(%Stand{} = s) do
    %{
      "fakten" => MapSet.size(s.gelesen),
      "gliederung" => length(Stand.abschnitt(s, "GLIEDERUNG"))
    }
  end

  @doc """
  Was den Abschluss verhindert. Leer heißt: fertig. `p` sind die Argumente
  von `fertig`; im Schreiben zählt daraus `ausgelassen`.
  """
  @spec hindernisse(Stand.t(), map()) :: [String.t()]
  def hindernisse(s, p \\ %{})

  def hindernisse(%Stand{lauf: :durchsicht} = s, _p) do
    offen = Durchsicht.offen(s)

    wenn(
      offen != [],
      "In Durchgang #{s.durchsicht.durchgang} sind diese Absätze noch offen: " <>
        "#{Enum.join(offen, ", ")}. Lies jeden mit durchsicht(nummer) und bestätige, ersetze " <>
        "oder streiche ihn."
    )
  end

  def hindernisse(%Stand{lauf: :schreiben} = s, p) do
    {begruendet, fehler} = ausgelassen(s, List.wrap(p["ausgelassen"]))
    arc = Enum.reject(Stand.arc_ohne_satz(s), &(norm(&1) in begruendet))

    wenn(
      s.entwurf == [],
      "Der Entwurf ist leer. Schreib das Resümee Absatz für Absatz mit absatz(), nach der " <>
        "GLIEDERUNG deiner Notizen."
    ) ++
      fehler ++
      wenn(
        arc != [],
        "Diese Handlungsbögen berührt die Sitzung, aber kein Satz nennt einen ihrer Fakten " <>
          "dieser Sitzung: #{Enum.join(arc, ", ")}. Erzähl jeden in mindestens einem Satz, der " <>
          "einen seiner Fakten nennt — oder nenn ihn in ausgelassen, mit dem Grund, warum er " <>
          "im Resümee fehlt."
      )
  end

  def hindernisse(%Stand{} = s, _p) do
    ungelesen = Stand.ungelesen(s)
    arc = Stand.arc_ohne_gliederung(s)
    mehr = if length(ungelesen) > 12, do: " …", else: ""

    wenn(
      ungelesen != [],
      "Diese Fakten dieser Sitzung hast du noch nicht gelesen: " <>
        "#{ungelesen |> Enum.take(12) |> Enum.join(", ")}#{mehr}. Hol sie mit " <>
        "fakten(von, bis) — die Gliederung spricht nur über Fakten, die du vor dir hattest."
    ) ++
      wenn(
        Stand.form(s) == nil,
        "Die FORM fehlt. Leite aus der Überschrift „#{s.ueberschrift}“ ab, welche Form das " <>
          "Resümee bekommt, und notier sie unter FORM."
      ) ++
      wenn(
        Stand.abschnitt(s, "GLIEDERUNG") == [],
        "Die GLIEDERUNG ist leer. Leg die Punkte des Resümees an, je mit den Fakten und " <>
          "Bögen, die sie abdecken."
      ) ++
      wenn(
        arc != [],
        "Diese Handlungsbögen berührt die Sitzung, aber kein Gliederungspunkt nennt sie: " <>
          "#{Enum.join(arc, ", ")}. Nimm jeden in einen Punkt auf (Feld boegen)."
      )
  end

  # Die gültig begründeten Auslassungen (normalisierte Titel) und die
  # Hindernisse aus ungültigen Angaben.
  defp ausgelassen(s, angaben) do
    Enum.reduce(angaben, {MapSet.new(), []}, fn a, {ok, fehler} ->
      titel = if is_map(a), do: to_string(a["bogen"] || ""), else: ""
      grund = if is_map(a), do: to_string(a["grund"] || ""), else: ""
      b = Stand.bogen_dieser_sitzung(s, titel)

      cond do
        b == nil ->
          {ok,
           fehler ++
             [
               "ausgelassen: „#{titel}“ ist kein Bogen dieser Sitzung. Nimm die Titel aus " <>
                 "boegen(), wie sie dort stehen."
             ]}

        b.art != "arc" ->
          {ok,
           fehler ++
             [
               "ausgelassen: „#{b.titel}“ hat die Art #{b.art} und darf ohne Grund fehlen. In " <>
                 "ausgelassen stehen nur Handlungsbögen der Art arc — nimm ihn heraus."
             ]}

        String.trim(grund) == "" ->
          {ok,
           fehler ++
             [
               "ausgelassen: für „#{b.titel}“ fehlt der Grund. Schreib in einem Satz, warum " <>
                 "der Bogen im Resümee fehlt."
             ]}

        true ->
          {MapSet.put(ok, norm(b.titel)), fehler}
      end
    end)
  end

  defp norm(t), do: Worker.ThreadOverride.normalize(t)

  defp wenn(true, text), do: [text]
  defp wenn(false, _text), do: []
end
