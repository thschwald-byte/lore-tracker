defmodule Worker.Jack.Resuemee.Entwurf do
  @moduledoc """
  Die schreibenden Werkzeuge des Resümee-Jack im zweiten Lauf, dem
  Schreiben (J5, #1209, B2): `absatz`, `absatz_ersetzen`,
  `absatz_streichen` und `entwurf`. Pur wie `Worker.Jack.Resuemee.Notizen`:
  Stand und Argumente hinein, neuer Stand und Ergebnis heraus.

  **Die Prüfeinheit ist der Satz** (Maintainer). Jeder Satz nennt die
  kurzen IDs der Fakten, auf die er sich stützt, und trägt höchstens eine
  von zwei Markierungen:

    * nennt er einen Fakt **dieser** Sitzung, braucht er keine — Fakten
      früherer Sitzungen dürfen dazukommen;
    * nennt er **nur** Fakten früherer Sitzungen, ist er ein Rückblick
      (`rueckblick: true`);
    * nennt er **keinen** Fakt, ist er ein Übergang (`uebergang: true`).

  Jede andere Kombination wird abgelehnt, mit der Regel, die sie verletzt:
  eine Markierung, die den Fakten widerspricht, ist ebenso ein Fehler wie
  eine fehlende. Jede genannte ID muss es geben, in dieser oder einer
  früheren Sitzung (`Worker.Jack.Resuemee.Stand.fakt/2`); gespeichert wird
  die Schreibweise des Bestands, doppelte fallen weg.

  **Keine Namensprüfung.** Jack darf formulieren (Maintainer): geprüft wird,
  worauf ein Satz sich stützt, nicht, welche Wörter er benutzt. Der Stoff
  sind die Fakten; fehlt einer, gehört die Stelle in
  `fertig(offen_geblieben)` statt in einen Satz.

  **Die Länge (#1209).** `max_woerter` (Länge aus „Stil setzen“, Standard
  150) ist das Ziel, das Doppelte die Obergrenze; gezählt wird über alle
  Satztexte und Absatztitel (`Worker.Jack.Resuemee.Stand.woerter/1`). Jede
  Antwort von `absatz`, `absatz_ersetzen`, `absatz_streichen` und `entwurf`
  nennt den Wortstand als „X Wörter — Ziel M, höchstens 2M“. `absatz` und
  `absatz_ersetzen` tragen einen Absatz auch über Ziel und Obergrenze ein —
  sonst könnte Jack nie umformulieren, ohne vorher zu streichen —, die
  Antwort warnt dann, über der Obergrenze deutlich
  (`Worker.Jack.Resuemee.Laenge`). Hart ist die Länge in `fertig`
  (`Worker.Jack.Resuemee.Abschluss`: über dem Ziel nur mit
  `laenge_begruendung`, über der Obergrenze nie) und in der Durchsicht, die
  keinen Absatz über die Obergrenze ersetzt.

  **Der Weg der Gruppe (#1209).** Die Antworten und `entwurf()` nennen die
  Stationen der GLIEDERUNG, die noch keinen Satz haben
  (`Worker.Jack.Resuemee.Weg`); `fertig` lehnt ab, solange eine fehlt.

  **Ganz oder gar nicht.** Ein Absatz mit einem abgelehnten Satz geht nicht
  halb in den Entwurf. Die Antwort nennt jeden abgelehnten Satz mit seiner
  Nummer im Absatz (ab 1), seinem Anfang und den Gründen; der
  Journal-Eintrag (`journal_datei/0`) hält die Gründe als Codes fest, für
  die Auswertung (`Worker.Jack.Resuemee.Ergebnis.zaehlwerte/1`).

  **Benannte Grenzen.** Ein Satz hat höchstens 80 Wörter — sonst ginge ein
  ganzer Absatz als ein „Satz“ an der Prüfung je Satz vorbei; großzügig,
  damit ein langer erzählender Satz durchgeht. Ein Titel hat höchstens 12
  Wörter: er ist ungeprüfter Text und bleibt eine Überschrift. Beides sind
  gegriffene Zahlen, keine gemessenen.

  **Ehrliche Grenzen.** Ein Übergang ist ungeprüfter Text; dass er nur
  verbindet und keinen Stoff erfindet, prüft kein Werkzeug. Die Zahl der
  Übergänge steht deshalb im Abbild und in den Zählwerten; hin sieht die
  Durchsicht (`Worker.Jack.Resuemee.Durchsicht`, B3) — gnädig, mit
  Hinweisen statt Ablehnungen. Ebenso prüft kein Code, ob ein Satz sagt, was
  seine Fakten sagen — nur, dass er welche nennt.

  Die Durchsicht benutzt `absatz_ersetzen/2` und `absatz_streichen/2` von
  hier, damit ein ersetzter Absatz dieselbe Prüfung durchläuft.
  """

  alias Worker.Jack.Antwort
  alias Worker.Jack.Resuemee.{Laenge, Stand, Weg}

  @max_woerter 80
  @max_titel_woerter 12
  @kurz_woerter 30
  @anfang_woerter 8
  @journal "entwurf_verlauf.jsonl"
  @optional ["titel", "saetze.uebergang", "saetze.rueckblick"]

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Die Datei im Journal, in die dieses Modul schreibt."
  @spec journal_datei() :: String.t()
  def journal_datei, do: @journal

  @doc "Die Höchstzahl der Wörter eines Satzes."
  @spec max_woerter() :: pos_integer()
  def max_woerter, do: @max_woerter

  @doc "Die optionalen Felder eines Absatzes (Titel und die Markierungen je Satz)."
  @spec optional() :: [String.t()]
  def optional, do: @optional

  @doc "Die Werkzeuge dieses Moduls für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{} = s) do
    [
      %{
        name: "absatz",
        beschreibung:
          "Hängt einen Absatz ans Ende des Entwurfs. titel ist optional — ohne ihn ist der " <>
            "Absatz Fließtext. saetze: jeder Satz mit text und den IDs der Fakten, auf die er " <>
            "sich stützt (fakten, erste Spalte von fakten()). Ein Satz mit einem Fakt dieser " <>
            "Sitzung braucht keine Markierung; einer, der nur Fakten früherer Sitzungen nennt, " <>
            "trägt rueckblick: true; einer ohne Fakten verbindet nur und trägt uebergang: true. " <>
            "Ein Absatz geht nur ganz in den Entwurf: ist ein Satz nicht in Ordnung, nennt die " <>
            "Antwort ihn mit dem Grund, und du schickst den Absatz vollständig noch einmal. " <>
            "Die Antwort nennt den Wortstand — Ziel #{s.max_woerter} Wörter, höchstens " <>
            "#{Stand.obergrenze(s)} — und die Stationen deiner GLIEDERUNG, die noch keinen " <>
            "Satz haben.",
        parameter: absatz_schema(%{}),
        optional: @optional,
        aendert_bestand: true,
        ausfuehren: &absatz/2
      },
      %{
        name: "absatz_ersetzen",
        beschreibung:
          "Ersetzt Absatz nummer (aus entwurf()) durch einen neuen, geprüft wie absatz(). " <>
            "Der Absatz behält seinen Platz.",
        parameter: absatz_schema(%{"nummer" => nummer_schema()}),
        optional: @optional,
        aendert_bestand: true,
        ausfuehren: &absatz_ersetzen/2
      },
      %{
        name: "absatz_streichen",
        beschreibung:
          "Streicht Absatz nummer (aus entwurf()). Die Absätze dahinter rücken um eins nach vorn.",
        parameter: %{"type" => "object", "properties" => %{"nummer" => nummer_schema()}},
        aendert_bestand: true,
        ausfuehren: &absatz_streichen/2
      },
      %{
        name: "entwurf",
        beschreibung:
          "Gibt deinen Entwurf zurück: jeden Absatz mit Nummer und Titel, jeden Satz mit " <>
            "seinen Fakten und Markierungen, dazu welche Handlungsbögen noch keinen Satz haben.",
        parameter: %{"type" => "object", "properties" => %{}},
        wiederholung: :frei,
        ausfuehren: &entwurf/2
      }
    ]
  end

  defp nummer_schema,
    do: %{"type" => "integer", "minimum" => 1, "description" => "die Nummer aus entwurf()"}

  @doc """
  Das Schema eines Absatzes (`titel`, `saetze`), dazu die Felder aus
  `extra` — für `absatz_ersetzen` die `nummer`, in der Durchsicht dazu der
  `grund`.
  """
  @spec absatz_schema(map()) :: map()
  def absatz_schema(extra) do
    %{
      "type" => "object",
      "properties" =>
        Map.merge(
          %{
            "titel" => %{
              "type" => "string",
              "minLength" => 1,
              "description" => "Überschrift des Absatzes; ohne sie ist der Absatz Fließtext"
            },
            "saetze" => %{
              "type" => "array",
              "minItems" => 1,
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "text" => %{
                    "type" => "string",
                    "description" => "der Satz, wie er im Resümee steht"
                  },
                  "fakten" => %{
                    "type" => "array",
                    "items" => %{"type" => "string"},
                    "description" =>
                      "die IDs der Fakten, auf die sich der Satz stützt; [] bei einem Übergang"
                  },
                  "uebergang" => %{
                    "type" => "boolean",
                    "description" => "true: der Satz verbindet nur und nennt keinen Fakt"
                  },
                  "rueckblick" => %{
                    "type" => "boolean",
                    "description" =>
                      "true: der Satz stützt sich nur auf Fakten früherer Sitzungen"
                  }
                }
              }
            }
          },
          extra
        )
    }
  end

  # ─── absatz, absatz_ersetzen, absatz_streichen ────────────────────────

  @doc "Einen Absatz ans Ende des Entwurfs hängen (Werkzeug `absatz`)."
  @spec absatz(Stand.t(), map()) :: ergebnis()
  def absatz(%Stand{} = s, p) do
    case pruefen(s, p) do
      {:ok, neu} ->
        nr = length(s.entwurf) + 1

        s =
          %{s | entwurf: s.entwurf ++ [neu]}
          |> Stand.journal(@journal, %{"art" => "+", "absatz" => nr, "neu" => als_json(neu)})

        {s, {:ok, eingetragen(s, nr, "Eingetragen als Absatz #{nr}.")}}

      {:abgelehnt, a} ->
        ablehnen(s, "absatz", nil, a)
    end
  end

  @doc "Einen Absatz ersetzen (Werkzeug `absatz_ersetzen`)."
  @spec absatz_ersetzen(Stand.t(), map()) :: ergebnis()
  def absatz_ersetzen(%Stand{} = s, %{"nummer" => nr} = p) do
    if nummer_da?(s, nr) do
      alt = Enum.at(s.entwurf, nr - 1)

      case pruefen(s, p) do
        {:ok, ^alt} ->
          {s,
           {:error,
            "Absatz #{nr} steht bereits genau so — nichts geändert. Nimm dir den nächsten " <>
              "Schritt vor."}}

        {:ok, neu} ->
          s =
            %{s | entwurf: List.replace_at(s.entwurf, nr - 1, neu)}
            |> Stand.journal(@journal, %{
              "art" => "~",
              "absatz" => nr,
              "neu" => als_json(neu),
              "vorher" => als_json(alt)
            })

          {s, {:ok, eingetragen(s, nr, "Absatz #{nr} ersetzt.")}}

        {:abgelehnt, a} ->
          ablehnen(s, "absatz_ersetzen", nr, a)
      end
    else
      {s, {:error, keine_nummer(s, nr)}}
    end
  end

  @doc "Einen Absatz streichen (Werkzeug `absatz_streichen`)."
  @spec absatz_streichen(Stand.t(), map()) :: ergebnis()
  def absatz_streichen(%Stand{} = s, %{"nummer" => nr}) do
    if nummer_da?(s, nr) do
      alt = Enum.at(s.entwurf, nr - 1)

      s =
        %{s | entwurf: List.delete_at(s.entwurf, nr - 1)}
        |> Stand.journal(@journal, %{"art" => "-", "absatz" => nr, "vorher" => als_json(alt)})

      hinweis =
        if nr <= length(s.entwurf),
          do:
            "Absatz #{nr} gestrichen. Die Absätze dahinter sind um eins nach vorn gerückt: " <>
              "der bisherige Absatz #{nr + 1} ist jetzt Absatz #{nr}.",
          else: "Absatz #{nr} gestrichen."

      {s,
       {:ok,
        Antwort.geordnet([
          {"ok", true},
          {"gestrichen", nr},
          {"entwurf", zahlen_text(s)},
          {"woerter", Stand.woerter_text(s)},
          {"woerter_je_absatz", nil_wenn_leer(Laenge.je_absatz(s))},
          {"warnung", Laenge.warnung(s)},
          {"stationen_ohne_satz", stationen_ohne_satz(s)},
          {"handlungsboegen_ohne_satz", nil_wenn_leer(Stand.arc_ohne_satz(s))},
          {"hinweis", hinweis}
        ])}}
    else
      {s, {:error, keine_nummer(s, nr)}}
    end
  end

  defp stationen_ohne_satz(s),
    do: s |> Weg.ohne_satz() |> Enum.map(&"#{&1.schluessel} — #{&1.zeile}") |> nil_wenn_leer()

  defp nummer_da?(s, nr), do: is_integer(nr) and nr >= 1 and nr <= length(s.entwurf)

  defp keine_nummer(%Stand{entwurf: []}, nr),
    do:
      "Einen Absatz #{nr} gibt es nicht — der Entwurf ist noch leer. Leg Absätze mit absatz() an."

  defp keine_nummer(s, nr),
    do:
      "Einen Absatz #{nr} gibt es nicht. Der Entwurf hat die Absätze 1 bis " <>
        "#{length(s.entwurf)}; entwurf() zeigt sie."

  defp eingetragen(s, nr, hinweis) do
    Antwort.geordnet([
      {"ok", true},
      {"absatz", nr},
      {"saetze", length(Enum.at(s.entwurf, nr - 1).saetze)},
      {"entwurf", zahlen_text(s)},
      {"woerter", Stand.woerter_text(s)},
      {"woerter_je_absatz", Laenge.je_absatz(s)},
      {"warnung", Laenge.warnung(s)},
      {"stationen_ohne_satz", stationen_ohne_satz(s)},
      {"handlungsboegen_ohne_satz", nil_wenn_leer(Stand.arc_ohne_satz(s))},
      {"hinweis", hinweis}
    ])
  end

  defp ablehnen(s, werkzeug, nr, %{titel: tg, saetze: sg}) do
    s =
      Stand.journal(s, @journal, %{
        "art" => "abgelehnt",
        "werkzeug" => werkzeug,
        "absatz" => nr,
        "titel_gruende" => Enum.map(tg, &elem(&1, 0)),
        "saetze" =>
          Enum.map(
            sg,
            &%{"satz" => &1.satz, "gruende" => Enum.map(&1.gruende, fn {c, _} -> c end)}
          )
      })

    {s,
     {:error,
      Antwort.geordnet([
        {"ok", false},
        {"hinweis",
         "Nichts eingetragen: ein Absatz geht nur ganz in den Entwurf. Bring die genannten " <>
           "Stellen in Ordnung und schick den Absatz noch einmal vollständig, mit allen Sätzen."},
        {"titel", nil_wenn_leer(Enum.map(tg, &elem(&1, 1)))},
        {"abgelehnt",
         nil_wenn_leer(
           Enum.map(sg, fn a ->
             Antwort.geordnet([
               {"satz", a.satz},
               {"anfang", a.anfang},
               {"gruende", Enum.map(a.gruende, &elem(&1, 1))}
             ])
           end)
         )}
      ])}}
  end

  # ─── Prüfung ──────────────────────────────────────────────────────────

  # Ein Absatz: {:ok, absatz} oder {:abgelehnt, %{titel: [{code, text}],
  # saetze: [%{satz:, anfang:, gruende:}]}}.
  defp pruefen(s, p) do
    {titel, titel_gruende} = titel_pruefen(p["titel"])

    geprueft =
      p["saetze"]
      |> Enum.with_index(1)
      |> Enum.map(fn {roh, i} -> {i, roh, satz_pruefen(s, roh)} end)

    abgelehnt =
      for {i, roh, {:abgelehnt, g}} <- geprueft,
          do: %{satz: i, anfang: anfang(roh["text"]), gruende: g}

    if titel_gruende == [] and abgelehnt == [] do
      {:ok, %{titel: titel, saetze: for({_, _, {:ok, satz}} <- geprueft, do: satz)}}
    else
      {:abgelehnt, %{titel: titel_gruende, saetze: abgelehnt}}
    end
  end

  defp titel_pruefen(nil), do: {nil, []}

  defp titel_pruefen(roh) do
    t = zusammenziehen(roh)
    n = woerter(t)

    cond do
      t == "" ->
        {nil,
         [
           {"titel_leer",
            "Der Titel ist leer. Für einen Absatz Fließtext lässt du titel ganz weg; sonst " <>
              "schreib die Überschrift hin."}
         ]}

      n > @max_titel_woerter ->
        {nil,
         [
           {"titel_zu_lang",
            "Der Titel hat #{n} Wörter, eine Überschrift hat höchstens #{@max_titel_woerter}. " <>
              "Was er erzählt, gehört als Satz mit seinen Fakten in den Absatz."}
         ]}

      true ->
        {t, []}
    end
  end

  @doc """
  Prüft einen Satz (`%{"text", "fakten", "uebergang"?, "rueckblick"?}`)
  gegen die Regeln im Moduldoc. Liefert `{:ok, satz}`
  (`t:Worker.Jack.Resuemee.Stand.satz/0`) oder `{:abgelehnt, [{code, text}]}`.
  Die Codes: `leer`, `zu_lang`, `fakt_unbekannt`, `uebergang_mit_fakten`,
  `rueckblick_mit_fakt_dieser_sitzung`, `rueckblick_fehlt`,
  `rueckblick_ohne_fakten`, `uebergang_fehlt`. Ist eine ID unbekannt, werden
  die Markierungen nicht geprüft — sie hängen an den Fakten.
  """
  @spec satz_pruefen(Stand.t(), map()) ::
          {:ok, Stand.satz()} | {:abgelehnt, [{String.t(), String.t()}]}
  def satz_pruefen(%Stand{} = s, roh) do
    text = zusammenziehen(roh["text"])
    {fakten, unbekannt} = aufloesen(s, List.wrap(roh["fakten"]))
    uebergang = roh["uebergang"] == true
    rueckblick = roh["rueckblick"] == true
    n = woerter(text)

    gruende =
      cond do
        text == "" ->
          [{"leer", "Der Satz ist leer. Schreib ihn aus oder lass ihn weg."}]

        unbekannt != [] ->
          zu_lang(n) ++
            [
              {"fakt_unbekannt",
               "Diese Fakten gibt es nicht: #{Jason.encode!(unbekannt)}. Die IDs stehen in der " <>
                 "ersten Spalte von fakten()."}
            ]

        true ->
          zu_lang(n) ++ markierung(s, fakten, uebergang, rueckblick)
      end

    if gruende == [] do
      {:ok,
       %{
         text: text,
         fakten: Enum.map(fakten, & &1.id),
         uebergang: uebergang,
         rueckblick: rueckblick
       }}
    else
      {:abgelehnt, gruende}
    end
  end

  defp zu_lang(n) when n > @max_woerter,
    do: [
      {"zu_lang",
       "Der Satz hat #{n} Wörter, ein Satz hat höchstens #{@max_woerter}. Teil ihn in mehrere " <>
         "Sätze, jeden mit seinen Fakten."}
    ]

  defp zu_lang(_n), do: []

  defp markierung(s, fakten, uebergang, rueckblick) do
    art =
      cond do
        fakten == [] -> :ohne
        Enum.any?(fakten, &Stand.diese_sitzung?(s, &1)) -> :diese
        true -> :frueher
      end

    case art do
      :diese ->
        wenn(uebergang, uebergang_mit_fakten()) ++
          wenn(
            rueckblick,
            {"rueckblick_mit_fakt_dieser_sitzung",
             "Der Satz ist als rueckblick markiert und stützt sich auf einen Fakt dieser " <>
               "Sitzung. rueckblick gilt für Sätze, die nur Fakten früherer Sitzungen nennen — " <>
               "dieser erzählt von Sitzung #{s.sitzung.nummer} und kommt ohne die Markierung aus."}
          )

      :frueher ->
        wenn(uebergang, uebergang_mit_fakten()) ++
          wenn(
            not rueckblick,
            {"rueckblick_fehlt",
             "Der Satz stützt sich nur auf Fakten früherer Sitzungen. Als Erinnerung an " <>
               "Früheres trägt er rueckblick: true; erzählt er von dieser Sitzung, nenn den Fakt " <>
               "dieser Sitzung, auf den er sich stützt."}
          )

      :ohne ->
        wenn(
          rueckblick,
          {"rueckblick_ohne_fakten",
           "Der Satz ist als rueckblick markiert und nennt keinen Fakt. Ein Rückblick nennt die " <>
             "Fakten früherer Sitzungen, an die er erinnert."}
        ) ++
          wenn(
            not uebergang,
            {"uebergang_fehlt",
             "Der Satz nennt keinen Fakt. Jeder Satz stützt sich auf Fakten — nenn ihre IDs in " <>
               "fakten. Ein Satz, der nur verbindet und keinen eigenen Stoff trägt, ist ein " <>
               "Übergang und trägt uebergang: true. Fehlt dir für eine Stelle der Stoff, gehört " <>
               "sie in fertig(offen_geblieben)."}
          )
    end
  end

  defp uebergang_mit_fakten,
    do:
      {"uebergang_mit_fakten",
       "Der Satz ist als uebergang markiert und nennt Fakten. Ein Übergang verbindet nur; ein " <>
         "Satz mit Fakten kommt ohne die Markierung aus."}

  # Löst die IDs auf; liefert {Fakten ohne doppelte, unbekannte Angaben}.
  defp aufloesen(s, ids) do
    {da, weg} =
      ids
      |> Enum.map(&{&1, if(is_binary(&1), do: Stand.fakt(s, &1))})
      |> Enum.split_with(fn {_, f} -> f != nil end)

    {da |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.id), Enum.map(weg, &elem(&1, 0))}
  end

  defp zusammenziehen(t) when is_binary(t), do: t |> String.split() |> Enum.join(" ")
  defp zusammenziehen(_), do: ""

  defp woerter(t), do: t |> String.split() |> length()

  defp anfang(roh) do
    w = roh |> zusammenziehen() |> String.split()
    teil = w |> Enum.take(@anfang_woerter) |> Enum.join(" ")
    if length(w) > @anfang_woerter, do: teil <> " …", else: teil
  end

  defp wenn(true, grund), do: [grund]
  defp wenn(false, _grund), do: []

  defp nil_wenn_leer([]), do: nil
  defp nil_wenn_leer(l), do: l

  defp als_json(a) do
    %{
      "titel" => a.titel,
      "saetze" =>
        Enum.map(a.saetze, fn s ->
          %{
            "text" => s.text,
            "fakten" => s.fakten,
            "uebergang" => s.uebergang,
            "rueckblick" => s.rueckblick
          }
        end)
    }
  end

  # ─── entwurf und Stand ────────────────────────────────────────────────

  @doc "Den Entwurf zurückgeben (Werkzeug `entwurf`)."
  @spec entwurf(Stand.t(), map()) :: ergebnis()
  def entwurf(%Stand{} = s, _args), do: {s, {:ok, entwurf_text(s)}}

  @doc """
  Der Entwurf als Text: je Absatz Nummer und Titel, je Satz Nummer, Text und
  in Klammern die Fakten oder die Markierung.
  """
  @spec entwurf_text(Stand.t()) :: String.t()
  def entwurf_text(%Stand{entwurf: []}),
    do: "Der Entwurf ist noch leer. Leg den ersten Absatz mit absatz() an."

  def entwurf_text(%Stand{} = s) do
    absaetze =
      s.entwurf
      |> Enum.with_index(1)
      |> Enum.map(fn {a, n} ->
        saetze =
          a.saetze
          |> Enum.with_index(1)
          |> Enum.map(fn {sa, i} -> "  #{i}. #{sa.text}  [#{marke(sa)}]" end)

        kopf = "Absatz #{n}#{titel_teil(a.titel)} · #{Laenge.anzahl(Laenge.absatz_woerter(s, n))}"
        Enum.join([kopf | saetze], "\n")
      end)

    Enum.join([stand_zeilen(s) | absaetze], "\n\n")
  end

  defp titel_teil(nil), do: " (Fließtext)"
  defp titel_teil(t), do: " — " <> t

  defp marke(%{uebergang: true}), do: "Übergang"
  defp marke(%{rueckblick: true, fakten: f}), do: "Rückblick: " <> Enum.join(f, ", ")
  defp marke(%{fakten: f}), do: Enum.join(f, ", ")

  @doc """
  Der Entwurf gekürzt, für die Kompaktierung: je Absatz Nummer, Titel, die
  ersten #{@kurz_woerter} Wörter und die Zahl der Sätze.
  """
  @spec entwurf_kurz(Stand.t()) :: String.t()
  def entwurf_kurz(%Stand{entwurf: []}), do: "(noch kein Absatz)"

  def entwurf_kurz(%Stand{} = s) do
    s.entwurf
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {a, n} ->
      w = a.saetze |> Enum.map_join(" ", & &1.text) |> String.split()
      teil = w |> Enum.take(@kurz_woerter) |> Enum.join(" ")
      mehr = if length(w) > @kurz_woerter, do: " …", else: ""
      "#{n}.#{titel_teil(a.titel)}: #{teil}#{mehr} (#{length(a.saetze)} Sätze)"
    end)
  end

  @doc "Wo das Schreiben steht, wie `notizen_lesen` und die Kompaktierung es zeigen."
  @spec stand_text(Stand.t()) :: String.t()
  def stand_text(%Stand{} = s) do
    "Sitzung #{s.sitzung.nummer}. Die Resümee-Spalte heißt „#{s.ueberschrift}“.\n" <>
      stand_zeilen(s)
  end

  defp stand_zeilen(s) do
    z = Stand.entwurf_zahlen(s)
    arc = Stand.arc_ohne_satz(s)

    zeile =
      "Entwurf: #{zahlen_text(s)} (davon #{z.uebergaenge} Übergänge, #{z.rueckblicke} " <>
        "Rückblicke); sie nennen #{MapSet.size(Stand.im_text(s))} von #{length(s.fakten)} " <>
        "Fakten dieser Sitzung.\n" <> Laenge.zeile(s)

    # In der Durchsicht sind der Weg und die Pflicht der Handlungsbögen
    # erledigt (der Weg ist dort gegen Verlust geschützt, die Durchsicht
    # gnädig); die Zeilen würden dort nur zum Nachschreiben einladen.
    if s.lauf == :durchsicht do
      zeile
    else
      Enum.join(
        Enum.reject(
          [
            zeile,
            Weg.stand_zeile(s),
            if(arc != [],
              do:
                "Handlungsbögen, von denen noch kein Satz einen Fakt dieser Sitzung nennt: " <>
                  Enum.join(arc, ", ")
            )
          ],
          &is_nil/1
        ),
        "\n"
      )
    end
  end

  defp zahlen_text(s) do
    z = Stand.entwurf_zahlen(s)
    "#{z.absaetze} Absätze, #{z.saetze} Sätze"
  end
end
