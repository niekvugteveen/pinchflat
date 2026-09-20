defmodule Pinchflat.Repo.Migrations.AddMediaLimitToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :media_limit, :integer
      add :media_limit_behaviour, :string, default: "wait_for_slot", null: false
    end
  end
end
