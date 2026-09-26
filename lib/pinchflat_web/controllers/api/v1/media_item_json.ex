defmodule PinchflatWeb.Api.V1.MediaItemJSON do
  @moduledoc """
  Renders media items for the JSON API.
  """

  alias Pinchflat.Media.MediaItem

  @doc """
  Renders a source's media items, newest first.
  """
  def index(%{source: source, media_items: media_items}) do
    %{
      source_id: source.id,
      media_items: Enum.map(media_items, &data/1)
    }
  end

  @doc """
  Renders the attributes of a media item a client needs to identify it and fetch it elsewhere.
  `media_id` is the YouTube video id.
  """
  def data(%MediaItem{} = media_item) do
    %{
      id: media_item.id,
      media_id: media_item.media_id,
      title: media_item.title,
      original_url: media_item.original_url,
      uploaded_at: media_item.uploaded_at,
      duration_seconds: media_item.duration_seconds,
      livestream: media_item.livestream,
      short_form_content: media_item.short_form_content,
      downloaded: not is_nil(media_item.media_filepath),
      prevent_download: media_item.prevent_download
    }
  end
end
