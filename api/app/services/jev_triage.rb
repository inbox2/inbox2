# The Jev triage contract (docs/Triage.md): builds the `state` and `questions`
# a Jev call sends, and reads its answers back into a Verdict. Pure functions —
# the Rust core has the byte-identical twin (`triage::jev_questions` /
# `triage::jev_state`), locked by fixtures/parity/fixtures.json → `jev_triage`.
module JevTriage
  MAX_MESSAGES = 8
  MAX_CHARS = 1500

  DIRECTION_RECEIVED = "received".freeze
  DIRECTION_SENT = "sent".freeze

  # The `space` Choice's escape hatch; never a real Space slug.
  NO_MATCH = "no_match".freeze
  # A space answer below this probability goes to the holding pen instead.
  SPACE_MIN_PROBABILITY = 0.5

  # The `priority` Score levels, index = value (0.0–4.0).
  PRIORITY_LEVELS = [
    "No attention needed: can be ignored, archived, or read whenever",
    "Low: worth reading eventually, no action or deadline",
    "Normal: needs a response or action within the next few days",
    "High: needs a response or action today, or blocks someone's work",
    "Urgent: needs immediate attention, such as an outage, a security incident, or a deadline within hours"
  ].freeze

  LABEL_QUESTION = "Which label describes what `thread` needs from its owner (`owner`) right now?".freeze
  LABEL_FOCUS = "Judge the newest message in the context of the thread. Bulk, marketing, newsletter and " \
                "automated mail never needs a personal reply from the owner: label it by what it is, such as " \
                "a bill to pay, a booked appointment, a statement to review, something to read, a receipt or " \
                "a system notification.".freeze
  PRIORITY_INSTRUCTIONS = "How soon does the owner of `thread` need to pay attention to it?".freeze
  SPACE_QUESTION = "Which team space should `thread` be filed in?".freeze
  SPACE_FOCUS = "Judge the main purpose of the thread.".freeze
  NO_MATCH_WHAT = "A genuine email that none of the spaces above clearly covers".freeze

  # label/space: a slug or nil (nil = not asked, or no confident space);
  # priority: Float or nil; source: provenance for conversations.triage_source.
  Verdict = Struct.new(:label, :priority, :space, :source, keyword_init: true)

  module_function

  # messages: [{direction:, from:, text:}] oldest first. Keeps the newest 8, each
  # cut to 1500 chars.
  def state(owner:, subject:, messages:)
    msgs = messages.last(MAX_MESSAGES).map do |m|
      { direction: m[:direction], from: m[:from].to_s, text: m[:text].to_s[0, MAX_CHARS] }
    end
    {
      owner: owner.to_s,
      thread: { subject: subject.to_s, messages: msgs, last_direction: msgs.last&.dig(:direction) }
    }
  end

  # labels: objects with slug/name/description/not_for/enabled, in position
  # order (disabled ones are skipped). spaces: classifiable spaces in position
  # order (slug/name/description/not_for); empty = don't ask the space question.
  def questions(labels:, spaces:, ask_label: true)
    q = {}
    if ask_label
      q[:label] = {
        type: "choice",
        instructions: { question: LABEL_QUESTION, focus: LABEL_FOCUS },
        criteria: labels.select(&:enabled).to_h { |l| [l.slug, criterion(l.name, l.description, l.not_for)] }
      }
    end
    q[:priority] = { type: "score", instructions: PRIORITY_INSTRUCTIONS, criteria: PRIORITY_LEVELS }
    if spaces.any?
      criteria = spaces.to_h { |s| [s.slug, criterion(s.name, s.description.presence || s.name, s.not_for)] }
      criteria[NO_MATCH] = { what: NO_MATCH_WHAT }
      q[:space] = {
        type: "choice",
        instructions: { question: SPACE_QUESTION, focus: SPACE_FOCUS },
        criteria: criteria
      }
    end
    q
  end

  # Reads a Jev response against the questions that produced it.
  def verdict(response, questions)
    answers = response["answers"] || {}
    label = nil
    if (asked = questions[:label])
      choice = answers.dig("label", "choice")
      label = asked[:criteria].key?(choice) ? choice : TriageLabel::FYI
    end
    space = nil
    if questions[:space]
      choice = answers.dig("space", "choice")
      probability = answers.dig("space", "probabilities", choice).to_f
      space = choice if choice.present? && choice != NO_MATCH && probability >= SPACE_MIN_PROBABILITY
    end
    score = answers.dig("priority", "score")
    Verdict.new(label: label, priority: score&.to_f, space: space, source: "jev:#{response['model']}")
  end

  def criterion(name, what, not_for)
    c = { name: name, what: what }
    c[:not_for] = not_for if not_for.present?
    c
  end
end
