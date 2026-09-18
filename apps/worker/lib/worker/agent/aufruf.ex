defmodule Worker.Agent.Aufruf do
  @moduledoc """
  Ein Werkzeugaufruf nach den Regeln der Laufzeit: Wiederholungssperre,
  Werkzeug finden, Argumente, Schema (samt `bei_formfehler`), Ausführung ohne
  Absturz, Antwort als Text.

  Aus `Worker.Agent.Lauf` herausgelöst (11.09.2026), damit ein MCP-Server —
  der Referenzlauf über Claude Code headless (`Worker.Jack.Mcp`) — jeden
  Aufruf genauso behandelt wie die eigene Schleife. Dort ist Claude Code die
  Schleife; die Regeln je Aufruf bleiben unsere.

  Der Zustand ist jede Map mit `:werkzeuge` (Name → `Worker.Agent.Werkzeug`),
  `:wiederholung` (`Worker.Agent.Wiederholung` oder `nil`) und `:abbruch`
  (`nil` oder Grund) — der Lauf-Struct selbst oder `zustand/2`.
  """

  alias Worker.Agent.{Schema, Werkzeug, Wiederholung}

  @type aufruf :: %{
          required(:name) => String.t(),
          required(:argumente) => {:ok, map()} | {:error, String.t()},
          optional(atom()) => term()
        }
  @type art :: :ok | :error | :halt | :abbruch

  # Was ein Werkzeug intern liefern kann: dazu `:innerer_fehler` — eine
  # Ausnahme im Werkzeug selbst. Nach aussen wird daraus ein `:error` (mit
  # dem Hinweis, dass es nicht an den Angaben liegt) oder ein `:abbruch`
  # (nach dem Deckel); `art()` bleibt also die Menge, die die Laufschleife
  # sieht.
  @type werkzeug_art :: art() | :innerer_fehler
  @type sperre :: nil | {:warnung | :abbruch, pos_integer()}

  # Wie oft ein Werkzeug an sich selbst scheitern darf, bevor der Lauf endet.
  # Drei, damit ein einmaliger Aussetzer (ein Zeitüberschritt in einem
  # Leser) nichts kostet, ein echter Bug aber nicht 28 Runden frisst.
  @innere_fehler_deckel 3

  @doc """
  Ein Zustand für Aufrufe von außen. `wiederholungen` wie in
  `Worker.Agent.Lauf` (`[warnung: n, abbruch: m]`, `false` schaltet ab).
  """
  @spec zustand([Werkzeug.t()], keyword() | false) :: map()
  def zustand(werkzeuge, wiederholungen \\ []) do
    w =
      case wiederholungen do
        false ->
          nil

        opts when is_list(opts) ->
          case Wiederholung.neu(opts) do
            {:ok, w} -> w
            {:error, grund} -> raise ArgumentError, "wiederholungen: #{grund}"
          end
      end

    %{
      werkzeuge: Map.new(werkzeuge, &{&1.name, &1}),
      wiederholung: w,
      abbruch: nil,
      innere_fehler: %{}
    }
  end

  @doc """
  Erst der Wiederholungssperre zeigen, dann ausführen. Ab der Warnschwelle
  läuft der Aufruf nicht mehr, seine Antwort ist die Warnung (Tom: „der
  gewarnte wird nicht ausgeführt, und das steht auch in der Antwort“); an der
  Abbruchschwelle ist der Lauf abgebrochen. Ist er abgebrochen, läuft kein
  weiterer Aufruf, jeder bekommt aber eine Antwort.

  Liefert das Ergebnis, den neuen Zustand und den Status der Sperre (für das
  Protokoll).
  """
  @spec beobachtet(map(), aufruf()) :: {{art(), String.t()}, map(), sperre()}
  def beobachtet(%{abbruch: grund} = s, _aufruf) when grund != nil,
    do: {{:error, "Nicht ausgeführt: der Lauf ist abgebrochen."}, s, nil}

  def beobachtet(s, aufruf) do
    werkzeug = Map.get(s.werkzeuge, aufruf.name)
    art_zaehlung = if werkzeug, do: werkzeug.wiederholung, else: :zaehlt

    {w, status} =
      if art_zaehlung == :frei,
        do: {s.wiederholung, nil},
        else: Wiederholung.beobachten(s.wiederholung, schluessel(werkzeug, aufruf), art_zaehlung)

    s = %{s | wiederholung: w}

    case status do
      {:abbruch, n} ->
        {{:abbruch, wiederholung_antwort(werkzeug, aufruf, :abbruch, n, w.abbruch)},
         %{s | abbruch: {:wiederholung, aufruf.name}}, status}

      {:warnung, n} ->
        {{:error, wiederholung_antwort(werkzeug, aufruf, :warnung, n, w.abbruch)}, s, status}

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

        innerer_fehler(s, aufruf, art, text)
    end
  end

  # Ein Werkzeug, das an sich selbst scheitert, ist kein Hindernis.
  #
  # Am 18.09.2026 hat genau diese Verwechslung 28 Runden gekostet: Der
  # Abschluss der Chronik-Durchsicht warf bei JEDEM Aufruf
  # `key :absaetze not found`. Für das Modell sah das aus wie „dir fehlt noch
  # etwas", also suchte es — erst nach dem fehlenden Feld, dann in der ganzen
  # Arbeit von vorn. Es hat den Bug sogar richtig erkannt („This isn't
  # something I can fix by changing my parameters") und konnte trotzdem nicht
  # aufhören, weil ein Lauf nur über `fertig()` endet und `fertig` als `:frei`
  # nie in die Wiederholungssperre läuft.
  #
  # Deshalb zwei Dinge: Die Antwort SAGT, dass der Fehler nicht an den
  # Angaben liegt, und nach `@innere_fehler_deckel` Mal endet der Lauf — der
  # Bestand bleibt (jeder Jack veröffentlicht, was bis dahin steht), statt in
  # der Wiederholung zu verglühen.
  defp innerer_fehler(s, _aufruf, art, text) when art != :innerer_fehler,
    do: {{art, text}, s, nil}

  defp innerer_fehler(s, aufruf, :innerer_fehler, text) do
    n = Map.get(s.innere_fehler, aufruf.name, 0) + 1
    s = %{s | innere_fehler: Map.put(s.innere_fehler, aufruf.name, n)}

    hinweis =
      "Das Werkzeug #{aufruf.name} ist an einem inneren Fehler gescheitert: #{text} " <>
        "Das liegt NICHT an deinen Angaben — derselbe Aufruf scheitert wieder. " <>
        "Versuch es nicht mit anderen Feldern; die gibt es nicht."

    if n >= @innere_fehler_deckel do
      {{:abbruch,
        hinweis <>
          " Nach #{n} Versuchen endet der Lauf hier. Was du bis jetzt eingetragen hast, " <>
          "bleibt erhalten."}, %{s | abbruch: {:innerer_fehler, aufruf.name}}, nil}
    else
      {{:error, hinweis <> " Arbeite weiter, wenn du kannst."}, s, nil}
    end
  end

  # Der „gleiche Aufruf“: Name und Argumente, bei einem Werkzeug mit
  # `wiederholung_merkmal` dazu das Merkmal seines Stands vor dem Aufruf
  # (`Worker.Agent.Werkzeug`, „Gewollte Wiederholungen“). Wirft das Merkmal,
  # zählt der Aufruf ohne es — die Sperre bleibt wirksam.
  defp schluessel(%Werkzeug{wiederholung_merkmal: f}, %{argumente: {:ok, a}} = aufruf)
       when is_function(f, 1),
       do: {aufruf.name, aufruf.argumente, merkmal(f, a)}

  defp schluessel(_werkzeug, aufruf), do: {aufruf.name, aufruf.argumente}

  defp merkmal(f, argumente) do
    f.(argumente)
  rescue
    _ -> :merkmal_fehlt
  catch
    _, _ -> :merkmal_fehlt
  end

  @doc "Den Aufruf ausführen, ohne Sperre: finden, Argumente, Schema, sicher ausführen."
  @spec ausfuehren(aufruf(), %{String.t() => Werkzeug.t()}) :: {werkzeug_art(), String.t()}
  def ausfuehren(%{name: name} = aufruf, werkzeuge) do
    with {:ok, w} <- finden(werkzeuge, name),
         {:ok, argumente} <- argumente(aufruf) do
      case pruefen(w, argumente) do
        {:ok, angeglichen} -> sicher(w, fn -> w.ausfuehren.(angeglichen) end)
        {:formfehler, verstoesse} -> sicher(w, fn -> w.bei_formfehler.(argumente, verstoesse) end)
        {:error, _} = fehler -> fehler
      end
    end
  end

  @doc "Ein Werkzeugergebnis als Text: Text bleibt, alles andere wird JSON."
  @spec als_text(term()) :: String.t()
  def als_text(text) when is_binary(text), do: text
  def als_text(inhalt), do: Jason.encode!(inhalt)

  # Wortlaut des Spikes (`mitSperre`). Ein Werkzeug mit `bei_wiederholung`
  # formt die Antwort selbst — Jacks `aussage` antwortet einheitlich mit
  # outcome repeat/aborted. Scheitert der Rückruf, gilt der Text.
  defp wiederholung_antwort(werkzeug, aufruf, folge, n, abbruch_bei) do
    args =
      case aufruf.argumente do
        {:ok, a} -> a
        {:error, roh} -> roh
      end

    texte = Wiederholung.texte(folge, Wiederholung.kurz_aufruf(aufruf.name, args), n, abbruch_bei)

    case werkzeug do
      %{bei_wiederholung: f} when is_function(f, 4) and is_map(args) ->
        {fehler, hinweis} = texte

        try do
          als_text(f.(args, folge, fehler, hinweis))
        rescue
          _ -> Wiederholung.text(texte)
        end

      _ ->
        Wiederholung.text(texte)
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

  # Ein Werkzeug mit `bei_formfehler` beantwortet einen Schemaverstoß selbst
  # (siehe `Worker.Agent.Werkzeug`, „Formfehler“).
  defp pruefen(w, argumente) do
    case Schema.pruefen(w.parameter, argumente) do
      {:ok, angeglichen} ->
        {:ok, angeglichen}

      {:error, verstoesse} when w.bei_formfehler != nil ->
        {:formfehler, verstoesse}

      {:error, verstoesse} ->
        {:error,
         "Argumente für #{w.name} ungültig:\n" <>
           Enum.map_join(verstoesse, "\n", &"  - #{&1}") <>
           "\n\nErhalten:\n" <> Jason.encode!(argumente, pretty: true)}
    end
  end

  defp sicher(w, fun) do
    case fun.() do
      {art, inhalt} when art in [:ok, :error, :halt, :abbruch, :innerer_fehler] ->
        {art, als_text(inhalt)}

      anderes ->
        {:error, "Werkzeug #{w.name} lieferte ein ungültiges Ergebnis: #{inspect(anderes)}"}
    end
  rescue
    e -> {:innerer_fehler, Exception.message(e)}
  catch
    art, grund -> {:innerer_fehler, "#{art}: #{inspect(grund)}"}
  end
end
