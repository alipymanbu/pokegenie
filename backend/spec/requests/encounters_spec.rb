require "rails_helper"

RSpec.describe "Encounters", type: :request do
  def create_encounter(boss: "Mewtwo", label: "Mega Raid Hour", room_size: 20)
    post "/encounters", params: {
      boss: boss, label: label, starts_at: 1.hour.from_now.iso8601, room_size: room_size
    }, as: :json
    response.parsed_body
  end

  it "creates one encounter per boss and funnels duplicates into it (no dupes)" do
    first = create_encounter
    expect(response).to have_http_status(:created)

    second = create_encounter(label: "Different Gym", room_size: 10) # same boss
    expect(response).to have_http_status(:ok)                         # reused, not created

    expect(second["id"]).to eq(first["id"])                           # same encounter row
    expect(Encounter.active.where("lower(boss) = 'mewtwo'").count).to eq(1)
  end

  it "treats the boss case-insensitively when deduping" do
    first = create_encounter(boss: "Mewtwo")
    again = create_encounter(boss: "mewtwo")
    expect(again["id"]).to eq(first["id"])
    expect(Encounter.active.count).to eq(1)
  end

  it "keeps distinct bosses as separate encounters" do
    mewtwo = create_encounter(boss: "Mewtwo")
    rayquaza = create_encounter(boss: "Rayquaza")
    expect(rayquaza["id"]).not_to eq(mewtwo["id"])
    expect(Encounter.active.count).to eq(2)
  end

  it "lets a boss be re-created once its prior encounter is closed" do
    first = create_encounter(boss: "Mewtwo")
    Encounter.find(first["id"]).update!(status: "closed")

    reopened = create_encounter(boss: "Mewtwo")
    expect(response).to have_http_status(:created)
    expect(reopened["id"]).not_to eq(first["id"])
  end
end
