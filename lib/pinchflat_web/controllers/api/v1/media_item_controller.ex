defmodule PinchflatWeb.Api.V1.MediaItemController do
  @moduledoc """
  Lists a source's media items over JSON, newest first.

  This exists so a client can find an episode by name and get its YouTube id - eg: the MCP
  server for the Hermes agents, which fetches transcripts straight from YouTube. It reads from
  Pinchflat's index, so it covers every item the source has indexed, not only the ones that
  are downloaded: a media limit or `download_media: false` does not hide anything here.
  """

  use PinchflatWeb, :controller

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem

  @default_limit 20
  @max_limit 100

  @doc """
  Params: `limit` (default #{@default_limit}, max #{@max_limit}) and `q`, a case-insensitive
  substring of the title.

  Returns a 200 JSON response, 404 if no source has that id, or 422 for an unusable `limit`.
  """
  def index(conn, %{"source_id" => source_id} = params) do
    with {:ok, source} <- fetch_source(source_id),
         {:ok, limit} <- parse_limit(params["limit"]) do
      media_items =
        MediaItem
        |> where([mi], mi.source_id == ^source.id)
        |> filter_title(params["q"])
        |> order_by([mi], desc: mi.uploaded_at, desc: mi.id)
        |> limit(^limit)
        |> Repo.all()

      render(conn, :index, source: source, media_items: media_items)
    else
      {:error, status, payload} ->
        conn
        |> put_status(status)
        |> json(payload)
    end
  end

  defp filter_title(query, term) when is_binary(term) and term != "" do
    pattern = "%" <> escape_like(String.downcase(term)) <> "%"

    where(query, [mi], fragment("lower(?) LIKE ? ESCAPE '\\'", mi.title, ^pattern))
  end

  defp filter_title(query, _term), do: query

  defp escape_like(term) do
    String.replace(term, ["\\", "%", "_"], fn char -> "\\" <> char end)
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(value) do
    case Integer.parse(to_string(value)) do
      {limit, ""} when limit > 0 ->
        {:ok, min(limit, @max_limit)}

      _ ->
        {:error, :unprocessable_entity, %{error: "unprocessable_entity", message: "limit must be a positive integer"}}
    end
  end

  defp fetch_source(id) do
    with {parsed, ""} <- Integer.parse(to_string(id)),
         %Source{} = source <- Repo.get(Source, parsed) do
      {:ok, source}
    else
      _ -> {:error, :not_found, %{error: "not_found", message: "no source with that id"}}
    end
  end
end
