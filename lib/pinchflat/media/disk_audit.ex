defmodule Pinchflat.Media.DiskAudit do
  @moduledoc """
  Finds files on disk that shouldn't be there any more, for an external check to report on.

  Two kinds:

    - **Ineligible media**: downloaded media items that no longer meet their source's criteria -
      a title filter, cutoff date, maximum age, shorts/livestream preference or duration bounds
      that changed after the download, or `prevent_download` ticked while the file stayed.
      Pinchflat itself only acts on a cutoff date and a maximum age (nightly, in
      `MediaRetentionWorker`); everything else stays on disk until someone deletes it.
    - **Orphans**: files in the media directory that no media item or source refers to - aborted
      downloads (`*.part`, `*.temp.mp4`), files left behind by a rename, remains of a deleted
      source.

  Deliberately not reported: media past a `wait_for_slot` limit (kept on purpose), anything with
  `prevent_culling`, sources that are disabled or don't download media (their files are left
  alone by design), hidden files, and files modified within `min_age_hours` (downloads in
  progress write their partial files there).
  """

  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem

  @default_min_age_hours 6

  @doc """
  Returns everything that is on disk and shouldn't be.

  Options:
    - `:min_age_hours` - ignore orphans modified more recently than this (default #{@default_min_age_hours})

  Returns %{ineligible: [map()], orphans: [map()]}
  """
  def report(opts \\ []) do
    %{
      ineligible: list_ineligible_media(),
      orphans: list_orphans(Keyword.get(opts, :min_age_hours, @default_min_age_hours))
    }
  end

  @doc """
  Deletes what `report/1` found. Ineligible media goes through `Media.delete_media_files/2`
  without `prevent_download`, like a cutoff date: loosen the criteria again and it comes back.
  Orphans are plain files and are simply removed.

  Returns %{deleted_media: integer(), deleted_orphans: integer()}
  """
  def fix!(%{ineligible: ineligible, orphans: orphans}) do
    Enum.each(ineligible, fn %{id: id} ->
      id |> Media.get_media_item!() |> Media.delete_media_files(%{culled_at: DateTime.utc_now()})
    end)

    Enum.each(orphans, fn %{path: path} -> File.rm(path) end)

    %{deleted_media: length(ineligible), deleted_orphans: length(orphans)}
  end

  # One query per criterion rather than one combined one, so that the report can say *why*.
  defp list_ineligible_media do
    reasons = [
      title_filter: MediaQuery.matches_source_title_regex(),
      cutoff_date: MediaQuery.upload_date_after_source_cutoff(),
      max_age: MediaQuery.upload_date_within_source_max_age(),
      format: MediaQuery.format_matching_profile_preference(),
      duration: MediaQuery.meets_min_and_max_duration(),
      prevent_download: dynamic([mi], not mi.prevent_download)
    ]

    reasons
    |> Enum.flat_map(fn {reason, condition} ->
      MediaQuery.new()
      |> MediaQuery.require_assoc(:media_profile)
      |> where(^dynamic(^MediaQuery.downloaded() and not (^MediaQuery.culling_prevented()) and not (^condition)))
      |> where([mi, source], source.enabled and source.download_media)
      |> Repo.all()
      |> Enum.map(&{&1, reason})
    end)
    |> Enum.group_by(fn {media_item, _} -> media_item.id end)
    |> Enum.map(fn {_id, [{media_item, _} | _] = pairs} ->
      media_item = Repo.preload(media_item, :source)

      %{
        id: media_item.id,
        source: media_item.source.custom_name,
        title: media_item.title,
        uploaded_at: media_item.uploaded_at,
        size_bytes: media_item.media_size_bytes,
        reasons: Enum.map(pairs, &elem(&1, 1))
      }
    end)
    |> Enum.sort_by(&{&1.source, &1.title})
  end

  defp list_orphans(min_age_hours) do
    known = known_filepaths()
    cutoff = System.os_time(:second) - min_age_hours * 3600

    Application.get_env(:pinchflat, :media_directory)
    |> Path.join("**/*")
    # Hidden files (a `.keep`, say) are skipped because `match_dot` is off
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.flat_map(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} when mtime < cutoff ->
          [%{path: path, size_bytes: size, modified_at: DateTime.from_unix!(mtime)}]

        _ ->
          []
      end
    end)
  end

  defp known_filepaths do
    media_paths =
      from(mi in MediaItem,
        select: [mi.media_filepath, mi.thumbnail_filepath, mi.metadata_filepath, mi.nfo_filepath, mi.subtitle_filepaths]
      )
      |> Repo.all()
      |> Enum.flat_map(fn [media, thumbnail, metadata, nfo, subtitles] ->
        [media, thumbnail, metadata, nfo | Enum.map(subtitles || [], fn [_lang, path] -> path end)]
      end)

    source_paths =
      from(s in Source, select: [s.nfo_filepath, s.poster_filepath, s.fanart_filepath, s.banner_filepath])
      |> Repo.all()
      |> List.flatten()

    (media_paths ++ source_paths)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end
end
