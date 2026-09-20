defmodule Worker.Timeline.Kette do
  @moduledoc """
  #1247: die **Kette** — die zeitliche Reihenfolge des Geschehens. Pur, ohne
  Mnesia und ohne Modell.

  ## Zwei Achsen, und das ist der ganze Punkt

  Maintainer, 20.09.2026: „es gibt 2 achsen — 1: die kette: in zeitlicher
  reihenfolge, 2: die sprechlinie: was wann gesprochen wurde. 2 bleibt
  unverändert, 1 wird komplett neu aufgebaut."

  Bis dahin gab es nur eine: `Worker.Timeline.Linie` nahm die
  Sprechreihenfolge und **mutierte** sie mit Verschiebungen. Was gesprochen
  wurde und wann es geschah war dasselbe Ding. Für eine Uhrzeit im Spiel
  fällt beides zusammen, für einen Rückblick nicht — und am echten Lauf vom
  20.09.2026 ist es aufgeschlagen: Der Weltbau-Block am Sitzungsanfang
  erzählt die Jahre 2000 bis 2011, steht aber in einer Sitzung, die 2080
  spielt. Die eine Achse las das als Folge und rechnete rückwärts.

  ## Ein Glied ist eine ZEITEINHEIT, nicht eine Äußerung

  Maintainer: „jack soll auch kettenglieder aus mehreren utts bilden
  können." Eine Szene — Ankunft, Verhandlung, Rückzug — ist ein Glied, auch
  wenn vierzig Äußerungen dazugehören. Daraus folgt zweierlei:

    * Ein Glied braucht eine **eigene Kennung**; die Utterance-ID taugt
      nicht mehr als Adresse, sobald mehrere zusammengehören.
    * Die Kette wird **kurz genug, um sie zu lesen**. Eine Sitzung mit 2168
      Äußerungen hat vielleicht achtzig Glieder — die kann ein Modell
      überblicken, die Äußerungen nicht.

  ## Die Kette beginnt LEER

  Maintainer: „Default beim Start: Kette ist leer — jack soll bewusst
  einsortieren." Es gibt keine stillschweigende Übernahme der
  Sprechreihenfolge. Jede Äußerung braucht eine Entscheidung: in ein Glied,
  oder ausdrücklich hinaus (Tischgespräch). Was niemand entschieden hat,
  ist **offen** — und `fertig()` fragt danach.

  Der Unterschied ist keine Förmlichkeit. Mit einem Default hiesse „nicht
  angefasst" zweierlei zugleich: „die Reihenfolge stimmt hier" und „ich bin
  noch nicht hingekommen". Genau diese Verwechslung machte die Schranke des
  Einsortier-Laufs bisher unscharf.

  ## Die fünf Operationen

      anhaengen(kette, utts, opts)     ein NEUES Glied, hinten oder an einer Stelle
      erweitern(kette, glied, utts, o) ein BESTEHENDES Glied wächst, bleibt wo es ist
      versetzen(kette, glied, wohin)   vor/nach ein anderes Glied, oder an den Anfang
      loeschen(kette, glied)           das Glied fällt heraus, seine Utts sind offen
      draussen(kette, utts, grund)     Äußerungen, die nie hineingehören

  `anhaengen` und `erweitern` sind nicht dasselbe, und die Verwechslung
  kostet die Stelle: Wer zwei Glieder über `anhaengen` vereinigt, bekommt
  ein neues Glied **am Ende** der Kette; wer über `erweitern` geht, lässt
  die Szene, wo sie ist, und macht sie grösser.

  **Die Elemente eines Gliedes sind selbst eine Kette** (Maintainer,
  20.09.2026). `erweitern/4` nimmt deshalb dieselben Positionsangaben wie
  `anhaengen/3` — nur zeigen sie dort auf eine Äußerung des Gliedes statt
  auf ein Glied der Kette.

  Alle fünf halten die Kette **durchgehend** (Maintainer: „so dass es weiter
  eine durchgehende kette ist"): Wer ein Glied herausnimmt, schliesst die
  Lücke; wer es woanders einsetzt, hinterlässt keine. Und jede eingereihte
  Äußerung steht **genau einmal** darin — das prüft `kette_test.exs` nach
  jeder Operation, nicht nur die Länge.
  """

  @typedoc "Die Kennung eines Gliedes — stabil über seine Lebensdauer."
  @type glied_id :: String.t()

  @typedoc """
  Ein Glied der Kette: eine Zeiteinheit aus einer oder mehreren Äußerungen.
  """
  @type glied :: %{
          id: glied_id(),
          utts: [String.t()],
          grund: String.t() | nil
        }

  @typedoc "Die Kette: Glieder in zeitlicher Reihenfolge, plus die, die draussen sind."
  @type t :: %{
          glieder: [glied()],
          draussen: %{String.t() => String.t()}
        }

  @doc "Eine leere Kette."
  @spec neu() :: t()
  def neu, do: %{glieder: [], draussen: %{}}

  @doc """
  Hängt ein neues Glied aus `utts` an.

  Optionen: `:vor` / `:nach` (eine `glied_id`) setzen es an eine bestimmte
  Stelle, `:anfang` ganz nach vorn; ohne Angabe hinten an. `:grund` ist eine
  Notiz für Menschen.

  **Eine Äußerung liegt in höchstens einem Glied.** Wer sie erneut anhängt,
  nimmt sie aus dem alten heraus — sonst stünde dieselbe Äußerung an zwei
  Stellen der Zeit, und die Kette wäre keine Reihenfolge mehr. Wird ein Glied
  dadurch leer, fällt es weg.
  """
  @spec anhaengen(t(), [String.t()], keyword()) :: {:ok, t(), glied()} | {:fehler, String.t()}
  def anhaengen(kette, utts, opts \\ [])

  def anhaengen(_kette, [], _opts),
    do: {:fehler, "Ein Glied ohne Äußerung trägt nichts — nenn mindestens eine Zeile."}

  def anhaengen(%{} = kette, utts, opts) when is_list(utts) do
    utts = Enum.uniq(utts)
    kette = loesbinden(kette, utts)
    glied = %{id: kennung(utts), utts: utts, grund: opts[:grund]}

    case einsetzen(kette.glieder, glied, opts) do
      {:ok, glieder} ->
        {:ok, %{kette | glieder: glieder, draussen: Map.drop(kette.draussen, utts)}, glied}

      {:fehler, _} = f ->
        f
    end
  end

  @doc """
  Versetzt ein Glied: `{:vor, glied_id}`, `{:nach, glied_id}` oder `:anfang`.

  **Beide Richtungen, ausdrücklich** (Maintainer, 20.09.2026: „verschiebe
  uuid a hinter uuid b — aber es muss auch geben verschiebe uuid a vor uuid
  b"). Ein Rückblick gehört vor etwas, eine Ankündigung dahinter; mit nur
  einer Richtung müsste man die andere über den Nachbarn ausdrücken, und
  wer den Nachbarn später versetzt, verliert die Aussage.
  """
  @spec versetzen(t(), glied_id(), {:vor | :nach, glied_id()} | :anfang) ::
          {:ok, t()} | {:fehler, String.t()}
  def versetzen(%{} = kette, glied_id, wohin) do
    case entnehmen(kette.glieder, glied_id) do
      {nil, _} ->
        {:fehler, "Das Glied #{glied_id} gibt es in der Kette nicht."}

      {glied, rest} ->
        case wohin do
          :anfang ->
            {:ok, %{kette | glieder: [glied | rest]}}

          {richtung, ziel} when richtung in [:vor, :nach] ->
            wenn_ziel_da(kette, rest, glied, richtung, ziel)

          _ ->
            {:fehler, "Sag wohin: vor ein Glied, nach ein Glied, oder an den Anfang."}
        end
    end
  end

  defp wenn_ziel_da(kette, rest, glied, richtung, ziel) do
    cond do
      ziel == glied.id ->
        {:fehler, "Ein Glied kann nicht vor oder hinter sich selbst stehen."}

      not Enum.any?(rest, &(&1.id == ziel)) ->
        {:fehler, "Das Zielglied #{ziel} gibt es in der Kette nicht."}

      true ->
        {:ok, %{kette | glieder: setze_relativ(rest, glied, richtung, ziel)}}
    end
  end

  @doc """
  Hängt Äußerungen **an ein bestehendes Glied** — das Glied wächst und
  bleibt, wo es ist.

  **Das ist etwas anderes als `anhaengen/3`** (Maintainer, 20.09.2026:
  „wenn man ein glied aus der kette nimmt und nicht wieder in die kette
  hängt, sondern an ein glied hängt?"). `anhaengen/3` bildet ein NEUES
  Glied und setzt es an eine Stelle; die Utterances verlassen ihre alten
  Glieder, und das Ergebnis liegt dort, wo das neue Glied hinkommt — bei
  zwei verschmolzenen Gliedern also am Ende statt an der Stelle eines der
  beiden. Für „diese Zeilen gehören zu der Szene da" ist das falsch: Die
  Szene soll bleiben, wo sie ist, nur grösser werden.

  Die Kennung ändert sich dabei (sie ist content-adressiert) — die Stelle
  in der Kette nicht.
  """
  @spec erweitern(t(), glied_id(), [String.t()], keyword()) ::
          {:ok, t(), glied()} | {:fehler, String.t()}
  def erweitern(kette, glied_id, utts, opts \\ [])

  def erweitern(%{} = kette, glied_id, utts, opts) when is_list(utts) do
    case glied(kette, glied_id) do
      nil ->
        {:fehler, "Das Glied #{glied_id} gibt es in der Kette nicht."}

      alt ->
        neue = im_glied(alt.utts, utts, opts)
        # Erst die Fremdbindungen lösen, DANN das Zielglied neu setzen —
        # sonst nimmt `loesbinden/2` dem Zielglied seine eigenen Äußerungen.
        kette = loesbinden(kette, utts -- alt.utts)
        groesser = %{alt | id: kennung(neue), utts: neue}

        glieder =
          Enum.map(kette.glieder, fn g -> if g.id == alt.id, do: groesser, else: g end)

        {:ok, %{kette | glieder: glieder, draussen: Map.drop(kette.draussen, utts)}, groesser}
    end
  end

  @doc """
  Nimmt ein Glied aus der Kette. Seine Äußerungen sind danach **offen** —
  nicht draussen: Herausnehmen ist kein Urteil über den Inhalt.
  """
  @spec loeschen(t(), glied_id()) :: {:ok, t()} | {:fehler, String.t()}
  def loeschen(%{} = kette, glied_id) do
    case entnehmen(kette.glieder, glied_id) do
      {nil, _} -> {:fehler, "Das Glied #{glied_id} gibt es in der Kette nicht."}
      {_, rest} -> {:ok, %{kette | glieder: rest}}
    end
  end

  @doc """
  Erklärt Äußerungen für **draussen** — Tischgespräch, Regelfrage, Smalltalk.
  Sie kommen nie in die Kette und werden nie datiert.
  """
  @spec draussen(t(), [String.t()], String.t()) :: {:ok, t()}
  def draussen(%{} = kette, utts, grund) when is_list(utts) do
    kette = loesbinden(kette, utts)
    {:ok, %{kette | draussen: Enum.reduce(utts, kette.draussen, &Map.put(&2, &1, grund))}}
  end

  @doc """
  Die Äußerungen, über die noch niemand entschieden hat — weder in einem
  Glied noch draussen. **Das ist die Schranke des Einsortier-Laufs.**
  """
  @spec offen(t(), [String.t()]) :: [String.t()]
  def offen(%{} = kette, alle_utts) when is_list(alle_utts) do
    drin = eingereiht(kette)
    Enum.reject(alle_utts, &(MapSet.member?(drin, &1) or Map.has_key?(kette.draussen, &1)))
  end

  @doc "Alle Äußerungen, die in einem Glied liegen."
  @spec eingereiht(t()) :: MapSet.t()
  def eingereiht(%{glieder: g}), do: g |> Enum.flat_map(& &1.utts) |> MapSet.new()

  @doc "Das Glied, in dem eine Äußerung liegt — oder `nil`."
  @spec glied_von(t(), String.t()) :: glied() | nil
  def glied_von(%{glieder: g}, utterance_id),
    do: Enum.find(g, &(utterance_id in &1.utts))

  @doc "Ein Glied nach seiner Kennung."
  @spec glied(t(), glied_id()) :: glied() | nil
  def glied(%{glieder: g}, id), do: Enum.find(g, &(&1.id == id))

  @doc """
  Die Äußerungen der Kette in ihrer zeitlichen Reihenfolge — Glied für
  Glied, innerhalb eines Gliedes in der Reihenfolge seiner Äußerungen.
  """
  @spec reihenfolge(t()) :: [String.t()]
  def reihenfolge(%{glieder: g}), do: Enum.flat_map(g, & &1.utts)

  # **Die Elemente eines Gliedes sind selbst eine Kette** (Maintainer,
  # 20.09.2026: „und elemente an einem glied sind auch eine kette"). Dieselbe
  # Sprache auf beiden Ebenen: `vor:` / `nach:` nennen hier eine
  # **Utterance** des Gliedes statt eines Gliedes der Kette, `anfang:` setzt
  # nach vorn. Ohne Angabe wird hinten angehängt.
  #
  # Warum das zählt: Eine Szene wird oft in zwei Anläufen erkannt — erst der
  # Kern, dann eine Zeile, die davor gehört („ach, das fing schon bei 98
  # an"). Ohne Positionsangabe landete sie am Ende der Szene, also in der
  # falschen Reihenfolge, und die einzige Abhilfe wäre, das ganze Glied neu
  # zu bilden.
  defp im_glied(vorhandene, neue, opts) do
    neue = Enum.uniq(neue) -- vorhandene
    rest = vorhandene

    cond do
      neue == [] -> rest
      opts[:anfang] -> neue ++ rest
      is_binary(opts[:vor]) -> setze_utts(rest, neue, opts[:vor], :vor)
      is_binary(opts[:nach]) -> setze_utts(rest, neue, opts[:nach], :nach)
      true -> rest ++ neue
    end
  end

  defp setze_utts(rest, neue, ziel, richtung) do
    if ziel in rest do
      {vorne, hinten} = Enum.split_while(rest, &(&1 != ziel))

      case {richtung, hinten} do
        {:vor, _} -> vorne ++ neue ++ hinten
        {:nach, [z | r]} -> vorne ++ [z] ++ neue ++ r
        {:nach, []} -> vorne ++ neue
      end
    else
      # Ein Ziel ausserhalb des Gliedes ist keine Position darin — angehängt
      # wird trotzdem, damit die Äußerung nicht verloren geht.
      rest ++ neue
    end
  end

  # ─── Innereien ──────────────────────────────────────────────────────

  # Die Kennung ist content-adressiert über die sortierten Utterance-IDs —
  # dasselbe Muster wie `Linie.anker_id/3` und `Parsing.fact_content_id/2`.
  # Zwei Worker, die dasselbe Glied bilden, kommen auf dieselbe Kennung,
  # ohne sich abzustimmen. **Ehrlich:** Ändert sich der Schnitt eines
  # Gliedes, ändert sich seine Kennung — ein Bezug darauf zeigt dann ins
  # Leere und wird zum Befund. Eine über den Schnitt hinweg stabile ID
  # müsste gespeichert werden; solange Glieder innerhalb eines Laufs
  # entstehen, wiegt die Nachvollziehbarkeit schwerer.
  defp kennung(utts) do
    roh = utts |> Enum.sort() |> Enum.join("|")
    "g_" <> (:crypto.hash(:sha, roh) |> Base.encode16(case: :lower) |> String.slice(0, 12))
  end

  # Dieselben Äußerungen dürfen nicht in zwei Gliedern liegen.
  defp loesbinden(kette, utts) do
    menge = MapSet.new(utts)

    glieder =
      kette.glieder
      |> Enum.map(fn g -> %{g | utts: Enum.reject(g.utts, &MapSet.member?(menge, &1))} end)
      |> Enum.reject(&(&1.utts == []))

    %{kette | glieder: glieder}
  end

  defp einsetzen(glieder, glied, opts) do
    cond do
      opts[:anfang] -> {:ok, [glied | glieder]}
      opts[:vor] -> relativ(glieder, glied, :vor, opts[:vor])
      opts[:nach] -> relativ(glieder, glied, :nach, opts[:nach])
      true -> {:ok, glieder ++ [glied]}
    end
  end

  defp relativ(glieder, glied, richtung, ziel) do
    if Enum.any?(glieder, &(&1.id == ziel)),
      do: {:ok, setze_relativ(glieder, glied, richtung, ziel)},
      else: {:fehler, "Das Zielglied #{ziel} gibt es in der Kette nicht."}
  end

  defp setze_relativ(glieder, glied, richtung, ziel) do
    {vorne, hinten} = Enum.split_while(glieder, &(&1.id != ziel))

    case {richtung, hinten} do
      {:vor, _} -> vorne ++ [glied] ++ hinten
      {:nach, [z | r]} -> vorne ++ [z, glied] ++ r
      {:nach, []} -> vorne ++ [glied]
    end
  end

  defp entnehmen(glieder, id) do
    case Enum.find(glieder, &(&1.id == id)) do
      nil -> {nil, glieder}
      g -> {g, Enum.reject(glieder, &(&1.id == id))}
    end
  end
end
