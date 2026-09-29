defmodule Pinchflat.Downloading.WatchedMediaWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    # A failed run is retried by the next hourly one - retrying in between only hammers a
    # Jellyfin server that is probably down. Failing is still worth it: it shows up in the UI.
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_item", "local_data"]

  use Pinchflat.Media.MediaQuery

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.MediaServers.Jellyfin
  alias Pinchflat.Downloading.DownloadingHelpers

  @doc """
  Deletes the media of `delete_watched_media` sources that a media server reports as watched,
  and prevents it from being downloaded again. Freed-up media limit slots are then filled
  straight away, which is what turns a media limit of N into "the newest N I haven't seen".

  Media is only deleted once it was last played more than `watched_grace_hours` ago, so that
  finishing an episode doesn't yank it away mid-credits and an accidental "mark as watched" can
  still be undone. `prevent_culling` is respected, same as it is for retention and limits.

  Scheduled hourly via the Oban Cron plugin. Does nothing unless a media server is configured.

  Returns :ok | {:error, String.t()}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    sources = Enum.filter(Sources.list_sources(), &(&1.enabled && &1.delete_watched_media))

    if sources != [] && Jellyfin.configured?() do
      delete_watched_media_for(sources)
    else
      :ok
    end
  end

  defp delete_watched_media_for(sources) do
    case Jellyfin.list_watched_media() do
      {:ok, watched} ->
        cutoff = DateTime.add(DateTime.utc_now(), -grace_hours(), :hour)

        filepaths =
          watched
          |> Enum.filter(&(is_nil(&1.last_played_at) || DateTime.before?(&1.last_played_at, cutoff)))
          |> Enum.map(& &1.filepath)
          |> Enum.uniq()

        Enum.each(sources, &delete_watched_media_for_source(&1, filepaths))

      {:error, reason} ->
        Logger.error("Couldn't fetch watched media from Jellyfin: #{reason}")

        {:error, reason}
    end
  end

  defp delete_watched_media_for_source(source, filepaths) do
    media_items =
      MediaQuery.new()
      |> where(
        ^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.downloaded() and not (^MediaQuery.culling_prevented()))
      )
      |> where([mi], mi.media_filepath in ^filepaths)
      |> Repo.all()

    if media_items != [] do
      Logger.info("Deleting #{length(media_items)} watched media items for source ##{source.id}")

      Enum.each(media_items, fn media_item ->
        # `prevent_download` is the point: watched media must not come back, not even when the
        # media limit's window later slides back over it. `culled_at` is informational.
        Media.delete_media_files(media_item, %{prevent_download: true, culled_at: DateTime.utc_now()})
      end)

      DownloadingHelpers.enqueue_pending_download_tasks(source)
    end
  end

  defp grace_hours, do: Application.get_env(:pinchflat, :watched_grace_hours, 12)
end
