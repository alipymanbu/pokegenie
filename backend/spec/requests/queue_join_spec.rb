require "rails_helper"

RSpec.describe "Queue join", type: :request do
  it "joins the line and returns a token + 1-based position (FR-001)" do
    raid = create_raid(capacity: 20)

    post "/raids/#{raid.id}/queue/join", params: { trainer_handle: "ash" }, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["token"]).to be_present
    expect(body["state"]).to eq("waiting")
    expect(body["position"]).to eq(1)
    expect(body["depth"]).to eq(1)
  end

  it "is idempotent: re-joining keeps the same position (duplicate-join edge case)" do
    raid = create_raid(capacity: 20)
    create_trainers(1) # noise

    post "/raids/#{raid.id}/queue/join", params: { trainer_handle: "misty" }, as: :json
    post "/raids/#{raid.id}/queue/join", params: { trainer_handle: "brock" }, as: :json
    first_pos = response.parsed_body["position"]

    post "/raids/#{raid.id}/queue/join", params: { trainer_handle: "brock" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["position"]).to eq(first_pos) # unchanged
    expect(response.parsed_body["depth"]).to eq(2) # not 3 — no duplicate entry
  end

  it "rejects joining a full raid with 409 (FR-013)" do
    raid = create_raid(capacity: 1, slots_remaining: 0)

    post "/raids/#{raid.id}/queue/join", params: { trainer_handle: "ash" }, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("raid_full")
  end

  it "rejects joining an unpublished raid with 409" do
    raid = create_raid(capacity: 20, status: "draft")

    post "/raids/#{raid.id}/queue/join", params: { trainer_handle: "ash" }, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("not_published")
  end
end
