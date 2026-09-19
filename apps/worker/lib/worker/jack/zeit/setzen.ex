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

  ## Die GUID gilt genau einmal

  Sie ist an die Stelle gebunden, die sie ausgelöst hat, und verfällt, wenn
  der nächste Aufruf sie nicht nennt (`Worker.Jack.Tor`-Muster). Damit kann
  eine Entscheidung nicht versehentlich auf einen anderen Anker wirken.

  ## Was hier NICHT entschieden wird

  Welcher von zwei Ankern an einer Stelle **gilt** — das rechnet
  `Worker.Timeline.Linie` beim Lesen (erst abgesegnet, dann früher). Hier geht
  es nur darum, was überhaupt eingetragen wird.
  """

  alias Worker.Timeline.Linie

  @typedoc "Ein Anker, wie Jack ihn setzen will."
  @type wunsch :: %{
          required(:utterance_ids) => [String.t()],
          required(:art) => atom(),
          required(:wert) => String.t(),
          required(:welt) => String.t(),
          required(:beleg) => String.t(),
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
  Entscheidet über einen Wunsch. `bestand` sind die Anker, die an denselben
  Utterances schon hängen; `guid_gibt` erzeugt eine frische Kennung.

  `entscheidung` ist `nil` beim ersten Aufruf, sonst `{:dazu, guid}` oder
  `{:ersetzen, guid}` — dann wird die Rückfrage übersprungen.
  """
  @spec entscheiden(wunsch(), [map()], (-> String.t()), {atom(), String.t()} | nil) :: ergebnis()
  def entscheiden(wunsch, bestand, guid_gibt, entscheidung \\ nil)

  def entscheiden(wunsch, bestand, guid_gibt, nil) do
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

  def entscheiden(wunsch, bestand, _guid_gibt, {art, _guid}) when art in [:dazu, :ersetzen] do
    # Auch mit Entscheidung gilt die Absegnung — sie ist für niemanden
    # verhandelbar, auch nicht über eine GUID.
    case Enum.find(bestand, &abgesegnet?/1) do
      nil -> {:gesetzt, bauen(wunsch)}
      a -> {:verworfen, %{text: verworfen_text(a)}}
    end
  end

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
      zweifel: Map.get(w, :zweifel, ""),
      quelle: "jack",
      abgesegnet_von: "",
      abgesegnet_am: ""
    }
  end

  @doc """
  Der Anker, den eine Rücknahme schreibt: dieselbe Adresse, Art `geloest`.
  **Nie ein Delete** — ein vertauschtes Setzen/Zurücknehmen divergierte sonst
  zwischen zwei Workern (#698-Klasse).
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
