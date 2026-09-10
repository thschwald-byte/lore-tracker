defmodule Worker.Jack.Antwort do
  @moduledoc """
  Die einheitliche Antwort von `aussage` und `aussage_entscheiden`, und ihre
  Texte.

  Wie im Spike (`einheitlich`, `alsEintrag`) hat jede Antwort dieselben
  Felder: `outcome`, `aussagen`, `fehler`, `hinweis`, `bestand`, `themen`.
  `outcome` ist einer von

    * `written` / `modify` — eingetragen bzw. ersetzt;
    * `verify` — eine Vorlage aus dem Bestand, oder eine wortgleiche Aussage;
    * `fix` — ein Feld stimmt nicht, nichts eingetragen;
    * `exhausted` — der fünfte vergebliche Versuch mit derselben Aussage;
    * `no_scaffold` — das Gerüst im Gedächtnis fehlt;
    * `fraud` / `expired` / `misplaced` — eine erfundene, abgelaufene oder
      an eine andere Stelle gebundene GUID.

  In `aussagen` trägt jeder Eintrag einen `status` (`vorgelegt`, `bestehend`,
  `identisch`, `neu`, `ersetzt`, `verworfen`). Keine interne Nummer: adressiert
  wird ausschließlich über die GUID. Die Texte sind die des Spikes; wo der
  Spike ein zweites `aussage()` mit Steuerfeldern verlangte, steht jetzt
  `aussage_entscheiden()` (Toms Entscheidung, das Werkzeug zu teilen).
  """

  alias Worker.Jack.Stand

  @felder ~w(claim beleg source_refs character cast_match fact_type threads narration_time
             time_anchor precision in_game_date time_offset entscheidung)

  @doc "Die einheitliche Antwort."
  @spec einheitlich(Stand.t(), String.t(), [map() | nil], [String.t()], String.t()) :: map()
  def einheitlich(%Stand{} = s, outcome, aussagen, fehler, hinweis) do
    %{
      "outcome" => outcome,
      "aussagen" => Enum.reject(aussagen, &is_nil/1),
      "fehler" => fehler,
      "hinweis" => hinweis,
      "bestand" => s.lfd,
      "themen" => Enum.take(s.themen, 40)
    }
  end

  @doc """
  Ein Datensatz, wie Jack ihn sieht: nur die Inhaltsfelder, dazu `status` und
  gegebenenfalls die GUID. Aus der Entscheidung fällt `gegen` (die interne
  Nummer) heraus; die eigene Eingabe (`vorgelegt`) zeigt keine Entscheidung.
  """
  @spec als_eintrag(map() | nil, String.t(), String.t() | nil) :: map() | nil
  def als_eintrag(rec, status, guid \\ nil)
  def als_eintrag(nil, _status, _guid), do: nil

  def als_eintrag(rec, status, guid) do
    e =
      if guid,
        do: %{"status" => status, "verifikations_guid" => guid},
        else: %{"status" => status}

    e =
      Enum.reduce(@felder, e, fn k, e ->
        cond do
          k == "entscheidung" and status == "vorgelegt" -> e
          Map.has_key?(rec, k) -> Map.put(e, k, rec[k])
          true -> e
        end
      end)

    e
    |> ohne_gegen()
    |> alter_escape_raus(status)
  end

  defp ohne_gegen(%{"entscheidung" => %{} = ent} = e),
    do: Map.put(e, "entscheidung", Map.delete(ent, "gegen"))

  defp ohne_gegen(e), do: e

  # Bestand aus Läufen vor dem 10.09. trägt noch den alten Escape-Wert. Nur
  # dort umschreiben — die eigene Eingabe zeigt, was Jack geschickt hat.
  defp alter_escape_raus(%{"cast_match" => c} = e, status)
       when status != "vorgelegt" and is_binary(c) do
    if String.trim(c) == Stand.alter_escape(), do: Map.put(e, "cast_match", ""), else: e
  end

  defp alter_escape_raus(e, _status), do: e

  @doc "Fehler und Hinweis, wenn das Gerüst im Gedächtnis fehlt."
  @spec geruest(Stand.t(), [String.t()]) :: {String.t(), String.t()}
  def geruest(%Stand{} = s, [erstes | _] = fehlt) do
    fehler =
      if String.starts_with?(erstes, "(") do
        "Dein Gedächtnis ist zu dünn: #{length(Stand.eintraege_mit_inhalt(s))} " <>
          "Einträge mit Inhalt, mindestens 10."
      else
        "Dem Gerüst in deinem Gedächtnis fehlt: " <> Enum.join(fehlt, ", ") <> "."
      end

    hinweis =
      "Nichts eingetragen.\n" <>
        "Bevor du einträgst, braucht dein Gedächtnis ein Gerüst: in jedem der fünf " <>
        "Abschnitte mindestens einen Eintrag mit Inhalt, zusammen mindestens 10. " <>
        "Leg sie mit notiz() an:\n" <>
        "  FIGUREN — wer vorkommt: Name, Rolle, Zugehörigkeit\n" <>
        "  ABLAUF — was in welchem Bereich geschieht; der Schlüssel ist der Bereich (\"0-180\")\n" <>
        "  AUFTRAG — worum es geht\n" <>
        "  THEMEN — die Themen, die sich durchziehen\n" <>
        "  OFFEN — Widersprüche und offene Fragen\n" <>
        "Danach trägst du wie gewohnt ein."

    {fehler, hinweis}
  end

  @doc "Der Text, mit dem eine Verifikation vorgelegt wird (`n` Vorlagen)."
  @spec verifikations_hinweis(pos_integer(), String.t() | nil) :: String.t()
  def verifikations_hinweis(n, kopf \\ nil) do
    [erste | rest] = if n == 1, do: eine(), else: mehrere(n)
    Enum.join([kopf || erste | rest], "\n")
  end

  defp eine do
    [
      "Du hast eine mögliche Übereinstimmung gefunden — verifiziere.",
      "",
      "An dieser Stelle steht schon eine Aussage im Bestand. Deine steht oben als " <>
        "„vorgelegt“ — sie ist noch nicht gespeichert. Vergleiche sie mit der bestehenden.",
      "",
      "Je nach Ergebnis gibt es drei Wege:",
      "",
      "1. Die bestehende Aussage sagt dasselbe wie deine.",
      "   → Deine ist damit schon im Bestand — reich sie nicht noch einmal ein und " <>
        "mach mit deiner nächsten Aussage weiter. Das gilt auch, wenn sich nur die " <>
        "Formulierung unterscheidet.",
      "",
      "2. Deine Aussage sagt etwas anderes — einen anderen Sachverhalt, auch wenn er " <>
        "an derselben Stelle steht.",
      "   → Trag sie als eigene Aussage ein: aussage_entscheiden() mit denselben Feldern, " <>
        "dazu die verifikations_guid aus dieser Antwort, entscheidung: \"neu\", " <>
        "begruendung — in einem Satz, worin sie sich unterscheidet — und weitere_guids: [].",
      "",
      "3. Deine Aussage ist die bessere Fassung — genauer belegt, vollständiger oder " <>
        "richtiger zugeordnet.",
      "   → Sie ersetzt die bestehende: aussage_entscheiden() mit der verifikations_guid, " <>
        "entscheidung: \"ersetzt\", begruendung — was deine besser macht — und weitere_guids: [].",
      "",
      "Die GUID gilt nur für deinen nächsten Aufruf und nur für eine Aussage an " <>
        "denselben Blöcken (mindestens einer gemeinsam). Nimm sie aus dieser Antwort — " <>
        "erfundene werden abgewiesen."
    ]
  end

  defp mehrere(n) do
    [
      "Du hast mögliche Übereinstimmungen gefunden — verifiziere.",
      "",
      "An dieser Stelle stehen schon #{n} Aussagen im Bestand " <>
        "(die nächstliegende zuerst). Deine steht oben als „vorgelegt“ — sie ist noch " <>
        "nicht gespeichert. Vergleiche sie mit jeder davon.",
      "",
      "Je nach Ergebnis gibt es drei Wege:",
      "",
      "1. Eine der bestehenden Aussagen sagt dasselbe wie deine.",
      "   → Deine ist damit schon im Bestand — reich sie nicht noch einmal ein und " <>
        "mach mit deiner nächsten Aussage weiter. Das gilt auch, wenn sich nur die " <>
        "Formulierung unterscheidet.",
      "",
      "2. Deine Aussage sagt etwas anderes als alle bestehenden — einen anderen " <>
        "Sachverhalt, auch wenn er an derselben Stelle steht.",
      "   → Trag sie als eigene Aussage ein: aussage_entscheiden() mit denselben Feldern, " <>
        "dazu verifikations_guid (irgendeine aus dieser Antwort), entscheidung: \"neu\", " <>
        "begruendung — in einem Satz, worin sie sich unterscheidet — und weitere_guids: [].",
      "",
      "3. Deine Aussage ist die bessere Fassung einer bestehenden — genauer belegt, " <>
        "vollständiger oder richtiger zugeordnet.",
      "   → Sie ersetzt diese: aussage_entscheiden() mit der verifikations_guid genau " <>
        "dieser Aussage, entscheidung: \"ersetzt\" und begruendung — was deine besser macht. " <>
        "Deckt deine Fassung mehrere der bestehenden ab, gib deren GUIDs in weitere_guids " <>
        "mit; sie werden verworfen und verweisen auf deine. Sonst weitere_guids: [].",
      "",
      "Die GUIDs gelten nur für deinen nächsten Aufruf und nur für eine Aussage an " <>
        "denselben Blöcken (mindestens einer gemeinsam). Nimm sie aus dieser Antwort — " <>
        "erfundene werden abgewiesen."
    ]
  end

  @doc """
  Fehler und Hinweis zu einer erfundenen (`fraud`) oder abgelaufenen
  (`expired`) GUID. `feld` ist `"verifikations_guid"` oder `"weitere_guids"`,
  `pos` die Stelle in `weitere_guids`.
  """
  @spec guid_problem(Stand.t(), :fraud | :expired, String.t(), non_neg_integer(), atom() | nil) ::
          {String.t(), String.t()}
  def guid_problem(%Stand{} = s, art, feld, pos, schicksal) do
    wer =
      if feld == "verifikations_guid",
        do: "Die verifikations_guid",
        else: "Die #{pos}. GUID in weitere_guids"

    fehler =
      cond do
        art == :fraud ->
          "#{wer} hat dieses Werkzeug nie ausgegeben — sie ist erfunden."

        schicksal == :eingeloest ->
          "#{wer} ist schon eingelöst — jede GUID gilt nur einmal."

        true ->
          "#{wer} ist verfallen — sie galt nur für den Aufruf direkt nach ihrer " <>
            "Verifikation, und dort hast du sie nicht genannt."
      end

    betrug =
      if art == :fraud,
        do: [
          "Eine GUID ist zufällig und kommt nur aus einer Verifikation — herleiten, " <>
            "weiterzählen oder raten geht nicht. Eine erfundene GUID würde im Zweifel eine " <>
            "fremde Aussage überschreiben; deshalb wird sie abgewiesen und protokolliert." <>
            if(s.geraten > 1,
              do: " Das ist deine #{s.geraten}. erfundene GUID in diesem Durchgang.",
              else: ""
            )
        ],
        else: []

    weiter =
      if feld == "verifikations_guid",
        do:
          "So geht es weiter: reich die Aussage mit aussage() neu ein. Steht an der " <>
            "Stelle nichts Ähnliches im Bestand, wird sie eingetragen; steht etwas da, " <>
            "bekommst du es mit gültigen GUIDs vorgelegt.",
        else:
          "Die übrigen GUIDs, die du in diesem Aufruf genannt hast, gelten weiter. " <>
            "Ruf erneut auf — ohne die abgewiesene, oder mit leerer Liste weitere_guids."

    {fehler, Enum.join(["Nichts eingetragen." | betrug] ++ [weiter], "\n")}
  end
end
