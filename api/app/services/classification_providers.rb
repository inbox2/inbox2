# Switchable triage vendors (docs/E2EE.md Phase E, docs/Triage.md), mirroring
# the DeliveryProviders ESP framework: the pipeline talks to an adapter, never a
# vendor client directly.
#
# Interface: `configured?` + `triage(state:, questions:) -> JevTriage::Verdict`
# (state/questions built by JevTriage). Adapters must be stateless. Selection is
# global via INBOX2_CLASSIFICATION_PROVIDER.
module ClassificationProviders
  KIND_TYPESAFE = "typesafe".freeze
  KIND_STUB = "stub".freeze
  KINDS = [KIND_TYPESAFE, KIND_STUB].freeze

  def self.default_kind
    ENV.fetch("INBOX2_CLASSIFICATION_PROVIDER", KIND_TYPESAFE)
  end

  def self.default
    build(default_kind)
  end

  def self.build(kind)
    case kind
    when KIND_STUB then Stub.new
    else Typesafe.new
    end
  end

  # TypeSafe's Jev (Jev::Client). Raises Jev::Client errors for the caller to
  # classify (transient → retry, auth/request → holding pen).
  class Typesafe
    def initialize(client: Jev::Client.default)
      @client = client
    end

    def configured?
      @client.configured?
    end

    def triage(state:, questions:)
      JevTriage.verdict(@client.ask(state: state, questions: questions), questions)
    end
  end

  # Deterministic offline provider for tests and outage drills: files every
  # thread into INBOX2_CLASSIFICATION_STUB_SLUG with INBOX2_CLASSIFICATION_STUB_LABEL
  # (default fyi).
  class Stub
    SOURCE = "stub".freeze

    def initialize(slug: ENV["INBOX2_CLASSIFICATION_STUB_SLUG"], label: ENV["INBOX2_CLASSIFICATION_STUB_LABEL"])
      @slug = slug
      @label = label.presence || TriageLabel::FYI
    end

    def configured?
      @slug.present?
    end

    def triage(state:, questions:)
      JevTriage::Verdict.new(
        label: questions[:label] ? @label : nil,
        priority: nil,
        space: questions[:space] ? @slug : nil,
        source: SOURCE
      )
    end
  end
end
