defmodule Worker.Recording.AudioBuffer.Retention do
  @moduledoc """
  Issue #934: Retention-Sidecar (`.retention.json`), TTL-Purge des Archivs und
  Alt-Pfad-Migration — aus `Worker.Recording.AudioBuffer` ausgelagert (God-Module-
  Entlastung, #544).

  Kernprinzip: Die Löschentscheidung hängt an einem **deklarierten** `purge_after`
  (Sidecar pro Session-Dir), NICHT an `mtime` (von Backup/rsync/touch mutierbar).
  Transkribiertes Audio im done_dir wird nach `purge_after` gelöscht; un-transkribierte
  Orphans (im audio_dir) werden hier nie angefasst; Sidecar-lose/aktive Dirs bleiben
  (flag-not-drop). Alle Funktionen nehmen die Pfade/Fristen explizit entgegen — der
  AudioBuffer hält die Settings-Accessoren.
  """

  require Logger

  @retention_file ".retention.json"

  # Alt-Pfade (tmpfs-/tmp) für den einmaligen Migrations-Scan beim Pfadwechsel.
  @legacy_audio_dir "/tmp/lore_audio"
  @legacy_done_dir "/tmp/lore_audio_done"

  @doc "Sidecar-Dateiname — für dir-listing-Filter (z.B. Tests)."
  def sidecar_file, do: @retention_file

  def iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  def write_sidecar(dir, map) do
    File.write(Path.join(dir, @retention_file), Jason.encode!(map))
  end

  def read_sidecar(dir) do
    with {:ok, body} <- File.read(Path.join(dir, @retention_file)),
         {:ok, %{} = m} <- Jason.decode(body) do
      m
    else
      _ -> nil
    end
  end

  @doc """
  `purge_after = jetzt + days` ins bestehende Sidecar mergen (behält `created_at`).
  `days <= 0` → nie purgen (kein `purge_after` gesetzt).
  """
  def stamp_purge_after(dir, days) do
    if is_integer(days) and days > 0 do
      base = read_sidecar(dir) || %{"created_at" => iso_now()}
      pa = DateTime.utc_now() |> DateTime.add(days * 86_400, :second) |> DateTime.to_iso8601()
      write_sidecar(dir, Map.put(base, "purge_after", pa))
    end

    :ok
  end

  @doc """
  Löscht im `done_dir` alle Sessions mit überschrittenem, DEKLARIERTEM `purge_after`.
  `active_ids` = derzeit offene Sessions (nie purgen — Belt-and-Suspenders, obwohl
  offene Writer im audio_dir und nicht im done_dir leben). `nil`-done_dir → no-op.
  """
  def purge_expired(nil, _active_ids), do: :ok

  def purge_expired(done_dir, active_ids) when is_binary(done_dir) do
    case File.ls(done_dir) do
      {:ok, entries} ->
        Enum.each(entries, fn sid ->
          sdir = Path.join(done_dir, sid)

          if File.dir?(sdir) and sid not in active_ids do
            maybe_purge_one(sdir, sid)
          end
        end)

      {:error, _} ->
        :ok
    end
  end

  defp maybe_purge_one(sdir, sid) do
    case read_sidecar(sdir) do
      %{"purge_after" => pa} when is_binary(pa) ->
        case DateTime.from_iso8601(pa) do
          {:ok, dt, _} ->
            if DateTime.compare(DateTime.utc_now(), dt) == :gt do
              File.rm_rf(sdir)
              Logger.info("AudioBuffer: Retention-Purge session=#{sid} (purge_after=#{pa})")
            end

          _ ->
            Logger.warning(
              "AudioBuffer: Retention-Sidecar unparsbar für #{sid} — behalten (flag-not-drop)"
            )
        end

      _ ->
        Logger.warning(
          "AudioBuffer: kein/kaputtes Retention-Sidecar für #{sid} — behalten (flag-not-drop)"
        )
    end
  end

  @doc """
  Einmaliger Boot-Scan der Alt-Pfade → Sessions in die neuen persistenten Ordner
  verschieben (gated auf `:audio_migrate_legacy_tmp`).

  `legacy_fixed_audio_dir` (Issue #948): der frühere FESTE audio_dir-Default
  (`~/.local/share/lore-worker/audio`), von dem Bestandsworker auf ihren neuen
  per-Worker-Pfad umziehen. `nil` = nicht migrieren. Der `move_legacy_sessions`-
  Guard (old != new) verhindert den Self-Move, wenn der neue Pfad zufällig gleich
  ist. Ehrliche Grenze: teilten sich MEHRERE Worker den alten Fixpfad, greift der
  ERSTE bootende Worker dessen Sessions einmalig ab — danach ist alles isoliert.
  """
  def migrate_legacy(new_audio_dir, new_done_dir, legacy_fixed_audio_dir \\ nil) do
    if Worker.Settings.get(:audio_migrate_legacy_tmp, true) do
      move_legacy_sessions(@legacy_audio_dir, new_audio_dir)
      if is_binary(new_done_dir), do: move_legacy_sessions(@legacy_done_dir, new_done_dir)

      if is_binary(legacy_fixed_audio_dir),
        do: move_legacy_sessions(legacy_fixed_audio_dir, new_audio_dir)
    end

    :ok
  end

  @doc """
  Verschiebt alle Session-Dirs aus `old` nach `new` (rename, cp+rm-Fallback bei
  FS-Grenze), ohne bestehende Ziele zu überschreiben. Public für Unit-Tests.
  """
  def move_legacy_sessions(old, new) do
    old_e = Path.expand(old)

    if old_e != Path.expand(new) and File.dir?(old_e) do
      File.mkdir_p!(new)

      case File.ls(old_e) do
        {:ok, entries} ->
          Enum.each(entries, fn name ->
            src = Path.join(old_e, name)
            dest = Path.join(new, name)

            if File.dir?(src) and not File.exists?(dest) do
              case File.rename(src, dest) do
                :ok ->
                  :ok

                {:error, _} ->
                  # EXDEV (FS-Grenze) → cp+rm-Fallback. Kein `&&` (cp_r! liefert eine
                  # Liste, nie nil → dialyzer guard_fail).
                  File.cp_r!(src, dest)
                  File.rm_rf(src)
              end

              Logger.warning("AudioBuffer: Alt-Pfad-Migration #{name}: #{src} → #{dest}")
            end
          end)

        {:error, _} ->
          :ok
      end
    end

    :ok
  end
end
