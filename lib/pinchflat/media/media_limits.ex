defmodule Pinchflat.Media.MediaLimits do
  @moduledoc """
  Methods for enforcing a source's media limit - the maximum number of media items a
  source is allowed to keep on-disk at any one time.

  Two behaviours are supported:

    - `:delete_oldest` - the source keeps the newest N media items on-disk. Once the limit
      is reached, downloading a newer media item deletes the oldest one to make room for it.
    - `:wait_for_slot` - the source downloads up to N media items and then stops. Nothing is
      deleted automatically - the next media item is only downloaded once one of the existing
      files is gone (eg: you watched it and your media center deleted it).

  Sources without a media limit are unaffected and behave exactly as they always have.
  """

  use Pinchflat.Media.MediaQuery

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Media.FileSyncing

  @doc """
  Whether a source has a media limit set.

  Returns boolean()
  """
  def limited?(%Source{media_limit: media_limit}) do
    is_integer(media_limit) && media_limit > 0
  end

  @doc """
  Returns the media items a source is allowed to download _right now_, newest first.

  For sources without a limit this is simply every pending media item. For limited sources
  this is capped by the limit - see the moduledoc for the specifics of each behaviour.

  Returns [%MediaItem{}]
  """
  def list_downloadable_media_items_for(%Source{} = source) do
    cond do
      !limited?(source) -> Media.list_pending_media_items_for(source)
      source.media_limit_behaviour == :delete_oldest -> Enum.reject(download_window(source), & &1.media_filepath)
      true -> list_media_items_for_free_slots(source)
    end
  end

  @doc """
  Whether a single media item may be downloaded right now, taking its source's media limit
  into account. Mirrors `list_downloadable_media_items_for/1` and exists so the limit can be
  re-checked immediately before a download starts (jobs can sit in the queue for a while).

  Returns boolean()
  """
  def downloadable?(%MediaItem{} = media_item) do
    media_item = Repo.preload(media_item, source: :media_profile)

    if limited?(media_item.source) do
      media_item.source
      |> list_downloadable_media_items_for()
      |> Enum.any?(fn downloadable_item -> downloadable_item.id == media_item.id end)
    else
      Media.pending_download?(media_item)
    end
  end

  @doc """
  Brings a source back in line with its media limit. What this means depends on the source's
  `media_limit_behaviour` - see the moduledoc. Sources without a limit are left alone.

  Does not enqueue any downloads - callers are expected to do that themselves once slots
  have been freed up.

  Returns :ok
  """
  def enforce_limit_for(%Source{} = source) do
    if limited?(source) do
      do_enforce_limit_for(source)
    else
      :ok
    end
  end

  defp do_enforce_limit_for(%Source{media_limit_behaviour: :delete_oldest} = source) do
    media_items = list_media_items_over_limit(source)

    if media_items != [] do
      Logger.info("Deleting #{length(media_items)} media items over the limit for source ##{source.id}")
    end

    Enum.each(media_items, fn media_item ->
      # NOTE: `prevent_download` is intentionally _not_ set. These media items simply fall
      # outside the source's download window so they won't be picked back up - and raising
      # the limit later should bring them back, same as changing a cutoff date does.
      Media.delete_media_files(media_item, %{culled_at: DateTime.utc_now()})
    end)
  end

  defp do_enforce_limit_for(%Source{media_limit_behaviour: :wait_for_slot} = source) do
    # This behaviour only works if we notice media being deleted from outside Pinchflat, so
    # check that the files we think we have are actually still on-disk. Anything that's gone
    # has had its slot freed up on purpose and mustn't come back - otherwise we'd just
    # re-download the thing you deleted.
    FileSyncing.sync_file_presence_on_disk(list_downloaded_media_items(source))

    vanished_media_items = list_media_items_with_vanished_files(source)

    if vanished_media_items != [] do
      Logger.info("Freeing up #{length(vanished_media_items)} media limit slots for source ##{source.id}")
    end

    Enum.each(vanished_media_items, fn media_item ->
      Media.update_media_item(media_item, %{prevent_download: true})
    end)
  end

  # The newest N media items this source should have on-disk. Anything already downloaded is
  # included so that the window doesn't shift as media gets downloaded and deleted.
  defp download_window(%Source{} = source) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.for_source(source) and (^MediaQuery.downloaded() or ^MediaQuery.pending())))
    |> order_by(desc: :uploaded_at, desc: :id)
    |> limit(^source.media_limit)
    |> Repo.all()
  end

  defp list_media_items_over_limit(%Source{} = source) do
    media_item_ids_to_keep = Enum.map(download_window(source), & &1.id)

    source
    |> downloaded_media_items_query()
    |> where(^dynamic(not (^MediaQuery.culling_prevented())))
    |> where([mi], mi.id not in ^media_item_ids_to_keep)
    |> Repo.all()
  end

  defp list_media_items_for_free_slots(%Source{} = source) do
    free_slots = source.media_limit - Repo.aggregate(downloaded_media_items_query(source), :count)

    if free_slots > 0 do
      MediaQuery.new()
      |> MediaQuery.require_assoc(:media_profile)
      |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.pending()))
      |> order_by(desc: :uploaded_at, desc: :id)
      |> limit(^free_slots)
      |> Repo.all()
    else
      []
    end
  end

  # Media that was downloaded at some point but no longer has a file on-disk _and_ that
  # Pinchflat didn't delete itself (`culled_at` covers retention, cutoff dates and media
  # limits). In other words: media that you - or your media center - deleted.
  #
  # This is deliberately not derived from the `sync_file_presence_on_disk` return value:
  # the file sync may well have been run by something else (eg: the `Sync files on disk`
  # button) before we got here, and the slot needs freeing up either way.
  defp list_media_items_with_vanished_files(%Source{} = source) do
    MediaQuery.new()
    |> where(
      ^dynamic(
        [mi],
        ^MediaQuery.for_source(source) and not (^MediaQuery.downloaded()) and
          not (^MediaQuery.download_prevented()) and not is_nil(mi.media_downloaded_at) and is_nil(mi.culled_at)
      )
    )
    |> Repo.all()
  end

  defp list_downloaded_media_items(%Source{} = source) do
    source
    |> downloaded_media_items_query()
    |> Repo.all()
  end

  defp downloaded_media_items_query(%Source{} = source) do
    MediaQuery.new()
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.downloaded()))
  end
end
