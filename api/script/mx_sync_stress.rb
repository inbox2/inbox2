# MX sync stress check (docs/MX-Sync.md) — what the transactional specs can't see.
#   RAILS_ENV=test RAILS_MAX_THREADS=16 bin/rails runner script/mx_sync_stress.rb
# 8 writers make real commits (inserts, bulk updates, tagging, merges, deletes) over
# a handful of threads while a client pulls continuously. Passes when the client
# ends up holding every record at its final version and nothing deleted, and the
# deadlock count stays near the no-trigger baseline (~1). Cleans up after itself.
begin
require "factory_bot_rails"
require "rack/mock"
include FactoryBot::Syntax::Methods

WRITERS = 8; ITER = 150
user = create(:user, username: "stress_#{SecureRandom.hex(3)}")
org = create(:organization, owner: user, domain: "stress-#{SecureRandom.hex(3)}.test")
create(:membership, user: user, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)
token = create(:session, user: user).token
convs = 6.times.map { create(:conversation, organization: org) }
tag = create(:tag, organization: org)

deadlocks = Concurrent::AtomicFixnum.new(0); errors = Queue.new; done = Concurrent::AtomicBoolean.new(false)
held = {}  # key => change_seq, what the "client" has
gone = Set.new

pull = lambda do |cursor|
  res = Rack::MockRequest.new(Rails.application).get(
    "/api/v1/orgs/#{org.key}/sync/pull?limit=50#{cursor && "&since=#{cursor}"}",
    "HTTP_AUTHORIZATION" => "Bearer #{token}", "HTTP_HOST" => "localhost")
  raise "pull #{res.status}: #{res.body[0, 200]}" unless res.status == 200
  JSON.parse(res.body)
end
apply = lambda do |data|
  data["records"].each_value { |rs| rs.each { |r| held[r["id"]] = [held[r["id"]].to_i, r["change_seq"]].max } }
  data["deleted"].each { |d| gone << d["id"]; held.delete(d["id"]) }
end

puller = Thread.new do
  cursor = nil
  until done.true?
    data = pull.(cursor); apply.(data); cursor = data["cursor"]
    sleep 0.005 unless data["has_more"]
  end
  loop { data = pull.(cursor); apply.(data); cursor = data["cursor"]; break unless data["has_more"] }
  2.times { data = pull.(cursor); apply.(data); cursor = data["cursor"] }   # horizon catches up
end

writers = WRITERS.times.map do |w|
  Thread.new do
    rng = Random.new(w)
    ITER.times do
      ActiveRecord::Base.connection_pool.with_connection do
        begin
          case rng.rand(6)
          when 0, 1 then Message.create!(conversation: convs.sample(random: rng), organization: org, from_address: "a@b.test", to_address: "c@d.test", subject: "s", body_plain: "x" * rng.rand(2000), is_inbound: true)
          when 2 then Conversation.update_all_in_order(Conversation.where(id: convs.map(&:id).shuffle(random: rng).first(4)), read: [true, false].sample(random: rng))
          when 3 then c = convs.sample(random: rng); ConversationTag.where(conversation: c, tag: tag).delete_all; ConversationTag.create!(conversation: c, tag: tag) rescue ActiveRecord::RecordNotUnique
          when 4 then a, b = convs.sample(2, random: rng); ActiveRecord::Base.transaction { Message.where(conversation_id: a.id).limit(3).update_all(conversation_id: b.id); sleep(rng.rand * 0.02) }
          when 5 then m = Message.where(organization_id: org.id).order("random()").first; m&.destroy
          end
        rescue ActiveRecord::Deadlocked then deadlocks.increment
        rescue ActiveRecord::RecordNotFound, ActiveRecord::InvalidForeignKey then nil
        rescue => e then errors << "#{e.class}: #{e.message[0, 160]}"
        end
      end
    end
  end
end
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
writers.each(&:join); elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
done.make_true; puller.join

truth = {}
Conversation.where(organization_id: org.id).pluck(:key, :change_seq).each { |k, s| truth[k] = s }
Message.where(organization_id: org.id).pluck(:key, :change_seq).each { |k, s| truth[k] = s }
missing = truth.keys - held.keys
stale = truth.select { |k, s| held[k] && held[k] < s }
ghosts = held.keys - truth.keys
puts "writes: #{WRITERS * ITER} in #{elapsed.round(1)}s | live records: #{truth.size} | tombstones: #{SyncTombstone.where(organization_id: org.id).count}"
puts "deadlocks: #{deadlocks.value} | other errors: #{errors.size}#{errors.empty? ? '' : " e.g. #{errors.pop}"}"
puts "MISSING on client: #{missing.size} | STALE on client: #{stale.size} | GHOSTS (deleted, still held): #{ghosts.size}"
puts((missing.empty? && stale.empty? && ghosts.empty?) ? "RESULT: client converged exactly" : "RESULT: DIVERGED #{missing.first(3)} #{stale.first(3)} #{ghosts.first(3)}")
ensure
  if defined?(org) && org
    [Message, Note, ConversationTag].each { |m| m.where(m == ConversationTag ? { conversation_id: convs.map(&:id) } : { organization_id: org.id }).delete_all rescue nil }
    Conversation.where(organization_id: org.id).delete_all rescue nil
    SyncTombstone.where(organization_id: org.id).delete_all
    Tag.where(organization_id: org.id).delete_all; Session.where(user_id: user.id).delete_all
    Membership.where(organization_id: org.id).delete_all
    org.destroy rescue nil; user.destroy rescue nil
  end
end
