defmodule Worker.Jack.Epos.Hinweise do
  @moduledoc """
  Die Hinweise der Epos-Durchsicht (E3, #1210): je Absatz die
  großgeschriebenen Wörter ohne Fundstelle. Deterministisch und nur ein
  Fingerzeig — kein Werkzeug lehnt deswegen etwas ab.

  **Die Methode ist die des Resümees** (`Worker.Jack.Resuemee.Hinweise.ohne_fundstelle/2`):
  ein Hinweis ist ein Wort, das mit einem Großbuchstaben beginnt, nicht am
  Satzanfang steht (erstes Wort, nach `.`, `!`, `?`, `:` oder einem
  Anführungszeichen), kein übliches Funktionswort ist und keine Fundstelle
  hat; Fundstelle heißt Wortteil (der Stamm ohne übliche Endung, ab vier
  Buchstaben irgendwo in den Fundstellen, kürzere als ganzes Wort; bei
  Bindestrich jeder Teil). Geprüft wird der Text des Absatzes, als Ganzes.

  **Die Fundstellen hängen an der Szene** — beim Epos gibt es keine Fakten je
  Satz (Maintainer, 13.09.2026):

    * ein Absatz **mit Szene**: Aussage und Figur jedes Fakts, den die Szene
      in den Notizen nennt (frühere Fakten eingeschlossen);
    * ein Absatz **ohne Szene** (eine Überleitung, ein Bild zwischen zwei
      Szenen) — oder mit einer Szene, die in den Notizen nicht steht:
      Aussage und Figur aller Fakten dieser Sitzung;
    * in beiden Fällen dazu der Cast, die Titel der Bögen dieser Sitzung und
      die Stränge (`Worker.Jack.Resuemee.Hinweise.grundfundstellen/1`) und
      der Text des **vorigen Kapitels** (`voriges_kapitel/1`) — Namen aus dem
      Anschluss sind legitim.

  **Benannte Grenzen.** Deutsch schreibt Substantive groß; beim Epos ist das
  Rauschen größer als beim Resümee, denn Bilder und Stimmung sind hier gewollt
  („Regen“, „Lampe“, „Vorhang“ haben selten eine Fundstelle). Dazu jeder
  Umlaut-Plural („Werkstätten“ findet „Werkstatt“ nicht) und jedes
  zusammengesetzte Wort, von dem nur ein Teil bekannt ist. Unsichtbar bleibt
  vor allem die **falsche Figur**: ein Name aus dem Cast hat immer eine
  Fundstelle, auch wenn die Szene von jemand anderem handelt; ebenso ein
  Name aus dem vorigen Kapitel, der in diese Szene nicht gehört, und bei einem
  Absatz ohne Szene ein Name aus einer anderen Szene dieser Sitzung. Ein Name
  am Satzanfang entgeht der Liste, Titel werden nicht geprüft. Ob ein Absatz
  erzählt, was seine Szene sagt, prüft kein Code — das ist die Durchsicht
  selbst.
  """

  alias Worker.Jack.Epos.Entwurf
  alias Worker.Jack.Resuemee.Hinweise, as: Methode
  alias Worker.Jack.Resuemee.Stand

  @doc "Die Hinweise eines Absatzes (`t:Worker.Jack.Epos.Entwurf.absatz/0`), je Wort einmal."
  @spec absatz(Stand.t(), Entwurf.absatz()) :: [String.t()]
  def absatz(%Stand{} = s, a), do: Methode.ohne_fundstelle(a.text, fundstellen(s, a))

  @doc "Wie viele Hinweise ein Absatz hat."
  @spec zahl(Stand.t(), Entwurf.absatz()) :: non_neg_integer()
  def zahl(%Stand{} = s, a), do: length(absatz(s, a))

  @doc "Wie viele Hinweise ein ganzes Kapitel hat (eine Liste von Absätzen)."
  @spec anzahl(Stand.t(), [Entwurf.absatz()]) :: non_neg_integer()
  def anzahl(%Stand{} = s, entwurf), do: entwurf |> Enum.map(&zahl(s, &1)) |> Enum.sum()

  @doc "Die Fundstellen eines Absatzes (Moduldoc), als Liste von Texten."
  @spec fundstellen(Stand.t(), Entwurf.absatz()) :: [String.t()]
  def fundstellen(%Stand{} = s, a) do
    Methode.fakt_fundstellen(fakten(s, a)) ++
      Methode.grundfundstellen(s) ++ kapitel_text(voriges_kapitel(s))
  end

  @doc """
  Die Fakten, an denen ein Absatz gemessen wird: die seiner Szene, sonst alle
  dieser Sitzung.
  """
  @spec fakten(Stand.t(), Entwurf.absatz()) :: [Stand.fakt()]
  def fakten(%Stand{} = s, a) do
    case szene(s, a) do
      nil -> s.fakten
      sz -> sz.fakten |> Enum.map(&Stand.fakt(s, &1)) |> Enum.reject(&is_nil/1)
    end
  end

  @doc "Die Szene eines Absatzes aus den Notizen; `nil` ohne Szene oder wenn sie dort nicht steht."
  @spec szene(Stand.t(), Entwurf.absatz()) :: Stand.notiz() | nil
  def szene(%Stand{} = s, %{szene: k}) when is_binary(k), do: Entwurf.szene(s, k)
  def szene(_s, _a), do: nil

  @doc """
  Das vorige Kapitel: unter den Kapiteln der Lesebasis das mit der größten
  Sitzungsnummer unterhalb dieser Sitzung, `%{nummer:, name:, text:}` — sonst
  `nil`.
  """
  @spec voriges_kapitel(Stand.t()) :: map() | nil
  def voriges_kapitel(%Stand{sitzung: %{nummer: n}, kapitel: kapitel}) do
    kapitel
    |> Enum.filter(&(is_integer(&1.nummer) and is_integer(n) and &1.nummer < n))
    |> Enum.max_by(& &1.nummer, fn -> nil end)
  end

  defp kapitel_text(%{text: t}) when is_binary(t), do: [t]
  defp kapitel_text(_kein), do: []
end
