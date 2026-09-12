defmodule Worker.Jack.Resuemee.Abschluss do
  @moduledoc """
  `fertig` für den Überblick des Resümee-Jack (J5, #1209) — nach dem Muster
  von `Worker.Jack.Abschluss`: das Werkzeug rechnet nach und lehnt ab,
  solange Arbeit offen ist, und vergleicht danach die gemeldeten Zahlen mit
  der eigenen Buchhaltung.

  **Offen ist der Überblick**, solange

    * ein Fakt dieser Sitzung ungelesen ist (die Gliederung darf nur über
      Fakten reden, die Jack vor sich hatte),
    * die FORM fehlt,
    * die GLIEDERUNG leer ist, oder
    * ein berührter Bogen der Art `arc` in keinem Gliederungspunkt vorkommt.
      Bögen der Art `context` und `rauschen` sind frei.

  **Die Zahlen:** `fakten` (gelesene Fakten dieser Sitzung) und `gliederung`
  (Punkte unter GLIEDERUNG), dazu `offen_geblieben` in Worten. Die Ablehnung
  sagt, welche Zahl nicht stimmt, nicht, was richtig wäre; der dritte Versuch
  geht trotzdem durch, die Abweichung steht dann mit beiden Werten im Journal
  (`abschluss.jsonl`) — wie beim Fakten-Jack (#1196, Punkt 5).

  Ergebnis: `{:halt, …}` bei Erfolg, sonst `{:error, …}`.
  """

  alias Worker.Jack.Antwort
  alias Worker.Jack.Resuemee.Stand

  @zahlversuche 3
  @zahlen ~w(fakten gliederung)

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Das Werkzeug `fertig` für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
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

  @doc "Die Parameter von `fertig`."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "fakten" => %{"type" => "integer", "minimum" => 0},
        "gliederung" => %{"type" => "integer", "minimum" => 0},
        "offen_geblieben" => %{
          "type" => "string",
          "minLength" => 0,
          "description" =>
            "was die Fakten zum Verstehen nicht hergeben — in Worten, nicht als Zahl"
        }
      }
    }
  end

  @doc "Den Überblick abschließen (Werkzeug `fertig`)."
  @spec fertig(Stand.t(), map()) :: ergebnis()
  def fertig(%Stand{} = s, p) do
    case hindernisse(s) do
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
    ist = ist_zahlen(s)
    gemeldet = Map.new(@zahlen, &{&1, p[&1]})
    falsch = Enum.filter(@zahlen, &(gemeldet[&1] != ist[&1]))
    versuch = s.abschluss_zahlversuche + if(falsch == [], do: 0, else: 1)
    s = %{s | abschluss_zahlversuche: versuch}

    if falsch != [] and versuch < @zahlversuche do
      s =
        Stand.journal(s, "abschluss.jsonl", %{
          "versuch" => "zahlen",
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
    s =
      Stand.journal(s, "abschluss.jsonl", %{
        "abschluss" => true,
        "lauf" => to_string(s.lauf),
        "zahlen" => ist,
        "gemeldet" => gemeldet,
        "zahlen_stimmten" => if(falsch == [], do: "ja", else: "nein"),
        "abweichung" => if(falsch != [], do: abweichung(falsch, gemeldet, ist)),
        "offen_geblieben" => p["offen_geblieben"]
      })

    {s,
     {:halt,
      Antwort.geordnet([
        {"ok", true},
        {"fertig", true},
        {"zahlen", Antwort.geordnet(Enum.map(@zahlen, &{&1, ist[&1]}))},
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
  def ist_zahlen(%Stand{} = s) do
    %{
      "fakten" => MapSet.size(s.gelesen),
      "gliederung" => length(Stand.abschnitt(s, "GLIEDERUNG"))
    }
  end

  @doc "Was den Abschluss verhindert. Leer heißt: fertig."
  @spec hindernisse(Stand.t()) :: [String.t()]
  def hindernisse(%Stand{} = s) do
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

  defp wenn(true, text), do: [text]
  defp wenn(false, _text), do: []
end
