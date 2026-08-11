defmodule Worker.Recording.ConsentPhrase do
  @moduledoc """
  Issue #1002: Auswertung einer **gesprochenen Einwilligung** in die Aufzeichnung.

  Vorbild ist die Mikro-Setup-Prüfung (#400): der Sprecher sagt einen kurzen,
  vorgegebenen Satz, der Clip wird per Whisper transkribiert und gegen ein Soll
  geprüft. Hier ist der Satz die Einwilligung selbst — ein Sprechakt, der
  gleichzeitig Zustimmung, Mikro-Check und Stimme→Person-Zuordnung erledigt.

  **Warum das NICHT `HubWeb.CampaignLive.Mic.phrase_match?/2` benutzt** (der
  entscheidende Befund aus der #1002-Analyse): jene Funktion ist ein
  Bag-of-Words-Match mit 60 %-Schwelle (`MapSet`, Reihenfolge egal, zusätzliche
  Wörter irrelevant). Für einen Mikro-Test ist diese Toleranz genau richtig. Für
  eine Einwilligung ist sie **gefährlich**: bei Soll-Satz „ich stimme der
  Aufnahme zu" enthält „ich stimme der Aufnahme **nicht** zu" alle erwarteten
  Wörter → 100 % Match → eine Ablehnung würde als Zustimmung gezählt. Genau
  dieser Fehler darf hier nie passieren, deshalb eine eigene, strengere Logik.

  ## Die drei Ergebnisse

    * `:granted`  — eine der akzeptierten Formulierungen ist **vollständig**
      erkannt UND es gibt **kein** Negationswort im Transkript.
    * `:declined` — ein Negationswort ist da. Bewusst **unabhängig** davon, ob
      die Zustimmungswörter auch vorkommen: „ich stimme **nicht** zu" und „ich
      stimme zu, **kein** Problem" fallen beide hierher.
    * `:unclear`  — alles andere (Schweigen, Gerede, unverständlicher ASR-Output,
      halbe Formulierung).

  **Fail-closed ist die Leitregel:** nur `:granted` erlaubt eine Aufzeichnung;
  `:declined` und `:unclear` werden gleich behandelt (keine Aufzeichnung dieser
  Stimme). Der Unterschied zwischen beiden ist nur für die Anzeige da — „hat
  widersprochen" ist eine andere Information als „hat nichts gesagt", auch wenn
  die Konsequenz dieselbe ist.

  Die Asymmetrie ist Absicht: ein **falsches `:granted`** zeichnet jemanden gegen
  seinen Willen auf (schwerer, teils strafbarer Fehler); ein **falsches
  `:unclear`** kostet ihn nur einen zweiten Versuch. Deshalb ist die Negations-
  Prüfung absichtlich übervorsichtig — sie vetoert auch dann, wenn das
  Negationswort gar nicht zur Zustimmung gehört.
  """

  @typedoc "Ergebnis der Auswertung eines Transkripts."
  @type verdict :: :granted | :declined | :unclear

  # Der Satz, um den gebeten wird (die Ansage nennt ihn wörtlich, #989).
  @canonical_phrase "Ich stimme der Aufnahme zu."

  # Akzeptierte Formulierungen als Kern-Token-Mengen: ALLE Tokens einer Gruppe
  # müssen vorkommen. Reihenfolge wird NICHT geprüft (ASR stellt gelegentlich um);
  # die Sicherheit kommt aus dem Negations-Veto, nicht aus der Wortstellung.
  # Absichtlich knapp gehalten — jede zusätzliche Variante vergrößert die Fläche
  # für versehentliche Zustimmung.
  @accepted_patterns [
    ["stimme", "aufnahme", "zu"],
    ["stimme", "aufzeichnung", "zu"],
    ["einverstanden", "aufnahme"],
    ["einverstanden", "aufzeichnung"]
  ]

  # Negations-STÄMME (Präfix-Match), nicht exakte Wörter: eine exakte Liste ist
  # immer unvollständig — beim Schreiben der Tests fiel prompt „keinesfalls"
  # durch, weil nur „kein/keine/keinen/…" gelistet waren. Präfixe fangen die
  # Flexions- und Verstärkungsformen mit („kein" → keinesfalls/keineswegs,
  # „nicht" → nichts, „nie" → niemals).
  #
  # Dass Präfixe auch harmlose Wörter treffen („nie" in „niedlich", „ohne" in
  # „ohnehin"), ist hier KEIN Fehler, sondern die gewollte Richtung der
  # Asymmetrie: ein zu Unrecht vetoetes „granted" kostet einen zweiten Versuch,
  # ein zu Unrecht erteiltes zeichnet jemanden gegen seinen Willen auf.
  @negation_stems ~w(nicht kein nein nie widerspr widerruf untersag
                     verbiet verbot ablehn lehne verweiger dagegen ohne)

  # Version des EINWILLIGUNGS-WORTLAUTS. Sie gehört zum Text, nicht zum Pfad:
  # ändert sich, worin eingewilligt wird, muss die Version steigen — dann zählt
  # eine ältere Zustimmung nicht mehr (`ConsentGate` prüft das), und es wird neu
  # gefragt. Format `v<n>`, weil `Worker.Materializer.version_rank/1` (das
  # Max-Version-Lattice des Folds, #824) genau das erwartet.
  @consent_version "v1"

  @doc "Der Satz, um den die Ansage bittet (eine Quelle für Prompt + Doku)."
  @spec canonical_phrase() :: String.t()
  def canonical_phrase, do: @canonical_phrase

  @doc """
  Version des aktuellen Einwilligungs-Wortlauts. Beim Ändern von
  `canonical_phrase/0` (oder der Ansage-Formulierung, die den Umfang der
  Einwilligung beschreibt) **muss** sie hochgezogen werden.
  """
  @spec version() :: String.t()
  def version, do: @consent_version

  @doc """
  Wertet ein Whisper-Transkript aus. PURE.

  Reihenfolge der Prüfung ist wesentlich: **erst** das Negations-Veto, **dann**
  der Zustimmungs-Match. Umgekehrt würde „ich stimme der Aufnahme nicht zu" als
  `:granted` durchgehen.
  """
  @spec evaluate(String.t() | nil) :: verdict()
  def evaluate(transcript) when is_binary(transcript) do
    tokens = tokenize(transcript)

    cond do
      tokens == [] -> :unclear
      negated?(tokens) -> :declined
      accepted?(tokens) -> :granted
      true -> :unclear
    end
  end

  def evaluate(_), do: :unclear

  @doc "Nur die Zustimmung erlaubt eine Aufzeichnung (fail-closed)."
  @spec granted?(verdict()) :: boolean()
  def granted?(:granted), do: true
  def granted?(_), do: false

  # ─── intern ──────────────────────────────────────────────────────

  # Wie `normalize_phrase/1` im Mikro-Setup: lowercase, alles außer Buchstaben/
  # Zahlen zu Trennern. Umlaute bleiben (\p{L} ist unicode-aware) — „widersprüche"
  # würde sonst zu „widerspr che" zerfallen.
  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/u, trim: true)
  end

  defp negated?(tokens) do
    Enum.any?(tokens, fn token ->
      Enum.any?(@negation_stems, &String.starts_with?(token, &1))
    end)
  end

  defp accepted?(tokens) do
    set = MapSet.new(tokens)
    Enum.any?(@accepted_patterns, fn pattern -> Enum.all?(pattern, &MapSet.member?(set, &1)) end)
  end
end
