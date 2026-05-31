defmodule Worker.MultiSourceEval.Normalize do
  @moduledoc """
  Text-Normalisierung für WER-Vergleich (Issue #377 Plan v5 Section B).

  Reihenfolge fix:
    NFC → lowercase → Interpunktion strippen → optional numerals → Whitespace.

  NFC zuerst, damit `String.downcase/1` über kombinierte Diakritika konsistent
  arbeitet. Numerals-Konvertierung als Flag (default `false`), weil der Faust-
  Korpus Zahlen ausgeschrieben hat — für künftige Korpora mit echten Ziffern
  Flag setzen.
  """

  @punct_regex ~r/[…\.\,\?\!\:\;\(\)\[\]"'„""'’—–\-]+/u
  @ws_regex ~r/\s+/u

  @doc """
  Normalisiert `text` für WER-Vergleich.

  Optionen:
    * `:numerals?` (boolean, default `false`) — wenn `true`, werden Ziffern
      durch ausgeschriebene Wörter ersetzt (Stub für künftige OOD-Korpora;
      aktuell no-op).
  """
  def for_wer(text, opts \\ [])
  def for_wer(nil, _opts), do: ""
  def for_wer("", _opts), do: ""

  def for_wer(text, opts) when is_binary(text) do
    text
    |> String.normalize(:nfc)
    |> String.downcase()
    |> String.replace(@punct_regex, " ")
    |> maybe_numerals_to_words(Keyword.get(opts, :numerals?, false))
    |> String.replace(@ws_regex, " ")
    |> String.trim()
  end

  @doc "Tokenisiert normalisierten Text in Wort-Liste (whitespace-split)."
  def words(text, opts \\ []) do
    case for_wer(text, opts) do
      "" -> []
      norm -> String.split(norm, " ", trim: true)
    end
  end

  defp maybe_numerals_to_words(text, false), do: text
  defp maybe_numerals_to_words(text, true), do: text
end
