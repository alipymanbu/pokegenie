require "rails_helper"

RSpec.describe "Raids (organizer)", type: :request do
  it "creates a raid as draft with slots_remaining seeded to capacity (FR-012)" do
    post "/raids", params: {
      boss: "Rayquaza", gym_name: "Sky Pillar", starts_at: 1.hour.from_now.iso8601, capacity: 18
    }, as: :json

    expect(response).to have_http_status(:created)
    body = response.parsed_body
    expect(body["status"]).to eq("draft")
    expect(body["capacity"]).to eq(18)
    expect(body["slots_remaining"]).to eq(18)
  end

  it "rejects an invalid capacity with 422" do
    post "/raids", params: {
      boss: "Rayquaza", gym_name: "Sky Pillar", starts_at: 1.hour.from_now.iso8601, capacity: 0
    }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "publishing a draft lets trainers join it (FR-012/013)" do
    post "/raids", params: {
      boss: "Kyogre", gym_name: "Seafloor Cavern", starts_at: 1.hour.from_now.iso8601, capacity: 5
    }, as: :json
    raid_id = response.parsed_body["id"]

    # Before publish: join is rejected.
    post "/raids/#{raid_id}/queue/join", params: { trainer_handle: "ash" }, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("not_published")

    post "/raids/#{raid_id}/publish", as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["status"]).to eq("published")

    # After publish: join works.
    post "/raids/#{raid_id}/queue/join", params: { trainer_handle: "ash" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["position"]).to eq(1)
  end

  it "lists only published raids" do
    post "/raids", params: { boss: "A", gym_name: "G", starts_at: 1.hour.from_now.iso8601, capacity: 5 }, as: :json
    draft_id = response.parsed_body["id"]
    post "/raids", params: { boss: "B", gym_name: "H", starts_at: 1.hour.from_now.iso8601, capacity: 5 }, as: :json
    pub_id = response.parsed_body["id"]
    post "/raids/#{pub_id}/publish", as: :json

    get "/raids"
    ids = response.parsed_body["raids"].map { |r| r["id"] }
    expect(ids).to include(pub_id)
    expect(ids).not_to include(draft_id)
  end
end
