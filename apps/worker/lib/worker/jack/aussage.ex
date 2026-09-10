defmodule Worker.Jack.Aussage do
  @moduledoc """
  `aussage` und `aussage_entscheiden`: eine Aussage einreichen und über eine
  Kollision mit dem Bestand entscheiden. Pur: Stand und Argumente hinein,
  neuer Stand und Antwort heraus.

  Portiert aus dem Werkzeug `aussage()` des Spikes. Die Reihenfolge der
  Prüfungen ist dieselbe: GUID-Verfall, Gerüst, Felder, Beleg, Versuchsdeckel,
  dann das Tor. Die Argumente sind bereits von der Laufzeit gegen
  `Worker.Jack.Felder` geprüft (Pflicht, Typen, Enums); hier folgt, was nur
  mit dem Stand prüfbar ist.

  **Abweichungen vom Spike, alle entschieden oder eine Folge davon:**

    * **Geteilt** (Tom): `einreichen/2` ist die erste Einreichung,
      `entscheiden/2` der Weg nach einer Vorlage (`neu` oder `ersetzt`). Im
      Spike steckten beide in einem Werkzeug mit sechs optionalen Feldern.
    * **Riegel auch bei „ersetzt“** (Tom): eine Fassung, die wortgleich an
      denselben Blöcken schon im Bestand steht, wird bei `neu` **und** bei
      `ersetzt` abgewiesen. Der Spike prüfte nur `neu`; über `ersetzt`
      entstand eine wortgleiche Dublette.
    * **Entschärfte Frageprüfung** (Tom), siehe `Worker.Jack.Beleg`.
    * `weitere_guids` ist Pflicht (Liste, darf leer sein) und wird bei `neu`
      mit Inhalt **abgelehnt** — der Spike überging es dort still.
    * Felder, die schon das Schema prüft, erreichen dieses Modul nicht; ihre
      Ablehnung kommt von der Laufzeit und zählt nicht in den Versuchsdeckel.

  Ergebnis: `{:ok, antwort}` bei `written`/`modify`, sonst `{:error, antwort}`
  — wer nichts eingetragen hat, meldet einen Fehler (Regel der
  Wiederholungssperre, #1197).
  """

  alias Worker.Jack.{Antwort, Beleg, Felder, Stand, Tor}

  @type ergebnis :: {Stand.t(), {:ok | :error, map()}}

  # ─── Einreichen ───────────────────────────────────────────────────────

  @doc "Eine Aussage einreichen (Werkzeug `aussage`)."
  @spec einreichen(Stand.t(), map()) :: ergebnis()
  def einreichen(%Stand{} = s, f) do
    s = Tor.verfallen_ausser(s, [])

    with {:ok, s} <- geruest(s, f),
         {:ok, s} <- form(s, f, "aussage") do
      case Tor.aehnliche(s, f["claim"], f["source_refs"], f["beleg"]) do
        [] -> neu_eintragen(s, f, nil)
        dups -> vorlegen(s, f, dups)
      end
    end
  end

  # ─── Entscheiden ──────────────────────────────────────────────────────

  @doc "Über eine Vorlage entscheiden (Werkzeug `aussage_entscheiden`)."
  @spec entscheiden(Stand.t(), map()) :: ergebnis()
  def entscheiden(%Stand{} = s, f) do
    gid = f["verifikations_guid"]
    ent = f["entscheidung"]
    weitere = f["weitere_guids"] || []
    s = Tor.verfallen_ausser(s, [gid | weitere])

    with {:ok, s} <- geruest(s, f),
         {:ok, s} <- form(s, f, "aussage_entscheiden"),
         {:ok, s, off} <- guid_gueltig(s, f, gid),
         {:ok, s} <- gebunden(s, f, gid, off),
         {:ok, s} <- riegel(s, f, gid, ent),
         {:ok, s} <- begruendung(s, f, ent),
         {:ok, s, weitere_nr} <- weitere_pruefen(s, f, gid, ent, weitere) do
      notiz = %{"art" => ent, "gegen" => off.nr, "grund" => String.trim(f["begruendung"])}
      s = Tor.verbrauchen(s, gid)

      case ent do
        "neu" -> neu_eintragen(s, f, notiz)
        "ersetzt" -> ersetzen(s, f, off.nr, notiz, weitere_nr)
      end
    end
  end

  # ─── Gemeinsame Prüfungen ─────────────────────────────────────────────

  defp geruest(s, f) do
    case Stand.geruest_fehlt(s) do
      [] ->
        {:ok, s}

      fehlt ->
        s =
          %{s | abgelehnt: s.abgelehnt + 1}
          |> Stand.journal("abgelehnt.jsonl", %{
            "fehler" => ["Geruest fehlt: " <> Enum.join(fehlt, ", ")],
            "feld" => f
          })

        {fehler, hinweis} = Antwort.geruest(s, fehlt)
        fehlschlag(s, "no_scaffold", [vorgelegt(f)], [fehler], hinweis)
    end
  end

  defp form(s, f, werkzeug) do
    fehler = inhalt_fehler(s, f)
    fehler = if fehler == [], do: beleg_fehler(s, f), else: fehler

    if fehler == [] do
      {:ok, s}
    else
      schluessel = String.slice(f["claim"] || "", 0, 60)
      n = Map.get(s.versuche, schluessel, 0) + 1
      aufgegeben? = n >= Stand.deckel()

      s =
        %{s | versuche: Map.put(s.versuche, schluessel, n), abgelehnt: s.abgelehnt + 1}
        |> Stand.journal(
          "abgelehnt.jsonl",
          Map.merge(%{"versuch" => n, "fehler" => fehler, "feld" => f}, aufgegeben(aufgegeben?))
        )

      if aufgegeben? do
        fehlschlag(
          s,
          "exhausted",
          [vorgelegt(f)],
          fehler,
          "Nichts eingetragen. Das war dein #{n}. vergeblicher Versuch mit dieser " <>
            "Aussage. Lass sie weg und mach mit der nächsten weiter — im Protokoll " <>
            "steht sie als aufgegeben."
        )
      else
        fehlschlag(
          s,
          "fix",
          [vorgelegt(f)],
          fehler,
          "Nichts eingetragen. Korrigiere die genannten Felder und rufe #{werkzeug}() erneut auf."
        )
      end
    end
  end

  defp aufgegeben(true), do: %{"aufgegeben" => true}
  defp aufgegeben(false), do: %{}

  defp inhalt_fehler(s, f) do
    character = f["character"] || ""
    cast = f["cast_match"] || ""
    refs = f["source_refs"] || []

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
          "Feld leer (\"\"), wenn keiner passt.",
      refs_fehler(s, refs)
    ]
    |> Enum.filter(&is_binary/1)
  end

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

  # Belegzwang: der Text der unzitierten Blöcke geht gleich mit, sonst kostet
  # jede Ablehnung einen zusätzlichen block()-Aufruf (Spike: sechs block()-
  # Aufrufe in fünf Durchgängen — das Nachschlagen wurde ausgelassen).
  defp beleg_fehler(s, f) do
    refs = f["source_refs"] || []

    case refs != [] && Beleg.fehler(f["beleg"], refs, s.bloecke) do
      list when is_list(list) ->
        pr = Beleg.pruefen(f["beleg"], refs, s.bloecke)

        list ++
          for r <- Enum.take(pr.refs_ohne_zitat, 3) do
            b = Stand.block(s, r) || %{}

            "Block #{r} lautet: " <>
              Jason.encode!("#{b[:sprecher] || ""}: " <> String.slice(b[:text] || "", 0, 240))
          end

      _ ->
        []
    end
  end

  # ─── Tor: Vorlage bei der Einreichung ─────────────────────────────────

  defp vorlegen(s, f, dups) do
    refs = f["source_refs"] || []
    s = %{s | abgelehnt: s.abgelehnt + 1}

    {vorlagen, s} =
      Enum.map_reduce(dups, s, fn d, s ->
        {g, s} = Stand.guid(s)

        s =
          s
          |> Tor.ausgeben(g, %{nr: d.nr, refs: refs})
          |> Map.update!(:kollisionen, &Map.update(&1, d.nr, 1, fn k -> k + 1 end))
          |> bestaetigen(d, f)
          |> Stand.journal("dubletten.jsonl", %{
            "iter" => s.durchgang,
            "guid" => g,
            "gegen" => d.nr,
            "neu" => f["claim"],
            "bestehend" => d.voll["claim"]
          })

        {Antwort.als_eintrag(Stand.bestand_von(s, d.nr), "bestehend", g), s}
      end)

    fehlschlag(
      s,
      "verify",
      [vorgelegt(f) | vorlagen],
      [],
      Antwort.verifikations_hinweis(length(vorlagen))
    )
  end

  # Wie oft hat ein späterer Versuch die Aussage unabhängig wiedergefunden?
  # Steht im Datensatz als `_bestaetigt`: Zahl der Durchgänge, die sie fanden.
  defp bestaetigen(s, d, f) do
    if Tor.bestaetigung?(d.voll, f["claim"], f["source_refs"]) do
      b = Map.get(s.bestaetigt, d.nr, 0) + 1
      s = %{s | bestaetigt: Map.put(s.bestaetigt, d.nr, b)}

      case Stand.bestand_von(s, d.nr) do
        nil -> s
        alt -> Stand.ersetzen(s, d.nr, Map.put(alt, "_bestaetigt", b + 1))
      end
    else
      s
    end
  end

  # ─── Tor: Entscheidung über eine Vorlage ──────────────────────────────

  defp guid_gueltig(s, f, gid) do
    case Tor.offen(s, gid) do
      nil ->
        schicksal = Tor.schicksal(s, gid)
        art = if schicksal, do: :expired, else: :fraud
        s = guid_abgewiesen(s, art, "verifikations_guid", gid, schicksal, f)
        {fehler, hinweis} = Antwort.guid_problem(s, art, "verifikations_guid", 0, schicksal)
        fehlschlag(s, Atom.to_string(art), [vorgelegt(f)], [fehler], hinweis)

      off ->
        {:ok, s, off}
    end
  end

  defp guid_abgewiesen(s, art, feld, gid, schicksal, f) do
    s = %{s | abgelehnt: s.abgelehnt + 1, geraten: s.geraten + if(schicksal, do: 0, else: 1)}

    herkunft =
      if schicksal,
        do: %{"schicksal" => Atom.to_string(schicksal)},
        else: %{"geraten" => gid, "versuch" => s.geraten}

    Stand.journal(
      s,
      "dubletten.jsonl",
      Map.merge(
        %{
          "iter" => s.durchgang,
          "guid_problem" => Atom.to_string(art),
          "feld" => feld,
          "guid" => gid,
          "claim" => f["claim"]
        },
        herkunft
      )
    )
  end

  # Die GUID gilt für DIESE Stelle: mindestens ein Block gemeinsam mit den
  # Fundstellen des Aufrufs, der die Vorlage ausgelöst hat (Spike, 09.09.:
  # mit einer GUID für Block 167 wurde eine Aussage über Block 160/162
  # eingetragen und eine fremde überschrieben).
  defp gebunden(s, f, gid, off) do
    jetzt = f["source_refs"] || []
    gebunden = off.refs

    if (gebunden == [] and jetzt == []) or Enum.any?(jetzt, &(&1 in gebunden)) do
      {:ok, s}
    else
      s = %{s | abgelehnt: s.abgelehnt + 1} |> Tor.verbrauchen(gid)

      {vorlagen, s} =
        s
        |> Tor.aehnliche(f["claim"], jetzt, f["beleg"])
        |> Enum.map_reduce(s, fn d, s ->
          {g, s} = Stand.guid(s)
          s = Tor.ausgeben(s, g, %{nr: d.nr, refs: jetzt})
          {Antwort.als_eintrag(Stand.bestand_von(s, d.nr), "bestehend", g), s}
        end)

      s =
        Stand.journal(s, "dubletten.jsonl", %{
          "iter" => s.durchgang,
          "guid_passt_nicht" => off.nr,
          "gebunden" => gebunden,
          "jetzt" => jetzt,
          "claim" => f["claim"]
        })

      fehler =
        "Die verifikations_guid gehört zu Block #{liste(gebunden)}, deine Aussage steht " <>
          "an Block #{liste(jetzt)}. Eine GUID gilt nur für Aussagen an derselben Stelle — " <>
          "mindestens ein Block muss gemeinsam sein."

      fehlschlag(s, "misplaced", [vorgelegt(f) | vorlagen], [fehler], misplaced_hinweis(vorlagen))
    end
  end

  defp misplaced_hinweis([]) do
    "Nichts eingetragen; die GUID ist damit eingelöst.\n" <>
      "An deiner Stelle steht nichts, das deiner Aussage ähnelt. So geht es weiter: " <>
      "reich sie mit aussage() ein — dann wird sie eingetragen."
  end

  defp misplaced_hinweis(vorlagen) do
    kopf =
      if length(vorlagen) == 1,
        do: "An deiner Stelle gibt es aber eine mögliche Übereinstimmung — verifiziere.",
        else: "An deiner Stelle gibt es aber mögliche Übereinstimmungen — verifiziere."

    "Nichts eingetragen; die GUID ist damit eingelöst.\n" <>
      Antwort.verifikations_hinweis(length(vorlagen), kopf)
  end

  defp liste([]), do: "—"
  defp liste(refs), do: Enum.join(refs, ", ")

  # Wortgleich UND dieselben Fundstellen: nichts abzuwägen, gegen den ganzen
  # Bestand. Seit Toms Entscheidung für "neu" und "ersetzt".
  defp riegel(s, f, gid, ent) do
    gl = Tor.refs_schluessel(f["source_refs"])
    claim = Beleg.norm(f["claim"] || "")

    zwilling =
      gl != "" &&
        Enum.find(s.eingetragen, fn alt ->
          Tor.refs_schluessel(alt.voll["source_refs"]) == gl and
            Beleg.norm(alt.voll["claim"] || "") == claim
        end)

    if zwilling do
      s =
        %{s | abgelehnt: s.abgelehnt + 1}
        |> Tor.verbrauchen(gid)
        |> Stand.journal("dubletten.jsonl", %{
          "iter" => s.durchgang,
          "hart_abgelehnt" => zwilling.nr,
          "claim" => f["claim"]
        })

      fehler =
        "Wortgleich mit der Aussage, die oben als „identisch“ steht, und aus denselben " <>
          "Blöcken (#{gl}). Das ist dieselbe Aussage, kein zweiter Fund."

      fehlschlag(
        s,
        "verify",
        [vorgelegt(f), Antwort.als_eintrag(zwilling.voll, "identisch")],
        [],
        fehler <> "\n" <> identisch_hinweis(ent)
      )
    else
      {:ok, s}
    end
  end

  defp identisch_hinweis("ersetzt") do
    "Deine Fassung unterscheidet sich im Wortlaut nicht von der bestehenden — es gibt " <>
      "nichts zu ersetzen. Mach mit deiner nächsten Aussage weiter."
  end

  defp identisch_hinweis(_neu) do
    "Deine Aussage steht damit schon im Bestand — reich sie nicht noch einmal ein und " <>
      "mach mit deiner nächsten Aussage weiter. Wolltest du etwas anderes sagen, " <>
      "formuliere es so, dass der Unterschied im Satz steht; ist deine Fassung besser " <>
      "belegt, nimm entscheidung: \"ersetzt\"."
  end

  # Die Begründung ist Pflicht und reist mit der Aussage in den Bestand —
  # sonst weiß später niemand, warum zwei ähnliche Aussagen dort stehen.
  defp begruendung(s, f, ent) do
    if String.length(String.trim(f["begruendung"] || "")) >= 10 do
      {:ok, s}
    else
      hinweis =
        if ent == "neu",
          do:
            "Sag in einem Satz, worin sich deine Aussage von der vorgelegten " <>
              "unterscheidet — genau der Unterschied, der sie zu einer eigenen " <>
              "Aussage macht. Die genannten GUIDs gelten weiter — ruf mit " <>
              "genau denselben noch einmal auf.",
          else:
            "Sag in einem Satz, was deine Fassung besser macht — genauer " <>
              "belegt, vollständiger, richtiger zugeordnet. Die genannten " <>
              "GUIDs gelten weiter — ruf mit genau denselben noch einmal auf."

      fehlschlag(
        %{s | abgelehnt: s.abgelehnt + 1},
        "fix",
        [vorgelegt(f)],
        ["`begruendung` fehlt oder ist zu knapp."],
        hinweis
      )
    end
  end

  defp weitere_pruefen(s, _f, _gid, "neu", []), do: {:ok, s, []}

  defp weitere_pruefen(s, f, _gid, "neu", _weitere) do
    fehlschlag(
      %{s | abgelehnt: s.abgelehnt + 1},
      "fix",
      [vorgelegt(f)],
      ["`weitere_guids` gibt es nur bei entscheidung \"ersetzt\"."],
      "Nichts eingetragen. Bei entscheidung \"neu\" bleibt weitere_guids leer ([]). " <>
        "Die genannten GUIDs gelten weiter — ruf noch einmal auf."
    )
  end

  # Erst alle prüfen, dann einlösen: eine ungültige GUID am Ende darf die
  # gültigen davor nicht verbrauchen (Spike, bis 10.09.).
  defp weitere_pruefen(s, f, gid, "ersetzt", weitere) do
    jetzt = f["source_refs"] || []

    weitere
    |> Enum.with_index(1)
    |> Enum.reject(fn {wg, _} -> wg == gid end)
    |> Enum.reduce_while({:ok, []}, fn {wg, pos}, {:ok, gut} ->
      case Tor.offen(s, wg) do
        nil ->
          {:halt, {:ungueltig, wg, pos}}

        w ->
          if w.refs != [] and not Enum.any?(jetzt, &(&1 in w.refs)),
            do: {:halt, {:falsche_stelle, w, pos}},
            else: {:cont, {:ok, gut ++ [{wg, w}]}}
      end
    end)
    |> case do
      {:ok, gut} ->
        s = Enum.reduce(gut, s, fn {wg, _}, s -> Tor.verbrauchen(s, wg) end)
        {:ok, s, Enum.map(gut, fn {_, w} -> w.nr end)}

      {:ungueltig, wg, pos} ->
        schicksal = Tor.schicksal(s, wg)
        art = if schicksal, do: :expired, else: :fraud
        s = guid_abgewiesen(s, art, "weitere_guids", wg, schicksal, f)
        {fehler, hinweis} = Antwort.guid_problem(s, art, "weitere_guids", pos, schicksal)
        fehlschlag(s, Atom.to_string(art), [vorgelegt(f)], [fehler], hinweis)

      {:falsche_stelle, w, pos} ->
        fehlschlag(
          %{s | abgelehnt: s.abgelehnt + 1},
          "misplaced",
          [vorgelegt(f)],
          [
            "Die #{pos}. GUID in weitere_guids gehört zu Block #{Enum.join(w.refs, ", ")}, " <>
              "deine Aussage steht an Block #{Enum.join(jetzt, ", ")}."
          ],
          "Nichts eingetragen.\nDie übrigen GUIDs, die du in diesem Aufruf genannt hast, " <>
            "gelten weiter."
        )
    end
  end

  # ─── Schreiben ────────────────────────────────────────────────────────

  defp neu_eintragen(s, f, notiz) do
    schluessel = String.slice(f["claim"] || "", 0, 60)
    nummer = s.lfd + 1

    rec =
      f
      |> Map.drop(Felder.steuerfelder())
      |> Map.merge(%{
        "nummer" => nummer,
        "_belegt" => true,
        "_versuche" => Map.get(s.versuche, schluessel, 0) + 1,
        "_pos" => Beleg.pos_von(f["source_refs"]),
        "_iter" => s.durchgang,
        "_iter0" => s.durchgang
      })
      |> then(&if(notiz, do: Map.put(&1, "entscheidung", notiz), else: &1))

    s =
      %{s | lfd: nummer}
      |> Stand.eintragen(rec)
      |> nach_dem_schreiben(f, schluessel)

    erfolg(s, "written", [Antwort.als_eintrag(rec, "neu")], ["Gespeichert."], f)
  end

  defp ersetzen(s, f, nr, notiz, weitere_nr) do
    schluessel = String.slice(f["claim"] || "", 0, 60)
    vorher = Stand.bestand_von(s, nr) || %{}

    rec =
      f
      |> Map.drop(Felder.steuerfelder())
      |> Map.merge(%{
        "nummer" => nr,
        "_belegt" => true,
        "_ersetzt" => true,
        # Immer gesetzt: ersetzt wird nur über aussage_entscheiden. Der Spike
        # fiel auf die alte Entscheidung zurück, weil sein einziges Werkzeug
        # beide Wege kannte.
        "entscheidung" => notiz,
        "_pos" => Beleg.pos_von(f["source_refs"]),
        "_iter" => s.durchgang,
        "_iter0" => vorher["_iter0"] || vorher["_iter"] || s.durchgang
      })

    s =
      s
      |> Stand.ersetzen(nr, rec)
      |> verwerfen(weitere_nr, nr, notiz["grund"])
      |> nach_dem_schreiben(f, schluessel)

    weg =
      case length(weitere_nr) do
        0 ->
          ""

        1 ->
          " Die Aussage aus weitere_guids wurde verworfen und verweist auf " <>
            "deine; ihr Wortlaut bleibt lesbar, zählt aber nicht mehr."

        n ->
          " Die #{n} Aussagen aus weitere_guids wurden verworfen und " <>
            "verweisen auf deine; ihr Wortlaut bleibt lesbar, zählt aber nicht mehr."
      end

    aussagen =
      [Antwort.als_eintrag(rec, "ersetzt")] ++
        Enum.map(weitere_nr, &Antwort.als_eintrag(Stand.bestand_von(s, &1), "verworfen"))

    erfolg(
      s,
      "modify",
      aussagen,
      ["Gespeichert: deine Fassung steht jetzt an Stelle der bestehenden." <> weg],
      f
    )
  end

  # Verwerfen, nicht löschen: der Wortlaut bleibt lesbar, die Nummer verweist
  # auf die Fassung, die ihn abgelöst hat.
  defp verwerfen(s, weitere_nr, durch, grund) do
    Enum.reduce(weitere_nr, s, fn wn, s ->
      case Stand.bestand_von(s, wn) do
        %{"_verworfen" => true} ->
          s

        nil ->
          s

        alt ->
          s
          |> Stand.ersetzen(
            wn,
            Map.merge(alt, %{
              "_verworfen" => true,
              "_grund" => "abgeloest von ##{durch}: #{grund}",
              "_abgeloest_von" => durch,
              "_iter" => s.durchgang
            })
          )
          |> Stand.journal("dubletten.jsonl", %{
            "iter" => s.durchgang,
            "abgeloest" => wn,
            "durch" => durch,
            "grund" => grund
          })
      end
    end)
  end

  defp nach_dem_schreiben(s, f, schluessel) do
    %{s | versuche: Map.delete(s.versuche, schluessel)}
    |> Stand.belegte_merken(f["source_refs"])
    |> Stand.themen_merken(f["threads"] || [])
  end

  # ─── Antworten ────────────────────────────────────────────────────────

  defp erfolg(s, outcome, aussagen, kopf, f) do
    hinweis =
      (kopf ++ [rueckbezug_hinweis(f), "Mach mit deiner nächsten Aussage weiter."])
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")

    {s, {:ok, Antwort.einheitlich(s, outcome, aussagen, [], hinweis)}}
  end

  defp rueckbezug_hinweis(f) do
    case Beleg.rueckbezug(f["claim"], f["source_refs"] || []) do
      nil ->
        nil

      wort ->
        "Der claim enthaelt #{Jason.encode!(wort)} und nennt nur einen Block. " <>
          "Wenn sich das Wort auf eine fruehere Stelle bezieht, ist die Aussage " <>
          "ohne diese Stelle nicht belegt: such sie mit suche(), lies sie mit " <>
          "block(nummer) und trage die Aussage mit BEIDEN Blocknummern erneut ein. " <>
          "Bezieht es sich auf nichts Frueheres, lass es so."
    end
  end

  defp fehlschlag(s, outcome, aussagen, fehler, hinweis),
    do: {s, {:error, Antwort.einheitlich(s, outcome, aussagen, fehler, hinweis)}}

  defp vorgelegt(f), do: Antwort.als_eintrag(f, "vorgelegt")
end
