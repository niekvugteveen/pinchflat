defmodule Pinchflat.Media.DiskCleanupWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_item", "local_data"]

  use Pinchflat.Media.MediaQuery

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media.DiskAudit

  # Partial files of a download that is merely slow or stuck are still being touched; anything
  # untouched for a day is not coming back.
  @orphan_min_age_hours 24

  @doc """
  Deletes what `Pinchflat.Media.DiskAudit` finds, so that files which no longer meet their
  source's criteria don't stay on disk until someone notices. Scheduled nightly, after
  `MediaRetentionWorker` has dealt with cutoff dates and maximum ages.

  Two things are deliberately left alone:

    - Media whose *only* problem is `prevent_download`. Ticking that on a downloaded item can
      just as well mean "keep this, but don't fetch it again".
    - A source whose title filter would remove *every* file it has. That is almost always a
      broken regex rather than an intention, and deleting a whole channel overnight over a typo
      is the one mistake this worker must not make. It is logged instead.

  Nothing sets `prevent_download`, so loosening the criteria brings the media back.

  Returns :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{ineligible: ineligible, orphans: orphans} = DiskAudit.report(min_age_hours: @orphan_min_age_hours)

    {deletable, kept} = Enum.split_with(ineligible, &deletable?/1)
    {deletable, suspicious} = Enum.split_with(deletable, &(not whole_source_filtered_out?(&1, deletable)))

    Enum.each(Enum.uniq_by(suspicious, & &1.source_id), fn item ->
      Logger.warning(
        "Not cleaning up source ##{item.source_id} (#{item.source}): its title filter excludes every downloaded file"
      )
    end)

    if kept != [] do
      Logger.info("Leaving #{length(kept)} downloaded media items that only have prevent_download set")
    end

    %{deleted_media: media_count, deleted_orphans: orphan_count} =
      DiskAudit.fix!(%{ineligible: deletable, orphans: orphans})

    Logger.info("Disk cleanup: deleted #{media_count} media items and #{orphan_count} orphan files")

    :ok
  end

  defp deletable?(%{reasons: reasons}), do: reasons -- [:prevent_download] != []

  # Only the title filter can plausibly be wrong in a way that matches nothing at all; a cutoff
  # date or a duration bound excluding everything is a visible, deliberate setting.
  defp whole_source_filtered_out?(%{reasons: reasons, source_id: source_id}, deletable) do
    :title_filter in reasons and
      Enum.count(deletable, &(&1.source_id == source_id and :title_filter in &1.reasons)) ==
        downloaded_count(source_id)
  end

  defp downloaded_count(source_id) do
    MediaQuery.new()
    |> where(^MediaQuery.downloaded())
    |> where([mi], mi.source_id == ^source_id)
    |> Repo.aggregate(:count)
  end
end
