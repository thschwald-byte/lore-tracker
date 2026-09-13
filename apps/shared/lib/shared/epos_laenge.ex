defmodule Shared.EposLaenge do
  @moduledoc """
  Die Mindestlänge eines Epos-Kapitels je Kampagne (J6, #1210, Epic #1195):
  wie viele Wörter das Kapitel einer Sitzung mindestens hat, das der
  Epos-Jack schreibt. Gelesen vom Epos-Jack (`Worker.Jack.Epos.Eingabe`);
  das Feld im Epos-Tab von „Stil setzen“ samt eigenem Ereignis kommt in E4
  (Muster `Shared.ResuemeeLaenge` / `CampaignResuemeeLaengeSet`). Bis dahin
  gilt für jede Kampagne der Standard.

  **Warum hier:** Hub und Worker brauchen denselben Standard und denselben
  Wertebereich — der Hub, um eine Eingabe abzulehnen, der Worker, um sie
  anzuwenden (#1090-Klasse, wie `Shared.ResuemeeLaenge`).

  **Standard 1250 Wörter** (Maintainer, 13.09.2026): Maßstab sind die ersten
  beiden Kapitel einer Referenzkampagne mit je rund 1270 Wörtern.

  **Keine Wortgrenze nach oben** (Maintainer, 13.09.2026, #1210 Kommentar 3):
  die Länge nach oben ergibt sich aus dem Stoff, denn mehr Text braucht mehr
  belegte Sätze; begrenzt wird der Anteil der Sätze ohne Beleg (höchstens
  30 %, geprüft im Schreiben, E2). `obergrenze/0` ist deshalb nur der größte
  erlaubte Wert der Mindestlänge.

  **Wertebereich 300 bis 5000, gegriffen:** unter 300 Wörtern trägt ein
  Kapitel kaum eine Szene, über 5000 wäre die Mindestlänge ein halber Roman
  je Sitzung.
  """

  @standard 1250
  @untergrenze 300
  @obergrenze 5000

  @doc "Der Standard, wenn für die Kampagne nichts gesetzt ist."
  @spec standard() :: pos_integer()
  def standard, do: @standard

  @doc "Der kleinste erlaubte Wert."
  @spec untergrenze() :: pos_integer()
  def untergrenze, do: @untergrenze

  @doc "Der größte erlaubte Wert der Mindestlänge (keine Obergrenze des Kapitels)."
  @spec obergrenze() :: pos_integer()
  def obergrenze, do: @obergrenze

  @doc """
  Prüft einen Wert — eine Zahl oder, aus einem Formular, einen Text.
  `{:ok, n}` für eine ganze Zahl im Wertebereich, `:leer` für `nil` oder
  leeren Text (heißt: Standard), sonst `{:error, :ungueltig}`.
  """
  @spec pruefen(term()) :: {:ok, pos_integer()} | :leer | {:error, :ungueltig}
  def pruefen(nil), do: :leer

  def pruefen(n) when is_integer(n) and n >= @untergrenze and n <= @obergrenze, do: {:ok, n}

  def pruefen(t) when is_binary(t) do
    case String.trim(t) do
      "" ->
        :leer

      s ->
        case Integer.parse(s) do
          {n, ""} -> pruefen(n)
          _ -> {:error, :ungueltig}
        end
    end
  end

  def pruefen(_), do: {:error, :ungueltig}

  @doc "Der Wert, der gilt: ein gültiger Wert, sonst der Standard."
  @spec wirksam(term()) :: pos_integer()
  def wirksam(wert) do
    case pruefen(wert) do
      {:ok, n} -> n
      _ -> @standard
    end
  end
end
