defmodule Worker.Schema.JackTabellen do
  @moduledoc """
  Die Tabellen der Jack-Stände (J4 #1207, J5 #1209, J6 #1210) — ausgelagert
  aus `Worker.Schema.Mnesia.bootstrap!/0`, das mit der dritten Tabelle die
  600-Code-Zeilen-Grenze des God-Module-Checks (#544) gerissen hätte. Der
  Schnitt ist inhaltlich: die drei Tabellen haben dieselbe Form, dieselbe
  LWW-Regel und denselben Fold (`Worker.Materializer.JackStandFolds`), und sie
  brauchen keine Migration — `ensure_table!` legt sie beim nächsten Boot leer
  an, Bestands-Mnesia bleibt unberührt.

  Je eine Row pro Sitzung: `stand_json` ist der Jason-kodierte Stand, die
  `event_id` steht als letzte Spalte (`existing_row_event_id/3` liest sie von
  hinten).

    * `worker_jack_staende` — Jacks Stand (`%{aussagen, fortsetzung}`);
    * `worker_jack_resuemee_staende` — der Stand des Resümee-Jack
      (`%{notizen, entwurf, satzquellen, zaehlwerte, modell, zeitpunkt}`);
    * `worker_jack_epos_staende` — der Stand des Epos-Jack
      (`%{notizen, entwurf, quellen, zaehlwerte, modell, zeitpunkt}`);
    * `worker_jack_zeit_staende` — der Stand des Zeit-Jack (#1247).

  Dazu die **Kette** (`worker_zeit_kette`, #1247): eine Row je Glied des
  Zeitstrahls, mit dem Platz als Bezug auf die Kennung des Nachbarn.

  **`worker_zeit_anker` hat eine andere Form** und steht trotzdem hier, weil
  sie zum selben Umbau gehört: eine Row je **Anker**, nicht je Sitzung, mit
  der content-adressierten `anker_id` als Schlüssel. Die Nutzdaten liegen als
  ein JSON-Feld (`daten_json`) — `ensure_table!` baut eine bestehende Tabelle
  nicht um, ein späteres Feld wäre sonst eine Migration. `session_id` und
  `campaign_id` stehen als eigene Spalten, weil die Cascade sie braucht.

  Die Namen bleiben in `Worker.Schema.Mnesia` (`S.jack_staende/0` …), wo
  jede andere Tabelle auch ihren Namen hat.
  """

  alias Worker.Schema.Mnesia, as: S

  @doc "Legt die Stand-Tabellen und die Anker-Tabelle an, falls sie fehlen."
  @spec ensure!() :: :ok
  def ensure! do
    for tabelle <- [
          S.jack_staende(),
          S.jack_resuemee_staende(),
          S.jack_epos_staende(),
          S.jack_zeit_staende()
        ] do
      :ok =
        Shared.Mnesia.ensure_table!(tabelle,
          attributes: [:session_id, :campaign_id, :stand_json, :ts, :event_id],
          type: :set,
          index: [:campaign_id]
        )
    end

    :ok =
      Shared.Mnesia.ensure_table!(S.zeit_anker(),
        attributes: [:anker_id, :campaign_id, :session_id, :daten_json, :ts, :event_id],
        type: :set,
        index: [:campaign_id, :session_id]
      )

    :ok =
      Shared.Mnesia.ensure_table!(S.zeit_kette(),
        attributes: [:glied_id, :campaign_id, :session_id, :daten_json, :ts, :event_id],
        type: :set,
        index: [:campaign_id, :session_id]
      )

    :ok
  end
end
