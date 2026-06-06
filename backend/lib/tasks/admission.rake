namespace :admission do
  desc "Run the admission worker loop (paces queue → admitted; control plane, Principle III)"
  task run: :environment do
    require Rails.root.join("lib/admission_loop")
    AdmissionLoop.run
  end

  desc "Run a single admission pass over all published raids (for cron/manual use)"
  task tick: :environment do
    require Rails.root.join("lib/admission_loop")
    AdmissionLoop.tick_once
  end
end
