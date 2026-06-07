Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions.
  get "up" => "rails/health#show", as: :rails_health_check

  resources :raids, only: %i[index show create] do
    member do
      get :metrics
      post :publish
    end
    # Waiting queue (US1 join/status; US2 stream added later)
    post "queue/join", to: "queue#join"
    get  "queue/status", to: "queue#status"
    get  "queue/stream", to: "queue_streams#show" # SSE (US2)
    post "queue/reconnect", to: "queue#reconnect" # resume from token (US3)
    # Slot reservation (the capacity-correct claim)
    resources :reservations, only: %i[create]
  end

  # Elastic encounters (feature 002): queue for a Pokémon, system auto-assigns a room.
  resources :encounters, only: %i[index show create] do
    member do
      get :metrics
      post :publish
    end
    post "queue/join", to: "encounter_queue#join"
    get  "queue/status", to: "encounter_queue#status"
    post "queue/reconnect", to: "encounter_queue#reconnect"
    get  "queue/stream", to: "encounter_streams#show"
  end
end
