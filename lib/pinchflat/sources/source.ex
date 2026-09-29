defmodule Pinchflat.Sources.Source do
  @moduledoc """
  The Source schema.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Pinchflat.Utils.ChangesetUtils

  alias __MODULE__
  alias Pinchflat.Repo
  alias Pinchflat.Tasks.Task
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Metadata.SourceMetadata

  @allowed_fields ~w(
    enabled
    collection_name
    collection_id
    collection_type
    custom_name
    description
    nfo_filepath
    poster_filepath
    fanart_filepath
    banner_filepath
    series_directory
    index_frequency_minutes
    fast_index
    cookie_behaviour
    download_media
    last_indexed_at
    original_url
    download_cutoff_date
    retention_period_days
    media_limit
    media_limit_behaviour
    title_filter_regex
    media_profile_id
    output_path_template_override
    marked_for_deletion_at
    min_duration_seconds
    max_duration_seconds
    sponsorblock_behaviour
    sponsorblock_categories
    delete_watched_media
    max_age_days
  )a

  # The categories yt-dlp accepts for --sponsorblock-mark/--sponsorblock-remove. Validated here
  # because an unknown category is not rejected until download time, where it fails every
  # download of the source instead of the save that introduced it.
  @sponsorblock_categories ~w(sponsor intro outro selfpromo preview filler interaction music_offtopic)

  # Expensive API calls are made when a source is inserted/updated so
  # we want to ensure that the source is valid before making the call.
  # This way, we check that the other attributes are valid before ensuring
  # that all fields are valid. This is still only one DB insert but it's
  # a two-stage validation process to fail fast before the API call.
  @initially_required_fields ~w(
    index_frequency_minutes
    fast_index
    download_media
    original_url
    media_profile_id
  )a

  @pre_insert_required_fields @initially_required_fields ++
                                ~w(
                                  uuid
                                  custom_name
                                  collection_name
                                  collection_id
                                  collection_type
                                )a

  schema "sources" do
    field :enabled, :boolean, default: true
    # This is _not_ used as the primary key or internally in the database
    # relations. This is only used to prevent an enumeration attack on the streaming
    # and RSS feed endpoints since those _must_ be public (ie: no basic auth)
    field :uuid, Ecto.UUID

    field :custom_name, :string
    field :description, :string
    field :collection_name, :string
    field :collection_id, :string
    field :collection_type, Ecto.Enum, values: [:channel, :playlist]
    field :index_frequency_minutes, :integer, default: 60 * 24
    field :fast_index, :boolean, default: false
    field :cookie_behaviour, Ecto.Enum, values: [:disabled, :when_needed, :all_operations], default: :disabled
    field :download_media, :boolean, default: true
    field :last_indexed_at, :utc_datetime
    # Only download media items that were published after this date
    field :download_cutoff_date, :date
    # A cutoff date that moves along: only keep media published in the last N days. Unlike
    # `retention_period_days` this counts from the upload date, not the download date, so media
    # downloaded late (eg: to fill a media limit slot) doesn't get a fresh lease on life
    field :max_age_days, :integer
    field :retention_period_days, :integer
    # The maximum number of media items this source may keep on-disk at once.
    # `nil` (or 0) means no limit. See `Pinchflat.Media.MediaLimits` for how this is enforced
    field :media_limit, :integer
    field :media_limit_behaviour, Ecto.Enum, values: [:wait_for_slot, :delete_oldest], default: :wait_for_slot
    # Delete media once a media server reports it as watched, and never download it again.
    # See `Pinchflat.Downloading.WatchedMediaWorker`
    field :delete_watched_media, :boolean, default: false
    field :original_url, :string
    field :title_filter_regex, :string
    field :output_path_template_override, :string

    field :min_duration_seconds, :integer
    field :max_duration_seconds, :integer

    # Overrides the media profile's SponsorBlock settings for this source only. `nil` means
    # "use the media profile's", so the two fields are only meaningful together - see
    # `Pinchflat.Downloading.DownloadOptionBuilder`
    field :sponsorblock_behaviour, Ecto.Enum, values: [:disabled, :mark, :remove]
    field :sponsorblock_categories, {:array, :string}

    field :series_directory, :string
    field :nfo_filepath, :string
    field :poster_filepath, :string
    field :fanart_filepath, :string
    field :banner_filepath, :string

    field :marked_for_deletion_at, :utc_datetime

    belongs_to :media_profile, MediaProfile

    has_one :metadata, SourceMetadata, on_replace: :update

    has_many :tasks, Task
    has_many :media_items, MediaItem, foreign_key: :source_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(source, attrs, validation_stage) do
    # See above for rationale
    required_fields =
      if validation_stage == :initial do
        @initially_required_fields
      else
        @pre_insert_required_fields
      end

    source
    |> cast(attrs, @allowed_fields)
    |> dynamic_default(:custom_name, fn cs -> get_field(cs, :collection_name) end)
    |> dynamic_default(:uuid, fn _ -> Ecto.UUID.generate() end)
    |> validate_required(required_fields)
    |> validate_title_regex()
    |> validate_min_and_max_durations()
    |> validate_sponsorblock_override()
    |> validate_number(:retention_period_days, greater_than_or_equal_to: 0)
    |> validate_number(:max_age_days, greater_than: 0)
    |> validate_number(:media_limit, greater_than: 0)
    # Ensures it ends with `.{{ ext }}` or `.%(ext)s` or similar (with a little wiggle room)
    |> validate_format(:output_path_template_override, MediaProfile.ext_regex(), message: "must end with .{{ ext }}")
    |> validate_format(:original_url, youtube_channel_or_playlist_regex(), message: "must be a channel or playlist URL")
    |> cast_assoc(:metadata, with: &SourceMetadata.changeset/2, required: false)
    |> unique_constraint([:collection_id, :media_profile_id, :title_filter_regex], error_key: :original_url)
  end

  @doc false
  def index_frequency_when_fast_indexing do
    # 30 days in minutes
    60 * 24 * 30
  end

  @doc false
  def fast_index_frequency do
    # minutes
    10
  end

  @doc false
  def filepath_attributes do
    ~w(nfo_filepath fanart_filepath poster_filepath banner_filepath)a
  end

  @doc false
  def json_exluded_fields do
    ~w(__meta__ __struct__ metadata tasks media_items)a
  end

  def youtube_channel_or_playlist_regex do
    # Validate that the original URL is not a video URL
    # Also matches if the string does NOT contain youtube.com or youtu.be. This preserves my tenuous support
    # for non-youtube sources.
    ~r<^(?:(?!youtube\.com/(watch|shorts|embed)|youtu\.be).)*$>
  end

  defp validate_title_regex(%{changes: %{title_filter_regex: regex}} = changeset) when is_binary(regex) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT regexp_like('', ?)", [regex]) do
      {:ok, _} -> changeset
      _ -> add_error(changeset, :title_filter_regex, "is invalid")
    end
  end

  defp validate_title_regex(changeset), do: changeset

  defp validate_min_and_max_durations(changeset) do
    min_duration = get_change(changeset, :min_duration_seconds)
    max_duration = get_change(changeset, :max_duration_seconds)

    case {min_duration, max_duration} do
      {min, max} when is_nil(min) or is_nil(max) -> changeset
      {min, max} when min >= max -> add_error(changeset, :max_duration_seconds, "must be greater than minumum duration")
      _ -> changeset
    end
  end

  # The override is one setting spread over two fields, so keep them coherent:
  #   - no behaviour means "use the profile's", which leaves nothing for categories to do
  #   - mark/remove without categories would silently do nothing, since yt-dlp is only given
  #     a SponsorBlock option when there is at least one category
  # Blank entries are dropped because a form's checkbox group submits one for "none ticked".
  defp validate_sponsorblock_override(changeset) do
    categories =
      changeset
      |> get_field(:sponsorblock_categories)
      |> Kernel.||([])
      |> Enum.reject(&(&1 in [nil, ""]))

    case get_field(changeset, :sponsorblock_behaviour) do
      nil ->
        put_change(changeset, :sponsorblock_categories, nil)

      behaviour when behaviour in [:mark, :remove] and categories == [] ->
        changeset
        |> put_change(:sponsorblock_categories, [])
        |> add_error(:sponsorblock_categories, "must include at least one category to #{behaviour}")

      _ ->
        changeset
        |> put_change(:sponsorblock_categories, categories)
        |> validate_subset(:sponsorblock_categories, @sponsorblock_categories)
    end
  end

  defimpl Jason.Encoder, for: Source do
    def encode(value, opts) do
      value
      |> Repo.preload(:media_profile)
      |> Map.drop(Source.json_exluded_fields())
      |> Jason.Encode.map(opts)
    end
  end
end
