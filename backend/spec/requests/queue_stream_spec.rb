require "rails_helper"

RSpec.describe "Queue SSE stream", type: :request do
  it "returns 404 when the trainer can't be resolved (bad/missing token)" do
    raid = create_raid(capacity: 5)
    get "/raids/#{raid.id}/queue/stream", params: { token: "nope" }
    expect(response).to have_http_status(:not_found)
  end

  it "is an event-stream and emits 'admitted' then closes for an already-admitted trainer" do
    raid = create_raid(capacity: 5)
    trainer = create_trainers(1).first
    admit!(raid, trainer) # claim pass present; not in the queue → admitted branch, terminal

    get "/raids/#{raid.id}/queue/stream", params: { trainer_handle: trainer.handle }

    expect(response.media_type).to eq("text/event-stream")
    expect(response.body).to include("event: admitted")
  end

  it "streams an initial 'position' then 'admitted' when the worker admits mid-stream" do
    raid = create_raid(capacity: 5)
    trainer = create_trainers(1).first
    RaidQueue::Join.call(raid: raid, trainer: trainer) # waiting, position 1

    body = +""
    streamer = Thread.new do
      get "/raids/#{raid.id}/queue/stream", params: { trainer_handle: trainer.handle }
      body = response.body
    end

    sleep 0.4 # let the stream send its first position + the subscriber attach
    RaidQueue::AdmitBatch.call(raid: raid) # pops trainer + publishes 'admitted'
    streamer.join(5)

    expect(body).to include("event: position")
    expect(body).to include("event: admitted")
  end
end
