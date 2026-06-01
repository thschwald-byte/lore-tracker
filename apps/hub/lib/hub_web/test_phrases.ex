defmodule HubWeb.TestPhrases do
  @moduledoc """
  Issue #400: Test-Phrasen für die ASR-gestützte Mic-Setup-Prüfung.

  Statt nur den Pegel zu messen (#391) bekommt der User ein kurzes, bekanntes
  Filmzitat zu sprechen; der aufgenommene Clip wird im Worker per Whisper
  transkribiert und gegen die erwartete Phrase abgeglichen (siehe
  `HubWeb.CampaignLive.phrase_match?/2`). Das fängt Mikros, die nur lauten
  Brei statt verständlicher Sprache liefern.

  Die Phrasen liegen in `priv/data/test_phrases.json`
  (`{"phrases": [{"text": ..., "source": ...}]}`) und werden zur **Compile-Zeit**
  eingebettet — kein Runtime-FS-Zugriff, kein Release-Pfad-Problem, und der
  Loader ist count-agnostisch (die Datei darf Richtung 1000 wachsen, ohne dass
  hier etwas geändert werden muss). `source` ist der Film + Jahr (Issue #410),
  wird unter dem Zitat angezeigt.

  Eine Phrase ist eine `%{text: String.t(), source: String.t()}`-Map.
  """

  @external_resource Path.join([__DIR__, "..", "..", "priv", "data", "test_phrases.json"])

  @phrases (case File.read(@external_resource) do
              {:ok, raw} ->
                case Jason.decode(raw) do
                  {:ok, %{"phrases" => list}} when is_list(list) ->
                    list
                    |> Enum.map(fn
                      %{"text" => text} = m ->
                        %{text: String.trim(text), source: String.trim(m["source"] || "")}

                      other ->
                        raise "test_phrases.json: Phrase ohne \"text\": #{inspect(other)}"
                    end)
                    |> Enum.reject(&(&1.text == ""))

                  other ->
                    raise "test_phrases.json hat kein \"phrases\"-Array: #{inspect(other)}"
                end

              {:error, reason} ->
                raise "test_phrases.json nicht lesbar (#{inspect(reason)}) unter #{@external_resource}"
            end)

  if @phrases == [] do
    raise "test_phrases.json enthält keine Phrasen"
  end

  @typedoc "Eine Test-Phrase: Zitat-Text + Quelle (Film + Jahr)."
  @type phrase :: %{text: String.t(), source: String.t()}

  @doc "Alle eingebetteten Test-Phrasen (Reihenfolge wie in der JSON-Datei)."
  @spec all() :: [phrase()]
  def all, do: @phrases

  @doc "Anzahl der eingebetteten Test-Phrasen."
  @spec count() :: pos_integer()
  def count, do: length(@phrases)

  @doc "Eine zufällige Test-Phrase (`%{text:, source:}`)."
  @spec random() :: phrase()
  def random, do: Enum.random(@phrases)
end
