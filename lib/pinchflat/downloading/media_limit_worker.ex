defmodule Pinchflat.Downloading.MediaLimitWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_item", "local_data"]

  alias Pinchflat.Sources
  alias Pinchflat.Media.MediaLimits
  alias Pinchflat.Downloading.DownloadingHelpers

  @doc """
  Brings every enabled source with a media limit back in line with that limit and fills any
  slots that have since been freed up.

  This worker is scheduled to run hourly via the Oban Cron plugin - rather than daily like
  the retention worker - because `wait_for_slot` sources rely on it to notice that you've
  watched (and deleted) something and that the next media item can be downloaded.

  Disabled sources are skipped entirely: disabling a source should leave its media alone.

  Returns :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Sources.list_sources()
    |> Enum.filter(fn source -> source.enabled && MediaLimits.limited?(source) end)
    |> Enum.each(fn source ->
      :ok = MediaLimits.enforce_limit_for(source)
      DownloadingHelpers.enqueue_pending_download_tasks(source)
    end)

    :ok
  end
end
