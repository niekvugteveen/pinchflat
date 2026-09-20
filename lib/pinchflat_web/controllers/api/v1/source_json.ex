defmodule PinchflatWeb.Api.V1.SourceJSON do
  @moduledoc """
  Renders sources for the JSON API.
  """

  alias Pinchflat.Sources.Source

  @doc """
  Renders a list of sources.
  """
  def index(%{sources: sources}) do
    %{sources: Enum.map(sources, &data/1)}
  end

  @doc """
  Renders a single source alongside whether this request is what created it.
  """
  def show(%{source: source, created: created}) do
    %{
      created: created,
      source: data(source)
    }
  end

  @doc """
  Renders the attributes of a source that an API client can act on.

  `media_profile_name` is only populated when the media profile is preloaded.
  """
  def data(%Source{} = source) do
    %{
      id: source.id,
      uuid: source.uuid,
      custom_name: source.custom_name,
      collection_name: source.collection_name,
      collection_id: source.collection_id,
      collection_type: source.collection_type,
      original_url: source.original_url,
      media_profile_id: source.media_profile_id,
      media_profile_name: media_profile_name(source),
      enabled: source.enabled,
      download_media: source.download_media,
      index_frequency_minutes: source.index_frequency_minutes,
      fast_index: source.fast_index,
      media_limit: source.media_limit,
      media_limit_behaviour: source.media_limit_behaviour,
      title_filter_regex: source.title_filter_regex,
      last_indexed_at: source.last_indexed_at
    }
  end

  defp media_profile_name(%{media_profile: %{name: name}}), do: name
  defp media_profile_name(_source), do: nil
end
