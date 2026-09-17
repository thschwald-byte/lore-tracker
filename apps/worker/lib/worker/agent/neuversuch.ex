defmodule Worker.Agent.Neuversuch do
  @moduledoc """
  Neuversuch nach einem vorübergehenden Modellfehler, wie pi
  (`pi-ai/dist/utils/retry.js`, `agent-session.js`; Tom, 11.09.2026).

  Anlass: J3 (#1195) brach in Durchgang 6 ab, weil der `llama-server` von
  Ollama mitten im Strom abstürzte (SIGSEGV in der ROCm-Laufzeit). pi hätte
  denselben Kontext nach 2 s noch einmal geschickt — so geschehen am 07.09.
  im Spike, der Lauf lief danach sauber weiter.

  Wie pi:

    * **Vorgabe 3 Neuversuche, Abstand 2 s, verdoppelt** (2, 4, 8 s).
    * **Wiederholt wird, was vorübergehend sein kann:** ein Strom, der ohne
      Abschluss endet (`{:strom_unvollstaendig, _}`, bei pi „Stream ended
      without finish_reason“), ein Transportfehler (`{:netz, _}`), die
      Status 500, 502, 503 und 504, und ein Fehler im Strom, dessen Text auf
      pis Muster passt. Nie wiederholt werden Client-Fehler (4xx), eine
      unlesbare Antwort und Ausnahmen im Client.
    * **Die abgebrochene Antwort zählt nicht**; derselbe Kontext geht noch
      einmal hinaus.
    * **Das Budget gilt je Fehlerserie**: nach einer erfolgreichen Antwort
      beginnt die Zählung von vorn.

  **Ehrliche Grenze:** Die Muster für Fehlertexte im Strom sind die, die eve
  aus pis `RETRYABLE_PROVIDER_ERROR_PATTERN` genannt hat („unter anderem“),
  nicht die vollständige Liste.
  """

  @enforce_keys [:versuche, :basis_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{versuche: non_neg_integer(), basis_ms: non_neg_integer()}

  @muster ~r/ended without|terminated|fetch failed|socket hang up|connection error|timeout|\b50[0234]\b/i

  @doc "Aus den Optionen `versuche:` (Default 3) und `basis_ms:` (Default 2000)."
  @spec neu(keyword()) :: {:ok, t()} | {:error, String.t()}
  def neu(opts) when is_list(opts) do
    versuche = Keyword.get(opts, :versuche, 3)
    basis = Keyword.get(opts, :basis_ms, 2000)

    cond do
      (fremd = Keyword.keys(opts) -- [:versuche, :basis_ms]) != [] ->
        {:error, "unbekannte Schlüssel #{inspect(fremd)}"}

      not (is_integer(versuche) and versuche >= 0) ->
        {:error, "versuche: ganze Zahl ≥ 0 erwartet, erhalten #{inspect(versuche)}"}

      not (is_integer(basis) and basis >= 0) ->
        {:error, "basis_ms: ganze Zahl ≥ 0 erwartet, erhalten #{inspect(basis)}"}

      true ->
        {:ok, %__MODULE__{versuche: versuche, basis_ms: basis}}
    end
  end

  @doc """
  Ob nach dem `versuch`-ten Fehlschlag einer Serie (1 = der erste Aufruf
  schlug fehl) noch einmal versucht wird. `nil` heißt: abgeschaltet.
  """
  @spec nochmal?(t() | nil, term(), pos_integer()) :: boolean()
  def nochmal?(nil, _grund, _versuch), do: false

  def nochmal?(%__MODULE__{versuche: n}, grund, versuch),
    do: versuch <= n and wiederholbar?(grund)

  @doc "Ob ein Fehler des Modell-Clients vorübergehend sein kann."
  @spec wiederholbar?(term()) :: boolean()
  def wiederholbar?({:strom_unvollstaendig, _roh}), do: true
  def wiederholbar?({:netz, _grund}), do: true
  def wiederholbar?({:http, status, _body}) when status in [500, 502, 503, 504], do: true
  def wiederholbar?({:strom, fehler}), do: Regex.match?(@muster, text(fehler))
  def wiederholbar?(_grund), do: false

  @doc "Wartezeit vor dem Neuversuch nach dem `versuch`-ten Fehlschlag."
  @spec wartezeit(t(), pos_integer()) :: non_neg_integer()
  def wartezeit(%__MODULE__{basis_ms: basis}, versuch), do: basis * Integer.pow(2, versuch - 1)

  defp text(text) when is_binary(text), do: text
  defp text(%{"message" => text}) when is_binary(text), do: text
  defp text(anderes), do: inspect(anderes)
end
