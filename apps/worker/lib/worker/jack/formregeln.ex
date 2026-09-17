defmodule Worker.Jack.Formregeln do
  @moduledoc """
  Die Feldprüfung einer Aussage, wie der Spike sie in `aussage()` macht
  (Abschnitt „Formregeln“ und der Anfang des Werkzeugs, werkzeuge.ts
  7ecc9ea8): in seiner Reihenfolge und seinem Wortlaut. `fehler/3` liefert
  die Meldungen, leer heißt: die Form stimmt.

  Reihenfolge wie im Spike: fehlende Felder, Texte, Listen, Enums,
  `character` und `cast_match`, `time_offset`, leere Pflichtfelder (seit
  7ecc9ea8), zuletzt Blöcke, die es nicht gibt. Für `aussage_entscheiden`
  kommen die Steuerfelder dazu (im Spike steckten sie als optionale Felder in
  `aussage`) und die beiden erlaubten Werte von `entscheidung`.

  Bei gültigem Schema findet die Prüfung nur, was das Schema nicht sieht
  (Cast, Blöcke). Nach einem Schemaverstoß nennt sie den Grund so, wie der
  Spike ihn nannte (`Worker.Jack.Aussage.formfehler/4`, Toms Entscheidung zu
  B2). Aus `Worker.Jack.Aussage` herausgelöst, als dieses Modul die
  God-Module-Grenze überschritt.
  """

  alias Worker.Jack.{Felder, Stand}

  @pflicht ~w(claim character cast_match narration_time time_anchor in_game_date fact_type
              threads source_refs beleg)
  @textfeld ~w(claim character cast_match narration_time time_anchor in_game_date fact_type beleg)
  @listenfeld ~w(threads source_refs)
  @enum_reihe ~w(narration_time time_anchor fact_type precision)

  @doc "Die Meldungen zur Form einer Aussage für das Werkzeug `werkzeug`, oder `[]`."
  @spec fehler(Stand.t(), map(), String.t()) :: [String.t()]
  def fehler(%Stand{} = s, f, werkzeug) do
    {pflicht, text, liste} =
      if werkzeug == "aussage_entscheiden",
        do:
          {@pflicht ++ Felder.steuerfelder(),
           @textfeld ++ ~w(verifikations_guid entscheidung begruendung),
           @listenfeld ++ ["weitere_guids"]},
        else: {@pflicht, @textfeld, @listenfeld}

    Enum.concat([
      for(k <- pflicht, not Map.has_key?(f, k), do: "`#{k}` fehlt"),
      for(
        k <- text,
        Map.has_key?(f, k) and not is_binary(f[k]),
        do: "`#{k}` erwartet Text, bekommen #{js_typ(f[k])}"
      ),
      for(
        k <- liste,
        Map.has_key?(f, k) and not is_list(f[k]),
        do: "`#{k}` erwartet Liste, bekommen #{js_typ(f[k])}"
      ),
      for(k <- @enum_reihe, enum_fehler?(f[k], Felder.enums()[k]), do: enum_text(k, f[k])),
      entscheidung_fehler(f, werkzeug),
      cast_fehler(s, f),
      offset_fehler(f),
      leer_fehler(f),
      if(is_list(f["source_refs"]), do: List.wrap(refs_fehler(s, f["source_refs"])), else: [])
    ])
  end

  defp enum_fehler?(v, erlaubt), do: is_binary(v) and v != "" and v not in erlaubt

  defp enum_text(k, v),
    do:
      "`#{k}` = #{Jason.encode!(v)} ist keiner der erlaubten Werte. " <>
        "Erlaubt: #{Enum.join(Felder.enums()[k], ", ")}"

  defp entscheidung_fehler(%{"entscheidung" => e}, "aussage_entscheiden")
       when is_binary(e) and e not in ["neu", "ersetzt"],
       do: [
         "`entscheidung` = #{Jason.encode!(e)} ist keiner der beiden Werte \"neu\" oder \"ersetzt\"."
       ]

  defp entscheidung_fehler(_f, _werkzeug), do: []

  defp cast_fehler(s, f) do
    character = if is_binary(f["character"]), do: f["character"], else: ""
    cast = if is_binary(f["cast_match"]), do: f["cast_match"], else: ""

    [
      String.contains?(character, "kein Cast") &&
        "`character` = #{Jason.encode!(character)} benennt keine Figur. " <>
          "Handelt in dieser Aussage niemand (Weltaussage), lass `character` leer (\"\").",
      String.trim(cast) == Stand.alter_escape() &&
        "`cast_match` = #{Jason.encode!(Stand.alter_escape())} gibt es nicht. " <>
          "Passt kein Eintrag aus cast(), lass das Feld leer (\"\").",
      (String.trim(cast) != Stand.alter_escape() and cast != "" and cast not in s.cast) &&
        "`cast_match` = #{Jason.encode!(cast)} steht nicht in cast(). " <>
          "Nimm einen Eintrag daraus in identischer Schreibweise, oder lass das " <>
          "Feld leer (\"\"), wenn keiner passt."
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp offset_fehler(%{"time_offset" => o}) when not is_nil(o) do
    if is_map(o) do
      einheiten = Felder.einheiten()

      if(is_integer(o["value"]), do: [], else: ["`time_offset.value` erwartet eine ganze Zahl"]) ++
        if o["unit"] in einheiten,
          do: [],
          else: [
            "`time_offset.unit` = #{js_json(o, "unit")} ist keine erlaubte Einheit. " <>
              "Erlaubt: #{Enum.join(einheiten, ", ")}"
          ]
    else
      ["`time_offset` erwartet ein Objekt {value, unit}"]
    end
  end

  defp offset_fehler(_f), do: []

  defp leer_fehler(f) do
    Enum.concat([
      if(leer?(f["claim"]), do: ["`claim` ist leer"], else: []),
      if(f["source_refs"] == [],
        do: ["`source_refs` ist leer. Nenne mindestens einen Block, aus dem die Aussage stammt."],
        else: []
      ),
      for(
        k <- ~w(narration_time time_anchor fact_type),
        leer?(f[k]),
        do: "`#{k}` ist leer. Erlaubt: #{Enum.join(Felder.enums()[k], ", ")}"
      ),
      if(leer?(f["beleg"]),
        do: [
          "`beleg` ist leer. Zitier aus jedem Block in source_refs die Stelle, die die Aussage trägt."
        ],
        else: []
      )
    ])
  end

  defp leer?(v), do: is_binary(v) and String.trim(v) == ""

  # Wie `typeof` in JavaScript, damit der Wortlaut der des Spikes bleibt.
  defp js_typ(v) when is_binary(v), do: "string"
  defp js_typ(v) when is_number(v), do: "number"
  defp js_typ(v) when is_boolean(v), do: "boolean"
  defp js_typ(_v), do: "object"

  defp js_json(map, k), do: if(Map.has_key?(map, k), do: Jason.encode!(map[k]), else: "undefined")

  defp refs_fehler(s, refs) do
    case Enum.reject(refs, &Map.has_key?(s.bloecke, &1)) do
      [] ->
        nil

      weg ->
        "`source_refs` nennt Blöcke, die es nicht gibt: #{Jason.encode!(weg)}. " <>
          if(s.beppo,
            do: "Nimm nur Blocknummern, die dir weiter() gezeigt hat.",
            else: "Gültig sind 0 bis #{s.max_block}."
          )
    end
  end
end
