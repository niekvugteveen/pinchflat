defmodule PinchflatWeb.Api.V1.MediaProfileControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Settings

  setup do
    {:ok, %{token: Settings.get!(:route_token)}}
  end

  describe "index" do
    test "returns 401 without a token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/media_profiles")

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "lists media profiles as id and name", %{conn: conn, token: token} do
      media_profile = media_profile_fixture()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/v1/media_profiles")

      assert %{"media_profiles" => [rendered]} = json_response(conn, 200)
      assert rendered == %{"id" => media_profile.id, "name" => media_profile.name}
    end
  end
end
