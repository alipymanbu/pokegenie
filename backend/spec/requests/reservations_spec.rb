require "rails_helper"

RSpec.describe "Reservations", type: :request do
  def join(raid, handle)
    post "/raids/#{raid.id}/queue/join", params: { trainer_handle: handle }, as: :json
    Trainer.find_by!(handle: handle)
  end

  it "claims a slot once admitted → 201 confirmed (FR-006)" do
    raid = create_raid(capacity: 5)
    trainer = join(raid, "ash")
    admit!(raid, trainer)

    post "/raids/#{raid.id}/reservations", params: { trainer_handle: "ash" }, as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body["status"]).to eq("confirmed")
    expect(response.parsed_body["trainer_handle"]).to eq("ash")
    expect(raid.reload.slots_remaining).to eq(4)
  end

  it "returns 200 (not 201) on idempotent replay (FR-008)" do
    raid = create_raid(capacity: 5)
    trainer = join(raid, "ash")
    admit!(raid, trainer)

    post "/raids/#{raid.id}/reservations", params: { trainer_handle: "ash" }, as: :json
    expect(response).to have_http_status(:created)

    admit!(raid, trainer) # re-admit (claim cleared the flag)
    post "/raids/#{raid.id}/reservations", params: { trainer_handle: "ash" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(confirmed_count(raid)).to eq(1)
  end

  it "rejects a claim from a non-admitted trainer with 409 not_admitted" do
    raid = create_raid(capacity: 5)
    join(raid, "ash") # joined but not admitted

    post "/raids/#{raid.id}/reservations", params: { trainer_handle: "ash" }, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("not_admitted")
  end

  it "rejects a claim when the raid is full with 409 raid_full (FR-009)" do
    raid = create_raid(capacity: 1)
    a = join(raid, "ash")
    b = join(raid, "gary")
    admit!(raid, a)
    admit!(raid, b)

    post "/raids/#{raid.id}/reservations", params: { trainer_handle: "ash" }, as: :json
    expect(response).to have_http_status(:created)

    post "/raids/#{raid.id}/reservations", params: { trainer_handle: "gary" }, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("raid_full")
  end
end
