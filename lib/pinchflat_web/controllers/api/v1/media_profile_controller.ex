defmodule PinchflatWeb.Api.V1.MediaProfileController do
  @moduledoc """
  Read-only listing of media profiles so an API client can offer a choice between them
  without having to know the numeric IDs, which differ between environments.
  """

  use PinchflatWeb, :controller

  alias Pinchflat.Profiles

  @doc """
  Lists every media profile as `{id, name}`.

  Returns a 200 JSON response.
  """
  def index(conn, _params) do
    render(conn, :index, media_profiles: Profiles.list_media_profiles())
  end
end
