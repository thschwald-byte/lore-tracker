defmodule Shared.ResuemeeLaenge do
  @moduledoc """
  Die Länge des Resümees je Kampagne (J5, #1209): höchstens so viele Wörter
  schreibt der Resümee-Jack. Gesetzt in „Stil setzen“ (Resümee-Tab,
  `HubWeb.CampaignLive.Stil`), gespeichert per `CampaignResuemeeLaengeSet`
  im Worker (`Worker.Materializer.ResuemeeLaengeFolds`), gelesen vom
  Resümee-Jack (`Worker.Jack.Resuemee.Eingabe`).

  **Warum hier:** Hub und Worker brauchen denselben Standard und denselben
  Wertebereich — der Hub, um eine Eingabe abzulehnen, der Worker, um einen
  Wert anzuwenden. Zwei Listen an zwei Orten laufen auseinander, ohne dass
  etwas rot wird (#1090-Klasse).

  **Standard 75 Wörter** (Maintainer, 13.09.2026): ein Resümee ist ein „Was
  bisher geschah“. Anlass war der erste echte Lauf — 1272 Wörter, 107 von 114
  Fakten erzählt, länger als das Epos-Kapitel.

  **Wertebereich 30 bis 1000, gegriffen:** unter 30 Wörtern trägt ein Absatz
  mit Titel kaum einen Satz, über 1000 wäre es kein Resümee mehr.
  """

  @standard 75
  @untergrenze 30
  @obergrenze 1000

  @doc "Der Standard, wenn für die Kampagne nichts gesetzt ist."
  @spec standard() :: pos_integer()
  def standard, do: @standard

  @doc "Der kleinste erlaubte Wert."
  @spec untergrenze() :: pos_integer()
  def untergrenze, do: @untergrenze

  @doc "Der größte erlaubte Wert."
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
