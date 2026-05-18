defmodule Shared.Codec do
  @moduledoc """
  Wire-format codec for events and snapshots.

  Wire format is `:erlang.term_to_binary/2` with `compressed: true` for
  Hub-internal `events`-Mnesia payloads and channel frames between Hub and
  Worker (both are BEAM peers, so native term encoding is the cheapest).

  JSON encoding (`encode_json/1`/`decode_json/2`) is reserved for the
  Hub-LiveView wire and any future external consumers.
  """

  @spec encode(term()) :: binary()
  def encode(term), do: :erlang.term_to_binary(term, [:compressed])

  @spec decode(binary()) :: term()
  def decode(bin) when is_binary(bin), do: :erlang.binary_to_term(bin, [:safe])
end
