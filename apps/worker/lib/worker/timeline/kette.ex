defmodule Worker.Timeline.Kette do
  @moduledoc """
  #1247: die **Kette** — der Zeitstrahl des Geschehens. Pur, ohne Mnesia und
  ohne Modell.

  ## Zwei Achsen, und das ist der ganze Punkt

  Maintainer, 20.09.2026: „es gibt 2 achsen — 1: die kette: in zeitlicher
  reihenfolge, 2: die sprechlinie: was wann gesprochen wurde. 2 bleibt
  unverändert, 1 wird komplett neu aufgebaut."

  Bis dahin gab es nur eine: `Worker.Timeline.Linie` nahm die
  Sprechreihenfolge und **mutierte** sie mit Verschiebungen. Was gesprochen
  wurde und wann es geschah war dasselbe Ding — für eine Uhrzeit im Spiel
  fällt beides zusammen, für einen Rückblick nicht. Am echten Lauf vom
  20.09.2026 aufgeschlagen: Der Weltbau-Block am Sitzungsanfang erzählt die
  Jahre 2000 bis 2011, die Sitzung spielt 2080; die eine Achse las das als
  Folge und rechnete rückwärts.

  ## Bäume auf dem Zeitstrahl

  Maintainer, 20.09.2026: „es gibt die ebene der kette (der zeitstrahl) — in
  die kette werden glieder eingehängt — jedem glied kann ein oder mehrere
  glieder angehängt werden — ein glied ist ein zusammenhängender context —
  darum kann ein glied auf mehrere utts verweisen und ein glied mehrere
  glieder haben — wie bäume die auf dem zeitstrahl stehen."

      Zeitstrahl:  [ Glied ]──[ Glied ]────────────[ Glied ]
                                  │
                        ┌─────────┴─────────┐
                     [ Glied ]          [ Glied ]

  Ein Glied ist ein **zusammenhängender Kontext**: eine Szene, ein Auftrag,
  ein Abend. Es trägt die Äußerungen, die unmittelbar dazugehören, **und**
  kann feinere Kontexte als Unterglieder enthalten — „der Überfall" mit „der
  Hinterhalt" und „die Flucht" darin.

  **Ein Glied hängt entweder am Zeitstrahl oder an einem Glied** (Maintainer)
  — nie an beidem. Daraus folgt die Regel beim Versetzen: Es bewegt sich
  unter seinen Geschwistern, nicht aus seinem Kontext heraus. Wer eine Szene
  aus ihrem Zusammenhang lösen will, nimmt sie heraus und hängt sie neu ein;
  das ist eine bewusste Handlung, kein Nebeneffekt einer Verschiebung.

  **Jedes Glied hat eine eigene Kennung, auf jeder Tiefe** (Maintainer:
  „jedes element in der kette ist ein glied — egal in welcher tiefe — jedes
  glied hat eine uuid"). Sie wird beim Anlegen vergeben und **überlebt jede
  Änderung**: Wächst eine Szene um eine Zeile, bleibt sie dieselbe Szene.

  Eine content-adressierte Kennung (Muster `Linie.anker_id/3`) wäre hier
  falsch — sie änderte sich mit dem Schnitt, und jeder Bezug auf das Glied
  zeigte danach ins Leere; genau das passiert bei `erweitern/4`, also im
  Normalfall „ach, das fing schon früher an". **Der Preis ist benannt:** Eine
  zufällige ID konvergiert nicht; zwei Worker, die dasselbe Glied bilden,
  vergeben verschiedene. Das ist hinnehmbar, weil ein Glied in EINEM Lauf
  entsteht und dieser Lauf sein Autor ist — die Anker daneben bleiben
  content-adressiert und konvergieren weiterhin.

  **Gefunden wird ein Glied über seine Äußerungen** (Maintainer: „jeder bezug
  in der anwendung sollte auf eine utt zurückführen"): `glied_von/2` sucht
  durch den ganzen Baum. Die Kennung ist die Identität, die Utterance der Weg
  dorthin — und sie ist die einzige Adresse, die ein Re-Smoothing überlebt.

  ## Die Kette beginnt leer — die Kampagne nur EINMAL

  Maintainer: „Default beim Start: Kette ist leer — jack soll bewusst
  einsortieren." Es gibt keine stillschweigende Übernahme der
  Sprechreihenfolge. Jede Äußerung braucht eine Entscheidung: in ein Glied,
  oder ausdrücklich hinaus (Tischgespräch). Was niemand entschieden hat, ist
  **offen** — und `fertig()` fragt danach.

  **Das gilt für die Äußerungen, nicht für die Kette** (Maintainer,
  25.09.2026: „die kette ist ja persistent — jeder weitere lauf soll diese
  kette ergänzen"). Ein Lauf startet mit der bestehenden Kette der **ganzen
  Kampagne** (`Worker.Jack.Zeit.Eingabe`), nicht mit einer leeren: Er hängt
  seine Zeilen zwischen die vorhandenen Glieder und darf sie erweitern oder
  versetzen. `Kette.neu/0` ist der Anfang einer Kampagne, nicht der Anfang
  eines Laufs.

  Vorher begann jeder Lauf leer, und weil `Kettenspeicher` gegen den Bestand
  vergleicht, bekam alles Bestehende beim **ersten Werkzeugaufruf** einen
  Grabstein: Ein Regenerate löschte die Kette der Sitzung, statt sie zu
  ergänzen. Über Sitzungsgrenzen gab es zudem gar keine Ordnung — ein Lauf sah
  die Glieder der anderen Sitzungen nicht.

  Der Unterschied ist keine Förmlichkeit. Mit einem Default hiesse „nicht
  angefasst" zweierlei zugleich: „die Reihenfolge stimmt hier" und „ich bin
  noch nicht hingekommen".

  ## Die Operationen

      anhaengen(kette, utts, opts)       ein Glied AUF den Zeitstrahl
      unterhaengen(kette, id, utts, o)   ein Glied AN ein Glied
      erweitern(kette, id, utts, opts)   ein Glied bekommt mehr Äußerungen
      versetzen(kette, id, wohin)        auf seiner Ebene: vor/nach/anfang
      loeschen(kette, id)                das Glied samt Unterbäumen heraus
      draussen(kette, utts, grund)       Äußerungen, die nie hineingehören

  Alle halten den Zeitstrahl **durchgehend** (Maintainer: „so dass es weiter
  eine durchgehende kette ist"): Wer ein Glied herausnimmt, schliesst die
  Lücke; wer es woanders einsetzt, hinterlässt keine. Und jede eingereihte
  Äußerung steht **genau einmal** im ganzen Baum — das prüft
  `kette_test.exs` nach jeder Operation als MENGE, nicht als Länge.
  """

  @typedoc """
  Die Kennung eines Gliedes — eine UUID, vergeben beim Anlegen, **stabil über
  jede Änderung** und eindeutig auf jeder Tiefe.
  """
  @type glied_id :: String.t()

  @typedoc """
  Ein Glied: ein zusammenhängender Kontext.

    * `utts` — die Äußerungen, die unmittelbar dazugehören
    * `kinder` — feinere Kontexte darin, selbst wieder Glieder
    * `grund` — wie Jack die Szene genannt hat

  **Die Reihenfolge innerhalb eines Gliedes ist: erst die eigenen
  Äußerungen, dann die Unterglieder.** Das ist eine Festlegung, keine
  Ableitung — ohne sie wäre die Folge der Blätter nicht bestimmt. Wer eine
  andere Ordnung braucht, bildet Unterglieder.
  """
  @type glied :: %{
          id: glied_id(),
          utts: [String.t()],
          kinder: [glied()],
          grund: String.t() | nil
        }

  @typedoc "Der Zeitstrahl: Glieder in zeitlicher Reihenfolge, plus die, die draussen sind."
  @type t :: %{
          glieder: [glied()],
          draussen: %{String.t() => String.t()}
        }

  @doc """
  Die Äußerungen dieser Liste, die noch in **keinem** Glied liegen.

  Wer einen Anker setzt, braucht ein Kettenglied darunter (#1247) — und diese
  Frage stellen zwei Aufrufer (`Anker`, `Vorbehalte`), seit der Schnitt sie
  getrennt hat. Sie gehört hierher: Es ist eine Frage an die Kette, keine an
  den Anker.
  """
  @spec offene(t(), [String.t()]) :: [String.t()]
  def offene(%{} = kette, ids) when is_list(ids),
    do: Enum.reject(ids, &glied_von(kette, &1))

  @doc "Ein leerer Zeitstrahl."
  @spec neu() :: t()
  def neu, do: %{glieder: [], draussen: %{}}

  # ─── Anlegen ────────────────────────────────────────────────────────

  @doc """
  Hängt ein neues Glied **auf den Zeitstrahl**.

  Optionen: `:vor` / `:nach` (eine `glied_id` auf derselben Ebene),
  `:anfang`, `:grund`. Ohne Angabe hinten an.

  **Eine Äußerung liegt in höchstens einem Glied** — im ganzen Baum. Wer sie
  erneut einreiht, nimmt sie aus dem alten heraus; wird das dadurch leer
  (keine Äußerungen, keine Kinder), fällt es weg.
  """
  @spec anhaengen(t(), [String.t()], keyword()) :: {:ok, t(), glied()} | {:fehler, String.t()}
  def anhaengen(kette, utts, opts \\ [])

  def anhaengen(_kette, [], _opts), do: {:fehler, leer_text()}

  def anhaengen(%{} = kette, utts, opts) when is_list(utts) do
    utts = Enum.uniq(utts)
    kette = loesbinden(kette, utts)
    glied = %{id: kennung(), utts: utts, kinder: [], grund: opts[:grund]}

    case einsetzen(kette.glieder, glied, opts) do
      {:ok, glieder} ->
        {:ok, %{kette | glieder: glieder, draussen: Map.drop(kette.draussen, utts)}, glied}

      {:fehler, _} = f ->
        f
    end
  end

  @doc """
  Hängt ein neues Glied **an ein bestehendes** — als Unterglied.

  Das ist der Baum: „Der Überfall" bekommt „Der Hinterhalt" und „Die Flucht".
  Das Elternglied bleibt, wo es ist; das neue steht darin, hinten oder an
  einer Stelle seiner Geschwister (`:vor` / `:nach` / `:anfang`).
  """
  @spec unterhaengen(t(), glied_id(), [String.t()], keyword()) ::
          {:ok, t(), glied()} | {:fehler, String.t()}
  def unterhaengen(kette, eltern_id, utts, opts \\ [])

  def unterhaengen(_kette, _eltern_id, [], _opts), do: {:fehler, leer_text()}

  def unterhaengen(%{} = kette, eltern_id, utts, opts) when is_list(utts) do
    if glied(kette, eltern_id) do
      utts = Enum.uniq(utts)
      kette = loesbinden(kette, utts)
      neues = %{id: kennung(), utts: utts, kinder: [], grund: opts[:grund]}

      ergebnis =
        aendern(kette, eltern_id, fn e ->
          case einsetzen(e.kinder, neues, opts) do
            {:ok, kinder} -> {:ok, %{e | kinder: kinder}}
            f -> f
          end
        end)

      case ergebnis do
        {:ok, kette} -> {:ok, %{kette | draussen: Map.drop(kette.draussen, utts)}, neues}
        f -> f
      end
    else
      {:fehler, kein_glied(eltern_id)}
    end
  end

  @doc """
  Gibt einem bestehenden Glied mehr Äußerungen — es bleibt, wo es ist, und
  **behält seine Kennung**.

  Das ist etwas anderes als `anhaengen/3`: Dort entsteht ein NEUES Glied und
  landet an der gewünschten Stelle; hier wächst eine Szene, die schon da ist.

  `:vor` / `:nach` nennen hier eine **Äußerung des Gliedes** — die eigenen
  Äußerungen sind selbst eine geordnete Folge.
  """
  @spec erweitern(t(), glied_id(), [String.t()], keyword()) ::
          {:ok, t(), glied()} | {:fehler, String.t()}
  def erweitern(kette, glied_id, utts, opts \\ [])

  def erweitern(%{} = kette, glied_id, utts, opts) when is_list(utts) do
    case glied(kette, glied_id) do
      nil ->
        {:fehler, kein_glied(glied_id)}

      alt ->
        # Erst die Fremdbindungen lösen, DANN das Zielglied neu setzen —
        # sonst nimmt `loesbinden/2` ihm seine eigenen Äußerungen.
        kette = loesbinden(kette, utts -- alt.utts)

        {:ok, kette} =
          aendern(kette, glied_id, fn g -> {:ok, %{g | utts: im_glied(g.utts, utts, opts)}} end)

        {:ok, %{kette | draussen: Map.drop(kette.draussen, utts)}, glied(kette, glied_id)}
    end
  end

  # ─── Bewegen und entfernen ──────────────────────────────────────────

  @doc """
  Versetzt ein Glied **auf seiner Ebene**: `{:vor, id}`, `{:nach, id}` oder
  `:anfang`.

  **Beide Richtungen, ausdrücklich** (Maintainer, 20.09.2026: „verschiebe
  uuid a hinter uuid b — aber es muss auch geben verschiebe uuid a vor uuid
  b"). Ein Rückblick gehört vor etwas, eine Ankündigung dahinter; mit nur
  einer Richtung müsste man die andere über den Nachbarn ausdrücken, und wer
  den Nachbarn später versetzt, verliert die Aussage.

  Ein Unterglied bewegt sich unter seinen Geschwistern, ein Wurzelglied auf
  dem Zeitstrahl. Ein Ziel auf einer anderen Ebene wird abgelehnt: Ein Glied
  hängt entweder am Zeitstrahl oder an einem Glied, und aus seinem Kontext
  gelöst wird es nur durch eine bewusste Handlung.
  """
  @spec versetzen(t(), glied_id(), {:vor | :nach, glied_id()} | :anfang) ::
          {:ok, t()} | {:fehler, String.t()}
  def versetzen(%{} = kette, glied_id, wohin) do
    with {:ok, eltern} <- eltern_von(kette, glied_id),
         {:ok, ziel} <- versetz_ziel(wohin, glied_id) do
      in_liste(kette, eltern, fn liste ->
        {g, rest} = entnehmen(liste, glied_id)

        cond do
          is_nil(g) -> {:fehler, kein_glied(glied_id)}
          ziel == :anfang -> {:ok, [g | rest]}
          not Enum.any?(rest, &(&1.id == elem(ziel, 1))) -> {:fehler, ziel_fehlt(elem(ziel, 1))}
          true -> {:ok, setze_relativ(rest, g, elem(ziel, 0), elem(ziel, 1))}
        end
      end)
    end
  end

  @doc """
  Nimmt ein Glied **samt seinen Untergliedern** aus der Kette. Alle
  betroffenen Äußerungen sind danach **offen** — nicht draussen:
  Herausnehmen ist kein Urteil über den Inhalt, sondern die Rücknahme einer
  Einreihung.
  """
  @spec loeschen(t(), glied_id()) :: {:ok, t()} | {:fehler, String.t()}
  def loeschen(%{} = kette, glied_id) do
    with {:ok, eltern} <- eltern_von(kette, glied_id) do
      in_liste(kette, eltern, fn liste ->
        case entnehmen(liste, glied_id) do
          {nil, _} -> {:fehler, kein_glied(glied_id)}
          {_, rest} -> {:ok, rest}
        end
      end)
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

  # ─── Lesen ──────────────────────────────────────────────────────────

  @doc """
  Die Äußerungen, über die noch niemand entschieden hat — weder in einem
  Glied noch draussen. **Das ist die Schranke des Einsortier-Laufs.**
  """
  @spec offen(t(), [String.t()]) :: [String.t()]
  def offen(%{} = kette, alle_utts) when is_list(alle_utts) do
    drin = eingereiht(kette)
    Enum.reject(alle_utts, &(MapSet.member?(drin, &1) or Map.has_key?(kette.draussen, &1)))
  end

  @doc "Alle Äußerungen, die irgendwo im Baum liegen."
  @spec eingereiht(t()) :: MapSet.t()
  def eingereiht(%{glieder: g}), do: g |> Enum.flat_map(&alle_utts/1) |> MapSet.new()

  @doc """
  Das Glied, in dem eine Äußerung **unmittelbar** liegt — auf jeder Tiefe.
  Der Weg von der Utterance zur Identität.
  """
  @spec glied_von(t(), String.t()) :: glied() | nil
  def glied_von(%{glieder: g}, utterance_id), do: suche(g, &(utterance_id in &1.utts))

  @doc "Ein Glied nach seiner Kennung, auf jeder Tiefe."
  @spec glied(t(), glied_id()) :: glied() | nil
  def glied(%{glieder: g}, id), do: suche(g, &(&1.id == id))

  @doc """
  Die Äußerungen des Zeitstrahls in ihrer zeitlichen Reihenfolge — Glied für
  Glied, darin erst die eigenen Äußerungen, dann die Unterglieder.
  """
  @spec reihenfolge(t()) :: [String.t()]
  def reihenfolge(%{glieder: g}), do: Enum.flat_map(g, &alle_utts/1)

  @doc "Alle Äußerungen eines Gliedes samt seiner Unterglieder, in Reihenfolge."
  @spec alle_utts(glied()) :: [String.t()]
  def alle_utts(%{utts: u, kinder: k}), do: u ++ Enum.flat_map(k, &alle_utts/1)

  @doc """
  Die Zahl der Glieder im **ganzen Baum**, nicht nur der Wurzeln. Wer nur die
  oberste Ebene zählt, meldet eine Kette als klein, die tief ist.
  """
  @spec anzahl(t()) :: non_neg_integer()
  def anzahl(%{glieder: g}), do: zaehle(g)

  defp zaehle(glieder), do: Enum.reduce(glieder, 0, fn g, n -> n + 1 + zaehle(g.kinder) end)

  @doc """
  Der Baum flach, für die Anzeige: ein Eintrag `{glied, tiefe}` je Glied, in
  Vorordnung — so, wie er gelesen wird.
  """
  @spec flach(t()) :: [{glied(), non_neg_integer()}]
  def flach(%{glieder: g}), do: flach_liste(g, 0)

  defp flach_liste(glieder, tiefe),
    do: Enum.flat_map(glieder, fn g -> [{g, tiefe} | flach_liste(g.kinder, tiefe + 1)] end)

  # ─── Innereien ──────────────────────────────────────────────────────

  defp kennung, do: "g_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))

  defp leer_text, do: "Ein Glied ohne Äußerung trägt nichts — nenn mindestens eine Zeile."

  defp kein_glied(id), do: "Das Glied #{id} gibt es in der Kette nicht."

  defp ziel_fehlt(ziel),
    do:
      "Das Zielglied #{ziel} liegt nicht auf derselben Ebene — ein Glied bewegt " <>
        "sich unter seinen Geschwistern, nicht aus seinem Kontext heraus."

  defp suche(glieder, pruef) do
    Enum.find_value(glieder, fn g ->
      if pruef.(g), do: g, else: suche(g.kinder, pruef)
    end)
  end

  # Die Eltern-Kennung eines Gliedes, `nil` für ein Wurzelglied.
  defp eltern_von(kette, glied_id) do
    if glied(kette, glied_id),
      do: {:ok, finde_eltern(kette.glieder, glied_id, nil)},
      else: {:fehler, kein_glied(glied_id)}
  end

  defp finde_eltern(glieder, id, eltern) do
    Enum.find_value(glieder, fn g ->
      if g.id == id, do: {:gefunden, eltern}, else: finde_eltern(g.kinder, id, g.id)
    end)
    |> case do
      {:gefunden, e} -> e
      andere -> andere
    end
  end

  # Wendet `fun` auf die Geschwisterliste an, in der das Glied liegt.
  defp in_liste(kette, nil, fun) do
    case fun.(kette.glieder) do
      {:ok, liste} -> {:ok, %{kette | glieder: liste}}
      f -> f
    end
  end

  defp in_liste(kette, eltern_id, fun) do
    aendern(kette, eltern_id, fn e ->
      case fun.(e.kinder) do
        {:ok, kinder} -> {:ok, %{e | kinder: kinder}}
        f -> f
      end
    end)
  end

  # Ändert genau ein Glied im Baum über seine Kennung.
  defp aendern(kette, glied_id, fun) do
    case aendern_liste(kette.glieder, glied_id, fun) do
      {:ok, glieder} -> {:ok, %{kette | glieder: glieder}}
      f -> f
    end
  end

  defp aendern_liste(glieder, id, fun) do
    Enum.reduce(glieder, {:ok, []}, fn
      _g, {:fehler, _} = f ->
        f

      g, {:ok, acc} ->
        cond do
          g.id == id ->
            case fun.(g) do
              {:ok, neu} -> {:ok, acc ++ [neu]}
              f -> f
            end

          true ->
            case aendern_liste(g.kinder, id, fun) do
              {:ok, kinder} -> {:ok, acc ++ [%{g | kinder: kinder}]}
              f -> f
            end
        end
    end)
  end

  defp versetz_ziel(:anfang, _), do: {:ok, :anfang}

  defp versetz_ziel({r, ziel}, glied_id) when r in [:vor, :nach] do
    if ziel == glied_id,
      do: {:fehler, "Ein Glied kann nicht vor oder hinter sich selbst stehen."},
      else: {:ok, {r, ziel}}
  end

  defp versetz_ziel(_, _),
    do: {:fehler, "Sag wohin: vor ein Glied, nach ein Glied, oder an den Anfang."}

  # Dieselben Äußerungen dürfen nicht an zwei Stellen des Baums liegen.
  defp loesbinden(kette, utts) do
    menge = MapSet.new(utts)
    %{kette | glieder: loesbinden_liste(kette.glieder, menge)}
  end

  defp loesbinden_liste(glieder, menge) do
    glieder
    |> Enum.map(fn g ->
      %{
        g
        | utts: Enum.reject(g.utts, &MapSet.member?(menge, &1)),
          kinder: loesbinden_liste(g.kinder, menge)
      }
    end)
    |> Enum.reject(&(&1.utts == [] and &1.kinder == []))
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
      else: {:fehler, ziel_fehlt(ziel)}
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

  # Die eigenen Äußerungen eines Gliedes sind selbst eine geordnete Folge —
  # `vor`/`nach` nennen hier eine Äußerung, nicht ein Glied.
  defp im_glied(vorhandene, neue, opts) do
    neue = Enum.uniq(neue) -- vorhandene

    cond do
      neue == [] -> vorhandene
      opts[:anfang] -> neue ++ vorhandene
      is_binary(opts[:vor]) -> setze_utts(vorhandene, neue, opts[:vor], :vor)
      is_binary(opts[:nach]) -> setze_utts(vorhandene, neue, opts[:nach], :nach)
      true -> vorhandene ++ neue
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

  # ─── Zeilen: die Kette als Tabelle ──────────────────────────────────

  @doc """
  Die Kette als **flache Zeilen**, eine je Glied und eine je gelöster
  Äußerung — die Form, in der sie gespeichert wird.

  ## Der Platz steht als Bezug auf die Nachbar-Kennung

  Maintainer, 20.09.2026: `vorher` ist die Kennung des linken Geschwisters
  (`nil` für das erste), `eltern` die des Gliedes, an dem es hängt (`nil`
  für ein Wurzelglied auf dem Zeitstrahl). Mehr braucht es nicht: Daraus
  ist der ganze Baum eindeutig wiederherstellbar.

  **Der Preis ist benannt** (die Alternative wäre ein Bezug auf eine
  Äußerung des Nachbarn gewesen): Eine Kennung konvergiert nicht, und wer
  ein Glied entfernt, muss die Zeile seines rechten Nachbarn nachziehen —
  sonst zeigt sie auf etwas, das es nicht mehr gibt. `aus_zeilen/1` ist
  deshalb **nachsichtig**: Ein gerissener Bezug hängt das Glied hinten an,
  statt es zu verlieren, und meldet das als Befund.

  Eine gelöste Äußerung bekommt ihre eigene Zeile mit `art: "draussen"` und
  der **Utterance-ID als Kennung** — sie ist eindeutig, stabil, und
  kollidiert nicht mit den `g_`-Kennungen der Glieder. Ohne sie wäre die
  gespeicherte Kette unvollständig: „gehört nicht hinein" ist eine
  Entscheidung wie jede andere und darf nicht zu „noch nicht angefasst"
  verfallen.
  """
  @spec zu_zeilen(t()) :: [map()]
  def zu_zeilen(%{glieder: glieder, draussen: draussen}) do
    glied_zeilen(glieder, nil) ++
      for {utt, grund} <- Enum.sort(draussen) do
        %{"glied_id" => utt, "art" => "draussen", "grund" => grund}
      end
  end

  defp glied_zeilen(geschwister, eltern_id) do
    geschwister
    |> Enum.reduce({[], nil}, fn g, {acc, vorher} ->
      zeile = %{
        "glied_id" => g.id,
        "art" => "glied",
        "utts" => g.utts,
        "vorher" => vorher,
        "eltern" => eltern_id,
        "grund" => g.grund
      }

      {acc ++ [zeile] ++ glied_zeilen(g.kinder, g.id), g.id}
    end)
    |> elem(0)
  end

  @doc """
  Die Kette aus ihren Zeilen — die Umkehrung von `zu_zeilen/1`.

  Liefert `{kette, befunde}`. Die Befunde nennen, was nicht aufging:
  ein `vorher`, das es nicht gibt, ein `eltern`, das es nicht gibt, oder
  ein Ring von `vorher`-Bezügen. **Nichts wird dabei verworfen** — ein
  Glied, dessen Platz unklar ist, landet hinten statt im Nichts
  (flag-not-drop, wie überall in diesem Repo).
  """
  @spec aus_zeilen([map()]) :: {t(), [String.t()]}
  def aus_zeilen(zeilen) when is_list(zeilen) do
    {draussen_zeilen, glied_zeilen} =
      Enum.split_with(zeilen, &(&1["art"] == "draussen"))

    bekannt = MapSet.new(glied_zeilen, & &1["glied_id"])
    {nach_eltern, waisen} = nach_eltern(glied_zeilen, bekannt)

    {glieder, befunde} = baum(nil, nach_eltern)

    draussen = Map.new(draussen_zeilen, &{&1["glied_id"], &1["grund"]})

    {%{glieder: glieder, draussen: draussen}, waisen ++ befunde}
  end

  # Ein `eltern`, das es nicht gibt, macht das Glied zur Wurzel — sonst
  # verschwände sein ganzer Unterbaum mit ihm.
  defp nach_eltern(zeilen, bekannt) do
    Enum.map_reduce(zeilen, [], fn z, befunde ->
      e = z["eltern"]

      if is_nil(e) or MapSet.member?(bekannt, e) do
        {z, befunde}
      else
        {Map.put(z, "eltern", nil),
         befunde ++
           [
             "Glied #{z["glied_id"]} hing an #{e}, das es nicht gibt — steht jetzt auf dem Zeitstrahl."
           ]}
      end
    end)
    |> then(fn {zeilen, befunde} -> {Enum.group_by(zeilen, & &1["eltern"]), befunde} end)
  end

  defp baum(eltern_id, nach_eltern) do
    zeilen = Map.get(nach_eltern, eltern_id, [])
    {geordnet, befunde} = ordnen(zeilen)

    Enum.map_reduce(geordnet, befunde, fn z, acc ->
      {kinder, kind_befunde} = baum(z["glied_id"], nach_eltern)

      glied = %{
        id: z["glied_id"],
        utts: z["utts"] || [],
        kinder: kinder,
        grund: z["grund"]
      }

      {glied, acc ++ kind_befunde}
    end)
  end

  # Aus den `vorher`-Bezügen eine Reihe: erst das Glied ohne Vorgänger, dann
  # jeweils das, dessen `vorher` darauf zeigt. Was übrig bleibt, hängt an
  # einem Ring oder an einem Bezug aus einer fremden Ebene; es kommt hinten
  # dran und wird gemeldet.
  defp ordnen([]), do: {[], []}

  defp ordnen(zeilen) do
    nachfolger = Map.new(zeilen, &{&1["vorher"], &1})
    start = Enum.filter(zeilen, &is_nil(&1["vorher"]))

    {kette, gesehen} = folgen(List.first(start), nachfolger, [], %{})
    rest = Enum.reject(zeilen, &Map.has_key?(gesehen, &1["glied_id"]))

    befunde =
      cond do
        length(start) > 1 ->
          [
            "#{length(start)} Glieder ohne Vorgänger auf derselben Ebene — die Reihenfolge ist dort nicht eindeutig."
          ]

        rest != [] ->
          [
            "#{length(rest)} Glied(er) hängen an einem Bezug, der nicht aufgeht — sie stehen am Ende ihrer Ebene."
          ]

        true ->
          []
      end

    {kette ++ rest, befunde}
  end

  # `gesehen` ist eine Map statt eines MapSet: Der Dialyzer sieht in der
  # `nil`-Klausel nur einen durchgereichten Wert und meldet die Opazität des
  # MapSet — eine Map ist hier ebenso schnell und braucht keine Ausnahme.
  @spec folgen(map() | nil, map(), [map()], map()) :: {[map()], map()}
  defp folgen(nil, _nachfolger, acc, gesehen), do: {acc, gesehen}

  defp folgen(zeile, nachfolger, acc, gesehen) do
    id = zeile["glied_id"]

    if Map.has_key?(gesehen, id) do
      {acc, gesehen}
    else
      folgen(nachfolger[id], nachfolger, acc ++ [zeile], Map.put(gesehen, id, true))
    end
  end
end
