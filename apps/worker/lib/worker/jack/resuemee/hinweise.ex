defmodule Worker.Jack.Resuemee.Hinweise do
  @moduledoc """
  Die Hinweise der Durchsicht (J5, #1209, B3): je Satz die großgeschriebenen
  Wörter ohne Fundstelle. Deterministisch und nur ein Fingerzeig — kein
  Werkzeug lehnt deswegen etwas ab. Die Durchsicht ist gnädig, Jack darf
  formulieren (Maintainer); die Hinweise zeigen ihm, wo er genauer hinsieht.

  **Ein Hinweis** ist ein Wort, das mit einem Großbuchstaben beginnt, nicht
  am Satzanfang steht, kein übliches Funktionswort ist („Der“, „Dann“, „Sie“)
  und keine Fundstelle hat:

    * in einem Satz mit Fakten (auch einem Rückblick) weder in der Aussage
      noch in der Figur eines zitierten Fakts, noch im Cast, in den Titeln
      der Bögen dieser Sitzung oder in den Strängen der Kampagne;
    * in einem Übergang gibt es keine Fundstelle: ein Übergang soll keinen
      Stoff tragen, jedes großgeschriebene Wort außer am Satzanfang ist ein
      Hinweis — auch ein bekannter Name.

  **Fundstelle heißt Wortteil.** Ein Wort gilt als gefunden, wenn sein Stamm
  — klein geschrieben, eine übliche Endung (`-ern`, `-en`, `-er`, `-es`,
  `-em`, `-e`, `-n`, `-s`) abgeschnitten, sofern mindestens vier Buchstaben
  bleiben — irgendwo in den Fundstellen steht, auch mitten in einem Wort:
  „Uhrmachers“ findet „Uhrmacher“, „Spieldosen“ findet „Spieldose“. Ein
  Stamm unter vier Buchstaben muss als ganzes Wort dastehen („Tor“ findet
  sich nicht in „Motor“). Ein Wort mit Bindestrich gilt als gefunden, wenn
  jeder seiner Teile es ist.

  **Satzanfang** ist das erste Wort eines Satzes und jedes Wort nach `.`,
  `!`, `?`, `:` oder einem Anführungszeichen — dort ist Großschreibung
  Grammatik, kein Name.

  **Benannte Grenzen.** Deutsch schreibt Substantive groß; die Liste enthält
  deshalb Rauschen — jedes Substantiv, das der Satz anders nennt als seine
  Fakten („Schenke“, wo der Fakt „Wirtshaus“ sagt), jeder Umlaut-Plural
  („Werkstätten“ findet „Werkstatt“ nicht) und jedes zusammengesetzte Wort,
  von dem nur ein Teil bekannt ist („Hafenkneipe“ bei „Hafen“). Umgekehrt
  entgeht ihr ein Name am Satzanfang, ein Name nach einer Abkürzung mit Punkt
  („z. B. Mira“), und vor allem die **falsche Figur**: ein Name aus dem Cast
  hat immer eine Fundstelle, auch wenn der Fakt des Satzes von jemand
  anderem handelt. Titel werden nicht geprüft. Ob ein Satz sagt, was seine
  Fakten sagen, prüft kein Code — das ist die Durchsicht selbst.
  """

  alias Worker.Jack.Resuemee.Stand

  @token ~r/\p{L}[\p{L}\p{N}]*(?:-[\p{L}\p{N}]+)*|[.!?:„“”"»«‚‘]/u
  @satzanfang ~w(. ! ? : „ “ ” " » « ‚ ‘)
  @endungen ~w(ern en er es em e n s)
  @min_stamm 4

  # Wörter, die groß nur am Satz- oder Teilsatzanfang stehen (oder als
  # Anrede) und nie ein Name sind. Klein geschrieben verglichen.
  @funktionswoerter MapSet.new(~w(
    der die das dem den des ein eine einen einem einer eines kein keine keinen keinem keiner
    er sie es wir ihr ich du man sich ihm ihn ihnen uns euch mich dich mir dir
    und oder aber doch denn sondern dann da als wenn weil ob dass damit bevor nachdem während
    so nun noch auch nur schon bald dort hier danach davor dabei darauf daraufhin trotzdem
    jedoch zudem außerdem später zuvor zuerst schließlich endlich plötzlich inzwischen
    im in am an auf aus bei mit nach von vor zu zum zur über unter durch für gegen ohne um
    bis seit wegen hinter neben zwischen was wer wie wo warum wohin woher wem wen wessen
    dieser diese dieses diesem diesen jener jene jenes sein seine seinen seinem seiner
    ihre ihren ihrem ihrer unser unsere euer eure alle alles jeder jede jedes jedem jeden
    viele einige beide nicht nie niemand jemand etwas nichts ja nein immer wieder zwar
    selbst gemeinsam zunächst anschließend kurz lange
  ))

  @doc """
  Die Hinweise eines Satzes (`t:Worker.Jack.Resuemee.Stand.satz/0`), je Wort
  einmal, in der Reihenfolge des Satzes.
  """
  @spec satz(Stand.t(), Stand.satz()) :: [String.t()]
  def satz(%Stand{}, %{uebergang: true, text: text}), do: kandidaten(text)

  def satz(%Stand{} = s, %{text: text, fakten: ids}) do
    fundus = fundus(s, ids)
    text |> kandidaten() |> Enum.reject(&gefunden?(&1, fundus))
  end

  @doc "Die Hinweise eines Absatzes, je Satz eine Liste (in der Reihenfolge der Sätze)."
  @spec absatz(Stand.t(), Stand.absatz()) :: [[String.t()]]
  def absatz(%Stand{} = s, %{saetze: saetze}), do: Enum.map(saetze, &satz(s, &1))

  @doc "Wie viele Hinweise ein Absatz hat."
  @spec zahl(Stand.t(), Stand.absatz()) :: non_neg_integer()
  def zahl(%Stand{} = s, a), do: s |> absatz(a) |> Enum.map(&length/1) |> Enum.sum()

  @doc "Wie viele Hinweise ein ganzer Entwurf hat (eine Liste von Absätzen)."
  @spec anzahl(Stand.t(), [Stand.absatz()]) :: non_neg_integer()
  def anzahl(%Stand{} = s, entwurf), do: entwurf |> Enum.map(&zahl(s, &1)) |> Enum.sum()

  # Die großgeschriebenen Wörter außerhalb des Satzanfangs, ohne
  # Funktionswörter, je einmal.
  defp kandidaten(text) do
    @token
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.reduce({true, []}, fn tok, {anfang?, acc} ->
      cond do
        tok in @satzanfang -> {true, acc}
        anfang? -> {false, acc}
        gross?(tok) and not funktionswort?(tok) -> {false, [tok | acc]}
        true -> {false, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp gross?(wort) do
    erstes = String.first(wort)
    erstes != String.downcase(erstes)
  end

  defp funktionswort?(wort), do: MapSet.member?(@funktionswoerter, String.downcase(wort))

  # Die Fundstellen eines Satzes: {Text klein geschrieben, seine Wörter}.
  defp fundus(s, ids) do
    fakten = ids |> Enum.map(&Stand.fakt(s, &1)) |> Enum.reject(&is_nil/1)

    text =
      (Enum.flat_map(fakten, &[&1.aussage, &1.figur || ""]) ++
         s.mitschnitt.cast ++ Enum.map(s.boegen, & &1.titel) ++ s.mitschnitt.straenge)
      |> Enum.map_join("\n", &to_string/1)
      |> String.downcase()

    {text, ~r/[\p{L}\p{N}]+/u |> Regex.scan(text) |> List.flatten() |> MapSet.new()}
  end

  defp gefunden?(wort, fundus),
    do: wort |> String.split("-", trim: true) |> Enum.all?(&teil_gefunden?(&1, fundus))

  defp teil_gefunden?(teil, {text, woerter}) do
    klein = String.downcase(teil)
    stamm = stamm(klein)

    if String.length(stamm) >= @min_stamm,
      do: String.contains?(text, stamm),
      else: MapSet.member?(woerter, klein)
  end

  defp stamm(wort) do
    case Enum.find(@endungen, &abschneidbar?(wort, &1)) do
      nil -> wort
      e -> String.slice(wort, 0, String.length(wort) - String.length(e))
    end
  end

  defp abschneidbar?(wort, endung),
    do:
      String.ends_with?(wort, endung) and
        String.length(wort) - String.length(endung) >= @min_stamm
end
