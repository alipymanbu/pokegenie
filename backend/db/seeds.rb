# Seed a sample published raid (capacity 20) to queue for — see quickstart.md.
raid = Raid.find_or_create_by!(boss: "Mewtwo", gym_name: "Central Park Gym") do |r|
  r.starts_at = 1.hour.from_now
  r.capacity = 20
  r.slots_remaining = 20
  r.status = "published"
end

puts "Seeded raid ##{raid.id}: #{raid.boss} @ #{raid.gym_name} (capacity #{raid.capacity}, status #{raid.status})"
