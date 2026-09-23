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
  Renders a single source with its media counts. Used by `show` and `update` - the counts are
  what let a caller see that a settings change is about to delete files.
  """
  def detail(%{source: source, stats: stats}) do
    %{
      source: data(source),
      stats: stats
    }
  end

  @doc """
  Renders the attributes of a source that an API client can act on.

  This is every setting the source form exposes, not a subset: a client that offers editing
  has to be able to show what the current values are, and a field that is missing here reads
  to that client exactly like a field that is unset.

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
      description: source.description,
      original_url: source.original_url,
      media_profile_id: source.media_profile_id,
      media_profile_name: media_profile_name(source),
      enabled: source.enabled,
      download_media: source.download_media,
      index_frequency_minutes: source.index_frequency_minutes,
      fast_index: source.fast_index,
      cookie_behaviour: source.cookie_behaviour,
      media_limit: source.media_limit,
      media_limit_behaviour: source.media_limit_behaviour,
      # Both of these delete already-downloaded files that fall outside them - see
      # `Pinchflat.Downloading.MediaRetentionWorker`
      download_cutoff_date: source.download_cutoff_date,
      retention_period_days: source.retention_period_days,
      title_filter_regex: source.title_filter_regex,
      min_duration_seconds: source.min_duration_seconds,
      max_duration_seconds: source.max_duration_seconds,
      series_directory: source.series_directory,
      output_path_template_override: source.output_path_template_override,
      marked_for_deletion_at: source.marked_for_deletion_at,
      last_indexed_at: source.last_indexed_at,
      inserted_at: source.inserted_at,
      updated_at: source.updated_at
    }
  end

  defp media_profile_name(%{media_profile: %{name: name}}), do: name
  defp media_profile_name(_source), do: nil
end
