# Issue #540: Dialyzer-Baseline. Eingefrorene bestehende Findings —
# nur NEUE failen. Grundsatz (#589): hier landen NUR bestätigte Dep-False-
# Positives mit Begründung, KEIN Bulk-Dump echter Findings (die werden gefixt).
[
  # Issue #589 (Cut 2): Phoenix.Tracker.update/5 hat ein verengtes Success-
  # Typing ({:error,_}) — asymmetrisch zu track/4, ein Dep-FP. Zur Laufzeit
  # liefert update/5 {:ok, ref}, weil der Worker-Channel die Presence in join/3
  # bereits getrackt hat (gleiche pid/topic/key). Der defensive {:ok,_ref}-Zweig
  # in log_registry_result/3 wird dadurch als unerreichbar geflaggt, ist aber
  # laufzeit-korrekt + die robustere Variante ggü. dem alten harten `{:ok,_} =`
  # (das bei {:error,_} den ganzen Channel gecrasht hätte). Siehe Modul-Kommentar.
  {"lib/hub_web/channels/worker_channel.ex", :pattern_match}
]
