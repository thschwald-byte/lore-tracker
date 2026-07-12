defmodule Hub.InputCaps do
  @moduledoc """
  Issue #636: Server-side Längen-Caps für User-Strings in den LV-Save-Pfaden.

  UI-`maxlength` ist Client-Side und mit Browser-DevTools oder einem Custom-
  WebSocket-Client trivial umgehbar — das ist die zweite Verteidigungslinie am
  Server. Threat: authentifizierter User submittet ein 10-MB-„name" oder -„text",
  landet im per-Campaign-Event-Store, wird via Gossip-Pull auf alle Member-Worker
  repliziert (Multiplikator-Effekt gegen die Self-Hoster-Maschinen).

  Konvention: `check/2` liefert `:ok` (wenn `byte_size(text) <= cap(key)`) oder
  `{:error, {:too_long, cap}}`. Die Save-Handler machen daraus einen Flash-Error
  und publishen KEIN Event. `nil` und Nicht-Binaries werden durchgereicht (`:ok`)
  — die Save-Handler entscheiden separat, ob Leere zulässig ist.

  Die Grenze ist bewusst in **Bytes** (nicht Codepoints): das Threat ist eine
  Byte-Größe (Mnesia-/Wire-Bloat), und `byte_size/1` deckelt UTF-8-Multibyte-
  Payloads härter ab als `String.length/1`. Die Werte sind großzügig — sie
  fangen Abuse, keine legitimen Eingaben.
  """

  @caps %{
    campaign_name: 200,
    theme_blurb: 4_000,
    utterance_text: 8_000,
    summary_body: 50_000,
    epos_body: 50_000,
    chapter_body: 50_000,
    chronik_body: 50_000
  }

  @keys Map.keys(@caps)

  @doc """
  Byte-Cap für den gegebenen Schlüssel. Unbekannter Schlüssel → `FunctionClauseError`
  (fail-loud: Rechtschreibfehler im Save-Handler sollen nicht in einer stillen
  Vollnahme durchkommen).
  """
  @spec cap(atom()) :: pos_integer()
  def cap(key) when key in @keys, do: Map.fetch!(@caps, key)

  @doc """
  Bekannte Schlüssel — für Tests und Diagnose.
  """
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc """
  `:ok` wenn `text` ein Binary ist und `byte_size(text) <= cap(key)`, sonst
  `{:error, {:too_long, cap}}`. `nil` und nicht-Binaries → `:ok`.
  """
  @spec check(atom(), term()) :: :ok | {:error, {:too_long, pos_integer()}}
  def check(key, text) when is_binary(text) do
    limit = cap(key)
    if byte_size(text) <= limit, do: :ok, else: {:error, {:too_long, limit}}
  end

  def check(_key, _), do: :ok

  @doc """
  Human-freundliche Flash-Message für ein `{:too_long, cap}`-Ergebnis.
  """
  @spec error_message(atom(), pos_integer()) :: String.t()
  def error_message(key, limit) when key in @keys and is_integer(limit) do
    "#{label(key)} zu lang — max #{limit} Zeichen."
  end

  defp label(:campaign_name), do: "Kampagnen-Name"
  defp label(:theme_blurb), do: "Beschreibung"
  defp label(:utterance_text), do: "Text"
  defp label(:summary_body), do: "Resümee"
  defp label(:epos_body), do: "Epos"
  defp label(:chapter_body), do: "Kapitel"
  defp label(:chronik_body), do: "Chronik-Eintrag"
end
