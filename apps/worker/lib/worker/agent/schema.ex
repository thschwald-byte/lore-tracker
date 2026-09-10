defmodule Worker.Agent.Schema do
  @moduledoc """
  Prüft Werkzeug-Argumente gegen ein JSON-Schema — die Teilmenge, die
  Werkzeuge brauchen, nicht der ganze Standard.

  Unterstützt: `type` (auch als Liste), `properties`, `required`,
  `additionalProperties` (nur `true`/`false`), `enum`, `items`,
  `minItems`/`maxItems`, `minimum`/`maximum`, `minLength`/`maxLength`.
  `description` und `title` sind erlaubt und werden nicht geprüft. **Jedes
  andere Schlüsselwort lehnt `Worker.Agent.Werkzeug.neu/1` ab**
  (`unbekannte/1`): ein `pattern` oder `default`, das still nicht wirkt, wäre
  eine Zusage, die niemand einlöst.

  Wie pi (`validateToolArguments`) wird vor der Prüfung angeglichen, was ein
  lokales Modell typischerweise falsch schickt: eine Zahl als Text (`"5"` für
  `integer`, `"2.5"` für `number`), einen Wahrheitswert als Text, `5.0` für
  `integer`, und `null` für ein optionales Feld, das kein `null` erlaubt (es
  fällt weg). Geprüft wird das Angeglichene, und genau das bekommt auch das
  Werkzeug.

  Die Fehlertexte gehen an das Modell. Deshalb nennen sie den Pfad des Felds
  und was erwartet war, in den Typnamen des Schemas, die das Modell kennt.
  """

  @schluessel ~w(type properties required additionalProperties enum items
                 minItems maxItems minimum maximum minLength maxLength description title)

  @typen ~w(object array string integer number boolean null)

  @doc "Die unterstützten Schema-Schlüssel."
  @spec schluessel() :: [String.t()]
  def schluessel, do: @schluessel

  @doc """
  Schreibt Atom-Schlüssel und Atom-Werte eines Schemas als Text (`true`,
  `false` und `nil` bleiben). Danach lässt sich das Schema einheitlich lesen
  und unverändert als JSON verschicken.
  """
  @spec normalisieren(term()) :: term()
  def normalisieren(%{} = m), do: Map.new(m, fn {k, v} -> {to_string(k), normalisieren(v)} end)
  def normalisieren(l) when is_list(l), do: Enum.map(l, &normalisieren/1)

  def normalisieren(v) when is_atom(v) and not is_boolean(v) and not is_nil(v),
    do: Atom.to_string(v)

  def normalisieren(v), do: v

  @doc """
  Pfade der Stellen im Schema, die diese Prüfung nicht einlösen würde:
  unbekannte Schlüssel, unbekannte Typnamen und `additionalProperties` mit
  einem Schema statt `true`/`false`. Leer, wenn alles geprüft wird.
  """
  @spec unbekannte(map()) :: [String.t()]
  def unbekannte(schema), do: unbekannte(normalisieren(schema), [])

  defp unbekannte(%{} = schema, pfad) do
    fremd = for {k, _} <- Enum.sort(schema), k not in @schluessel, do: zeige(pfad ++ [k])

    typ =
      for t <- typen(schema), t not in @typen, do: "#{zeige(pfad ++ ["type"])} (#{inspect(t)})"

    zusatz =
      case Map.get(schema, "additionalProperties") do
        wert when is_boolean(wert) or is_nil(wert) -> []
        _ -> ["#{zeige(pfad ++ ["additionalProperties"])} (nur true/false)"]
      end

    innen =
      for {name, s} <- Enum.sort(Map.get(schema, "properties", %{})),
          p <- unbekannte(s, pfad ++ [name]),
          do: p

    posten =
      case Map.get(schema, "items") do
        %{} = s -> unbekannte(s, pfad ++ ["items"])
        _ -> []
      end

    fremd ++ typ ++ zusatz ++ innen ++ posten
  end

  defp unbekannte(_kein_schema, pfad), do: ["#{zeige(pfad)} (kein Schema-Objekt)"]

  @doc """
  Gleicht `wert` an das Schema an und prüft ihn. Liefert den angeglichenen
  Wert oder die Liste aller Verstöße, jeder als eine Zeile `pfad: was`.
  """
  @spec pruefen(map(), term()) :: {:ok, term()} | {:error, [String.t()]}
  def pruefen(schema, wert) do
    schema = normalisieren(schema)
    wert = angleichen(schema, wert)

    case fehler(schema, wert, []) do
      [] -> {:ok, wert}
      verstoesse -> {:error, verstoesse}
    end
  end

  # ─── Angleichen ────────────────────────────────────────────────────────

  defp angleichen(schema, wert) when is_map(wert) do
    if Map.has_key?(schema, "properties"), do: objekt_angleichen(schema, wert), else: wert
  end

  defp angleichen(%{"items" => %{} = posten}, wert) when is_list(wert),
    do: Enum.map(wert, &angleichen(posten, &1))

  defp angleichen(schema, wert), do: skalar_angleichen(typen(schema), wert)

  defp objekt_angleichen(schema, wert) do
    props = Map.get(schema, "properties", %{})
    pflicht = Map.get(schema, "required", [])

    for {k, v} <- wert, not weglassen?(k, v, props, pflicht), into: %{} do
      {k, if(Map.has_key?(props, k), do: angleichen(props[k], v), else: v)}
    end
  end

  # pi: normalizeOptionalNulls — ein `null` für ein optionales Feld, dessen
  # Schema kein `null` erlaubt, heißt „nicht angegeben“.
  defp weglassen?(k, nil, props, pflicht),
    do: k not in pflicht and "null" not in typen(Map.get(props, k, %{}))

  defp weglassen?(_k, _v, _props, _pflicht), do: false

  defp skalar_angleichen([], wert), do: wert

  defp skalar_angleichen(typen, wert) do
    if Enum.any?(typen, &typ?(wert, &1)) do
      wert
    else
      case Enum.find_value(typen, &umwandeln(&1, wert)) do
        {:ok, neu} -> neu
        nil -> wert
      end
    end
  end

  defp umwandeln("integer", w) when is_float(w) and trunc(w) == w, do: {:ok, trunc(w)}

  defp umwandeln("integer", w) when is_binary(w) do
    case Integer.parse(String.trim(w)) do
      {i, ""} -> {:ok, i}
      _ -> nil
    end
  end

  defp umwandeln("number", w) when is_binary(w) do
    text = String.trim(w)

    case {Integer.parse(text), Float.parse(text)} do
      {{i, ""}, _} -> {:ok, i}
      {_, {f, ""}} -> {:ok, f}
      _ -> nil
    end
  end

  defp umwandeln("boolean", "true"), do: {:ok, true}
  defp umwandeln("boolean", "false"), do: {:ok, false}
  defp umwandeln(_typ, _w), do: nil

  # ─── Prüfen ────────────────────────────────────────────────────────────

  defp fehler(schema, wert, pfad) do
    typen = typen(schema)

    if typen != [] and not Enum.any?(typen, &typ?(wert, &1)) do
      ["#{zeige(pfad)}: erwartet #{Enum.join(typen, " oder ")}, erhalten #{typ_von(wert)}"]
    else
      enum_fehler(schema, wert, pfad) ++ inhalt_fehler(schema, wert, pfad)
    end
  end

  defp enum_fehler(%{"enum" => erlaubt}, wert, pfad) do
    if wert in erlaubt do
      []
    else
      [
        "#{zeige(pfad)}: muss einer von #{Enum.map_join(erlaubt, ", ", &json/1)} sein, erhalten #{json(wert)}"
      ]
    end
  end

  defp enum_fehler(_schema, _wert, _pfad), do: []

  defp inhalt_fehler(schema, wert, pfad) when is_map(wert) do
    props = Map.get(schema, "properties", %{})

    fehlend =
      for k <- Map.get(schema, "required", []),
          not Map.has_key?(wert, k),
          do: "#{zeige(pfad ++ [k])}: fehlt"

    fremd =
      if schema["additionalProperties"] == false do
        erlaubt = props |> Map.keys() |> Enum.sort() |> Enum.join(", ")

        for k <- wert |> Map.keys() |> Enum.sort(),
            not Map.has_key?(props, k),
            do: "#{zeige(pfad ++ [k])}: unbekanntes Feld (erlaubt: #{erlaubt})"
      else
        []
      end

    innen =
      for {k, v} <- Enum.sort(wert),
          Map.has_key?(props, k),
          f <- fehler(props[k], v, pfad ++ [k]),
          do: f

    fehlend ++ fremd ++ innen
  end

  defp inhalt_fehler(schema, wert, pfad) when is_list(wert) do
    posten =
      case schema["items"] do
        %{} = s ->
          for {v, i} <- Enum.with_index(wert),
              f <- fehler(s, v, pfad ++ [Integer.to_string(i)]),
              do: f

        _ ->
          []
      end

    grenzen(schema, length(wert), {"minItems", "maxItems"}, pfad, " Einträge") ++ posten
  end

  defp inhalt_fehler(schema, wert, pfad) when is_binary(wert),
    do: grenzen(schema, String.length(wert), {"minLength", "maxLength"}, pfad, " Zeichen")

  defp inhalt_fehler(schema, wert, pfad) when is_number(wert),
    do: grenzen(schema, wert, {"minimum", "maximum"}, pfad, "")

  defp inhalt_fehler(_schema, _wert, _pfad), do: []

  defp grenzen(schema, n, {min_key, max_key}, pfad, einheit) do
    min = schema[min_key]
    max = schema[max_key]

    cond do
      is_number(min) and n < min -> ["#{zeige(pfad)}: mindestens #{min}#{einheit}, erhalten #{n}"]
      is_number(max) and n > max -> ["#{zeige(pfad)}: höchstens #{max}#{einheit}, erhalten #{n}"]
      true -> []
    end
  end

  # ─── Hilfen ────────────────────────────────────────────────────────────

  defp typen(%{"type" => t}) when is_binary(t), do: [t]
  defp typen(%{"type" => l}) when is_list(l), do: l
  defp typen(_schema), do: []

  defp typ?(v, "object"), do: is_map(v)
  defp typ?(v, "array"), do: is_list(v)
  defp typ?(v, "string"), do: is_binary(v)
  defp typ?(v, "integer"), do: is_integer(v)
  defp typ?(v, "number"), do: is_number(v)
  defp typ?(v, "boolean"), do: is_boolean(v)
  defp typ?(v, "null"), do: is_nil(v)
  defp typ?(_v, _unbekannt), do: false

  defp typ_von(nil), do: "null"
  defp typ_von(v) when is_boolean(v), do: "boolean"
  defp typ_von(v) when is_binary(v), do: "string"
  defp typ_von(v) when is_integer(v), do: "integer"
  defp typ_von(v) when is_float(v), do: "number"
  defp typ_von(v) when is_map(v), do: "object"
  defp typ_von(v) when is_list(v), do: "array"
  defp typ_von(v), do: inspect(v)

  defp zeige([]), do: "Argumente"
  defp zeige(pfad), do: Enum.join(pfad, ".")

  defp json(w) do
    case Jason.encode(w) do
      {:ok, text} -> text
      {:error, _} -> inspect(w)
    end
  end
end
