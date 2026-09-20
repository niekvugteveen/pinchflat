defmodule PinchflatWeb.Api.V1.SourceController do
  @moduledoc """
  Creating and listing sources over JSON, for clients that should never see the source form -
  an iOS share-sheet Shortcut, a Kodi context-menu add-on and an MCP server for the Hermes
  agents.

  Creation is idempotent. A share-sheet button _will_ get double-tapped, so posting the same
  channel to the same media profile twice returns the existing source with `created: false`
  rather than an error.
  """

  use PinchflatWeb, :controller

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Sources.SourceUrlResolver

  # Applied only when present - the changeset owns the defaults, this controller does not
  # invent any of its own.
  @passthrough_params ~w(
    custom_name
    index_frequency_minutes
    fast_index
    download_media
    media_limit
    media_limit_behaviour
    title_filter_regex
    download_cutoff_date
    retention_period_days
  )

  @doc """
  Lists every source, with its media profile preloaded so clients can show which profile a
  source belongs to without a second request.

  Returns a 200 JSON response.
  """
  def index(conn, _params) do
    sources =
      Sources.list_sources()
      |> Repo.preload(:media_profile)
      |> Enum.sort_by(& &1.custom_name)

    render(conn, :index, sources: sources)
  end

  @doc """
  Creates a source from a URL, resolving video URLs to their channel first.

  Returns a 201 JSON response, or 200 when the source already existed. See
  `handle_create_error/3` for the error statuses.
  """
  def create(conn, params) do
    with {:ok, url} <- fetch_url(params),
         {:ok, media_profile} <- fetch_media_profile(params),
         {:ok, resolved_url} <- resolve_url(url) do
      insert_source(conn, params, resolved_url, media_profile)
    else
      {:error, status, payload} -> send_api_error(conn, status, payload)
    end
  end

  defp insert_source(conn, params, resolved_url, media_profile) do
    attrs = source_attrs(params, resolved_url, media_profile)

    case Sources.create_source(attrs) do
      {:ok, source} -> render_source(conn, :created, source, true)
      {:error, changeset} -> handle_create_error(conn, changeset, media_profile)
    end
  end

  # The database has a unique index on (collection_id, media_profile_id, title_filter_regex),
  # so we let the insert tell us about the duplicate instead of checking for one up-front.
  # That costs one fewer yt-dlp call and, unlike a check-then-insert, is correct when two
  # requests race each other - which is exactly what a double-tapped share button does.
  defp handle_create_error(conn, changeset, media_profile) do
    cond do
      duplicate_source_error?(changeset) ->
        render_existing_source(conn, changeset, media_profile)

      message = yt_dlp_error_message(changeset) ->
        send_api_error(conn, :bad_gateway, %{error: "bad_gateway", message: message})

      true ->
        send_api_error(conn, :unprocessable_entity, %{
          error: "unprocessable_entity",
          errors: translate_errors(changeset)
        })
    end
  end

  defp render_existing_source(conn, changeset, media_profile) do
    case find_duplicate_source(changeset, media_profile) do
      %Source{} = source ->
        render_source(conn, :ok, source, false)

      nil ->
        # The index rejected the insert but we cannot find what it collided with. Reporting
        # the changeset is more honest than inventing a source we never found.
        send_api_error(conn, :unprocessable_entity, %{
          error: "unprocessable_entity",
          errors: translate_errors(changeset)
        })
    end
  end

  defp render_source(conn, status, source, created) do
    conn
    |> put_status(status)
    |> render(:show, source: Repo.preload(source, :media_profile), created: created)
  end

  defp find_duplicate_source(changeset, media_profile) do
    collection_id = Ecto.Changeset.get_field(changeset, :collection_id)
    title_filter_regex = Ecto.Changeset.get_field(changeset, :title_filter_regex) || ""

    if is_binary(collection_id) do
      Repo.one(
        from(s in Source,
          where: s.collection_id == ^collection_id,
          where: s.media_profile_id == ^media_profile.id,
          where: fragment("IFNULL(?, '')", s.title_filter_regex) == ^title_filter_regex,
          limit: 1
        )
      )
    end
  end

  defp source_attrs(params, resolved_url, media_profile) do
    params
    |> Map.take(@passthrough_params)
    |> Map.put("original_url", resolved_url)
    |> Map.put("media_profile_id", media_profile.id)
  end

  defp fetch_url(%{"url" => url}) when is_binary(url) do
    case String.trim(url) do
      "" -> bad_request_url_error()
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_url(_params), do: bad_request_url_error()

  defp bad_request_url_error do
    {:error, :bad_request, %{error: "bad_request", message: "`url` is required and must be a string"}}
  end

  defp resolve_url(url) do
    case SourceUrlResolver.resolve(url) do
      {:ok, resolved_url} -> {:ok, resolved_url}
      {:error, message} -> {:error, :bad_gateway, %{error: "bad_gateway", message: message}}
    end
  end

  defp fetch_media_profile(%{"media_profile_id" => id}) when not is_nil(id) do
    case cast_id(id) do
      {:ok, cast_id} -> found_or_error(Repo.get(MediaProfile, cast_id), :media_profile_id)
      :error -> profile_error(:media_profile_id, "must be an integer")
    end
  end

  defp fetch_media_profile(%{"media_profile_name" => name}) when is_binary(name) do
    found_or_error(Repo.get_by(MediaProfile, name: name), :media_profile_name)
  end

  defp fetch_media_profile(_params) do
    profile_error(:media_profile_id, "either media_profile_id or media_profile_name is required")
  end

  defp found_or_error(%MediaProfile{} = media_profile, _field), do: {:ok, media_profile}
  defp found_or_error(nil, field), do: profile_error(field, "does not match any media profile")

  defp profile_error(field, message) do
    {:error, :unprocessable_entity, %{error: "unprocessable_entity", errors: %{field => [message]}}}
  end

  defp cast_id(id) when is_integer(id), do: {:ok, id}

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp cast_id(_id), do: :error

  # `Sources.create_source/2` maps a unique constraint violation onto `:original_url`
  defp duplicate_source_error?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  # `Sources.create_source/2` attaches yt-dlp's own message under the `:error` option, and
  # it's the only useful thing to report when a channel is private, deleted or region-blocked.
  defp yt_dlp_error_message(changeset) do
    Enum.find_value(changeset.errors, fn {_field, {message, opts}} ->
      case Keyword.get(opts, :error) do
        nil -> nil
        runner_error -> "#{message}: #{stringify(runner_error)}"
      end
    end)
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", stringify(value))
      end)
    end)
  end

  defp stringify(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end

  defp send_api_error(conn, status, payload) do
    conn
    |> put_status(status)
    |> json(payload)
  end
end
