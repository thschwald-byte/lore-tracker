defmodule Worker.Jack.Zeit.Setzen do
  @moduledoc """
  #1247 (Z2): was beim Setzen eines Ankers passiert — **pur**. Kein Mnesia,
  kein Modell, kein Prozess: Bestand und Wunsch hinein, Entscheidung heraus.

  ## Drei Fälle, und nur der dritte ist hart

  Die Regel stammt vom Maintainer (19.09.2026) und ist die Mitte dieses
  Tickets:

      1. Die Stelle ist frei          → gesetzt, fertig. Der Normalfall.
      2. Dort hängt schon ein Anker   → WARNEN, nichts eintragen. Die Antwort
         (maschinell)                    legt den bestehenden mit einer GUID
                                         vor; Jack entscheidet im nächsten
                                         Aufruf: `dazu` oder `ersetzen`.
      3. Dort hängt etwas ABGESEGNETES → der Anker wird verworfen. Die Antwort
                                         nennt die Festlegung und die zwei
                                         Wege: Konflikt eintragen oder anders
                                         einordnen.

  **„Es darf an einem utt mehrere Anker geben"** — der zweite Fall ist also
  keine Ablehnung, sondern eine Rückfrage. Eine Utterance, die eine Dauer und
  den daraus folgenden Zeitpunkt in einem Satz nennt, trägt zu Recht beide
  („also ist jetzt so grob eine Stunde vergangen, dann wird es jetzt so kurz
  nach zwölf sein" — seattleV5 S3, Block 1106, eine einzige Utterance).

  **Warum überhaupt gewarnt wird, wenn beides nebeneinander darf:** Weil das
  Modell den Bestand nicht sieht, solange es nicht kollidiert (dieselbe
  Zurückhaltung wie beim Verifikationstor, `Worker.Jack.Tor`). Ohne die
  Rückfrage trüge es denselben Anker in leicht anderer Formulierung ein
  zweites Mal ein und merkte es nie.

  ## Was „dieselbe Stelle" heißt

  **Überlappung der Utterances UND dieselbe Art.** Beide reinen Formen sind
  unbrauchbar: Mengengleichheit fängt den Doppeleintrag nicht (derselbe Anker
  in leicht anderer Formulierung hat meist auch eine leicht andere Menge),
  reine Überlappung fragt in dicht annotierter Gegend bei fast jedem Anker
  zurück. Die Art trennt sauber: Spanne und Zeitpunkt an derselben Utterance
  ergänzen sich, zwei Zeitpunkte widersprechen sich potenziell. Die Regel
  steht in `Stand.an/3`.

  ## Die GUID gilt genau einmal — und wird geprüft

  Sie ist an die Stelle gebunden, die sie ausgelöst hat, und verfällt, wenn
  der nächste Aufruf sie nicht nennt (`Worker.Jack.Tor`-Muster).
  `pruefe_kennung/3` setzt das durch und unterscheidet dabei drei Fälle, die
  Jack verschieden behandeln muss: nie ausgegeben (Modellfehler), abgelaufen
  (normaler Ablauf), falsche Stelle (Denkfehler).

  Der erste Wurf verwarf die Kennung und setzte einfach — die Zusage stand
  nur hier im Text. **Eine ungeprüfte Kennung ist schlechter als gar keine**,
  weil der Moduldoc Sicherheit zusagt, die es nicht gibt (Review, 19.09.2026).

  ## Was hier NICHT entschieden wird

  Welcher von zwei Ankern an einer Stelle **gilt** — das rechnet
  `Worker.Timeline.Linie` beim Lesen (erst abgesegnet, dann früher). Hier geht
  es nur darum, was überhaupt eingetragen wird.
  """

  alias Worker.Jack.Zeit.Stand
  alias Worker.Timeline.Linie

  @typedoc "Ein Anker, wie Jack ihn setzen will."
  @type wunsch :: %{
          required(:utterance_ids) => [String.t()],
          required(:art) => atom(),
          required(:wert) => String.t(),
          required(:welt) => String.t(),
          required(:beleg) => String.t(),
          optional(:halbtag) => String.t(),
          optional(:tageswechsel) => boolean(),
          optional(:zweifel) => String.t()
        }

  @typedoc """
  Die Entscheidung. `:gesetzt` trägt den fertigen Anker samt Adresse;
  `:rueckfrage` und `:verworfen` tragen den Text für das Modell.
  """
  @type ergebnis ::
          {:gesetzt, map()}
          | {:rueckfrage, %{guid: String.t(), bestand: [map()], text: String.t()}}
          | {:verworfen, %{text: String.t()}}

  @doc """
  Entscheidet über einen Wunsch — **mit dem Stand**, weil nur er weiß, was an
  der Stelle hängt und welche Kennung dafür offen ist.

  `entscheidung` ist `nil` beim ersten Aufruf, sonst `{:dazu, guid}` oder
  `{:ersetzen, guid}`. Die Kennung wird **geprüft**, nicht geglaubt (s.u.).
  """
  @spec entscheiden(Stand.t(), wunsch(), {atom(), String.t()} | nil, (-> String.t())) ::
          ergebnis()
  def entscheiden(stand, wunsch, entscheidung \\ nil, guid_gibt \\ &guid/0)

  def entscheiden(%Stand{} = stand, wunsch, nil, guid_gibt) do
    bestand = Stand.an(stand, wunsch.utterance_ids, art: wunsch.art)

    cond do
      abgesegnete = Enum.find(bestand, &abgesegnet?/1) ->
        {:verworfen, %{text: verworfen_text(abgesegnete)}}

      bestand == [] ->
        {:gesetzt, bauen(wunsch)}

      true ->
        guid = guid_gibt.()
        {:rueckfrage, %{guid: guid, bestand: bestand, text: rueckfrage_text(bestand, guid)}}
    end
  end

  def entscheiden(%Stand{} = stand, wunsch, {art, guid}, _guid_gibt)
      when art in [:dazu, :ersetzen] do
    bestand = Stand.an(stand, wunsch.utterance_ids, art: wunsch.art)

    cond do
      # Die Absegnung gilt auch mit Entscheidung — sonst wäre die Kennung ein
      # Weg an der Kuration vorbei.
      a = Enum.find(bestand, &abgesegnet?/1) ->
        {:verworfen, %{text: verworfen_text(a)}}

      # **Die Kennung wird geprüft, nicht geglaubt.** Der erste Wurf verwarf
      # sie (`_guid`) und setzte einfach — die Zusage „an die Stelle gebunden"
      # stand nur im Moduldoc, und eine ungeprüfte Kennung ist schlechter als
      # gar keine: Beim nächsten Lesen hält man die Stelle für abgesichert.
      # Durchspielbar war: Rückfrage zu Stelle A mit g1, Antwort {:ersetzen,
      # g1}, Wunsch auf Stelle B — gesetzt wurde bei B. (Review, 19.09.2026.)
      nicht = pruefe_kennung(stand, wunsch, guid) ->
        {:verworfen, %{text: nicht}}

      true ->
        {:gesetzt, bauen(wunsch)}
    end
  end

  @doc """
  Warum eine Kennung nicht gilt — oder `nil`, wenn sie gilt.

  Drei Fälle, und sie müssen **unterscheidbar** bleiben: „nie ausgegeben" ist
  ein Modellfehler, „abgelaufen" normaler Ablauf, „falsche Stelle" ein
  Denkfehler. Eine Antwort, die alle drei gleich behandelt, schickt Jack in
  die Wiederholung, statt ihm zu sagen, was er anders machen soll.
  """
  @spec pruefe_kennung(Stand.t(), wunsch(), String.t()) :: String.t() | nil
  def pruefe_kennung(%Stand{} = stand, wunsch, guid) do
    offen = Map.get(stand.offene, guid)

    case {offen, Stand.schicksal(stand, guid)} do
      {nil, nil} ->
        "Die Kennung „#{guid}“ gibt es nicht — sie wurde nie ausgegeben. " <>
          "Setz den Anker ohne Entscheidung; wenn dort etwas hängt, bekommst du " <>
          "eine frische."

      {nil, :eingeloest} ->
        "Die Kennung „#{guid}“ ist schon eingelöst. Jede gilt genau einmal."

      {nil, :offen} ->
        "Die Kennung „#{guid}“ ist verfallen — sie gilt nur für den nächsten " <>
          "Aufruf. Setz den Anker noch einmal ohne Entscheidung."

      {%{utterance_ids: ids}, _} ->
        wenn_andere_stelle(ids, wunsch.utterance_ids, guid)

      _ ->
        nil
    end
  end

  defp wenn_andere_stelle(ids, gewuenscht, guid) do
    if MapSet.new(ids) == MapSet.new(gewuenscht) do
      nil
    else
      "Die Kennung „#{guid}“ gehört zu einer anderen Stelle. Eine Entscheidung " <>
        "gilt nur dort, wo die Rückfrage entstanden ist — sonst könnte sie " <>
        "versehentlich einen fremden Anker treffen."
    end
  end

  defp guid, do: "z" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

  @doc """
  Der Anker, der aus einem Wunsch entsteht — mit seiner content-adressierten
  Kennung (`Linie.anker_id/3`).
  """
  @spec bauen(wunsch()) :: map()
  def bauen(w) do
    ids = w.utterance_ids |> Enum.uniq() |> Enum.sort()

    %{
      anker_id: Linie.anker_id(ids, w.art, w.wert),
      utterance_ids: ids,
      art: w.art,
      wert: w.wert,
      welt: w.welt,
      beleg: w.beleg,
      # Der Halbtag ist eine Angabe ÜBER den Ausdruck, kein Teil von ihm —
      # deshalb geht er nicht in die Adresse ein (`Linie.anker_id/3` hasht
      # utterance_ids, art und wert). Derselbe Ausdruck an derselben Stelle
      # bleibt derselbe Anker, ob Jack den Halbtag nun dazusagt oder nicht.
      halbtag: Map.get(w, :halbtag, ""),
      # **Der Tageswechsel ist Jacks Urteil, kein Parser-Treffer** (#1247):
      # „Es vergeht eine Nacht" heisst „wir sind am Tag danach", und ob ein
      # Satz das meint, entscheidet er am Sinn. Ein Muster dafür wäre die
      # #1109-Klasse — sechs Regexe dafür waren geschrieben und sind
      # zurückgenommen worden, bevor sie liefen.
      tageswechsel: Map.get(w, :tageswechsel, false),
      zweifel: Map.get(w, :zweifel, ""),
      quelle: "jack",
      abgesegnet_von: "",
      abgesegnet_am: ""
    }
  end

  @doc """
  Der Anker, den eine Rücknahme schreibt: **dieselbe Adresse**, Art `geloest`.
  **Nie ein Delete** — ein vertauschtes Setzen/Zurücknehmen divergierte sonst
  zwischen zwei Workern (#698-Klasse).

  **Damit bricht die Content-Adressierung, und zwar mit Absicht.** Die Art
  geht in `Linie.anker_id/3` ein; für diese Row liefert die Funktion also ein
  anderes Ergebnis als die gespeicherte Kennung. Das ist der Preis dafür, dass
  die Rücknahme dieselbe Zeile trifft statt eine zweite anzulegen — wer die
  Kennung beim Lösen „korrekt" neu berechnet, erzeugt genau diese zweite Row,
  und die alte bliebe für immer gesetzt. (Benannt im Review, 19.09.2026.)
  """
  @spec loesen(map(), String.t()) :: map()
  def loesen(anker, grund) do
    anker
    |> Map.put(:art, :geloest)
    |> Map.put(:zweifel, grund)
  end

  defp abgesegnet?(%{abgesegnet_am: am}) when is_binary(am), do: am != ""
  defp abgesegnet?(%{"abgesegnet_am" => am}) when is_binary(am), do: am != ""
  defp abgesegnet?(_), do: false

  # Die Antwort nennt, WAS dort steht und WER es festgelegt hat — ohne das
  # müsste Jack raten, wogegen er anläuft. Und sie nennt beide Wege, weil ein
  # „geht nicht" ohne Ausweg ihn in die Wiederholung schickt (#1211-Lehre:
  # ein Werkzeug, das nur ablehnt, kostete dort 28 von 51 Runden).
  defp verworfen_text(a) do
    "An dieser Stelle hat ein Mensch am #{feld(a, :abgesegnet_am)} festgelegt: " <>
      "#{art_wort(feld(a, :art))} „#{feld(a, :wert)}“. Das lässt sich nicht überschreiben — " <>
      "auch nicht mit einer Entscheidung. Entweder du trägst einen Konflikt ein " <>
      "(`konflikt_eintragen`) oder du ordnest anders ein."
  end

  defp rueckfrage_text(bestand, guid) do
    liste =
      bestand
      |> Enum.map(fn a -> "#{art_wort(feld(a, :art))} „#{feld(a, :wert)}“" end)
      |> Enum.join(", ")

    "An dieser Stelle hängt schon: #{liste}. Eingetragen ist noch nichts. " <>
      "Mit `dazu(\"#{guid}\", …)` kommt deiner daneben — an einer Utterance dürfen " <>
      "mehrere Anker hängen. Mit `ersetzen(\"#{guid}\", …)` löst du den bestehenden " <>
      "aus der Kette. Nennst du die Kennung nicht, verfällt sie."
  end

  defp art_wort(:zeitpunkt), do: "ein Zeitpunkt"
  defp art_wort("zeitpunkt"), do: "ein Zeitpunkt"
  defp art_wort(:spanne), do: "eine Spanne"
  defp art_wort("spanne"), do: "eine Spanne"
  defp art_wort(:ordnung), do: "eine Verschiebung"
  defp art_wort("ordnung"), do: "eine Verschiebung"
  defp art_wort(x), do: to_string(x)

  defp feld(a, k) when is_map(a), do: Map.get(a, k) || Map.get(a, to_string(k)) || ""
end
