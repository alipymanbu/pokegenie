Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions.
  get "up" => "rails/health#show", as: :rails_health_check

  resources :raids, only: %i[index show] do
    member do
      get :metrics
    end
    # Waiting queue (US1 join/status; US2 stream added later)
    post "queue/join", to: "queue#join"
    get  "queue/status", to: "queue#status"
    # Slot reservation (the capacity-correct claim)
    resources :reservations, only: %i[create]
  end
end
