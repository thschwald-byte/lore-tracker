defmodule Worker.Jack.Probieren do
  @moduledoc """
  Rumprobieren erkennen (Spike `werkzeuge.ts`, „Rumprobieren erkennen“, Toms
  Wunsch vom 10.09.). Zwei Formen, beide in Reihe C belegt und beide ohne
  Raten erkennbar:

    1. **`aussage` als Abfrage:** eingereicht ohne GUID, Antwort `verify`,
       danach keine Entscheidung. In `lauf35_iter2_c` waren das 104 von 113
       Einreichungen. Ab der zehnten in Folge, danach bei jeder fünften, steht
       ein Hinweis vorn im `hinweis`. Eine echte Eintragung (`written`,
       `modify`) oder eine Entscheidung (`aussage_entscheiden`, trägt immer
       eine GUID) setzt die Serie zurück. Der Hinweis kommt **nur im ersten
       Durchgang**: in einem Verifizierungsdurchgang sind Kollisionen in Folge
       die gewollte Arbeit (Spike seit 60aa1e84).
    2. **`suche` mit einem Aussagesatz:** mindestens sechs Wörter, oder
       deckungsgleich mit einer in diesem Lauf eingereichten Aussage. Damit
       prüft Jack, „ob es schon eingetragen ist“; `suche` kennt aber nur den
       Mitschnitt.

  Nichts davon blockiert: die Suche läuft, die Einreichung auch. Jeder
  Hinweis steht im Journal `probieren.jsonl`.

  Der Zustand lebt je Lauf im `Worker.Jack.Halter`, wie im Spike je
  pi-Prozess; er gehört nicht zum Stand und übersteht keine Fortsetzung.
  Aufrufe, die die Wiederholungssperre abfängt, kommen hier nicht an — auch
  das wie im Spike.

  Wo der Bestand dünn ist, sagt der Hinweis bewusst nicht (Toms Entscheidung,
  keine Bestandssicht beim Sammeln): wer weiß, wo „Lücken“ sind, verteilt
  seine Suche gleichmäßig, obwohl manche Bereiche mehr hergeben als andere.
  """

  alias Worker.Jack.Stand

  @ab 10
  @alle 5
  @satz_woerter 6
  @satz_zeichen 20

  @suche_hinweis "HINWEIS: suche() durchsucht nur den Mitschnitt, nicht den Bestand — ob etwas " <>
                   "schon eingetragen ist, kannst du damit nicht prüfen. Trag ein, was du im " <>
                   "Mitschnitt findest; steht es schon da, zeigt dir aussage() das beim " <>
                   "Eintragen.\n\n"

  defstruct serie: 0, eingereicht: []

  @type t :: %__MODULE__{serie: non_neg_integer(), eingereicht: [String.t()]}

  @doc "Ein leerer Zustand, zu Beginn eines Laufs."
  @spec neu() :: t()
  def neu, do: %__MODULE__{}

  @doc """
  Sieht sich einen ausgeführten Aufruf an: merkt sich, was nötig ist, und
  stellt gegebenenfalls einen Hinweis vor das Ergebnis. Liefert Zustand,
  Stand (mit Journal) und Ergebnis.
  """
  @spec nachsehen(t(), Stand.t(), String.t() | nil, map(), term()) :: {t(), Stand.t(), term()}
  def nachsehen(p, s, name, argumente, {art, %{"outcome" => outcome} = a})
      when name in ["aussage", "aussage_entscheiden"] do
    p = p |> merken(argumente["claim"]) |> zaehlen(name, outcome)

    if s.durchgang == 1 and name == "aussage" and outcome == "verify" and faellig?(p.serie) do
      s =
        Stand.journal(
          s,
          "probieren.jsonl",
          eintrag(s, %{"art" => "abfrageserie", "n" => p.serie})
        )

      {p, s, {art, Map.put(a, "hinweis", serie_text(p.serie) <> (a["hinweis"] || ""))}}
    else
      {p, s, {art, a}}
    end
  end

  def nachsehen(p, s, "suche", %{"begriff" => begriff}, {art, text})
      when is_binary(begriff) and is_binary(text) do
    case grund(p, norm(begriff)) do
      nil ->
        {p, s, {art, text}}

      grund ->
        s =
          Stand.journal(
            s,
            "probieren.jsonl",
            eintrag(s, %{
              "art" => "suche_mit_aussagesatz",
              "grund" => grund,
              "begriff" => String.slice(begriff, 0, 120)
            })
          )

        {p, s, {art, @suche_hinweis <> text}}
    end
  end

  def nachsehen(p, s, _name, _argumente, ergebnis), do: {p, s, ergebnis}

  defp merken(p, claim) when is_binary(claim) do
    c = norm(claim)
    if String.length(c) >= @satz_zeichen, do: %{p | eingereicht: [c | p.eingereicht]}, else: p
  end

  defp merken(p, _claim), do: p

  defp zaehlen(p, "aussage_entscheiden", _outcome), do: %{p | serie: 0}
  defp zaehlen(p, "aussage", "verify"), do: %{p | serie: p.serie + 1}
  defp zaehlen(p, "aussage", outcome) when outcome in ["written", "modify"], do: %{p | serie: 0}
  defp zaehlen(p, _name, _outcome), do: p

  defp faellig?(n), do: n >= @ab and rem(n - @ab, @alle) == 0

  defp serie_text(n) do
    "Deine letzten #{n} Einreichungen standen alle schon im Bestand. aussage() ist zum " <>
      "Eintragen da, nicht zum Nachsehen. Geh die Blöcke weiter der Reihe nach durch und " <>
      "trag ein, was du dort findest.\n\n"
  end

  defp grund(p, q) do
    cond do
      length(String.split(q, " ", trim: true)) >= @satz_woerter ->
        "lang"

      String.length(q) >= @satz_zeichen and
          Enum.any?(p.eingereicht, &(String.contains?(&1, q) or String.contains?(q, &1))) ->
        "wie_eingereichte_aussage"

      true ->
        nil
    end
  end

  defp eintrag(s, felder), do: Map.put(felder, "phase", s.phase)

  # Wie `norm` im Spike: Leerraum zusammenziehen, trimmen, klein. Nicht
  # `Beleg.norm`, das zusätzlich faltet — die Schwellen sind auf diese
  # Normalform gemessen.
  defp norm(t), do: t |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.downcase()
end
