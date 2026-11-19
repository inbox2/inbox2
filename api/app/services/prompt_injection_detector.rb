# Scans agent-processed content for prompt injection patterns (spec 11.4.4)
# Returns a risk assessment with matched patterns and severity.
class PromptInjectionDetector
  SEVERITY_HIGH = "high".freeze
  SEVERITY_MEDIUM = "medium".freeze
  SEVERITY_LOW = "low".freeze

  # Patterns that indicate prompt injection attempts
  PATTERNS = [
    { pattern: /ignore\s+(all\s+)?(previous|prior|above)\s+(instructions?|prompts?|rules?)/i,
      severity: SEVERITY_HIGH, label: "instruction_override" },
    { pattern: /you\s+are\s+now\s+(a|an|acting\s+as)/i,
      severity: SEVERITY_HIGH, label: "role_reassignment" },
    { pattern: /disregard\s+(all|any|the)\s+(previous|prior|safety|system)/i,
      severity: SEVERITY_HIGH, label: "safety_bypass" },
    { pattern: /system\s*prompt|system\s*message|initial\s*prompt/i,
      severity: SEVERITY_MEDIUM, label: "system_probe" },
    { pattern: /\bDAN\b.*\bjailbreak\b|\bjailbreak\b.*\bDAN\b/i,
      severity: SEVERITY_HIGH, label: "jailbreak_attempt" },
    { pattern: /repeat\s+(back\s+)?(the\s+)?(instructions?|prompt|system\s*message)/i,
      severity: SEVERITY_MEDIUM, label: "prompt_extraction" },
    { pattern: /pretend\s+(you|that|to\s+be)\s+(are\s+)?(a\s+different|not\s+bound|free\s+from)/i,
      severity: SEVERITY_HIGH, label: "constraint_evasion" },
    { pattern: /\[INST\]|\[\/INST\]|<<SYS>>|<\|im_start\|>/i,
      severity: SEVERITY_HIGH, label: "format_injection" },
    { pattern: /base64_decode|eval\s*\(|exec\s*\(/i,
      severity: SEVERITY_MEDIUM, label: "code_injection" },
    { pattern: /bypass\s+(content\s+)?filter|override\s+(safety|content)\s+(policy|filter)/i,
      severity: SEVERITY_MEDIUM, label: "filter_bypass" }
  ].freeze

  def initialize(content)
    @content = content.to_s
  end

  def scan
    matches = []

    PATTERNS.each do |entry|
      if @content.match?(entry[:pattern])
        matches << { label: entry[:label], severity: entry[:severity] }
      end
    end

    {
      safe: matches.empty?,
      risk_level: highest_severity(matches),
      matches: matches
    }
  end

  def safe?
    scan[:safe]
  end

  private

  def highest_severity(matches)
    return nil if matches.empty?

    order = [SEVERITY_LOW, SEVERITY_MEDIUM, SEVERITY_HIGH]
    matches.map { |m| m[:severity] }.max_by { |s| order.index(s) }
  end
end
